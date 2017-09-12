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
  context->erl_port = port;

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
  // TODO: implement me
  return 0;
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
