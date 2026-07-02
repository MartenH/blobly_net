#!/bin/bash
# build_win.sh — native Windows build of Blobly Net via mingw-w64 gcc (W1),
# the bash twin of build_win.ps1. RUN FROM MSYS2 (MINGW64 shell):
#
#   bash scripts/build_win.sh                 # -> build/blobly_net.exe  (GL backend)
#   bash scripts/build_win.sh -run            # build then run
#   bash scripts/build_win.sh -debug          # build with -g (asserts on) for gdb
#   BLOBLY_PROJECT=projects/demo-udp.blobnet bash scripts/build_win.sh -run
#
# Uses the DEDICATED, isolated toolchain under C:\dev (see CLAUDE.md "Windows
# build (W1)" + docs/windows_build.md). Nothing outside C:\dev is touched.
# Prereqs (one-time): C:\dev\msys64-ct (mingw-w64 gcc/pkgconf/pango/...),
# C:\dev\v\v.exe (V 0.5.1 @ de365a1), C:\dev\vmodules-ct\{gui,vglyph} (W1 patches).
#
# Why this can be simpler than the .ps1: inside MINGW64, `/mingw64` is a real
# mount onto C:\dev\msys64-ct\mingw64, so even the `-I/mingw64/...` paths V's own
# v.pkgconfig emits resolve correctly here (gotcha #2 only bites *outside* the
# shell). We still feed the system pkgconf's flags explicitly — belt and braces —
# so the build is identical to the PowerShell path.
set -e
cd "$(dirname "$0")/.."

mingw=/c/dev/msys64-ct/mingw64
export VMODULES=/c/dev/vmodules-ct
export PKG_CONFIG_PATH="$mingw/lib/pkgconfig"   # V's v.pkgconfig reads this
export PATH="$mingw/bin:$PATH"                  # gcc + pkgconf + runtime DLLs

# flags
target='src/main.v'
out='build/blobly_net.exe'
dbg=''
run=0
for a in "$@"; do
  case "$a" in
    -run|--run)     run=1 ;;
    -debug|--debug) dbg='-g' ;;
    *.v)            target="$a" ;;
    *)              echo "unknown arg: $a (want -run, -debug, or a target .v)"; exit 2 ;;
  esac
done

# vglyph's native deps. V's built-in v.pkgconfig does NOT relocate a .pc `prefix=`
# and our MSYS2 isn't at the default C:\msys64, so feed the *system* pkgconf's
# (correctly relocated) flags directly.
libs='freetype2 harfbuzz fribidi fontconfig pango pangoft2 gobject-2.0 glib-2.0'
cflags=$(pkgconf --cflags $libs)
# -ld3d11 -ldxgi: gui's nativebridge/readback_windows.c references D3D11 symbols
# unconditionally on Windows (screenshots only), so they must link even on the GL
# backend.
ldflags="$(pkgconf --libs $libs) -ld3d11 -ldxgi"

mkdir -p "$(dirname "$out")"
# -enable-globals: main.v imports the in-proc bus (transport/inproc.v __global).
/c/dev/v/v.exe -cc gcc -enable-globals $dbg -path '@vlib|@vmodules|modules' \
  -cflags "$cflags" -ldflags "$ldflags" -o "$out" "$target"

echo "BUILD OK -> $out"
# Use `if` (not `[ ] && …`): a false test as the script's last command would make
# `set -e` exit non-zero on a *successful* build when -run is absent.
if [ "$run" -eq 1 ]; then exec "./$out"; fi
