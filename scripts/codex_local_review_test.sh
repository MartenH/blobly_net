#!/usr/bin/env bash
# Tests for scripts/codex_local_review.sh's choice of codex binary, through --check-codex (which
# prints the binary it would run and its version, then exits — no git, no network):
#   - $CODEX (a path, relative or not, or a command name) that does not run — empty, silent, or
#     hanging on --version — is refused with exit 3, never replaced;
#   - otherwise the first candidate that runs wins: every codex on PATH, then the extension copies
#     newest first, skipping a newer empty or non-executable copy for an older working one;
#   - nothing that runs: exit 3. The chosen binary's version is the second line printed.
# And of a whole review run (#568), in a throwaway repository with a stub codex:
#   - two runs at once are serialised by the per-user lock, the second saying whose run it waits
#     for — through the flock command, through perl's flock where it is missing, and across the
#     two when the flock command is on one run's PATH only; CODEX_REVIEW_NO_WAIT=1 refuses with
#     exit 5 instead; a run killed with SIGKILL leaves the lock held while its codex runs (named
#     as such) and free once that ends; with neither tool the run warns and reviews unlocked;
#   - codex holds the lock's descriptor;
#   - a summary codex's transcript does not record for this run (another checkout, another prompt,
#     another final message) is printed under a WARNING; the stub writes codex's real shapes.
# PATH is built from only the tools the check uses, so an installed codex cannot leak in.
set -uo pipefail
cd "$(dirname "$0")/.." || exit
repo=$PWD

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
for t in bash dirname basename find sort head sed timeout cut mktemp rm sleep grep git tr date mkdir cat tail ln readlink ps; do
	ln -s "$(command -v "$t")" "$tmp/tools/$t"
done

# check <home> <extra PATH dirs> [VAR=value...]: "<exit>|<first stdout line>" of --check-codex, run
# from $CWD (default the repo); $LINE2=1 appends "|<second line>"
check() {
	local home=$1 extra=$2
	shift 2
	local out code
	out=$(cd "${CWD:-$repo}" && env -i PATH="${extra:+$extra:}$tmp/tools" HOME="$home" "$@" \
		timeout 30 bash "$repo/scripts/codex_local_review.sh" --check-codex 2>/dev/null)
	code=$?
	printf '%s|%s' "$code" "$(printf '%s\n' "$out" | head -1)"
	[ -z "${LINE2:-}" ] || printf '|%s' "$(printf '%s\n' "$out" | sed -n 2p)"
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
ext() { # ext <home> <version> [tree]: the path an extension version bundles codex at
	printf '%s' "$1/${3:-.vscode-server}/extensions/openai.chatgpt-$2-linux-x64/bin/linux-x86_64/codex"
}

# $CODEX: used when it runs, refused (not replaced) when it does not
working "$tmp/good/codex"
expect "a working \$CODEX is chosen, with its version" "$(LINE2=1 check "$tmp/h0" "" CODEX="$tmp/good/codex")" \
	"0|$tmp/good/codex|codex-cli 0.0.0-test"
expect "a relative \$CODEX is the caller's" "$(CWD=$tmp check "$tmp/h0" "" CODEX=good/codex)" "0|$tmp/good/codex"
expect "a bare \$CODEX is looked up on PATH" "$(check "$tmp/h0" "$tmp/good" CODEX=codex)" "0|$tmp/good/codex"
printf '#!/bin/sh\nexec sleep 1000\n' >"$tmp/hang-codex"
chmod +x "$tmp/hang-codex"
expect "a \$CODEX that hangs on --version is refused" "$(check "$tmp/h0" "" CODEX="$tmp/hang-codex" CODEX_PROBE_TIMEOUT=1)" "3|"
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
expect "every codex on PATH is tried, a broken first one skipped" "$(check "$h" "$tmp/onpath:$tmp/goodpath")" "0|$tmp/goodpath/codex"

# both extension trees: the newer version wins, whichever tree holds it
h=$tmp/h4
working "$(ext "$h" 1.0.0 .vscode)"
working "$(ext "$h" 100.0.0)"
expect "the newest copy across the remote and desktop trees is chosen" "$(check "$h" "")" "0|$(ext "$h" 100.0.0)"

# a bare $CODEX found through a relative PATH entry is the caller's
expect "a bare \$CODEX on a relative PATH entry is the caller's" "$(CWD=$tmp check "$tmp/h0" "good" CODEX=codex)" "0|$tmp/good/codex"

# a relative PATH entry in the automatic search is the caller's directory too
expect "a codex on a relative PATH entry is the caller's" "$(CWD=$tmp check "$tmp/h0" "good")" "0|$tmp/good/codex"

# a working one that leaves a child holding its stdout is accepted, promptly
mkdir -p "$tmp/bg"
printf '#!/bin/sh\nsleep 30 &\necho "codex-cli 0.0.0-test"\n' >"$tmp/bg/codex"
chmod +x "$tmp/bg/codex"
expect "a codex that leaves a child on its stdout does not hang the probe" \
	"$(check "$tmp/h0" "" CODEX="$tmp/bg/codex" CODEX_PROBE_TIMEOUT=2)" "0|$tmp/bg/codex"

# a codex whose interpreter is found through the same relative PATH entry still runs
mkdir -p "$tmp/rel"
printf '#!/bin/sh\necho "codex-cli 0.0.0-test"\n' >"$tmp/rel/myinterp"
chmod +x "$tmp/rel/myinterp"
printf '#!/usr/bin/env myinterp\n' >"$tmp/rel/codex"
chmod +x "$tmp/rel/codex"
ln -sf "$(command -v env)" "$tmp/tools/env"
expect "a codex whose interpreter is on the same relative PATH entry runs" "$(CWD=$tmp check "$tmp/h0" "rel")" "0|$tmp/rel/codex"

# a zero probe timeout is not "no deadline": a hanging candidate is still refused
expect "CODEX_PROBE_TIMEOUT=0 keeps a deadline" "$(check "$tmp/h0" "" CODEX="$tmp/hang-codex" CODEX_PROBE_TIMEOUT=0)" "3|"

# a probe runs outside the worktree: a candidate that drops a file where it runs leaves the repo clean
# (a name this run owns, so the cleanup can never remove a file of somebody else's)
litter=probe-litter-$$-$RANDOM$RANDOM
mkdir -p "$tmp/litter"
printf '#!/bin/sh\n: > %s\necho "codex-cli 0.0.0-test"\n' "$litter" >"$tmp/litter/codex"
chmod +x "$tmp/litter/codex"
expect "a probe leaves nothing in the worktree" "$(check "$tmp/h0" "" CODEX="$tmp/litter/codex"; [ -e "$repo/$litter" ] && printf ' LITTER')" "0|$tmp/litter/codex"
rm -f "$repo/$litter"

# a version after a blank first line is still a version
printf '#!/bin/sh\necho\necho "codex-cli 0.0.0-test"\n' >"$tmp/blank-codex"
chmod +x "$tmp/blank-codex"
expect "a version after a blank first line is accepted" "$(LINE2=1 check "$tmp/h0" "" CODEX="$tmp/blank-codex")" \
	"0|$tmp/blank-codex|codex-cli 0.0.0-test"

# a probe does not bound the files a real codex writes (a cache larger than 64 KiB)
mkdir -p "$tmp/cache"
printf '#!/bin/sh\nhead -c 200000 /dev/zero > "$HOME/codex-cache" || exit 1\necho "codex-cli 0.0.0-test"\n' >"$tmp/cache/codex"
chmod +x "$tmp/cache/codex"
mkdir -p "$tmp/hc"
expect "a codex writing a large cache is accepted" "$(check "$tmp/hc" "" CODEX="$tmp/cache/codex")" "0|$tmp/cache/codex"

# a leading-zero timeout is that many seconds, not the default
expect "CODEX_PROBE_TIMEOUT=001 is one second" \
	"$(s0=$SECONDS; r=$(check "$tmp/h0" "" CODEX="$tmp/hang-codex" CODEX_PROBE_TIMEOUT=001); [ $((SECONDS - s0)) -lt 6 ] && printf '%s' "$r" || printf 'slow %s' "$r")" "3|"

# a PATH entry starting with ~ is bash's to expand, not a directory under the caller's
working "$tmp/ht/bin/codex"
expect "a codex in a ~ PATH entry is found" "$(check "$tmp/ht" "~/bin")" "0|$tmp/ht/bin/codex"
# ~name with no such user is a relative directory, which bash leaves as it is
working "$tmp/~nouser-$$/bin/codex"
expect "a ~nouser PATH entry is the caller's directory" "$(CWD=$tmp check "$tmp/h0" "~nouser-$$/bin")" "0|$tmp/~nouser-$$/bin/codex"

# a bare $CODEX names a file on PATH, never a function of the same name
expect "a bare \$CODEX skips a function of that name" \
	"$(check "$tmp/h0" "$tmp/good" CODEX=codex 'BASH_FUNC_codex%%=() { :; }')" "0|$tmp/good/codex"

# a drive-qualified $CODEX is absolute, not a path under the caller's directory (which here holds
# a working C:/codex that only a wrongly prefixed path would reach)
working "$tmp/C:/codex"
expect "a drive-qualified \$CODEX is taken as written" "$(CWD=$tmp check "$tmp/h0" "" CODEX=C:/codex)" "3|"

# a PATH entry holding a newline does not cut off the entries after it
mkdir -p "$tmp/nl"$'\n'dir
expect "the whole PATH is kept past a newline" "$(check "$tmp/h0" "$tmp/nl"$'\n'"dir:$tmp/good")" "0|$tmp/good/codex"

# a refusal says why
why() { # the stderr of --check-codex for $CODEX=<path>
	env -i PATH="$tmp/tools" HOME="$tmp/h0" CODEX="$1" CODEX_PROBE_TIMEOUT=1 \
		timeout 30 bash "$repo/scripts/codex_local_review.sh" --check-codex 2>&1 >/dev/null
}
expect "an empty \$CODEX is called empty" "$(why "$tmp/empty/codex")" "codex-local-review: \$CODEX=$tmp/empty/codex does not run: an empty file"
expect "a hanging \$CODEX is called slow" "$(why "$tmp/hang-codex")" \
	"codex-local-review: \$CODEX=$tmp/hang-codex does not run: no answer to --version within 1 s (CODEX_PROBE_TIMEOUT raises it)"
printf '#!/bin/sh\nexit 124\n' >"$tmp/x124-codex"
chmod +x "$tmp/x124-codex"
expect "a \$CODEX exiting 124 at once is not called slow" "$(why "$tmp/x124-codex")" "codex-local-review: \$CODEX=$tmp/x124-codex does not run: --version exited 124"
expect "a silent \$CODEX is called silent" "$(why "$tmp/mute-codex")" "codex-local-review: \$CODEX=$tmp/mute-codex does not run: --version printed nothing"

# nothing that runs
h=$tmp/h3
empty "$(ext "$h" 26.930.1)"
expect "an empty extension copy alone is refused" "$(check "$h" "")" "3|"

# --- a whole review run (#568) ---
# a repository holding what the script reads, whose .claude/reviews is ignored as the real one is
sbx=$tmp/sbx
mkdir -p "$sbx/scripts"
cp "$repo/scripts/codex_local_review.sh" "$repo/scripts/v_toolchain.sh" "$sbx/scripts/"
cp "$repo/.v-version" "$repo/.vc-version" "$sbx/"
printf '.claude/\n' >"$sbx/.gitignore"
git -C "$sbx" init -q
git -C "$sbx" add -A
git -C "$sbx" -c user.name=t -c user.email=t@example.invalid commit -q -m sandbox
short=$(git -C "$sbx" rev-parse --short=9 HEAD)
mkdir -p "$tmp/flock-tool" "$tmp/perl-tool"
ln -s "$(command -v flock)" "$tmp/flock-tool/flock"
ln -s "$(command -v perl)" "$tmp/perl-tool/perl"

# the stub: logs "start <tag> <its parent, the script>", waits for $STUB_HOLD to exist if set, and
# notes whether fd 9 is open. It writes what codex writes: a transcript on stdout (header with the
# workdir, the prompt it read, the final message twice) and, as --output-last-message, the final
# message as codex renders a review's — a verdict, "Full review comments:" and one line per finding.
# $STUB_WORKDIR stands for another checkout, $STUB_PROMPT for another run's prompt, $STUB_FOREIGN
# for a final message the transcript lacks.
cat >"$tmp/review-codex" <<'STUB'
#!/bin/sh
if [ "$1" = --version ]; then echo "codex-cli 0.0.0-test"; exit 0; fi
out=$5
prompt=$(cat)
echo "start $STUB_TAG $PPID" >>"$STUB_LOG"
if (: >&9) 2>/dev/null; then echo "fd9 $STUB_TAG" >>"$STUB_LOG"; fi # a subshell: dash exits on a bad fd
if [ -n "${STUB_HOLD:-}" ]; then
	n=0
	while [ ! -e "$STUB_HOLD" ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n+1)); done
fi
echo "end $STUB_TAG" >>"$STUB_LOG"
final="One defect: the probe misreads an empty file.

Full review comments:

- [P2] Refuse an empty file — $PWD/scripts/codex_local_review.sh:1-2
  An empty candidate is run and exits 0."
printf 'OpenAI Codex v0.0.0-test\n--------\nworkdir: %s\nmodel: m\n--------\nuser\n%s\ncodex\n%s\n%s\n' \
	"${STUB_WORKDIR:-$PWD}" "${STUB_PROMPT:-$prompt}" "$final" "$final"
if [ -n "${STUB_FOREIGN:-}" ]; then final="Another branch: nothing found.$final"; fi
printf '%s\n' "$final" >"$out"
STUB
chmod +x "$tmp/review-codex"

# review <home> <extra PATH> <tag> [VAR=value...]: a review run of the sandbox (with $ARGS too),
# stdout and stderr to $tmp/<tag>.out / .err, its exit status returned
review() {
	local home=$1 extra=$2 tag=$3
	shift 3
	# shellcheck disable=SC2086 # $ARGS is split on purpose: unset, it adds no argument
	env -i PATH="${extra:+$extra:}$tmp/tools" HOME="$home" CODEX="$tmp/review-codex" \
		STUB_LOG="$home/stub.log" STUB_TAG="$tag" "$@" \
		timeout 60 bash "$sbx/scripts/codex_local_review.sh" --base HEAD ${ARGS:-} >"$tmp/$tag.out" 2>"$tmp/$tag.err"
}
wait_for() { # wait_for <file> <text>: up to 15 s for <file> to hold <text>
	local n=0
	while ! grep -qF -- "$2" "$1" 2>/dev/null && [ $n -lt 150 ]; do sleep 0.1; n=$((n+1)); done
	grep -qF -- "$2" "$1" 2>/dev/null
}

# serialise <mode> <extra PATH of A> <extra PATH of B and C>: run A holds the lock until released;
# run B waits for it, naming A's pid, and starts only once A has ended; run C, with
# CODEX_REVIEW_NO_WAIT=1, refuses
serialise() {
	local mode=$1 extra_a=$2 extra=$3 home=$tmp/lock-$1 a b c apid
	mkdir -p "$home"
	review "$home" "$extra_a" "$mode-A" STUB_HOLD="$home/release" &
	a=$!
	wait_for "$home/stub.log" "start $mode-A "
	apid=$(sed -n "s/^start $mode-A //p" "$home/stub.log")
	review "$home" "$extra" "$mode-B" &
	b=$!
	wait_for "$tmp/$mode-B.err" "waiting for another local review (pid $apid) to finish"
	expect "$mode: a second run says whose review it waits for" "$(grep -c "waiting for another local review (pid $apid) to finish" "$tmp/$mode-B.err")" 1
	review "$home" "$extra" "$mode-C" CODEX_REVIEW_NO_WAIT=1
	c=$?
	expect "$mode: CODEX_REVIEW_NO_WAIT=1 refuses while another review runs" \
		"$c|$(cat "$tmp/$mode-C.err")" \
		"5|codex-local-review: another local review (pid $apid) is running; CODEX_REVIEW_NO_WAIT=1 refuses to wait"
	expect "$mode: nothing else started while the first held the lock" "$(grep -v '^fd9' "$home/stub.log" | cut -d' ' -f1,2 | tr '\n' ' ')" "start $mode-A "
	: >"$home/release"
	wait "$a"
	a=$?
	wait "$b"
	b=$?
	expect "$mode: both runs pass, one after the other" "$a $b|$(grep -v '^fd9' "$home/stub.log" | cut -d' ' -f1,2 | tr '\n' ' ')" \
		"0 0|start $mode-A end $mode-A start $mode-B end $mode-B "
	expect "$mode: the second run prints its own summary, unwarned" "$(head -1 "$tmp/$mode-B.out")|$(grep -c WARNING "$tmp/$mode-B.err")" \
		"One defect: the probe misreads an empty file.|0"
}
serialise flock "$tmp/flock-tool" "$tmp/flock-tool"
expect "flock: codex holds the lock's descriptor" "$(grep -c '^fd9' "$tmp/lock-flock/stub.log")" 2
serialise perl "$tmp/perl-tool" "$tmp/perl-tool"
expect "perl: codex holds the lock's descriptor" "$(grep -c '^fd9' "$tmp/lock-perl/stub.log")" 2
# two sessions of one user, the flock command on the PATH of one only: one kernel lock either way
serialise flock-first "$tmp/flock-tool" "$tmp/perl-tool"
serialise perl-first "$tmp/perl-tool" "$tmp/flock-tool"

# a run killed with SIGKILL, its EXIT trap skipped: its codex, still running, keeps the lock, and
# the kernel lets go of it once that ends
home=$tmp/lock-killed
mkdir -p "$home"
(review "$home" "$tmp/perl-tool" killed-A STUB_HOLD="$home/release") 2>/dev/null & # bash would report the kill
wait_for "$home/stub.log" "start killed-A "
kpid=$(sed -n 's/^start killed-A //p' "$home/stub.log")
kill -9 "$kpid"
while kill -0 "$kpid" 2>/dev/null; do sleep 0.1; done
review "$home" "$tmp/flock-tool" killed-B CODEX_REVIEW_NO_WAIT=1
expect "a killed run's codex still holds the lock, said as such" "$?|$(cat "$tmp/killed-B.err")" \
	"5|codex-local-review: another local review (pid $kpid, ended; a process it started holds $home/.codex-local-review.lock) is running; CODEX_REVIEW_NO_WAIT=1 refuses to wait"
: >"$home/release"
wait_for "$home/stub.log" "end killed-A"
n=0
while ! review "$home" "$tmp/flock-tool" killed-C CODEX_REVIEW_NO_WAIT=1 && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
expect "the lock is free once that codex has ended" "$(grep -c 'is running' "$tmp/killed-C.err")" 0
wait

# with neither the flock command nor perl, the run says so and reviews unlocked
mkdir -p "$tmp/lock-none"
review "$tmp/lock-none" "" none
expect "with no lock tool the run warns and reviews" "$?|$(grep -c 'WARNING: no flock or perl' "$tmp/none.err")" "0|1"

# the summary is the one codex recorded for this run, or the run warns
home=$tmp/sum
mkdir -p "$home"
review "$home" "$tmp/flock-tool" sum-ok
expect "a summary the transcript records for this run is printed plainly" "$?|$(grep -c WARNING "$tmp/sum-ok.err")" "0|0"
review "$home" "$tmp/flock-tool" sum-foreign STUB_FOREIGN=1
expect "a summary the transcript does not hold is printed under a WARNING" \
	"$(head -1 "$tmp/sum-foreign.out")|$(grep -c "WARNING: this summary may be another review's, not $short's: the summary is not the transcript's" "$tmp/sum-foreign.err")" \
	"Another branch: nothing found.One defect: the probe misreads an empty file.|1"
review "$home" "$tmp/flock-tool" sum-elsewhere STUB_WORKDIR=/elsewhere
expect "a transcript of another checkout is warned about" "$(grep -c "the transcript is not of this checkout" "$tmp/sum-elsewhere.err")" 1
review "$home" "$tmp/flock-tool" sum-prompt STUB_PROMPT='Review the changes on this branch: `git diff 1 2`.'
expect "a transcript of another run's prompt is warned about" "$(grep -c "the transcript does not hold this run's prompt" "$tmp/sum-prompt.err")" 1
ARGS=--dry-run review "$home" "$tmp/flock-tool" prompt
expect "the prompt asks nothing of the final message's shape" "$(grep -c "final message" "$tmp/prompt.out")" 0

echo "codex_local_review_test: $pass passed, $fail failed"
[ "$fail" = 0 ]
