#!/bin/zsh
# Build the iOS ptrace-demo binaries on the host (cross for arm64-apple-ios)
# and ad-hoc sign them. They run on the vphone (AMFI disabled) as root.
set -euo pipefail
HERE=${0:a:h}
SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) || {
    echo "[!] iphoneos SDK not found (need Xcode)."; exit 1
}
cd "$HERE"

echo "[+] compiling for arm64-apple-ios (SDK: $SDK)"
clang -target arm64-apple-ios -miphoneos-version-min=15.0 -isysroot "$SDK" \
      -O2 -Wall -o watch_ptraced watch_ptraced.c
clang -target arm64-apple-ios -miphoneos-version-min=15.0 -isysroot "$SDK" \
      -O2 -Wall -o tracer_hold  tracer_hold.c

echo "[+] ad-hoc signing with get-task-allow (ptrace needs it on iOS)"
codesign -f -s - --entitlements "$HERE/debugger.entitlements" watch_ptraced tracer_hold

echo "[+] built:"
file watch_ptraced tracer_hold
echo "[+] done. Now run: ./demo_ios.sh"
