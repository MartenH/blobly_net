#!/usr/bin/env bash
# Tests for scripts/codex_local_review.sh's choice of codex binary, through --check-codex (which
# prints the binary it would run and its version, then exits — no git, no network):
#   - $CODEX that does not run (empty, silent) is refused with exit 3, never replaced;
#   - otherwise the first candidate that runs wins: PATH, then the extension copies newest first,
#     skipping a newer empty or non-executable copy for an older working one;
#   - nothing that runs: exit 3.
# PATH is built from only the tools the check uses, so an installed codex cannot leak in.
set -uo pipefail
cd "$(dirname "$0")/.." || exit

pass=0
fail=0
expect() { # expect <name> <got> <want>
	if [ "$2" = "$3" ]; then
		pass=$((pass+1))
	else
		fail=$((fail+1))
		echo "FAIL: $1"
		echo "  want: $3"
		echo "  got:  $2"
	fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools"
for t in bash dirname basename find sort head sed timeout; do
	ln -s "$(command -v "$t")" "$tmp/tools/$t"
done

# check <home> [extra PATH dir] [VAR=value...]: "<exit>|<first stdout line>" of --check-codex
check() {
	local home=$1 extra=$2
	shift 2
	local out code
	out=$(env -i PATH="${extra:+$extra:}$tmp/tools" HOME="$home" "$@" bash scripts/codex_local_review.sh --check-codex 2>/dev/null)
	code=$?
	printf '%s|%s' "$code" "$(printf '%s\n' "$out" | head -1)"
}

working() { # a stub codex that answers --version
	mkdir -p "$(dirname "$1")"
	printf '#!/bin/sh\necho "codex-cli 0.0.0-test"\n' >"$1"
	chmod +x "$1"
}
empty() { # a 0-byte executable, as an interrupted extension update left one
	mkdir -p "$(dirname "$1")"
	: >"$1"
	chmod +x "$1"
}
ext() { # ext <home> <version>: the path an extension version bundles codex at
	printf '%s' "$1/.vscode-server/extensions/openai.chatgpt-$2-linux-x64/bin/linux-x86_64/codex"
}

# $CODEX: used when it runs, refused (not replaced) when it does not
working "$tmp/good/codex"
expect "a working \$CODEX is chosen" "$(check "$tmp/h0" "" CODEX="$tmp/good/codex")" "0|$tmp/good/codex"
empty "$tmp/empty/codex"
working "$(ext "$tmp/h1" 26.900.1)"
expect "an empty \$CODEX is refused, not replaced" "$(check "$tmp/h1" "" CODEX="$tmp/empty/codex")" "3|"
printf '#!/bin/sh\nexit 0\n' >"$tmp/mute-codex"
chmod +x "$tmp/mute-codex"
expect "a silent \$CODEX is refused" "$(check "$tmp/h1" "" CODEX="$tmp/mute-codex")" "3|"

# the extension copies, newest first: a newer empty one and a newer non-executable one are skipped
h=$tmp/h2
working "$(ext "$h" 26.900.1)"
empty "$(ext "$h" 26.930.1)"
working "$(ext "$h" 26.920.1)"
chmod -x "$(ext "$h" 26.920.1)"
expect "an older working copy is chosen over newer broken ones" "$(check "$h" "")" "0|$(ext "$h" 26.900.1)"

# PATH first: a broken codex on PATH falls through to a working extension copy
empty "$tmp/onpath/codex"
expect "a broken codex on PATH falls through to the extension" "$(check "$h" "$tmp/onpath")" "0|$(ext "$h" 26.900.1)"
working "$tmp/goodpath/codex"
expect "a working codex on PATH is chosen first" "$(check "$h" "$tmp/goodpath")" "0|$tmp/goodpath/codex"

# nothing that runs
h=$tmp/h3
empty "$(ext "$h" 26.930.1)"
expect "an empty extension copy alone is refused" "$(check "$h" "")" "3|"

echo "codex_local_review_test: $pass passed, $fail failed"
[ "$fail" = 0 ]
