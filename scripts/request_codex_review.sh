#!/usr/bin/env bash
# Record a freshness baseline for one @codex review round, then either print or
# post the review request.
set -eu

cd "$(dirname "$0")/.."
. scripts/codex_review_common.sh

usage() {
	cat <<'USAGE'
usage: scripts/request_codex_review.sh PR [--repo OWNER/REPO] --post [--state-dir DIR]

With --post, comments @codex review and creates DIR/pr-PR.env with the PR
head SHA, the request marker, and the highest relevant GitHub ids.
USAGE
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
esac
[ "$#" -ge 1 ] || { usage; exit 64; }
PR=$1
shift
REPO=
POST=0
STATE_DIR=.claude/reviews

while [ "$#" -gt 0 ]; do
	case "$1" in
		--repo) [ "$#" -ge 2 ] || codex_review_die "--repo needs a value"; REPO=$2; shift 2 ;;
		--post) POST=1; shift ;;
		--state-dir) [ "$#" -ge 2 ] || codex_review_die "--state-dir needs a value"; STATE_DIR=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) codex_review_die "unknown argument: $1" ;;
	esac
done

write_state() {
	{
		printf 'PR=%s\n' "$PR"
		printf 'REPO=%s\n' "$REPO"
		printf 'SHA=%s\n' "$SHA"
		printf 'BASELINE_REVIEW_ID=%s\n' "$BASELINE_REVIEW_ID"
		printf 'BASELINE_PULL_COMMENT_ID=%s\n' "$BASELINE_PULL_COMMENT_ID"
		printf 'BASELINE_ISSUE_COMMENT_ID=%s\n' "$BASELINE_ISSUE_COMMENT_ID"
		printf 'BASELINE_FAILURE_COMMENT_ID=%s\n' "$BASELINE_FAILURE_COMMENT_ID"
		printf 'REQUEST_COMMENT_ID=%s\n' "$REQUEST_COMMENT_ID"
		printf 'REQUESTED_AT=%s\n' "$REQUESTED_AT"
		printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} >"$STATE_FILE"
}

check_remote_pending_request() {
	_tmp=$(mktemp)
	_state=$(mktemp)
	codex_review_gh_tsv "$REPO" "issues/$PR/comments" '.[] | [.id, .created_at, ((.body // "") | gsub("\n"; " "))] | @tsv' "$_tmp"
	_marker=$(awk -F '\t' -v sha="$CURRENT_SHA" '
		index($0, "codex-review-state: " sha) {
			id = $1 + 0
			created = $2
		}
		END {
			if (id > 0) printf "%d\t%s\n", id, created
		}
	' "$_tmp")
	rm -f "$_tmp"
	if [ -z "$_marker" ]; then
		rm -f "$_state"
		return 0
	fi
	_marker_id=$(printf '%s' "$_marker" | awk -F '\t' '{ print $1 }')
	_marker_created=$(printf '%s' "$_marker" | awk -F '\t' '{ print $2 }')
	{
		printf 'PR=%s\n' "$PR"
		printf 'REPO=%s\n' "$REPO"
		printf 'SHA=%s\n' "$CURRENT_SHA"
		printf 'BASELINE_REVIEW_ID=0\n'
		printf 'BASELINE_PULL_COMMENT_ID=0\n'
		printf 'BASELINE_ISSUE_COMMENT_ID=%s\n' "$_marker_id"
		printf 'BASELINE_FAILURE_COMMENT_ID=%s\n' "$_marker_id"
		printf 'REQUEST_COMMENT_ID=%s\n' "$_marker_id"
		printf 'REQUESTED_AT=%s\n' "$_marker_created"
	} >"$_state"
	set +e
	./scripts/codex_review_watch.sh --state "$_state" --once >/tmp/codex-review-remote-$$ 2>&1
	existing_rc=$?
	set -e
	rm -f "$_state"
	case "$existing_rc" in
		0|20|30|40)
			rm -f /tmp/codex-review-remote-$$
			return 0
			;;
		1)
			cat /tmp/codex-review-remote-$$ >&2
			rm -f /tmp/codex-review-remote-$$
			codex_review_die "same-SHA review is already pending from request comment $_marker_id"
			;;
		*)
			cat /tmp/codex-review-remote-$$ >&2
			rm -f /tmp/codex-review-remote-$$
			codex_review_die "could not determine whether remote same-SHA request $_marker_id is still pending"
			;;
	esac
}

if [ -z "$REPO" ]; then
	REPO=$(codex_review_repo_slug) || codex_review_die "could not infer GitHub repo from origin"
fi
REQUESTED_PR=$PR
REQUESTED_REPO=$REPO

command -v gh >/dev/null 2>&1 || codex_review_die "gh is required"
if [ "$POST" -ne 1 ]; then
	echo "Manual mode cannot create a safe watcher baseline because the review result must be"
	echo "tied to the actual request comment. Re-run with --post from an authorized account."
	echo
	echo "PR comment:"
	echo "@codex review"
	exit 0
fi

SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')
[ -n "$SHA" ] || codex_review_die "could not read PR head SHA"
LOCAL_SHA=$(git rev-parse HEAD)
if [ "$LOCAL_SHA" != "$SHA" ]; then
	codex_review_die "local HEAD $LOCAL_SHA does not match PR head $SHA; push/pull before requesting review"
fi
CURRENT_SHA=$SHA
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/pr-$PR.env"
if [ -f "$STATE_FILE" ]; then
	# shellcheck disable=SC1090
	. "$STATE_FILE"
	STATE_PR=${PR:-}
	STATE_REPO=${REPO:-}
	STATE_SHA=${SHA:-}
	STATE_REQUEST_COMMENT_ID=${REQUEST_COMMENT_ID:-}
	STATE_REQUESTED_AT=${REQUESTED_AT:-}
	PR=$REQUESTED_PR
	REPO=$REQUESTED_REPO
	SHA=$CURRENT_SHA
	if [ "$STATE_PR" = "$REQUESTED_PR" ] && [ "$STATE_REPO" = "$REQUESTED_REPO" ] && [ "$STATE_SHA" = "$CURRENT_SHA" ]; then
		if [ -n "$STATE_REQUEST_COMMENT_ID" ] && [ -z "$STATE_REQUESTED_AT" ]; then
			codex_review_die "same-SHA review has a request comment but no timestamp; inspect $STATE_FILE before retrying"
		fi
		set +e
		./scripts/codex_review_watch.sh --state "$STATE_FILE" --once >/tmp/codex-review-existing-$$ 2>&1
		existing_rc=$?
		set -e
		case "$existing_rc" in
			0|20|30|40)
				;;
			1)
				cat /tmp/codex-review-existing-$$ >&2
				rm -f /tmp/codex-review-existing-$$
				codex_review_die "same-SHA review is still pending; wait for it before requesting another round"
				;;
			*)
				cat /tmp/codex-review-existing-$$ >&2
				rm -f /tmp/codex-review-existing-$$
				codex_review_die "could not determine whether the same-SHA review is still pending"
				;;
		esac
		rm -f /tmp/codex-review-existing-$$
	fi
fi
SHA=$CURRENT_SHA
PR=$REQUESTED_PR
REPO=$REQUESTED_REPO
check_remote_pending_request

REVIEWS_ID_JQ='.[] | .id'
COMMENTS_ID_JQ='.[] | .id'
BASELINE_REVIEW_ID=$(codex_review_max_id "$REPO" "pulls/$PR/reviews" "$REVIEWS_ID_JQ")
BASELINE_PULL_COMMENT_ID=$(codex_review_max_id "$REPO" "pulls/$PR/comments" "$COMMENTS_ID_JQ")
BASELINE_ISSUE_COMMENT_ID=$(codex_review_max_id "$REPO" "issues/$PR/comments" "$COMMENTS_ID_JQ")
BASELINE_FAILURE_COMMENT_ID=$BASELINE_ISSUE_COMMENT_ID

LATEST_SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')
if [ "$LATEST_SHA" != "$CURRENT_SHA" ]; then
	codex_review_die "PR head changed from $CURRENT_SHA to $LATEST_SHA while preparing the request; retry"
fi
REQUEST_BODY=$(printf '@codex review\n\ncodex-review-state: %s\n' "$SHA")
REQUEST_URL=$(gh pr comment "$PR" --repo "$REPO" --body "$REQUEST_BODY")
REQUEST_COMMENT_ID=${REQUEST_URL##*issuecomment-}
[ "$REQUEST_COMMENT_ID" != "$REQUEST_URL" ] || codex_review_die "could not parse request comment id: $REQUEST_URL"
BASELINE_ISSUE_COMMENT_ID=$REQUEST_COMMENT_ID
BASELINE_FAILURE_COMMENT_ID=$REQUEST_COMMENT_ID
REQUESTED_AT=
write_state

if ! REQUESTED_AT=$(codex_review_gh_one "$REPO" "issues/comments/$REQUEST_COMMENT_ID" '.created_at'); then
	echo "codex-review: request was posted but its timestamp could not be read; state was saved at $STATE_FILE" >&2
	exit 70
fi
write_state

echo "$REQUEST_URL"
echo "requested @codex review for $REPO#$PR at $SHA"
echo
echo "Watch it with:"
echo "scripts/codex_review_watch.sh --state $(codex_review_shell_quote "$STATE_FILE")"
