#!/usr/bin/env bash
# Shared helpers for the Codex review scripts. Sourced, not executed.

codex_review_die() {
	echo "codex-review: $*" >&2
	exit 64
}

codex_review_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null
}

codex_review_repo_slug() {
	_url=$(git config --get remote.origin.url || true)
	case "$_url" in
		git@github.com:*)
			_slug=${_url#git@github.com:}
			printf '%s\n' "${_slug%.git}"
			;;
		ssh://git@github.com/*)
			_slug=${_url#ssh://git@github.com/}
			printf '%s\n' "${_slug%.git}"
			;;
		https://github.com/*.git)
			_slug=${_url#https://github.com/}
			printf '%s\n' "${_slug%.git}"
			;;
		https://github.com/*)
			printf '%s\n' "${_url#https://github.com/}"
			;;
		*)
			return 1
			;;
	esac
}

codex_review_gh_tsv() {
	_repo=$1
	_path=$2
	_jq=$3
	_out=$4

	gh api --paginate "repos/$_repo/$_path" --jq "$_jq" >"$_out"
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		echo "codex-review: gh api failed ($_rc): repos/$_repo/$_path" >&2
		return "$_rc"
	fi
	return 0
}

codex_review_gh_one() {
	_repo=$1
	_path=$2
	_jq=$3

	gh api "repos/$_repo/$_path" --jq "$_jq"
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		echo "codex-review: gh api failed ($_rc): repos/$_repo/$_path" >&2
		return "$_rc"
	fi
	return 0
}

codex_review_max_id() {
	_repo=$1
	_path=$2
	_jq=$3
	_tmp=$(mktemp)
	codex_review_gh_tsv "$_repo" "$_path" "$_jq" "$_tmp"
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		rm -f "$_tmp"
		return "$_rc"
	fi
	awk 'BEGIN { max = 0 } /^[0-9]+$/ { if ($1 + 0 > max) max = $1 + 0 } END { print max }' "$_tmp"
	rm -f "$_tmp"
	return 0
}

codex_review_shell_quote() {
	printf '%q' "$1"
}
