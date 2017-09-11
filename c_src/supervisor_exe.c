#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

#include "supervisor.h"

static int getint(char *string, int *result)
{
  if (*string == 0) // empty string
    return 0;

  char *end;
  int res = strtol(string, &end, 10);
  if (*end != 0) // a part of the string is invalid
    return 0;

  if (res < 0) // negative values can't be file descriptors
    return 0;

  *result = res;
  return 1;
}

int main(int argc, char **argv)
{
  int fd_comm;
  int fd_events;
  if (argc != 3 || !getint(argv[1], &fd_comm) || !getint(argv[2], &fd_events)) {
    fprintf(stderr, "Usage: %s <commfd> <eventfd>\n", argv[0]);
    return 1;
  }

  int maxfd = sysconf(_SC_OPEN_MAX);
  int fd;
  for (fd = 3; fd < maxfd; ++fd)
    if (fd != fd_comm && fd != fd_events)
      close(fd);

  supervisor_loop(fd_comm, fd_events);

  return 0;
}
