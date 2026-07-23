# `scripts/boot.sh` — Boot a vphone VM variant by name

One script, parameterized by variant. Boots the right VM directory and (for the
`vm/`-sharing variants) switches to the requested backup automatically.

## Quick start

```bash
zsh scripts/boot.sh regular        # boot regular (GUI)
zsh scripts/boot.sh dev            # boot dev     (needs a `dev` backup — see below)
zsh scripts/boot.sh jb             # boot jailbreak (needs a `jb` backup — see below)
zsh scripts/boot.sh less           # boot patchless (vm-less/)
zsh scripts/boot.sh --list         # show what's available + active identity
zsh scripts/boot.sh                # boot whatever is currently in vm/
```

## What it actually runs

| Variant                          | VM dir     | Command (normal / DFU)                                            |
| -------------------------------- | ---------- | ----------------------------------------------------------------- |
| `regular`, `dev`, `jb`, `exp`, `<backup>` | `vm/`  | `make boot VM_DIR=vm` / `make boot_dfu VM_DIR=vm`                 |
| `less`                           | `vm-less/` | `make boot_less VM_DIR=vm-less` / `make boot_dfu VM_DIR=vm-less`  |

For the `vm/`-sharing variants, if `vm/.vm_name` already equals the requested
variant, it just boots. Otherwise it runs `make vm_switch NAME=<variant>` first
(which saves the current `vm/` under its existing name, then restores the
target backup into `vm/`), then boots.

## DFU mode — available for ALL variants

```bash
zsh scripts/boot.sh regular --dfu
zsh scripts/boot.sh dev --dfu
zsh scripts/boot.sh jb --dfu
zsh scripts/boot.sh less --dfu
```

DFU boots the VM headless and exposes the DFU USB gadget so `make restore` can
flash a patched boot chain. It is **not** regular-only.

### Why it looks regular-only in the Makefile

The Makefile exposes three boot aliases:

- `boot`      → `--config ./config.plist`              (defaults to `VM_DIR=vm`)
- `boot_less` → `--config ./config.plist --variant less`
- `boot_dfu`  → `--config ./config.plist --dfu`        (defaults to `VM_DIR=vm`)

There is no `boot_less_dfu` target, so `boot_dfu` *appears* to be regular-only.
But `boot_dfu` honors `VM_DIR=`, so `make boot_dfu VM_DIR=vm-less` puts the
patchless VM into DFU just fine. The `--variant less` flag only affects
runtime vphoned auto-update behavior (`VPhoneControl.swift`), which does not
run in DFU (no guest control channel). `boot.sh` papers over this gap: `--dfu`
works for every variant.

After booting DFU, flash the boot chain from a second terminal:

```bash
make restore VM_DIR=vm         # regular / dev / jb
make restore VM_DIR=vm-less    # patchless
```

## Backups — what the script does and does not do

`boot.sh` **does not create new backups.** It only:

1. **Boots** an existing VM dir, or
2. **Switches** `vm/` to an existing backup (via `make vm_switch`), which as a
   side effect *saves the current `vm/` state under its existing `.vm_name*`
   before swapping. That is a swap, not a fresh backup — it overwrites the
   backup of the current name.

To **create** a named backup (one-time per variant), use the Makefile directly:

```bash
make vm_backup NAME=regular
make vm_backup NAME=dev
make vm_backup NAME=jb
```

List what exists:

```bash
zsh scripts/boot.sh --list      # or: make vm_list
```

## One-time setup to make `dev` / `jb` bootable by name

`regular`/`dev`/`jb`/`exp` all share `vm/` (mutually exclusive — see
`setup_machine.sh: --jb/--dev/--exp/--less are mutually exclusive`). You can
only hold one in `vm/` at a time, so each variant must be set up once and
backed up, then switched between:

```bash
# regular (you already have `regular` and `regular-bt` backups)
make setup_machine               && make vm_backup NAME=regular

# dev
make setup_machine DEV=1         && make vm_backup NAME=dev

# jailbreak
make setup_machine JB=1          && make vm_backup NAME=jb

# patchless — lives in its own dir, no backup needed to switch
make setup_machine LESS=1 VM_DIR=vm-less
```

After that, `zsh scripts/boot.sh dev` / `jb` switch-and-boot automatically.

## Options

```
Usage: zsh scripts/boot.sh [--dfu] [--list] [variant]

  --dfu    Boot in DFU mode (for restore). Works with any variant.
  --list   List available backups + active vm/ identity, then exit.
  (none)   Boot whatever is currently in vm/.
  -h       Help.
```

## Safety

- Refuses to boot if a `vphone-cli` process is already running (avoid two VMs
  on the same `vm/`).
- Refuses to switch if the requested backup doesn't exist, and prints the
  setup/backup command you need.
