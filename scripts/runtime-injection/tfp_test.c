// tfp_test.c — probe whether a target pid is debuggable (get-task-allow honored).
//
// task_for_pid(caller, pid, &port) succeeds iff the CALLER holds a task-port
// entitlement OR the TARGET has get-task-allow (CS_GET_TASK_ALLOW). This probe
// is ad-hoc signed with NO entitlements, so a success can ONLY mean the target
// pid has get-task-allow — exactly what the Dev TXM patch is supposed to force.
//
// Build (host, Xcode + iOS SDK):
//   xcrun --sdk iphoneos clang -arch arm64e -o /tmp/tfp_test \
//       scripts/runtime-injection/tfp_test.c \
//       -isysroot $(xcrun --sdk iphoneos --show-sdk-path)
//   ldid -S /tmp/tfp_test
// Deploy (usbmux forward 2222 -> 22222 already running):
//   sshpass -p alpine scp -P 2222 -o StrictHostKeyChecking=no \
//       -o UserKnownHostsFile=/dev/null /tmp/tfp_test root@127.0.0.1:/var/root/tfp_test
// Run on guest (as root):
//   /var/root/tfp_test <pid>
// Exit 0 -> get-task-allow HONORED; exit 1 -> NOT honored.

#include <stdio.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_init.h>

extern kern_return_t task_for_pid(mach_port_t target, int pid, mach_port_t *port);

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <pid>\n", argv[0]);
        return 2;
    }
    int pid = atoi(argv[1]);
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &port);
    printf("task_for_pid(%d) = %u (%s)\n", pid, (unsigned)kr,
           (kr == KERN_SUCCESS) ? "KERN_SUCCESS" : "FAILURE");
    if (kr == KERN_SUCCESS) {
        printf("=> get-task-allow HONORED: pid %d is debuggable\n", pid);
        mach_port_deallocate(mach_task_self(), port);
        return 0;
    }
    printf("=> get-task-allow NOT honored: pid %d not debuggable (kr=%u)\n",
           pid, (unsigned)kr);
    return 1;
}
