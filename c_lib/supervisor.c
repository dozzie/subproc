//----------------------------------------------------------------------------

#include <stdio.h>

#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <errno.h>

#include "supervisor.h"

//----------------------------------------------------------------------------

void supervisor_loop(int fd_comm, int fd_events);

//----------------------------------------------------------------------------
// public functions
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// start and stop supervisor process {{{

int supervisor_spawn(struct sup_h *sup)
{
  pid_t pid;
  int comm[2];
  int events[2];

  sup->pid = -1;
  sup->comm = -1;
  sup->events = -1;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, comm) < 0)
    return -1;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, events) < 0) {
    close(comm[0]);
    close(comm[1]);
    return -1;
  }

  if ((pid = fork()) < 0) {
    close(comm[0]);
    close(comm[1]);
    close(events[0]);
    close(events[1]);
    return -1;
  }

  if (pid == 0) {
    close(comm[1]);
    close(events[1]);
    shutdown(events[0], SHUT_RD);
    supervisor_loop(comm[0], events[0]);
    _exit(0);
  }

  close(comm[0]);
  close(events[0]);
  shutdown(events[1], SHUT_WR);
  sup->pid = pid;
  sup->comm = comm[1];
  sup->events = events[1];

  return 0;
}

int supervisor_terminate(struct sup_h *sup)
{
  if (sup->pid <= 0)
    return 0; // TODO: signal this somehow?

  // TODO: make this a message, maybe with an ACK event
  close(sup->comm);
  close(sup->events);

  int status;
  waitpid(sup->pid, &status, 0);
  sup->pid = -1;
  sup->comm = -1;
  sup->events = -1;

  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  } else { // WIFSIGNALED(status)
    return -WTERMSIG(status);
  }
}

// }}}
//----------------------------------------------------------------------------
// send/receive messages {{{

int supervisor_send_command(struct sup_h *sup, void *data, size_t size)
{
  // TODO: fill me
  errno = ENOSYS;
  return -1;
}

int supervisor_read_event(struct sup_h *sup, void *data, size_t *size,
                          int *received_fds, size_t *fd_count)
{
  // TODO: fill me
  // NOTE: write to `size' the actual number of data read
  // NOTE: write to `fd_count' the actual number of descriptors received
  // result:
  //   -1 -- error
  //    0 -- nothing to read
  //   >0 -- got some messages, `*size' and `*fd_count' updated
  errno = ENOSYS;
  return -1;
}

// }}}
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// main loop of the supervisor

void supervisor_loop(int fd_comm, int fd_events)
{
  // TODO: replace this stub

  char buffer[4096];
  while (read(fd_comm, buffer, sizeof(buffer)) > 0) {
    fprintf(stderr, "<%d> some data read\n", getpid());
  }

  fprintf(stderr, "<%d> EOF, child supervisor terminates\n", getpid());
}

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
