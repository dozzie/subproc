//----------------------------------------------------------------------------
// preamble

//----------------------------------------------------------
// unix OS {{{

#include <ctype.h>
#include <string.h>

#include <stdint.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

// }}}
//----------------------------------------------------------
// local includes {{{

#include "supervisor.h"
#include "proto_event.h" // EVENT_MESSAGE_SIZE
#include "signal_names.h"
#include "int_pack.h"

// }}}
//----------------------------------------------------------
// Erlang port driver {{{

#include <erl_driver.h>
#include <ei.h> // Erlang term manipulation

// }}}
//----------------------------------------------------------
// definitions {{{

#define PORT_DRIVER_NAME      "subproc_sup_drv"
#define PORT_DRIVER_NAME_SYM   subproc_sup_drv

#define PORT_DRIVER_NAME_LEN (sizeof(PORT_DRIVER_NAME) - 1)

// }}}
//----------------------------------------------------------

//----------------------------------------------------------------------------
// Erlang port driver API {{{

struct subproc_sup_context {
  struct sup_h sup;
  ErlDrvPort erl_port;
};

// let's hope that the child process' FD number won't land higher than 4095
// FIXME: put a mutex here
static pid_t subproc_sup_fd_pids[4096];

//----------------------------------------------------------
// entry point definition {{{

ErlDrvData   driver_start(ErlDrvPort port, char *cmd);
void         driver_stop(ErlDrvData drv_data);
ErlDrvSSizeT driver_control(ErlDrvData drv_data, unsigned int command, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen);
void         driver_ready_input(ErlDrvData drv_data, ErlDrvEvent event);
void         driver_stop_select(ErlDrvEvent event, void *reserved);

ErlDrvEntry driver_entry = {
  NULL,                         // int        init(void)
  driver_start,                 // ErlDrvData start(ErlDrvPort port, char *cmd)
  driver_stop,                  // void       stop(ErlDrvData drv_data)
  NULL,                         // void       output(ErlDrvData drv_data, char *buf, int len) // Erlang has data for driver
  driver_ready_input,           // void       ready_input(ErlDrvData, ErlDrvEvent)
  NULL,                         // void       ready_output(ErlDrvData, ErlDrvEvent)
  PORT_DRIVER_NAME,             // <driver name>
  NULL,                         // void       finish(void)
  NULL,                         // <reserved>
  driver_control,               // int        control(...) // port_control/3 handler
  NULL,                         // void       timeout(ErlDrvData drv_data)
  NULL,                         // void       outputv(ErlDrvData drv_data, ErlIOVec *ev) // Erlang has data for driver
  NULL,                         // void       ready_async(ErlDrvData drv_data, ErlDrvThreadData thread_data)
  NULL,                         // void       flush(ErlDrvData drv_data)
  NULL,                         // int        call(...) // erlang:port_call/3 handler
  NULL,                         // void       event(ErlDrvData drv_data, ErlDrvEvent event, ErlDrvEventData event_data)
  ERL_DRV_EXTENDED_MARKER,
  ERL_DRV_EXTENDED_MAJOR_VERSION,
  ERL_DRV_EXTENDED_MINOR_VERSION,
  ERL_DRV_FLAG_USE_PORT_LOCKING,  // driver flags
  NULL,                         // <reserved>
  NULL,                         // called when process monitor dies
  driver_stop_select            // called to close an event object
};

// the same as <driver name> in structure above, but as identifer instead of
// string
DRIVER_INIT(PORT_DRIVER_NAME_SYM)
{
  return &driver_entry;
}

// }}}
//----------------------------------------------------------
// Erlang port start {{{

ErlDrvData driver_start(ErlDrvPort port, char *cmd)
{
  struct subproc_sup_context *context =
    driver_alloc(sizeof(struct subproc_sup_context));
  memset(context, 0, sizeof(*context));

  context->erl_port = port;

  // port_control() should return binaries
  set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);

  if (supervisor_spawn(&context->sup) < 0) {
    driver_free(context);
    return ERL_DRV_ERROR_ERRNO;
  }

  // TODO: check if `context->sup.events' fits in subproc_sup_fd_pids array
  subproc_sup_fd_pids[context->sup.events] = context->sup.pid;

  ErlDrvEvent event = (ErlDrvEvent)((long int)context->sup.events);
  driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_READ, 1);

  return (ErlDrvData)context;
}

// }}}
//----------------------------------------------------------
// Erlang port stop {{{

void driver_stop(ErlDrvData drv_data)
{
  struct subproc_sup_context *context = (struct subproc_sup_context *)drv_data;

  // `context->sup.events' will be closed in driver_stop_select() handler
  close(context->sup.comm);

  ErlDrvEvent event = (ErlDrvEvent)((long int)context->sup.events);
  driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_READ, 0);

  driver_free(context);
}

// }}}
//----------------------------------------------------------
// Erlang event close (after port stop) {{{

void driver_stop_select(ErlDrvEvent event, void *reserved)
{
  long int fd = (long int)event;
  pid_t pid = subproc_sup_fd_pids[fd];
  subproc_sup_fd_pids[fd] = 0;

  close(fd);
  if (pid != 0)
    waitpid(pid, NULL, 0);
}

// }}}
//----------------------------------------------------------
// Erlang port control {{{

static
ErlDrvSSizeT translate_signal_to_number(struct subproc_sup_context *context,
                                        char *buf, ErlDrvSizeT len,
                                        char **rbuf, ErlDrvSizeT rlen)
{
  char name[32] = "SIG";
  if (len >= sizeof(name) - 3)
    return 0;

  size_t i;
  for (i = 0; i < len; ++i)
    name[i + 3] = toupper(buf[i]);
  name[len + 3] = 0;

  int signum = find_signal_number(name);
  if (signum == 0)
    return 0;

  *rbuf[0] = (uint8_t)signum;
  return 1;
}

static
ErlDrvSSizeT translate_signal_to_name(struct subproc_sup_context *context,
                                      char *buf, ErlDrvSizeT len,
                                      char **rbuf, ErlDrvSizeT rlen)
{
  if (len < 1)
    return 0;

  // `MAX_SIGNAL_NAME' is just a few bytes, so this should never be called
  if (MAX_SIGNAL_NAME > rlen)
    *rbuf = driver_alloc(MAX_SIGNAL_NAME);

  const char *name = find_signal_name(buf[0]);
  if (name == NULL)
    return 0;

  name += 3; // skip "SIG" prefix
  size_t i;
  for (i = 0; name[i] != 0; ++i)
    (*rbuf)[i] = tolower(name[i]);

  return i;
}

static
ErlDrvSSizeT translate_errno_to_name(struct subproc_sup_context *context,
                                     char *buf, ErlDrvSizeT len,
                                     char **rbuf, ErlDrvSizeT rlen)
{
  if (len != 4)
    return 0;

  char *errstr = erl_errno_id(unpack32((unsigned char*)buf));
  size_t errlen = strlen(errstr);

  // `errlen' should be just a few bytes, so this should never be called
  if (errlen > rlen)
    *rbuf = driver_alloc(errlen);

  memcpy(*rbuf, errstr, errlen);

  return errlen;
}

ErlDrvSSizeT driver_control(ErlDrvData drv_data, unsigned int command,
                            char *buf, ErlDrvSizeT len,
                            char **rbuf, ErlDrvSizeT rlen)
{
  struct subproc_sup_context *context = (struct subproc_sup_context *)drv_data;

  if (command == 1) {
    return translate_signal_to_number(context, buf, len, rbuf, rlen);
  } else if (command == 2) {
    return translate_signal_to_name(context, buf, len, rbuf, rlen);
  } else if (command == 3) {
    return translate_errno_to_name(context, buf, len, rbuf, rlen);
  } else if (command != 0) {
    return -1;
  }

  // we know in advance how much space there will be needed; note that this
  // should never be executed, as ACK_MESSAGE_SIZE is just 10 bytes
  if (ACK_MESSAGE_SIZE > rlen)
    *rbuf = driver_alloc(ACK_MESSAGE_SIZE);

  int result = supervisor_send_command(&context->sup, buf, len, *rbuf);
  if (result < 0)
    driver_failure_posix(context->erl_port, errno);

  // TODO: convert `errno' in <<0x02 0x02 Errno:32 _Zero>> with erl_errno_id()

  return result;
}

// }}}
//----------------------------------------------------------
// Erlang input on select socket {{{

void driver_ready_input(ErlDrvData drv_data, ErlDrvEvent event)
{
  struct subproc_sup_context *context = (struct subproc_sup_context *)drv_data;
  // `event' is events descriptor

  // XXX: event protocol guarantees that an event message is of fixed size and
  // carries at most two file descriptors
  char buffer[EVENT_MESSAGE_SIZE];
  size_t bufsize = EVENT_MESSAGE_SIZE;
  int fds[2];
  size_t fdnum = 2;

  int result = supervisor_read_event(&context->sup, buffer, &bufsize,
                                     fds, &fdnum);
  if (result == 0) {
    // nothing to read (should never happen, since we have a "ready to read"
    // event)
    return;
  }

  if (result < 0) {
    driver_failure_posix(context->erl_port, errno);
    return;
  }

  if (bufsize == 0) { // EOF
    driver_failure_eof(context->erl_port);
    return;
  }

  ErlDrvPort port = context->erl_port;
  ErlDrvTermData owner = driver_connected(port);

  size_t data_size = 7; // this many positions in `data' are filled initially
  ErlDrvTermData data[] = { // send `{subproc_sup, Port, Data, [FDs]}'
    // data[0,1,2,3]
    ERL_DRV_ATOM, driver_mk_atom("subproc_sup"),
    ERL_DRV_PORT, driver_mk_port(port),
    // data[4,5,6]
    ERL_DRV_BUF2BINARY, (ErlDrvTermData)buffer, bufsize,
    // space to be filled later
    ERL_DRV_NIL, ERL_DRV_NIL, // ERL_DRV_INT, fds[0]
    ERL_DRV_NIL, ERL_DRV_NIL, // ERL_DRV_INT, fds[1]
    ERL_DRV_NIL, ERL_DRV_NIL, ERL_DRV_NIL, // list construction
    ERL_DRV_NIL, ERL_DRV_NIL  // tuple construction
  };

  // build a (possibly empty) proper list of integers (FDs)
  size_t i;
  for (i = 0; i < fdnum; ++i) {
    data[data_size++] = ERL_DRV_INT;
    data[data_size++] = fds[i];
  }
  data[data_size++] = ERL_DRV_NIL;
  data[data_size++] = ERL_DRV_LIST;
  data[data_size++] = 1 + fdnum; // one more for NIL (`[]')

  // now make it a tuple: `{subproc_sup, port(), binary(), [integer()]}'
  data[data_size++] = ERL_DRV_TUPLE;
  data[data_size++] = 4;

  // FIXME: driver_send_term() will be removed in OTP R17, use
  // erl_drv_send_term()
  driver_send_term(port, owner, data, data_size);
}

// }}}
//----------------------------------------------------------

// }}}
//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker:nowrap
