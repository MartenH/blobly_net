#!/usr/bin/env bash
# unit_shard.sh — the module folders of part I of N of the unit suite, one per line.
#
# Whole folders, so V's own discovery still decides which files in one are tests (backend and
# architecture suffixes, _test.c.v). Balanced by test-file count: largest folder first, each to
# the part with the fewest files so far, ties to the lower part — deterministic, so N jobs that
# each ask for their own part cover every folder exactly once.
#
#   ./scripts/unit_shard.sh I N        1 <= I <= N
set -eo pipefail
i=${1:?part}
n=${2:?parts}
[ "$i" -ge 1 ] && [ "$i" -le "$n" ] || { echo "unit_shard: part $i of $n" >&2; exit 2; }
cd "$(dirname "$0")/.."
tests() { find "$@" \( -name '*_test.v' -o -name '*_test.*.v' \) | wc -l; }
total=$(tests blobly)
for d in blobly/*/; do
	c=$(tests "$d")
	[ "$c" -eq 0 ] || echo "$c ${d%/}"
done | sort -k1,1nr -k2,2 | awk -v i="$i" -v n="$n" -v total="$total" '
{
	best = 1
	for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
	load[best] += $1
	sum += $1
	if (best == i) { print $2; mine++ }
}
END {
	# a test outside a module folder would be in no part, and so never run
	if (sum != total) { printf "unit_shard: %d test file(s) outside a module folder\n", total - sum > "/dev/stderr"; exit 1 }
	# an empty part would hand the runner no path, which unit_tests.sh reads as the whole suite
	if (!mine) { printf "unit_shard: part %d of %d is empty\n", i, n > "/dev/stderr"; exit 1 }
}'
