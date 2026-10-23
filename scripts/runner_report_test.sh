#!/usr/bin/env bash
# The headless Lua runner's exit statuses and --report file, end to end: a passing, a failing, an
# erroring and three hanging suites (tests/runner/), a refused project and a bad argument.
#   scripts/runner_report_test.sh            (RUN=<built cmd/script> to skip the build)
set -euo pipefail
cd "$(dirname "$0")/.."

V="${V:-$HOME/v/v}"
[ -x "$V" ] || V="v"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
RUN="${RUN:-}"
if [ -z "$RUN" ]; then
  "$V" -enable-globals -o "$work/run" cmd/script/run.v
  RUN="$work/run"
fi

fails=0
# expect <name> <exit status> <python assertions over r, the report> -- <runner args...>
expect() {
  local name="$1" want="$2" checks="$3"
  shift 4
  local t0 got
  t0=$(date +%s)
  set +e
  "$RUN" "$@" --report "$work/$name.json" >"$work/$name.out" 2>&1   # last: found wherever it is
  got=$?
  set -e
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: exit $got, want $want"; sed 's/^/    /' "$work/$name.out"; fails=$((fails + 1)); return
  fi
  if ! python3 -I -c "
import json, sys
r = json.load(open(sys.argv[1]))
assert r['schema'] == 1 and r['exit_code'] == $want, r
$checks
" "$work/$name.json"; then
    echo "FAIL $name: report"; cat "$work/$name.json"; fails=$((fails + 1)); return
  fi
  echo "ok   $name (exit $got, $(( $(date +%s) - t0 )) s)"
}

expect pass 0 "
assert r['status'] == 'passed' and r['counts'] == {'passed': 2, 'failed': 0, 'timed_out': 0, 'script_errors': 0}
assert [t['status'] for t in r['tests']] == ['passed', 'passed']
assert r['project'].endswith('sim-demo.blobnet') and 'timeout' not in r" \
  -- tests/runner/pass.lua

expect fail 1 "
t = r['tests'][1]
assert r['status'] == 'failed' and t['name'] == 'fails' and t['status'] == 'failed'
assert t['line'] == 7 and 'one is two' in t['message'] and t['script'] == 'tests/runner/fail.lua'" \
  -- tests/runner/fail.lua

expect error 3 "
assert r['status'] == 'error' and r['counts']['passed'] == 1
assert 'not inside a test' in r['script_errors'][0]['message']" \
  -- tests/runner/error.lua

expect hang 4 "
assert r['status'] == 'timeout' and r['timeout']['test'] == 'spins' and r['timeout']['after_s'] == 2
assert [t['status'] for t in r['tests']] == ['passed', 'timeout'] and r['tests'][1]['line'] == 6
assert r['duration_ms'] < 10000" \
  -- --timeout 2 tests/runner/hang.lua

expect wait 4 "
assert r['timeout']['test'] == 'waits' and r['duration_ms'] < 10000" \
  -- --timeout 2 tests/runner/wait.lua

# what the deadline cannot end, the watchdog does, 5 s later
expect stuck 4 "
assert r['status'] == 'timeout' and r['timeout']['script'] == 'tests/runner/stuck.lua'
assert 'without closing' in r['message'] and r['duration_ms'] < 15000" \
  -- --timeout 1 tests/runner/stuck.lua

# the suites after a timed-out one do not run
expect order 4 "
assert r['timeout']['script'] == 'tests/runner/hang.lua'
assert all(t['script'] != 'tests/runner/fail.lua' for t in r['tests'])" \
  -- --timeout 2 tests/runner/hang.lua tests/runner/fail.lua

expect refused 2 "
assert r['status'] == 'refused' and 'cannot load project' in r['message']" \
  -- --project "$work/none.blobnet" tests/runner/pass.lua

expect badarg 2 "
assert r['status'] == 'refused' and '--timeout' in r['message']" \
  -- --timeout soon tests/runner/pass.lua

if [ "$fails" -ne 0 ]; then
  echo "runner_report_test: $fails FAILED"
  exit 1
fi
echo "runner_report_test: all passed"
