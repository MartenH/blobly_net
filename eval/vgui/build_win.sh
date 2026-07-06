#!/bin/sh
# build_win.sh — build the trace_chart example on Windows (mingw / MSYS2 MINGW64).
# Run from the dedicated MSYS2 MINGW64 shell (gcc + glfw on PATH). Run from anywhere:
#   sh eval/vgui/build_win.sh
#
# WHY A 2-STEP BUILD (not the one-liner `v -cc gcc run`)? V 0.5.1 (c0624b2) panics on
# Windows inside os.execute while driving the C compiler for this target
# ("array.push_many: new len exceeds max_int" in os__windows_execute_command_line) —
# reproducible from both MSYS bash and PowerShell, independent of shell. The C compile and
# link themselves are correct, so we drive them ourselves: V emits the C (`-o …c`), then we
# compile+link with the mingw gcc/g++. Revisit the one-liner on a newer V (this is a V bug,
# not a vgui one). See docs/gui_toolkit_evaluation.md.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BLD="$HERE/build"
V="${V:-/c/dev/v/v.exe}"
EXAMPLE="$HERE/examples/trace_chart/trace_chart.v"
OUT="$HERE/examples/trace_chart/trace_chart.exe"

[ -f "$HERE/libvgui_c.a" ] || { echo "libvgui_c.a missing — run build_deps.sh first"; exit 1; }
mkdir -p "$BLD"

echo "1/3  V -> C ($EXAMPLE)"
# -gc none keeps the link deps minimal for the spike (no libgc); the app proper would use
# V's default GC. -cc gcc so the generated C is C (g++ rejects V's char**/named-struct casts).
"$V" -cc gcc -gc none -path "@vlib|@vmodules|eval" -o "$BLD/trace_chart.c" "$EXAMPLE"

echo "2/3  gcc -c (compile the generated C)"
gcc -c "$BLD/trace_chart.c" -o "$BLD/trace_chart.o" \
	-fwrapv -std=c99 -D_DEFAULT_SOURCE -municode -I"$HERE"

echo "3/3  g++ link (C++ archive: imgui/implot/glfw)"
# Link libs MIRROR the `#flag windows` line in vgui.v (keep them in sync). Static glfw +
# static libstdc++/libgcc => self-contained exe (only system DLLs).
g++ "$BLD/trace_chart.o" "$HERE/libvgui_c.a" \
	-municode -Wl,-stack=33554432 -static -static-libstdc++ -static-libgcc \
	-l:libglfw3.a -lopengl32 -lgdi32 -limm32 -lshell32 -luser32 -lws2_32 -ladvapi32 -ldbghelp \
	-o "$OUT"

echo "built $OUT"
echo "run: $OUT      (event-driven; VGUI_POLL=1 for a 60fps poll loop)"
