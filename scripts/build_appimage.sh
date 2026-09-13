#!/bin/sh
# Build the Linux AppImage: one file, chmod +x, runs — no `apt install` first.
#
# WHY THIS EXISTS (#322). The tarball is a dynamically linked binary, so a user who downloads a
# release and runs it gets
#
#   ./blobly_net: error while loading shared libraries: libglfw.so.3: cannot open shared object
#
# from the dynamic linker, BEFORE main(), where the program cannot say anything useful. The remedy
# was documented in a README nobody has reason to open. An AppImage carries the libraries instead
# of asking for them.
#
# NO APP CHANGES ARE NEEDED, which was the open question: cmd/blobly_net/main.v already re-anchors
# to os.dir(os.executable()) when `projects/` is not in the cwd, so the payload beside the binary
# inside the mount is found; and everything the app WRITES — the session log ($XDG_STATE_HOME) and
# settings + layout ($XDG_CONFIG_HOME) — is in the user's home, never in the bundle. Verified by
# running the built AppImage and a chmod -R a-w copy of the tarball.
#
#   usage: scripts/build_appimage.sh <staged-bundle-dir> <version>
set -e

# NO FUSE FOR THE BUILD. linuxdeploy and appimagetool are themselves AppImages, and mounting one
# needs libfuse2. The release job is pinned to ubuntu-22.04 (where that package still exists under
# its old name) and deliberately does NOT install it: extract-and-run unpacks to a temp directory,
# so the build depends on no FUSE at all and cannot break when the pin moves to a runner where the
# package was renamed — ubuntu-24.04 being exactly that. Depending on a package we do not install,
# on a host we chose for a different reason, is a coupling worth not having.
#
# THIS COVERS THE BUILD ONLY. What a user needs to run the emitted image is a separate question
# with a different answer, in the README: the type-2 runtime dlopens libfuse from their host.
export APPIMAGE_EXTRACT_AND_RUN=1

src="$1"
ver="$2"
[ -n "$src" ] && [ -n "$ver" ] || { echo "usage: build_appimage.sh <staged-bundle-dir> <version>" >&2; exit 2; }
cd "$(dirname "$0")/.."
root="$(pwd)"
case "$src" in /*) ;; *) src="$root/$src" ;; esac
[ -x "$src/blobly_net" ] || { echo "no blobly_net in $src" >&2; exit 1; }

work="${APPIMAGE_WORK:-$root/build/appimage}"
case "$work" in /*) ;; *) work="$root/$work" ;; esac
rm -rf "$work"
mkdir -p "$work/AppDir/usr/bin"

# The whole bundle payload goes BESIDE the binary, which is where the exe-dir anchor looks.
cp -r "$src/." "$work/AppDir/usr/bin/"
# README.txt tells a tarball user to unpack and cd; inside an AppImage it is noise.
rm -f "$work/AppDir/usr/bin/README.txt"

cp "$root/packaging/appimage/blobly_net.desktop" "$work/blobly_net.desktop"
cp "$root/packaging/appimage/blobly_net.png" "$work/blobly_net.png"

# PINNED AND CHECKSUMMED. The `continuous` asset is mutable: the same reviewed tag could execute
# different packaging code on a later build, which for something that assembles a published
# artifact is a supply-chain hole, not a convenience (codex round 1 on #322). A tagged release
# plus sha256 means this either runs the reviewed tool or stops.
ld_ver=1-alpha-20250213-2
ld_sha=4648f278ab3ef31f819e67c30d50f462640e5365a77637d7e6f2ad9fd0b4522a
ld="${LINUXDEPLOY:-$work/linuxdeploy.AppImage}"
case "$ld" in /*) ;; *) ld="$root/$ld" ;; esac
if [ ! -x "$ld" ]; then
	curl -sSLf -o "$ld" \
		"https://github.com/linuxdeploy/linuxdeploy/releases/download/$ld_ver/linuxdeploy-x86_64.AppImage"
	chmod +x "$ld"
fi
if [ -z "${LINUXDEPLOY:-}" ]; then
	got="$(sha256sum "$ld" | cut -d' ' -f1)"
	[ "$got" = "$ld_sha" ] || {
		echo "build_appimage: linuxdeploy $ld_ver checksum mismatch" >&2
		echo "  expected $ld_sha" >&2
		echo "  got      $got" >&2
		exit 1
	}
fi

# TWO PHASES, AND THE ORDER IS THE WHOLE POINT. Phase one populates the AppDir: linuxdeploy
# resolves the binary's shared libraries, copies them in and rewrites the rpath. Phase two turns
# the finished AppDir into the image.
#
# The licence sweep has to sit BETWEEN them. It reads what phase one put in usr/lib, and the image
# is only sealed in phase two — doing it after `--output appimage` copied files into a directory
# nobody ships, and the published AppImage carried none of them (codex round 1 on #322, and the
# same failure as #318 reproduced in the code written to honour #318).
#
# The excludelist leaves out the graphics driver stack (libGL, libGLX, libGLdispatch, libX11) —
# a bundled libGL would be the wrong one for the user's GPU — and libfreetype, which clashes with
# the host fontconfig stack and is on any system with a desktop. libglfw.so.3, the one that
# actually goes missing, IS bundled.
( cd "$work" && ARCH=x86_64 "$ld" --appdir AppDir \
	-e AppDir/usr/bin/blobly_net -d blobly_net.desktop -i blobly_net.png )

# THE BUNDLED LIBRARIES' LICENCES, DERIVED FROM WHAT LANDED IN THE AppDir — the rule #318 settled
# for the Windows DLLs. An AppImage is a distribution like any other: whatever travels inside it
# needs its notice travelling with it. dpkg names the owning package; Debian keeps the text at
# /usr/share/doc/<pkg>/copyright. Derived, never a hand-kept list.
lic="$work/AppDir/usr/bin/licenses"
mkdir -p "$lic"
n=0
for so in "$work"/AppDir/usr/lib/*.so*; do
	[ -e "$so" ] || continue
	# BY SONAME, not by path: linuxdeploy COPIED these in, so the file here is owned by no package
	# and `dpkg -S` on it finds nothing.
	base="$(basename "$so")"
	pkg="$(dpkg -S "*/$base" 2>/dev/null | head -1 | cut -d: -f1)"
	[ -n "$pkg" ] || { echo "build_appimage: no owning package for $base" >&2; exit 1; }
	cp="/usr/share/doc/$pkg/copyright"
	[ -f "$cp" ] || { echo "build_appimage: no copyright file for $pkg ($base)" >&2; exit 1; }
	cp "$cp" "$lic/$pkg-copyright.txt"
	n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "build_appimage: no libraries were bundled at all" >&2; exit 1; }
# AND THE RUNTIME ITSELF. appimagetool PREPENDS the AppImage type-2 runtime to the SquashFS — the
# published file begins with an ELF header and the `AI\x02` magic — so the artifact distributes
# that third-party executable as surely as it distributes libglfw (codex round 2 on #322). It is
# not a .so under usr/lib, so the sweep above cannot see it; its text is vendored beside the
# desktop file, where it is in-repo and auditable rather than fetched at build time.
cp "$root/packaging/appimage/appimage-runtime-LICENSE.txt" "$lic/appimage-runtime-LICENSE.txt"
# AND WHAT THE RUNTIME ITSELF STATICALLY CONTAINS. AppImageKit's own licence says in its second
# sentence that it "does not necessarily apply for all dependencies", and the runtime links
# squashfuse (BSD-2) plus the compressors it needs to read the image without host libraries —
# confirmed by their strings being in the prepended bytes (codex round 3 on #322).
#
# libfuse is NOT among them: the type-2 runtime dlopens it from the host, which is exactly why a
# user needs libfuse2 installed. That requirement is the evidence it is not bundled, so there is
# no LGPL obligation here.
for f in "$root"/packaging/appimage/runtime-deps/*-LICENSE.txt; do
	cp "$f" "$lic/appimage-runtime-$(basename "$f")"
done
# PACKAGES, NOT LIBRARIES. Several sonames can come from one package — libbrotlicommon and
# libbrotlidec are both libbrotli1 — so the file count is lower than the library count and
# comparing the two is comparing different things. The invariant that matters is that what was
# staged is what ends up inside the image.
staged=$(ls "$lic"/*-copyright.txt 2>/dev/null | wc -l)
echo "staged $staged package licence(s) for $n bundled librar(y|ies)"

if ! find "$work/AppDir" -name 'libglfw.so.*' | grep -q .; then
	echo "build_appimage: libglfw is not bundled — the AppImage would fail like the tarball" >&2
	exit 1
fi

out="$root/blobly_net-v${ver}-x86_64.AppImage"
rm -f "$out"
( cd "$work" && ARCH=x86_64 OUTPUT="$out" "$ld" --appdir AppDir \
	-e AppDir/usr/bin/blobly_net -d blobly_net.desktop -i blobly_net.png --output appimage )
[ -f "$out" ] || { echo "build_appimage: linuxdeploy produced no $out" >&2; exit 1; }
chmod +x "$out"

# WHAT IS IN THE IMAGE, NOT WHAT IS IN THE AppDir. The AppDir is scaffolding; the image is what a
# user gets, and checking the wrong one is exactly how the licences went missing. Extract it and
# look.
ex="$work/verify"
rm -rf "$ex"
mkdir -p "$ex"
( cd "$ex" && "$out" --appimage-extract >/dev/null )
for f in lua-LICENSE.txt v-stdlib-LICENSE.txt boehm-gc-LICENSE.txt appimage-runtime-LICENSE.txt \
         appimage-runtime-squashfuse-LICENSE.txt; do
	[ -s "$ex/squashfs-root/usr/bin/licenses/$f" ] \
		|| { echo "build_appimage: $f is not inside the image" >&2; exit 1; }
done
inside=$(ls "$ex/squashfs-root/usr/bin/licenses/"*-copyright.txt 2>/dev/null | wc -l)
[ "$inside" -eq "$staged" ] || {
	echo "build_appimage: staged $staged package licences but $inside are inside the image" >&2
	exit 1
}
[ -s "$ex/squashfs-root/usr/bin/projects/sim-demo.blobnet" ] \
	|| { echo "build_appimage: the payload is not inside the image" >&2; exit 1; }

# WHAT THE HOST MUST STILL PROVIDE, DERIVED. The excludelist is linuxdeploy's, not ours, so the
# set changes when it does — and a hand-written list in the README goes stale silently, which it
# did three times in review (OpenGL, then FreeType, then X11). Printed here so the documentation
# can be checked against the build instead of against memory.
host=$(comm -23 \
	"$(ldd "$work/AppDir/usr/bin/blobly_net" 2>/dev/null | awk '{print $1}' | grep '^lib' | sort -u > "$work/.need"; echo "$work/.need")" \
	"$(ls "$work/AppDir/usr/lib" 2>/dev/null | sort -u > "$work/.have"; echo "$work/.have")" \
	| grep -vE '^(libc|libm|libdl|libpthread|librt|libstdc\+\+|libgcc_s)\.so' | tr '\n' ' ')
echo "host libraries still required: $host"

# AND IT RUNS. A built file that cannot start is the failure this whole change exists to prevent.
got="$("$out" --version 2>&1 | head -1)" || {
	echo "build_appimage: the AppImage does not run: $got" >&2
	exit 1
}
[ "$got" = "blobly_net $ver" ] || {
	echo "build_appimage: expected 'blobly_net $ver', got '$got'" >&2
	exit 1
}
echo "built $out — runs, says '$got', $inside package notices for $n libraries, payload inside"
