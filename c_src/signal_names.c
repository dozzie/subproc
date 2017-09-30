//----------------------------------------------------------------------------

#include <string.h>
#include <signal.h>
#include "signal_names.h"

//----------------------------------------------------------------------------

struct signal_desc {
  int signum;
  const char *name;
  const char *shortname;
};

#define MAKE_SIGNAL(n, sn) { n, #n, sn }

// XXX: remember to update `MAX_SIGNAL_NAME' if necessary when adding a new
// signal entry
static const struct signal_desc signals[] = {
  MAKE_SIGNAL(SIGHUP,  "hup"),
  MAKE_SIGNAL(SIGINT,  "int"),
  MAKE_SIGNAL(SIGQUIT, "quit"),
  MAKE_SIGNAL(SIGILL,  "ill"),
  MAKE_SIGNAL(SIGABRT, "abrt"),
  MAKE_SIGNAL(SIGFPE,  "fpe"),
  MAKE_SIGNAL(SIGKILL, "kill"),
  MAKE_SIGNAL(SIGSEGV, "segv"),
  MAKE_SIGNAL(SIGPIPE, "pipe"),
  MAKE_SIGNAL(SIGALRM, "alrm"),
  MAKE_SIGNAL(SIGTERM, "term"),
  MAKE_SIGNAL(SIGUSR1, "usr1"),
  MAKE_SIGNAL(SIGUSR2, "usr2"),
  MAKE_SIGNAL(SIGCHLD, "chld"),
  MAKE_SIGNAL(SIGCONT, "cont"),
  MAKE_SIGNAL(SIGSTOP, "stop"),
  MAKE_SIGNAL(SIGTSTP, "tstp"),
  MAKE_SIGNAL(SIGTTIN, "ttin"),
  MAKE_SIGNAL(SIGTTOU, "ttou"),
  MAKE_SIGNAL(SIGBUS,  "bus"),
#ifdef SIGPOLL // BSD doesn't have this one, but it has SIGIO
  MAKE_SIGNAL(SIGPOLL, "poll"),
#endif
  MAKE_SIGNAL(SIGPROF, "prof"),
  MAKE_SIGNAL(SIGSYS,  "sys"),
  MAKE_SIGNAL(SIGTRAP, "trap"),
  MAKE_SIGNAL(SIGURG,  "urg"),
  MAKE_SIGNAL(SIGVTALRM, "vtalrm"),
  MAKE_SIGNAL(SIGXCPU, "xcpu"),
  MAKE_SIGNAL(SIGXFSZ, "xfsz"),

  // signals below are non-standard

#ifdef SIGIOT
  MAKE_SIGNAL(SIGIOT, "iot"),
#endif
#ifdef SIGEMT
  MAKE_SIGNAL(SIGEMT, "emt"),
#endif
#ifdef SIGSTKFLT
  MAKE_SIGNAL(SIGSTKFLT, "stkflt"),
#endif
#ifdef SIGIO
  MAKE_SIGNAL(SIGIO, "io"),
#endif
#ifdef SIGCLD
  MAKE_SIGNAL(SIGCLD, "cld"),
#endif
#ifdef SIGPWR
  MAKE_SIGNAL(SIGPWR, "pwr"),
#endif
#ifdef SIGINFO
  MAKE_SIGNAL(SIGINFO, "info"),
#endif
#ifdef SIGLOST
  MAKE_SIGNAL(SIGLOST, "lost"),
#endif
#ifdef SIGWINCH
  MAKE_SIGNAL(SIGWINCH, "winch"),
#endif
#ifdef SIGUNUSED
  MAKE_SIGNAL(SIGUNUSED, "unused"),
#endif

  { 0, NULL, NULL } // guard
};

//----------------------------------------------------------------------------

const char* find_signal_shortname(int signum)
{
  if (signum <= 0)
    return NULL;

  const struct signal_desc *sig = signals;
  while (sig->name != NULL) {
    if (sig->signum == signum)
      return sig->shortname;
    ++sig;
  }
  // nothing found
  return NULL;
}

int find_signal_number(const char *signame)
{
  if (signame == NULL)
    return 0;

  const struct signal_desc *sig = signals;
  while (sig->name != NULL) {
    if (strcmp(sig->name, signame) == 0)
      return sig->signum;
    ++sig;
  }
  // nothing found
  return 0;
}

//----------------------------------------------------------------------------
// vim:ft=c
