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
# RIGHT vermagic is already present. The build is a full `make` and takes tens of minutes once;
# after that only the load steps run, and those are needed once per `wsl --shutdown`.
#
# Everything that needs root is a single `sudo` line, so it is obvious what is being elevated.
# The in-process (`inproc:`) and UDP buses need NONE of this — unit tests and the headless
# runner pass on a machine where SocketCAN cannot work at all.
set -euo pipefail

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

say() { echo "[vcan-module] $*"; }
die() { echo "[vcan-module] ERROR: $*" >&2; exit 1; }

# --- 0. is there anything to do at all? -----------------------------------------------------
# Probed WITHOUT root: `ip link add` needs privileges, so using it as the capability test would
# report "vcan is missing" for every unprivileged run and rebuild a kernel that was already fine.
if lsmod | grep -q '^vcan '; then
	say "vcan is already loaded — skipping the build"
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

[ "$MODE" = build ] && { say "built $KO"; exit 0; }
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
