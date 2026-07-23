/*
 * tracer_hold.c — iOS analog of the Android "pta" freestanding ptrace attacher.
 *
 * Android pta does PTRACE_ATTACH on an arbitrary running pid. iOS has no
 * external ptrace(PT_ATTACH) (it's deprecated) and no /proc/TracerPid. The
 * faithful iOS equivalent that SETS the kernel P_TRACED flag (the TracerPid
 * analog) is the cooperative ptrace model:
 *
 *   fork()
 *   child:  ptrace(PT_TRACE_ME)   -> sets P_TRACED on the child
 *           raise(SIGTRAP)        -> child stops under the tracer
 *           (loop alive while traced)
 *   parent: waitpid(child)        -> reaps the trace-stop
 *           ptrace(PT_CONTINUE)   -> let the child run while traced
 *           hold N seconds        -> P_TRACED stays 1 (visible to watch_ptraced)
 *           ptrace(PT_DETACH)     -> clears P_TRACED
 *
 * The ptrace calls go through a raw `svc #0` with x16=SYS_ptrace (26), because
 * iOS/BSD uses x16 for the syscall number (Linux uses x8) and because ptrace is
 * a private/restricted API on iOS. The rest (fork, waitpid, nanosleep, raise)
 * uses libsystem, which is always present on iOS.
 *
 * Usage: tracer_hold [hold_seconds]
 * Prints "CHILD_PID=<pid>" so watch_ptraced knows which pid to watch.
 */

#include <sys/types.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <string.h>

/* sys/ptrace.h is private on the public iPhoneOS SDK, so the PT_* request
 * numbers are defined here directly. ptrace itself is invoked via a raw
 * syscall (see ptrace_raw). sys/wait.h (waitpid + W* macros) is pulled in
 * transitively by the standard headers below. */
#define PT_TRACE_ME  0
#define PT_CONTINUE  7
#define PT_DETACH   11

/* Raw BSD/Darwin ptrace syscall: syscall number in x16, args in x0-x3.
 * Returns 0 on success, positive errno on error (kernel sets carry on error;
 * ptrace's only success value is 0, so "!= 0" means error). */
static long ptrace_raw(long request, long pid, long addr, long data) {
    register long x16 asm("x16") = 26;          /* SYS_ptrace */
    register long x0  asm("x0")  = request;
    register long x1  asm("x1")  = pid;
    register long x2  asm("x2")  = addr;
    register long x3  asm("x3")  = data;
    asm volatile("svc #0"
                 : "+r"(x0)
                 : "r"(x16), "r"(x1), "r"(x2), "r"(x3)
                 : "memory", "cc");
    return x0;
}

int main(int argc, char **argv) {
    int hold = (argc >= 2) ? atoi(argv[1]) : 20;

    pid_t child = fork();
    if (child < 0) { perror("fork"); return 1; }

    if (child == 0) {
        /* --- child (tracee) --- */
        struct timespec d = { 5, 0 };
        nanosleep(&d, NULL);                     /* let the watcher start, to see off->on */

        long r = ptrace_raw(PT_TRACE_ME, 0, 0, 0);
        if (r != 0) {
            fprintf(stderr, "[child] PT_TRACE_ME failed (errno-ish=%ld)\n", r);
            _exit(1);
        }
        raise(SIGTRAP);                          /* stop under the tracer */

        /* resumed by parent's PT_CONTINUE; stay alive while traced */
        time_t end = time(NULL) + hold + 8;
        while (time(NULL) < end) {
            struct timespec s = { 1, 0 };
            nanosleep(&s, NULL);
        }
        _exit(0);
    }

    /* --- parent (tracer) --- */
    printf("CHILD_PID=%d\n", (int)child);
    fflush(stdout);

    int status = 0;
    if (waitpid(child, &status, 0) < 0) { perror("waitpid"); return 1; }
    if (WIFSTOPPED(status))
        printf("[+] child stopped (sig=%d) — P_TRACED is set\n", WSTOPSIG(status));
    else if (WIFEXITED(status)) {
        printf("[!] child exited early (status=%d); not tracing\n", WEXITSTATUS(status));
        return 1;
    }

    if (ptrace_raw(PT_CONTINUE, child, 1, 0) != 0)
        perror("[!] PT_CONTINUE");               /* may still be traced */

    printf("[+] holding %ds (child traced; P_TRACED=1)...\n", hold);
    fflush(stdout);
    struct timespec h = { hold, 0 };
    nanosleep(&h, NULL);

    if (ptrace_raw(PT_DETACH, child, 1, 0) != 0)
        perror("[!] PT_DETACH");
    else
        printf("[+] detached — P_TRACED cleared\n");
    fflush(stdout);

    int st2 = 0;
    waitpid(child, &st2, 0);                      /* reap child when it exits */
    return 0;
}
