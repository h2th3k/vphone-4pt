#!/bin/zsh
# check_prerequisites.sh — Verify the host can run `make setup_machine` from a
# fresh clone. Complements boot_host_preflight.sh (which checks the signed
# binary launchability) by covering the from-scratch prerequisites: macOS
# version, nested-VM guard, SIP / research-guests / AMFI bypass, brew deps,
# and git submodules.
#
# Usage: zsh scripts/check_prerequisites.sh
# Exit: 0 if all HARD prerequisites pass, 1 if any fails.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

PASS=0
FAIL=0
WARN=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
no()   { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "=== Prerequisites check (for make setup_machine) ==="
echo "  repo: $PROJECT_ROOT"
echo ""

# --- 1. macOS version >= 15 (Sequoia) for PV=3 ---
echo "## macOS version (>= 15)"
MAJOR="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
if [[ -n "${MAJOR:-}" ]] && (( MAJOR >= 15 )); then
  ok "macOS $(sw_vers -productVersion) (Build $(sw_vers -buildVersion))"
else
  no "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') — needs 15+ (Sequoia) for PV=3"
fi
echo ""

# --- 2. Not a nested Apple VM ---
echo "## Host is not a nested Apple VM"
HV_VMM="$(sysctl -n kern.hv_vmm_present 2>/dev/null || true)"
MODEL="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ {print $2; exit}')"
if [[ "$HV_VMM" == "1" || "$MODEL" == "Apple Virtual Machine 1" ]]; then
  no "nested Apple VM detected (model=${MODEL:-?}, kern.hv_vmm_present=${HV_VMM:-?}) — Virtualization.framework guest boot is unavailable here"
else
  ok "bare-metal host (model=${MODEL:-?}, kern.hv_vmm_present=${HV_VMM:-0})"
fi
echo ""

# --- 3. SIP status ---
echo "## SIP status"
SIP_STATUS="$(csrutil status 2>/dev/null || true)"
echo "  $SIP_STATUS"
if echo "$SIP_STATUS" | grep -qi 'disabled'; then
  ok "SIP is disabled (Option 1 path)"
else
  warn "SIP is not fully disabled — Option 2 needs 'csrutil enable --without debug' + amfidont/amfree"
fi
echo ""

# --- 4. allow-research-guests enabled ---
echo "## allow-research-guests"
RG_STATUS="$(csrutil allow-research-guests status </dev/null 2>/dev/null || true)"
echo "  $RG_STATUS"
if echo "$RG_STATUS" | grep -qi 'enabled'; then
  ok "research guests enabled"
else
  no "research guests NOT enabled — run in Recovery: csrutil allow-research-guests enable"
fi
echo ""

# --- 5. AMFI bypass active (Option 1 boot-arg OR Option 2 amfidont/amfree) ---
echo "## AMFI bypass"
CUR_BOOTARGS="$(sysctl -n kern.bootargs 2>/dev/null || true)"
NEXT_BOOTARGS="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//' || true)"
AMFI_OK=0
if [[ "$CUR_BOOTARGS" == *"amfi_get_out_of_my_way=1"* ]]; then AMFI_OK=1; fi
if [[ "$NEXT_BOOTARGS" == *"amfi_get_out_of_my_way=1"* ]]; then AMFI_OK=1; fi
if pgrep -f 'amfidont' >/dev/null 2>&1 || pgrep -f 'amfree' >/dev/null 2>&1; then AMFI_OK=1; fi
echo "  current boot-args: ${CUR_BOOTARGS:-<none>}"
echo "  next-boot boot-args: ${NEXT_BOOTARGS:-<none>}"
if (( AMFI_OK == 1 )); then
  ok "AMFI bypass active (amfi_get_out_of_my_way=1 in boot-args, or amfidont/amfree running)"
else
  no "no AMFI bypass detected — set 'sudo nvram boot-args=\"amfi_get_out_of_my_way=1 -v\"' (Option 1) or run amfidont/amfree (Option 2)"
fi
echo ""

# --- 6. brew dependencies ---
echo "## brew dependencies"
DEPS=(aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw zstd)
INSTALLED="$(brew list --formula -1 2>/dev/null || true)"
for d in "${DEPS[@]}"; do
  if echo "$INSTALLED" | grep -qx "$d"; then
    ok "brew: $d"
  else
    no "brew: $d — missing (brew install $d)"
  fi
done
echo ""

# --- 7. git submodules initialized (non-empty) ---
echo "## git submodules"
SUBMODULES=(
  vendor/Dynamic
  vendor/swift-argument-parser
  vendor/libcapstone-spm
  vendor/libimg4-spm
  vendor/MachOKit
  scripts/repos/trustcache
  scripts/repos/insert_dylib
  scripts/resources
)
for s in "${SUBMODULES[@]}"; do
  if [[ ! -d "$s" ]]; then
    no "submodule missing: $s — run: git submodule update --init --recursive"
  elif [[ -z "$(ls -A "$s" 2>/dev/null)" ]]; then
    no "submodule empty: $s — run: git submodule update --init --recursive"
  else
    ok "submodule populated: $s"
  fi
done
echo ""

# --- 8. Optional / info (not hard) ---
echo "## Optional / info"
if [[ -x .venv/bin/python3 ]]; then
  ok ".venv present (setup_tools will (re)create it if absent)"
else
  warn ".venv absent — will be created by 'make setup_tools'"
fi
if command -v gh >/dev/null 2>&1; then
  ok "gh CLI installed ($(gh --version | head -1))"
else
  warn "gh CLI not installed (only needed for repo creation/management)"
fi
if command -v ldid >/dev/null 2>&1; then
  ok "ldid on PATH (vphoned signing)"
else
  warn "ldid not on PATH — provided by 'ldid-procursus' brew dep"
fi
echo ""

# --- Verdict ---
echo "=== Verdict ==="
echo "  PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
if (( FAIL > 0 )); then
  echo ""
  echo "Prerequisites NOT met — fix the [FAIL] items above before 'make setup_machine'." >&2
  exit 1
fi
echo "All hard prerequisites met — you can run 'make setup_machine'."
exit 0
