#ifndef __SUPERVISOR_H
#define __SUPERVISOR_H

#include <sys/types.h>

struct sup_h {
  pid_t pid;
  int comm;
  int events;
};

int supervisor_spawn(struct sup_h *sup);
int supervisor_terminate(struct sup_h *sup);

int supervisor_send_command(struct sup_h *sup, void *data, size_t size);
int supervisor_read_event(struct sup_h *sup, void *data, size_t *size,
                          int *received_fds, size_t *fd_count);

#endif // __SUPERVISOR_H
