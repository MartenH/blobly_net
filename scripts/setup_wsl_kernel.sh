#!/usr/bin/env bash
# setup_wsl_kernel.sh — build the `vcan` module a stock WSL2 kernel does not ship.
#
# WSL2 gives you CONFIG_CAN=m and CONFIG_CAN_RAW=m but NOT CONFIG_CAN_VCAN, so
# `ip link add type vcan` fails with "Unknown device type" and nothing in this repo that needs
# SocketCAN can run. The kernel itself does not have to be replaced: CONFIG_MODULES=y and there
# is no MODULE_SIG_FORCE, so a module built from the matching source loads fine.
#
#   ./scripts/setup_wsl_kernel.sh            # build (if needed), then load + bring up vcan0/vcan1
#   ./scripts/setup_wsl_kernel.sh --build    # build only, do not touch the running system
#   ./scripts/setup_wsl_kernel.sh --load     # load an already-built module and bring the links up
#   SRC=~/src/wsl-kernel ./scripts/setup_wsl_kernel.sh    # keep the source tree elsewhere
#
# Idempotent: exits early when vcan already works, and skips the build when a module with the
# RIGHT vermagic is already present. The build is a full `make` and takes tens of minutes once;
# after that only the load steps run, and those are needed once per `wsl --shutdown`.
#
# Everything that needs root is a single `sudo` line, so it is obvious what is being elevated.
# The in-process (`inproc:`) and UDP buses need NONE of this — unit tests and the headless
# runner pass on a machine where SocketCAN cannot work at all.
set -euo pipefail

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

say() { echo "[wsl-kernel] $*"; }
die() { echo "[wsl-kernel] ERROR: $*" >&2; exit 1; }

# --- 0. is there anything to do at all? -----------------------------------------------------
# Probed WITHOUT root: `ip link add` needs privileges, so using it as the capability test would
# report "vcan is missing" for every unprivileged run and rebuild a kernel that was already fine.
if lsmod | grep -q '^vcan '; then
	say "vcan is already loaded — skipping the build"
	[ "$MODE" = build ] && exit 0
	MODE=load
elif modinfo vcan >/dev/null 2>&1; then
	say "this kernel SHIPS vcan (no build needed) — loading it"
	sudo modprobe vcan
	MODE=load
fi

# --- 1. build ------------------------------------------------------------------------------
# Skipped when a module with the right vermagic already exists: rebuilding a correct one wastes
# half an hour, and a module with the WRONG vermagic is the failure this script exists to avoid.
need_build=1
if [ -f "$KO" ]; then
	have="$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')"
	if [ "$have" = "$KREL" ]; then
		say "existing $KO matches the running kernel ($KREL) — skipping build"
		need_build=0
	else
		say "existing module is for '$have', running kernel is '$KREL' — rebuilding"
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

	if [ ! -d "$SRC" ]; then
		say "cloning $TAG (shallow) into $SRC"
		git clone --depth 1 -b "$TAG" https://github.com/microsoft/WSL2-Linux-Kernel "$SRC" \
			|| die "no source for tag $TAG — check https://github.com/microsoft/WSL2-Linux-Kernel/tags"
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
want="$KREL SMP preempt mod_unload modversions"
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

for IFACE in "${IFACES[@]}"; do
	if ip link show "$IFACE" >/dev/null 2>&1; then
		say "$IFACE already exists"
	else
		sudo ip link add dev "$IFACE" type vcan
	fi
	# mtu 72 = CAN-FD capable (a classic vcan is 16). Real captures are half CAN-FD, and on a
	# 16-byte interface every one of those frames fails to send.
	sudo ip link set "$IFACE" mtu 72 || say "warning: could not set mtu 72 on $IFACE (CAN-FD frames will fail)"
	sudo ip link set up "$IFACE"
	say "$IFACE up ($(ip -d link show "$IFACE" | grep -o 'mtu [0-9]*'))"
done

cat <<EOF
[wsl-kernel] done. Nothing here survives \`wsl --shutdown\` except the built module, so re-run
             this (it will skip straight to the load steps) once per session.
             Check CAN-FD end to end with:
               cansend ${IFACES[0]} '123##1112233445566778899AABBCCDDEEFF'
               candump -x ${IFACES[0]}
EOF
