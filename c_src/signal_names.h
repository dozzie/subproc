#ifndef __SIGNAL_NAMES_H
#define __SIGNAL_NAMES_H

#define MAX_SIGNAL_NAME 10 // includes terminating '\0'

const char* find_signal_name(int signum);
int find_signal_number(const char *signame);

#endif // __SIGNAL_NAMES_H
