#!/usr/bin/env bash
# Bring up a Linux virtual CAN interface (vcan0) for the tester + virtual SUT.
#
# vcan is an in-kernel virtual CAN bus: multiple processes bound to vcan0 see
# each other's frames, exactly like a real bus. Swapping to real hardware later
# is just `can0` instead of `vcan0` (plus a bitrate) — no app code changes.
#
# On this WSL2 kernel CAN_RAW / CAN_VCAN / CAN_ISOTP are built in (=y), so NO
# modprobe is needed — `ip link add type vcan` works directly. (A stale vcan.ko
# in /lib/modules fails to insert and is irrelevant; ignore it.)
#
# Needs root for `ip` (scoped passwordless sudo is configured).
set -euo pipefail

IFACE="${1:-vcan0}"

if ip link show "$IFACE" >/dev/null 2>&1; then
	echo "[setup_vcan] $IFACE already exists"
else
	sudo ip link add dev "$IFACE" type vcan
	echo "[setup_vcan] created $IFACE"
fi

sudo ip link set up "$IFACE"
echo "[setup_vcan] $IFACE is up:"
ip -details -brief link show "$IFACE"
