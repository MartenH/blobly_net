#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."
exec python3 scripts/codex_review.py watch "$@"
