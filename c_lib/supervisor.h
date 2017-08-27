#ifndef __SUPERVISOR_H
#define __SUPERVISOR_H

#include <sys/types.h>

int supervisor_spawn(pid_t *sup_pid, int *sup_fd);
int supervisor_terminate(pid_t sup_pid, int sup_fd);

int supervisor_send_command(int sup_fd, void *data, size_t size);
int supervisor_read_event(int sup_fd, void *data, size_t *size,
                          int *received_fds, size_t *fd_count);

#endif // __SUPERVISOR_H
