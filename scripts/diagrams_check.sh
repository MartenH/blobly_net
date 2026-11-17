#!/usr/bin/env bash
# diagrams_check.sh — every docs/*.drawio.svg is what its script in docs/diagrams/ draws. A
# diagram is edited in its script and regenerated (python3 docs/diagrams/<name>.py docs), so a
# committed SVG that differs was edited by hand or not regenerated, and the next regeneration
# would silently undo or drop that change. Fails naming the file.
set -euo pipefail
shopt -s nullglob
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
	[ -e "$tmp/$(basename "$svg")" ] || { echo "diagrams_check: docs/$(basename "$svg") has no script in docs/diagrams/" >&2; fail=1; }
done
made=("$tmp"/*.drawio.svg)
[ "${#made[@]}" -gt 0 ] || { echo "diagrams_check: no script in docs/diagrams/ drew a *.drawio.svg" >&2; fail=1; }
[ "$fail" = 0 ] && echo "diagrams_check: ${#made[@]} diagram(s) match their scripts"
exit "$fail"
