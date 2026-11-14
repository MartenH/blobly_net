#!/bin/sh
# build_libblobly.sh [out-dir] — build the engine as a shared library with the C ABI of
# cmd/libblobly/bb.h: build/libblobly.so on Linux, build/blobly.dll on Windows (mingw, through
# the msys2 shell as windows.yml runs it). -cflags -O2, the release flavour of every shipped
# binary (run_gui.sh's RELEASE=1): decode, a DBC parse or a .log read run about twice as fast as
# at -O1. Measured on Linux: -O1 builds in ~42 s, -O2 in ~105 s; the library is 7.4 and 7.7 MB.
# Not -prod, which is -O3 plus a different program (`$if prod`, its own GC build), and buys
# nothing else here: nothing in blobly/ or cmd/libblobly is `$if prod`, and
# no $embed_file is read at run time (check_cmds.sh refuses one in cmd/blobly/libs). On Linux the
# collector linked is then V's prebuilt, thread-enabled thirdparty/tcc/lib/libgc.a (-prod compiled
# it from source); both smokes attach host threads and churn handles against what is linked.
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
"$V" $cc -enable-globals -cflags -O2 -shared -o "$lib" cmd/libblobly
echo "built $lib"
