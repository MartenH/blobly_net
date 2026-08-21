#!/usr/bin/env bash
# Fixture tests for scripts/codex_review_watch.sh. The fake gh emits the TSV
# that gh --jq would have produced, so these tests exercise the watcher logic:
# endpoints, baselines, SHA matching and exit-code classification.
set -uo pipefail
cd "$(dirname "$0")/.." || exit

pass=0
fail=0
ok() {
	if [ "$2" = "$3" ]; then
		pass=$((pass+1))
	else
		fail=$((fail+1))
		echo "FAIL: $1"
		echo "  want: $3"
		echo "  got:  $2"
	fi
}

stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
cat >"$stub/git" <<'GIT'
#!/usr/bin/env bash
if [ "$1" = rev-parse ] && [ "${2:-}" = HEAD ]; then
	printf '%s\n' "${FAKE_GIT_HEAD_SHA:-abcdef1234567890abcdef1234567890abcdef12}"
	exit 0
fi
exec /usr/bin/git "$@"
GIT
chmod +x "$stub/git"
cat >"$stub/gh" <<'GH'
#!/usr/bin/env bash
endpoint=
paginate=0
head_sha=${FAKE_GH_HEAD_SHA:-abcdef1234567890abcdef1234567890abcdef12}
[ "${FAKE_GH_CASE:-}" = stale_head ] && head_sha=fedcba9876543210fedcba9876543210fedcba98
if [ "$1" = pr ] && [ "$2" = view ]; then
	printf '%s\n' "$head_sha"
	exit 0
fi
if [ "$1" = pr ] && [ "$2" = comment ]; then
	if [ "${FAKE_GH_CASE:-}" = request_success ] || [ "${FAKE_GH_CASE:-}" = request_timestamp_fail ]; then
		repo=
		while [ "$#" -gt 0 ]; do
			case "$1" in
				--repo) repo=$2; shift 2 ;;
				*) shift ;;
			esac
		done
		[ "$repo" = MartenH/blobly_net ] || { echo "wrong repo: $repo" >&2; exit 8; }
		printf 'https://github.com/MartenH/blobly_net/pull/123#issuecomment-999\n'
		exit 0
	fi
	echo "unexpected review request post" >&2
	exit 8
fi
for arg in "$@"; do
	case "$arg" in
		repos/*) endpoint=$arg ;;
		--paginate) paginate=1 ;;
	esac
done
if [ "$endpoint" = repos/MartenH/blobly_net/pulls/123 ]; then
	printf '%s\n' "$head_sha"
	exit 0
fi
if [ "$endpoint" = repos/MartenH/blobly_net/issues/comments/999 ]; then
	[ "${FAKE_GH_CASE:-}" = request_timestamp_fail ] && exit 4
	printf '2026-01-01T00:00:02Z\n'
	exit 0
fi
[ "$paginate" -eq 1 ] || { echo "missing --paginate" >&2; exit 9; }

case "${FAKE_GH_CASE:-}:$endpoint" in
	clean:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '10\t2026-01-01T00:00:00Z\tchatgpt-codex-connector[bot]\told review **Reviewed commit:** `aaaaaaaaaa`\n'
		;;
	clean:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '41\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tDone. Didn'\''t find any major issues. **Reviewed commit:** `abcdef1234`\n'
		;;
	clean_alt:repos/MartenH/blobly_net/pulls/123/reviews)
		;;
	clean_alt:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	clean_alt:repos/MartenH/blobly_net/issues/123/comments)
		printf '44\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tNo blocking defects found. **Reviewed commit:** `abcdef1234`\n'
		;;
	findings:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '11\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tP1 finding in body /blob/abcdef1234567890/file.v#L12 **Reviewed commit:** `abcdef1234`\n'
		;;
	findings:repos/MartenH/blobly_net/pulls/123/comments)
		printf '31\tinline issue\tabcdef1234567890abcdef1234567890abcdef12\tchatgpt-codex-connector[bot]\n'
		;;
	findings:repos/MartenH/blobly_net/issues/123/comments)
		;;
	body_only:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '12\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tP2 body-only issue /blob/abcdef1234567890/file.v#L44 **Reviewed commit:** `abcdef1234`\n'
		;;
	body_only:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	body_only:repos/MartenH/blobly_net/issues/123/comments)
		;;
	foreign_review:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '14\t2026-01-01T00:00:02Z\thuman\tHuman note linking /blob/abcdef1234567890/file.v#L44 without a reviewed marker\n'
		;;
	foreign_review:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	foreign_review:repos/MartenH/blobly_net/issues/123/comments)
		;;
	spoof_review:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '16\t2026-01-01T00:00:02Z\thuman\tLooks important. **Reviewed commit:** `abcdef1234`\n'
		;;
	spoof_review:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	spoof_review:repos/MartenH/blobly_net/issues/123/comments)
		;;
	foreign_clean:repos/MartenH/blobly_net/pulls/123/reviews)
		;;
	foreign_clean:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	foreign_clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '43\t2026-01-01T00:00:02Z\thuman\tDidn'\''t find any major issues while discussing abcdef1234, but no marker here.\n'
		;;
	spoof_clean:repos/MartenH/blobly_net/pulls/123/reviews)
		;;
	spoof_clean:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	spoof_clean:repos/MartenH/blobly_net/issues/123/comments)
		printf '46\t2026-01-01T00:00:02Z\thuman\tDone. **Reviewed commit:** `abcdef1234`\n'
		;;
	split_marker_sha:repos/MartenH/blobly_net/pulls/123/reviews)
		;;
	split_marker_sha:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	split_marker_sha:repos/MartenH/blobly_net/issues/123/comments)
		printf '45\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tLooks clean. Reviewed commit: `ffffffffff`; see also abcdef1234 elsewhere.\n'
		;;
	remote_pending:repos/MartenH/blobly_net/pulls/123/reviews)
		;;
	remote_pending:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	remote_pending:repos/MartenH/blobly_net/issues/123/comments)
		printf '998\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\t@codex review codex-review-state: abcdef1234567890abcdef1234567890abcdef12\n'
		;;
	early_same_sha:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '15\t2026-01-01T00:00:00Z\tchatgpt-codex-connector[bot]\tOld same-SHA result **Reviewed commit:** `abcdef1234`\n'
		;;
	early_same_sha:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	early_same_sha:repos/MartenH/blobly_net/issues/123/comments)
		;;
	old_sha:repos/MartenH/blobly_net/pulls/123/reviews)
		printf '13\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tDone. **Reviewed commit:** `ffffffffff`\n'
		;;
	old_sha:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	old_sha:repos/MartenH/blobly_net/issues/123/comments)
		printf '41\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tDone. Didn'\''t find any major issues. **Reviewed commit:** `ffffffffff`\n'
		;;
	failed:repos/MartenH/blobly_net/pulls/123/reviews)
		;;
	failed:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	failed:repos/MartenH/blobly_net/issues/123/comments)
		printf '42\t2026-01-01T00:00:02Z\tchatgpt-codex-connector[bot]\tSomething went wrong while reviewing this pull request.\n'
		;;
	ghfail:repos/MartenH/blobly_net/pulls/123/reviews)
		exit 4
		;;
	ghfail:repos/MartenH/blobly_net/pulls/123/comments)
		;;
	ghfail:repos/MartenH/blobly_net/issues/123/comments)
		;;
	*)
		;;
esac
GH
chmod +x "$stub/gh"

run_case() {
	_case=$1
	_path=$2
	FAKE_GH_CASE=$_case PATH="$stub:/usr/bin:/bin" \
		bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
		--sha abcdef1234567890abcdef1234567890abcdef12 \
		--baseline-review-id 10 \
		--baseline-pull-comment-id 30 \
		--baseline-issue-comment-id 40 \
		--baseline-failure-comment-id 40 \
		--requested-at 2026-01-01T00:00:01Z \
		--interval 1 \
		--timeout 1 \
		>"$_path" 2>&1
	printf '%s' "$?"
}

out=$(mktemp)
rc=$(run_case clean "$out")
ok "clean exits 0" "$rc" "0"
ok "clean result" "$(grep -c '^RESULT=clean$' "$out")" "1"

rc=$(run_case clean_alt "$out")
ok "alternate clean prose exits 0" "$rc" "0"
ok "alternate clean prose result" "$(grep -c '^RESULT=clean$' "$out")" "1"

rc=$(run_case findings "$out")
ok "findings exits 20" "$rc" "20"
ok "findings counts inline comments" "$(grep -c '^PULL_COMMENTS=1$' "$out")" "1"

rc=$(run_case body_only "$out")
ok "body-only findings still exit 20" "$rc" "20"
ok "body-only has zero inline comments" "$(grep -c '^PULL_COMMENTS=0$' "$out")" "1"

rc=$(run_case foreign_review "$out")
ok "foreign review mentioning SHA is pending" "$rc" "1"
ok "foreign review does not claim findings" "$(grep -c '^RESULT=findings$' "$out")" "0"

rc=$(run_case spoof_review "$out")
ok "non-Codex review with marker is pending" "$rc" "1"
ok "non-Codex review with marker does not claim findings" "$(grep -c '^RESULT=findings$' "$out")" "0"

rc=$(run_case foreign_clean "$out")
ok "foreign clean wording without marker is pending" "$rc" "1"
ok "foreign clean does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case spoof_clean "$out")
ok "non-Codex clean marker is pending" "$rc" "1"
ok "non-Codex clean marker does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case split_marker_sha "$out")
ok "split marker and SHA is pending" "$rc" "1"
ok "split marker and SHA does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case early_same_sha "$out")
ok "same-SHA result before request marker is pending" "$rc" "1"
ok "same-SHA early result does not claim findings" "$(grep -c '^RESULT=findings$' "$out")" "0"

rc=$(run_case old_sha "$out")
ok "old SHA result is pending" "$rc" "1"
ok "old SHA does not claim clean" "$(grep -c '^RESULT=clean$' "$out")" "0"

rc=$(run_case stale_head "$out")
ok "changed PR head exits 40" "$rc" "40"
ok "changed PR head result" "$(grep -c '^RESULT=stale_head$' "$out")" "1"

rc=$(run_case failed "$out")
ok "fresh failure exits 30" "$rc" "30"
ok "fresh failure result" "$(grep -c '^RESULT=failed$' "$out")" "1"

rc=$(run_case ghfail "$out")
ok "gh API failure exits 70" "$rc" "70"
ok "gh API failure is not pending" "$(grep -c '^RESULT=pending$' "$out")" "0"

bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 --interval 0 >"$out" 2>&1
ok "zero interval rejected" "$?" "64"

bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 --interval 1 >"$out" 2>&1
ok "direct watcher without freshness baseline is rejected" "$?" "64"

PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-failure-comment-id 40 --interval 1 >"$out" 2>&1
ok "direct watcher with only failure baseline is rejected" "$?" "64"

PATH="$stub:/usr/bin:/bin" bash scripts/codex_review_watch.sh --once --pr 123 --repo MartenH/blobly_net \
	--sha abcdef1234567890abcdef1234567890abcdef12 \
	--baseline-review-id 0 \
	--baseline-pull-comment-id 0 \
	--baseline-issue-comment-id 0 \
	--baseline-failure-comment-id 0 \
	--interval 1 \
	--timeout 1 >"$out" 2>&1
ok "direct watcher with explicit baselines is allowed" "$?" "1"

bash scripts/request_codex_review.sh --help >"$out" 2>&1
ok "request helper handles help before PR" "$?" "0"
ok "request helper help prints usage" "$(grep -c '^usage:' "$out")" "1"

state_missing_ts=$(mktemp -d)
cat >"$state_missing_ts/pr-123.env" <<STATE
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=999
BASELINE_FAILURE_COMMENT_ID=999
REQUEST_COMMENT_ID=999
REQUESTED_AT=
STATE
bash scripts/codex_review_watch.sh --state "$state_missing_ts/pr-123.env" --once >"$out" 2>&1
ok "state with request id but no timestamp is rejected" "$?" "64"

repo_root=$PWD
repo_tmp=$(mktemp -d)
git -C "$repo_tmp" init -q
git -C "$repo_tmp" remote add origin git@github.com:MartenH/blobly_net
slug=$(cd "$repo_tmp" && . "$repo_root/scripts/codex_review_common.sh"; codex_review_repo_slug)
ok "SSH origin without suffix" "$slug" "MartenH/blobly_net"
git -C "$repo_tmp" remote set-url origin ssh://git@github.com/MartenH/blobly_net.git
slug=$(cd "$repo_tmp" && . "$repo_root/scripts/codex_review_common.sh"; codex_review_repo_slug)
ok "ssh:// origin with suffix" "$slug" "MartenH/blobly_net"

state_dir=$(mktemp -d)
cat >"$state_dir/pr-123.env" <<STATE
PR=123
REPO=MartenH/blobly_net
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=40
BASELINE_FAILURE_COMMENT_ID=40
REQUESTED_AT=2026-01-01T00:00:01Z
STATE
FAKE_GH_CASE=manual_pending PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$state_dir" >"$out" 2>&1
ok "same-SHA pending request is rejected" "$?" "64"
ok "same-SHA pending request is explained" "$(grep -c 'same-SHA review is still pending' "$out")" "1"

FAKE_GH_CASE=ghfail PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$state_dir" >"$out" 2>&1
ok "same-SHA indeterminate scan is rejected" "$?" "64"
ok "same-SHA indeterminate scan is explained" "$(grep -c 'could not determine whether the same-SHA review is still pending' "$out")" "1"

remote_state=$(mktemp -d)
FAKE_GH_CASE=remote_pending PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$remote_state" >"$out" 2>&1
ok "remote same-SHA pending request is rejected" "$?" "64"
ok "remote same-SHA pending request is explained" "$(grep -c 'same-SHA review is already pending from request comment 998' "$out")" "1"

other_repo_state=$(mktemp -d)
cat >"$other_repo_state/pr-123.env" <<STATE
PR=123
REPO=Other/Repo
SHA=abcdef1234567890abcdef1234567890abcdef12
BASELINE_REVIEW_ID=10
BASELINE_PULL_COMMENT_ID=30
BASELINE_ISSUE_COMMENT_ID=40
BASELINE_FAILURE_COMMENT_ID=40
REQUESTED_AT=2026-01-01T00:00:01Z
STATE
FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$other_repo_state" >"$out" 2>&1
ok "old state for another repo does not retarget request" "$?" "0"
ok "new state preserves requested repo" "$(grep -c '^REPO=MartenH/blobly_net$' "$other_repo_state/pr-123.env")" "1"

mismatch_state=$(mktemp -d)
FAKE_GIT_HEAD_SHA=fedcba9876543210fedcba9876543210fedcba98 FAKE_GH_CASE=request_success PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$mismatch_state" >"$out" 2>&1
ok "request helper rejects PR head that differs from local HEAD" "$?" "64"
ok "request helper explains local/remote mismatch" "$(grep -c 'does not match PR head' "$out")" "1"

timestamp_fail_state=$(mktemp -d)
FAKE_GH_CASE=request_timestamp_fail PATH="$stub:/usr/bin:/bin" \
	bash scripts/request_codex_review.sh 123 --repo MartenH/blobly_net --post --state-dir "$timestamp_fail_state" >"$out" 2>&1
ok "posted request with failed timestamp exits API error" "$?" "70"
ok "posted request state is persisted before timestamp lookup" "$(grep -c '^REQUEST_COMMENT_ID=999$' "$timestamp_fail_state/pr-123.env")" "1"

echo "codex_review_watch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
