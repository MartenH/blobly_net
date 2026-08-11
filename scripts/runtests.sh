#!/usr/bin/env bash
# Run Lua test scripts headlessly against a project's simulation (no GUI).
#   scripts/runtests.sh [--project projects/sim-demo.blobnet] tests/diag_basic.lua [more.lua ...]
# Defaults to projects/sim-demo.blobnet when --project is omitted. Exits non-zero if
# any test fails (CI-friendly). -enable-globals is needed for the in-process bus.
set -euo pipefail

# Absolutise caller-relative paths BEFORE changing directory. The cd below is what lets the
# repo-relative `-path modules` and `cmd/script/run.v` work, but it also silently re-based every
# argument the caller wrote — so `--project my.blobnet` from another directory looked for that
# file inside the repository and failed before any asset resolution ran. Scripts have the same
# problem, so both are resolved here.
args=()
next_is_project=0
for a in "$@"; do
  if [ "$next_is_project" = 1 ]; then
    next_is_project=0
    [ -e "$a" ] && a="$(cd "$(dirname "$a")" && pwd)/$(basename "$a")"
    args+=("$a")
    continue
  fi
  case "$a" in
    --project) next_is_project=1; args+=("$a") ;;
    -*)        args+=("$a") ;;
    *)         if [ -e "$a" ]; then
                 args+=("$(cd "$(dirname "$a")" && pwd)/$(basename "$a")")
               else
                 args+=("$a")   # leave it alone: repo-relative, as CI passes
               fi ;;
  esac
done

cd "$(dirname "$0")/.."

V="${V:-$HOME/v/v}"
[ -x "$V" ] || V="v"

exec "$V" -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v "${args[@]}"
