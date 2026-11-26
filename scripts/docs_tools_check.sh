#!/bin/sh
# docs_tools_check.sh — the guides may name a cmd/ tool only where a reader can find it (#198).
#
# A release bundle ships the app and the engine library; every other cmd/ tool is built from a
# checkout. docs/ travels in the bundle and the Help menu renders it, so a guide naming a tool the
# bundle lacks must send the reader to docs/building.md's "Command-line tools (source checkout
# only)" section, and that section's table must list the tool. Checked here:
#   - every `cmd/<tool>` a guide names (an existing directory under cmd/) is bundled or in the table;
#   - a guide naming a tool that is not bundled links to the section;
#   - every table row names a tool that exists and is not bundled;
#   - what this script calls bundled is still copied into both bundles by the workflows.
# docs/history.md is an archive and not maintained, so it is not held to this.
#
#   ROOT=<dir>   the tree to check (default: this repository); docs_tools_check_test.sh uses it
set -u
root="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root" || exit 2
guide=docs/building.md
anchor=command-line-tools-source-checkout-only
heading='## Command-line tools (source checkout only)'
fail=0
say() { echo "docs_tools_check: $*"; fail=1; }

# The bundled tools and the line in each workflow that copies them into the bundle.
bundled="blobly_net libblobly"
need() { grep -qF -- "$2" "$1" || say "$1 no longer has \`$2\`: is $3 still in the bundle? update this script"; }
need .github/workflows/release.yml 'cp build/blobly_net dist/' blobly_net
need .github/workflows/release.yml 'cp build/libblobly.so dist/' libblobly
need .github/workflows/windows.yml 'cp build/blobly_net.exe dist/' blobly_net
need .github/workflows/windows.yml 'cp build/blobly.dll dist/' libblobly

is_bundled() { case " $bundled " in *" $1 "*) return 0 ;; esac; return 1; }

grep -qxF "$heading" "$guide" || say "$guide has no heading \"$heading\""
# the table's rows: | `cmd/<tool>` | ... inside the section
listed=$(awk -v h="$heading" '$0 == h {on = 1; next} on && /^## / {exit} on' "$guide" \
	| sed -n 's/^| `cmd\/\([a-z0-9_]*\)`.*/\1/p')
[ -n "$listed" ] || say "$guide: the section lists no tool"
for t in $listed; do
	[ -d "cmd/$t" ] || say "$guide lists cmd/$t, which does not exist"
	! is_bundled "$t" || say "$guide lists cmd/$t as source-only, but the bundle carries it"
done
is_listed() { case " $(echo $listed) " in *" $1 "*) return 0 ;; esac; return 1; }

for doc in docs/*.md; do
	case "$doc" in docs/history.md | "$guide") continue ;; esac
	src_only=""
	for t in $(grep -oE 'cmd/[a-z0-9_]+' "$doc" | sed 's|cmd/||' | sort -u); do
		[ -d "cmd/$t" ] || continue # V's own paths (cmd/v, cmd/tools) and removed tools
		is_bundled "$t" && continue
		src_only="$src_only $t"
		is_listed "$t" || say "$doc names cmd/$t: add it to the table in $guide ($heading)"
	done
	if [ -n "$src_only" ] && ! grep -qF "building.md#$anchor" "$doc"; then
		say "$doc names source-only tools (${src_only# }) but does not link to building.md#$anchor"
	fi
done
[ "$fail" -eq 0 ] && echo "docs_tools_check: ok"
exit "$fail"
