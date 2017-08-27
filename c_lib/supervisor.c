//----------------------------------------------------------------------------

#include <stdio.h>

#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <errno.h>

#include "supervisor.h"

//----------------------------------------------------------------------------

void supervisor_loop(int fd);

//----------------------------------------------------------------------------
// public functions
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// start and stop supervisor process {{{

int supervisor_spawn(pid_t *sup_pid, int *sup_fd)
{
  int fds[2];
  pid_t pid;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0)
    return -1;

  if ((pid = fork()) < 0) {
    close(fds[0]);
    close(fds[1]);
    return -1;
  }

  if (pid == 0) {
    close(fds[1]);
    supervisor_loop(fds[0]);
    _exit(0);
  }

  close(fds[0]);
  *sup_pid = pid;
  *sup_fd = fds[1];
  return 0;
}

int supervisor_terminate(pid_t sup_pid, int sup_fd)
{
  // TODO: make this a message, maybe with an ACK event
  close(sup_fd);

  int status;
  waitpid(sup_pid, &status, 0);
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  } else { // WIFSIGNALED(status)
    return -WTERMSIG(status);
  }
}

// }}}
//----------------------------------------------------------------------------
// send/receive messages {{{

int supervisor_send_command(int sup_fd, void *data, size_t size)
{
  // TODO: fill me
  errno = ENOSYS;
  return -1;
}

int supervisor_read_event(int sup_fd, void *data, size_t *size,
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

void supervisor_loop(int fd)
{
  // TODO: replace this stub

  char buffer[4096];
  while (read(fd, buffer, sizeof(buffer)) > 0) {
    fprintf(stderr, "<%d> some data read\n", getpid());
  }

  fprintf(stderr, "<%d> EOF, child supervisor terminates\n", getpid());
}

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
