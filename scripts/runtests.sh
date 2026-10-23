#!/usr/bin/env bash
# Run Lua test scripts headlessly against a project's simulation (no GUI).
#   scripts/runtests.sh [--project projects/sim-demo.blobnet] [--report run.json] [--timeout 60] \
#                       tests/diag_basic.lua [more.lua ...]
# Defaults to projects/sim-demo.blobnet when --project is omitted. Exits with the runner's status
# (0 passed, 1 a test failed, 2 refused, 3 a script error, 4 timeout; docs/scripting.md). With no
# script named, every suite in tests/ runs, one invocation each, and this exits 1 when any did
# not pass (the summary gives each one's status); --report then names a DIRECTORY that gets one
# <suite>.json per suite, and --timeout bounds each suite. -enable-globals is needed
# for the in-process bus.
set -euo pipefail

# Absolutise caller-relative paths BEFORE changing directory. The cd below is what lets the
# repo-relative `cmd/script/run.v` and the blobly modules beside v.mod resolve, but it also silently re-based every
# argument the caller wrote — so `--project my.blobnet` from another directory looked for that
# file inside the repository and failed before any asset resolution ran. Scripts have the same
# problem, so both are resolved here.
abs() { # an existing $1 made absolute; any other left alone (repo-relative, as CI passes)
  if [ -e "$1" ]; then echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; else echo "$1"; fi
}
args=()
named=0
report=""
next=""
for a in "$@"; do
  case "$next" in
    path)   next=""; args+=("$(abs "$a")"); continue ;;
    value)  next=""; args+=("$a"); continue ;;
    report) next=""; [ -n "$a" ] || { echo "runtests: --report names no file" >&2; exit 2; }
            case "$a" in /*|[A-Za-z]:[/\\]*) report="$a" ;; *) report="$PWD/$a" ;; esac; continue ;;
  esac
  case "$a" in
    --project|-p) next=path; args+=("$a") ;;
    --timeout)    next=value; args+=("$a") ;;
    --report)     next=report ;;
    --project-ports) args+=("$a") ;;
    -*)           named=1; args+=("$a") ;;  # one invocation, which refuses it
    *)            named=1; args+=("$(abs "$a")") ;;
  esac
done
case "$next" in
  report)    echo "runtests: --report needs a value" >&2; exit 2 ;;
  path|value) named=1 ;;  # the runner refuses the missing value, into the report
esac

cd "$(dirname "$0")/.."

V="${V:-$HOME/v/v}"
[ -x "$V" ] || V="v"

# Built ONCE, into a directory of this invocation's own. `v run` writes its binary beside the
# source and deletes it after, so two runs in parallel raced on one cmd/script/run: one started
# a suite on a binary the other had just removed ("No such file or directory") — and every
# suite paid a compile of its own.
bin_dir="$(mktemp -d)"
trap 'rm -rf "$bin_dir"' EXIT
"$V" -enable-globals -o "$bin_dir/run" cmd/script/run.v

run_one() {
  "$bin_dir/run" "$@"
}

# Named scripts run as one invocation, in one environment — the fast path, and what --project is
# for. Anything the caller passes is honoured exactly as written.
if [ "$named" = 1 ]; then
  set +e
  run_one ${report:+--report "$report"} "${args[@]}"
  exit $?
fi
[ -z "$report" ] || mkdir -p "$report"

# NOTHING named: run the whole suite, which is the case CI has.
#
# One invocation PER FILE, because a run brings up ONE project and the tests do not all want the
# same one — the DoIP pair needs its own, and says so in its own head (`-- @project`, see
# blobly/script/project_decl.v). Per file, each script selects for itself and this script never
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
  run_one ${report:+--report "$report/$(basename "$f" .lua).json"} "${args[@]}" "$f" || failed+=("$f (exit $?)")
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
