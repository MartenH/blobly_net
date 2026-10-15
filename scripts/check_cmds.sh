#!/bin/sh
# check_cmds.sh — type-check EVERY cmd/ entry point, for BOTH OS targets, from one machine.
#
# Nothing else in CI compiles a CLI tool: `v test blobly/` covers the engine and runtests.sh
# runs the Lua suites through the headless runner. So a rename in blobly/ could break any of
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
		if out="$("$V" -os "$os" -enable-globals -path '@vlib|libs|@vmodules' -check "$d" 2>&1)"; then
			:
		else
			fail=$((fail + 1))
			printf 'FAIL %s (-os %s)\n%s\n' "$d" "$os" "$out"
		fi
	done
done
# and one class -check cannot see: C's int is 32 bits and V3's 64, so an `&int` in a C declaration
# hands C half a value wherever V3 does not copy it through a C int itself (a forwarded pointer,
# an escaped local, an array). C's int* is `&i32` (docs/known_issues.md).
n=$((n + 1))
if bad=$(grep -rnE --include='*.v' '^[[:space:]]*(pub )?fn C\.[A-Za-z0-9_.]+\(.*&int\b' cmd blobly libs); then
	echo "FAIL fn C. declarations taking &int (a C int* is &i32):"
	echo "$bad"
	fail=$((fail + 1))
fi
# and $embed_file, which V3 does not embed outside -prod: it records the BUILD machine's path and
# reads that file at run time, panicking wherever the build tree is absent -- every user's machine.
# The shipped build is not -prod (#284), so one such constant killed the Windows bundle before its
# first frame (#455). Spell the bytes out instead (cmd/blobly_net/assets/gen.vsh).
n=$((n + 1))
if bad=$(grep -rnE --include='*.v' --exclude-dir=build '^[^/]*\$embed_file\(' cmd blobly libs); then
	echo "FAIL \$embed_file (V3 reads it from the build tree at run time outside -prod):"
	echo "$bad"
	fail=$((fail + 1))
fi
printf '%d checks, %d failed\n' "$n" "$fail"
[ "$fail" -eq 0 ]
