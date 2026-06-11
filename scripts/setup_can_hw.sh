#!/usr/bin/env bash
# Bring up a REAL CAN interface (Kvaser/PEAK over SocketCAN) — the hardware twin of
# setup_vcan.sh. On native Linux the device is just there; under WSL2 it must first
# be passed in from Windows with usbipd-win (see docs/can_hardware.md):
#   usbipd list ; usbipd bind --busid <ID> ; usbipd attach --wsl --busid <ID>
# Once attached, the in-kernel kvaser_usb/peak_usb driver (built in =y on this kernel)
# creates can0, and this script sets the bitrate and brings it up.
#
# Usage: scripts/setup_can_hw.sh [iface] [bitrate] [data_bitrate]
#   data_bitrate (optional) enables CAN-FD (e.g. PCAN Pro FD): nominal + data rates.
# Needs root for `ip` (scoped passwordless sudo is configured).
set -euo pipefail

IFACE="${1:-can0}"
BITRATE="${2:-500000}"
DBITRATE="${3:-}"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
	echo "[setup_can_hw] '$IFACE' not found." >&2
	echo "  Visible USB devices:" >&2
	(command -v lsusb >/dev/null && lsusb) >&2 || echo "  (install usbutils for lsusb)" >&2
	echo "  Under WSL, attach the adapter from Windows first:" >&2
	echo "    usbipd list ; usbipd bind --busid <ID> ; usbipd attach --wsl --busid <ID>" >&2
	echo "  (PCAN often needs to be plugged DIRECTLY into the PC, not via a hub.)" >&2
	exit 1
fi

# Interface must be down to (re)configure bitrate.
sudo ip link set "$IFACE" down 2>/dev/null || true

if [ -n "$DBITRATE" ]; then
	echo "[setup_can_hw] $IFACE: CAN-FD nominal=$BITRATE data=$DBITRATE"
	sudo ip link set "$IFACE" type can bitrate "$BITRATE" dbitrate "$DBITRATE" fd on
else
	echo "[setup_can_hw] $IFACE: classic CAN bitrate=$BITRATE"
	sudo ip link set "$IFACE" type can bitrate "$BITRATE"
fi

sudo ip link set up "$IFACE"
echo "[setup_can_hw] $IFACE is up:"
ip -details -brief link show "$IFACE"
echo "[setup_can_hw] verify traffic with:  candump $IFACE   (or: cansend $IFACE 123#DEADBEEF)"
