#!/usr/bin/env bash
# diagrams_check.sh — every docs/*.drawio.svg is what its script in docs/diagrams/ draws. A
# diagram is edited in its script and regenerated (python3 docs/diagrams/<name>.py docs), so a
# committed SVG that differs was edited by hand or not regenerated, and the next regeneration
# would silently undo or drop that change. Fails naming the file.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for script in "$repo"/docs/diagrams/*.py; do
	[ "$(basename "$script")" = drawio.py ] && continue
	python3 "$script" "$tmp"
done
fail=0
for svg in "$tmp"/*.drawio.svg; do
	name="$(basename "$svg")"
	if ! cmp -s "$svg" "$repo/docs/$name"; then
		echo "diagrams_check: docs/$name differs from what its script draws — run: python3 docs/diagrams/<script>.py docs" >&2
		fail=1
	fi
done
for svg in "$repo"/docs/*.drawio.svg; do
	[ -e "$svg" ] || continue
	[ -e "$tmp/$(basename "$svg")" ] || { echo "diagrams_check: docs/$(basename "$svg") has no script in docs/diagrams/" >&2; fail=1; }
done
[ "$fail" = 0 ] && echo "diagrams_check: $(ls "$tmp"/*.drawio.svg | wc -l) diagram(s) match their scripts"
exit "$fail"
