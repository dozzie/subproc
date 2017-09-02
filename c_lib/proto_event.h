#ifndef __PROTO_EVENT_H
#define __PROTO_EVENT_H

#include <stdint.h>
#include <sys/types.h>

#define STDIO_MODE_BIDIR  0 // one FD, for both reading and writing
#define STDIO_MODE_IN     1 // one FD, for parent to write to
#define STDIO_MODE_OUT    2 // one FD, for parent to read from
#define STDIO_MODE_IN_OUT 3 // two FDs, for parent to 0: write to, 1: read from

#define STAGE_CONFIRM_CHAN    0
#define STAGE_PIPE_IN         1
#define STAGE_PIPE_OUT        2
#define STAGE_SOCKETPAIR_IN   3
#define STAGE_SOCKETPAIR_OUT  4
#define STAGE_FORK            5
#define STAGE_SETPRIORITY     6
#define STAGE_SETGID          7
#define STAGE_SETUID          8
#define STAGE_CHDIR           9
#define STAGE_EXEC           10

struct event_t {
  enum { event_spawn, event_spawn_error, event_exit, event_signal } type;
  uint64_t id;

  union {
    struct {
      pid_t pid;
      int stdio_mode; // STDIO_MODE_*
    } spawn;
    struct {
      int stage; // STAGE_*
      int error;
    } error;
    int exit_code;
    int signal;
  };
};

// <spawn:  0x73> <mode:8>  <id:64> <pid:32> + file descriptors
// <error:  0x65> <stage:8> <id:64> <errno:32>
// <exit:   0x78> <zero:8>  <id:64> <code:32>
// <signal: 0x6b> <zero:8>  <id:64> <signal:32>
#define EVENT_MESSAGE_SIZE 14

// buffer should be EVENT_MESSAGE_SIZE bytes large
int parse_event(void *buffer, struct event_t *event);
void build_event(void *buffer, struct event_t *event);

#endif // __PROTO_EVENT_H
