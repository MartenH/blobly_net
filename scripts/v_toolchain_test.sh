#!/usr/bin/env bash
# Tests for scripts/v_toolchain.sh — when the pinned V toolchain is rebuilt, what counts as
# evidence that it was built, and what the install is not allowed to touch on the way.
#
# WHY THIS FILE EXISTS. #285 found one shape four rounds running: a check standing in for
# "this is the toolchain the pins name, and it was actually built".
#   1. the unpinned vc bootstrap (what broke CI on every branch)
#   2. `-x $HOME/v/v` + "the checkout is at V_PIN" read as "already built"
#   3. that predicate with the vc HEAD added — still true after a failed `make`, because the
#      pins are moved before `make` runs
#   4. a build stamp INSTEAD of the HEAD checks — which fixes 2 and 3 and breaks 1 again, since
#      the stamp is untracked and survives an ordinary `git checkout` in the V tree
# CLAUDE.md's rule for findings that repeat in one path is to cover the path rather than keep
# patching cases. The two regressions pinned here are therefore BOTH directions:
#   * `make` fails            -> the next run must still rebuild   (3)
#   * a tree is moved by hand -> the stamp must not be believed    (4)
#
# `set -e` is deliberately absent (the harness counts failures instead of dying on the first),
# which is why the install tests set it explicitly: setup_env.sh runs under `set -euo pipefail`
# and a suite that never does cannot see an errexit bug.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/v_toolchain.sh

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "  want: $3"; echo "  got:  $2"; fi; }

work=$(mktemp -d)
stub=$(mktemp -d)
trap 'rm -rf "$work" "$stub"' EXIT

# A fake toolchain tree: a v executable, a real V checkout and a real vc checkout (so the HEAD
# checks run against actual git), plus whatever stamp the case wants.
#   make_vdir <dir> [stamp]   — echoes "<v_head> <vc_head>"
make_vdir() {
	d=$1
	mkdir -p "$d/vc"
	printf '#!/bin/sh\necho fake v\n' > "$d/v"; chmod +x "$d/v"
	git init -q "$d"; git -C "$d" commit -q --allow-empty -m v1
	git init -q "$d/vc"; git -C "$d/vc" commit -q --allow-empty -m vc1
	if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$d/.blobly_built_from"; fi
	printf '%s %s\n' "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d/vc" rev-parse HEAD)"
}

# --- the predicate ----------------------------------------------------------------------------

d="$work/absent"
ok "no checkout at all -> missing" "$(v_toolchain_build_reason "$d" aaa bbb)" "missing"

d="$work/notgit"; mkdir -p "$d"; printf '#!/bin/sh\n' > "$d/v"; chmod +x "$d/v"
ok "executable but not a git checkout -> notgit" "$(v_toolchain_build_reason "$d" aaa bbb)" "notgit"

d="$work/nostamp"; read -r VH VCH <<<"$(make_vdir "$d")"
ok "both trees at the pins but NO stamp -> stale" "$(v_toolchain_build_reason "$d" "$VH" "$VCH")" "stale"

d="$work/good"; read -r VH VCH <<<"$(make_vdir "$d")"
printf '%s %s\n' "$VH" "$VCH" > "$d/.blobly_built_from"
ok "trees at the pins AND stamp names them -> no build" "$(v_toolchain_build_reason "$d" "$VH" "$VCH")" ""

# Regression for round 4: the stamp is untracked, so a hand checkout leaves it behind claiming
# a build of a tree that is no longer there.
d="$work/vmoved"; read -r VH VCH <<<"$(make_vdir "$d")"
printf '%s %s\n' "$VH" "$VCH" > "$d/.blobly_built_from"
git -C "$d" commit -q --allow-empty -m moved
ok "stamp intact but V tree moved by hand -> stale" "$(v_toolchain_build_reason "$d" "$VH" "$VCH")" "stale"

d="$work/vcmoved"; read -r VH VCH <<<"$(make_vdir "$d")"
printf '%s %s\n' "$VH" "$VCH" > "$d/.blobly_built_from"
git -C "$d/vc" commit -q --allow-empty -m moved
ok "stamp intact but vc tree moved by hand -> stale" "$(v_toolchain_build_reason "$d" "$VH" "$VCH")" "stale"

# A pin bump must reach a bench that already built the OLD pins — the point of the stamp naming
# both, rather than recording a bare "built once".
d="$work/bumped"; read -r VH VCH <<<"$(make_vdir "$d")"
printf '%s %s\n' "$VH" "$VCH" > "$d/.blobly_built_from"
ok "pins bumped under an existing build -> stale" "$(v_toolchain_build_reason "$d" "$VH" deadbeef)" "stale"

# --- the install ------------------------------------------------------------------------------

# git and make are stubbed wholesale: what is under test is the ORDER of the stamp against the
# build, and which git subcommands are reached — not git itself.
cat > "$stub/git" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$GITLOG"
exit 0
SH
chmod +x "$stub/git"

printf '#!/bin/sh\nexit 0\n' > "$stub/make"; chmod +x "$stub/make"
d="$work/inst_ok"; mkdir -p "$d"; printf '#!/bin/sh\n' > "$d/v"; chmod +x "$d/v"
GITLOG="$work/git_ok.log"; : > "$GITLOG"
out=$(PATH="$stub:$PATH" GITLOG="$GITLOG" bash -c "set -euo pipefail; . scripts/v_toolchain.sh; v_toolchain_install '$d' AAA BBB; echo rc=\$?" 2>&1)
ok "install: succeeds" "${out##*$'\n'}" "rc=0"
ok "install: writes the stamp AFTER a successful make" "$(cat "$d/.blobly_built_from" 2>/dev/null || echo MISSING)" "AAA BBB"

# Round-4 finding: the installer must not rewrite a fork's or a mirror's remote, and it runs
# against pre-existing checkouts whenever the stamp is missing, so this is not a rare path.
ok "install: never touches git remotes" "$(grep -c '^remote' "$GITLOG" || true)" "0"
ok "install: fetches the V pin by URL" "$(grep -c 'fetch .* https://github.com/vlang/v AAA' "$GITLOG" || true)" "1"
ok "install: fetches the vc pin by URL" "$(grep -c 'fetch .* https://github.com/vlang/vc BBB' "$GITLOG" || true)" "1"

# make FAILS — the round-3 regression.
printf '#!/bin/sh\nexit 1\n' > "$stub/make"; chmod +x "$stub/make"
d="$work/inst_fail"; mkdir -p "$d"; printf '#!/bin/sh\n' > "$d/v"; chmod +x "$d/v"
printf 'AAA BBB\n' > "$d/.blobly_built_from"   # a stamp from an EARLIER build
GITLOG="$work/git_fail.log"; : > "$GITLOG"
PATH="$stub:$PATH" GITLOG="$GITLOG" bash -c "set -euo pipefail; . scripts/v_toolchain.sh; v_toolchain_install '$d' AAA BBB" >/dev/null 2>&1
rc=$?
ok "install: a failing make fails the script" "$rc" "1"
ok "install: no stamp survives a failed make" "$(cat "$d/.blobly_built_from" 2>/dev/null || echo MISSING)" "MISSING"

# ...and therefore the NEXT run rebuilds rather than trusting the stale binary. Every earlier
# version of the predicate answered "nothing to do" here.
d2="$work/after_fail"; read -r VH VCH <<<"$(make_vdir "$d2")"
ok "after a failed make, the next run still rebuilds" "$(v_toolchain_build_reason "$d2" "$VH" "$VCH")" "stale"

echo
echo "v_toolchain_test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
