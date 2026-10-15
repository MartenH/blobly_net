#!/usr/bin/env bash
# unit_tests.sh — the engine's unit tests, as CI runs them, at one parallel job per core.
#
# V3's test runner allows one job per 8 GB of memory (three on a 32 GB machine) while a compile
# here peaks near 1 GB, so its default leaves most cores idle. VJOBS, when set, still decides.
#
#   ./scripts/unit_tests.sh [path...]   default: blobly/
set -e
cd "$(dirname "$0")/.."
export VJOBS=${VJOBS:-$(nproc)}
exec v -enable-globals test "${@:-blobly/}"
