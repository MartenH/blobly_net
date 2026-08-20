#!/usr/bin/env bash
# Bring up one or more Linux virtual CAN interfaces for the tester + virtual SUT.
# Default is two buses (vcan0 vcan1); pass your own names to override:
#     ./scripts/setup_vcan.sh                 # vcan0 + vcan1
#     ./scripts/setup_vcan.sh vcan0           # just one
#     ./scripts/setup_vcan.sh vcan0 vcan1 vcan2
#
# Multiple independent virtual buses let you exercise multi-channel projects and the
# per-(id, bus, dir) trace grouping with no hardware — e.g. one bus for the SUT and a
# second for a separate network/protocol.
#
# vcan is an in-kernel virtual CAN bus: multiple processes bound to the same vcanN see
# each other's frames, exactly like a real bus. Swapping to real hardware later is just
# `canN` instead of `vcanN` (plus a bitrate, via setup_can_hw.sh) — no app code changes.
#
# RUN THIS ONCE PER WSL SESSION. Nothing here survives `wsl --shutdown`: the interfaces go,
# and on WSL2 the vcan MODULE goes with them, because a stock kernel does not ship vcan.ko and
# the built one is inserted rather than installed. So this script loads the module first and
# then creates the interfaces — it is the only thing you need to run to get a virtual bus back.
#
# WSL2 CAVEAT, verified 2026-08-17 on 6.6.87.2-microsoft-standard-WSL2: the stock kernel has
# CONFIG_CAN=m and CONFIG_CAN_RAW=m but **CONFIG_CAN_VCAN is not set**. Building that module is
# a separate, rare job — `./scripts/build_vcan_module.sh`, needed once and again only after a
# kernel upgrade. This script calls for it by name if the module is missing.
# docs/can_hardware.md explains why each step is needed.
#
# This comment previously claimed CAN_RAW / CAN_VCAN / CAN_ISOTP were built in (=y) and that
# no modprobe was needed. None of that is true on a stock kernel; it described one machine's
# custom build, and cost a fresh setup an evening.
#
# Nothing here persists: vcan interfaces die on `wsl --shutdown`, so re-run this each session.
#
# Needs root for `ip` (scoped passwordless sudo is configured).
set -euo pipefail

IFACES=("$@")
[ ${#IFACES[@]} -eq 0 ] && IFACES=(vcan0 vcan1)

# THE MODULE BEFORE THE INTERFACES. Without it `ip link add type vcan` fails with a bare
# "Unknown device type", which names neither the cause nor the fix — and it is the first thing
# every session hits after a restart, since an insmod'd module does not persist.
ensure_vcan_module() {
	lsmod | grep -q '^vcan ' && return 0
	sudo modprobe vcan 2>/dev/null && return 0
	# WHERE THE MODULE IS. $SRC for this invocation, else the path build_vcan_module.sh recorded
	# when it built one (which is how a tree kept somewhere other than the default is found — an
	# `SRC=... ./scripts/build_vcan_module.sh` sets it for that command only, and this script,
	# run bare in a later session, would otherwise look in the default place and report that
	# nothing was built while a perfectly good module sat elsewhere), else the default.
	src="${SRC:-}"
	[ -z "$src" ] && [ -f "$(dirname "$0")/../.vcan_module_src" ] \
		&& src="$(cat "$(dirname "$0")/../.vcan_module_src")"
	ko="${src:-$HOME/repos/WSL2-Linux-Kernel}/drivers/net/can/vcan.ko"
	if [ -f "$ko" ]; then
		# can-dev FIRST: vcan.ko declares it as a dependency (`modinfo -F depends`), and insmod
		# resolves nothing on its own — modprobe would have, but it cannot see a module outside
		# /lib/modules, which is the whole reason this path exists. A stock `wsl --shutdown`
		# unloads can-dev along with vcan, so on the session this script is FOR, the dependency
		# is missing and insmod fails with unresolved symbols.
		sudo modprobe can-dev 2>/dev/null || true
		echo "[setup_vcan] vcan not loaded; inserting the module built earlier: $ko"
		sudo insmod "$ko" 2>/dev/null && return 0
		echo "[setup_vcan] insmod failed. Two usual causes:"
		echo "[setup_vcan]   - the kernel moved on since that module was built ($(uname -r)):"
		echo "[setup_vcan]     rebuild with ./scripts/build_vcan_module.sh"
		echo "[setup_vcan]   - insmod is not in the passwordless sudo rule (it was added after"
		echo "[setup_vcan]     that rule shipped): re-run sudo ./scripts/setup_sudoers.sh"
		return 1
	fi
	echo "[setup_vcan] no vcan module, and none built at $ko"
	echo "[setup_vcan] build it once (a few minutes): ./scripts/build_vcan_module.sh"
	return 1
}
ensure_vcan_module || exit 1

for IFACE in "${IFACES[@]}"; do
	if ip link show "$IFACE" >/dev/null 2>&1; then
		echo "[setup_vcan] $IFACE already exists"
	else
		sudo ip link add dev "$IFACE" type vcan
		echo "[setup_vcan] created $IFACE"
	fi
	# MTU 72 = CAN-FD capable (a classic vcan is 16). Replaying a real capture needs it: half the
	# buses in a vehicle log carry payloads over 8 bytes, and on a 16-byte interface every one of
	# those sends fails. Costs nothing when only classic traffic is used.
	# MTU can only be changed while the link is DOWN — CAN's can_change_mtu() returns -EBUSY
	# otherwise, so a re-run over an already-up classic interface warned and left it at 16, and
	# every CAN-FD send kept failing while setup reported success. Only bounced when the MTU is
	# actually wrong, because bringing a link down interrupts anything already using it.
	cur_mtu="$(cat /sys/class/net/$IFACE/mtu 2>/dev/null || echo 0)"
	if [ "$cur_mtu" != "72" ]; then
		sudo ip link set "$IFACE" down 2>/dev/null || true
		sudo ip link set "$IFACE" mtu 72 || echo "[setup_vcan] warning: could not set mtu 72 on $IFACE (CAN-FD frames will fail)"
	fi
	sudo ip link set up "$IFACE"
	echo "[setup_vcan] $IFACE is up:"
	ip -details -brief link show "$IFACE"
done
