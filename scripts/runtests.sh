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

run_one() {
  "$V" -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v "$@"
}

# Named scripts run as one invocation, in one environment — the fast path, and what --project is
# for. Anything the caller passes is honoured exactly as written.
for a in "${args[@]}"; do
  case "$a" in
    -*) ;;
    *)  exec "$V" -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v "${args[@]}" ;;
  esac
done

# NOTHING named: run the whole suite, which is the case CI has.
#
# One invocation PER FILE, because a run brings up ONE project and the tests do not all want the
# same one — the DoIP pair needs its own, and says so in its own head (`-- @project`, see
# modules/script/project_decl.v). Per file, each script selects for itself and this script never
# has to parse that directive, so the rule lives in exactly one place.
#
# CI ran a single named file before, so six of the eight suites were only ever run by hand. Two
# of them had been failing on main for weeks and reported nothing (#115). Running everything by
# DEFAULT is what stops that recurring: a test added to tests/ is run without anyone remembering
# to list it.
set +e
failed=()
total=0
for f in tests/*.lua; do
  [ -e "$f" ] || continue
  total=$((total + 1))
  echo "== $f"
  run_one "${args[@]}" "$f" || failed+=("$f")
done
set -e

echo
if [ "${#failed[@]}" -eq 0 ]; then
  echo "runtests: $total/$total suites passed"
  exit 0
fi
echo "runtests: ${#failed[@]} of $total suites FAILED:"
printf '  %s\n' "${failed[@]}"
exit 1
