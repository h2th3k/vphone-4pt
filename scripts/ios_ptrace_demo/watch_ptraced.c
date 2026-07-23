/*
 * watch_ptraced.c — iOS analog of the Android watch_tracerpid.sh.
 *
 * iOS has no /proc/<pid>/status TracerPid. The kernel equivalent is the
 * P_TRACED flag (0x800) on the process, exposed via:
 *     sysctl({CTL_KERN, KERN_PROC, KERN_PROC_PID, pid}) -> struct kinfo_proc
 *     -> kp_proc.p_flag & P_TRACED
 *
 * This polls that flag and prints a line only when P_TRACED (or p_flag)
 * changes, plus a "process GONE" line when the target exits/is killed.
 *
 * Usage: watch_ptraced <pid> [duration_sec] [interval_ms]
 *
 * Build (host, cross for iOS): see build.sh
 */

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

/* p_stat values (sys/proc.h) — used to tell alive vs zombie vs gone. */
#ifndef SZOMB
#define SZOMB 5
#endif
#ifndef SSTOP
#define SSTOP 4
#endif

static const char *state_name(char s) {
    switch (s) {
        case 1: return "IDL";
        case 2: return "RUN";
        case 3: return "SLEEP";
        case SSTOP: return "STOP";
        case SZOMB: return "ZOMB";
        default: return "?";
    }
}

static void ts_now(char *buf, size_t n) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    snprintf(buf, n, "%02d:%02d:%02d.%03ld",
             tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000000);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <pid> [duration_sec] [interval_ms]\n", argv[0]);
        return 2;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    int dur   = (argc >= 3) ? atoi(argv[2]) : 40;
    int iv_ms = (argc >= 4) ? atoi(argv[3]) : 200;

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc k;
    size_t len;
    int prev_traced = -1;
    unsigned prev_flag = 0;
    char tbuf[32];

    printf("[*] watching P_TRACED of pid %d for %ds (poll %dms)\n", pid, dur, iv_ms);
    printf("    (P_TRACED 0x%x: 1 = tracer/debugger attached, 0 = not traced)\n", P_TRACED);
    fflush(stdout);

    time_t end = time(NULL) + dur;
    while (time(NULL) < end) {
        len = sizeof(k);
        memset(&k, 0, sizeof(k));
        if (sysctl(mib, 4, &k, &len, NULL, 0) != 0) {
            ts_now(tbuf, sizeof(tbuf));
            if (errno == ENOENT || errno == ESRCH)
                printf("%s  pid %d GONE (exited/killed)\n", tbuf, (int)pid);
            else
                printf("%s  sysctl error: %s\n", tbuf, strerror(errno));
            break;
        }
        unsigned flag   = (unsigned)k.kp_proc.p_flag;
        int      traced = (flag & P_TRACED) ? 1 : 0;
        char     pstat  = k.kp_proc.p_stat;

        if (pstat == SZOMB) {
            ts_now(tbuf, sizeof(tbuf));
            printf("%s  pid %d ZOMBIE (exited/killed, awaiting reap; p_flag=0x%x)\n",
                   tbuf, (int)pid, flag);
            break;
        }

        if (traced != prev_traced) {
            ts_now(tbuf, sizeof(tbuf));
            if (prev_traced == -1)
                printf("%s  P_TRACED = %d  (initial; p_flag=0x%x)\n", tbuf, traced, flag);
            else if (traced == 0) {
                printf("%s  P_TRACED = 0  (detached; p_flag=0x%x)\n", tbuf, flag);
                printf("%s  -> pid %d still EXISTS (state=%s, survived detach)\n",
                       tbuf, (int)pid, state_name(pstat));
            } else
                printf("%s  P_TRACED = 1  (tracer attached; p_flag=0x%x)\n", tbuf, flag);
            prev_traced = traced;
            prev_flag   = flag;
        } else if (flag != prev_flag) {
            ts_now(tbuf, sizeof(tbuf));
            printf("%s  p_flag changed -> 0x%x (P_TRACED=%d)\n", tbuf, flag, traced);
            prev_flag = flag;
        }
        fflush(stdout);
        usleep(iv_ms * 1000);
    }
    ts_now(tbuf, sizeof(tbuf));
    len = sizeof(k);
    memset(&k, 0, sizeof(k));
    if (sysctl(mib, 4, &k, &len, NULL, 0) == 0) {
        unsigned f = (unsigned)k.kp_proc.p_flag;
        char     s = k.kp_proc.p_stat;
        if (s == SZOMB)
            printf("%s  watch finished; pid %d ZOMBIE (exited, awaiting reap; p_flag=0x%x)\n",
                   tbuf, (int)pid, f);
        else
            printf("%s  watch finished; pid %d still EXISTS (state=%s, p_flag=0x%x, P_TRACED=%d)\n",
                   tbuf, (int)pid, state_name(s), f, (f & P_TRACED) ? 1 : 0);
    } else
        printf("%s  watch finished; pid %d GONE (no longer exists)\n", tbuf, (int)pid);
    return 0;
}
