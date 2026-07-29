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

ALLOWED_RE='^(marten\.hildell@gmail\.com|noreply@anthropic\.com|noreply@github\.com|codex@openai\.com)$'

# DOCUMENTATION addresses are allowed too. RFC 2606 reserves example.com/.net/.org and the
# .test / .example / .invalid / .localhost TLDs, and RFC 5737 reserves 192.0.2.0/24,
# 198.51.100.0/24 and 203.0.113.0/24, precisely so they can be written down without ever
# belonging to anyone. Excluding them costs nothing in protection — no work address lives
# there — and buys the ability to describe this gate in its own commit message and docs.
# Without it the rule is self-defeating: the commit that adds the scanner cannot say what
# the scanner catches. (.テスト is the IDN form of .test.)
DOC_RE='@(([A-Za-z0-9-]+\.)*example\.(com|net|org)|([A-Za-z0-9-]+\.)*(test|example|invalid|localhost)|([^[:space:].]+\.)*テスト|\[(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]+\])$'

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
	# Candidates are unwrapped, their domain truncated at the first character that cannot
	# appear in one, and then VALIDATED — matching loosely and filtering afterwards is what
	# produced three rounds of bypasses and a pile of false positives. A candidate counts
	# only if it looks like a deliverable address: a domain literal, or dot-separated labels
	# whose final label is at least two non-numeric characters.
	#
	# That last rule is deliberate and evidence-based. Over the 1084 real commit messages in
	# this project and its companion, a laxer rule (any 2+ character domain, to catch
	# single-label internal hosts) flagged 23 messages, every one of them a false positive:
	# `gui@68b9302`, `cyclic@100ms`, `ctr@1/crc@2`, `vlang/setup-v@v1.4`, `kvaser:0@500000`.
	# A gate that cries wolf on ordinary version pins and config notation gets disabled, so
	# single-label domains are OUT — the address this exists to stop has a real TLD.
	{
		printf '%s\n' "$text" | grep -oE '[^[:space:]<>(),;"]+@[^[:space:]<>(),;"]+' || true
		printf '%s\n' "$text" | grep -oE '"[^"]+"@[^[:space:]<>(),;"]+' || true
	} \
		| while IFS= read -r cand; do unwrap_candidate "$cand"; done \
		| sed -E 's/(@[^[:space:]]*)[#/\\|?!$%^&*+={}]+.*/\1/' \
		| sed -E 's/(@[^[:space:]]+)\.\..*/\1/' \
		| grep -E '^("[^"]+"|[^@[:space:]]+)@(\[[^]]+\]|([^[:space:].]+\.)+[^[:space:].]{2,})$' \
		| grep -vE '\.[0-9]+$' \
		| sort -u \
		| grep -viE "$ALLOWED_RE" \
		| grep -viE "$DOC_RE" || true
}

# unwrap_candidate <raw> -> the address with surrounding MARKUP removed.
#
# This is where a naive strip becomes a bypass. Most punctuation people wrap an address
# in — backtick, ' * _ { } ~ + - and more — is ALSO legal in an email local part, so
# stripping it unconditionally maps a foreign address onto an allowlisted one: dropping
# the leading underscore of an address that is otherwise the maintainer's turns it into
# the maintainer's and it passes (codex #66 r3, reproduced).
#
# So only BALANCED wrappers are removed — an opening delimiter with its matching close.
# `addr`, [addr], <addr>, "addr", (addr) are unwrapped; a lone leading character is not,
# because a legal address may genuinely start with it. A `mailto:` prefix is dropped
# outright: ':' cannot appear in an unquoted local part, so it is never part of one.
unwrap_candidate() {
	local c="$1" prev=""
	c=${c#[Mm][Aa][Ii][Ll][Tt][Oo]:}
	while [ "$c" != "$prev" ]; do
		prev="$c"
		# Trailing sentence punctuation FIRST, and again each pass. A wrapped address at the
		# end of a sentence arrives as `addr`. — the closing delimiter is not last, so the
		# balanced-wrapper test below would never fire and the whole thing stayed "foreign".
		c=${c%[.,;:!?]}
		case "$c" in
			'`'*'`') c=${c#\`}; c=${c%\`} ;;
			'['*']') # but NOT a bare domain literal like user@[192.0.2.1]
				case "$c" in *'@['*']') ;; *) c=${c#[}; c=${c%]} ;; esac ;;
			'<'*'>') c=${c#<}; c=${c%>} ;;
			'('*')') c=${c#(}; c=${c%)} ;;
			'{'*'}') c=${c#\{}; c=${c%\}} ;;
			'*'*'*') c=${c#\*}; c=${c%\*} ;;
			'_'*'_') c=${c#_}; c=${c%_} ;;
			'~'*'~') c=${c#\~}; c=${c%\~} ;;
			"'"*"'") c=${c#\'}; c=${c%\'} ;;
			*) ;;
		esac
	done
	# TRAILING markup is safe to strip unconditionally, and this is the asymmetry that
	# matters: a local part may legally contain ` ' * _ { } ~ + and friends, so stripping
	# those from the FRONT can turn a foreign address into an allowlisted one — that is the
	# bypass above. A DOMAIN can contain none of them, so anything of that shape hanging off
	# the end is punctuation, never part of the address. (']' is exempt when the candidate
	# holds a domain literal, where it is the real final character.)
	prev=""
	while [ "$c" != "$prev" ]; do
		prev="$c"
		case "$c" in
			*'@['*']') ;; # domain literal — leave its closing bracket alone
			*[]\`\'\"\)\}\>*_,\;:!?~+=\|^\&%\$\#/\\.]) c=${c%?} ;;
		esac
	done
	printf '%s\n' "$c"
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
