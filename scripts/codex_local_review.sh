#!/usr/bin/env bash
# A local codex review of this branch, run BEFORE `@codex review` is requested on the PR.
#
#   scripts/codex_local_review.sh            # gpt-6.1-sol, high effort, against origin/main
#   scripts/codex_local_review.sh --astra    # gpt-6-astra, xhigh (slower; for risky changes)
#   scripts/codex_local_review.sh --model M --effort E --base REF --dry-run
#
# It reviews COMMITTED work only (merge-base of REF and HEAD, to HEAD). The full transcript is
# kept under .claude/reviews/, and the final message (the findings) is printed.
#
# The prompt asks for EVERY defect rather than the default review's short list: on #378's first
# round the default prompt found 1-2.5 of the 6 findings GitHub's codex reported, and this one
# found 4 (plus 2 GitHub only reported two and three rounds later). It does not replace
# `@codex review` -- it still missed the protocol-semantic ones -- it front-loads what it can.
set -eu

cd "$(dirname "$0")/.."

model=gpt-6.1-sol
effort=high
base=origin/main
dry_run=0
while [ $# -gt 0 ]; do
	case "$1" in
	--model) model=$2; shift 2 ;;
	--effort) effort=$2; shift 2 ;;
	--base) base=$2; shift 2 ;;
	--astra) model=gpt-6-astra; effort=xhigh; shift ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "codex-local-review: unknown argument: $1" >&2; exit 2 ;;
	esac
done

# The codex CLI: $CODEX, then PATH, then the newest copy the VS Code extension bundles.
codex=${CODEX:-}
if [ -z "$codex" ]; then
	codex=$(command -v codex || true)
fi
if [ -z "$codex" ]; then
	codex=$(ls -1d "$HOME"/.vscode-server/extensions/openai.chatgpt-*/bin/*/codex 2>/dev/null | sort -V | tail -1 || true)
fi
if [ -z "$codex" ] || [ ! -x "$codex" ]; then
	echo "codex-local-review: no codex CLI found (set CODEX=/path/to/codex)" >&2
	exit 3
fi

if [ "$base" = origin/main ] && ! git fetch -q origin; then
	echo "codex-local-review: could not fetch origin; refusing to review against a stale origin/main" >&2
	exit 1
fi
merge_base=$(git merge-base "$base" HEAD)
head=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "codex-local-review: note: uncommitted changes are NOT reviewed; commit them first" >&2
fi

# The V that matches .v-version, so the review runs tests instead of hunting for a compiler.
pin=$(tr -d '[:space:]' < .v-version | cut -c1-7)
v_bin=
for cand in "${V:-}" "$HOME/v/v" "$HOME/vpin/v" "$(command -v v || true)"; do
	if [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -old-compiler version 2>/dev/null | grep -q "$pin"; then
		v_bin=$cand
		break
	fi
done
if [ -n "$v_bin" ]; then
	v_note="The V toolchain is \`$v_bin\` (the commit .v-version pins). Run it with \`VFLAGS=-old-compiler\`, e.g. \`VFLAGS=-old-compiler $v_bin -enable-globals test modules/<module>/\`. Do not look for other V installations. Network sockets are allowed, so the UDP/TCP tests can run."
else
	v_note="No V matching .v-version ($pin) was found on this machine; review statically and say that tests were not run."
	echo "codex-local-review: warning: no V at $pin found; the review will not run tests" >&2
fi

prompt="Review the changes on this branch: \`git diff $merge_base HEAD\` (HEAD is $head).

Report EVERY defect you find, not only the most important ones. Include minor ones and edge cases: wire-level and protocol behaviour, inputs at or past their limits, timing and deadlines, error paths, data that is accepted and then lost or silently altered, and inconsistencies between what an API accepts and what it can actually do. Do not filter for importance or for how likely the case is; the author triages. Exclude pure style with no behavioural consequence, and values no caller could plausibly pass (an integer near its type's overflow) unless they arrive from outside (a file, the wire, a project).

For each finding give a priority (P1/P2/P3), the file and line range, and a concrete scenario: the input or state, and the wrong result.

$v_note"

mkdir -p .claude/reviews
branch=$(git symbolic-ref --quiet --short HEAD || echo detached)
out=.claude/reviews/local-${branch//\//-}-$head-$model.txt
cmd=("$codex" review -
	-c "model=$model" -c "review_model=$model" -c "model_reasoning_effort=$effort"
	-c sandbox_workspace_write.network_access=true
	-c "sandbox_workspace_write.writable_roots=[\"$HOME/.vmodules/.cache\"]")

if [ "$dry_run" = 1 ]; then
	printf '%q ' "${cmd[@]}"
	printf '\n\n%s\n' "$prompt"
	exit 0
fi

echo "codex-local-review: $model ($effort) on $head against $base; transcript: $out" >&2
start=$(date +%s)
status=0
printf '%s\n' "$prompt" | "${cmd[@]}" > "$out" 2>&1 || status=$?
echo "codex-local-review: finished in $(( $(date +%s) - start )) s, exit $status" >&2
# The final message follows the last line that is exactly `codex`; it is printed twice.
awk '/^codex$/ { buf = ""; on = 1; next } on { buf = buf $0 "\n" } END { printf "%s", buf }' "$out" | awk '$0 == "" || !seen[$0]++' | cat -s
exit $status
