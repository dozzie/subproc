#ifndef __PROTOCOL_H
#define __PROTOCOL_H

#include <stdint.h>
#include <sys/types.h>

struct comm_t {
  enum { comm_exec, comm_kill, comm_shutdown } type;
  union {
    struct {
      char *command;
      char **argv;
      char *cwd;
      // TODO: struct { char *name; char *value } *env_set;
      // TODO: char **env_clear;
      unsigned int termsig;
      enum { bidirectional, in, out, in_out } stdio_mode;
      uint8_t stdio_socket;
      uint8_t stderr_to_stdout;
      uint8_t use_pgroup;
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
  };
};

int parse_command(void *data, size_t size, struct comm_t *comm);
void free_command(struct comm_t *comm);

#endif // __PROTOCOL_H
