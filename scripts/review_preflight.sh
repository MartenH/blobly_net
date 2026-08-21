#!/usr/bin/env bash
# Cheap checks before starting this repo's review flow.
set -eu

cd "$(dirname "$0")/.."

if ! branch=$(git symbolic-ref --quiet --short HEAD); then
	echo "review-preflight: detached HEAD; create/use a named worktree branch first" >&2
	exit 1
fi

git_dir=$(git rev-parse --git-dir)
git_common_dir=$(git rev-parse --git-common-dir)
git_dir_abs=$(cd "$git_dir" && pwd -P) || exit
git_common_dir_abs=$(cd "$git_common_dir" && pwd -P) || exit
if [ "$git_dir_abs" = "$git_common_dir_abs" ]; then
	echo "review-preflight: this is the primary checkout, not a linked worktree" >&2
	echo "review-preflight: create/use .claude/worktrees/<name> before requesting review" >&2
	exit 1
fi

if [ "$branch" = main ]; then
	echo "review-preflight: this checkout is on main; create/use a worktree branch first" >&2
	exit 1
fi

if ! git fetch -q origin; then
	echo "review-preflight: could not fetch origin; refusing to trust a cached origin/main" >&2
	exit 1
fi

if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
	echo "review-preflight: origin/main is missing; run 'git fetch -q origin' first" >&2
	exit 1
fi

if ! git merge-base --is-ancestor origin/main HEAD; then
	echo "review-preflight: this branch does not contain current origin/main" >&2
	echo "review-preflight: fetch/rebase before trusting CLAUDE.md or requesting review" >&2
	exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
	echo "review-preflight: worktree has uncommitted or untracked files" >&2
	echo "review-preflight: commit/stash them before requesting review of the pushed head" >&2
	exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
	echo "review-preflight: gh is not installed or not on PATH" >&2
	exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
	echo "review-preflight: gh is not authenticated" >&2
	exit 1
fi

echo "review-preflight: ok ($branch contains origin/main)"
