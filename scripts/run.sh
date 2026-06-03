#!/usr/bin/env bash
# Build & run CANTester.
#
# WSLg note: the GPU GL passthrough (d3d12) renders a blank/black window under
# WSLg — frames draw but never composite to screen. Forcing Mesa software
# rendering (llvmpipe) fixes it. Harmless on native Linux with a real GPU; unset
# CANTESTER_SOFTWARE_GL=1 there if you want hardware acceleration.
set -euo pipefail

cd "$(dirname "$0")/.."

V="${V:-$HOME/v/v}"
[ -x "$V" ] || V="v" # fall back to PATH

if [ "${CANTESTER_SOFTWARE_GL:-1}" = "1" ]; then
	export LIBGL_ALWAYS_SOFTWARE=1
	export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
fi

# First arg is the target to run; defaults to the main window.
TARGET="${1:-src/main.v}"
shift || true
exec "$V" run "$TARGET" "$@"
