#!/usr/bin/env bash
# Regression suite for the commit-message address scanner (.githooks/_email_scan.sh).
#
# WHY THIS EXISTS: the scanner took three review rounds, and every round found a BYPASS
# rather than a style nit — a scissors marker that hid the rest of a stored message, a
# redaction that emitted its input when the regex declined to match, and a markup strip
# that turned a foreign address into the allowlisted one by removing a leading character
# that is legal in a local part. Those are exactly the failures a spot check misses and a
# pinned case catches. CI runs this, so the gate cannot silently regress.
#
# Run: .githooks/test-email-scan.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. .githooks/_email_scan.sh

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
pass=0; fail=0

# expect <clean|hit> <description> <message text>
expect() {
	local want="$1" desc="$2" text="$3" mode="${4:-stored}" got
	printf '%s\n' "$text" > "$tmp"
	if [ -n "$(scan_message_text "$tmp" "$mode")" ]; then got=hit; else got=clean; fi
	if [ "$got" = "$want" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1)); echo "FAIL [$desc] expected $want, got $got"
	fi
}

# --- the address must be caught -------------------------------------------------------
expect hit  "plain foreign address"        'body: real.person@somecompany.com'
expect hit  "at end of a sentence"         'body: real.person@somecompany.com.'
expect hit  "inside backticks"             'body: `real.person@somecompany.com`'
# Single-label domains are deliberately NOT flagged. Requiring a real TLD is what keeps
# the gate quiet on this project's ordinary notation — over 1084 real commit messages the
# laxer rule flagged 23, all false positives (gui@68b9302, cyclic@100ms, ctr@1/crc@2).
expect clean "single-label domain"         'body: user@mailhost'
expect clean "version pin notation"        'body: pinned gui@68b9302 and vlang/setup-v@v1.4'
expect clean "config notation"             'body: cyclic@100ms, ctr@1/crc@2, kvaser:0@500000'
expect hit  "foreign addr after junk"      'body: real.person@somecompany.com#x.example.com'
expect hit  "non-reserved domain literal"  'body: admin@[10.0.0.5]'
expect hit  "quoted local part"            'body: "local part"@somecompany.com'
expect hit  "punycode IDN TLD"             'body: real.person@company.xn--p1ai'
expect hit  "address then ellipsis"        'body: mail real.person@somecompany.com..then reply'
expect clean "codex bot address"           'body: authored by codex@openai.com'
# a leading character that is LEGAL in a local part must not be stripped into the allowlist
expect hit  "leading _ bypass"             'body: _marten.hildell@gmail.com'
expect hit  "leading * bypass"             'body: *marten.hildell@gmail.com'
expect hit  "leading ~ bypass"             'body: ~marten.hildell@gmail.com'
expect hit  "bypass wrapped in markup"     'body: `_marten.hildell@gmail.com`'
# a stored message must NOT be truncated at a scissors marker
expect hit  "hidden behind scissors" 'subject

------------------------ >8 ------------------------
real.person@somecompany.com'

# --- the address must NOT be flagged --------------------------------------------------
expect clean "maintainer address"          'body: marten.hildell@gmail.com'
expect clean "bot trailer"                 'Co-Authored-By: Claude <noreply@anthropic.com>'
expect clean "allowlisted in backticks"    'body: `marten.hildell@gmail.com`'
expect clean "allowlisted in brackets"     'body: [noreply@anthropic.com]'
expect clean "allowlisted via mailto link" 'body: [M](mailto:marten.hildell@gmail.com)'
expect clean "MAILTO uppercase"            'body: [M](MAILTO:marten.hildell@gmail.com)'
expect clean "markdown emphasis"           'body: *marten.hildell@gmail.com* and _noreply@anthropic.com_'
expect clean "allowlisted, punctuated"     'body: `marten.hildell@gmail.com`, and more.'
# RFC 2606 / RFC 5737 reserved names exist to be written down
expect clean "example.com"                 'body: foreign@example.com'
expect clean "dangling backtick after doc" 'body: was `# foreign@example.com`. Comment lines'
expect clean ".test IDN"                   'body: user@例え.テスト'
expect clean "reserved domain literal"     'body: admin@[192.0.2.1]'
expect clean "corp.example (.example TLD)" 'body: "local part"@corp.example'
# this gate's own redaction output must not look like an address
expect clean "redaction sample"            'body: reported as m***@***om'
# a template must ignore the diff `git commit -v` appends
expect clean "verbose diff below scissors" 'subject

body
# ------------------------ >8 ------------------------
diff --git a/x b/x
+auth = "someone@somecompany.com"' template

# --- redaction must fail CLOSED -------------------------------------------------------
for v in 'real.person@somecompany.com' 'alice.smith@[' 'x@y' '@' ''; do
	out=$(redact "$v")
	if [ -n "$v" ] && [ "$out" = "$v" ]; then
		fail=$((fail + 1)); echo "FAIL [redact] returned its input unchanged"
	else
		pass=$((pass + 1))
	fi
done

echo "email-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
