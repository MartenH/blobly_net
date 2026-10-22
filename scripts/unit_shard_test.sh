#!/usr/bin/env bash
# unit_shard_test.sh — the parts of the unit suite cover every module folder with tests exactly
# once, for any part count CI might use; a folder in no part is a suite that silently stops running.
set -u
cd "$(dirname "$0")/.."
fail=0
want=$(for d in blobly/*/; do
	[ -n "$(find "$d" \( -name '*_test.v' -o -name '*_test.*.v' \) -print -quit)" ] && echo "${d%/}"
done | sort)
for n in 1 2 3 4 5; do
	got=$(for i in $(seq 1 "$n"); do scripts/unit_shard.sh "$i" "$n" || echo "FAILED part $i"; done | sort)
	if [ "$got" != "$want" ]; then
		echo "FAIL $n parts do not cover each folder once:"
		diff <(echo "$want") <(echo "$got")
		fail=1
	fi
done
folders=$(echo "$want" | wc -l)
scripts/unit_shard.sh 4 3 2>/dev/null && { echo "FAIL part 4 of 3 accepted"; fail=1; }
scripts/unit_shard.sh "$((folders + 1))" "$((folders + 1))" 2>/dev/null && { echo "FAIL an empty part accepted"; fail=1; }
[ "$fail" -eq 0 ] && echo "unit_shard: OK ($folders folders)"
exit "$fail"
