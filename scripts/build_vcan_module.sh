#!/usr/bin/env bash
# build_vcan_module.sh — build the `vcan` module a stock WSL2 kernel does not ship.
#
# RARE. You need this once, and again only after a kernel upgrade. To get a virtual bus back
# after an ordinary WSL restart, run ./scripts/setup_vcan.sh — it loads this module for you.
#
# WSL2 gives you CONFIG_CAN=m and CONFIG_CAN_RAW=m but NOT CONFIG_CAN_VCAN, so
# `ip link add type vcan` fails with "Unknown device type" and nothing in this repo that needs
# SocketCAN can run. The kernel itself does not have to be replaced: CONFIG_MODULES=y and there
# is no MODULE_SIG_FORCE, so a module built from the matching source loads fine.
#
#   ./scripts/build_vcan_module.sh            # build (if needed), then load + bring up vcan0/vcan1
#   ./scripts/build_vcan_module.sh --build    # build only, do not touch the running system
#   ./scripts/build_vcan_module.sh --load     # load an already-built module and bring the links up
#   SRC=~/src/wsl-kernel ./scripts/build_vcan_module.sh    # keep the source tree elsewhere
#
# Idempotent: exits early when vcan already works, and skips the build when a module with the
# RIGHT vermagic is already present. The build is a full `make` and takes tens of minutes once.
# After that you do NOT come back here each session — the per-session job is setup_vcan.sh
# above, which loads what this built. This script is for the build, and for kernel upgrades.
#
# Everything that needs root is a single `sudo` line, so it is obvious what is being elevated.
# The in-process (`inproc:`) and UDP buses need NONE of this — unit tests and the headless
# runner pass on a machine where SocketCAN cannot work at all.
set -euo pipefail

say() { echo "[vcan-module] $*"; }
die() { echo "[vcan-module] ERROR: $*" >&2; exit 1; }

# Where the tree this script built in is recorded, for setup_vcan.sh and for the next run of
# this one. Per-MACHINE, under the user's cache, NOT in the repo: the path is one machine's
# fact, and a repo-relative marker is per-CHECKOUT — this project works in `.claude/worktrees/*`
# by convention, so a build from one worktree left a marker no other checkout could see.
marker_path() {
	if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
		_h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
		echo "${_h:-$HOME}/.cache/blobly_net/vcan_module_src"
		return 0
	fi
	echo "${XDG_CACHE_HOME:-$HOME/.cache}/blobly_net/vcan_module_src"
}

# WHERE THE SOURCE TREE IS, in order: an explicit SRC= for this invocation, then the tree a
# previous run recorded, then (under sudo) the invoking user's default, then the default.
#
# The recorded tree matters most on the path that leads back here: a kernel upgrade makes the
# built module stale, setup_vcan.sh says so and sends the user to a BARE
# `./scripts/build_vcan_module.sh` — which, reading no marker, cloned and built a SECOND kernel
# in the default place (tens of minutes, gigabytes) and then overwrote the marker pointing at
# the first. It also makes the advertised `--load` find a custom build.
if [ -z "${SRC:-}" ]; then
	_marker="$(marker_path)"
	if [ -s "$_marker" ] && [ -d "$(cat "$_marker")" ]; then
		SRC="$(cat "$_marker")"
		say "using the source tree an earlier run recorded: $SRC"
	fi
fi

# Run as a NORMAL user: the script sudo's the three steps that need it, so what is elevated
# stays visible. Under `sudo ./build_vcan_module.sh` the whole thing runs as root, $HOME becomes
# /root, and SRC then defaults to a tree that does not exist — so it clones and rebuilds a second
# kernel (minutes, gigabytes) into /root instead of reusing the one already built. Recover the
# invoking user's home rather than punishing a reasonable mistake.
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ -z "${SRC:-}" ]; then
	_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
	if [ -n "$_home" ] && [ -d "$_home" ]; then
		SRC="$_home/repos/WSL2-Linux-Kernel"
		echo "[vcan-module] running under sudo — using $SUDO_USER's tree ($SRC), not root's."
		echo "[vcan-module] you can run this WITHOUT sudo; it elevates only the load and ip steps."
	fi
fi
SRC="${SRC:-$HOME/repos/WSL2-Linux-Kernel}"
# ABSOLUTE, before $KO is derived from it and before it is recorded. The marker is explicitly
# machine-wide — read by setup_vcan.sh in a later session and by this script from any checkout —
# and a relative SRC= written verbatim would be resolved against whatever directory the reader
# happens to be in. From another worktree it names nothing, and the bare rebuild then falls back
# to cloning the default tree. Resolved via the directory when it exists (so symlinks and `..`
# collapse), and prefixed with $PWD when it does not yet — SRC is also the clone target.
case "$SRC" in
	/*) ;;
	*) SRC="$(cd "$SRC" 2>/dev/null && pwd -P || echo "$PWD/$SRC")" ;;
esac
IFACES=(vcan0 vcan1)
MODE="all"
case "${1:-}" in
	--build) MODE=build ;;
	--load) MODE=load ;;
	'') ;;
	*) echo "usage: $0 [--build|--load]" >&2; exit 2 ;;
esac

KREL="$(uname -r)"                       # e.g. 6.6.87.2-microsoft-standard-WSL2
KVER="${KREL%%-*}"                       # e.g. 6.6.87.2
TAG="linux-msft-wsl-${KVER}"
KO="$SRC/drivers/net/can/vcan.ko"

# RECORD WHERE THE MODULE IS, for setup_vcan.sh and for the next run of this script. Either can
# run bare in a later session with no SRC in its environment, so a tree kept anywhere but the
# default would be invisible — reported as "nothing was built" while a good module sat next to
# it, or rebuilt from scratch somewhere else.
#
# Called from EVERY exit that leaves a usable module behind, not just the end: `--build` returns
# at the build-only exit, which is exactly the mode a custom SRC is most likely paired with.
# Guarded on $KO existing, so the early exits that build nothing (kernel already has vcan) do
# not overwrite a good marker with a tree that holds no module.
#
# And written as the INVOKING user. `sudo ./build_vcan_module.sh` is tolerated above, and it
# reaches this line whenever no build is needed; the root-owned file it left behind then made
# the RECOMMENDED non-root run fail here — after tens of minutes of successful rebuild, and
# before the interfaces came up. The unlink recovers a marker an older version already left,
# since the directory is the user's; a failure to record is only a lost optimisation, so it
# warns rather than taking the run down with it.
record_src() {
	[ -f "$KO" ] || return 0
	marker="$(marker_path)"
	if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
		sudo -u "$SUDO_USER" mkdir -p "$(dirname "$marker")" 2>/dev/null || true
		printf '%s\n' "$SRC" | sudo -u "$SUDO_USER" tee "$marker" >/dev/null 2>&1 \
			|| say "note: could not record $SRC in $marker (setup_vcan.sh will need SRC=)"
		return 0
	fi
	mkdir -p "$(dirname "$marker")" 2>/dev/null || true
	rm -f "$marker" 2>/dev/null || true
	# 2>/dev/null BEFORE the redirect, so a failing `>` is silenced by it — bash reports that
	# one against whatever fd 2 is at the moment it tries, and the say below is the message
	# worth reading.
	printf '%s\n' "$SRC" 2>/dev/null > "$marker" \
		|| say "note: could not record $SRC in $marker (setup_vcan.sh will need SRC=)"
}

# --- 0. is there anything to do at all? -----------------------------------------------------
# vcan_usable asks the question that actually decides this: CAN THIS KERNEL MAKE A VCAN DEVICE?
# The two checks below it ask narrower ones — "is a module loaded", "is a module installable" —
# and a kernel built with CONFIG_CAN_VCAN=y answers no to both while `ip link add type vcan`
# works: a built-in vcan is in no `lsmod` listing, and such a build often ships no
# /lib/modules/$(uname -r) for modinfo to search. Without this the script cloned and compiled an
# ENTIRE KERNEL — tens of minutes, gigabytes — for a machine whose vcan was already there.
# Observed on 6.6.123.2-microsoft-standard-WSL2+ while testing the sibling fix in setup_vcan.sh:
# the same wrong probe, in the second of the two places it lived.
#
# Answered without root and without touching anything wherever possible: an interface that
# already exists, the running kernel's own config, or the builtin list. Only if none of those can
# tell do we ask by doing — and NOT under --build, which promises to leave the running system
# alone, and whose caller has every reason not to have authorised `sudo ip` at all. A denied or
# unauthorised probe is not evidence that vcan is missing, and treating it as such is how this
# script talks itself into compiling a kernel it does not need.
vcan_builtin() {
	[ -n "$(ip -brief link show type vcan 2>/dev/null)" ] && return 0
	# Process substitution, NOT a pipe. Under `set -o pipefail` a `grep -q` that matches closes
	# the pipe, zcat dies of SIGPIPE, and the pipeline reports failure — so the check answered
	# "no" precisely when the answer was yes, and this script went off to build a kernel again.
	grep -q '^CONFIG_CAN_VCAN=y' <(zcat /proc/config.gz 2>/dev/null) && return 0
	grep -qs 'vcan\.ko' "/lib/modules/$(uname -r)/modules.builtin" && return 0
	return 1
}

# The mutating fallback. `sudo -n`: a probe must never sit at a password prompt, and a refusal
# has to be distinguishable from "the kernel cannot do this".
vcan_probe() {
	sudo -n ip link add dev vcanprobe type vcan >/dev/null 2>&1 || return 1
	sudo -n ip link del vcanprobe >/dev/null 2>&1 || true
	return 0
}

vcan_usable() {
	vcan_builtin && return 0
	# --build changes nothing on the running system, so it stops at the free checks. If they
	# cannot tell, it goes on and builds a module — redundant on a built-in kernel, but that is
	# the conservative answer for a mode whose whole promise is not to touch anything.
	[ "$MODE" = build ] && return 1
	vcan_probe
}

if lsmod | grep -q '^vcan '; then
	say "vcan is already loaded — skipping the build"
	# BEFORE the exit. The loaded module may be the one in $SRC, put there by an earlier run or
	# by hand, and this is the only moment we know where it came from. Without it, a marker that
	# is missing or stale stays that way, and after the next shutdown a bare setup_vcan.sh
	# cannot find that custom build. record_src is a no-op unless $KO actually exists.
	record_src
	[ "$MODE" = build ] && exit 0
	MODE=load
elif modinfo vcan >/dev/null 2>&1; then
	# --build promises to leave the running system alone, so it reports and stops rather than
	# loading anything. Without this, `--build` modprobe'd the module AND brought interfaces up.
	if [ "$MODE" = build ]; then
		say "this kernel SHIPS vcan — nothing to build (run without --build to load it)"
		exit 0
	fi
	say "this kernel SHIPS vcan (no build needed) — loading it"
	sudo modprobe vcan
	MODE=load
elif vcan_usable; then
	# Built in (CONFIG_CAN_VCAN=y): there is no module, and there is nothing for the load path
	# below to do either — it would reach the "$KO not found" die. Finish here instead.
	say "this kernel creates vcan devices with no module at all (CONFIG_CAN_VCAN=y)"
	[ "$MODE" = build ] && { say "nothing to build"; exit 0; }
	say "bringing the interfaces up via setup_vcan.sh"
	"$(dirname "$0")/setup_vcan.sh" "${IFACES[@]}"
	exit 0
fi

# --- 1. build ------------------------------------------------------------------------------
# Skipped when a module with the right vermagic already exists: rebuilding a correct one wastes
# half an hour, and a module with the WRONG vermagic is the failure this script exists to avoid.
# The SAME comparison the pre-insmod check uses, not just the release prefix: a module built
# from a different .config can share the release and still differ in flags, and comparing only
# the first field skipped the build and then failed the full check — on every retry, forever.
WANT_VERMAGIC="$KREL SMP preempt mod_unload modversions"
need_build=1
if [ -f "$KO" ]; then
	have="$(modinfo -F vermagic "$KO" 2>/dev/null || true)"
	if [ "$(echo "$have" | xargs)" = "$(echo "$WANT_VERMAGIC" | xargs)" ]; then
		say "existing $KO matches the running kernel — skipping build"
		need_build=0
	else
		say "existing module is '$have', need '$WANT_VERMAGIC' — rebuilding"
	fi
fi

if [ "$MODE" != load ] && [ "$need_build" = 1 ]; then
	# cpio is needed by CONFIG_IKHEADERS; the others are ordinary kbuild deps. Missing any of
	# them fails hundreds of lines into the build, where the message is easy to miss.
	missing=()
	for t in flex bison bc cpio; do command -v "$t" >/dev/null || missing+=("$t"); done
	for p in libssl-dev libelf-dev dwarves; do
		dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
	done
	if [ ${#missing[@]} -gt 0 ]; then
		say "installing build dependencies: ${missing[*]}"
		sudo apt-get install -y "${missing[@]}"
	fi

	# Refuse to BUILD as root. Loading needs root and the script elevates that itself; compiling
	# does not, and doing it under sudo scatters root-owned objects through the invoking user's
	# tree — which then fails for them later with permission errors they did not cause.
	if [ "$(id -u)" = 0 ]; then
		die "a build is needed, and this is running as root.
  Run it WITHOUT sudo: the script elevates only the module load and the ip commands.
  (Building as root would leave root-owned files in $SRC.)"
	fi
	if [ ! -d "$SRC" ]; then
		say "cloning $TAG (shallow) into $SRC"
		git clone --depth 1 -b "$TAG" https://github.com/microsoft/WSL2-Linux-Kernel "$SRC" \
			|| die "no source for tag $TAG — check https://github.com/microsoft/WSL2-Linux-Kernel/tags"
	else
		# WSL updates its kernel underneath you. A tree left from the previous one rebuilds the
		# OLD source, and the module then fails the vermagic check on every retry — an
		# "idempotent" script that can never recover. Move it to the running kernel's tag, and
		# drop the stale .config with it (it seeds from /proc/config.gz again below).
		have_tag="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
		if [ "$have_tag" != "$TAG" ]; then
			say "source tree is at '${have_tag:-unknown}', running kernel needs $TAG — refetching"
			git -C "$SRC" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" \
				|| die "cannot fetch $TAG into $SRC (delete it and re-run to clone afresh)"
			git -C "$SRC" checkout -q "$TAG" || die "cannot check out $TAG in $SRC"
			rm -f "$SRC/.config" "$SRC/include/config/kernel.release" "$SRC/include/generated/utsrelease.h"
		fi
	fi
	cd "$SRC"

	if [ ! -f .config ]; then
		[ -r /proc/config.gz ] || die "/proc/config.gz is unreadable; cannot match the running kernel's config"
		say "seeding .config from the RUNNING kernel (/proc/config.gz)"
		zcat /proc/config.gz > .config
	fi
	./scripts/config --module CONFIG_CAN_VCAN --module CONFIG_CAN_VXCAN
	# CONFIG_IKHEADERS only embeds a headers tarball — it changes no struct layout, vermagic or
	# symbol CRC — so dropping it is the safe way past a missing cpio.
	command -v cpio >/dev/null || { say "cpio unavailable — disabling CONFIG_IKHEADERS"; ./scripts/config --disable CONFIG_IKHEADERS; }
	make olddefconfig >/dev/null

	# A FULL make, not modules_prepare: WSL ships no /lib/modules/$(uname -r)/build and no
	# Module.symvers, and this vermagic ends in `modversions`, so the symbol CRCs have to come
	# from a real build of the tree or insmod rejects the module.
	#
	# LOCALVERSION= is NOT decoration. setlocalversion looks for a tag named v<KERNELVERSION>;
	# Microsoft's is linux-msft-wsl-<version>, so it never matches, decides the tree is "past a
	# tag", and appends '+' — after which the vermagic disagrees and insmod refuses. Setting
	# LOCALVERSION (even empty) skips that suffix entirely. `touch .scmversion` does NOT work on
	# 6.6; that support was removed from the script.
	say "building (a full kernel make — tens of minutes the first time)"
	make LOCALVERSION= -j"$(nproc)"
	cd - >/dev/null
fi

[ "$MODE" = build ] && { record_src; say "built $KO"; exit 0; }
if ! lsmod | grep -q '^vcan ' && [ ! -f "$KO" ]; then
	die "$KO not found and vcan is not loaded — run with --build first"
fi

# --- 2. the check that turns a confusing failure into a clear one ---------------------------
if lsmod | grep -q '^vcan '; then
	say "vcan already loaded — skipping the vermagic check"
else
want="$WANT_VERMAGIC"
got="$(modinfo -F vermagic "$KO")"
if [ "$(echo "$got" | xargs)" != "$(echo "$want" | xargs)" ]; then
	die "vermagic mismatch — insmod would refuse this module.
    built:   $got
    running: $want
  If the built string ends in '+', the build lost LOCALVERSION=; remove
  include/config/kernel.release and include/generated/utsrelease.h, then rebuild."
fi
say "vermagic matches: $got"
fi

# --- 3. load + bring up --------------------------------------------------------------------
lsmod | grep -q '^vcan ' || {
	sudo modprobe can-dev            # vcan declares this dependency
	sudo insmod "$KO"
	say "loaded vcan.ko"
}

# THE INTERFACES ARE setup_vcan.sh's JOB. This script used to create them too, with its own
# copy of the mtu-72 dance — two places to fix when the rule changed, and two answers when they
# disagreed. Build here, bring the bus up there.
record_src

say "module ready — bringing the interfaces up via setup_vcan.sh"
"$(dirname "$0")/setup_vcan.sh" "${IFACES[@]}"

cat <<EOF
[vcan-module] done. The BUILT MODULE is the only part that survives \`wsl --shutdown\`; the
              module load and the interfaces do not. After each restart run just:
                  ./scripts/setup_vcan.sh
              You need this script again only after a kernel upgrade, when the module stops
              matching the running kernel.
              Check CAN-FD end to end with:
                cansend ${IFACES[0]} '123##1112233445566778899AABBCCDDEEFF'
                candump -x ${IFACES[0]}
EOF
