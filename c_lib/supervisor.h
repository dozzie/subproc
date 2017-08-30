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

#ifndef ACK_MESSAGE_SIZE
#  define ACK_MESSAGE_SIZE 10
#endif

// reply buffer should be ACK_MESSAGE_SIZE bytes large
int supervisor_send_command(struct sup_h *sup, void *data, size_t size,
                            void *reply);
// event is of fixed size and up to two file descriptors
// see also `proto_event.h'
int supervisor_read_event(struct sup_h *sup, void *data, size_t *size,
                          int *received_fds, size_t *fd_count);

#endif // __SUPERVISOR_H
