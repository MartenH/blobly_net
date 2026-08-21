#!/usr/bin/env bash
# Watch one @codex review round. It matches verdicts by reviewed SHA and by
# freshness baselines recorded before the round was requested.
set -u

cd "$(dirname "$0")/.." || exit
. scripts/codex_review_common.sh

usage() {
	cat <<'USAGE'
usage: scripts/codex_review_watch.sh --state FILE [--once]
       scripts/codex_review_watch.sh --pr N --sha SHA [--repo OWNER/REPO] [options]

options:
  --baseline-review-id N        highest pulls/N/reviews id before request
  --baseline-issue-comment-id N highest issues/N/comments id before request
  --baseline-failure-comment-id N
  --baseline-pull-comment-id N  highest pulls/N/comments id before request
  --requested-at TIMESTAMP       request comment timestamp from GitHub
  --interval SECONDS            polling interval (default: 60)
  --timeout SECONDS             stop after this many seconds (default: 3600)
  --once                        scan once and return pending if no result is present

exit codes:
  0 clean, 1 pending/timeout, 20 findings, 30 review failed,
  40 PR head changed, 70 GitHub/API error
USAGE
}

state_file=
args=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--state)
			[ "$#" -ge 2 ] || codex_review_die "--state needs a file"
			state_file=$2
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
	esac
done

if [ -n "$state_file" ]; then
	[ -f "$state_file" ] || codex_review_die "state file not found: $state_file"
	# shellcheck disable=SC1090
	. "$state_file"
fi

# Re-parse non-state arguments after the state file so callers can override it.
set -- "${args[@]}"

PR=${PR:-}
REPO=${REPO:-}
SHA=${SHA:-}
BASELINE_REVIEW_ID=${BASELINE_REVIEW_ID:-0}
BASELINE_ISSUE_COMMENT_ID=${BASELINE_ISSUE_COMMENT_ID:-0}
BASELINE_FAILURE_COMMENT_ID=${BASELINE_FAILURE_COMMENT_ID:-0}
BASELINE_PULL_COMMENT_ID=${BASELINE_PULL_COMMENT_ID:-0}
REQUESTED_AT=${REQUESTED_AT:-}
INTERVAL=${INTERVAL:-60}
TIMEOUT=${TIMEOUT:-3600}
CODEX_REVIEW_ACTOR=${CODEX_REVIEW_ACTOR:-chatgpt-codex-connector[bot]}
ONCE=0
SAW_BASELINE_REVIEW=0
SAW_BASELINE_ISSUE=0
SAW_BASELINE_FAILURE=0
SAW_BASELINE_PULL=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--pr) [ "$#" -ge 2 ] || codex_review_die "--pr needs a value"; PR=$2; shift 2 ;;
		--repo) [ "$#" -ge 2 ] || codex_review_die "--repo needs a value"; REPO=$2; shift 2 ;;
		--sha) [ "$#" -ge 2 ] || codex_review_die "--sha needs a value"; SHA=$2; shift 2 ;;
		--baseline-review-id) [ "$#" -ge 2 ] || codex_review_die "--baseline-review-id needs a value"; BASELINE_REVIEW_ID=$2; SAW_BASELINE_REVIEW=1; shift 2 ;;
		--baseline-issue-comment-id) [ "$#" -ge 2 ] || codex_review_die "--baseline-issue-comment-id needs a value"; BASELINE_ISSUE_COMMENT_ID=$2; SAW_BASELINE_ISSUE=1; shift 2 ;;
		--baseline-failure-comment-id) [ "$#" -ge 2 ] || codex_review_die "--baseline-failure-comment-id needs a value"; BASELINE_FAILURE_COMMENT_ID=$2; SAW_BASELINE_FAILURE=1; shift 2 ;;
		--baseline-pull-comment-id) [ "$#" -ge 2 ] || codex_review_die "--baseline-pull-comment-id needs a value"; BASELINE_PULL_COMMENT_ID=$2; SAW_BASELINE_PULL=1; shift 2 ;;
		--requested-at) [ "$#" -ge 2 ] || codex_review_die "--requested-at needs a value"; REQUESTED_AT=$2; shift 2 ;;
		--interval) [ "$#" -ge 2 ] || codex_review_die "--interval needs a value"; INTERVAL=$2; shift 2 ;;
		--timeout) [ "$#" -ge 2 ] || codex_review_die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
		--once) ONCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) codex_review_die "unknown argument: $1" ;;
	esac
done

[ -n "$PR" ] || codex_review_die "--pr is required"
[ -n "$SHA" ] || codex_review_die "--sha is required"
if [ -n "${REQUEST_COMMENT_ID:-}" ] && [ -z "$REQUESTED_AT" ]; then
	codex_review_die "state has REQUEST_COMMENT_ID but no REQUESTED_AT"
fi
case "$INTERVAL" in
	''|*[!0-9]*) codex_review_die "--interval must be a positive integer" ;;
esac
[ "$INTERVAL" -gt 0 ] || codex_review_die "--interval must be a positive integer"
case "$TIMEOUT" in
	''|*[!0-9]*) codex_review_die "--timeout must be a positive integer" ;;
esac
[ "$TIMEOUT" -gt 0 ] || codex_review_die "--timeout must be a positive integer"
if [ -z "$state_file" ] && [ -z "$REQUESTED_AT" ]; then
	if [ "$SAW_BASELINE_REVIEW" -ne 1 ] || [ "$SAW_BASELINE_PULL" -ne 1 ] ||
		[ "$SAW_BASELINE_ISSUE" -ne 1 ] || [ "$SAW_BASELINE_FAILURE" -ne 1 ]; then
		codex_review_die "direct mode requires --requested-at or all verdict freshness baselines"
	fi
fi
if [ -z "$REPO" ]; then
	REPO=$(codex_review_repo_slug) || codex_review_die "could not infer GitHub repo from origin"
fi

SHA_PREFIX=$(printf '%s' "$SHA" | cut -c1-10)
REVIEW_MARKER='Reviewed commit:**'
REVIEW_MARKER_FULL="$REVIEW_MARKER \`$SHA\`"
REVIEW_MARKER_PREFIX="$REVIEW_MARKER \`$SHA_PREFIX\`"
REVIEWS_JQ='.[] | [.id, .submitted_at, (.user.login // ""), ((.body // "") | gsub("\n"; " "))] | @tsv'
ISSUE_COMMENTS_JQ='.[] | [.id, .created_at, (.user.login // ""), ((.body // "") | gsub("\n"; " "))] | @tsv'
PULL_COMMENTS_JQ='.[] | [.id, ((.body // "") | gsub("\n"; " ")), (.commit_id // ""), (.user.login // "")] | @tsv'

head_still_current() {
	_current_head=$(codex_review_gh_one "$REPO" "pulls/$PR" '.head.sha') || return 70
	if [ "$_current_head" != "$SHA" ]; then
		printf 'RESULT=stale_head\n'
		printf 'PR=%s\nSHA=%s\nCURRENT_SHA=%s\n' "$PR" "$SHA" "$_current_head"
		return 40
	fi
	return 0
}

scan_once() {
	_reviews=$(mktemp)
	_issues=$(mktemp)
	_pull_comments=$(mktemp)
	trap 'rm -f "$_reviews" "$_issues" "$_pull_comments"' RETURN

	head_still_current || return "$?"

	codex_review_gh_tsv "$REPO" "pulls/$PR/reviews" "$REVIEWS_JQ" "$_reviews" || return 70
	_review_match=$(awk -F '\t' -v min="$BASELINE_REVIEW_ID" -v requested="$REQUESTED_AT" -v actor="$CODEX_REVIEW_ACTOR" -v full="$REVIEW_MARKER_FULL" -v short="$REVIEW_MARKER_PREFIX" '
		$1 + 0 > min && $3 == actor && (requested == "" || $2 >= requested) && (index($4, full) || index($4, short)) {
			id = $1 + 0
			body = $4
		}
		END {
			if (id > 0) printf "%d\t%s\n", id, body
		}
	' "$_reviews")
	if [ -n "$_review_match" ]; then
		codex_review_gh_tsv "$REPO" "pulls/$PR/comments" "$PULL_COMMENTS_JQ" "$_pull_comments" || return 70
		_comment_count=$(awk -F '\t' -v min="$BASELINE_PULL_COMMENT_ID" -v actor="$CODEX_REVIEW_ACTOR" -v sha="$SHA" -v prefix="$SHA_PREFIX" '
			$1 + 0 > min && $4 == actor && (index($0, sha) || index($0, prefix) || index($3, sha) == 1 || index($3, prefix) == 1) { count++ }
			END { print count + 0 }
		' "$_pull_comments")
		head_still_current || return "$?"
		printf 'RESULT=findings\n'
		printf 'PR=%s\nSHA=%s\nSHA_PREFIX=%s\n' "$PR" "$SHA" "$SHA_PREFIX"
		printf 'REVIEW_ID=%s\nPULL_COMMENTS=%s\n' "$(printf '%s' "$_review_match" | awk -F '\t' '{ print $1 }')" "$_comment_count"
		return 20
	fi

	codex_review_gh_tsv "$REPO" "issues/$PR/comments" "$ISSUE_COMMENTS_JQ" "$_issues" || return 70
	_clean_match=$(awk -F '\t' -v min="$BASELINE_ISSUE_COMMENT_ID" -v requested="$REQUESTED_AT" -v actor="$CODEX_REVIEW_ACTOR" -v full="$REVIEW_MARKER_FULL" -v short="$REVIEW_MARKER_PREFIX" '
		$1 + 0 > min && $3 == actor && (requested == "" || $2 >= requested) && (index($4, full) || index($4, short)) {
			id = $1 + 0
			body = $4
		}
		END {
			if (id > 0) printf "%d\t%s\n", id, body
		}
	' "$_issues")
	if [ -n "$_clean_match" ]; then
		head_still_current || return "$?"
		printf 'RESULT=clean\n'
		printf 'PR=%s\nSHA=%s\nSHA_PREFIX=%s\n' "$PR" "$SHA" "$SHA_PREFIX"
		printf 'ISSUE_COMMENT_ID=%s\n' "$(printf '%s' "$_clean_match" | awk -F '\t' '{ print $1 }')"
		return 0
	fi

	_failed_match=$(awk -F '\t' -v min="$BASELINE_FAILURE_COMMENT_ID" -v requested="$REQUESTED_AT" -v actor="$CODEX_REVIEW_ACTOR" '
		$1 + 0 > min && $3 == actor && (requested == "" || $2 >= requested) && index($4, "Something went wrong") {
			id = $1 + 0
			body = $4
		}
		END {
			if (id > 0) printf "%d\t%s\n", id, body
		}
	' "$_issues")
	if [ -n "$_failed_match" ]; then
		head_still_current || return "$?"
		printf 'RESULT=failed\n'
		printf 'PR=%s\nSHA=%s\nSHA_PREFIX=%s\n' "$PR" "$SHA" "$SHA_PREFIX"
		printf 'ISSUE_COMMENT_ID=%s\n' "$(printf '%s' "$_failed_match" | awk -F '\t' '{ print $1 }')"
		return 30
	fi

	printf 'RESULT=pending\n'
	printf 'PR=%s\nSHA=%s\nSHA_PREFIX=%s\n' "$PR" "$SHA" "$SHA_PREFIX"
	printf 'REVIEWS_AFTER_BASELINE=%s\n' "$(awk -F '\t' -v min="$BASELINE_REVIEW_ID" '$1 + 0 > min { count++ } END { print count + 0 }' "$_reviews")"
	printf 'ISSUE_COMMENTS_AFTER_BASELINE=%s\n' "$(awk -F '\t' -v min="$BASELINE_ISSUE_COMMENT_ID" '$1 + 0 > min { count++ } END { print count + 0 }' "$_issues")"
	return 1
}

start=$(date +%s)
while :; do
	scan_once
	rc=$?
	case "$rc" in
		0|20|30|40|70) exit "$rc" ;;
	esac
	if [ "$ONCE" -eq 1 ]; then
		exit 1
	fi
	now=$(date +%s)
	elapsed=$((now - start))
	if [ "$elapsed" -ge "$TIMEOUT" ]; then
		echo "codex-review: timed out after ${TIMEOUT}s" >&2
		exit 1
	fi
	remaining=$((TIMEOUT - elapsed))
	sleep_for=$INTERVAL
	[ "$remaining" -lt "$sleep_for" ] && sleep_for=$remaining
	sleep "$sleep_for"
done
