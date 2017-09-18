//----------------------------------------------------------------------------
// preamble

//----------------------------------------------------------
// unix OS {{{

#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/uio.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <string.h>

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

#define DEFAULT_BUFFER_SIZE (((4 * PIPE_BUF) > 4096) ? 4 * PIPE_BUF : 4096)
#define MAX_BUFFER_SIZE (64 * 1024 * 1024) // 64MB (gen_tcp uses the same max)

// zero errno value will never occur in the wild, so it can be used to request
// sending a `{error,closed}' tuple
#define ERROR_CLOSED 0

// argument for `cdrv_set_reading()' when receiver won't be used
#define ERL_PID_DOESNT_MATTER ERL_DRV_NIL

// argument for `cdrv_set_reading()'
#define READ_RECV     1
#define READ_ACTIVE   0

// argument for `cdrv_close_fd()'; can be OR-ed
#define FDR 0x01
#define FDW 0x02

// }}}
//----------------------------------------------------------

//----------------------------------------------------------------------------
// Erlang port driver API

struct subproc_context {
  int reading;
  enum { passive, active, once } read_mode;
  enum { string, binary } data_mode;
  enum { raw, pfx1, pfx2, pfx4, line } packet_mode;
  size_t buffer_used;
  ErlDrvBinary *buffer;
  int fdin;
  int fdout;
  pid_t pid;
  ErlDrvPort erl_port;
  ErlDrvTermData write_reply_to;
  ErlDrvTermData read_reply_to;
};

static int cdrv_send_ok(ErlDrvPort port, ErlDrvTermData receiver);
static int cdrv_send_data(ErlDrvPort port, ErlDrvTermData receiver, ErlDrvTermData *data, size_t len);
static int cdrv_send_active(ErlDrvPort port, char *reply_tag, ErlDrvTermData *data, size_t len, size_t tuple_len);
static int cdrv_send_error(ErlDrvPort port, ErlDrvTermData receiver, int error);

static void cdrv_close_fd(struct subproc_context *context, unsigned int fds);
static void cdrv_interrupt_write(struct subproc_context *context, int error);
static void cdrv_interrupt_read(struct subproc_context *context, int error);
static int  cdrv_set_reading(struct subproc_context *context, ErlDrvTermData caller, int is_recv, int *error);
static void cdrv_stop_reading(struct subproc_context *context);

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

  context->reading = 0;
  context->read_mode = passive;
  context->fdin = context->fdout = -1;
  context->pid = -1;
  context->read_mode = passive;
  context->data_mode = string;
  context->packet_mode = raw;
  context->buffer_used = 0;
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

  cdrv_close_fd(context, FDR | FDW);

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
    // setting file descriptors and maybe PID

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

    if (len != 7)
      return -1;

    unsigned int read_mode   = buf[0];
    unsigned int data_mode   = buf[1];
    unsigned int packet_mode = buf[2];
    if (read_mode > 3 || data_mode > 2 || packet_mode > 5)
      return -1;

    if (read_mode != passive && context->read_mode == passive) {
      // change from passive to active mode
      cdrv_interrupt_read(context, EINTR);
      // NOTE: no need to stop reading, since the new mode is one of the
      // active ones and it will be enabled back soon enough
      //cdrv_stop_reading(context);
    } else if (read_mode == passive && context->read_mode != passive) {
      // change from active to passive mode
      cdrv_stop_reading(context);
    }

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

    if (context->read_mode != passive) {
      // one of the active modes
      // NOTE: the only error possible here is when `fdin' is invalid
      cdrv_set_reading(context, ERL_PID_DOESNT_MATTER, READ_ACTIVE, NULL);
    }

    size_t new_size = unpack32((unsigned char *)(buf + 3));
    if (new_size == 0)
      // no change to buffer size
      return 0;

    // TODO: careful about shrinking a buffer with data
    // TODO: context->buffer = driver_realloc(context->buffer, new_size);

    return 0;
  } // }}}

  if (command == 2) { // getopts() {{{

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
    store32((unsigned char *)(*rbuf + 3),
            (context->buffer != NULL) ? context->buffer->orig_size : 0);

    store32((unsigned char *)(*rbuf + 7),
            (context->pid > 0) ? context->pid : 0);
    return 11;
  } // }}}

  if (command == 3) { // close(read|write|read_write) {{{

    if (len != 1 || buf[0] < 1 || buf[0] > 3)
      return -1;

    switch (buf[0]) {
      case 1:
        cdrv_interrupt_read(context, ERROR_CLOSED);
        cdrv_close_fd(context, FDR);
      break;
      case 2:
        cdrv_interrupt_write(context, ERROR_CLOSED);
        cdrv_close_fd(context, FDW);
      break;
      case 3:
        cdrv_interrupt_read(context, ERROR_CLOSED);
        cdrv_interrupt_write(context, ERROR_CLOSED);
        cdrv_close_fd(context, FDR | FDW);
      break;
      default:
        // never happens
        return -1;
    }

    return 0;
  } // }}}

  if (command == 4) { // recv() {{{
    // recv(): errors are signaled by sending a message

    ErlDrvTermData caller = driver_caller(context->erl_port);
    int error;
    if (cdrv_set_reading(context, caller, READ_RECV, &error) != 0)
      cdrv_send_error(context->erl_port, caller, error);
    // on success, `cdrv_ready_input()' sends a reply

    return 0;
  } // }}}

  if (command == 5) { // cancel_recv() {{{
    // recv() cancel
    if (context->fdin == -1)
      // possibly a race between read() error and read timeout; don't crash
      // the caller
      return 0;

    // dangling recv() cancel is not allowed
    if (context->read_mode != passive ||
        (context->reading &&
         driver_caller(context->erl_port) != context->read_reply_to))
      return -1;

    // since it's called from the same process that started the recv() call,
    // we don't need to send any "call interrupted" messages
    cdrv_stop_reading(context);

    return 0;
  } // }}}

  // TODO: "child terminated" notification

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

  // TODO: use `context->buffer'
  // TODO: honour `context->packet_mode'
  char buffer[DEFAULT_BUFFER_SIZE];
  ssize_t result = read((long int)event, buffer, sizeof(buffer));

  // this should not be necessary, but it does no harm
  if (result < 0 && (errno == EWOULDBLOCK || errno == EAGAIN))
    return;

  if (context->read_mode == passive) {
    if (result > 0) { // {ok, Data :: string() | binary()}
      ErlDrvTermData reply[] = {
        ERL_DRV_ATOM, driver_mk_atom("ok"),
        ((context->data_mode == string) ? ERL_DRV_STRING : ERL_DRV_BUF2BINARY),
          (ErlDrvTermData)(buffer), (ErlDrvTermData)result,
        ERL_DRV_TUPLE, 2
      };
      cdrv_send_data(context->erl_port, context->read_reply_to,
                     reply, sizeof(reply) / sizeof(reply[0]));
      cdrv_stop_reading(context);
    } else if (result == 0) { // eof
      ErlDrvTermData reply[] = {
        ERL_DRV_ATOM, driver_mk_atom("eof")
      };
      cdrv_send_data(context->erl_port, context->read_reply_to,
                     reply, sizeof(reply) / sizeof(reply[0]));
      cdrv_stop_reading(context);
      cdrv_close_fd(context, FDR);
    } else { // {error, Reason :: atom()}
      cdrv_send_error(context->erl_port, context->read_reply_to, errno);
      cdrv_stop_reading(context);
      cdrv_close_fd(context, FDR);
    }
  }

  // one of the active modes

  if (result > 0) { // {subproc, Port, Data :: string() | binary()}
    ErlDrvTermData reply[] = {
      ((context->data_mode == string) ? ERL_DRV_STRING : ERL_DRV_BUF2BINARY),
        (ErlDrvTermData)(buffer), (ErlDrvTermData)result
    };

    cdrv_send_active(context->erl_port, "subproc", reply,
                     sizeof(reply) / sizeof(reply[0]), 1);

    if (context->read_mode == once) {
      cdrv_stop_reading(context);
      context->read_mode = passive;
    }
  } else if (result == 0) { // {subproc_closed, Port}
    cdrv_send_active(context->erl_port, "subproc_closed", NULL, 0, 0);
    cdrv_stop_reading(context);
    cdrv_close_fd(context, FDR);
  } else { // {subproc_error, Port, Reason :: atom()}
    ErlDrvTermData reply[] = {
      ERL_DRV_ATOM, driver_mk_atom(erl_errno_id(errno))
    };

    cdrv_send_active(context->erl_port, "subproc_error", reply,
                     sizeof(reply) / sizeof(reply[0]), 1);
    cdrv_stop_reading(context);
    cdrv_close_fd(context, FDR);
  }
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
    cdrv_close_fd(context, FDW);
    set_busy_port(context->erl_port, 0);
  }
}

// }}}
//----------------------------------------------------------
// Erlang output {{{

static
void cdrv_outputv(ErlDrvData drv_data, ErlIOVec *ev)
{
  struct subproc_context *context = (struct subproc_context *)drv_data;

  ErlDrvTermData caller = driver_caller(context->erl_port);

  if (context->fdout < 0) {
    cdrv_send_error(context->erl_port, caller, ERROR_CLOSED);
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
    cdrv_send_ok(context->erl_port, caller);
  } else if ((result >= 0 && result < ev->size) ||
             (result <  0 && (errno == EWOULDBLOCK || errno == EAGAIN))) {
    // partial write() (possibly the written part is zero)

    // NOTE: sending ACK/NAK is delayed until the queue is flushed
    context->write_reply_to = caller;

    // TODO: build ErlIOVec when iov != ev->iov
    driver_enqv(context->erl_port, ev, (result > 0) ? result : 0);

    ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdout);
    driver_select(context->erl_port, event, ERL_DRV_WRITE, 1);
    set_busy_port(context->erl_port, 1);
  } else {
    // write error
    cdrv_send_error(context->erl_port, caller, errno);
    cdrv_close_fd(context, FDW);
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

  cdrv_interrupt_write(context, ERROR_CLOSED);
  driver_deq(context->erl_port, queued_bytes);
}

// }}}
//----------------------------------------------------------

//----------------------------------------------------------------------------
// port state and descriptor helpers {{{

static
int cdrv_set_reading(struct subproc_context *context, ErlDrvTermData caller,
                     int is_recv, int *error)
{
  if (context->fdin < 0) {
    if (error != NULL)
      *error = ERROR_CLOSED;
    return -1;
  }

  if ((is_recv && context->read_mode != passive) ||
      (!is_recv && context->read_mode == passive)) {
    if (error != NULL)
      *error = EINVAL;
    return -1;
  }

  if (context->read_mode == passive && context->reading) {
    if (error != NULL)
      *error = EALREADY;
    return -1;
  }

  if (is_recv) {
    context->reading = 1;
    context->read_reply_to = caller;
  }

  ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdin);
  driver_select(context->erl_port, event, ERL_DRV_READ, 1);

  return 0;
}

static
void cdrv_stop_reading(struct subproc_context *context)
{
  context->reading = 0;
  ErlDrvEvent event = (ErlDrvEvent)((long int)context->fdin);
  driver_select(context->erl_port, event, ERL_DRV_READ, 0);
}

static
void cdrv_interrupt_read(struct subproc_context *context, int error)
{
  if (context->read_mode != passive || !context->reading)
    return;

  context->reading = 0;
  cdrv_send_error(context->erl_port, context->read_reply_to, error);
}

static
void cdrv_interrupt_write(struct subproc_context *context, int error)
{
  if (driver_sizeq(context->erl_port) > 0)
    cdrv_send_error(context->erl_port, context->write_reply_to, error);
}

static
void cdrv_close_fd(struct subproc_context *context, unsigned int fds)
{
  ErlDrvEvent event;

  ErlDrvSizeT queued_bytes;
  if ((fds & FDW) == FDW &&
      (queued_bytes = driver_sizeq(context->erl_port)) > 0) {
    driver_deq(context->erl_port, queued_bytes);
    set_busy_port(context->erl_port, 0);
  }

  if (context->fdin >= 0 && context->fdin == context->fdout) {
    // bidirectional STDIO (socketpair(); pipe() only guarantees
    // unidirectional pipes)

    event = (ErlDrvEvent)((long int)context->fdin);

    if ((fds & (FDR | FDW)) == (FDR | FDW)) {
      // close the descriptor altogether
      driver_select(context->erl_port, event,
                    ERL_DRV_USE | ERL_DRV_READ | ERL_DRV_WRITE, 0);
      context->fdin = -1;
      context->fdout = -1;
    } else if ((fds & FDR) != 0) {
      driver_select(context->erl_port, event, ERL_DRV_READ, 0);
      shutdown(context->fdin, SHUT_RD);
      context->fdin = -1;
    } else { // (fds & FDW) != 0
      driver_select(context->erl_port, event, ERL_DRV_WRITE, 0);
      //set_busy_port(context->erl_port, 0); // already called
      shutdown(context->fdout, SHUT_WR);
      context->fdout = -1;
    }
  } else {
    // unidirectional, separate descriptors or an already half-closed
    // bidirectional STDIO
    if ((fds & FDR) != 0 && context->fdin >= 0) {
      event = (ErlDrvEvent)((long int)context->fdin);
      driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_READ, 0);
      context->fdin = -1;
    }

    if ((fds & FDW) != 0 && context->fdout >= 0) {
      event = (ErlDrvEvent)((long int)context->fdout);
      driver_select(context->erl_port, event, ERL_DRV_USE | ERL_DRV_WRITE, 0);
      //set_busy_port(context->erl_port, 0); // already called
      context->fdout = -1;
    }
  }
}

// }}}
//----------------------------------------------------------------------------
// message sending helpers {{{

static
int cdrv_send_active(ErlDrvPort port, char *reply_tag,
                     ErlDrvTermData *data, size_t len, size_t tuple_len)
{
  ErlDrvTermData reply[128] = {
    ERL_DRV_ATOM, driver_mk_atom(reply_tag),
    ERL_DRV_PORT, driver_mk_port(port)
  };
  if (len > 0)
    memcpy(reply + 4, data, sizeof(ErlDrvTermData) * len);
  reply[4 + len] = ERL_DRV_TUPLE;
  reply[5 + len] = tuple_len + 2;
  return driver_send_term(port, driver_connected(port), reply, 6 + len);
}

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
  char *error_atom;
  if (error == ERROR_CLOSED)
    error_atom = "closed";
  else
    error_atom = erl_errno_id(error);

  ErlDrvTermData reply[] = {
    ERL_DRV_ATOM, driver_mk_atom("subproc_reply"),
    ERL_DRV_PORT, driver_mk_port(port),
      ERL_DRV_ATOM, driver_mk_atom("error"),
      ERL_DRV_ATOM, driver_mk_atom(error_atom),
      ERL_DRV_TUPLE, 2,
    ERL_DRV_TUPLE, 3
  };
  return driver_send_term(port, receiver,
                          reply, sizeof(reply) / sizeof(reply[0]));
}

// }}}
//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker:nowrap
