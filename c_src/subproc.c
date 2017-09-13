//----------------------------------------------------------------------------
// preamble

//----------------------------------------------------------
// unix OS {{{

#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>

// }}}
//----------------------------------------------------------
// local includes {{{

#include "int_pack.h"

// }}}
//----------------------------------------------------------
// Erlang port driver {{{

#include <erl_driver.h>
#include <ei.h> // Erlang term manipulation

// }}}
//----------------------------------------------------------
// definitions {{{

#define PORT_DRIVER_NAME      "subproc_drv"
#define PORT_DRIVER_NAME_SYM   subproc_drv

#define PORT_DRIVER_NAME_LEN (sizeof(PORT_DRIVER_NAME) - 1)

// }}}
//----------------------------------------------------------

//----------------------------------------------------------------------------
// Erlang port driver API {{{

struct subproc_context {
  enum { passive, active, once } read_mode;
  enum { string, binary } data_mode;
  enum { raw, pfx1, pfx2, pfx4, line } packet_mode;
  size_t buffer_size;
  size_t buffer_used;
  char *buffer;
  int fdin;
  int fdout;
  pid_t pid;
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
  struct subproc_context *context =
    driver_alloc(sizeof(struct subproc_context));

  context->read_mode = passive;
  context->fdin = context->fdout = -1;
  context->pid = -1;
  context->read_mode = passive;
  context->data_mode = string;
  context->packet_mode = raw;
  context->buffer_used = context->buffer_size = 0;
  context->buffer = NULL;
  context->erl_port = port;

  // port_control() should return binaries
  set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);

  return (ErlDrvData)context;
}

// }}}
//----------------------------------------------------------
// Erlang port stop {{{

void driver_stop(ErlDrvData drv_data)
{
  struct subproc_context *context = (struct subproc_context *)drv_data;

  if (context->fdin >= 0 && context->fdin == context->fdout) {
    ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdin);
    driver_select(context->erl_port, event,
                  ERL_DRV_USE | ERL_DRV_READ | ERL_DRV_WRITE, 0);
    context->fdin = context->fdout = -1;
  }

  if (context->fdin >= 0) {
    ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdin);
    driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_READ, 0);
  }
  if (context->fdout >= 0) {
    ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdout);
    driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_WRITE, 0);
  }

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
  struct subproc_context *context = (struct subproc_context *)drv_data;

  if (command == 0) {
    // initialization: setting file descriptors and maybe PID

    if (context->fdin != -1 || context->fdout != -1) // FDs already set
      return -1;

    // `buf' contains [FDR, FDW] or [FDR, FDW, PID], so 8 or 12 bytes
    context->fdin = unpack32((unsigned char *)buf);
    context->fdout = unpack32((unsigned char *)(buf + 4));
    if (len == 12)
      context->pid = unpack32((unsigned char *)(buf + 8));

    if (context->fdin > 0) {
      fcntl(context->fdin, F_SETFL,
            O_NONBLOCK | fcntl(context->fdin, F_GETFL));
      ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdin);
      driver_select(context->erl_port, event, ERL_DRV_USE, 1);
    }

    if (context->fdout > 0) {
      fcntl(context->fdout, F_SETFL,
            O_NONBLOCK | fcntl(context->fdout, F_GETFL));
      ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdout);
      driver_select(context->erl_port, event, ERL_DRV_USE, 1);
    }

    return 0;
  }

  if (command == 1) {
    // setopts()

    if (len != 3 && len != 7)
      return -1;

    unsigned int read_mode   = buf[0];
    unsigned int data_mode   = buf[1];
    unsigned int packet_mode = buf[2];
    if (read_mode > 3 || data_mode > 2 || packet_mode > 5)
      return -1;

    switch (read_mode) {
      case 1: context->read_mode = passive; break;
      case 2: context->read_mode = active; break;
      case 3: context->read_mode = once; break;
      default: break; // 0, no change
    }
    switch (data_mode) {
      case 1: context->data_mode = string; break;
      case 2: context->data_mode = binary; break;
      default: break; // 0, no change
    }
    switch (packet_mode) {
      case 1: context->packet_mode = raw; break;
      case 2: context->packet_mode = pfx1; break;
      case 3: context->packet_mode = pfx2; break;
      case 4: context->packet_mode = pfx4; break;
      case 5: context->packet_mode = line; break;
      default: break; // 0, no change
    }

    if (len == 7) {
      size_t new_size = unpack32((unsigned char *)(buf + 3));
      // TODO: careful about shrinking a buffer with data
      // TODO: context->buffer = driver_realloc(context->buffer, new_size);
      context->buffer_size = new_size;
    }

    return 0;
  }

  if (command == 2) {
    // getopts()

    // this should never be called
    if (context->pid <= 0 && 7 > rlen) *rbuf = driver_alloc(7);
    if (context->pid > 0 && 11 > rlen) *rbuf = driver_alloc(11);

    switch (context->read_mode) {
      case passive: (*rbuf)[0] = 1; break;
      case active:  (*rbuf)[0] = 2; break;
      case once:    (*rbuf)[0] = 3; break;
      default:      (*rbuf)[0] = 0; break; // never reached
    }
    switch (context->data_mode) {
      case string: (*rbuf)[1] = 1; break;
      case binary: (*rbuf)[1] = 2; break;
      default:     (*rbuf)[1] = 0; break; // never reached
    }
    switch (context->packet_mode) {
      case raw:  (*rbuf)[2] = 1; break;
      case pfx1: (*rbuf)[2] = 2; break;
      case pfx2: (*rbuf)[2] = 3; break;
      case pfx4: (*rbuf)[2] = 4; break;
      case line: (*rbuf)[2] = 5; break;
      default:   (*rbuf)[2] = 0; break; // never reached
    }
    store32((unsigned char *)(*rbuf + 3), context->buffer_size);

    if (context->pid > 0) {
      store32((unsigned char *)(*rbuf + 7), context->pid);
      return 11;
    } else {
      return 7;
    }
  }

  // TODO: "child terminated" notification
  // TODO: "read one packet", called from recv()
  // TODO: "close FD" command

  return -1;
}

// }}}
//----------------------------------------------------------
// Erlang input on select descriptor {{{

void driver_ready_input(ErlDrvData drv_data, ErlDrvEvent event)
{
  struct subproc_context *context = (struct subproc_context *)drv_data;
  // `event' is fdin descriptor

  ErlDrvPort port = context->erl_port;
  ErlDrvTermData owner = driver_connected(port);

  ErlDrvTermData data[] = { // send `{subproc, Port, Data}'
    ERL_DRV_ATOM, driver_mk_atom("subproc"),
    ERL_DRV_PORT, driver_mk_port(port),
    //ERL_DRV_BUF2BINARY, (ErlDrvTermData)buffer, read_len,
    ERL_DRV_BUF2BINARY, (ErlDrvTermData)(""), 1,
    ERL_DRV_TUPLE, 3
  };

  // FIXME: this will be removed in OTP R17, use erl_drv_send_term()
  driver_send_term(port, owner, data, sizeof(data) / sizeof(data[0]));
}

// }}}
//----------------------------------------------------------

// }}}
//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker:nowrap
