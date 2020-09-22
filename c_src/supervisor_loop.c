//----------------------------------------------------------------------------

#include <string.h>
#include <stdio.h> // snprintf()
#include <stdlib.h>

#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <signal.h>
#include <errno.h>
#include <poll.h>
#include <fcntl.h>
#include <time.h>

#include "supervisor_loop.h"
#include "proto_command.h"
#include "proto_event.h"
#include "int_pack.h"

//----------------------------------------------------------------------------

// milliseconds
#define LOOP_INTERVAL 100
// milliseconds
#define SHUTDOWN_REAP_INTERVAL 10

static
void set_close_on_exec(int fd);

static
ssize_t recvall(int fd, void *buffer, size_t size, int flags);
static
void recvdiscard(int fd, size_t size);

//----------------------------------------------------------------------------
// public functions
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// supervisor internals
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// receive commands, send events {{{

static
ssize_t supervisor_read_command(int fd, void *buffer, size_t size)
{
  unsigned char sizebuf[4];
  int result = recvall(fd, &sizebuf, sizeof(sizebuf), 0);
  if (result != sizeof(sizebuf)) {
    if (result >= 0)
      errno = EIO; // incomplete read means unexpected EOF
    return -1;
  }
  size_t msgsize = unpack32(sizebuf);
  if (size < msgsize) {
    recvdiscard(fd, msgsize);
    errno = EMSGSIZE;
    return -1;
  }
  result = recvall(fd, buffer, msgsize, 0);
  if (result != msgsize) {
    if (result >= 0)
      errno = EIO; // incomplete read means unexpected EOF
    return -1;
  }
  return msgsize;
}

static
ssize_t supervisor_send_event(int fd, void *data, size_t size,
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

//----------------------------------------------------------
// recv*() helpers {{{

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

static
void recvdiscard(int fd, size_t size)
{
  char buf[4096];
  ssize_t received;
  do {
    received = recv(fd, buf, (size > sizeof(buf)) ? sizeof(buf) : size, 0);
  } while ((received > 0 && (size -= received) > 0) ||
           (received < 0 && errno == EINTR));
}

// }}}
//----------------------------------------------------------

// }}}
//----------------------------------------------------------------------------
// child process list {{{

#define MAX_CHILDREN (16 * 1024)

typedef struct {
  uint64_t id;
  pid_t pid;
  int termsig;
  uint8_t pgroup;
  uint8_t term_killpg; // send `termsig' signal on leader's termination
} child_t;

struct children_t {
  uint64_t last_id;
  child_t *last_child;
  child_t children[MAX_CHILDREN];
};

// returns record for a new child process, NULL on no free space
static
child_t* child_add(struct children_t *children)
{
  if (children->last_child == NULL)
    // take first
    children->last_child = children->children;
  else if ((children->last_child - children->children) + 1 == MAX_CHILDREN)
    // container is full
    return NULL;
  else
    // take next
    ++children->last_child;

  children->last_child->id = ++children->last_id;

  return children->last_child;
}

// returns child's position, NULL on not found
static
child_t* child_find_id(struct children_t *children, uint64_t id)
{
  if (children->last_child == NULL)
    return NULL;

  child_t *child;
  for (child = children->children; child <= children->last_child; ++child)
    if (child->id == id)
      return child;

  return NULL;
}

// returns child's position, NULL on not found
static
child_t* child_find_pid(struct children_t *children, pid_t pid)
{
  if (children->last_child == NULL)
    return NULL;

  child_t *child;
  for (child = children->children; child <= children->last_child; ++child)
    if (child->pid == pid)
      return child;

  return NULL;
}

static
void child_remove(struct children_t *children, child_t *child)
{
  if (children->last_child == NULL)
    // should never happen, but who knows?
    return;

  if (child == children->last_child) {
    memset(child, 0, sizeof(child_t));
  } else {
    memcpy(child, children->last_child, sizeof(child_t));
    memset(children->last_child, 0, sizeof(child_t));
  }

  if (children->last_child == children->children)
    children->last_child = NULL;
  else
    --children->last_child;
}

// }}}
//----------------------------------------------------------------------------
// millisecond sleep {{{

struct millisleep_t {
  uint32_t timeout;
  int infinity;
};

static
uint32_t millisleep(struct millisleep_t *total, unsigned int chunk)
{
  if (!total->infinity && total->timeout < chunk)
    chunk = total->timeout;

  struct timespec to_sleep = {
    .tv_sec = chunk / 1000,
    .tv_nsec = (chunk % 1000) * 1000 * 1000
  };
  struct timespec not_slept;

  if (total->infinity) {
    nanosleep(&to_sleep, NULL);
    return chunk;
  }

  if (total->timeout == 0)
    return 0;

  if (nanosleep(&to_sleep, &not_slept) == 0)
    total->timeout -= chunk;
  else
    total->timeout -= chunk - not_slept.tv_sec * 1000 +
                              not_slept.tv_nsec / (1000 * 1000);
  return total->timeout;
}

// }}}
//----------------------------------------------------------------------------
// signal handlers {{{

static int term_signal_received;

static
void term_signal_handler(int signum)
{
  term_signal_received = 1;
}

static
void set_signal_handler(int signum)
{
  struct sigaction handler;
  memset(&handler, 0, sizeof(handler));
  handler.sa_handler = term_signal_handler;
  sigaction(signum, &handler, NULL);
}

// }}}
//----------------------------------------------------------------------------
// main loop

// `buffer' should be EVENT_MESSAGE_SIZE bytes large
static
pid_t child_next_event(struct children_t *children, void *buffer);
// `fds' should be big enough for up to two ints
// `buffer' should be EVENT_MESSAGE_SIZE bytes large
// returns number of created FDs, or 0 on failure
static
int child_spawn(struct comm_t *cmd, child_t *child, void *buffer, int *fds);
static
int child_kill(child_t *child, int signal);

void supervisor_loop(int fd_comm, int fd_events)
{
  // administrative data
  unsigned char cmdbuf[16 * 1024 + sysconf(_SC_ARG_MAX)];
  struct pollfd pollcomm = {
    .fd = fd_comm,
    .events = POLLIN
  };

  set_close_on_exec(fd_comm);
  set_close_on_exec(fd_events);

  term_signal_received = 0;
  set_signal_handler(SIGHUP);
  set_signal_handler(SIGINT);
  set_signal_handler(SIGTERM);

  // options
  uint32_t shutdown_timeout = 0;
  int shutdown_send_sigkill = 0;

  // children registry
  struct children_t children;
  memset(&children, 0, sizeof(children));

  while (!term_signal_received) {
    int ready = poll(&pollcomm, 1, LOOP_INTERVAL);

    char evbuf[EVENT_MESSAGE_SIZE];
    while (child_next_event(&children, evbuf) > 0) {
      // TODO: handle send errors
      supervisor_send_event(fd_events, evbuf, sizeof(evbuf), NULL, 0);
    }

    if (ready <= 0)
      continue;
    // XXX: only one descriptor (fd_comm) could make this loop enter here

    ssize_t r = supervisor_read_command(fd_comm, cmdbuf, sizeof(cmdbuf));
    if (r < 0 && errno == EMSGSIZE) {
      char reply[ACK_MESSAGE_SIZE];
      build_nack_req(reply, ERR_REQ_TOO_BIG);
      send(fd_comm, reply, sizeof(reply), MSG_NOSIGNAL); // ignore send errors
      continue;
    }
    if (r <= 0)
      // read error or EOF
      break;

    struct comm_t cmd;
    memset(&cmd, 0, sizeof(cmd));
    char reply[ACK_MESSAGE_SIZE];
    int error;

    if ((error = parse_command(cmdbuf, r, &cmd)) != 0) {
      build_nack_req(reply, error);
      send(fd_comm, reply, sizeof(reply), MSG_NOSIGNAL); // ignore send errors
      continue;
    }

    if (cmd.type == comm_exec) {
      child_t *child = child_add(&children);

      if (child == NULL) {
        build_nack_req(reply, ERR_CHILD_SPACE);
        send(fd_comm, reply, sizeof(reply), MSG_NOSIGNAL); // ignore send errors
        free_command(&cmd); // XXX: this is important here
        continue;
      }

      // NOTE: send an ACK immediately
      build_ack(reply, child->id);
      send(fd_comm, reply, sizeof(reply), MSG_NOSIGNAL);

      int fds[2];
      int nfds = child_spawn(&cmd, child, evbuf, fds);
      supervisor_send_event(fd_events, evbuf, sizeof(evbuf), fds, nfds);

      if (nfds > 0) {
        // on success, close descriptors in this process
        while (nfds > 0)
          close(fds[--nfds]);
      } else {
        // on failure, remove the child record from registry
        child_remove(&children, child);
      }

      free_command(&cmd); // XXX: this is important here
    } else if (cmd.type == comm_kill) {
      child_t *child = child_find_id(&children, cmd.kill.id);

      if (child == NULL) {
        build_nack_req(reply, ERR_NX_CHILD);
      } else {
        if (child_kill(child, cmd.kill.signal) == 0)
          build_ack(reply, 0);
        else
          build_nack_os(reply, errno);
      }

      // NOTE: we don't wait here for child to terminate (especially that it
      // could have been a "reload config" signal)

      send(fd_comm, reply, sizeof(reply), MSG_NOSIGNAL);
      free_command(&cmd);
    } else if (cmd.type == comm_shutdown_opts) {
      shutdown_timeout = cmd.shutdown_opts.timeout;
      shutdown_send_sigkill = cmd.shutdown_opts.send_kill;
      build_ack(reply, 0);
      send(fd_comm, reply, sizeof(reply), MSG_NOSIGNAL);
      free_command(&cmd);
    } else { // cmd.type == comm_shutdown
      build_ack(reply, 0);
      send(fd_comm, reply, sizeof(reply), MSG_NOSIGNAL);
      free_command(&cmd);
      break;
    }
  }

  char evbuf[EVENT_MESSAGE_SIZE];
  struct event_t shutdown_event = { .type = event_shutdown, .id = 0 };

  if (children.last_child == NULL) {
    shutdown_event.shutdown.alive_children = 0;
    build_event(evbuf, &shutdown_event);
    supervisor_send_event(fd_events, evbuf, sizeof(evbuf), NULL, 0);
    return;
  }

  child_t *c;
  for (c = children.children; c <= children.last_child; ++c)
    child_kill(c, 0);

  struct millisleep_t sleep = {
    .timeout = shutdown_timeout,
    .infinity = (shutdown_timeout == 0)
  };

  while (children.last_child != NULL &&
         millisleep(&sleep, SHUTDOWN_REAP_INTERVAL) > 0) {
    while (child_next_event(&children, evbuf) > 0) {
      // NOTE: ignore send errors
      supervisor_send_event(fd_events, evbuf, sizeof(evbuf), NULL, 0);
    }
  }

  if (shutdown_send_sigkill && children.last_child != NULL) {
    // send SIGKILL to all the children that are still alive
    for (c = children.children; c <= children.last_child; ++c)
      child_kill(c, SIGKILL);

    // reset the timeout and wait again (don't wait infinitely, because some
    // child processes can be stuck in an uninterruptible sleep)
    sleep.timeout = shutdown_timeout;
    while (children.last_child != NULL &&
           millisleep(&sleep, SHUTDOWN_REAP_INTERVAL) > 0) {
      while (child_next_event(&children, evbuf) > 0) {
        // NOTE: ignore send errors
        supervisor_send_event(fd_events, evbuf, sizeof(evbuf), NULL, 0);
      }
    }
  }

  shutdown_event.shutdown.alive_children =
    (children.last_child != NULL) ?
    children.last_child - children.children + 1 :
    0;
  build_event(evbuf, &shutdown_event);
  supervisor_send_event(fd_events, evbuf, sizeof(evbuf), NULL, 0);
}

//----------------------------------------------------------
// spawn a child process {{{

#define READ_END  0
#define WRITE_END 1

static
int create_pipe(int *fds, int socket)
{
  if (!socket)
    return pipe(fds);

  int result = socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
  if (result == 0) {
    shutdown(fds[READ_END], SHUT_WR);
    shutdown(fds[WRITE_END], SHUT_RD);
  }
  return result;
}

static
int child_spawn(struct comm_t *cmd, child_t *child, void *buffer, int *fds)
{
  int fds_confirm[2] = { -1, -1 }; // FD pair for exec() confirmation
  int fds_stdin[2]   = { -1, -1 }; // FD pair for child's STDIN
  int fds_stdout[2]  = { -1, -1 }; // FD pair for child's STDOUT
  struct event_t event;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds_confirm) < 0) {
    event.type = event_spawn_error;
    event.id = child->id;
    event.error.stage = STAGE_CONFIRM_CHAN;
    event.error.error = errno;
    build_event(buffer, &event);
    return 0;
  }
  set_close_on_exec(fds_confirm[WRITE_END]);

  if (cmd->exec_opts.stdio_mode == bidirectional) { // socketpair
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds_stdin) < 0) {
      event.type = event_spawn_error;
      event.id = child->id;
      event.error.stage = STAGE_SOCKETPAIR_IN;
      event.error.error = errno;
      build_event(buffer, &event);
      return 0;
    }
    //fds_stdout[READ_END] = fds_stdin[WRITE_END];
    //fds_stdout[WRITE_END] = fds_stdin[READ_END];
  }

  if (cmd->exec_opts.stdio_mode == in || cmd->exec_opts.stdio_mode == in_out) {
    if (create_pipe(fds_stdin, cmd->exec_opts.stdio_socket) < 0) {
      event.type = event_spawn_error;
      event.id = child->id;
      event.error.stage = cmd->exec_opts.stdio_socket ?
                            STAGE_SOCKETPAIR_IN :
                            STAGE_PIPE_IN;
      event.error.error = errno;
      build_event(buffer, &event);
      return 0;
    }
  }

  if (cmd->exec_opts.stdio_mode == out || cmd->exec_opts.stdio_mode == in_out) {
    if (create_pipe(fds_stdout, cmd->exec_opts.stdio_socket) < 0) {
      event.type = event_spawn_error;
      event.id = child->id;
      event.error.stage = cmd->exec_opts.stdio_socket ?
                            STAGE_SOCKETPAIR_OUT :
                            STAGE_PIPE_OUT;
      event.error.error = errno;
      build_event(buffer, &event);
      return 0;
    }
  }

  pid_t pid = fork();

  if (pid < 0) {
    event.type = event_spawn_error;
    event.id = child->id;
    event.error.stage = STAGE_FORK;
    event.error.error = errno;
    build_event(buffer, &event);

    close(fds_confirm[READ_END]);
    close(fds_confirm[WRITE_END]);
    if (fds_stdin[READ_END] >= 0) {
      close(fds_stdin[READ_END]);
      close(fds_stdin[WRITE_END]);
    }
    if (fds_stdout[READ_END] >= 0) {
      close(fds_stdout[READ_END]);
      close(fds_stdout[WRITE_END]);
    }
    return 0;
  }

  if (pid > 0) {
    // parent
    close(fds_confirm[WRITE_END]);
    if (fds_stdin[READ_END] >= 0)
      close(fds_stdin[READ_END]);
    if (fds_stdout[WRITE_END] >= 0)
      close(fds_stdout[WRITE_END]);

    int confirm[2]; // stage, errno
    if (recvall(fds_confirm[READ_END], confirm, sizeof(confirm), 0) > 0) {
      // when a problem is encountered, the child process will send both the
      // stage and errno
      close(fds_confirm[READ_END]);
      if (fds_stdin[WRITE_END] >= 0)
        close(fds_stdin[WRITE_END]);
      if (fds_stdout[READ_END] >= 0)
        close(fds_stdout[READ_END]);

      waitpid(pid, NULL, 0);

      event.type = event_spawn_error;
      event.id = child->id;
      event.error.stage = confirm[0];
      event.error.error = confirm[1];
      build_event(buffer, &event);
      return 0;
    }

    // no error message, confirmation channel must have been closed on exec()
    close(fds_confirm[READ_END]);

    child->pid = pid;
    child->termsig = cmd->exec_opts.termsig;
    child->pgroup = cmd->exec_opts.use_pgroup;
    child->term_killpg = cmd->exec_opts.term_pgroup;

    event.type = event_spawn;
    event.id = child->id;
    event.spawn.pid = pid;
    if (cmd->exec_opts.stdio_mode == bidirectional)
      event.spawn.stdio_mode = STDIO_MODE_BIDIR;
    else if (cmd->exec_opts.stdio_mode == in)
      event.spawn.stdio_mode = STDIO_MODE_IN;
    else if (cmd->exec_opts.stdio_mode == out)
      event.spawn.stdio_mode = STDIO_MODE_OUT;
    else if (cmd->exec_opts.stdio_mode == in_out)
      event.spawn.stdio_mode = STDIO_MODE_IN_OUT;
    build_event(buffer, &event);

    int result = 0;
    // NOTE: at least one of these should be open, so `result' will not stay
    // at zero
    if (fds_stdin[WRITE_END] >= 0)
      fds[result++] = fds_stdin[WRITE_END];
    if (fds_stdout[READ_END] >= 0)
      fds[result++] = fds_stdout[READ_END];

    return result;
  }

  // XXX: child process

  close(fds_confirm[READ_END]);
  close(fds_stdin[WRITE_END]);
  close(fds_stdout[READ_END]);

  // NOTE: parent (supervisor) has STDIN and STDOUT redirected to /dev/null
  // and all the file descriptors closed (or with FD_CLOEXEC flag set)
  if (fds_stdin[READ_END] >= 0) {
    dup2(fds_stdin[READ_END], 0);
    close(fds_stdin[READ_END]);
  }
  if (fds_stdout[WRITE_END] >= 0) {
    dup2(fds_stdout[WRITE_END], 1);
    close(fds_stdout[WRITE_END]);
  }

  if (cmd->exec_opts.stderr_to_stdout)
    dup2(1, 2);

  if (cmd->exec_opts.use_pgroup)
    setpgid(0, 0);

  if (cmd->exec_opts.use_priority) {
    if (setpriority(PRIO_PROCESS, 0, cmd->exec_opts.priority) < 0) {
      int error[2] = { STAGE_SETPRIORITY, errno };
      send(fds_confirm[WRITE_END], error, sizeof(error), MSG_NOSIGNAL);
      _exit(255);
    }
  }

  if (cmd->exec_opts.use_gid) {
    if (setgid(cmd->exec_opts.gid) < 0) {
      int error[2] = { STAGE_SETGID, errno };
      send(fds_confirm[WRITE_END], error, sizeof(error), MSG_NOSIGNAL);
      _exit(255);
    }
  }

  if (cmd->exec_opts.use_uid) {
    if (setuid(cmd->exec_opts.uid) < 0) {
      int error[2] = { STAGE_SETUID, errno };
      send(fds_confirm[WRITE_END], error, sizeof(error), MSG_NOSIGNAL);
      _exit(255);
    }
  }

  if (cmd->exec_opts.cwd != NULL) {
    if (chdir(cmd->exec_opts.cwd) < 0) {
      int error[2] = { STAGE_CHDIR, errno };
      send(fds_confirm[WRITE_END], error, sizeof(error), MSG_NOSIGNAL);
      _exit(255);
    }
  }

  struct sigaction ignore_action;
  memset(&ignore_action, 0, sizeof(ignore_action));
  ignore_action.sa_handler = SIG_IGN;
  unsigned int sig;
  for (sig = 1; sig <= 64; ++sig)
    if ((cmd->exec_opts.sigmask & (((uint64_t)1) << (sig - 1))) != 0)
      sigaction(sig, &ignore_action, NULL);

  execve(cmd->exec_opts.command, cmd->exec_opts.argv, cmd->exec_opts.env);
  // if we got here, exec() must have failed
  int error[2] = { STAGE_EXEC, errno };
  send(fds_confirm[WRITE_END], error, sizeof(error), MSG_NOSIGNAL);
  _exit(255);
}

// }}}
//----------------------------------------------------------
// wait for child processes and reap them {{{

static
pid_t child_next_event(struct children_t *children, void *buffer)
{
  int status;
  pid_t pid;
  child_t *term_child;

  while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
    term_child = child_find_pid(children, pid);
    if (term_child != NULL) {
      if (term_child->pgroup && term_child->term_killpg &&
          term_child->termsig != 0)
        killpg(pid, term_child->termsig);

      struct event_t event;

      if (WIFEXITED(status)) {
        event.type = event_exit;
        event.id = term_child->id;
        event.exit_code = WEXITSTATUS(status);
      } else { // WIFSIGNALED(status)
        event.type = event_signal;
        event.id = term_child->id;
        event.signal = WTERMSIG(status);
      }

      build_event(buffer, &event);
      child_remove(children, term_child);
      return pid;
    }
  }

  // no more children or an error occurred
  return pid;
}

// }}}
//----------------------------------------------------------
// send a signal to a child process {{{

static
int child_kill(child_t *child, int signal)
{
  if (signal == 0)
    signal = child->termsig;

  if (signal == 0)
    return 0;

  if (child->pid <= 0)
    return 0;

  if (child->pgroup)
    return killpg(child->pid, signal);
  else
    return kill(child->pid, signal);
}

// }}}
//----------------------------------------------------------

static
void set_close_on_exec(int fd)
{
  int flags = fcntl(fd, F_GETFD);
  fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
