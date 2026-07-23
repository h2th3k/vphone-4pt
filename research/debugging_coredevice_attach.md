# Debugging an app on the Dev-variant vphone via CoreDevice (LLDB attach)

Deterministic runbook for attaching LLDB to a third-party app on the vphone Dev
variant. Established after the `lldb-1700` "lost connection"/segfault rabbit hole
(see *Dead ends*). The short version: **launch the app suspended through
`devicectl --start-stopped` and attach before the app's anti-debug runs — never
attach to an already-running instance of an app that arms `PT_DENY_ATTACH`.**

> Verified 2026-07-15: the debugserver that serves the working attach is
> `/usr/libexec/debugserver` (`lldb-1700.2.2.9`), spawned by
> `/System/Developer/usr/libexec/dtdebugproxyd`. That is the **same** binary that
> segfaulted on armed instances. The debugserver version is NOT the
> differentiator. The differentiator is `P_LNOATTACH` (set by the app's
> `ptrace(PT_DENY_ATTACH)`), which `--start-stopped` avoids by attaching before
> the call runs.

## TL;DR — the working recipe

```bash
# 1. Confirm CoreDevice sees the device (paired, available)
xcrun devicectl list devices

# 2. Launch the app SUSPENDED via CoreDevice. Starts the app stopped at
#    _dyld_start, BEFORE any app code (including PT_DENY_ATTACH) runs.
xcrun devicectl device process launch --start-stopped --terminate-existing \
  --device CDBB4729-FA3E-52F4-9D23-D26F8D4CAE06 com.insulet.omnipod.icontroller

# 3. Attach IMMEDIATELY (within ~60s if not yet attached, before the
#    suspended-app watchdog kills it; once attached, lldb holds it indefinitely)
xcrun lldb
(lldb) device select CDBB4729-FA3E-52F4-9D23-D26F8D4CAE06
(lldb) device process attach -n PhoneControlApp
# fallback if -n does not resolve: get pid via `ps aux | grep PhoneControlApp`
# over ssh, then: (lldb) device process attach -p <pid>
```

Expected result:

```
Process NNN stopped
* thread #1, stop reason = signal SIGSTOP
    frame #0: 0x... dyld`_dyld_start
Target 0: (PhoneControlApp) stopped.
```

## Environment (verified 2026-07-15)

- Device: `iPhone99,11`, iOS 26.1, build **23B85**, Darwin 25.1.0
  (`xnu-12377.42.6`). CoreDevice UDID `CDBB4729-FA3E-52F4-9D23-D26F8D4CAE06`.
- Host: Xcode 26.5, `lldb-2100.0.17.203`, `devicectl` 518.33.
- App: `com.insulet.omnipod.icontroller` (Insulet OmniPod PDM), Mach-O **arm64**
  (not arm64e). Has anti-debug (`ptrace(PT_DENY_ATTACH)`) and SSL pinning.
- Variant: Dev (`cfw_install_dev.sh`). The Dev install places
  `/usr/libexec/debugserver` (`lldb-1700.2.2.9`) with `task_for_pid-allow`.
  `dtdebugproxyd` spawns THIS binary for CoreDevice attaches. It works fine for a
  suspended (unarmed) target; it segfaults only on a `P_LNOATTACH` target.

## Why this works (and the old way didn't)

The app calls `ptrace(PT_DENY_ATTACH)` (request `31`), which sets the kernel
flag `P_LNOATTACH` on its process. When a debugger then does
`ptrace(PT_ATTACHEXC)` (`14`) to attach, XNU delivers `SIGSEGV` to the
**attaching debugserver** while it is still inside the syscall → debugserver dies
→ LLDB reports `attach failed: lost connection`. This is kernel behavior; **no
debugserver version can attach to a `P_LNOATTACH` process via normal attach.**

The on-device crash reports (`debugserver-*.ips`, pulled via
`pymobiledevice3 crash ls`) all share the identical signature:

- `EXC_CRASH / SIGSEGV`, faulting thread = main.
- Faulting frame: `__ptrace` (libsystem_kernel) called from `debugserver`
  offset `0x44bd8`.
- Registers at fault: `x0 = 0xe` (`PT_ATTACHEXC`), `x19 = target pid`.
- Crashing binary UUID = `/usr/libexec/debugserver` (lldb-1700).

A bad pointer in debugserver would crash in debugserver's own code, not inside
the kernel syscall stub — so `SIGSEGV` inside `__ptrace` during `PT_ATTACHEXC`
is specifically the `P_LNOATTACH` rejection. (The same lldb-1700 attaches fine
to a suspended instance, which is why this is not a debugserver-version bug.)

The working recipe sidesteps the problem on the attach-timing axis, not the
version axis:

1. **`devicectl ... launch --start-stopped`** launches the app suspended at
   `_dyld_start`, before any app code runs. `PT_DENY_ATTACH` has not been called
   yet → `P_LNOATTACH` is not set → `ptrace(PT_ATTACHEXC)` succeeds → no
   segfault.
2. **`device process attach`** is the LLDB/CoreDevice attach path that connects
   to the `dtdebugproxyd`-spawned `debugserver`. `devicectl` is the right tool
   because it exposes `--start-stopped`; `pymobiledevice3 developer debugserver`
   does not, so it ends up attaching to an already-running (armed) instance.

`devicectl` manages its own RemoteXPC tunnel (via `remoted`); no need to run
`pymobiledevice3 remote tunneld` separately for this flow. The "Enabling
developer disk image services" line just means CoreDevice started
`dtdebugproxyd`; the debugserver remains `/usr/libexec/debugserver` (lldb-1700)
on this Dev variant — there is no separate cryptex debugserver in play.

## Dead ends — do NOT retry these

- `pymobiledevice3 developer debugserver start-server` → uses
  `/usr/libexec/debugserver` (lldb-1700). `process attach -p <pid>` on a running
  app → segfault / "lost connection" (target is `P_LNOATTACH`).
- Classic `/usr/libexec/debugserver 127.0.0.1:1234` + `pymobiledevice3 usbmux
  forward 1234 1234` + `process connect connect://127.0.0.1:1234` +
  `process attach -p <pid>` → same segfault on a `P_LNOATTACH` target.
- Attaching to an **already-running** app instance (one that has already armed
  `PT_DENY_ATTACH`) → always segfaults, regardless of debugserver version.
- Reinstalling the app / clean launches / unmounting the DDI / rebooting → does
  NOT help. The app arms `PT_DENY_ATTACH` at launch on this build; the only
  attachable state is **suspended-before-launch**.
- Moving the on-disk DSC (`~/Library/Developer/Xcode/iOS DeviceSupport/...`)
  out of the way → does NOT help (the segfault is the kernel killing
  debugserver, not DSC symbol loading).
- Treating it as a debugserver-version mismatch: **confirmed wrong**. The
  working attach used the same `/usr/libexec/debugserver` (lldb-1700) that
  segfaulted on armed instances. Do not chase a "compatible debugserver image"
  — `pymobiledevice3` is hardcoded to `LATEST_DDI_BUILD_ID = "27A5194q"` and its
  cryptex has no usable standalone debugserver anyway; the fix is
  `--start-stopped`, not a different debugserver.

## Verify which debugserver served the attach

Over ssh on the guest, while attached:

```bash
ps aux | grep -iE "debugserver|dtdebug"
/usr/libexec/debugserver --version
```

Expected: `/System/Developer/usr/libexec/dtdebugproxyd` plus
`/usr/libexec/debugserver --setsid -fd 3`; `--version` → `lldb-1700.2.2.9`.
This is fine — the app is suspended, so `P_LNOATTACH` is not set.

## Follow-up: continuing past the anti-debug to step 4

The app is stopped at `_dyld_start`; `PT_DENY_ATTACH` has not run yet. If you
`continue` with no intervention, the app calls `ptrace(PT_DENY_ATTACH)` while
being traced (`P_TRACED` set) and XNU exits it with `ENOTSUP`. Skip the call:

```
(lldb) process status                       # confirm still attached/stopped
(lldb) b ptrace                             # break on the libsystem ptrace stub
(lldb) continue
# when it hits ptrace, read the request in x0: PT_DENY_ATTACH == 31
(lldb) register read x0
# if x0 == 31, short-circuit ptrace so the syscall never runs:
(lldb) thread return 0
(lldb) continue
```

`thread return 0` makes `ptrace` return 0 without executing the `svc`, so
`P_LNOATTACH` is never set and the app does not exit. The app sees
`ptrace(PT_DENY_ATTACH)` "succeed" and continues, fully debuggable. If it hits
`ptrace` again, repeat (or script the breakpoint to auto-skip when `x0 == 31`).

Then `continue` and let the app run to its step-4 onboarding under the debugger.
The actual target of this debugging is the app's step-4 registration failure
(SSL pinning / `TWICertificateManager load (data is NULL)` /
`INSSSLPinningManager adjust (TC == nil)`); see the decoded app logs for context.

## Notes

- The app is arm64; LLDB prints
  `warning: Architecture changed from arm64e-apple-ios to arm64-apple-ios-.` —
  expected and harmless.
- Keep the vphone screen unlocked for launch/attach, or `devicectl` launch will
  fail with an `fbs_port_fail` / "device locked" error.
- Once attached, lldb holds the suspended process; the ~60s watchdog only
  applies before the first attach.
