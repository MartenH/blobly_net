#!/usr/bin/env bash
# Build & run CANTester.
#
# Graphics: hardware GL is the DEFAULT and works on Ubuntu 24.04 + Mesa 24.x/25.x
# under WSLg (verified 2026-06-03 on Mesa 25.2.8 — OpenGL 4.5). Set
# CANTESTER_SOFTWARE_GL=1 to force Mesa software rendering (llvmpipe) — was needed
# on older Mesa (22.04's 23.2 rendered a blank/black window: the d3d12 GL
# passthrough drew frames but never composited). Software GL stays a fine fallback
# for this 2D app if hardware GL ever regresses.
set -euo pipefail

cd "$(dirname "$0")/.."

V="${V:-$HOME/v/v}"
[ -x "$V" ] || V="v" # fall back to PATH

if [ "${CANTESTER_SOFTWARE_GL:-0}" = "1" ]; then
	export LIBGL_ALWAYS_SOFTWARE=1
	export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
fi

# First arg is the target to run; defaults to the main window.
TARGET="${1:-src/main.v}"
shift || true

# Local modules live in ./modules — add it to V's lookup order (which -path
# otherwise replaces, so the defaults @vlib|@vmodules must be re-listed).
exec "$V" -path "@vlib|@vmodules|modules" run "$TARGET" "$@"
