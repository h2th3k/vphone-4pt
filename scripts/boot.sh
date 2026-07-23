#!/bin/zsh
# boot.sh — Boot a vphone VM variant by name.
#
# regular / dev / jb / exp / regular-bt / <any-backup-name>:
#   Switch vm/ to the named backup (vm_switch) if it isn't already active,
#   then `make boot`.
# less:
#   Boot the patchless VM at vm-less/ via `make boot_less`.
#
# Usage:
#   zsh scripts/boot.sh <variant>          # boot (GUI)
#   zsh scripts/boot.sh <variant> --dfu    # boot in DFU mode (for restore)
#   zsh scripts/boot.sh --list             # list available variants
#   zsh scripts/boot.sh                    # boot whatever is in vm/
#
# One-time setup per variant (creates + flashes Disk.img, not done here):
#   regular: make setup_machine
#   dev:     make setup_machine DEV=1
#   jb:      make setup_machine JB=1
#   exp:     make setup_machine EXP=1
#   less:    make setup_machine LESS=1
# Then back it up so this script can switch to it later:
#   make vm_backup NAME=dev

set -euo pipefail

SCRIPT_DIR="${0:a:h}"
REPO_DIR="${SCRIPT_DIR:h}"
cd "${REPO_DIR}"

VM_DIR="${VM_DIR:-vm}"
LESS_DIR="${LESS_DIR:-vm-less}"
BACKUPS_DIR="${BACKUPS_DIR:-vm.backups}"

DFU=0
LIST=0
VARIANT=""

usage() {
    cat <<EOF
Usage: zsh scripts/boot.sh [--dfu] [--list] [variant]

Variants:
  regular, dev, jb, exp, regular-bt, <backup-name>
      Switch vm/ to the named backup (if not already active), then boot.
  less
      Boot the patchless VM at ${LESS_DIR}/.

Options:
  --dfu    Boot in DFU mode (for restore). Use with a variant name.
  --list   List available backups and the active vm/ identity, then exit.
  (none)   Boot whatever is currently in ${VM_DIR}/.

Examples:
  zsh scripts/boot.sh dev
  zsh scripts/boot.sh regular --dfu
  zsh scripts/boot.sh less
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dfu)  DFU=1; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1"; usage; exit 1 ;;
        *)  if [[ -z "$VARIANT" ]]; then VARIANT="$1"; else
                echo "Unexpected arg: $1"; usage; exit 1; fi; shift ;;
    esac
done

current_name() {
    [[ -f "${VM_DIR}/.vm_name" ]] && cat "${VM_DIR}/.vm_name" || true
}

list_backups() {
    if [[ ! -d "${BACKUPS_DIR}" ]]; then
        echo "  (no backups)"; return
    fi
    local found=0
    for d in "${BACKUPS_DIR}"/*/; do
        [[ -f "${d}config.plist" ]] || continue
        echo "  - $(basename "${d}")"
        found=1
    done
    [[ "$found" = 1 ]] || echo "  (no backups)"
}

if [[ "$LIST" = 1 ]]; then
    echo "=== Active vm/ identity ==="
    name="$(current_name)"; echo "  ${name:-<unnamed>}"
    echo ""
    echo "=== Backups (bootable by name) ==="
    list_backups
    echo ""
    if [[ -f "${LESS_DIR}/config.plist" ]]; then
        echo "=== Patchless ==="
        echo "  - less (${LESS_DIR}/)"
    fi
    exit 0
fi

# Guard: don't boot if a VM is already running.
if running="$(pgrep -f "vphone-cli" 2>/dev/null)" && [[ -n "$running" ]]; then
    echo "ERROR: vphone-cli appears to be running (pid: $(echo "$running" | tr '\n' ' '))."
    echo "  Stop it first (Ctrl-C in its terminal, or kill the pid)."
    exit 1
fi

boot_vm_dir() {
    local dir="$1"
    if [[ "$DFU" = 1 ]]; then
        echo "=== Booting ${dir} in DFU mode ==="
        make boot_dfu VM_DIR="${dir}"
    else
        echo "=== Booting ${dir} ==="
        make boot VM_DIR="${dir}"
    fi
}

boot_less() {
    if [[ ! -f "${LESS_DIR}/config.plist" ]]; then
        echo "ERROR: patchless VM not found at ${LESS_DIR}/."
        echo "  Set it up first: make setup_machine LESS=1"
        exit 1
    fi
    if [[ "$DFU" = 1 ]]; then
        echo "=== Booting ${LESS_DIR} in DFU mode ==="
        make boot_dfu VM_DIR="${LESS_DIR}"
    else
        echo "=== Booting ${LESS_DIR} (patchless) ==="
        make boot_less VM_DIR="${LESS_DIR}"
    fi
}

# No variant: boot whatever is in vm/.
if [[ -z "$VARIANT" ]]; then
    name="$(current_name)"
    echo "=== Active vm/ identity: '${name:-<unnamed>}' ==="
    boot_vm_dir "${VM_DIR}"
    exit 0
fi

# Patchless is a dedicated dir, not a vm/ backup.
if [[ "$VARIANT" = "less" ]]; then
    boot_less
    exit 0
fi

# regular/dev/jb/exp/<backup>: ensure vm/ holds that variant, then boot.
name="$(current_name)"
if [[ "$name" = "$VARIANT" && -f "${VM_DIR}/config.plist" ]]; then
    echo "=== '${VARIANT}' is already active in ${VM_DIR}/ ==="
    boot_vm_dir "${VM_DIR}"
    exit 0
fi

target="${BACKUPS_DIR}/${VARIANT}"
if [[ ! -d "${target}" || ! -f "${target}/config.plist" ]]; then
    echo "ERROR: No backup named '${VARIANT}' in ${BACKUPS_DIR}/."
    echo ""
    echo "Available backups:"
    list_backups
    echo ""
    echo "To create it, set up the variant then back it up, e.g.:"
    echo "  make setup_machine DEV=1 && make vm_backup NAME=dev"
    exit 1
fi

echo "=== Switching vm/ to '${VARIANT}' ==="
make vm_switch NAME="$VARIANT"
echo ""
boot_vm_dir "${VM_DIR}"
