// Owned tiny Darwin PTY probe. No terminal core, user shell/session or shared
// daemon. This proves ioctl argument/identity/signal behavior independently.
#include <util.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>

static void hup(int signal_number) { (void)signal_number; _exit(42); }
static int probe(int signal_number) {
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, NULL);
    if (pid < 0) return 1;
    if (pid == 0) {
        signal(SIGHUP, hup);
        if (write(1, "READY", 5) != 5) _exit(1);
        for (;;) pause();
    }
    char ready[64], name[128] = {0};
    int error = 0;
    if (read(fd, ready, sizeof(ready)) <= 0 || ioctl(fd, TIOCPTYGNAME, name) != 0
        || tcgetpgrp(fd) != pid || strncmp(name, "/dev/", 5) != 0
        || ioctl(fd, TIOCSIG, signal_number) != 0) error = 1;
    int status = 0;
    for (int i = 0; i < 100 && !error; ++i) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            close(fd);
            int ok = signal_number == SIGHUP ? WIFEXITED(status) && WEXITSTATUS(status) == 42
                : WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL;
            printf("owned_pty: name=%s foreground_matches_child=1 signal=%d verified=%d\n", name, signal_number, ok);
            return ok ? 0 : 1;
        }
        if (waited == -1 && errno != EINTR) { close(fd); return 1; }
        usleep(10000);
    }
    // No other reaper exists in this tiny process: this positive, unreaped
    // direct child still owns its PID. Never signal a cached/reaped group ID.
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    close(fd);
    return 1;
}
int main(void) { return probe(SIGHUP) || probe(SIGKILL); }
