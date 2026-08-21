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
cp packaging/README.txt "$dest/README.txt"
printf 'blobly_net %s\n' "$ver" > "$dest/VERSION.txt"
echo "staged bundle payload -> $dest (version $ver)"
