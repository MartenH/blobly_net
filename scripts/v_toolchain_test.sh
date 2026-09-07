#!/usr/bin/env bash
# Tests for scripts/v_toolchain.sh — when the pinned V toolchain is rebuilt, and what counts
# as evidence that it was built.
#
# WHY THIS FILE EXISTS. #285 took three review rounds and every one found the same shape: a
# check on the STATE OF THE INPUTS standing in for "this was successfully built". Round 1 was
# the unpinned vc bootstrap, round 2 was `-x $HOME/v/v` plus a matching V HEAD, round 3 was
# that same predicate with the vc HEAD added — which still passes after a failed `make`,
# because the pins are moved before `make` runs. CLAUDE.md's rule for findings that repeat in
# one path is to cover the path rather than keep patching cases.
#
# The regression test is `make fails -> next run still rebuilds`. Every earlier version of this
# predicate answered "nothing to do" there and went on with a stale compiler.
#
# `set -e` is deliberately absent (the harness counts failures instead of dying on the first),
# which is why the install tests set it explicitly: setup_env.sh runs under `set -euo pipefail`
# and a suite that never does cannot see an errexit bug.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/v_toolchain.sh

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "  want: $3"; echo "  got:  $2"; fi; }

VP=1111111111111111111111111111111111111111
VC=2222222222222222222222222222222222222222

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# A fake V checkout: an executable, a .git so `git -C` answers, and whatever stamp is asked for.
make_vdir() { # <dir> [stamp-content]
	mkdir -p "$1"
	printf '#!/bin/sh\necho fake v\n' > "$1/v"; chmod +x "$1/v"
	git init -q "$1" 2>/dev/null
	if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$1/.blobly_built_from"; fi
}

# --- the predicate ----------------------------------------------------------------------------

d="$work/absent"
ok "no checkout at all -> missing" "$(v_toolchain_build_reason "$d" "$VP" "$VC")" "missing"

d="$work/notgit"; mkdir -p "$d"; printf '#!/bin/sh\n' > "$d/v"; chmod +x "$d/v"
ok "executable but not a git checkout -> notgit" "$(v_toolchain_build_reason "$d" "$VP" "$VC")" "notgit"

d="$work/nostamp"; make_vdir "$d"
ok "both repos at the pins but NO stamp -> stale" "$(v_toolchain_build_reason "$d" "$VP" "$VC")" "stale"

d="$work/good"; make_vdir "$d" "$VP $VC"
ok "stamp names exactly these pins -> no build" "$(v_toolchain_build_reason "$d" "$VP" "$VC")" ""

d="$work/vmoved"; make_vdir "$d" "9999999999999999999999999999999999999999 $VC"
ok "stamp names another V pin -> stale" "$(v_toolchain_build_reason "$d" "$VP" "$VC")" "stale"

d="$work/vcmoved"; make_vdir "$d" "$VP 9999999999999999999999999999999999999999"
ok "stamp names another vc pin -> stale" "$(v_toolchain_build_reason "$d" "$VP" "$VC")" "stale"

# A .v-version bump must reach a bench that already built the OLD pin — the whole point of the
# stamp naming both, rather than recording a bare "built once".
d="$work/bumped"; make_vdir "$d" "$VP $VC"
ok "pins bumped under an existing build -> stale" \
	"$(v_toolchain_build_reason "$d" "$VP" 3333333333333333333333333333333333333333)" "stale"

# --- the install, and what it does when make fails ---------------------------------------------

# Stubs: git is real (the fetches are stubbed out below by pointing origin at a local repo is
# overkill — instead stub `git` and `make` wholesale, since what is under test is the ORDER of
# the stamp against the build, not git itself).
stub=$(mktemp -d); trap 'rm -rf "$work" "$stub"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$stub/git"; chmod +x "$stub/git"

# make SUCCEEDS
printf '#!/bin/sh\nexit 0\n' > "$stub/make"; chmod +x "$stub/make"
d="$work/inst_ok"; mkdir -p "$d"; printf '#!/bin/sh\n' > "$d/v"; chmod +x "$d/v"
out=$(PATH="$stub:$PATH" bash -c "set -euo pipefail; . scripts/v_toolchain.sh; v_toolchain_install '$d' '$VP' '$VC'; echo rc=\$?" 2>&1)
ok "install: succeeds" "${out##*$'\n'}" "rc=0"
ok "install: writes the stamp AFTER a successful make" "$(cat "$d/.blobly_built_from" 2>/dev/null || echo MISSING)" "$VP $VC"

# make FAILS — the regression this whole file exists for.
printf '#!/bin/sh\nexit 1\n' > "$stub/make"; chmod +x "$stub/make"
d="$work/inst_fail"; mkdir -p "$d"; printf '#!/bin/sh\n' > "$d/v"; chmod +x "$d/v"
printf '%s\n' "$VP $VC" > "$d/.blobly_built_from"   # a stamp from an EARLIER, different build
PATH="$stub:$PATH" bash -c "set -euo pipefail; . scripts/v_toolchain.sh; v_toolchain_install '$d' '$VP' '$VC'" >/dev/null 2>&1
rc=$?
ok "install: a failing make fails the script" "$rc" "1"
ok "install: no stamp survives a failed make" "$(cat "$d/.blobly_built_from" 2>/dev/null || echo MISSING)" "MISSING"

# ...and therefore the NEXT run rebuilds rather than trusting the stale binary. This is the
# case every earlier version of the predicate got wrong: both repos sit at the pins, the old
# executable is still there, and the answer must still be "build".
git init -q "$d" 2>/dev/null
ok "after a failed make, the next run still rebuilds" "$(v_toolchain_build_reason "$d" "$VP" "$VC")" "stale"

echo
echo "v_toolchain_test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
