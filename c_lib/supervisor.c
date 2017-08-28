//----------------------------------------------------------------------------

#include <stdio.h>
#include <string.h>

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
  return send(sup->comm, data, size, MSG_NOSIGNAL);
}

int supervisor_read_event(struct sup_h *sup, void *data, size_t *size,
                          int *received_fds, size_t *fd_count)
{
  // NOTE: write to `size' the actual number of data read
  // NOTE: write to `fd_count' the actual number of descriptors received
  // result:
  //   -1 -- error
  //    0 -- nothing to read
  //   >0 -- got some messages, `*size' and `*fd_count' updated

  struct msghdr message;
  memset(&message, 0, sizeof(message));

  struct iovec msgvec = { .iov_base = data, .iov_len = *size };
  message.msg_iov = &msgvec;
  message.msg_iovlen = 1;

  char fd_buffer[CMSG_SPACE(*fd_count * sizeof(int))];
  memset(fd_buffer, 0, sizeof(fd_buffer));
  message.msg_control = fd_buffer;
  message.msg_controllen = sizeof(fd_buffer);

  ssize_t result = recvmsg(sup->events, &message, MSG_DONTWAIT);
  if (result < 0) {
    *size = 0;
    *fd_count = 0;
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
  }
  // result > 0
  *size = result;

  struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
  while (cmsg != NULL &&
         !(cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS)) {
    cmsg = CMSG_NXTHDR(&message, cmsg);
  }
  if (cmsg == NULL) {
    *fd_count = 0;
    return 1;
  }

  size_t fd_copy_count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
  int *fds = (int *)CMSG_DATA(cmsg); // let's trust this is aligned properly
  size_t i;
  for (i = 0; i < fd_copy_count; ++i) {
    if (i < *fd_count)
      received_fds[i] = fds[i];
    else
      close(fds[i]);
  }
  if (fd_copy_count < *fd_count)
    *fd_count = fd_copy_count;

  return 1;
}

// }}}
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// main loop of the supervisor

int supervisor_send_event(int fd, void *data, size_t size,
                          int *fds, size_t numfd)
{
  if (fds == NULL && numfd > 0) {
    errno = EINVAL;
    return -1;
  }

  struct msghdr message;
  memset(&message, 0, sizeof(message));

  struct iovec msgvec = { .iov_base = data, .iov_len = size };
  message.msg_iov = &msgvec;
  message.msg_iovlen = 1;

  char fdbuf[CMSG_SPACE(sizeof(int) * numfd)];
  message.msg_control = fdbuf;
  message.msg_controllen = sizeof(fdbuf);

  struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int) * numfd);
  memcpy(CMSG_DATA(cmsg), fds, sizeof(int) * numfd);
  message.msg_controllen = cmsg->cmsg_len;

  return sendmsg(fd, &message, MSG_NOSIGNAL);
}

#include <sys/stat.h>
#include <fcntl.h>

void supervisor_loop(int fd_comm, int fd_events)
{
  // TODO: replace this stub

  char buffer[4096];
  ssize_t bufsize;
  while ((bufsize = read(fd_comm, buffer, sizeof(buffer))) > 0) {
    fprintf(stderr, "<%d> some data read\n", getpid());
    if (buffer[0] == 'o' && buffer[1] != 0) {
      if (bufsize == sizeof(buffer))
        buffer[bufsize - 1] = 0;
      else
        buffer[bufsize] = 0;

      int fd = open(buffer + 1, O_RDONLY);
      if (fd < 0) {
        supervisor_send_event(fd_events, "open failed", 11, NULL, 0);
      } else {
        supervisor_send_event(fd_events, "open ok", 7, &fd, 1);
        close(fd);
      }
    } else {
      supervisor_send_event(fd_events, "qwertyuiop", 10, NULL, 0);
    }
  }

  fprintf(stderr, "<%d> EOF, child supervisor terminates\n", getpid());
}

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
