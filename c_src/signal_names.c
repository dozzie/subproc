//----------------------------------------------------------------------------

#include <string.h>
#include <signal.h>
#include "signal_names.h"

//----------------------------------------------------------------------------

struct signal_desc {
  int signum;
  const char *name;
};

#define MAKE_SIGNAL(n) { n, #n }

// XXX: remember to update `MAX_SIGNAL_NAME' if necessary when adding a new
// signal entry
static const struct signal_desc signals[] = {
  MAKE_SIGNAL(SIGHUP),
  MAKE_SIGNAL(SIGINT),
  MAKE_SIGNAL(SIGQUIT),
  MAKE_SIGNAL(SIGILL),
  MAKE_SIGNAL(SIGABRT),
  MAKE_SIGNAL(SIGFPE),
  MAKE_SIGNAL(SIGKILL),
  MAKE_SIGNAL(SIGSEGV),
  MAKE_SIGNAL(SIGPIPE),
  MAKE_SIGNAL(SIGALRM),
  MAKE_SIGNAL(SIGTERM),
  MAKE_SIGNAL(SIGUSR1),
  MAKE_SIGNAL(SIGUSR2),
  MAKE_SIGNAL(SIGCHLD),
  MAKE_SIGNAL(SIGCONT),
  MAKE_SIGNAL(SIGSTOP),
  MAKE_SIGNAL(SIGTSTP),
  MAKE_SIGNAL(SIGTTIN),
  MAKE_SIGNAL(SIGTTOU),
  MAKE_SIGNAL(SIGBUS),
#ifdef SIGPOLL // BSD doesn't have this one, but it has SIGIO
  MAKE_SIGNAL(SIGPOLL),
#endif
  MAKE_SIGNAL(SIGPROF),
  MAKE_SIGNAL(SIGSYS),
  MAKE_SIGNAL(SIGTRAP),
  MAKE_SIGNAL(SIGURG),
  MAKE_SIGNAL(SIGVTALRM),
  MAKE_SIGNAL(SIGXCPU),
  MAKE_SIGNAL(SIGXFSZ),

  // signals below are non-standard

#ifdef SIGIOT
  MAKE_SIGNAL(SIGIOT),
#endif
#ifdef SIGEMT
  MAKE_SIGNAL(SIGEMT),
#endif
#ifdef SIGSTKFLT
  MAKE_SIGNAL(SIGSTKFLT),
#endif
#ifdef SIGIO
  MAKE_SIGNAL(SIGIO),
#endif
#ifdef SIGCLD
  MAKE_SIGNAL(SIGCLD),
#endif
#ifdef SIGPWR
  MAKE_SIGNAL(SIGPWR),
#endif
#ifdef SIGINFO
  MAKE_SIGNAL(SIGINFO),
#endif
#ifdef SIGLOST
  MAKE_SIGNAL(SIGLOST),
#endif
#ifdef SIGWINCH
  MAKE_SIGNAL(SIGWINCH),
#endif
#ifdef SIGUNUSED
  MAKE_SIGNAL(SIGUNUSED),
#endif

  { 0, NULL } // guard
};

//----------------------------------------------------------------------------

const char* find_signal_name(int signum)
{
  if (signum <= 0)
    return NULL;

  const struct signal_desc *sig = signals;
  while (sig->name != NULL) {
    if (sig->signum == signum)
      return sig->name;
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
