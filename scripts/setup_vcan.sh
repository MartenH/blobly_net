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
# WSL2 CAVEAT, verified 2026-08-17 on 6.6.87.2-microsoft-standard-WSL2: the stock kernel
# has CONFIG_CAN=m and CONFIG_CAN_RAW=m but **CONFIG_CAN_VCAN is not set**, and no vcan.ko
# ships — so `ip link add type vcan` fails with "Unknown device type" until the module is
# built. docs/can_hardware.md has the recipe (a full `make LOCALVERSION=` of the matching
# WSL2-Linux-Kernel tag; the kernel itself does not need replacing).
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
	sudo ip link set "$IFACE" mtu 72 || echo "[setup_vcan] warning: could not set mtu 72 on $IFACE (CAN-FD frames will fail)"
	sudo ip link set up "$IFACE"
	echo "[setup_vcan] $IFACE is up:"
	ip -details -brief link show "$IFACE"
done
