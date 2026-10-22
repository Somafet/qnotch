#include "QNotchTerminalPTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/wait.h>
#include <libproc.h>
#include <crt_externs.h>

pid_t qn_terminal_spawn(const char *shell, const char *home, unsigned short columns,
                        unsigned short rows, int *master) {
    // Prepare all allocation and environment work before forkpty. Only async-signal-safe
    // calls (chdir, close, execve, write, _exit) follow in the child of the threaded app.
    char **parent = *_NSGetEnviron();
    size_t count = 0;
    while (parent[count]) count++;
    char **env = calloc(count + 4, sizeof(char *));
    if (!env) return -1;
    char *home_env = NULL, *shell_env = NULL;
    if (asprintf(&home_env, "HOME=%s", home) < 0) {
        free(env); errno = ENOMEM; return -1;
    }
    if (asprintf(&shell_env, "SHELL=%s", shell) < 0) {
        free(home_env); free(env); errno = ENOMEM; return -1;
    }
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        if (strncmp(parent[i], "TERM=", 5) && strncmp(parent[i], "COLORTERM=", 10)
            && strncmp(parent[i], "HOME=", 5) && strncmp(parent[i], "SHELL=", 6)
            && strncmp(parent[i], "COLUMNS=", 8) && strncmp(parent[i], "LINES=", 6)) env[n++] = parent[i];
    }
    env[n++] = home_env;
    env[n++] = shell_env;
    env[n] = "TERM=vt100"; // Deliberately don't advertise xterm's unsupported capabilities.
    const char *base = strrchr(shell, '/');
    char login[1024];
    if (snprintf(login, sizeof(login), "-%s", base ? base + 1 : shell) >= (int)sizeof(login)) {
        free(home_env); free(shell_env); free(env); errno = ENAMETOOLONG; return -1;
    }
    char *args[] = {login, "-i", NULL};
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    int descriptor_limit = getdtablesize();
    pid_t child = forkpty(master, NULL, NULL, &size);
    if (child == 0) {
        // forkpty gave the child a new session, controlling terminal and stdio on the slave.
        // Avoid leaking unrelated app sockets/files to commands.
        for (int fd = 3; fd < descriptor_limit; fd++) close(fd);
        if (chdir(home) == 0) execve(shell, args, env);
        const char message[] = "\r\nQNotch: could not start the login shell in your home folder.\r\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(127);
    }
    int saved = errno;
    free(home_env); free(shell_env); free(env);
    if (child > 0) {
        if (fcntl(*master, F_SETFD, FD_CLOEXEC) < 0 || fcntl(*master, F_SETFL, O_NONBLOCK) < 0) {
            saved = errno;
            qn_terminal_stop(child, *master);
            *master = -1;
            child = -1;
        }
    }
    errno = saved;
    return child;
}

// The unreaped leader reserves the session id. Scan by session rather than just parent:
// background jobs can be reparented when a shell exits. Deliberately detached sessions are
// outside this ownership boundary. Enumeration runs only at explicit stop/exit, never idle.
static void signal_session(pid_t session, int signal_number) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 4 * 1024 * 1024) return;
    bytes += 4096;
    pid_t *pids = calloc(1, (size_t)bytes);
    if (!pids) return;
    int count = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes) / (int)sizeof(pid_t);
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid > 1 && pid != session && getsid(pid) == session) kill(pid, signal_number);
    }
    free(pids);
}

void qn_terminal_terminate(pid_t child) {
    if (child <= 1) return;
    // Freeze the shell and its jobs before termination, including distinct foreground and
    // background job-control groups. No name-based process lookup or global app kill.
    kill(child, SIGSTOP);
    signal_session(child, SIGSTOP);
    signal_session(child, SIGHUP);
    signal_session(child, SIGKILL);
    kill(child, SIGHUP);
    kill(child, SIGKILL);
}

void qn_terminal_stop(pid_t child, int master) {
    if (child <= 1) return;
    qn_terminal_terminate(child);
    // Close before waitpid: tty teardown can wait for an undrained master on macOS.
    if (master >= 0) close(master);
    int status;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}
