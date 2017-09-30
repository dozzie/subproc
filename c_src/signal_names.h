#ifndef __SIGNAL_NAMES_H
#define __SIGNAL_NAMES_H

#define MAX_SIGNAL_NAME 10 // "SIGFOO", including terminating '\0'

const char* find_signal_shortname(int signum);
int find_signal_number(const char *signame);

#endif // __SIGNAL_NAMES_H
