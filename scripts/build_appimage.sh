#!/bin/sh
# Build the Linux AppImage: one file, chmod +x, runs — no `apt install` first.
#
# WHY THIS EXISTS (#322). The tarball is a dynamically linked binary, so a user who downloads a
# release and runs it gets
#
#   ./blobly_net: error while loading shared libraries: libglfw.so.3: cannot open shared object
#
# from the dynamic linker, BEFORE main(), where the program cannot say anything useful. The
# remedy was documented in a README nobody has reason to open. An AppImage carries the libraries
# instead of asking for them.
#
# NO APP CHANGES ARE NEEDED, which was the open question: cmd/blobly_net/main.v already
# re-anchors to os.dir(os.executable()) when `projects/` is not in the cwd, so the payload beside
# the binary inside the mount is found; and everything the app WRITES — the session log
# ($XDG_STATE_HOME) and settings + layout ($XDG_CONFIG_HOME) — is in the user's home, never in
# the bundle. Verified by running the built AppImage and from a chmod -R a-w copy of the tarball.
#
#   usage: scripts/build_appimage.sh <staged-bundle-dir> <version>
set -e
# NO FUSE ANYWHERE. linuxdeploy and appimagetool are themselves AppImages, and mounting one needs
# libfuse2 — which ubuntu-24.04 runners do not have under that name, and which a container may not
# allow at all. Extract-and-run unpacks to a temp dir instead. It also applies to the image we
# build below, so the smoke test at the end needs no FUSE either.
export APPIMAGE_EXTRACT_AND_RUN=1

src="$1"
ver="$2"
[ -n "$src" ] && [ -n "$ver" ] || { echo "usage: build_appimage.sh <staged-bundle-dir> <version>" >&2; exit 2; }
[ -x "$src/blobly_net" ] || { echo "no blobly_net in $src" >&2; exit 1; }
cd "$(dirname "$0")/.."
root="$(pwd)"

work="${APPIMAGE_WORK:-build/appimage}"
rm -rf "$work"
mkdir -p "$work/AppDir/usr/bin"

# The whole bundle payload goes BESIDE the binary, which is where the exe-dir anchor looks.
cp -r "$src/." "$work/AppDir/usr/bin/"
# README.txt tells a tarball user to unpack and cd; inside an AppImage it is noise.
rm -f "$work/AppDir/usr/bin/README.txt"

cp "$root/packaging/appimage/blobly_net.desktop" "$work/blobly_net.desktop"
cp "$root/packaging/appimage/blobly_net.png" "$work/blobly_net.png"

# linuxdeploy resolves the binary's shared libraries, copies them into the AppDir and rewrites
# the rpath. It applies the AppImage excludelist, which deliberately leaves out the graphics
# driver stack (libGL, libGLX, libGLdispatch, libX11) — a bundled libGL would be the wrong one
# for the user's GPU — and libfreetype, which conflicts with the host fontconfig stack and is
# present on any system with a desktop. libglfw.so.3, the one that actually goes missing, IS
# bundled.
ld="${LINUXDEPLOY:-$work/linuxdeploy.AppImage}"
if [ ! -x "$ld" ]; then
	curl -sSLf -o "$ld" https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
	chmod +x "$ld"
fi

out="blobly_net-v${ver}-x86_64.AppImage"
rm -f "$out"
( cd "$work" && ARCH=x86_64 OUTPUT="$root/$out" "$ld" \
	--appdir AppDir \
	-e AppDir/usr/bin/blobly_net \
	-d blobly_net.desktop \
	-i blobly_net.png \
	--output appimage )

[ -f "$out" ] || { echo "linuxdeploy produced no $out" >&2; exit 1; }
chmod +x "$out"

# THE BUNDLED LIBRARIES' LICENCES, DERIVED FROM WHAT LANDED IN THE AppDir — the same rule #318
# settled for the Windows DLLs, applied to the .so files linuxdeploy copied in. An AppImage is a
# distribution like any other: whatever travels inside it needs its notice travelling with it.
# dpkg tells us which package owns each one; Debian keeps the text at
# /usr/share/doc/<pkg>/copyright. Derived, never a hand-kept list — every gap #318 found came
# from a list somebody maintained.
lic="$work/AppDir/usr/bin/licenses"
mkdir -p "$lic"
for so in "$work"/AppDir/usr/lib/*.so*; do
	[ -e "$so" ] || continue
	# BY SONAME, not by path: linuxdeploy COPIED these into the AppDir, so the file here is
	# owned by no package and `dpkg -S` on it finds nothing. The name is what identifies it.
	base="$(basename "$so")"
	pkg="$(dpkg -S "*/$base" 2>/dev/null | head -1 | cut -d: -f1)"
	[ -n "$pkg" ] || { echo "build_appimage: no owning package for $(basename "$so")" >&2; exit 1; }
	cp="/usr/share/doc/$pkg/copyright"
	[ -f "$cp" ] || { echo "build_appimage: no copyright file for $pkg ($(basename "$so"))" >&2; exit 1; }
	cp "$cp" "$lic/$pkg-copyright.txt"
done
echo "staged licences for $(ls "$work"/AppDir/usr/lib/*.so* 2>/dev/null | wc -l) bundled librar(y|ies)"

# THE POINT OF THE EXERCISE, ASSERTED. If libglfw is not inside, this AppImage fails on exactly
# the system the issue was reported from, and we would not find out until a user said so again.
if ! find "$work/AppDir" -name 'libglfw.so.*' | grep -q .; then
	echo "build_appimage: libglfw is not bundled — the AppImage would fail like the tarball" >&2
	exit 1
fi

# AND IT RUNS. A built file that cannot start is the failure this whole change exists to prevent,
# so the build does not claim success without executing the thing it just made.
got="$("$root/$out" --version 2>&1 | head -1)" || {
	echo "build_appimage: the AppImage does not run: $got" >&2
	exit 1
}
[ "$got" = "blobly_net $ver" ] || {
	echo "build_appimage: expected 'blobly_net $ver', got '$got'" >&2
	exit 1
}
echo "built $out — runs, says '$got'"
