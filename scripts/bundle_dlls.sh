#!/bin/bash
# Copy the mingw runtime DLLs cantester.exe depends on next to the exe, so it
# runs from any shell / by double-click without C:\dev\msys64-ct\mingw64\bin on PATH.
# Run from MSYS2 (MINGW64): bash scripts/bundle_dlls.sh
set -e
cd "$(dirname "$0")/.."
exe="build/cantester.exe"
[ -f "$exe" ] || { echo "no $exe (build first)"; exit 1; }
n=0
ldd "$exe" | grep -i 'mingw64' | awk '{print $3}' | sort -u | while read -r f; do
  if [ -f "$f" ]; then cp -f "$f" build/; echo "  $(basename "$f")"; fi
done
echo "bundled mingw DLLs into build/"
