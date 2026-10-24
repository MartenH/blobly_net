#!/bin/sh
# build_canbridge.sh [out-dir] — build the canbridge the Windows app and wheel carry into WSL
# (cmd/canbridge, docs/wsl_bridge.md): <out-dir>/canbridge, a STATIC x86-64 Linux program against
# musl, so it runs in a distribution of any age and package set (#503), and <out-dir>/musl-LICENSE.txt,
# the notice of the libc compiled into it. musl rather than a static glibc: glibc is LGPL, and a
# static link would ask of the distributor what the Windows bundle's dynamic DLLs do not (#318).
# canbridge does no name lookups (SocketCAN, and TCP to the address it is given), so no NSS is
# missed. Needs musl-gcc (Debian/Ubuntu: musl-tools) and the kernel headers (linux-libc-dev).
#
#   V=/path/to/v   the compiler (default: `v` on PATH)
set -e
cd "$(dirname "$0")/.."
out="${1:-build}"
V="${V:-v}"
command -v musl-gcc >/dev/null || { echo "build_canbridge: no musl-gcc (apt-get install musl-tools)" >&2; exit 1; }
mkdir -p "$out"
# musl's include path has no kernel headers; linux/can.h and its asm come from the system's.
hdr="$(mktemp -d)"
trap 'rm -rf "$hdr"' EXIT
asm="/usr/include/$(gcc -print-multiarch)/asm"
for d in /usr/include/linux /usr/include/asm-generic "$asm"; do
	[ -d "$d" ] || { echo "build_canbridge: no $d (apt-get install linux-libc-dev)" >&2; exit 1; }
done
ln -s /usr/include/linux "$hdr/linux"
ln -s /usr/include/asm-generic "$hdr/asm-generic"
ln -s "$asm" "$hdr/asm"
# V's prebuilt collector is glibc's, so the bundled one is compiled; musl has no getcontext.
"$V" -enable-globals -cc musl-gcc -d use_bundled_libgc \
	-cflags "-static -isystem $hdr -DNO_GETCONTEXT" -o "$out/canbridge" cmd/canbridge
if ldd "$out/canbridge" >/dev/null 2>&1; then
	echo "build_canbridge: $out/canbridge is dynamically linked" >&2
	ldd "$out/canbridge" >&2
	exit 1
fi
lic=/usr/share/doc/musl/copyright
grep -q 'License: MIT' "$lic" || { echo "build_canbridge: no musl licence at $lic" >&2; exit 1; }
cp "$lic" "$out/musl-LICENSE.txt"
"$out/canbridge" --help >/dev/null
echo "built $out/canbridge (static, musl)"
