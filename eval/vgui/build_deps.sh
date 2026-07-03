#!/bin/sh
# build_deps.sh — fetch cimgui + cimplot (pinned) and build libvgui_c.a next to v.mod.
# Runs unmodified on Linux/WSL AND Windows/MSYS2 (verified: plain git + g++). On Windows use
# the dedicated MSYS2 MINGW64 shell; then build the example with build_win.sh. Run from anywhere:
#   sh eval/vgui/build_deps.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BLD="$HERE/build"
mkdir -p "$BLD"

# --- pinned deps (imgui 1.92.8; ImPlot). Same commits the Linux spike validated. ---
CIMGUI_REPO=https://github.com/cimgui/cimgui.git
CIMGUI_REV=053280dfff63a74cc56a3e493671bee4bb6c60e4      # imgui submodule -> b61e563 (1.92.8), docking
CIMPLOT_REPO=https://github.com/cimgui/cimplot.git
CIMPLOT_REV=999ce3e173aa0d7b5a3d08d6727dda028b7e8e25     # implot submodule -> 1351ab2

clone_pin() { # url rev dir
	if [ ! -d "$3/.git" ]; then
		git clone --recursive "$1" "$3"
	fi
	git -C "$3" fetch --recurse-submodules origin "$2" 2>/dev/null || true
	git -C "$3" checkout "$2" 2>/dev/null || true
	git -C "$3" submodule update --init --recursive
}
clone_pin "$CIMGUI_REPO"  "$CIMGUI_REV"  "$BLD/cimgui"
clone_pin "$CIMPLOT_REPO" "$CIMPLOT_REV" "$BLD/cimplot"

CIMGUI="$BLD/cimgui"; IMGUI="$CIMGUI/imgui"; CIMPLOT="$BLD/cimplot"
INC="-I$CIMGUI -I$IMGUI -I$IMGUI/backends -I$CIMPLOT -I$CIMPLOT/implot -I$HERE"

# CRITICAL: every TU must share the SAME imgui config, or sizeof(ImGuiIO) differs across
# objects and imgui aborts at startup ("Mismatched struct layout!"). Keep this flag set
# identical for core, backends, cimplot, AND the glue.
CFG="-O2 -fno-threadsafe-statics -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1 -DIMGUI_DEFINE_MATH_OPERATORS $INC"

echo "compiling imgui core + cimgui + cimplot + backends + glue ..."
cd "$BLD"
g++ $CFG -c \
	"$IMGUI/imgui.cpp" "$IMGUI/imgui_draw.cpp" "$IMGUI/imgui_tables.cpp" "$IMGUI/imgui_widgets.cpp" \
	"$CIMGUI/cimgui.cpp" \
	"$CIMPLOT/cimplot.cpp" "$CIMPLOT/implot/implot.cpp" "$CIMPLOT/implot/implot_items.cpp" \
	"$IMGUI/backends/imgui_impl_glfw.cpp" "$IMGUI/backends/imgui_impl_opengl3.cpp" \
	"$HERE/vgui_glue.cpp"
ar rcs "$HERE/libvgui_c.a" *.o
echo "built $HERE/libvgui_c.a"
echo "run: v -path \"@vlib|@vmodules|eval\" run eval/vgui/examples/trace_chart/trace_chart.v"
