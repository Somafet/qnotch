#pragma once
#include <sys/types.h>
// fork/exec stays entirely in C: no Swift/Foundation code runs in the forked child.
pid_t qn_terminal_spawn(const char *shell, const char *home, unsigned short columns,
                        unsigned short rows, int *master);
void qn_terminal_terminate(pid_t child);
void qn_terminal_stop(pid_t child, int master);
