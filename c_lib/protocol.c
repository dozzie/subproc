//----------------------------------------------------------------------------

#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <pwd.h>
#include <grp.h>

#include "protocol.h"

//----------------------------------------------------------------------------

#define TAG_COMM_EXEC       0x01
#define TAG_COMM_KILL       0x02
#define TAG_COMM_SHUTDOWN   0xff

#define FLAG_STDIO_MODE         0x03 // mode (inout, in, out, in + out)
#define FLAG_STDIO_SOCKET       0x04 // pipe or socket
#define FLAG_STDERR_TO_STDOUT   0x08 // redirect STDERR to STDOUT
#define FLAG_PGROUP             0x10 // spawn a command in its proc group

// numeric option tags
#define OPT_TERMSIG   0x74 // uint8_t
#define OPT_PRIORITY  0x70 // int8_t
#define OPT_UID       0x75 // uint16_t
#define OPT_GID       0x67 // uint16_t
// string option tags
#define OPT_USER      0x55 // getpwnam()
#define OPT_GROUP     0x47 // getgrnam()
#define OPT_CWD       0x43
#define OPT_ARGV0     0x30

//----------------------------------------------------------------------------

int parse_exec_command(unsigned char *data, size_t size, struct comm_t *comm);

//----------------------------------------------------------------------------

int parse_command(void *data, size_t size, struct comm_t *comm)
{
  memset(comm, 0, sizeof(struct comm_t));
  unsigned char *rdata = data;

  if (rdata[0] == TAG_COMM_EXEC && size > 2) {
    comm->type = comm_exec;
    if (parse_exec_command(rdata, size, comm) < 0) {
      free_command(comm);
      return -1;
    }
    return 0;
  }

  if (rdata[0] == TAG_COMM_KILL && size == 2 + sizeof(uint64_t)) {
    comm->type = comm_kill;
    comm->kill.signal = rdata[1];
    if (comm->kill.signal > 32)
      return -1;
    comm->kill.id = ((uint64_t)rdata[2] << (8 * 7))
                  | ((uint64_t)rdata[3] << (8 * 6))
                  | ((uint64_t)rdata[4] << (8 * 5))
                  | ((uint64_t)rdata[5] << (8 * 4))
                  | ((uint64_t)rdata[6] << (8 * 3))
                  | ((uint64_t)rdata[7] << (8 * 2))
                  | ((uint64_t)rdata[8] << (8 * 1))
                  | ((uint64_t)rdata[9] << (8 * 0));
    return 0;
  }

  if (rdata[0] == TAG_COMM_SHUTDOWN && size == 2) {
    comm->type = comm_shutdown;
    return 0;
  }

  return -1;
}

void free_command(struct comm_t *comm)
{
  // other types don't have dynamically allocated memory
  if (comm->type != comm_exec)
    return;

  if (comm->exec_opts.argv != NULL &&
      comm->exec_opts.command == comm->exec_opts.argv[0])
    // this will be freed on free(argv[0])
    comm->exec_opts.command = NULL;

  if (comm->exec_opts.command != NULL) {
    free(comm->exec_opts.command);
    comm->exec_opts.command = NULL;
  }

  if (comm->exec_opts.argv != NULL) {
    char **ptr;
    for (ptr = comm->exec_opts.argv; *ptr != NULL; ++ptr)
      free(*ptr);
    free(comm->exec_opts.argv);
    comm->exec_opts.argv = NULL;
  }

  // TODO: comm->exec_opts.envp, once it's added

  if (comm->exec_opts.cwd != NULL) {
    free(comm->exec_opts.cwd);
    comm->exec_opts.cwd = NULL;
  }
}

//----------------------------------------------------------------------------

char* parse_string(unsigned char *data, size_t size, size_t *read_at)
{
  if (size - *read_at < 2)
    return NULL;

  size_t read_size = (data[*read_at] << 8) | (data[*read_at + 1]);

  if (read_size == 0)
    return NULL;

  if (size - (*read_at + 2) < read_size)
    return NULL;

  char *result = strndup((char *)(data + *read_at + 2), read_size);
  *read_at += read_size + 2;
  return result;
}

int parse_exec_command(unsigned char *data, size_t size, struct comm_t *comm)
{
  // data[0] is a command tag
  // data[1] carries bit flags
  switch (data[1] & FLAG_STDIO_MODE) {
    case 0x00:
      comm->exec_opts.stdio_mode = bidirectional;
    break;
    case 0x01:
      comm->exec_opts.stdio_mode = in;
    break;
    case 0x02:
      comm->exec_opts.stdio_mode = out;
    break;
    case 0x03:
      comm->exec_opts.stdio_mode = in_out;
    break;
    default:
      return -1;
  }
  comm->exec_opts.stdio_socket     = ((data[1] & FLAG_STDIO_SOCKET) != 0);
  comm->exec_opts.stderr_to_stdout = ((data[1] & FLAG_STDERR_TO_STDOUT) != 0);
  comm->exec_opts.use_pgroup       = ((data[1] & FLAG_PGROUP) != 0);

  size_t read_at = 2;
  if ((comm->exec_opts.command = parse_string(data, size, &read_at)) == NULL)
    return -1;

  if (size - read_at < 2)
    return -1;
  size_t nargs = (data[read_at] << 8) | (data[read_at + 1]);
  read_at += 2;

  // argv has two more entries: argv[0] (command name) and NULL ward
  comm->exec_opts.argv = calloc(nargs + 2, sizeof(char *));
  comm->exec_opts.argv[0] = comm->exec_opts.command;
  //comm->exec_opts.argv[nargs + 2 - 1] = NULL; // already done by calloc()
  size_t argi;
  for (argi = 1; argi <= nargs; ++argi) {
    comm->exec_opts.argv[argi] = parse_string(data, size, &read_at);
    if (comm->exec_opts.argv[argi] == NULL)
      return -1;
  }

  // TODO: list of env vars to set
  // TODO: list of env vars to clear

  char *argv0;
  while (read_at < size) {
    switch (data[read_at++]) {
      // numeric options
      case OPT_TERMSIG:
        if (size - read_at < 1)
          return -1;
        comm->exec_opts.termsig = data[read_at++];
        if (comm->exec_opts.termsig > 32)
          return -1;
      break;
      case OPT_PRIORITY:
        if (size - read_at < 1)
          return -1;
        comm->exec_opts.priority = (signed char)data[read_at++];
        comm->exec_opts.use_priority = 1;
      break;
      case OPT_UID:
        if (size - read_at < 2)
          return -1;
        comm->exec_opts.uid = (data[read_at] << 8) | (data[read_at + 1]);
        comm->exec_opts.use_uid = 1;
        read_at += 2;
      break;
      case OPT_GID:
        if (size - read_at < 2)
          return -1;
        comm->exec_opts.gid = (data[read_at] << 8) | (data[read_at + 1]);
        comm->exec_opts.use_gid = 1;
        read_at += 2;
      break;

      // string options
      //case OPT_USER:
      //  TODO: implement me
      //break;
      //case OPT_GROUP:
      //  TODO: implement me
      //break;
      case OPT_CWD:
        if (comm->exec_opts.cwd != NULL)
          free(comm->exec_opts.cwd);
        comm->exec_opts.cwd = parse_string(data, size, &read_at);
        if (comm->exec_opts.cwd == NULL)
          return -1;
      break;
      case OPT_ARGV0:
        argv0 = parse_string(data, size, &read_at);
        if (argv0 == NULL)
          return -1;
        if (comm->exec_opts.argv[0] != comm->exec_opts.command)
          free(comm->exec_opts.argv[0]);
        comm->exec_opts.argv[0] = argv0;
      break;

      default:
        return -1;
    }
  }

  return 0;
}

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
