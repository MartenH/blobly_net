#!/usr/bin/env bash
# diagrams_check.sh — every docs/*.drawio.svg is what its script in docs/diagrams/ draws. A
# diagram is edited in its script and regenerated (python3 docs/diagrams/<name>.py docs), so a
# committed SVG that differs was edited by hand or not regenerated, and the next regeneration
# would silently undo or drop that change. Each script draws into a folder of its own, so two
# scripts drawing one file is refused rather than one overwriting the other. Fails naming the
# file and the script that draws it.
set -euo pipefail
shopt -s nullglob
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
declare -A drawn_by=()
fail=0
for script in "$repo"/docs/diagrams/*.py; do
	base="$(basename "$script")"
	[ "$base" = drawio.py ] && continue
	out="$tmp/${base%.py}"
	mkdir "$out"
	python3 "$script" "$out"
	made=("$out"/*.drawio.svg)
	[ "${#made[@]}" -gt 0 ] || { echo "diagrams_check: docs/diagrams/$base drew no *.drawio.svg" >&2; fail=1; }
	for svg in "${made[@]}"; do
		name="$(basename "$svg")"
		if [ -n "${drawn_by[$name]:-}" ]; then
			echo "diagrams_check: docs/$name is drawn by both docs/diagrams/${drawn_by[$name]} and docs/diagrams/$base" >&2
			fail=1
			continue
		fi
		drawn_by[$name]=$base
		if ! cmp -s "$svg" "$repo/docs/$name"; then
			echo "diagrams_check: docs/$name differs from what its script draws — run: python3 docs/diagrams/$base docs" >&2
			fail=1
		fi
	done
done
for svg in "$repo"/docs/*.drawio.svg; do
	name="$(basename "$svg")"
	[ -n "${drawn_by[$name]:-}" ] || { echo "diagrams_check: docs/$name has no script in docs/diagrams/" >&2; fail=1; }
done
[ "${#drawn_by[@]}" -gt 0 ] || { echo "diagrams_check: no script in docs/diagrams/ drew a diagram" >&2; fail=1; }
[ "$fail" = 0 ] && echo "diagrams_check: ${#drawn_by[@]} diagram(s) match their scripts"
exit "$fail"
