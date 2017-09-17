//----------------------------------------------------------------------------
// preamble

//----------------------------------------------------------
// unix OS {{{

#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/uio.h>
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
// Erlang port driver API

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
  ErlDrvTermData write_reply_to;
};

static int cdrv_send_ok(ErlDrvPort port, ErlDrvTermData receiver);
static int cdrv_send_data(ErlDrvPort port, ErlDrvTermData receiver, ErlDrvTermData *data, size_t len);
static int cdrv_send_error(ErlDrvPort port, ErlDrvTermData receiver, int error);

//----------------------------------------------------------
// entry point definition {{{

static ErlDrvData   cdrv_start(ErlDrvPort port, char *cmd);
static void         cdrv_stop(ErlDrvData drv_data);
static ErlDrvSSizeT cdrv_control(ErlDrvData drv_data, unsigned int command, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen);
static void         cdrv_ready_input(ErlDrvData drv_data, ErlDrvEvent event);
static void         cdrv_ready_output(ErlDrvData drv_data, ErlDrvEvent event);
static void         cdrv_stop_select(ErlDrvEvent event, void *reserved);
static void         cdrv_outputv(ErlDrvData drv_data, ErlIOVec *ev);
static void         cdrv_flush(ErlDrvData drv_data);

ErlDrvEntry driver_entry = {
  NULL,                         // int        init(void)
  cdrv_start,                   // ErlDrvData start(ErlDrvPort port, char *cmd)
  cdrv_stop,                    // void       stop(ErlDrvData drv_data)
  NULL,                         // void       output(ErlDrvData drv_data, char *buf, ErlDrvSizeT len) // port_command/2 handler
  cdrv_ready_input,             // void       ready_input(ErlDrvData, ErlDrvEvent)  // "ready for reading" event
  cdrv_ready_output,            // void       ready_output(ErlDrvData, ErlDrvEvent) // "ready for writing" event
  PORT_DRIVER_NAME,             // <driver name>
  NULL,                         // void       finish(void)
  NULL,                         // <reserved>
  cdrv_control,                 // int        control(...) // port_control/3 handler
  NULL,                         // void       timeout(ErlDrvData drv_data)
  cdrv_outputv,                 // void       outputv(ErlDrvData drv_data, ErlIOVec *ev) // port_command/2 handler, faster
  NULL,                         // void       ready_async(ErlDrvData drv_data, ErlDrvThreadData thread_data)
  cdrv_flush,                   // void       flush(ErlDrvData drv_data)
  NULL,                         // int        call(...) // erlang:port_call/3 handler
  NULL,                         // void       event(ErlDrvData drv_data, ErlDrvEvent event, ErlDrvEventData event_data)
  ERL_DRV_EXTENDED_MARKER,
  ERL_DRV_EXTENDED_MAJOR_VERSION,
  ERL_DRV_EXTENDED_MINOR_VERSION,
  ERL_DRV_FLAG_USE_PORT_LOCKING,  // driver flags
  NULL,                         // <reserved>
  NULL,                         // void  process_exit(...) // called when monitored process dies
  cdrv_stop_select              // void  stop_select(ErlDrvEvent event, void *reserved) // called to close an event object
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

static
ErlDrvData cdrv_start(ErlDrvPort port, char *cmd)
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

static
void cdrv_stop(ErlDrvData drv_data)
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

static
void cdrv_stop_select(ErlDrvEvent event, void *reserved)
{
  long int fd = (long int)event;
  close(fd);
}

// }}}
//----------------------------------------------------------
// Erlang port control {{{

static
ErlDrvSSizeT cdrv_control(ErlDrvData drv_data, unsigned int command,
                          char *buf, ErlDrvSizeT len,
                          char **rbuf, ErlDrvSizeT rlen)
{
  struct subproc_context *context = (struct subproc_context *)drv_data;

  if (command == 0) { // port initialization {{{
    // initialization: setting file descriptors and maybe PID

    if (context->fdin != -1 || context->fdout != -1) // FDs already set
      return -1;

    if (len != 12)
      return -1;

    // `buf' contains [FDR, FDW] or [FDR, FDW, PID], so 8 or 12 bytes
    context->fdin = unpack32((unsigned char *)buf);
    context->fdout = unpack32((unsigned char *)(buf + 4));
    pid_t pid = unpack32((unsigned char *)(buf + 8));
    if (pid > 0)
      context->pid = pid;

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
  } // }}}

  if (command == 1) { // setopts() {{{
    // setopts()

    if (len != 7)
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

    size_t new_size = unpack32((unsigned char *)(buf + 3));
    if (new_size == 0)
      // no change to buffer size
      return 0;

    // TODO: careful about shrinking a buffer with data
    // TODO: context->buffer = driver_realloc(context->buffer, new_size);
    context->buffer_size = new_size;

    return 0;
  } // }}}

  if (command == 2) { // getopts() {{{
    // getopts()

    // this should never be called
    if (11 > rlen) *rbuf = driver_alloc(11);

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

    store32((unsigned char *)(*rbuf + 7),
            (context->pid > 0) ? context->pid : 0);
    return 11;
  } // }}}

  if (command == 3) { // close(read|write|read_write) {{{
    // close FD(s)

    if (len != 1 || buf[0] < 1 || buf[0] > 3)
      return -1;

    if ((buf[0] == 1 || buf[0] == 3) && context->fdin >= 0) {
      ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdin);
      driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_READ, 0);
      context->fdin = -1;
    }
    if ((buf[0] == 2 || buf[0] == 3) && context->fdout >= 0) {
      ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdout);
      driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_WRITE, 0);
      context->fdout = -1;

      ErlDrvSizeT queued_bytes = driver_sizeq(context->erl_port);
      if (queued_bytes > 0) {
        // NOTE: `send()' blocks until the write queue gets empty, so if this
        // operation is called from the same process as `send()' (typically
        // the port owner), the queue should already be empty
        driver_deq(context->erl_port, queued_bytes);

        ErlDrvTermData data[] = {
          ERL_DRV_ATOM, driver_mk_atom("error"),
          ERL_DRV_ATOM, driver_mk_atom("closed"),
          ERL_DRV_TUPLE, 2
        };
        cdrv_send_data(context->erl_port, context->write_reply_to,
                       data, sizeof(data) / sizeof(data[0]));
      }
    }

    return 0;
  } // }}}

  // TODO: "child terminated" notification
  // TODO: "read one packet", called from recv()

  return -1;
}

// }}}
//----------------------------------------------------------
// Erlang input on select descriptor {{{

static
void cdrv_ready_input(ErlDrvData drv_data, ErlDrvEvent event)
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
// Erlang output ready on select descriptor {{{

static
void cdrv_ready_output(ErlDrvData drv_data, ErlDrvEvent event)
{
  struct subproc_context *context = (struct subproc_context *)drv_data;
  // `event' is fdout descriptor

  ErlDrvSizeT queued_bytes = driver_sizeq(context->erl_port);
  if (queued_bytes == 0) {
    driver_select(context->erl_port, event, ERL_DRV_WRITE, 0);
    set_busy_port(context->erl_port, 0);
    return;
  }

  int iov_len;
  SysIOVec *iov = driver_peekq(context->erl_port, &iov_len);

  ssize_t result = writev((long int)event, (struct iovec *)iov, iov_len);
  if (result > 0)
    queued_bytes = driver_deq(context->erl_port, result);

  if (queued_bytes == 0) {
    cdrv_send_ok(context->erl_port, context->write_reply_to);

    driver_select(context->erl_port, event, ERL_DRV_WRITE, 0);
    set_busy_port(context->erl_port, 0);
  } else if (result >= 0 || errno == EWOULDBLOCK || errno == EAGAIN) {
    // partial write() (possibly the written part is zero); stay busy and
    // selected (i.e., do nothing)
  } else {
    // write error
    cdrv_send_error(context->erl_port, context->write_reply_to, errno);
    driver_deq(context->erl_port, driver_sizeq(context->erl_port));
    ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdout);
    driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_WRITE, 0);
    set_busy_port(context->erl_port, 0);
    context->fdout = -1;
  }
}

// }}}
//----------------------------------------------------------
// Erlang output {{{

static
void cdrv_outputv(ErlDrvData drv_data, ErlIOVec *ev)
{
  struct subproc_context *context = (struct subproc_context *)drv_data;

  if (context->fdout < 0) {
    ErlDrvTermData data[] = {
      ERL_DRV_ATOM, driver_mk_atom("error"),
      ERL_DRV_ATOM, driver_mk_atom("closed"),
      ERL_DRV_TUPLE, 2
    };
    cdrv_send_data(context->erl_port, driver_caller(context->erl_port),
                   data, sizeof(data) / sizeof(data[0]));
    return;
  }

  SysIOVec *iov = ev->iov;
  int iov_len = ev->vsize;
  uint32_t packet_size = ev->size;
  switch (context->packet_mode) {
    case pfx1: case pfx2: case pfx4:
      // add data prefix
      // TODO: make space for packet prefix when iov[0].iov_len != 0 or
      // iov[0].iov_base != NULL
      iov[0].iov_len = context->packet_mode == pfx4 ? 4 :
                       context->packet_mode == pfx2 ? 2 : 1;
      iov[0].iov_base = (void *)&packet_size;
    break;
    default:
      // add nothing
    break;
  }

  ssize_t result = writev(context->fdout, (struct iovec *)iov, iov_len);

  if (result == ev->size) {
    cdrv_send_ok(context->erl_port, driver_caller(context->erl_port));
  } else if ((result >= 0 && result < ev->size) ||
             (result <  0 && (errno == EWOULDBLOCK || errno == EAGAIN))) {
    // partial write() (possibly the written part is zero)

    // NOTE: sending ACK/NAK is delayed until the queue is flushed
    context->write_reply_to = driver_caller(context->erl_port);

    // TODO: build ErlIOVec when iov != ev->iov
    driver_enqv(context->erl_port, ev, (result > 0) ? result : 0);
    ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdout);
    driver_select(context->erl_port, event, ERL_DRV_WRITE, 1);
    set_busy_port(context->erl_port, 1);
  } else {
    // write error
    cdrv_send_error(context->erl_port, driver_caller(context->erl_port),
                    errno);

    // NOTE: the write queue should be empty here
    ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdout);
    driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_WRITE, 0);
    context->fdout = -1;
  }
}

// }}}
//----------------------------------------------------------
// flush write queue {{{

static
void cdrv_flush(ErlDrvData drv_data)
{
  struct subproc_context *context = (struct subproc_context *)drv_data;

  ErlDrvSizeT queued_bytes = driver_sizeq(context->erl_port);
  if (queued_bytes == 0)
    // well, this callback wouldn't be called if queued_bytes == 0
    return;

  driver_deq(context->erl_port, queued_bytes);

  ErlDrvTermData data[] = {
    ERL_DRV_ATOM, driver_mk_atom("error"),
    ERL_DRV_ATOM, driver_mk_atom("closed"),
    ERL_DRV_TUPLE, 2
  };
  cdrv_send_data(context->erl_port, context->write_reply_to,
                 data, sizeof(data) / sizeof(data[0]));
}

// }}}
//----------------------------------------------------------

//----------------------------------------------------------------------------
// message sending helpers {{{

static
int cdrv_send_data(ErlDrvPort port, ErlDrvTermData receiver,
                   ErlDrvTermData *data, size_t len)
{
  ErlDrvTermData reply[6 + 10] = {
    ERL_DRV_ATOM, driver_mk_atom("subproc_reply"),
    ERL_DRV_PORT, driver_mk_port(port)
  };
  memcpy(reply + 4, data, sizeof(ErlDrvTermData) * len);
  reply[4 + len] = ERL_DRV_TUPLE;
  reply[5 + len] = 3;
  return driver_send_term(port, receiver, reply, 6 + len);
}

static
int cdrv_send_ok(ErlDrvPort port, ErlDrvTermData receiver)
{
  ErlDrvTermData reply[] = {
    ERL_DRV_ATOM, driver_mk_atom("subproc_reply"),
    ERL_DRV_PORT, driver_mk_port(port),
    ERL_DRV_ATOM, driver_mk_atom("ok"),
    ERL_DRV_TUPLE, 3
  };
  return driver_send_term(port, receiver,
                          reply, sizeof(reply) / sizeof(reply[0]));
}

static
int cdrv_send_error(ErlDrvPort port, ErlDrvTermData receiver, int error)
{
  ErlDrvTermData reply[] = {
    ERL_DRV_ATOM, driver_mk_atom("subproc_reply"),
    ERL_DRV_PORT, driver_mk_port(port),
    ERL_DRV_ATOM, driver_mk_atom("error"),
    ERL_DRV_ATOM, driver_mk_atom(erl_errno_id(error)),
    ERL_DRV_TUPLE, 2,
    ERL_DRV_TUPLE, 3
  };
  return driver_send_term(port, receiver,
                          reply, sizeof(reply) / sizeof(reply[0]));
}

// }}}
//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker:nowrap
