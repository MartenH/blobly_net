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
#
# "If the module is missing" is decided by TRYING TO CREATE AN INTERFACE, not by looking for a
# .ko. A kernel built with CONFIG_CAN_VCAN=y needs no module at all, shows nothing in `lsmod`
# and may have no /lib/modules tree for `modprobe` to search — and an earlier version of this
# script refused to run on exactly such a machine, while its vcan0 sat there working.
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

# Where build_vcan_module.sh records the tree it built in. Per-MACHINE, under the user's cache —
# not in the repo. The path is one machine's fact, and a repo-relative marker is per-CHECKOUT:
# this project's own convention is to work in `.claude/worktrees/*`, so a build run from one
# worktree left a marker no other checkout could see.
MARKER="${XDG_CACHE_HOME:-$HOME/.cache}/blobly_net/vcan_module_src"

# ASKED BY TRYING, NOT BY LOOKING FOR A MODULE. This is called only when creating an interface
# has actually failed, because "is there a loadable vcan module?" is a narrower question than
# "can this kernel make a vcan device?", and on a kernel built with CONFIG_CAN_VCAN=y it gets
# the answer wrong in both directions: a built-in vcan appears in no `lsmod` listing, and a WSL
# kernel may have no /lib/modules tree at all for `modprobe` to search — yet `ip link add type
# vcan` works perfectly. Gating on the module up front made this script refuse to run on a
# machine where every interface it wanted already existed and could be recreated at will.
ensure_vcan_module() {
	lsmod | grep -q '^vcan ' && return 0
	sudo modprobe vcan 2>/dev/null && return 0
	# WHERE THE MODULE IS. $SRC for this invocation, else the path build_vcan_module.sh recorded
	# when it built one (which is how a tree kept somewhere other than the default is found — an
	# `SRC=... ./scripts/build_vcan_module.sh` sets it for that command only, and this script,
	# run bare in a later session, would otherwise look in the default place and report that
	# nothing was built while a perfectly good module sat elsewhere), else the default.
	src="${SRC:-}"
	[ -z "$src" ] && [ -f "$MARKER" ] && src="$(cat "$MARKER")"
	ko="${src:-$HOME/repos/WSL2-Linux-Kernel}/drivers/net/can/vcan.ko"
	if [ -f "$ko" ]; then
		# can-dev FIRST: vcan.ko declares it as a dependency (`modinfo -F depends`), and insmod
		# resolves nothing on its own — modprobe would have, but it cannot see a module outside
		# /lib/modules, which is the whole reason this path exists. A stock `wsl --shutdown`
		# unloads can-dev along with vcan, so on the session this script is FOR, the dependency
		# is missing and insmod fails with unresolved symbols.
		if ! sudo modprobe can-dev 2>/dev/null; then
			echo "[setup_vcan] note: could not load can-dev; if the insmod below fails with"
			echo "[setup_vcan]       unresolved symbols, that is why."
		fi
		echo "[setup_vcan] vcan not loaded; inserting the module built earlier: $ko"
		# KEEP THE ERROR. It was discarded and replaced by a guessed list of two causes, neither
		# of which covered the ones this function itself can create — a silently-failed can-dev
		# (unresolved symbols) or a stale .ko over a built-in vcan (EEXIST). Both were reported
		# as "rebuild the module": tens of minutes, and it never helps.
		if err="$(sudo insmod "$ko" 2>&1)"; then
			return 0
		fi
		echo "[setup_vcan] insmod failed: ${err:-(no message)}"
		echo "[setup_vcan] usual causes:"
		echo "[setup_vcan]   - 'Invalid module format' / vermagic: the kernel moved on since that"
		echo "[setup_vcan]     module was built ($(uname -r)) — ./scripts/build_vcan_module.sh"
		echo "[setup_vcan]   - 'Unknown symbol': can-dev is not loaded (see the note above)"
		echo "[setup_vcan]   - 'File exists': vcan is already provided by this kernel; the .ko is"
		echo "[setup_vcan]     redundant and this script should not have needed it"
		echo "[setup_vcan]   - a sudo password prompt: insmod was added to the rule after it"
		echo "[setup_vcan]     shipped — re-run sudo ./scripts/setup_sudoers.sh"
		return 1
	fi
	echo "[setup_vcan] this kernel cannot create a vcan device, and no module is built at $ko"
	echo "[setup_vcan] build it once (a few minutes): ./scripts/build_vcan_module.sh"
	return 1
}

tried_module=0
for IFACE in "${IFACES[@]}"; do
	if ip link show "$IFACE" >/dev/null 2>&1; then
		echo "[setup_vcan] $IFACE already exists"
	else
		# THE CREATE IS THE CAPABILITY TEST. Only when it fails is there any reason to hunt for
		# a module — and then we retry, letting the second attempt's error speak for itself.
		if ! err="$(sudo ip link add dev "$IFACE" type vcan 2>&1)"; then
			if [ "$tried_module" = 0 ]; then
				tried_module=1
				# A MISSING MODULE IS ONLY THE LIKELIEST CAUSE, not the only one — a name too
				# long for an interface fails right here too, and the module hunt that follows
				# would answer a question nobody asked. Print what the kernel actually said, so
				# the guess below arrives next to the truth rather than instead of it.
				echo "[setup_vcan] cannot create $IFACE: ${err:-(no message)}"
				ensure_vcan_module || exit 1
			fi
			sudo ip link add dev "$IFACE" type vcan
		fi
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
