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
#include <sys/ioctl.h>
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

// default size for reading buffers
#define DEFAULT_BUFFER_SIZE (((4 * PIPE_BUF) > 4096) ? 4 * PIPE_BUF : 4096)
#define MAX_PACKET_SIZE (64 * 1024 * 1024) // 64MB (gen_tcp uses the same max)

// payload of packets of this size and larger will be read to
// subproc_context.packet instead of subproc_context.buffer
#define BIG_PACKET_SIZE 256

// zero errno value will never occur in the wild, so it can be used to request
// sending a `{error,closed}' tuple
#define ERROR_CLOSED 0

// argument for `cdrv_set_reading()' when receiver won't be used
#define ERL_PID_DOESNT_MATTER ERL_DRV_NIL

// argument for `cdrv_set_reading()'
#define READ_RECV     1
#define READ_ACTIVE   0

// argument for `cdrv_close_fd()'; can be OR-ed
#define FDR             0x01
#define FDW             0x02
#define FDR_KEEP_PACKET 0x04

// }}}
//----------------------------------------------------------

//----------------------------------------------------------------------------
// Erlang port driver API

enum packet_mode { raw, pfx1, pfx2, pfx4, line };
enum read_mode { passive, active, once };
enum data_mode { string, binary };
enum process_status {
  process_not_initialized,
  process_undefined,
  process_alive,
  process_exited,
  process_killed
};

struct packet {
  enum packet_mode packet_mode;
  uint32_t target_size; // 0 if undefined
  uint32_t max_size;

  unsigned char pending[DEFAULT_BUFFER_SIZE]; // read but not parsed yet
  unsigned char *pending_start;
  size_t pending_used;

  ErlDrvBinary *buffer;
  size_t buffer_used;

  // reading large packets as separate binaries; after reading complete
  // packet, it's returned as (ErlDrvBinary *) and `packet' is reset to NULL
  int use_packet; // flag; for non-prefix packets always unset
  ErlDrvBinary *packet;
  size_t packet_used;
};

struct subproc_context {
  // flags
  uint8_t close_fds;
  uint8_t close_on_exit; // either exit() or killed by signal
  uint8_t reading;
  uint8_t exit_code; // or signal if the process was killed
  enum process_status process_status; // how to interpret exit_code
  // shutdown sequence
  ErlDrvBinary *output_pending;
  char *output_start;
  // how to read data (active/passive, packet format, return format)
  enum read_mode read_mode;
  uint8_t send_term_info;
  enum data_mode data_mode;
  enum packet_mode packet_mode;
  size_t max_packet_size;
  struct packet packet;
  // OS internals
  int fdin;
  int fdout;
  pid_t pid;
  // Erlang owner and reply-to addresses
  ErlDrvPort erl_port;
  ErlDrvTermData write_reply_to;
  ErlDrvTermData read_reply_to;
};

static int cdrv_send_ok(ErlDrvPort port, ErlDrvTermData receiver);
static int cdrv_send_data(ErlDrvPort port, ErlDrvTermData receiver, ErlDrvTermData *data, size_t len);
static int cdrv_send_active(ErlDrvPort port, char *reply_tag, ErlDrvTermData *data, size_t len, size_t tuple_len);
static int cdrv_send_error(ErlDrvPort port, ErlDrvTermData receiver, int error);
static ssize_t cdrv_flush_packet(struct subproc_context *context, ErlDrvTermData receiver, size_t pkt_count, size_t read_size);

//----------------------------------------------------------
// helpers for sending read results {{{

// NOTE: these three functions ignore `receiver' argument in active mode and
// send a message to driver_caller(context->erl_port)

// NOTE: on EOF (len == 0) and error (len < 0), reading descriptor is closed
// and read buffers are freed
static void cdrv_send_input(struct subproc_context *context, ErlDrvTermData receiver, void *data, ssize_t len, int error);
// to send a (size-prefixed) packet (valid read, non-EOF) with empty payload
static void cdrv_send_empty_input(struct subproc_context *context, ErlDrvTermData receiver);
// NOTE: this function assumes that read was successful and the whole binary
// is to be sent; caller should also call `driver_free_binary(data)'
static void cdrv_send_binary(struct subproc_context *context, ErlDrvTermData receiver, ErlDrvBinary *data);

// }}}
//----------------------------------------------------------

static int cdrv_check_fd_mode(int fd, unsigned int mode);
static void cdrv_close_fd(struct subproc_context *context, unsigned int fds);
static void cdrv_interrupt_write(struct subproc_context *context, int error);
static void cdrv_interrupt_read(struct subproc_context *context, int error);
static int  cdrv_set_reading(struct subproc_context *context, ErlDrvTermData caller, int is_recv, size_t recv_size, int *error);
static void cdrv_stop_reading(struct subproc_context *context);

// shutdown procedure helpers
static void   cdrv_shutdown_initiate(struct subproc_context *context);
static size_t cdrv_shutdown_send_data(struct subproc_context *context, ErlDrvTermData receiver, size_t read_size, size_t nmsg);
static void   cdrv_shutdown_send_exit(struct subproc_context *context);

// all of these are and smaller than PKT_ERR_NOT_READY
#define PKT_ERR_NOT_READY       -1
#define PKT_ERR_ENOMEM          -2
#define PKT_ERR_EMSGSIZE        -3
#define PKT_ERR_NEVER_REACHED   -255

static void packet_init(struct packet *ctx);
static void packet_free(struct packet *ctx);
static int  packet_errno(int error_code);
static int  packet_boundary(struct packet *ctx);
static int32_t packet_start_parse(struct packet *ctx,
                                  enum packet_mode packet_mode,
                                  size_t target_size, size_t max_size,
                                  int detect_big_packet);
static void* packet_get_pending(struct packet *ctx);
static void* packet_buffer(struct packet *ctx, size_t *size);
static int32_t packet_update_read(struct packet *ctx, size_t len);
static uint32_t packet_get(struct packet *ctx, char **resbuf,
                           ErlDrvBinary **resbin);

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

  // port flags
  context->close_fds = 0;
  context->close_on_exit = 0;
  // process' status
  context->exit_code = 0;
  context->process_status = process_not_initialized;
  context->pid = -1;
  // shutdown procedure fields
  context->output_pending = NULL;
  context->output_start = NULL;
  // operational data
  context->erl_port = port;
  context->fdin = context->fdout = -1;
  // flags, options, and buffers for reading
  context->reading = 0;
  context->read_mode = passive;
  context->send_term_info = 0;
  context->data_mode = string;
  context->packet_mode = raw;
  context->max_packet_size = MAX_PACKET_SIZE;
  packet_init(&context->packet);

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

  //packet_free(&context->packet); // called by cdrv_close_fd()
  cdrv_close_fd(context, FDR | FDW);

  if (context->output_pending != NULL)
    driver_free_binary(context->output_pending);

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

    if (context->process_status != process_not_initialized)
      return -1;

    if (len != 14)
      return -1;

    int fdin = unpack32((unsigned char *)buf);
    int fdout = unpack32((unsigned char *)(buf + 4));
    pid_t pid = unpack32((unsigned char *)(buf + 8));

    // check if the descriptors, if defined, have appropriate modes
    if ((fdin >= 0 && !cdrv_check_fd_mode(fdin, FDR)) ||
        (fdout >= 0 && !cdrv_check_fd_mode(fdout, FDW)))
      return -1;

    context->fdin = fdin;
    context->fdout = fdout;
    if (pid > 0) {
      context->pid = pid;
      context->process_status = process_alive;
    } else {
      context->process_status = process_undefined;
    }
    context->close_fds = buf[12];
    context->close_on_exit = buf[13];

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

    if (len != 8)
      return -1;

    enum read_mode read_mode;
    int send_term_info;
    enum data_mode data_mode;
    enum packet_mode packet_mode;

    switch (buf[0]) {
      case 0: read_mode = context->read_mode; break;
      case 1: read_mode = passive; break;
      case 2: read_mode = active; break;
      case 3: read_mode = once; break;
      default: return -1;
    }
    switch (buf[1]) {
      case 0: send_term_info = context->send_term_info; break;
      case 1: send_term_info = 0 /* false */; break;
      case 2: send_term_info = 1 /* true */; break;
      default: return -1;
    }
    switch (buf[2]) {
      case 0: data_mode = context->data_mode; break;
      case 1: data_mode = string; break;
      case 2: data_mode = binary; break;
      default: return -1;
    }
    switch (buf[3]) {
      case 0: packet_mode = context->packet_mode; break;
      case 1: packet_mode = raw; break;
      case 2: packet_mode = pfx1; break;
      case 3: packet_mode = pfx2; break;
      case 4: packet_mode = pfx4; break;
      case 5: packet_mode = line; break;
      default: return -1;
    }

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

    if (send_term_info && !context->send_term_info &&
        (context->process_status == process_exited ||
         context->process_status == process_killed)) {
      cdrv_shutdown_send_exit(context);
      send_term_info = 0; // mark the term info as already sent
    }

    context->read_mode = read_mode;
    context->send_term_info = send_term_info;
    context->data_mode = data_mode;
    context->packet_mode = packet_mode;

    size_t max_packet_size = unpack32((unsigned char *)(buf + 4));
    if (max_packet_size > MAX_PACKET_SIZE)
      context->max_packet_size = MAX_PACKET_SIZE;
    else if (max_packet_size > 0)
      context->max_packet_size = max_packet_size;

    if (context->read_mode != passive) {
      // one of the active modes

      if (context->output_pending) {
        // shutdown and some data left to send
        if (context->read_mode == active) {
          if (cdrv_shutdown_send_data(context, ERL_PID_DOESNT_MATTER, 0, 0) > 0)
            // we still need to send EOF
            cdrv_shutdown_send_data(context, ERL_PID_DOESNT_MATTER, 0, 0);
        } else { // context->read_mode == once
          cdrv_shutdown_send_data(context, ERL_PID_DOESNT_MATTER, 0, 1);
        }
        return 0;
      }

      int error;
      int result = cdrv_set_reading(context, ERL_PID_DOESNT_MATTER,
                                    READ_ACTIVE, 0, &error);
      // ERROR_CLOSED (fdin closed) can/should be ignored, but other errors
      // are important
      if (result < 0 && error != ERROR_CLOSED)
        driver_failure_posix(context->erl_port, error);
    }

    return 0;
  } // }}}

  if (command == 2) { // getopts() {{{

    // this should never be called
    if (12 > rlen) *rbuf = driver_alloc(12);

    switch (context->read_mode) {
      case passive: (*rbuf)[0] = 1; break;
      case active:  (*rbuf)[0] = 2; break;
      case once:    (*rbuf)[0] = 3; break;
      default:      (*rbuf)[0] = 0; break; // never reached
    }
    switch (context->send_term_info) {
      case 0:  (*rbuf)[1] = 1; break;
      default: (*rbuf)[1] = 2; break;
    }
    switch (context->data_mode) {
      case string: (*rbuf)[2] = 1; break;
      case binary: (*rbuf)[2] = 2; break;
      default:     (*rbuf)[2] = 0; break; // never reached
    }
    switch (context->packet_mode) {
      case raw:  (*rbuf)[3] = 1; break;
      case pfx1: (*rbuf)[3] = 2; break;
      case pfx2: (*rbuf)[3] = 3; break;
      case pfx4: (*rbuf)[3] = 4; break;
      case line: (*rbuf)[3] = 5; break;
      default:   (*rbuf)[3] = 0; break; // never reached
    }
    store32((unsigned char *)(*rbuf + 4), context->max_packet_size);

    store32((unsigned char *)(*rbuf + 8),
            (context->pid > 0) ? context->pid : 0);
    return 12;
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
    // recv(): request errors are signaled by sending a message

    if (len != 4) // invalid request qualifies to an exception, not a reply
      return -1;

    ErlDrvTermData caller = driver_caller(context->erl_port);

    uint32_t read_size = unpack32((unsigned char *)buf);
    if (read_size != 0 && context->packet_mode != raw) {
      // reading a specific number of bytes only allowed for raw packet mode
      cdrv_send_error(context->erl_port, caller, EINVAL);
      return 0;
    }

    if (context->output_pending) {
      // shutdown and some data left to send
      cdrv_shutdown_send_data(context, caller, read_size, 1);
      return 0;
    }

    int error;
    if (cdrv_set_reading(context, caller, READ_RECV, read_size, &error) != 0)
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

  if (command == 6) { // subprocess terminated {{{
    if (len != 2)
      return -1;

    if (context->process_status != process_alive)
      return -1;

    switch (buf[0]) {
      case 1: context->process_status = process_exited; break;
      case 2: context->process_status = process_killed; break;
      default: return -1;
    }
    context->exit_code = buf[1];

    if (context->fdin >= 0 && context->close_on_exit) {
      cdrv_shutdown_initiate(context);

      if (context->read_mode == passive && !context->reading) {
        // passive mode and no recv() in progress (nobody to send data to)

        // nothing();
      } else if (context->read_mode == passive || context->read_mode == once) {
        // read/send exactly one packet (if passive mode, recv() is in
        // progress and it has target packet size already set)

        cdrv_shutdown_send_data(context, context->read_reply_to, 0, 1);
      } else { // (context->read_mode == active)
        // read/send all packets

        // at least one data message was sent, send also EOF
        if (cdrv_shutdown_send_data(context, ERL_PID_DOESNT_MATTER, 0, 0) > 0)
          // we still need to send EOF
          cdrv_shutdown_send_data(context, ERL_PID_DOESNT_MATTER, 0, 0);
      }

      // no more poll() on fdin, all recv() calls will be satisfied within
      // cdrv_control() callback
      // NOTE: this needs to be called *after* cdrv_shutdown_send_data(),
      // because the latter uses context->read_mode to select message
      // recipient and format
      cdrv_stop_reading(context);
    }

    // a recv() already got a proper reply above
    //cdrv_interrupt_read(context, ERROR_CLOSED);
    cdrv_interrupt_write(context, ERROR_CLOSED);
    cdrv_close_fd(context, FDR_KEEP_PACKET | FDR | FDW);

    if (context->send_term_info) {
      cdrv_shutdown_send_exit(context);
      context->send_term_info = 0;
    }

    return 0;
  } // }}}

  if (command == 7) { // status() {{{
    // this should never be called
    if (2 > rlen) *rbuf = driver_alloc(2);

    switch (context->process_status) {
      case process_alive:
        (*rbuf)[0] = 1;
        (*rbuf)[1] = 0;
      break;
      case process_exited:
        (*rbuf)[0] = 2;
        (*rbuf)[1] = context->exit_code;
      break;
      case process_killed:
        (*rbuf)[0] = 3;
        (*rbuf)[1] = context->exit_code;
      break;
      default:
        (*rbuf)[0] = 0;
        (*rbuf)[1] = 0;
      break;
    }

    return 2;
  } // }}}

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

  if (context->packet_mode == raw && packet_boundary(&context->packet)) {
    // reading arbitrary sized chunks of raw data;
    // raw + specific size makes packet_boundary() return false, and pending
    // buffer was flushed before enabling reading from descriptor
    char buffer[DEFAULT_BUFFER_SIZE];
    ssize_t result = read((long int)event, buffer, sizeof(buffer));
    cdrv_send_input(context, context->read_reply_to, buffer, result, errno);
    return;
  }

  if (packet_boundary(&context->packet)) {
    // target size is only used for raw packets, and if it was set previously,
    // we're not at packet boundary, so it's safe to set it to zero

    // pending buffer flushing was done earlier (entering read mode:
    // cdrv_set_reading(); looping in active mode: at the end of this
    // function), so now we just have to start packet parsing

    int32_t result = packet_start_parse(&context->packet,
                                        context->packet_mode,
                                        0, // target size
                                        context->max_packet_size,
                                        (context->data_mode == binary));
    if (result < PKT_ERR_NOT_READY) {
      cdrv_send_input(context, context->read_reply_to,
                      NULL, -1, packet_errno(result));
      return;
    }
    // XXX: (result > PKT_ERR_NOT_READY) cannot occur here because the pending
    // buffer was flushed (see earlier comment in this block)
  }

  size_t bufsize = 0;
  void *buffer = packet_buffer(&context->packet, &bufsize);
  ssize_t result = read((long int)event, buffer, bufsize);
  if (result <= 0) {
    cdrv_send_input(context, context->read_reply_to, NULL, result, errno);
    return;
  }

  int32_t psize = packet_update_read(&context->packet, result);
  if (psize < PKT_ERR_NOT_READY) {
    cdrv_send_input(context, context->read_reply_to,
                    NULL, -1, packet_errno(psize));
    return;
  }

  if (psize == PKT_ERR_NOT_READY)
    // wait for more data
    return;

  // we have a complete packet (and we're at packet boundary)

  if (psize == 0) {
    // special case for size-prefixed packet with empty payload (regular
    // cdrv_send_input() thinks we got EOF, which is not the case)

    cdrv_send_empty_input(context, context->read_reply_to);
  } else {
    char *resbuf;
    ErlDrvBinary *resbin;
    packet_get(&context->packet, &resbuf, &resbin);
    if (resbin != NULL) {
      cdrv_send_binary(context, context->read_reply_to, resbin);
      driver_free_binary(resbin);
    } else {
      cdrv_send_input(context, context->read_reply_to, resbuf, psize, 0);
    }
  }

  if (context->read_mode == active) {
    // after a complete packet there could be some data leftovers; try parsing
    // and sending full packets out of them
    ssize_t sent = cdrv_flush_packet(context, ERL_PID_DOESNT_MATTER, 0, 0);
    if (sent < 0) {
      cdrv_send_input(context, context->read_reply_to,
                      NULL, -1, packet_errno(sent));
      return;
    }
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
                     int is_recv, size_t recv_size, int *error)
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

  if (!is_recv)
    // there was no way to pass read size (unlike `recv(S, 10)'), so ignore
    // this value in active modes
    recv_size = 0;

  // if this function is called for recv(), we're already at packet boundary;
  // in active modes packet parsing may be already in progress, though, so we
  // need to check
  if (packet_boundary(&context->packet)) {
    // active mode wants to get all packets possible, but {active,once} and
    // recv() only need one
    size_t send_count = (context->read_mode == active) ? 0 : 1;

    ssize_t sent = cdrv_flush_packet(context, caller, send_count, recv_size);
    if (sent < 0) {
      // fatal error (out of memory, packet too big, the like)
      if (error != NULL)
        *error = packet_errno(sent);
      cdrv_close_fd(context, FDR);
      return -1;
    }

    if (sent > 0 && context->read_mode != active) {
      // just one packet was requested and it was sent from pending data
      context->read_mode = passive;
      return 0;
    }
  }

  // nothing sent from pending buffer (or active mode), more data needed

  if (is_recv /* && context->read_mode == passive */) {
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
int cdrv_check_fd_mode(int fd, unsigned int mode)
{
  // O_ACCMODE mask isn't documented in fcntl(2) man page in neither Linux nor
  // FreeBSD, but SUSv3 says it's there
  int flags = fcntl(fd, F_GETFL) & O_ACCMODE;
  return (mode == FDR && (flags == O_RDONLY || flags == O_RDWR)) ||
         (mode == FDW && (flags == O_WRONLY || flags == O_RDWR));
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

  if ((fds & (FDR | FDR_KEEP_PACKET)) == FDR) {
    // TODO: maybe flush data from context->packet?
    packet_free(&context->packet);
  }

  // only unset `ERL_DRV_USE' flag when we're supposed to close the
  // descriptors
  int close_flag = context->close_fds ? ERL_DRV_USE : 0;

  if (context->fdin >= 0 && context->fdin == context->fdout) {
    // bidirectional STDIO (socketpair(); pipe() only guarantees
    // unidirectional pipes)

    event = (ErlDrvEvent)((long int)context->fdin);

    if ((fds & (FDR | FDW)) == (FDR | FDW)) {
      // close the descriptor altogether
      driver_select(context->erl_port, event,
                    close_flag | ERL_DRV_READ | ERL_DRV_WRITE, 0);
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
      driver_select(context->erl_port, event, close_flag | ERL_DRV_READ, 0);
      context->fdin = -1;
    }

    if ((fds & FDW) != 0 && context->fdout >= 0) {
      event = (ErlDrvEvent)((long int)context->fdout);
      driver_select(context->erl_port, event, close_flag | ERL_DRV_WRITE, 0);
      //set_busy_port(context->erl_port, 0); // already called
      context->fdout = -1;
    }
  }
}

// NOTE: errors (<0) returned from this function can be translated to `errno'
// values with packet_errno() function
static
ssize_t cdrv_flush_packet(struct subproc_context *context, ErlDrvTermData receiver,
                          size_t pkt_count, size_t read_size)
{
  ssize_t sent_packets = 0;

  while (pkt_count == 0 || sent_packets < pkt_count) {
    int32_t size = packet_start_parse(&context->packet, context->packet_mode,
                                      read_size, context->max_packet_size,
                                      (context->data_mode == binary));
    if (size < PKT_ERR_NOT_READY) // error, leave early
      return size;

    if (size == PKT_ERR_NOT_READY)
      break;

    if (size == 0) {
      // special case for size-prefixed packet with empty payload (regular
      // cdrv_send_input() thinks we got EOF, which is not the case)

      cdrv_send_empty_input(context, receiver);
      ++sent_packets;
      continue;
    }

    char *data = packet_get_pending(&context->packet);

    if (context->read_mode == passive) {
      cdrv_send_input(context, receiver, data, size, 0);
    } else {
      ErlDrvTermData reply[] = {
        ((context->data_mode == string) ? ERL_DRV_STRING : ERL_DRV_BUF2BINARY),
          (ErlDrvTermData)data, (ErlDrvTermData)size
      };

      cdrv_send_active(context->erl_port, "subproc", reply,
                       sizeof(reply) / sizeof(reply[0]), 1);
    }

    ++sent_packets;
  }

  return sent_packets;
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

static void cdrv_send_input(struct subproc_context *context,
                            ErlDrvTermData receiver,
                            void *data, ssize_t len, int error)
{
  // this should not be necessary (cdrv_ready_input() has some FD event
  // ready), but there's no harm to check it
  if (len < 0 && (error == EWOULDBLOCK || error == EAGAIN))
    return;

  if (len == 0 &&
      (!packet_boundary(&context->packet) ||
       (context->packet.packet_mode == raw &&
        context->packet.pending_used == 0 &&
        context->packet.buffer_used == 0 &&
        context->packet.pending_used == 0))) {
    // FIXME: move the condition to a function instead of checking the
    // structure internals directly
    len = -1;
    error = ERROR_CLOSED;
  }

  if (context->read_mode == passive) {
    if (len > 0) { // {ok, Data :: string() | binary()}
      ErlDrvTermData reply[] = {
        ERL_DRV_ATOM, driver_mk_atom("ok"),
        ((context->data_mode == string) ? ERL_DRV_STRING : ERL_DRV_BUF2BINARY),
          (ErlDrvTermData)(data), (ErlDrvTermData)len,
        ERL_DRV_TUPLE, 2
      };
      cdrv_send_data(context->erl_port, receiver,
                     reply, sizeof(reply) / sizeof(reply[0]));
      cdrv_stop_reading(context);
    } else if (len == 0) { // eof
      ErlDrvTermData reply[] = {
        ERL_DRV_ATOM, driver_mk_atom("eof")
      };
      cdrv_send_data(context->erl_port, receiver,
                     reply, sizeof(reply) / sizeof(reply[0]));
      cdrv_stop_reading(context);
      cdrv_close_fd(context, FDR);
    } else { // {error, Reason :: atom()}
      cdrv_send_error(context->erl_port, receiver, error);
      cdrv_stop_reading(context);
      cdrv_close_fd(context, FDR);
    }
  } else { // context->read_mode == active | once
    if (len > 0) { // {subproc, Port, Data :: string() | binary()}
      ErlDrvTermData reply[] = {
        ((context->data_mode == string) ? ERL_DRV_STRING : ERL_DRV_BUF2BINARY),
          (ErlDrvTermData)(data), (ErlDrvTermData)len
      };

      cdrv_send_active(context->erl_port, "subproc", reply,
                       sizeof(reply) / sizeof(reply[0]), 1);

      if (context->read_mode == once) {
        cdrv_stop_reading(context);
        context->read_mode = passive;
      }
    } else if (len == 0) { // {subproc_closed, Port}
      cdrv_send_active(context->erl_port, "subproc_closed", NULL, 0, 0);
      cdrv_stop_reading(context);
      cdrv_close_fd(context, FDR);
    } else { // {subproc_error, Port, Reason :: atom()}
      ErlDrvTermData reply[] = {
        ERL_DRV_ATOM, driver_mk_atom(erl_errno_id(error))
      };

      cdrv_send_active(context->erl_port, "subproc_error", reply,
                       sizeof(reply) / sizeof(reply[0]), 1);
      cdrv_stop_reading(context);
      cdrv_close_fd(context, FDR);
    }
  }
}

static void cdrv_send_empty_input(struct subproc_context *context,
                                  ErlDrvTermData receiver)
{
  if (context->read_mode == passive) {
    ErlDrvTermData reply[] = {
      ERL_DRV_ATOM, driver_mk_atom("ok"),
      ((context->data_mode == string) ? ERL_DRV_STRING : ERL_DRV_BUF2BINARY),
        (ErlDrvTermData)"", (ErlDrvTermData)0,
      ERL_DRV_TUPLE, 2
    };
    cdrv_send_data(context->erl_port, receiver,
                   reply, sizeof(reply) / sizeof(reply[0]));
    cdrv_stop_reading(context);
  } else {
    ErlDrvTermData reply[] = {
      ((context->data_mode == string) ? ERL_DRV_STRING : ERL_DRV_BUF2BINARY),
        (ErlDrvTermData)"", (ErlDrvTermData)0
    };

    cdrv_send_active(context->erl_port, "subproc", reply,
                     sizeof(reply) / sizeof(reply[0]), 1);

    if (context->read_mode == once) {
      cdrv_stop_reading(context);
      context->read_mode = passive;
    }
  }
}

static void cdrv_send_binary(struct subproc_context *context,
                             ErlDrvTermData receiver,
                             ErlDrvBinary *data)
{
  if (context->read_mode == passive) {
    ErlDrvTermData reply[] = {
      ERL_DRV_ATOM, driver_mk_atom("ok"),
      ERL_DRV_BINARY, (ErlDrvTermData)data, data->orig_size, 0,
      ERL_DRV_TUPLE, 2
    };
    cdrv_send_data(context->erl_port, receiver,
                   reply, sizeof(reply) / sizeof(reply[0]));
    cdrv_stop_reading(context);
  } else { // active | once
    ErlDrvTermData reply[] = {
      ERL_DRV_BINARY, (ErlDrvTermData)data, data->orig_size, 0
    };

    cdrv_send_active(context->erl_port, "subproc", reply,
                     sizeof(reply) / sizeof(reply[0]), 1);

    if (context->read_mode == once) {
      cdrv_stop_reading(context);
      context->read_mode = passive;
    }
  }
}

// }}}
//----------------------------------------------------------------------------
// "subprocess terminated" shutdown sequence {{{

// caller is expected to call cdrv_close_fd(context, FDR | FDR_KEEP_PACKET)
static
void cdrv_shutdown_initiate(struct subproc_context *context)
{
  int size_left = 0;
  if (context->fdin >= 0)
    ioctl(context->fdin, FIONREAD, &size_left);

  if (size_left > 0) {
    // TODO: skip allocating a binary if (size_left < DEFAULT_BUFFER_SIZE) and
    // fit the data into packet's pending buffer
    context->output_pending = driver_alloc_binary(size_left);
    if (context->output_pending == NULL)
      driver_failure_posix(context->erl_port, ENOMEM);
    // assume that read() returns the same as `size_left', i.e. nothing else
    // suddenly read data from our descriptor
    read(context->fdin, context->output_pending->orig_bytes, size_left);
    context->output_start = context->output_pending->orig_bytes;
  }
}

// send nmsg messages with payload to receiver
// EOF/{error,closed} message is only sent when no data packets were sent
// function returns number of data packets sent
static
size_t cdrv_shutdown_send_data(struct subproc_context *context,
                               ErlDrvTermData receiver,
                               size_t read_size, size_t nmsg)
{
  // XXX: the only case when this function is called with (read_size > 0) is
  // when (nmsg == 1)

  size_t count = 0;
  while (nmsg == 0 || count < nmsg) {
    int32_t packet_size = PKT_ERR_NOT_READY;

    if (packet_boundary(&context->packet)) {
      // only now there can be some data in pending buffer
      packet_size = packet_start_parse(&context->packet, context->packet_mode,
                                       read_size, context->max_packet_size,
                                       (context->data_mode == binary));

      // full packet ready from pending data
      if (packet_size == 0) {
        cdrv_send_empty_input(context, receiver);
        ++count;
        continue;
      } else if (packet_size > 0) {
        void *buffer = packet_get_pending(&context->packet);
        cdrv_send_input(context, receiver, buffer, packet_size, 0);
        ++count;
        continue;
      }

      // NOTE: if (packet_mode == line), it is possible that we're still at
      // packet boundary here
    }

    if (packet_size == PKT_ERR_NOT_READY && context->output_pending != NULL) {
      // packet parsing in progress

      size_t output_left = (context->output_pending->orig_bytes +
                            context->output_pending->orig_size) -
                           context->output_start;
      size_t buffer_size;
      void *buffer = packet_buffer(&context->packet, &buffer_size);

      if (output_left <= buffer_size) {
        // all pending data fits in the buffer
        memcpy(buffer, context->output_start, output_left);
        packet_size = packet_update_read(&context->packet, output_left);

        driver_free_binary(context->output_pending);
        context->output_pending = NULL;
        context->output_start = NULL;
      } else { // output_left > buffer_size
        // pass a chunk of pending output
        memcpy(buffer, context->output_start, buffer_size);
        packet_size = packet_update_read(&context->packet, buffer_size);

        context->output_start += buffer_size;
      }
    }

    if (packet_size < PKT_ERR_NOT_READY) {
      // fatal error, disregard `count' (if (count == 0), it's OK to send
      // EOF-like message, and if (count >= 1), we're in active mode anyway)
      cdrv_send_input(context, receiver, NULL, -1, packet_errno(packet_size));
      if (context->output_pending != NULL) {
        driver_free_binary(context->output_pending);
        context->output_pending = NULL;
        context->output_start = NULL;
      }
      return 0;
    } else if (packet_size == PKT_ERR_NOT_READY &&
               context->output_pending == NULL) {
      // no more data to feed packet with, so it's an EOF
      break; // exit the loop
    } else if (packet_size == PKT_ERR_NOT_READY) {
      // incomplete packet, but we can still add some data, continue the loop
    } else if (packet_size == 0) {
      // got a complete packet, send it and continue the loop
      cdrv_send_empty_input(context, receiver);
      ++count;
    } else { // (packet_size > 0)
      // got a complete packet, send it and continue the loop
      char *resbuf;
      ErlDrvBinary *resbin;
      packet_get(&context->packet, &resbuf, &resbin);
      if (resbin != NULL) {
        cdrv_send_binary(context, receiver, resbin);
        driver_free_binary(resbin);
      } else {
        cdrv_send_input(context, receiver, resbuf, packet_size, 0);
      }
      ++count;
    }
  }

  if (count == 0)
    // if we weren't able to send any data message, send an EOF now
    cdrv_send_input(context, receiver, NULL, 0, 0);

  return count;
}

static
void cdrv_shutdown_send_exit(struct subproc_context *context)
{
  ErlDrvTermData reply[8]; // XXX: keep in sync with maximum value of `count'
  size_t count = 0;

  switch (context->process_status) {
    case process_exited:
      reply[count++] = ERL_DRV_ATOM;
      reply[count++] = driver_mk_atom("exit");

      reply[count++] = ERL_DRV_UINT;
      reply[count++] = (ErlDrvUInt)context->exit_code;
    break;

    case process_killed:
      reply[count++] = ERL_DRV_ATOM;
      reply[count++] = driver_mk_atom("signal");

      reply[count++] = ERL_DRV_UINT;
      reply[count++] = (ErlDrvUInt)context->exit_code;
      // TODO: make a tuple {SigNum :: integer(), SigName :: atom()}
      // reply[count++] = ERL_DRV_ATOM;
      // reply[count++] = driver_mk_atom(signal_name);
      // reply[count++] = ERL_DRV_TUPLE;
      // reply[count++] = 2;
    break;

    default:
      // don't send anything (this should never be reached)
      return;
  }

  cdrv_send_active(context->erl_port, "subproc_terminated", reply, count, 2);
}

// }}}
//----------------------------------------------------------------------------
// packet parsing {{{

// internal helpers
static int32_t packet_pending_complete_size(struct packet *ctx);
static int32_t packet_alloc_buffer(struct packet *ctx);

//----------------------------------------------------------
// init/free {{{

static void packet_init(struct packet *ctx)
{
  ctx->packet_mode = raw;
  ctx->target_size = 0;
  ctx->max_size = MAX_PACKET_SIZE;

  ctx->pending_start = ctx->pending;
  ctx->pending_used = 0;

  ctx->buffer = NULL;
  ctx->buffer_used = 0;
  ctx->packet = NULL;
  ctx->packet_used = 0;
}

static void packet_free(struct packet *ctx)
{
  if (ctx->buffer != NULL)
    driver_free_binary(ctx->buffer);
  if (ctx->packet != NULL)
    driver_free_binary(ctx->packet);
  packet_init(ctx);
}

static int packet_errno(int error_code)
{
  switch (error_code) {
    case PKT_ERR_ENOMEM: return ENOMEM;
    case PKT_ERR_EMSGSIZE: return EMSGSIZE;
  }
  return ENOSYS;
}

// }}}
//----------------------------------------------------------
// packet_start_parse() {{{

// returns size of a complete packet that can be parsed from pending data,
// PKT_ERR_NOT_READY if there's too little data for a complete packet,
// <PKT_ERR_NOT_READY on errors (out of memory, too big (size-prefixed) packet
// expected from pending data)
// should only be called at packet boundary (packet_boundary())
static int32_t packet_start_parse(struct packet *ctx,
                                  enum packet_mode packet_mode,
                                  size_t target_size, size_t max_size,
                                  int detect_big_packet)
{
  ctx->packet_mode = packet_mode;
  // target size only makes sense for raw packets
  ctx->target_size = (packet_mode == raw) ? target_size : 0;
  ctx->max_size = (max_size > 0 && max_size < MAX_PACKET_SIZE) ?
                    max_size :
                    MAX_PACKET_SIZE;
  ctx->buffer_used = 0;
  ctx->packet_used = 0;
  if (packet_mode == pfx1 || packet_mode == pfx2 || packet_mode == pfx4 ||
      packet_mode == raw)
    ctx->use_packet = detect_big_packet;
  else
    ctx->use_packet = 0;

  int32_t packet_size = packet_pending_complete_size(ctx);
  // NOTE: packet errors (EMSGSIZE) will propagate through this `if'
  if (packet_size == PKT_ERR_NOT_READY && packet_alloc_buffer(ctx) < 0)
    // we ran out of memory when preparing for next data portion
    return PKT_ERR_ENOMEM;
  return packet_size;
}

// }}}
//----------------------------------------------------------
// packet_boundary() {{{

static
int packet_boundary(struct packet *ctx)
{
  // (ctx->packet_used > 0) means that we're parsing a size-prefixed packet,
  // and such packets have non-zero target_size
  return (ctx->target_size == 0 && ctx->buffer_used == 0);
}

// }}}
//----------------------------------------------------------
// packet_get_pending() {{{

// should only be called when packet_start_parse() returned non-zero
static void* packet_get_pending(struct packet *ctx)
{
  unsigned char *result = ctx->pending_start;

  ctx->pending_start += ctx->target_size;
  ctx->pending_used -= ctx->target_size;
  if (ctx->pending_used == 0)
    ctx->pending_start = ctx->pending;

  ctx->target_size = 0;

  return result;
}

// }}}
//----------------------------------------------------------
// packet_buffer(), packet_update_read() {{{

// return pointer to read buffer and how much data the caller should read
// the caller is expected call packet_update_read() afterwards
static void* packet_buffer(struct packet *ctx, size_t *size)
{
  size_t hlen;
  switch (ctx->packet_mode) {
    case pfx1: hlen = 1; break;
    case pfx2: hlen = 2; break;
    case pfx4: hlen = 4; break;
    default:   hlen = 0; break; // hlen will not be used
  }

  // move data from pending buffer to processing buffer
  if (ctx->pending_used > 0) {
    // XXX: (ctx->pending_used < ctx->target_size), so it fits in the
    // processing buffer, and for line packets the buffer is at least as large
    // as pending buffer for this block plus for what is returned for reading
    if (ctx->packet != NULL) {
      memcpy(ctx->packet->orig_bytes, ctx->pending_start, ctx->pending_used);
      ctx->packet_used = ctx->pending_used;
    } else {
      memcpy(ctx->buffer->orig_bytes, ctx->pending_start, ctx->pending_used);
      ctx->buffer_used = ctx->pending_used;
    }
    ctx->pending_used = 0;
    ctx->pending_start = ctx->pending;
  }

  switch (ctx->packet_mode) {
    case raw:
      if (ctx->target_size > 0)
        *size = ctx->target_size - ctx->buffer_used;
      else
        *size = ctx->buffer->orig_size - ctx->buffer_used;
      return ctx->buffer->orig_bytes + ctx->buffer_used;

    case pfx1:
    case pfx2:
    case pfx4:
      if (ctx->target_size == 0) { // header not read yet
        *size = hlen - ctx->pending_used;
        return ctx->pending_start;
      }
      if (ctx->packet != NULL) { // reading a big packet
        *size = ctx->target_size - ctx->packet_used;
        return ctx->packet->orig_bytes + ctx->packet_used;
      }
      *size = ctx->target_size - ctx->buffer_used;
      return ctx->buffer->orig_bytes + ctx->buffer_used;

    case line:
      // XXX: we don't know how much leftovers there will be, but we need to
      // make sure they will be less than pending buffer;
      // NOTE: remember to keep the ctx->buffer large enough
      *size = sizeof(ctx->pending);
      return ctx->buffer->orig_bytes + ctx->buffer_used;
  }

  // never reached, but the compiler warns
  return NULL;
}

// after read() was called, update the amount of data that was added to the
// buffer
// returns size of a complete packet if the packet is complete, zero if the
// packet is still incomplete, and negative value on error (e.g. out of
// memory)
static int32_t packet_update_read(struct packet *ctx, size_t len)
{
  size_t hlen;
  switch (ctx->packet_mode) {
    case pfx1: hlen = 1; break;
    case pfx2: hlen = 2; break;
    case pfx4: hlen = 4; break;
    default:   hlen = 0; break; // hlen will not be used
  }

  char *eol;

  switch (ctx->packet_mode) {
    case raw:
      ctx->buffer_used += len;
      if (ctx->target_size == 0 || ctx->buffer_used == ctx->target_size) {
        ctx->target_size = ctx->buffer_used;
        return ctx->target_size;
      }
      return PKT_ERR_NOT_READY;

    case pfx1:
    case pfx2:
    case pfx4:
      if (ctx->target_size == 0) { // header not read yet
        ctx->pending_used += len;
        if (ctx->pending_used < hlen)
          return PKT_ERR_NOT_READY;

        if (ctx->packet_mode == pfx1)
          ctx->target_size = (uint8_t)ctx->pending_start[0];
        else if (ctx->packet_mode == pfx2)
          ctx->target_size = unpack16(ctx->pending_start);
        else // (ctx->packet_mode == pfx4)
          ctx->target_size = unpack32(ctx->pending_start);

        ctx->pending_used = 0;
        ctx->pending_start = ctx->pending;

        if (ctx->target_size == 0)
          return 0; // valid and complete packet

        if (packet_alloc_buffer(ctx) < 0)
          return PKT_ERR_ENOMEM;
        return PKT_ERR_NOT_READY;
      }

      if (ctx->packet != NULL) {
        ctx->packet_used += len;
        return (ctx->packet_used == ctx->target_size) ?
                 ctx->target_size : PKT_ERR_NOT_READY;
      }

      ctx->buffer_used += len;
      return (ctx->buffer_used == ctx->target_size) ?
               ctx->target_size : PKT_ERR_NOT_READY;

    case line:
      eol = memchr(ctx->buffer->orig_bytes + ctx->buffer_used, '\n', len);
      ctx->buffer_used += len;

      if (eol != NULL) {
        ctx->target_size = eol - ctx->buffer->orig_bytes + 1;
        // we already have the full message in memory, but let's behave
        // consistently
        if (ctx->target_size > ctx->max_size)
          return PKT_ERR_EMSGSIZE;
        return ctx->target_size; // NOTE: this is >0
      }

      if (ctx->buffer_used > ctx->max_size)
        return PKT_ERR_EMSGSIZE;

      // XXX: make sure the buffer has enough free space to fit the most
      // possible amount of leftovers after finding the newline (see
      // packet_buffer())
      if (ctx->buffer->orig_size - ctx->buffer_used < sizeof(ctx->pending))
        ctx->buffer =
          driver_realloc_binary(ctx->buffer,
                                ctx->buffer->orig_size + sizeof(ctx->pending));
      if (ctx->buffer == NULL)
        return PKT_ERR_ENOMEM;
      return PKT_ERR_NOT_READY;
  }

  // never reached, but the compiler warns
  return PKT_ERR_NEVER_REACHED;
}

// }}}
//----------------------------------------------------------
// packet_get() {{{

static uint32_t packet_get(struct packet *ctx, char **resbuf,
                           ErlDrvBinary **resbin)
{
  uint32_t size = ctx->target_size;

  if (ctx->packet != NULL) {
    *resbuf = NULL;
    *resbin = ctx->packet;
    ctx->packet = NULL;
    ctx->packet_used = 0;
    ctx->target_size = 0;

    return size;
  }

  // ctx->buffer was used

  if (ctx->buffer_used > ctx->target_size) {
    // store the rest in pending buffer
    ctx->pending_start = ctx->pending; // unnecessary, but not harmful
    ctx->pending_used = ctx->buffer_used - ctx->target_size;
    memcpy(ctx->pending, ctx->buffer->orig_bytes + ctx->target_size,
           ctx->pending_used);
  }

  *resbuf = ctx->buffer->orig_bytes;
  *resbin = NULL;
  //ctx->buffer = ...; // leave the processing buffer as is
  ctx->buffer_used = 0;
  ctx->target_size = 0;

  return size;
}

// }}}
//----------------------------------------------------------
// internal helpers

//----------------------------------------------------------
// packet_pending_complete_size() {{{

// determine size of a complete packet from pending buffer including prefix
// headers in pfx[124] modes
// returns PKT_ERR_NOT_READY if pending data doesn't form a complete packet
// returns PKT_ERR_EMSGSIZE when a packet is expected to be larger than
// allowed maximum
static int32_t packet_pending_complete_size(struct packet *ctx)
{
  unsigned char *eol;

  switch (ctx->packet_mode) {
    case raw:
      if (ctx->target_size == 0) {
        // no specific length requested, return whatever we have in pending
        // buffer (up to maximum packet size)
        if (ctx->pending_used == 0)
          return PKT_ERR_NOT_READY;
        ctx->target_size = (ctx->pending_used <= ctx->max_size) ?
                             ctx->pending_used : ctx->max_size;
        return ctx->target_size;
      }
      // NOTE: the user knows what he's doing, we won't check if he requested
      // more than max_size bytes
      return (ctx->pending_used >= ctx->target_size) ?
               ctx->target_size : PKT_ERR_NOT_READY;

    case pfx1:
      if (ctx->pending_used >= 1) {
        ctx->target_size = (uint8_t)ctx->pending_start[0];
        ctx->pending_start += 1;
        ctx->pending_used -= 1;
        if (ctx->target_size > ctx->max_size)
          return PKT_ERR_EMSGSIZE;
        else if (ctx->pending_used < ctx->target_size)
          return PKT_ERR_NOT_READY;
        else
          return ctx->target_size;
      }
      // NOTE: (pending_start == pending), as pending_start is reset when
      // pending_used reaches zero
      return PKT_ERR_NOT_READY;

    case pfx2:
      if (ctx->pending_used >= 2) {
        ctx->target_size = unpack16(ctx->pending_start);
        ctx->pending_start += 2;
        ctx->pending_used -= 2;
        if (ctx->target_size > ctx->max_size)
          return PKT_ERR_EMSGSIZE;
        else if (ctx->pending_used < ctx->target_size)
          return PKT_ERR_NOT_READY;
        else
          return ctx->target_size;
      } else if (ctx->pending_start != ctx->pending) {
        // make sure there's space for reading rest of the header
        memmove(ctx->pending, ctx->pending_start, ctx->pending_used);
        ctx->pending_start = ctx->pending;
      }
      return PKT_ERR_NOT_READY;

    case pfx4:
      if (ctx->pending_used >= 4) {
        ctx->target_size = unpack32(ctx->pending_start);
        ctx->pending_start += 4;
        ctx->pending_used -= 4;
        if (ctx->target_size > ctx->max_size)
          return PKT_ERR_EMSGSIZE;
        else if (ctx->pending_used < ctx->target_size)
          return PKT_ERR_NOT_READY;
        else
          return ctx->target_size;
      } else if (ctx->pending_start != ctx->pending) {
        // make sure there's space for reading rest of the header
        memmove(ctx->pending, ctx->pending_start, ctx->pending_used);
        ctx->pending_start = ctx->pending;
      }
      return PKT_ERR_NOT_READY;

    case line:
      if (ctx->pending_used > 0 &&
          (eol = memchr(ctx->pending_start, '\n', ctx->pending_used)) != NULL) {
        ctx->target_size = eol - ctx->pending_start + 1;
        if (ctx->target_size > ctx->max_size)
          // the user must want quite short lines for this to happen, but
          // let's respect that wish
          return PKT_ERR_EMSGSIZE;
        return ctx->target_size; // NOTE: this is >0
      }
      return PKT_ERR_NOT_READY;
  }

  // never reached, but the compiler warns
  return PKT_ERR_NEVER_REACHED;
}

// }}}
//----------------------------------------------------------
// packet_alloc_buffer() {{{

// returns 0 on success, PKT_ERR_ENOMEM on out of memory
static int32_t packet_alloc_buffer(struct packet *ctx)
{
  if ((ctx->packet_mode == pfx1 || ctx->packet_mode == pfx2 ||
       ctx->packet_mode == pfx4) && ctx->target_size == 0) {
    // we don't know the size of the buffer yet (the full header hasn't been
    // read yet), so postpone this operation
    return 0;
  }

  ctx->buffer_used = 0;
  ctx->packet_used = 0;

  // ctx->packet will be used instead of ctx->buffer
  if (ctx->use_packet && ctx->target_size >= BIG_PACKET_SIZE) {
    // XXX: at this point (ctx->packet == NULL)
    ctx->packet = driver_alloc_binary(ctx->target_size);

    return (ctx->packet != NULL) ? 0 : PKT_ERR_ENOMEM;
  }

  size_t buffer_size = ctx->target_size; // 0 for most of the modes

  if (ctx->packet_mode == line)
    // XXX: line packet mode needs processing buffer big enough to hold
    // whatever there is currently in pending buffer plus a size of pending
    // buffer (see packet_buffer())
    buffer_size = 2 * sizeof(ctx->pending);

  // always allocate at least DEFAULT_BUFFER_SIZE for ctx->buffer
  if (buffer_size < DEFAULT_BUFFER_SIZE)
    buffer_size = DEFAULT_BUFFER_SIZE;

  if (ctx->buffer == NULL) {
    ctx->buffer = driver_alloc_binary(buffer_size);
  } else if (ctx->buffer->orig_size < buffer_size) {
    driver_free_binary(ctx->buffer);
    ctx->buffer = driver_alloc_binary(buffer_size);
  }
  return (ctx->buffer != NULL) ? 0 : PKT_ERR_ENOMEM;
}

// }}}
//----------------------------------------------------------

// }}}
//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker:nowrap
