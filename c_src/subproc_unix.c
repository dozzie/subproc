//----------------------------------------------------------------------------

#include <erl_nif.h>
#include <erl_driver.h> // for erl_errno_id()

#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>

#include <ctype.h>

#include "signal_names.h"

//----------------------------------------------------------------------------
// unix API

static
ERL_NIF_TERM unix_waitpid(ErlNifEnv* env, int argc, const ERL_NIF_TERM *argv)
{
  int pid;
  if (!enif_get_int(env, argv[0], &pid) || pid <= 0)
    return enif_make_tuple2(env,
      enif_make_atom(env, "error"),
      enif_make_atom(env, "badarg")
    );

  int status;
  pid_t result = waitpid(pid, &status, WNOHANG);

  if (result == 0)
    return enif_make_atom(env, "alive");

  if (result < 0 && errno == ECHILD)
    return enif_make_atom(env, "undefined");

  if (result < 0)
    return enif_make_tuple2(env,
      enif_make_atom(env, "error"),
      enif_make_atom(env, erl_errno_id(errno))
    );

  if (WIFSIGNALED(status)) {
    // I prefer to be sure (WIFSIGNALED()) that it's a signal than assume it

    const char *signame = find_signal_shortname(WTERMSIG(status));
    // TODO: what if signame == NULL?

    return enif_make_tuple2(env,
      enif_make_atom(env, "ok"),
      enif_make_atom(env, (char *)signame)
    );
  }

  return enif_make_tuple2(env,
    enif_make_atom(env, "ok"),
    enif_make_int(env, WEXITSTATUS(status))
  );
}

static
ERL_NIF_TERM unix_close(ErlNifEnv* env, int argc, const ERL_NIF_TERM *argv)
{
  int fd;
  if (!enif_get_int(env, argv[0], &fd))
    return enif_make_tuple2(env,
      enif_make_atom(env, "error"),
      enif_make_atom(env, "badarg")
    );

  if (close(fd) != 0)
    return enif_make_tuple2(env,
      enif_make_atom(env, "error"),
      enif_make_atom(env, erl_errno_id(errno))
    );

  return enif_make_atom(env, "ok");
}

static
ERL_NIF_TERM unix_getuid(ErlNifEnv* env, int argc, const ERL_NIF_TERM *argv)
{
  return enif_make_int(env, getuid());
}

static
ERL_NIF_TERM unix_geteuid(ErlNifEnv* env, int argc, const ERL_NIF_TERM *argv)
{
  return enif_make_int(env, geteuid());
}

static
ERL_NIF_TERM unix_getgid(ErlNifEnv* env, int argc, const ERL_NIF_TERM *argv)
{
  return enif_make_int(env, getgid());
}

static
ERL_NIF_TERM unix_getegid(ErlNifEnv* env, int argc, const ERL_NIF_TERM *argv)
{
  return enif_make_int(env, getegid());
}

//----------------------------------------------------------------------------
// translation functions

static
ERL_NIF_TERM translate_errno_to_posix(ErlNifEnv* env,
                                      int argc, const ERL_NIF_TERM *argv)
{
  int error;
  if (!enif_get_int(env, argv[0], &error))
    return enif_make_badarg(env);

  return enif_make_atom(env, erl_errno_id(error));
}

static
ERL_NIF_TERM translate_signal_name(ErlNifEnv* env,
                                   int argc, const ERL_NIF_TERM *argv)
{
  int signal;
  if (!enif_get_int(env, argv[0], &signal))
    return enif_make_badarg(env);

  const char *signame = find_signal_shortname(signal);
  if (signame == NULL)
    return enif_make_badarg(env);

  return enif_make_atom(env, (char *)signame);
}

static
ERL_NIF_TERM translate_signal_number(ErlNifEnv* env,
                                     int argc, const ERL_NIF_TERM *argv)
{
  char signame[MAX_SIGNAL_NAME] = "SIG";
  if (!enif_get_atom(env, argv[0], signame + 3, sizeof(signame) - 3,
                     ERL_NIF_LATIN1))
    return enif_make_badarg(env);

  size_t i;
  for (i = 3; signame[i] != 0; ++i)
    signame[i] = toupper(signame[i]);

  int signal = find_signal_number(signame);
  if (signal == 0)
    return enif_make_badarg(env);

  return enif_make_int(env, signal);
}

//----------------------------------------------------------------------------

static
ErlNifFunc nif_functions[] = {
  {"waitpid", 1, unix_waitpid},
  {"close", 1,   unix_close},
  {"getuid", 0,  unix_getuid},
  {"geteuid", 0, unix_geteuid},
  {"getgid", 0,  unix_getgid},
  {"getegid", 0, unix_getegid},
  {"errno_to_posix", 1, translate_errno_to_posix},
  {"signal_name", 1,    translate_signal_name},
  {"signal_number", 1,  translate_signal_number}
  // TODO: format_error()
};

ERL_NIF_INIT(subproc_unix, nif_functions, NULL, NULL, NULL, NULL)

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
