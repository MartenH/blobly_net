#!/usr/bin/env bash
# Tests for scripts/vcan_common.sh — the shared answers behind setup_vcan.sh and
# build_vcan_module.sh.
#
# WHY THIS FILE EXISTS. net#122 took four review rounds, and every one of them found the same two
# shapes: a per-user path that forgot SUDO_USER, and a capability check that read "I was not
# allowed to ask" as "the answer is no". Both are pure functions of the environment, so both are
# testable — and CLAUDE.md's rule for findings that repeat in one path is to cover the path
# rather than keep patching cases.
# `set -e` is DELIBERATELY absent here (the harness counts failures rather than dying on the
# first), which is exactly why the caller-path tests at the bottom set it explicitly: the real
# scripts run under `set -euo pipefail`, and a suite that never does cannot see an errexit bug.
# One slipped through precisely that gap — a bare `vcan_available` that killed the script before
# its status could be captured, on the stock-WSL path the script exists to repair.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/vcan_common.sh

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "  want: $3"; echo "  got:  $2"; fi; }

# --- whose home, and the paths derived from it ------------------------------------------------
out=$(HOME=/home/alice XDG_CACHE_HOME= bash -c '. scripts/vcan_common.sh; vcan_user_home')
ok "vcan_user_home: plain" "$out" "/home/alice"

# Under sudo the answer must be the INVOKING user's home, not root's. Driven through a stubbed
# `getent`/`id` so it runs as an ordinary user in CI.
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
printf '#!/bin/sh\necho "bob:x:1001:1001::/home/bob:/bin/bash"\n' > "$stub/getent"
printf '#!/bin/sh\n[ "$1" = "-u" ] && echo 0 || echo bob\n' > "$stub/id"
chmod +x "$stub/getent" "$stub/id"

out=$(PATH="$stub:$PATH" HOME=/root SUDO_USER=bob bash -c '. scripts/vcan_common.sh; vcan_user_home')
ok "vcan_user_home: under sudo -> invoking user" "$out" "/home/bob"

out=$(PATH="$stub:$PATH" HOME=/root SUDO_USER=bob bash -c '. scripts/vcan_common.sh; vcan_marker_path')
ok "vcan_marker_path: under sudo" "$out" "/home/bob/.cache/blobly_net/vcan_module_src"

out=$(PATH="$stub:$PATH" HOME=/root SUDO_USER=bob bash -c '. scripts/vcan_common.sh; vcan_default_src')
ok "vcan_default_src: under sudo" "$out" "/home/bob/repos/WSL2-Linux-Kernel"

out=$(HOME=/home/alice bash -c 'unset XDG_CACHE_HOME; . scripts/vcan_common.sh; vcan_marker_path')
ok "vcan_marker_path: plain" "$out" "/home/alice/.cache/blobly_net/vcan_module_src"

out=$(HOME=/home/alice XDG_CACHE_HOME=/tmp/xdg bash -c '. scripts/vcan_common.sh; vcan_marker_path')
ok "vcan_marker_path: honours XDG_CACHE_HOME" "$out" "/tmp/xdg/blobly_net/vcan_module_src"

# The marker that setup_vcan.sh READS must be the one build_vcan_module.sh WRITES. They each had
# their own expression of it once, and the two drifted.
a=$(grep -c 'vcan_marker_path' scripts/setup_vcan.sh)
b=$(grep -c 'vcan_marker_path' scripts/build_vcan_module.sh)
ok "both scripts use the shared marker path" "$([ "$a" -ge 1 ] && [ "$b" -ge 1 ] && echo yes || echo no)" "yes"
ok "neither script hard-codes a second marker path" \
   "$(grep -h 'blobly_net/vcan_module_src' scripts/setup_vcan.sh scripts/build_vcan_module.sh | wc -l)" "0"

# --- "cannot tell" is not "no" ------------------------------------------------------------------
# A kernel with no usable signal AND no sudo must return 2, never 1: returning 1 sends the caller
# off to compile a kernel because a probe was refused.
# Stub environments, one per scenario and never reused — an earlier draft shared one directory
# and then rewrote its `zcat` for a later assertion, so a test asking for "the kernel says no"
# silently got "vcan is built in" and passed for the wrong reason.
#
# `kernelno`: sudo works, `ip link show` succeeds and lists no vcan, `ip link add` fails.
# That is the kernel genuinely answering no — availability 1.
kernelno=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = "-n" ] && shift\nexec "$@"\n' > "$kernelno/sudo"
printf '#!/bin/sh\ncase "$*" in *"link add"*) exit 1 ;; *) exit 0 ;; esac\n' > "$kernelno/ip"
printf '#!/bin/sh\nexit 1\n' > "$kernelno/zcat"
printf '#!/bin/sh\nexit 1\n' > "$kernelno/lsmod"
printf '#!/bin/sh\nexit 1\n' > "$kernelno/modinfo"
chmod +x "$kernelno"/*

# `nosudo`: sudo is refused outright, so the question cannot be asked — availability 2.
nosudo=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$nosudo/sudo"
printf '#!/bin/sh\nexit 1\n' > "$nosudo/ip"
printf '#!/bin/sh\nexit 1\n' > "$nosudo/zcat"
printf '#!/bin/sh\nexit 1\n' > "$nosudo/lsmod"
printf '#!/bin/sh\nexit 1\n' > "$nosudo/modinfo"
chmod +x "$nosudo"/*

deny=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$deny/sudo"                                  # every sudo denied
printf '#!/bin/sh\nexit 1\n' > "$deny/ip"                                    # no vcan interfaces
printf '#!/bin/sh\nexit 1\n' > "$deny/zcat"                                  # no /proc/config.gz
chmod +x "$deny/sudo" "$deny/ip" "$deny/zcat"
PATH="$deny:/usr/bin:/bin" bash -c '. '"$PWD"'/scripts/vcan_common.sh; vcan_available' >/dev/null 2>&1
ok "vcan_available: no signal + no sudo -> 2 (cannot tell)" "$?" "2"

# The free half must never touch sudo, so --build can call it.
out=$(PATH="$deny:/usr/bin:/bin" bash -c '. '"$PWD"'/scripts/vcan_common.sh; vcan_available_free' 2>&1; echo "rc=$?")
ok "vcan_available_free: no signal -> 1, and never shells out to sudo" "$out" "rc=1"

# And the pipefail trap that made the config check answer backwards: a MATCH must return 0 under
# `set -o pipefail`, which a plain `zcat | grep -q` does not.
# BIG, deliberately. `grep -q` only closes the pipe early — and so only kills zcat with SIGPIPE,
# and so only exposes the pipefail bug — when there is more output left to write. A one-line
# fixture let zcat finish first and the buggy version passed. The real /proc/config.gz is ~8000
# lines; match that order of magnitude, with the match near the top.
cfg=$(mktemp -d)
{ echo 'CONFIG_CAN_VCAN=y'; for i in $(seq 1 20000); do echo "CONFIG_FILLER_$i=y"; done; } | gzip > "$cfg/config.gz"
printf '#!/bin/sh\nexec /bin/zcat "'"$cfg"'/config.gz"\n' > "$deny/zcat"; chmod +x "$deny/zcat"
PATH="$deny:/usr/bin:/bin" bash -c 'set -o pipefail; . '"$PWD"'/scripts/vcan_common.sh; vcan_available_free' >/dev/null 2>&1
ok "vcan_available_free: CONFIG_CAN_VCAN=y matches under pipefail" "$?" "0"

# --- the CALLER path, under the errexit the real scripts actually use --------------------------
# Not the helpers in isolation: how build_vcan_module.sh consumes them. `vcan_available` returns
# 1 and 2 as ANSWERS, and under `set -e` a bare call turns either into a silent exit.
for want in 1 2; do
	case $want in
		1) env="$kernelno" ;; # sudo works, the kernel says no
		2) env="$nosudo" ;;   # sudo refused: cannot tell
	esac
	got=$(PATH="$env:/usr/bin:/bin" bash -c '
		set -euo pipefail
		. '"$PWD"'/scripts/vcan_common.sh
		_avail=0
		vcan_available || _avail=$?
		echo "captured=$_avail"' 2>&1)
	ok "caller under set -e captures $want instead of dying" "$got" "captured=$want"
done

# And the real script must reach its own reporting on the no-privilege path rather than
# vanishing: exit 2 with no output was the symptom.
out=$(PATH="$nosudo:/usr/bin:/bin" timeout 30 bash "$PWD/scripts/build_vcan_module.sh" --load 2>&1 || true)
ok "build_vcan_module.sh --load explains a refused probe" \
   "$(printf '%s' "$out" | grep -c 'setup_sudoers.sh')" "1"

echo "vcan_common: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
