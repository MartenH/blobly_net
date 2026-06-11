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
# On this WSL2 kernel CAN_RAW / CAN_VCAN / CAN_ISOTP are built in (=y), so NO modprobe
# is needed — `ip link add type vcan` works directly. (A stale vcan.ko in /lib/modules
# fails to insert and is irrelevant; ignore it.) Nothing here persists: vcan interfaces
# die on `wsl --shutdown`, so re-run this each session.
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
	sudo ip link set up "$IFACE"
	echo "[setup_vcan] $IFACE is up:"
	ip -details -brief link show "$IFACE"
done
