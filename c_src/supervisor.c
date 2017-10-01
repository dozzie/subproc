//----------------------------------------------------------------------------

#include <string.h>
#include <stdio.h> // snprintf()

#include <unistd.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>

#include "supervisor.h"

//----------------------------------------------------------------------------

static
ssize_t recvall(int fd, void *buffer, size_t size, int flags);

//----------------------------------------------------------------------------
// public functions
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// start and stop supervisor process {{{

int supervisor_spawn(struct sup_h *sup, char *exe_path)
{
  pid_t pid;
  int comm[2];
  int events[2];
  int devnullr;
  int devnullw;
  if ((devnullr = open("/dev/null", O_RDONLY)) < 0)
    return -1;
  if ((devnullw = open("/dev/null", O_WRONLY)) < 0)
    return -1;

  sup->pid = -1;
  sup->comm = -1;
  sup->events = -1;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, comm) < 0) {
    int save_errno = errno;
    close(devnullr);
    close(devnullw);
    errno = save_errno;
    return -1;
  }

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, events) < 0) {
    int save_errno = errno;
    close(devnullr);
    close(devnullw);
    close(comm[0]);
    close(comm[1]);
    errno = save_errno;
    return -1;
  }

  if ((pid = fork()) < 0) {
    int save_errno = errno;
    close(devnullr);
    close(devnullw);
    close(comm[0]);
    close(comm[1]);
    close(events[0]);
    close(events[1]);
    errno = save_errno;
    return -1;
  }

  if (pid == 0) {
    dup2(devnullr, 0);
    dup2(devnullw, 1);
    // STDERR stays as it was

    close(devnullr);
    close(devnullw);
    close(comm[1]);
    close(events[1]);

    // NOTE: comm[0] needs to stay bidirectional
    shutdown(events[0], SHUT_RD);

    char fd_comm[32];
    char fd_events[32];
    snprintf(fd_comm, sizeof(fd_comm), "%d", comm[0]);
    snprintf(fd_events, sizeof(fd_events), "%d", events[0]);

    char *exe_name = strrchr(exe_path, '/');
    if (exe_name != NULL)
      ++exe_name;
    else
      exe_name = exe_path;

    execl(exe_path, exe_name, fd_comm, fd_events, NULL);
    _exit(255);
  }

  close(devnullr);
  close(devnullw);
  close(comm[0]);
  close(events[0]);
  shutdown(events[1], SHUT_WR);
  sup->pid = pid;
  sup->comm = comm[1];
  sup->events = events[1];

  return 0;
}

// }}}
//----------------------------------------------------------------------------
// send/receive messages {{{

int supervisor_send_command(struct sup_h *sup, void *data, size_t size,
                            void *reply)
{
  // NOTE: reply buffer should be ACK_MESSAGE_SIZE bytes large
  int result = send(sup->comm, data, size, MSG_NOSIGNAL);
  if (result < 0)
    return result;
  return recvall(sup->comm, reply, ACK_MESSAGE_SIZE, 0);
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
// helpers
//----------------------------------------------------------------------------

static
ssize_t recvall(int fd, void *buffer, size_t size, int flags)
{
  uint8_t *wbuf = buffer;
  size_t to_fill = size;
  ssize_t received;
  do {
    received = recv(fd, wbuf + (size - to_fill), to_fill, flags | MSG_WAITALL);
  } while ((received > 0 && (to_fill -= received) > 0) ||
           (received < 0 && errno == EINTR));

  return (received >= 0) ? size - to_fill : -1;
}

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
