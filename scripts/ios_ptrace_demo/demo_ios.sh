#!/usr/bin/env zsh
# demo_ios.sh — iOS analog of the Android ptrace demo
#   (Android: demo.sh + watch_tracerpid.sh + pta).
#
# Android: PTRACE_ATTACH a running pid, watch /proc/<pid>/status TracerPid.
# iOS:     no /proc; watch the kernel P_TRACED flag via sysctl(KERN_PROC_PID).
#          No external PT_ATTACH on iOS, so tracer_hold uses the cooperative
#          model: fork -> child PT_TRACE_ME (sets P_TRACED) -> parent
#          PT_CONTINUE -> hold -> PT_DETACH (clears P_TRACED).
#
# Scenario A (automated below): demonstrate P_TRACED toggling live, fully on
# the vphone over SSH. Scenario B (the real PhoneControlApp + its anti-debug)
# is printed at the end — it uses debugserver's --start-stopped attach (which
# also sets P_TRACED) and shows ptrace(PT_DENY_ATTACH) -> exit(45).
set -euo pipefail

HERE=${0:a:h}
HOST=${VPHONE_HOST:-127.0.0.1}
PORT=${VPHONE_PORT:-2222}
USER=${VPHONE_USER:-root}
PASS=${VPHONE_PASS:-alpine}
REMOTE=${VPHONE_REMOTE:-/var/root}
HOLD=${1:-20}

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)
vssh() { sshpass -p "$PASS" ssh -p "$PORT" "${SSHOPTS[@]}" "$USER@$HOST" "$@"; }
vscp() { sshpass -p "$PASS" scp -P "$PORT" "${SSHOPTS[@]}" "$@"; }
# A printable prefix for the Scenario B instructions:
SSHCMD="sshpass -p $PASS ssh -p $PORT $USER@$HOST"

echo "[+] building (if needed)"
[[ -x "$HERE/watch_ptraced" && -x "$HERE/tracer_hold" ]] || zsh "$HERE/build.sh"

echo "[+] pushing binaries to ${USER}@${HOST}:${REMOTE}/"
vssh "mkdir -p ${REMOTE}"
vscp "$HERE/watch_ptraced" "$HERE/tracer_hold" "${USER}@${HOST}:${REMOTE}/"
vssh "chmod +x ${REMOTE}/watch_ptraced ${REMOTE}/tracer_hold"

echo "[+] Scenario A: P_TRACED toggle via fork + PT_TRACE_ME (hold ${HOLD}s)"
echo "    starting tracer_hold in the background on the VM..."
# tracer_hold prints CHILD_PID=<tracee> to /tmp/tracer.out, then traces it.
vssh "cd ${REMOTE} && ./tracer_hold ${HOLD} > /tmp/tracer.out 2>&1 & echo \$! > /tmp/tracer.bgpid"

# Child's pre-trace delay is 3s, so start the watcher within that window to
# capture the off -> on transition.
sleep 1
CHILD_PID=$(vssh "grep -a CHILD_PID /tmp/tracer.out | head -1 | cut -d= -f2 | tr -d '\r\n'")
if [[ -z "${CHILD_PID}" ]]; then
    echo "[!] no CHILD_PID yet; tracer_hold output:"
    vssh "cat /tmp/tracer.out"
    exit 1
fi
echo "[+] tracee pid = ${CHILD_PID}; watching P_TRACED for $((HOLD+12))s"
echo "------------------------------------------------------------"
vssh "cd ${REMOTE} && ./watch_ptraced ${CHILD_PID} $((HOLD+12)) 200" || true
echo "------------------------------------------------------------"
echo "[+] tracer_hold output:"
vssh "cat /tmp/tracer.out"
vssh "kill \$(cat /tmp/tracer.bgpid) 2>/dev/null" || true

cat <<EOF

[+] Scenario B — real PhoneControlApp + its anti-debug (manual):
    iOS has no TracerPid file, but debugserver's attach sets P_TRACED, and the
    app's inline ptrace(PT_DENY_ATTACH) makes the kernel exit(45) once P_TRACED
    is set (ENOTSUP). To demonstrate on the real app:

    1. Host:  xcrun devicectl device process launch --start-stopped \\
                 --terminate-existing --device <UDID> com.insulet.omnipod.icontroller

    2. Get the app pid on the VM:
              ${SSHCMD} "ps ax | grep -i PhoneControlApp | grep -v grep"

    3. Watch P_TRACED (will be 1 while suspended under debugserver):
              ${SSHCMD} "cd ${REMOTE} && ./watch_ptraced <APP_PID> 120 200"

    4. Host:  xcrun lldb  ->  platform select remote-ios
              ->  process connect connect://<tunnel-url>   (or device process attach)
              ->  continue                                  (app runs its anti-debug)

    5. The watcher prints:
           P_TRACED = 1  (tracer attached; p_flag=0x...)
           ... pid <APP_PID> GONE (exited/killed)
       and LLDB reports: Process <pid> exited with status = 45 (0x0000002d).
       Status 45 = ENOTSUP = the kernel killing a traced process that called
       ptrace(PT_DENY_ATTACH). That is the iOS analog of "anti-debug fires
       when TracerPid != 0".

[+] cleanup:
              ${SSHCMD} "rm -f ${REMOTE}/watch_ptraced ${REMOTE}/tracer_hold /tmp/tracer.out /tmp/tracer.bgpid"
EOF
