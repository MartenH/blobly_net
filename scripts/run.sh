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

# Native file dialogs: the app itself detects WSL and defaults GUI_NO_PORTAL=1
# there (gui's XDG Desktop Portal path hangs the UI thread under WSLg — see
# src/main.v is_wsl() + docs/known_issues.md). No env setup needed here. To force
# either backend regardless of platform, set GUI_NO_PORTAL=1 (zenity) or =0 (portal).

# First arg is the target to run; defaults to the main window.
TARGET="${1:-src/main.v}"
shift || true

# Local modules live in ./modules — add it to V's lookup order (which -path
# otherwise replaces, so the defaults @vlib|@vmodules must be re-listed).
# -enable-globals: the in-process bus (transport/inproc.v) uses a process-global
# registry so independent open('inproc:…') calls share one medium.
exec "$V" -enable-globals -path "@vlib|@vmodules|modules" run "$TARGET" "$@"
