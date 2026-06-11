#!/usr/bin/env bash
# usbip.sh — drive usbipd-win from WSL to share USB CAN adapters into Linux.
#
# WSL can invoke the Windows usbipd.exe directly (interop). The one-time `bind`
# needs Windows admin (run `usbipd bind --busid <id>` in an elevated PowerShell);
# `attach --wsl` of an already-bound device does NOT, so this script handles the
# repeat-after-replug/shutdown step. Once attached, the in-kernel kvaser_usb /
# peak_usb driver creates can0/can1/… — bring them up with setup_can_hw.sh.
#
# Usage:  scripts/usbip.sh [list|can|attach <busid>|detach <busid>]
set -euo pipefail

# Locate usbipd.exe (not always on the interop PATH).
USBIPD="${USBIPD:-}"
if [ -z "$USBIPD" ]; then
	for p in "/mnt/c/Program Files/usbipd-win/usbipd.exe" "$(command -v usbipd.exe 2>/dev/null || true)"; do
		if [ -n "$p" ] && [ -f "$p" ]; then USBIPD="$p"; break; fi
	done
fi
if [ -z "$USBIPD" ] || [ ! -f "$USBIPD" ]; then
	echo "usbipd.exe not found — install on Windows: winget install dorssel.usbipd-win" >&2
	exit 1
fi

cmd="${1:-list}"
case "$cmd" in
	list | ls)
		"$USBIPD" list
		;;
	can)
		# CAN adapters only — Kvaser 0bfd, PEAK 0c72, Vector 0bce (Vector is Windows-only,
		# listed for completeness). Keep the header line for the BUSID column.
		"$USBIPD" list | grep -iE 'BUSID|0bfd:|0c72:|0bce:|kvaser|peak|vector' || echo "(no CAN adapters found)"
		;;
	attach | a)
		busid="${2:?usage: usbip.sh attach <busid>}"
		"$USBIPD" attach --wsl --busid "$busid"
		echo "attached $busid — verify: lsusb ; ip -brief link show type can"
		;;
	detach | d)
		busid="${2:?usage: usbip.sh detach <busid>}"
		"$USBIPD" detach --busid "$busid"
		;;
	*)
		echo "usage: scripts/usbip.sh [list|can|attach <busid>|detach <busid>]" >&2
		exit 1
		;;
esac
