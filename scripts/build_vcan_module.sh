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

# The questions this script shares with setup_vcan.sh — whose home, where the marker is, whether
# sudo can be used, whether vcan is available — are answered in ONE place. Every review round on
# this PR found another spot where two local copies of one of them had drifted.
. "$(dirname "$0")/vcan_common.sh"

# WHERE THE SOURCE TREE IS, in order: an explicit SRC= for this invocation, then the tree a
# previous run recorded, then the default.
#
# The recorded tree matters most on the path that leads back here: a kernel upgrade makes the
# built module stale, setup_vcan.sh says so and sends the user to a BARE
# `./scripts/build_vcan_module.sh` — which, reading no marker, cloned and built a SECOND kernel
# in the default place (tens of minutes, gigabytes) and then overwrote the marker pointing at
# the first. It also makes the advertised `--load` find a custom build.
if [ -z "${SRC:-}" ]; then
	_marker="$(vcan_marker_path)"
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
	SRC="$(vcan_default_src)"
	echo "[vcan-module] running under sudo — using $SUDO_USER's tree ($SRC), not root's."
	echo "[vcan-module] you can run this WITHOUT sudo; it elevates only the load and ip steps."
fi
SRC="${SRC:-$(vcan_default_src)}"
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
	marker="$(vcan_marker_path)"
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
elif [ "$MODE" = build ] && vcan_available_free; then
	# --build may LOOK — the free checks need no root and change nothing. What it must not do is
	# reach the privileged probe inside vcan_available, which creates and removes a device.
	say "this kernel creates vcan devices with no module at all (CONFIG_CAN_VCAN=y)"
	say "nothing to build"
	exit 0
elif [ "$MODE" = build ]; then
	# The free checks cannot tell, and --build will not pay for the answer by touching anything.
	# It builds: that is what the caller asked for in as many words, and a redundant module is
	# the cheap wrong answer here where a refusal would be the expensive one.
	:
else
	# `|| _avail=$?`, never a bare call. Under `set -e` a bare `vcan_available` that returns
	# non-zero kills the script BEFORE the assignment — silently, on the stock-WSL path this
	# whole script exists to repair (no vcan, probe says no → 1), and equally on the 2 that was
	# supposed to print the sudoers guidance. A `||` suspends errexit for the call and captures
	# the status (codex #122 r5).
	_avail=0
	vcan_available || _avail=$?
	case "$_avail" in
		0)
			# Built in (CONFIG_CAN_VCAN=y): there is no module, and there is nothing for the load
			# path below to do either — it would reach the "$KO not found" die. Finish here.
			say "this kernel creates vcan devices with no module at all (CONFIG_CAN_VCAN=y)"
			say "bringing the interfaces up via setup_vcan.sh"
			"$(dirname "$0")/setup_vcan.sh" "${IFACES[@]}"
			exit 0
			;;
		2)
			# NOT "unsupported". Building a kernel because a probe was refused is the single most
			# expensive wrong answer this script can give.
			vcan_say_no_privilege
			die "not building a kernel on a guess — grant the rule above, or pass --build to force it"
			;;
	esac
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
