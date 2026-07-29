#!/usr/bin/env bash
# Shared scanner: find email addresses in commit-message text that are not allowlisted.
# Sourced by .githooks/commit-msg (one message) and .githooks/pre-push (a whole range),
# so the two gates cannot drift apart. CI (.github/workflows/guard.yml) applies the same
# rule as the authoritative check.
#
# WHY: the identity gate checks WHO commits; nothing checked what the message BODY says.
# A work address in a commit message is permanent — it survives branch deletion, `git log`
# and code search index it, and removing it costs a rewrite of every branch that carries
# it (and GitHub's PR refs keep it even then).

ALLOWED_RE='^(marten\.hildell@gmail\.com|noreply@anthropic\.com|noreply@github\.com)$'

# scan_message_text <file> -> prints one non-allowlisted address per line (empty = clean)
scan_message_text() {
	# 1. Cut the SCISSORS section first. `git commit -v` appends the staged diff below a
	#    "------ >8 ------" line and git removes it before storing; scanning it would
	#    reject a clean message because some source line happens to contain an address.
	#    Matched loosely so a non-default core.commentChar still cuts.
	# 2. Then scan EVERYTHING that remains, comment lines INCLUDED. Comments are usually
	#    stripped, but `--cleanup=verbatim` (and a changed core.commentChar) keeps them,
	#    and a hook must not miss an address that will really be stored. A false positive
	#    here costs one message edit; a false negative costs a history rewrite.
	# 3. The address pattern is deliberately NOT ASCII-only: internationalized domains
	#    (user@例え.テスト) and domain literals (user@[192.0.2.1]) are real addresses.
	#    Candidates are split on whitespace and message punctuation, then required to
	#    carry a dot or a bracket so ordinary prose ("@handle", "foo@bar") does not match.
	sed -n '/-\{2,\} *>8 *-\{2,\}/q;p' "$1" \
		| grep -oE '[^[:space:]<>(),;"]+@[^[:space:]<>(),;"]+' \
		| sed 's/[.,;:!?]*$//' \
		| grep -E '@.*[.[]' \
		| sort -u \
		| grep -viE "$ALLOWED_RE" || true
}

# redact <address> -> a shape-preserving stand-in, safe for logs.
# The gate must never echo the value it exists to contain: a CI annotation is a separate,
# permanent copy that rewriting the commit does not remove (codex #66).
redact() {
	printf '%s' "$1" | sed -E 's/^(.).*@.*(.{2})$/\1***@***\2/'
}

explain_rejection() {
	echo "  A commit message is permanent: it survives branch deletion, and removing" >&2
	echo "  it later means rewriting every branch that contains it." >&2
	echo "  Describe the address instead of quoting it, e.g." >&2
	echo '    "rejects a non-maintainer work address"' >&2
	echo "  Allowed: the maintainer address and bot trailers (Co-Authored-By)." >&2
}
