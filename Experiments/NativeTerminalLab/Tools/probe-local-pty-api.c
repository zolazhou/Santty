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
#include <fcntl.h>

// Swift cannot import the function-like _IOR macro. Keep its explicit ABI
// value checked against the real SDK, not against the Swift implementation.
_Static_assert(FIONREAD == 0x4004667fUL, "Darwin FIONREAD ABI changed");
_Static_assert(TIOCOUTQ == 0x40047473UL, "Darwin TIOCOUTQ ABI changed");

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
static int readable_fence(void) {
    int ready[2], fd = -1;
    if (pipe(ready)) return 1;
    pid_t pid = forkpty(&fd, NULL, NULL, NULL);
    if (pid < 0) { close(ready[0]); close(ready[1]); return 1; }
    if (pid == 0) {
        alarm(5);
        close(ready[0]);
        if (write(1, "FINAL-TAIL", 10) != 10 || write(ready[1], "R", 1) != 1) _exit(1);
        for (;;) pause();
    }
    close(ready[1]);
    char notification = 0, bytes[64];
    int available = -1, output = -1, status = 0;
    (void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    int ok = read(ready[0], &notification, 1) == 1
        && ioctl(fd, FIONREAD, &available) == 0
        && ioctl(fd, TIOCOUTQ, &output) == 0 && output == 10;
    ssize_t got = read(fd, bytes, sizeof(bytes));
    ok = ok && got == 10 && memcmp(bytes, "FINAL-TAIL", 10) == 0;
    // Positive unreaped owned child, no competing reaper in this tiny client.
    kill(pid, SIGKILL); waitpid(pid, &status, 0);
    close(ready[0]); close(fd);
    printf("owned_capture_fence: fionread_input=%d output=%d read=%zd exact=%d\n", available, output, got, ok);
    return ok ? 0 : 1;
}

static int short_child_hangup(void) {
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, NULL);
    if (pid < 0) return 1;
    if (pid == 0) {
        alarm(5);
        _exit(write(1, "FINAL-TAIL", 10) == 10 ? 0 : 1);
    }
    int status = 0, available = -1;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) { close(fd); return 1; }
    (void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    int queried = ioctl(fd, TIOCOUTQ, &available);
    char bytes[64];
    ssize_t got = read(fd, bytes, sizeof(bytes));
    int exact = got == 10 && memcmp(bytes, "FINAL-TAIL", 10) == 0;
    close(fd);
    printf("owned_short_child_after_reap: write_verified=10 output=%d read=%zd exact=%d\n", available, got, exact);
    if (!exact) puts("KNOWN LIMITATION: Darwin may discard PTY bytes before capture on short-child hangup; the parser-fence fix does not recover them.");
    // Successful observation, NOT certification that the bad vector works.
    return queried == 0 ? 0 : 1;
}

int main(void) {
    int signals = probe(SIGHUP) | probe(SIGKILL);
    int fence = readable_fence(), hangup = short_child_hangup();
    return signals || fence || hangup;
}
