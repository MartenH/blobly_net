#!/bin/sh
# stage_bundle.sh <dest-dir> <version> — the ONE list of what a Blobly Net bundle contains.
# Called by release.yml (Linux tar.gz) and windows.yml (zip, via the msys2 shell), so the two
# archives cannot drift: the self-review that introduced it found the list already written
# twice in two languages, and packaging/README.txt — the in-bundle readme — shipped by
# neither. Platform extras (the exe, mingw DLLs, register_blobnet_win.ps1) stay with the
# caller; everything here is platform-neutral payload.
#
# NO error silencing: a bundle missing its samples or licence must FAIL the release, not ship
# thin. (The four sample files are tracked and .gitignore re-includes them by name — if this
# cp fails, something real broke.)
set -e
dest="$1"
ver="$2"
[ -n "$dest" ] && [ -n "$ver" ] || { echo "usage: stage_bundle.sh <dest-dir> <version>" >&2; exit 2; }
cd "$(dirname "$0")/.."
mkdir -p "$dest/samples"
cp -r projects dbc tests manifests docs "$dest/"
cp samples/*.log samples/*.mf4 "$dest/samples/"
cp LICENSE "$dest/LICENSE.txt"
cp packaging/THIRD-PARTY-NOTICES.txt "$dest/"
# THE TEXTS, NOT JUST THE INDEX (#318). THIRD-PARTY-NOTICES.txt lists components and links and
# says so itself; MIT wants the copyright and permission notices to travel with copies of what
# is compiled in. These are the components statically incorporated on BOTH platforms, and their
# texts come from this repo or from the tree build_deps.sh fetched. What Windows links
# dynamically is covered by the notices file's own DLL section and the DLLs themselves.
mkdir -p "$dest/licenses"
cp thirdparty/lua/LICENSE                    "$dest/licenses/lua-LICENSE.txt"
cp libs/markdown/LICENSE                     "$dest/licenses/vlang-markdown-LICENSE.txt"
# Two components keep their notice in a SOURCE HEADER rather than a LICENSE file, so it is
# extracted: everything up to the first close-comment, with the comment marks stripped.
header_notice() { awk '/^ \*\//{exit} {sub(/^\/\*/,""); sub(/^ \* ?/,""); print}' "$1" > "$2"; }
# md4c is vendored inside libs/markdown under a DIFFERENT copyright holder, so markdown's own
# notice does not cover it.
header_notice libs/markdown/thirdparty/md4c/md4c.c "$dest/licenses/md4c-LICENSE.txt"
cp libs/vgui/build/cimgui/imgui/LICENSE.txt  "$dest/licenses/dear-imgui-LICENSE.txt"
cp libs/vgui/build/cimgui/LICENSE            "$dest/licenses/cimgui-LICENSE.txt"
cp libs/vgui/build/cimplot/implot/LICENSE    "$dest/licenses/implot-LICENSE.txt"
cp libs/vgui/build/cimplot/LICENSE           "$dest/licenses/cimplot-LICENSE.txt"
# V's standard library is compiled in and its text is not in this repo: it comes from the
# toolchain that built this. THROUGH $V, like every other script here — the Windows job runs V
# from /c/v-ct/v.exe by absolute path and never puts it on PATH, so `command -v v` finds nothing
# there. Unguarded, `dirname` of an empty string is ".", and this copied Blobly Net's OWN LICENSE
# as V's, which a non-empty check cannot notice (codex round 1 on #318).
vbin="${V:-$(command -v v || true)}"
[ -n "$vbin" ] || { echo "stage_bundle: no V found; pass V=/path/to/v" >&2; exit 1; }
vroot="$(dirname "$(readlink -f "$vbin")")"
[ -s "$vroot/LICENSE" ] || { echo "stage_bundle: no LICENSE beside $vbin" >&2; exit 1; }
cp "$vroot/LICENSE"                          "$dest/licenses/v-stdlib-LICENSE.txt"
# Boehm GC: V's DEFAULT collector, so it is linked into every build here — run_gui.sh does not
# pass `-gc none` — and its terms are notice-retention ("provided the above notices are retained
# on all copies"). Like md4c, the notice is the source header (codex round 2 on #318).
header_notice "$vroot/thirdparty/libgc/gc.c" "$dest/licenses/boehm-gc-LICENSE.txt"
# WHAT THE WINDOWS LINK PULLS IN STATICALLY, by explicit flag rather than the blanket -static:
# GLFW (-l:libglfw3.a) and the GCC runtime (-static-libgcc, -l:libstdc++.a). Both are compiled
# into the exe there, so both texts travel; on Linux they are the distro's shared libraries and
# neither is. Staged from the MSYS2 tree when it is present, which is exactly the case where the
# static link happened (codex round 1, and round 1 on the release PR for the GCC half — which
# this branch created by making libstdc++ static in the first place).
for d in glfw gcc-libs gcc; do
  for base in /mingw64/share/licenses/$d /mingw64/share/doc/$d; do
    [ -d "$base" ] || continue
    mkdir -p "$dest/licenses/$d"
    cp -r "$base/." "$dest/licenses/$d/"
    break
  done
done
# ON WINDOWS THOSE ARE NOT OPTIONAL. The loop skips what is absent, which is right on Linux where
# both are the distro's shared libraries — and would be a silent miss on Windows if MSYS2 ever
# moved the paths. An mingw64 tree present means the static link happened, so the texts must be
# here. Fail rather than ship the claim without the files behind it.
if [ -d /mingw64 ]; then
  [ -d "$dest/licenses/glfw" ] || { echo "stage_bundle: no GLFW licence, but -l:libglfw3.a links it" >&2; exit 1; }
  [ -d "$dest/licenses/gcc-libs" ] || [ -d "$dest/licenses/gcc" ] \
    || { echo "stage_bundle: no GCC runtime licence, but -static-libgcc/-l:libstdc++.a link it" >&2; exit 1; }
fi
for f in lua vlang-markdown md4c boehm-gc dear-imgui cimgui implot cimplot v-stdlib; do
  [ -s "$dest/licenses/$f-LICENSE.txt" ] || { echo "licence text missing: $f" >&2; exit 1; }
done
# NON-EMPTY IS NOT THE SAME AS RIGHT. The V lookup above failed open once and produced a
# perfectly non-empty file holding the wrong project's licence, so this checks the content says
# what it should rather than that a file exists.
grep -qi 'Alexander Medvednikov' "$dest/licenses/v-stdlib-LICENSE.txt" \
  || { echo "stage_bundle: v-stdlib-LICENSE.txt is not V's licence" >&2; exit 1; }
grep -qi 'Martin Mitas' "$dest/licenses/md4c-LICENSE.txt" \
  || { echo "stage_bundle: md4c-LICENSE.txt is not md4c's notice" >&2; exit 1; }
grep -qi 'Xerox Corporation' "$dest/licenses/boehm-gc-LICENSE.txt" \
  || { echo "stage_bundle: boehm-gc-LICENSE.txt is not the collector's notice" >&2; exit 1; }
cp packaging/README.txt "$dest/README.txt"
printf 'blobly_net %s\n' "$ver" > "$dest/VERSION.txt"
echo "staged bundle payload -> $dest (version $ver)"
