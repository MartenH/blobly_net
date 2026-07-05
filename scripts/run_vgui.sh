#!/bin/sh
# run_vgui.sh — build + run the vgui-migration app (cmd/blobly_vgui) on Linux/WSL AND Windows.
# This is the Dear ImGui + ImPlot + FreeType port; it does NOT use vlang/gui.
#
# ONE script for both platforms. On Windows run it through the dedicated MSYS2 bash:
#   C:\dev\msys64-ct\usr\bin\bash.exe -c "sh scripts/run_vgui.sh"
# (the VS Code "vgui: …" tasks do this for you). On Linux/WSL just run it directly.
#
#   scripts/run_vgui.sh                       # build + run (driver-free sim by default)
#   RUN=0 scripts/run_vgui.sh                 # build only -> build/blobly_vgui[.exe]
#   DEPS=1 scripts/run_vgui.sh                # force-rebuild eval/vgui/libvgui_c.a first
#   BLOBLY_PROJECT=projects/doip-demo.blobnet scripts/run_vgui.sh
#
# Prereqs (one-time):
#   Linux/WSL : sudo apt install libglfw3-dev   (freetype2 dev is already a project dep)
#   Windows   : the dedicated C:\dev\msys64-ct with
#               pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-glfw \
#                                  mingw-w64-x86_64-freetype git
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
target="${1:-cmd/blobly_vgui/main.v}"

# --- platform: pin the dedicated mingw toolchain + v.exe on Windows/MSYS2 --------------
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		# Dedicated toolchain lives BESIDE the repo (…/msys64-ct and …/v, per the project's
		# docs/windows_build.md convention — repo at C:\dev\blobly_net, MSYS2 at C:\dev\msys64-ct).
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

# 1. C deps: imgui + ImPlot + GLFW + FreeType -> eval/vgui/libvgui_c.a. Build if missing/DEPS=1.
if [ "${DEPS:-0}" = "1" ] || [ ! -f eval/vgui/libvgui_c.a ]; then
	echo "== building eval/vgui/libvgui_c.a (imgui+implot+glfw+freetype) =="
	sh eval/vgui/build_deps.sh
fi

# 2. build (+ run). V's #flags (eval/vgui/vgui.v) carry the whole link line; in-proc bus
#    needs -enable-globals.
set -- -cc gcc -enable-globals -path "@vlib|@vmodules|modules|eval"
if [ "${RUN:-1}" = "0" ]; then
	mkdir -p build
	exec "$V" "$@" -o build/blobly_vgui "$target"
else
	export BLOBLY_PROJECT="${BLOBLY_PROJECT:-projects/sim-demo.blobnet}"
	exec "$V" "$@" run "$target"
fi
