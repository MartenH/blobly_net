#!/usr/bin/env bash
# Run Lua test scripts headlessly against a project's simulation (no GUI).
#   scripts/runtests.sh [--project projects/sim-demo.yml] tests/diag_basic.lua [more.lua ...]
# Defaults to projects/sim-demo.yml when --project is omitted. Exits non-zero if
# any test fails (CI-friendly). -enable-globals is needed for the in-process bus.
set -euo pipefail
cd "$(dirname "$0")/.."

V="${V:-$HOME/v/v}"
[ -x "$V" ] || V="v"

exec "$V" -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v "$@"
