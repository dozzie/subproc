//----------------------------------------------------------------------------
// preamble

//----------------------------------------------------------
// unix OS {{{

#include <ctype.h>
#include <string.h>

#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

// }}}
//----------------------------------------------------------
// local includes {{{

#include "supervisor.h"
#include "proto_event.h" // EVENT_MESSAGE_SIZE
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
  char *exe_path = strchr(cmd, ' ');
  if (exe_path == NULL)
    return ERL_DRV_ERROR_BADARG;
  ++exe_path; // skip space

  struct subproc_sup_context *context =
    driver_alloc(sizeof(struct subproc_sup_context));
  memset(context, 0, sizeof(*context));

  context->erl_port = port;

  // port_control() should return binaries
  set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);

  if (supervisor_spawn(&context->sup, exe_path) < 0) {
    driver_free(context);
    return ERL_DRV_ERROR_ERRNO;
  }

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
  close(fd);
}

// }}}
//----------------------------------------------------------
// Erlang port control {{{

ErlDrvSSizeT driver_control(ErlDrvData drv_data, unsigned int command,
                            char *buf, ErlDrvSizeT len,
                            char **rbuf, ErlDrvSizeT rlen)
{
  struct subproc_sup_context *context = (struct subproc_sup_context *)drv_data;

  if (command == 1) {
    // assume that `*rbuf' is at least four bytes large
    store32((unsigned char *)*rbuf, (uint32_t)context->sup.pid);
    return 4;
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
