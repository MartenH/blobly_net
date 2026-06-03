#!/usr/bin/env bash
# Bring up a Linux virtual CAN interface (vcan0) for the tester + virtual SUT.
#
# vcan is an in-kernel virtual CAN bus: multiple processes bound to vcan0 see
# each other's frames, exactly like a real bus. Swapping to real hardware later
# is just `can0` instead of `vcan0` (plus a bitrate) — no app code changes.
#
# Needs root for modprobe + ip (scoped passwordless sudo is configured for these).
set -euo pipefail

IFACE="${1:-vcan0}"

if ip link show "$IFACE" >/dev/null 2>&1; then
	echo "[setup_vcan] $IFACE already exists"
else
	sudo modprobe vcan
	sudo ip link add dev "$IFACE" type vcan
	echo "[setup_vcan] created $IFACE"
fi

sudo ip link set up "$IFACE"
echo "[setup_vcan] $IFACE is up:"
ip -details -brief link show "$IFACE"
