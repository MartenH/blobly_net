#!/usr/bin/env bash
# Copy arxmodel's library (its arxmodel/ folder) and the flatxml it vendors (its flatxml/ folder,
# VENDORED included) at a stated arxmodel commit into arxmodel/ and flatxml/ here, and record the
# commit in arxmodel/VENDORED. Neither copy is ever edited: to change one, vendor another commit.
# Tests are left out, since they read arxmodel's own test data. Both sit at the repository root
# because V3 resolves `import flatxml` from v.mod's folder and nowhere else.
#
#   scripts/vendor_arxmodel.sh <full commit sha> [arxmodel checkout or URL]
set -euo pipefail
commit=${1:?usage: vendor_arxmodel.sh <commit> [arxmodel checkout or URL]}
src=${2:-https://github.com/MartenH/arxmodel}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
# a local checkout is accepted only as a copy of the public repository, and the commit is then
# fetched from that repository: a path on this machine, another remote, or a commit not pushed
# never goes into VENDORED
public=https://github.com/MartenH/arxmodel
if [ -d "$src" ]; then
	origin=$(git -C "$src" remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')
	if [ "$origin" != "$public" ]; then
		echo "$src: its origin is not $public; vendor from that URL instead" >&2
		exit 1
	fi
	src=$public
fi
git -C "$work" fetch -q --depth=1 "$src" "$commit"
full=$(git -C "$work" rev-parse FETCH_HEAD)
git -C "$work" checkout -q FETCH_HEAD -- arxmodel flatxml
find "$work/arxmodel" "$work/flatxml" -name '*_test.v' -delete
rm -rf "$root/arxmodel" "$root/flatxml"
cp -R "$work/arxmodel" "$root/arxmodel"
cp -R "$work/flatxml" "$root/flatxml"
printf 'arxmodel %s\nsource %s\nThe library folder at that commit, without its tests. Do not edit; re-vendor.\n' \
	"$full" "$src" > "$root/arxmodel/VENDORED"
echo "vendored arxmodel ${full} ($(head -1 "$root/flatxml/VENDORED"))"
