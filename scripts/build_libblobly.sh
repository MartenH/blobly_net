#!/bin/sh
# build_libblobly.sh [out-dir] — build the engine as a shared library with the C ABI of
# cmd/libblobly/bb.h: build/libblobly.so on Linux, build/blobly.dll on Windows (mingw, through
# the msys2 shell as windows.yml runs it). -prod, because a shared library is what a host keeps
# loaded, and because V3 reads a $embed_file from the build tree outside -prod (check_cmds.sh).
#
#   V=/path/to/v   the compiler (default: `v` on PATH)
set -e
cd "$(dirname "$0")/.."
out="${1:-build}"
V="${V:-v}"
mkdir -p "$out"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) lib="$out/blobly.dll" cc="-cc gcc" ;;
*) lib="$out/libblobly.so" cc="" ;;
esac
# shellcheck disable=SC2086
"$V" $cc -enable-globals -prod -shared -o "$lib" cmd/libblobly
echo "built $lib"
