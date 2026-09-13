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
# md4c is vendored inside libs/markdown and is a DIFFERENT copyright holder, so markdown's own
# notice does not cover it; its permission notice lives in the source header.
awk '/^ \*\//{exit} {sub(/^\/\*/,""); sub(/^ \* ?/,""); print}' \
  libs/markdown/thirdparty/md4c/md4c.c > "$dest/licenses/md4c-LICENSE.txt"
cp libs/vgui/build/cimgui/imgui/LICENSE.txt  "$dest/licenses/dear-imgui-LICENSE.txt"
cp libs/vgui/build/cimgui/LICENSE            "$dest/licenses/cimgui-LICENSE.txt"
cp libs/vgui/build/cimplot/implot/LICENSE    "$dest/licenses/implot-LICENSE.txt"
cp libs/vgui/build/cimplot/LICENSE           "$dest/licenses/cimplot-LICENSE.txt"
# V's standard library is compiled in and its text is not in this repo: it comes from the
# toolchain that built this.
vroot="$(dirname "$(readlink -f "$(command -v v)")")"
cp "$vroot/LICENSE"                          "$dest/licenses/v-stdlib-LICENSE.txt"
for f in lua vlang-markdown md4c dear-imgui cimgui implot cimplot v-stdlib; do
  [ -s "$dest/licenses/$f-LICENSE.txt" ] || { echo "licence text missing: $f" >&2; exit 1; }
done
cp packaging/README.txt "$dest/README.txt"
printf 'blobly_net %s\n' "$ver" > "$dest/VERSION.txt"
echo "staged bundle payload -> $dest (version $ver)"
