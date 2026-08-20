#!/bin/sh
# run_gui.sh — build + run the GUI app (cmd/blobly_net) on Linux/WSL AND Windows.
# Dear ImGui + ImPlot + FreeType, via the `vgui` binding in libs/vgui.
#
# ONE script for both platforms. On Windows run it through the dedicated MSYS2 bash as a
# LOGIN shell (so coreutils are on PATH), keeping the repo cwd via CHERE_INVOKING:
#   CHERE_INVOKING=1 MSYSTEM=MSYS <repo>/../msys64-ct/usr/bin/bash.exe --login -c ./scripts/run_gui.sh
# (the VS Code "Run GUI" task does exactly this). On Linux/WSL just run it directly.
#
#   scripts/run_gui.sh                       # build + run (driver-free sim by default)
#   DEPS=1 scripts/run_gui.sh                # rebuild libvgui_c.a FIRST — REQUIRED after any
#                                             #   libs/vgui/{vgui.h,vgui_glue.cpp} change, else
#                                             #   the link fails with 'undefined reference to vgui_*'
#   RUN=0 scripts/run_gui.sh                 # build only -> build/blobly_net[.exe]
#   DBG=1 RUN=0 scripts/run_gui.sh           # build with -g (asserts on) for gdb
#   DEPS=1 scripts/run_gui.sh                # force-rebuild libs/vgui/libvgui_c.a first
#   BLOBLY_PROJECT=projects/doip-demo.blobnet scripts/run_gui.sh
#
# Prereqs (one-time) — these mirror what CI installs on a clean runner; see the README's
# Dependencies section, and .github/workflows/{ci,windows}.yml as the source of truth:
#   Linux/WSL : sudo apt install g++ pkg-config libglfw3-dev libfreetype-dev libgl1-mesa-dev
#   Windows   : the dedicated C:\dev\msys64-ct with
#               pacman -S --needed git mingw-w64-x86_64-{gcc,pkgconf,glfw,freetype,\
#                                  harfbuzz,glib2,fribidi,fontconfig}
set -e
# On Windows run this from a MSYS2 login/MINGW64 context so coreutils + gcc are on PATH
# (the VS Code tasks launch `bash -l`; or use the C:\dev\msys64-ct MINGW64 shell directly).
# Capture the CALLER's directory before moving: a project path given on the command line is
# relative to where the user ran this from, not to the repo root (codex #65 r4).
CALLER_PWD="$PWD"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
# Convenience: if the first arg is a .blobnet project (not a .v target), open THAT
# project instead of the sim-demo default. So `run_gui.sh path/to/system_full.blobnet`
# launches straight into that system. A .v arg still overrides the target as before.
target="${1:-cmd/blobly_net/}"
case "$target" in
	*.blobnet)
		# resolve against the caller's directory, since we have already cd'd to the repo root
		case "$target" in
		/*) ;;
		*) target="$CALLER_PWD/$target" ;;
		esac
		export BLOBLY_PROJECT="$target"
		target="cmd/blobly_net/"
		;;
esac

# --- platform: pin the dedicated mingw toolchain + v.exe on Windows/MSYS2 --------------
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		# Dedicated toolchain lives BESIDE the repo (…/msys64-ct and …/v, per the project's
		# the C:\dev layout convention — repo at C:\dev\blobly_net, MSYS2 at C:\dev\msys64-ct).
		# Derive from the repo's parent so it's not a hard C:\dev assumption; override with
		# MSYS2_CT= / V= if yours live elsewhere.
		parent="$(cd "$HERE/.." && pwd)"
		ct="${MSYS2_CT:-$parent/msys64-ct}"
		export PATH="$ct/mingw64/bin:$PATH"                # gcc + static glfw/freetype libs
		export TMP="${TMP:-/tmp}" TEMP="${TEMP:-/tmp}"     # writable temp (not C:\Windows) for gcc
		V="${V:-$parent/v/v.exe}"
		[ -x "$V" ] || V=v                                 # fall back to `v` on PATH
		;;
	*)
		V="${V:-v}"
		;;
esac

# 1. C deps: imgui + ImPlot + GLFW + FreeType -> libs/vgui/libvgui_c.a. Build if missing/DEPS=1.
if [ "${DEPS:-0}" = "1" ] || [ ! -f libs/vgui/libvgui_c.a ]; then
	echo "== building libs/vgui/libvgui_c.a (imgui+implot+glfw+freetype) =="
	sh libs/vgui/build_deps.sh
fi

# 1.5 the C++ glue is linked as a PREBUILT archive — V won't notice when the .cpp changes, and a
#     stale archive against a changed call signature is an instant segfault. Rebuild when newer.
if [ libs/vgui/vgui_glue.cpp -nt libs/vgui/libvgui_c.a ] || [ libs/vgui/vgui.h -nt libs/vgui/libvgui_c.a ]; then
	echo "vgui_glue.cpp/vgui.h newer than libvgui_c.a — rebuilding the archive"
	bash libs/vgui/build_deps.sh
fi

# 2. build (+ run). V's #flags (libs/vgui/vgui.v) carry the whole link line; in-proc bus
#    needs -enable-globals. DBG=1 adds -g (source-level symbols for gdb).
set -- -cc gcc -enable-globals -path "@vlib|@vmodules|modules|libs"
[ "${DBG:-0}" = "1" ] && set -- "$@" -g
if [ "${RUN:-1}" = "0" ]; then
	mkdir -p build
	out="build/blobly_net"
	[ "${DBG:-0}" = "1" ] && out="build/blobly_net_dbg"
	exec "$V" "$@" -o "$out" "$target"
else
	export BLOBLY_PROJECT="${BLOBLY_PROJECT:-projects/sim-demo.blobnet}"
	exec "$V" "$@" run "$target"
fi
