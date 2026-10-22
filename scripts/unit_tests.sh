#!/usr/bin/env bash
# unit_tests.sh — the engine's unit tests (CI's `v test blobly/`), at one parallel job per core.
#
# V3's test runner allows one job per 8 GB of memory (three on a 32 GB machine) while a compile
# here peaks near 1 GB, so its default leaves most cores idle. VJOBS, when set, still decides.
#
#   ./scripts/unit_tests.sh [path...]   default: blobly/
#   ./scripts/unit_tests.sh --shard I/N part I of N (scripts/unit_shard.sh) — CI runs one per job
set -e
# the default is the repo's; a path given is the caller's, so the directory is not changed
root=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = --shard ]; then
	part=${2:?--shard I/N}
	[ $# -eq 2 ] || { echo "unit_tests: --shard takes no paths" >&2; exit 2; }
	dirs=$("$root/scripts/unit_shard.sh" "${part%/*}" "${part#*/}")
	echo "shard $part: $(echo $dirs)"
	set --
	for d in $dirs; do set -- "$@" "$root/$d"; done
fi
export VJOBS=${VJOBS:-$(nproc)}
# V's default tcc cannot build the suite on native Windows (docs/known_issues.md)
cc=()
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) cc=(-cc gcc) ;; esac
exec v "${cc[@]}" -enable-globals test "${@:-$root/blobly/}"
