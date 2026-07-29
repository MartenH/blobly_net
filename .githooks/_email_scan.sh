#!/usr/bin/env bash
# Shared scanner: find email addresses in commit-message text that are not allowlisted.
# Sourced by .githooks/commit-msg (one message being written), .githooks/pre-push (a whole
# range about to leave the machine) and .github/workflows/guard.yml (the authoritative
# check), so the three enforcement points cannot drift apart.
#
# WHY: the identity gate checks WHO commits; nothing checked what the message BODY says.
# A work address in a commit message is permanent — it survives branch deletion, `git log`
# and code search index it, and removing it costs a rewrite of every branch that carries
# it (and GitHub's PR refs keep it even then).

ALLOWED_RE='^(marten\.hildell@gmail\.com|noreply@anthropic\.com|noreply@github\.com)$'

# scan_message_text <file> <template|stored>
#   template — the file git is about to clean up (commit-msg hook)
#   stored   — a message already in history, from `git log --format=%B`
# Prints one non-allowlisted address per line; empty output = clean.
scan_message_text() {
	local file="$1" mode="${2:-stored}" text

	# SCISSORS. `git commit -v` appends the staged diff below a "------ >8 ------" line and
	# git drops it before storing, so scanning it would reject a clean message over some
	# source line. But that cut is ONLY valid while the message is still a template: in a
	# STORED message the same line is ordinary content, and truncating there let a message
	# hide an address behind a scissors marker — bypassing every gate (codex #66). So the
	# cut applies to templates only, and even then only when a real diff follows it.
	if [ "$mode" = template ] && grep -q '^diff --git ' "$file" \
		&& grep -qE -- '-{2,} *>8 *-{2,}' "$file"; then
		text=$(sed -n '/-\{2,\} *>8 *-\{2,\}/q;p' "$file")
	else
		text=$(cat "$file")
	fi

	# Comment lines are scanned, not stripped: they are usually removed by git, but
	# --cleanup=verbatim and a changed core.commentChar keep them, and a hook must not miss
	# an address that will really be stored. A false positive costs one message edit; a
	# false negative costs a history rewrite.
	#
	# Two extraction patterns, unioned:
	#   1. ordinary addresses — deliberately NOT ASCII-only, so internationalized domains
	#      (user@例え.テスト) and domain literals (user@[192.0.2.1]) are seen;
	#   2. quoted local parts ("local part"@corp.example), which pattern 1 cannot match
	#      because it excludes quotes on both sides.
	# Candidates are then stripped of surrounding markup — `addr`, [addr], <addr> — before
	# the allowlist compare, or a permitted address in backticks would be rejected.
	{
		printf '%s\n' "$text" | grep -oE '[^[:space:]<>(),;"]+@[^[:space:]<>(),;"]+' || true
		printf '%s\n' "$text" | grep -oE '"[^"]+"@[^[:space:]<>(),;"]+' || true
	} \
		| sed -E "s/^[\`'\"([{<*_]+//" \
		| sed -E "s/[]\`'\"),.;:!?}>*_]+\$//" \
		| grep -E '@.*[.[]' \
		| sort -u \
		| grep -viE "$ALLOWED_RE" || true
}

# redact <address> -> a bounded stand-in, safe to print anywhere.
# FAIL CLOSED: built by slicing, not by a substitution that can decline to match. A regex
# that simply fails on a malformed candidate (e.g. "alice.smith@[") would echo the value
# whole and recreate the disclosure this exists to prevent (codex #66). Output is at most
# one leading character plus two trailing ones, whatever the input looks like.
redact() {
	local a="$1" lp dom
	lp=${a%%@*}
	dom=${a##*@}
	printf '%s***@***%s' "${lp:0:1}" "$(printf '%s' "$dom" | tail -c 2)"
}

# redact_list — redact every address on stdin, one per line.
redact_list() {
	local a
	while IFS= read -r a; do
		[ -n "$a" ] && printf '  %s\n' "$(redact "$a")"
	done
}

explain_rejection() {
	echo "  A commit message is permanent: it survives branch deletion, and removing" >&2
	echo "  it later means rewriting every branch that contains it." >&2
	echo "  Describe the address instead of quoting it, e.g." >&2
	echo '    "rejects a non-maintainer work address"' >&2
	echo "  Allowed: the maintainer address and bot trailers (Co-Authored-By)." >&2
	echo "  (Addresses are shown redacted — read the message itself to see the value.)" >&2
}
