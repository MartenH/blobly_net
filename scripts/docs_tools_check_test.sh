#!/bin/sh
# Tests for scripts/docs_tools_check.sh, over small trees built here: one that passes, and one
# defect of each kind the check exists to catch.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/docs_tools_check.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
link='building.md#command-line-tools-source-checkout-only'

# tree <name>: a passing tree: two bundled tools, two source-only ones, one guide naming one of them
tree() {
	t="$tmp/$1"
	mkdir -p "$t/cmd/blobly_net" "$t/cmd/libblobly" "$t/cmd/restbus" "$t/cmd/flash" \
		"$t/docs" "$t/.github/workflows"
	printf 'cp build/blobly_net dist/\ncp build/libblobly.so dist/\n' > "$t/.github/workflows/release.yml"
	printf 'cp build/blobly_net.exe dist/\ncp build/blobly.dll dist/\n' > "$t/.github/workflows/windows.yml"
	cat > "$t/docs/building.md" <<-EOF
	# Building

	## Command-line tools (source checkout only)

	| tool | what |
	|---|---|
	| \`cmd/restbus\` | replay |
	| \`cmd/flash\` | flash |

	## Dependencies
	EOF
	printf 'Run `cmd/restbus` ([source checkout only](%s)), or `cmd/blobly_net`; `cmd/v/v.v` is V.\n' "$link" \
		> "$t/docs/guide.md"
	printf 'Long ago `cmd/nonesuch` and `cmd/flash` existed.\n' > "$t/docs/history.md"
	echo "$t"
}

# expect <label> <want-status> <dir> [<text the output must hold>]
expect() {
	out=$(ROOT="$3" sh "$check" 2>&1)
	st=$?
	if [ "$st" -ne "$2" ]; then
		fail=$((fail + 1))
		printf 'FAIL %s: exit %s, want %s\n%s\n' "$1" "$st" "$2" "$out"
	elif [ -n "${4:-}" ] && ! printf '%s\n' "$out" | grep -qF -- "$4"; then
		fail=$((fail + 1))
		printf 'FAIL %s: output lacks "%s"\n%s\n' "$1" "$4" "$out"
	else
		pass=$((pass + 1))
	fi
}

expect "a tree that holds" 0 "$(tree ok)" "ok"

t=$(tree unlisted)
printf 'See `cmd/lin_monitor` ([x](%s)).\n' "$link" > "$t/docs/lin.md"
mkdir -p "$t/cmd/lin_monitor"
expect "a guide naming a tool the table lacks" 1 "$t" "docs/lin.md names cmd/lin_monitor"

t=$(tree nolink)
printf 'Run `cmd/flash`.\n' > "$t/docs/flash.md"
expect "a guide naming a source-only tool without the link" 1 "$t" "docs/flash.md names source-only tools (flash)"

t=$(tree stale)
sed -i 's/cmd\/flash/cmd\/gone/' "$t/docs/building.md"
expect "a table row for a tool that does not exist" 1 "$t" "lists cmd/gone, which does not exist"

t=$(tree bundledrow)
sed -i 's/^| `cmd\/flash`.*/&\n| `cmd\/libblobly` | lib |/' "$t/docs/building.md"
expect "a table row for a bundled tool" 1 "$t" "lists cmd/libblobly as source-only"

t=$(tree workflow)
printf 'nothing\n' > "$t/.github/workflows/windows.yml"
expect "a bundled tool the workflow no longer copies" 1 "$t" "is blobly_net still in the bundle"

t=$(tree heading)
sed -i 's/^## Command-line tools.*/## Tools/' "$t/docs/building.md"
expect "the section renamed" 1 "$t" "has no heading"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
