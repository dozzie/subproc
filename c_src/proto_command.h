#ifndef __PROTO_COMMAND_H
#define __PROTO_COMMAND_H

#include <stdint.h>
#include <sys/types.h>

#define ERR_UNDEFINED     -128  // a situation that should never happen (development error)
#define ERR_CHILD_SPACE   -127  // can't register more children
#define ERR_REQ_TOO_BIG   -126  // request was too big
#define ERR_PARSE           -1  // general request parse error
#define ERR_BAD_REQ_HEADER  -2  // invalid request packet header
#define ERR_BAD_SIGNAL      -3  // invalid signal number
#define ERR_BAD_STDIO       -4  // bidirectional STDIO requested for pipe
#define ERR_NX_USER         -5  // no such user
#define ERR_NX_GROUP        -6  // no such group
#define ERR_BAD_OPTION      -7  // unrecognized exec option tag
#define ERR_NX_CHILD        -8  // no such child process

struct comm_t {
  enum { comm_exec, comm_kill, comm_shutdown_opts, comm_shutdown } type;
  union {
    struct {
      char *command;
      char **argv;
      char *cwd;
      char **env;
      unsigned int termsig;
      uint64_t sigmask; // ignored signals
      // modes:
      //   bidirectional -- one descriptor for both reading and writing
      //   in     -- one descriptor, for parent to write to
      //   out    -- one descriptor, for parent to read from
      //   in_out -- two descriptors, for parent to 0: write to, 1: read from
      enum { bidirectional, in, out, in_out } stdio_mode;
      uint8_t stdio_socket;
      uint8_t stderr_to_stdout;
      uint8_t use_pgroup;
      uint8_t term_pgroup; // if group leader terminates, send termsig to whole group
      uint8_t use_uid;
      uint8_t use_gid;
      uint8_t use_priority;
      // options that have no null value on their own
      uid_t uid;
      gid_t gid;
      int priority; // niceness
    } exec_opts;

    struct {
      uint64_t id;
      unsigned int signal;
    } kill;
    struct {
      // time to wait for children to exit after sending them their signals on
      // shutdown
      uint32_t timeout;
      // whether to send SIGKILL on shutdown timeout
      uint8_t send_kill;
    } shutdown_opts;
  };
};

int parse_command(void *data, size_t size, struct comm_t *comm);
void free_command(struct comm_t *comm);

// <ok:     0x01 0x00> <id:64>
// <reqerr: 0x02 0x01> <error:8>  <zero:56> // ERR_*
// <oserr:  0x02 0x02> <errno:32> <zero:32>
#ifndef ACK_MESSAGE_SIZE
#  define ACK_MESSAGE_SIZE 10
#endif

// buffer should be ACK_MESSAGE_SIZE bytes large
void build_ack(void *buffer, uint64_t id);
void build_nack_req(void *buffer, int8_t error);
void build_nack_os(void *buffer, int error);

#endif // __PROTO_COMMAND_H
