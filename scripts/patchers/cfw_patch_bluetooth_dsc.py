"""CoreBluetooth DSC patches — make the guest report a usable Bluetooth stack.

The vphone VM has no Bluetooth controller, so `bluetoothd` has nothing to
attach to and CoreBluetooth reports `CBManagerStateUnsupported` (2). Apps that
gate startup on Bluetooth (state check + authorization) bail before the
permission flow even engages — `authorization` stays `notDetermined` because
there is "nothing to authorize." Granting TCC alone does not help: the app
still reads `state == unsupported` and quits.

This patcher is the Bluetooth analog of `cfw_patch_camera_dsc.py`'s
`+[AVCaptureDevice authorizationStatusForMediaType:]` -> `Authorized` rewrite:
it patches two CoreBluetooth accessors in the dyld shared cache so every
process sees a powered-on, authorized Bluetooth stack — natively, with no
injected dylib and no jailbreak fingerprint. Applied at CFW install time with
per-page slot-hash re-attestation (same pipeline as the camera/hv_vmm DSC
patches).

Patches:

1. `-[CBManager state]` -> `mov w0, #5; ret`
   `CBManagerStatePoweredOn = 5`. `state` is declared on the `CBManager` base
   class, so this covers `CBCentralManager` too (apps reading
   `centralManager.state` or `central.state` inside
   `centralManagerDidUpdateState:` both go through this getter).

2. `+[CBManager authorization]` -> `mov w0, #3; ret`
   `CBManagerAuthorizationAllowedAlways = 3`. Mirrors the camera authorization
   gate — any process probing Bluetooth authorization gets "allowedAlways"
   without going through TCC.

Scope: this passes the state/authorization gate. It does NOT provide real
peripherals — apps that subsequently scan/connect will find nothing. Intended
for running apps whose only Bluetooth requirement is to clear the startup
gate on the VM.
"""

import os
import re
import shutil
import subprocess

try:
    from .cfw_asm import asm
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import reattest_modified_pages
except ImportError:
    from cfw_asm import asm
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import reattest_modified_pages


CB_IMAGE = "/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth"

CB_STATE_SYMBOL = "-[CBManager state]"
CB_AUTHORIZATION_SYMBOL = "+[CBManager authorization]"

# CBManagerState enum (CoreBluetooth/CBManager.h)
CB_MANAGER_STATE_POWERED_ON = 5
# CBManagerAuthorization enum
CB_MANAGER_AUTH_ALLOWED_ALWAYS = 3


def _resolve_symbols_in_image(dsc_path, image_path, wanted_symbols):
    """Resolve a set of ObjC method symbols in `image_path` against `dsc_path`
    via `ipsw dyld symaddr`. Returns {symbol: vmaddr}. Raises if any are missing.
    """
    ipsw_bin = shutil.which("ipsw")
    if not ipsw_bin:
        raise RuntimeError("`ipsw` not in PATH")
    cmd = [
        ipsw_bin, "dyld", "symaddr", dsc_path,
        "--image", image_path,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    wanted = set(wanted_symbols)
    results = {}
    for line in out.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
        m = re.match(r"\s*(0x[0-9A-Fa-f]+):\s*\([^)]+\)\s*(.+)$", line)
        if not m:
            continue
        addr, rest = m.group(1), m.group(2)
        sym = rest.rsplit("\t", 1)[0].strip() if "\t" in rest else rest.strip()
        if sym in wanted and sym not in results:
            results[sym] = int(addr, 16)
    missing = [s for s in wanted_symbols if s not in results]
    if missing:
        raise RuntimeError(
            f"could not resolve symbols in {image_path}: {missing}"
        )
    return results


def resolve_cb_symbols(dsc_path):
    """Resolve -[CBManager state] and +[CBManager authorization] in CoreBluetooth."""
    return _resolve_symbols_in_image(
        dsc_path,
        CB_IMAGE,
        [CB_STATE_SYMBOL, CB_AUTHORIZATION_SYMBOL],
    )


def _patch_accessor(chunks, vmas, symbol, new_bytes, *, dry_run=False, force=False):
    """Replace a single accessor with `new_bytes` (8 bytes: mov w0,#imm; ret)."""
    patched = []
    for sym, vma in sorted(vmas.items()):
        if sym != symbol:
            continue
        orig = chunks.bytes_at_vma(vma, 8)
        print(f"  {sym}  @ 0x{vma:X}")
        print(f"    {orig.hex()} → {new_bytes.hex()}")
        if orig == new_bytes:
            print(f"    already patched, skipping")
            continue
        if orig[:4] != b"\x7f\x23\x03\xd5" and not force:
            raise RuntimeError(
                f"{sym}: prologue not pacibsp (got {orig[:4].hex()}); use --force to override"
            )
        if not dry_run:
            chunks.write_at_vma(vma, new_bytes)
            patched.append(vma)

    if dry_run:
        print("  [DRY RUN]")
        return []

    if patched:
        diags = reattest_modified_pages(chunks, patched, verbose=True)
        print(f"  re-attested {len(diags)} page(s)")
        for vma in patched:
            if chunks.bytes_at_vma(vma, 8) != new_bytes:
                raise RuntimeError(f"post-write verify failed at 0x{vma:X}")
    return patched


def patch_cb_state_powered_on(chunks, vmas, *, dry_run=False, force=False):
    """`-[CBManager state]` -> `mov w0, #5; ret` (CBManagerStatePoweredOn)."""
    new_bytes = asm(f"mov w0, #{CB_MANAGER_STATE_POWERED_ON}\nret")
    if len(new_bytes) != 8:
        raise RuntimeError(f"expected 8 bytes, got {len(new_bytes)}")
    print(f"\n  [1/2] -[CBManager state] -> return PoweredOn")
    return _patch_accessor(chunks, vmas, CB_STATE_SYMBOL, new_bytes,
                           dry_run=dry_run, force=force)


def patch_cb_authorization_allowed(chunks, vmas, *, dry_run=False, force=False):
    """`+[CBManager authorization]` -> `mov w0, #3; ret` (AllowedAlways)."""
    new_bytes = asm(f"mov w0, #{CB_MANAGER_AUTH_ALLOWED_ALWAYS}\nret")
    if len(new_bytes) != 8:
        raise RuntimeError(f"expected 8 bytes, got {len(new_bytes)}")
    print(f"\n  [2/2] +[CBManager authorization] -> return AllowedAlways")
    return _patch_accessor(chunks, vmas, CB_AUTHORIZATION_SYMBOL, new_bytes,
                           dry_run=dry_run, force=force)


def apply_all_bluetooth_patches(chunks_dir, dsc_path, *, dry_run=False, force=False):
    """Apply every CoreBluetooth DSC patch against `chunks_dir`, resolving
    symbols against `dsc_path`."""
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] DSC: {chunks!r}")

    print(f"  [.] resolving CoreBluetooth symbols against {dsc_path}...")
    cb_vmas = resolve_cb_symbols(dsc_path)

    patch_cb_state_powered_on(chunks, cb_vmas, dry_run=dry_run, force=force)
    patch_cb_authorization_allowed(chunks, cb_vmas, dry_run=dry_run, force=force)

    print(f"\n  [+] CoreBluetooth DSC patches applied: 2/2")
    return 2


def patch_bluetooth_in_dsc(chunks_dir, dsc_path=None):
    """Entry point used by `cfw.py patch-bluetooth-dsc`."""
    if not dsc_path:
        raise RuntimeError("dsc_path is required (pass --dsc-header on the CLI)")
    return apply_all_bluetooth_patches(chunks_dir, dsc_path)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="CoreBluetooth DSC patcher")
    ap.add_argument("chunks_dir",
                    help="directory containing dyld_shared_cache_arm64e.* files")
    ap.add_argument("dsc_header",
                    help="path to the dyld_shared_cache_arm64e header (no suffix)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    apply_all_bluetooth_patches(args.chunks_dir, args.dsc_header,
                                dry_run=args.dry_run, force=args.force)
