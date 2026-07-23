# vphone Setup & Debugging Runbook

Consolidated record of the variant build flow, the tweaks applied during this work
(Bluetooth availability + debugging enablement), and why first-time debugging failed.

## 1. Variants and how to build each

Five firmware variants — mutually exclusive. Each has a **boot-chain** patch step
(`fw_patch_*`, writes kernelcache/TXM). Regular/dev/jb/exp additionally run a **CFW**
install step (`cfw_install_*`, writes files into `Disk.img` while the VM is off);
Patchless skips `cfw_install` and builds its merged rootfs offline in `fw_patch_less`.

| Variant   | AIO setup                | Boot chain        | CFW install          | Purpose                                              |
| --------- | ------------------------ | ----------------- | -------------------- | ---------------------------------------------------- |
| Patchless | `make setup_machine LESS=1` | `make fw_patch_less` | *(none — `boot_less`)* | Minimal; closest to stock; relies on host `amfidont -S` |
| Regular   | `make setup_machine`     | `make fw_patch`   | `make cfw_install`   | Baseline CFW; trustcache bypass only                 |
| Dev       | `make setup_machine DEV=1` | `make fw_patch_dev` | `make cfw_install_dev` | + debug TXM + debugserver entitlements + rpcserver |
| Jailbreak | `make setup_machine JB=1`  | `make fw_patch_jb`  | `make cfw_install_jb`  | + jetsam fix + procursus + basebin                  |
| Experimental | `make setup_machine EXP=1` | `make fw_patch_exp` | `make cfw_install_exp` | JB + hv_vmm rename / DT identity / build spoof     |

`JB=1 / DEV=1 / EXP=1 / LESS=1` are mutually exclusive. Optional flags:
`SUDO_PASSWORD=...`, `INTERACTIVE=1`, `NO_BINPACK=1`, `NO_VPHONED=1`, `SPOOF_BUILD=<id>` (EXP).

### Full automated path (one command)
```bash
make setup_machine DEV=1
```
Runs `setup_tools → fw_prepare → fw_patch_dev → restore → cfw_install_dev → first boot`.

### Manual step-by-step (dev example)
```bash
make setup_tools                 # one-time tooling (brew, trustcache, insert_dylib, venv+pymobiledevice3)
make build                       # build + sign host tool (NEVER swift build alone)
make vm_new                      # create VM dir (CPU=8 MEMORY=8192 DISK_SIZE=64)
make fw_prepare                  # download + merge IPSWs (cloudOS into iPhone)
make fw_patch_dev                # patch boot chain (kernelcache + TXM dev patches)
make boot_dfu                    # boot VM in DFU mode
make restore_get_shsh            # dump SHSH from Apple
make restore                     # flash patched boot chain to device (or `make restore_offline`)
make cfw_install_dev             # install CFW into Disk.img (VM must be OFF; re-execs sudo)
make boot                        # boot GUI
```

> Boot-chain patches (fw_patch_*) require a DFU **restore** to take effect.
> CFW patches (cfw_install_*) only need a re-run of `cfw_install_*` (no restore).

---

## 2. Tweaks we applied

### 2.1 Bluetooth availability (DSC patch + TCC grant)

**Problem:** The VM has no Bluetooth controller → `bluetoothd` reports none → CoreBluetooth
returns `CBManagerStateUnsupported` (2). Apps that gate startup on Bluetooth bail before the
permission flow engages, and `authorization` stays `notDetermined`.

**Fix — two layers:**

1. **DSC patch** (offline). Rewrites two CoreBluetooth accessors in the installed
   `dyld_shared_cache_arm64e`:
   - `-[CBManager state]` → `mov w0,#5; ret` (PoweredOn)
   - `+[CBManager authorization]` → `mov w0,#3; ret` (AllowedAlways)

   Applied via two equivalent paths depending on variant:
   - **regular/dev/jb/exp** — in `cfw_install.sh` / `cfw_install_dev.sh` (host-mount
     `Disk.img` after restore). Toggle: `DISABLE_BT_DSC_PATCH=1 make cfw_install_dev`.
   - **patchless (`less`)** — in `CryptexFilesystemPatcher.mergeFilesystems()` during
     `fw_patch_less` (right after the SystemOS cryptex copy, before the volume re-seal;
     no `cfw_install` step). Toggle: `DISABLE_BT_DSC_PATCH=1 make fw_patch_less`
     (Makefile-translated to `--disable-bt-dsc-patch`).

   Idempotent in both paths. The `less` path needs no kernel/TXM SSV bypass — the patched
   DSC is baked into the re-sealed root hash + manifest.

2. **TCC grant** (runtime, via `vphoned`). The "Grant Bluetooth Permission" menu makes
   `vphoned` write a row to `/private/var/mobile/Library/TCC/TCC.db`
   (`BluetoothAlways` + `BluetoothPeripheral`). `vphoned` can do this because it carries
   private entitlements (`container-manager`, `storage.AppDataContainers`,
   `rootless.datavault.metadata`); root over SSH cannot (no entitlements + data protection).

**Reality check — this is a facade.** There is no BT radio, no `VZBluetoothDevice` in the VM
config, and no DeviceTree BT controller node. `BluetoothManager.framework` (private,
IOKit-backed) reports `available=0 / enabled=0 / powered=0`. Apps pass the
state/authorization gate, but real BLE scan/connect/advertise cannot work. Verify via
Connect menu → **Bluetooth Status** (CoreBluetooth line = the lie; BluetoothManager line =
the truth).

### 2.2 Debugging enablement (three layers)

**Layer A — boot chain** (`fw_patch_dev` → `TXMDevPatcher`, 5 patches beyond trustcache bypass):

| Patch ID                         | Effect                                                        |
| -------------------------------- | ------------------------------------------------------------- |
| `txm_dev.selector24_bypass_*`    | selector24 handler returns 0xA1 (PASS) immediately            |
| `txm_dev.get_task_allow`         | `get-task-allow` check BL → `mov x0,#1` (always true)         |
| `txm_dev.sel42_29_*`             | selector42\|29 shellcode hook + manifest flag force           |
| `txm_dev.debugger_entitlement`   | `com.apple.private.cs.debugger` BL → `mov w0,#1` (always true)|
| `txm_dev.developer_mode_bypass`  | NOP the developer-mode guard before the deny-log path         |

These make `get-task-allow` honored and `task_for_pid` usable for debuggable processes.

**Layer B — CFW** (`cfw_install_dev.sh`):
- **debugserver entitlement patch** (`scripts/cfw_install_dev.sh:265-277`): removes
  `seatbelt-profiles` (unsandboxed) and adds `task_for_pid-allow`, then re-signs with `ldid`.
- **dev overlay**: replaces `rpcserver_ios` in `iosbinpack64`.
- Inherits the CoreBluetooth DSC patch from the base run.

**Layer C — attach-time** (runtime, no patch):
- Launch the app suspended: `xcrun devicectl device process launch ... --start-stopped`.
- Attach LLDB via `process connect` to `debugserver` **before** the app's anti-debug runs.
- The app's anti-debug = inline `ptrace(PT_DENY_ATTACH)` (38 `svc #26` sites) + inline
  `proc_info` (syscall 336) `P_TRACED` detection at the obfuscated function `0x100008bc0`.
  `b ptrace` never fires (it's an inline `svc`, not the symbol). Break at `0x100008bc0`
  and `thread return 0` to neutralize it.

---

## 3. Why first-time debugging didn't work

| Symptom                                              | Root cause                                                                 | Fix                                                          |
| ---------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `tfp_test` SIGKILLed at launch (exit 137)            | Boot chain was **stock** — ad-hoc cdhash not trusted, `trustcache_bypass` not active | Run `make fw_patch_dev` + DFU `restore`                      |
| `DYLD_INSERT_LIBRARIES` silently stripped            | Without `get-task-allow` forcing (dev-only TXM patch), app is `CS_RESTRICTED` → `dyld` strips `DYLD_*` | Use the **dev** variant (not regular)                        |
| `debugserver` segfaults / "lost connection" on attach | Attaching to an already-running app that called `ptrace(PT_DENY_ATTACH)` → `P_LNOATTACH` set | Launch with `--start-stopped`, attach before anti-debug runs |
| App exits 45 (`ENOTSUP`) shortly after resume        | Inline `ptrace(PT_DENY_ATTACH)` on an already-traced proc → XNU `proc_exit(ENOTSUP)`; `b ptrace` doesn't fire (inline `svc`) | Break at obfuscated `0x100008bc0`, `thread return 0`        |
| `libobjc.A.dylib is being read from process memory` | `dyld_shared_cache_arm64e` absent/mislocated in Xcode `iOS DeviceSupport` | Use classic `process connect` flow (loads DSC correctly)     |
| `less` restore hangs at `send_component("iBSS")` — bridge 100% CPU, VM idle, `Disk.img` 0B, no USB device | Two layers. (1) `less` skipped the iBSS `image4_validate_property_callback` bypass → unpatched iBSS rejects the hybrid TSS-personalized image. **(2) The persistent hang after the iBSS fix:** `vm_manifest.py` always wrote an empty `machineIdentifier` and `vm_create.sh` always regenerated `config.plist` but reused `SEPStorage` → each `setup_machine LESS=1` re-run minted a **new ECID** while keeping **stale SEPStorage** keyed to the first run's ECID → SEP fails to boot → AP iBSS never re-enumerates after the USB reset → `pymobiledevice3` `_find()` busy-polls `libusb_get_device_list` forever. The `less`/`dev` iBSS and BuildManifest are byte-identical, so the image/manifest are NOT the difference; the per-VM identity desync is. | (1) `less` now applies the base iBSS patcher (serial labels + image4-callback bypass). (2) `vm_manifest.py` now preserves an existing `machineIdentifier` (stable ECID across re-runs) and `vm_create.sh` wipes stale `SEPStorage`/`nvram.bin` on a fresh identity. To clear an already-desynced `vm-less`: `rm -f vm-less/SEPStorage vm-less/nvram.bin` then `make setup_machine LESS=1` |

**Key correction during this work:** the `get-task-allow` forcing patch is **dev-only**
(`TXMDevPatcher.patchGetTaskAllowForceTrue`), not in the regular variant. The earlier
`NoopInject.dylib` injection failed on the **regular** variant precisely because that
patch was absent → `CS_RESTRICTED` → `DYLD_INSERT_LIBRARIES` stripped. Use dev for injection
and debugging.

---

## 4. Proposed: easy on/off toggles for the debugging tweaks

Today only the Bluetooth DSC patch has a toggle (`DISABLE_BT_DSC_PATCH=1`). The debugging
tweaks are unconditional. Proposed env-var gates, modeled on the BT toggle:

| Flag (proposed)              | Layer      | Gate                                              | Cost to toggle        |
| ---------------------------- | ---------- | ------------------------------------------------- | --------------------- |
| `DISABLE_DEBUGSERVER_PATCH=1` | CFW        | Skip debugserver entitlement patch in `cfw_install_dev.sh` | Re-run `cfw_install_dev` (no restore) |
| `DISABLE_BT_DSC_PATCH=1`     | CFW        | *(already exists)* Skip CoreBluetooth DSC patch   | Re-run `cfw_install_dev` (no restore) |
| `DISABLE_TXM_DEV_PATCHES=1`  | Boot chain | Skip the 5 dev TXM patches (keep trustcache bypass only) | Re-run `fw_patch_dev` + DFU `restore` |

**Asymmetry to be aware of:** CFW-level toggles are cheap (re-run `cfw_install_*`, VM off,
seconds). Boot-chain toggles need a re-patch + DFU restore (minutes). Granular boot-chain
flags (`DISABLE_TXM_GET_TASK_ALLOW=1`, etc.) are possible but probably not worth the
complexity — a single `DISABLE_TXM_DEV_PATCHES` covers the common "regular-equivalent
boot chain" case.

> These are **proposed**, not yet implemented. Implementation touches `cfw_install_dev.sh`
> (debugserver gate) and `TXMDevPatcher.findAll()` (dev-patch gate). No new binary patches,
> so `0_binary_patch_comparison.md` needs no update unless the gates are added.

---

## 5. Is the "Grant Bluetooth Permission" menu now redundant?

**With the DSC patch ON (default build): yes, redundant for the authorization gate.**
`+[CBManager authorization]` returns `AllowedAlways` to every process regardless of whether
`TCC.db` has a row, so the app's authorization check passes with or without the menu grant.

**With the DSC patch OFF (`DISABLE_BT_DSC_PATCH=1`): no — the menu is the only lever.**
The accessor then reads the real TCC state, so the grant is needed to avoid
`notDetermined`/`denied`.

Recommendation: **keep the menu.** It's the runtime lever for the no-patch case and the
honest "real permission" path. With the patch on it's a harmless no-op for the gate. Note
that neither the menu nor the patch makes real BLE work — there is no radio.
