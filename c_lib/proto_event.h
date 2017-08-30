#ifndef __PROTO_EVENT_H
#define __PROTO_EVENT_H

#include <stdint.h>
#include <sys/types.h>

#define STDIO_MODE_BIDIR  0
#define STDIO_MODE_IN     1
#define STDIO_MODE_OUT    2
#define STDIO_MODE_IN_OUT 3

#define STAGE_FORK        0
#define STAGE_SETPRIORITY 1
#define STAGE_SETGID      2
#define STAGE_SETUID      3
#define STAGE_CHDIR       4
#define STAGE_EXEC        5

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
