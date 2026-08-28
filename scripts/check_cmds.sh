#!/bin/sh
# check_cmds.sh — type-check EVERY cmd/ entry point, for BOTH OS targets, from one machine.
#
# Nothing else in CI compiles a CLI tool: `v test modules/` covers the engine and runtests.sh
# runs the Lua suites through the headless runner. So a rename in modules/ could break any of
# the tools in cmd/ and the build stayed green — #217 retired a helper and broke cmd/vectorcheck,
# the tool you reach for when you suspect the HARDWARE, and two smoke tools sat broken on
# Windows for months (#220). `-check` stops before C: no GLFW, no FreeType, no linker, so both
# targets run from either runner in under a minute.
#
#   V=/path/to/v             the compiler (default: `v` on PATH)
#   CHECK_OS="linux windows" targets to check (default: both)
set -u
V="${V:-v}"
targets="${CHECK_OS:-linux windows}"
cd "$(dirname "$0")/.." || exit 2
fail=0
n=0
for d in cmd/*/; do
	d="${d%/}"
	for os in $targets; do
		n=$((n + 1))
		if out="$("$V" -os "$os" -enable-globals -path '@vlib|@vmodules|modules|libs' -check "$d" 2>&1)"; then
			:
		else
			fail=$((fail + 1))
			printf 'FAIL %s (-os %s)\n%s\n' "$d" "$os" "$out"
		fi
	done
done
printf '%d checks, %d failed\n' "$n" "$fail"
[ "$fail" -eq 0 ]
