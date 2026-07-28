# Real CAN hardware — Kvaser / PEAK / Vector across Linux, WSL, Windows

We have a **Kvaser Leaf Light v2** (classic CAN) and a **PCAN-USB Pro FD** (CAN-FD),
and possibly **Vector** (VN-series). Support differs sharply by vendor *and* OS.

## Support matrix

| | Kvaser Leaf Light v2 | PCAN-USB Pro FD | Vector (VN16xx/…) |
|---|---|---|---|
| **Native Linux** | ✅ mainline `kvaser_usb` → `can0` (SocketCAN) | ✅ mainline `peak_usb` → `can0`/`can1` | ❌ no mainline driver |
| **WSL2** | ⚠️ `usbipd-win` + WSL-kernel driver | ⚠️ same | ❌ — |
| **Native Windows** | vendor SDK — Kvaser **CANlib** | vendor SDK — PEAK **PCAN-Basic** | vendor SDK — Vector **XL Driver Library** |
| **CAN-FD** | classic only | ✅ FD | ✅ FD |

**Takeaway:** Kvaser + PEAK are the two best-supported vendors (in-tree SocketCAN
drivers); **Vector is Windows-only here** — skip it for any Linux/WSL kernel work.

## Native Linux — zero new code (recommended first bring-up)

Plug in, bring the netdev up, and our existing stack just works:

```bash
sudo ip link set can0 up type can bitrate 500000
candump can0            # or: cansend can0 123#DEADBEEF
```

`modules/transport/socketcan_linux.v` handles I/O unchanged, and the new
`modules/transport/discover_linux.v` (`ip -details -json link show`) lists `can0`
as a real `can` interface **with its bitrate** — so `cmd/project_scaffold scan`
scaffolds it straight into a project channel. This is the cleanest way to validate
the scaffolder against real hardware.

## WSL2 — usbipd-win + a kernel rebuild

Two requirements, because WSL2 doesn't expose USB by default:

**1. Windows side — pass the USB device into WSL** (`usbipd-win`):
```powershell
winget install usbipd
usbipd list                       # find the BUSID of the Kvaser/PEAK
usbipd bind   --busid <BUSID>
usbipd attach --wsl --busid <BUSID>
```

**2. WSL kernel — add USB/IP + the CAN USB drivers.** Our custom kernel already has
`CONFIG_CAN=y` + `vcan`, but **not** USB or the vendor drivers. Check first:
```bash
zcat /proc/config.gz | grep -iE 'KVASER|PEAK_USB|USBIP_VHCI|CONFIG_USB='
```
If empty, enable them in the kernel source tree (`scripts/config`, the `-e` you asked
about; build them **`=y` / built-in** to match the existing `CAN=y` approach and dodge
the empty-`/lib/modules` module-loading gotcha noted in CLAUDE.md):
```bash
scripts/config -e USB \
               -e USBIP_CORE -e USBIP_VHCI_HCD \   # USB/IP client for usbipd-win
               -e CAN_DEV \                         # real-netdev CAN infra (vcan doesn't need it)
               -e CAN_KVASER_USB \                  # Kvaser Leaf Light v2 (+ most Kvaser USB)
               -e CAN_PEAK_USB                      # PCAN-USB / Pro / FD
make olddefconfig && make -j"$(nproc)"              # rebuild bzImage-can.new
```
Then point `.wslconfig` at the new bzImage, `wsl --shutdown`, reattach with `usbipd`,
and `can0` appears. (No `CAN_VECTOR` symbol exists — Vector can't ride this path.)

> **Status on this box (verified 2026-06-11):** the kernel rebuild is **already done** —
> `CAN_DEV`, `CAN_KVASER_USB`, `CAN_PEAK_USB`, `USB`, `USBIP_CORE`, `USBIP_VHCI_HCD` are
> all `=y`. So no rebuild needed here; just `usbipd attach --wsl` the adapter and run
> **`scripts/setup_can_hw.sh [iface] [bitrate] [data_bitrate]`** to set the rate and bring
> the interface up (the hardware twin of `setup_vcan.sh`). **PCAN often must be plugged
> directly into the PC, not through a USB hub, to enumerate for usbipd.**

## Native Windows — vendor backends behind the `*_windows.v` seam

No SocketCAN on Windows, so each vendor needs its SDK DLL wrapped via C-interop as a
`Bus` implementation — exactly what the platform seam (`open_windows.v` /
`discover_windows.v`) was built for.

> **Kvaser and PEAK are built and hardware-verified** (cross-vendor send/receive on a
> shared 500 kbit/s bus, 2026-06-18) — use the `kvaser:` / `pcan:` interface prefixes.
> **Vector is not implemented**; its row below is the sketch it would follow.
> [`windows_can_hardware.md`](windows_can_hardware.md) is the current, detailed reference
> for the Windows path (DLL loading, bitrate mapping, the `slcan` fallback).

| Vendor | SDK | File | Key calls (open/tx/rx) | Discovery |
|---|---|---|---|---|
| Kvaser | CANlib (`canlib32.dll`) | `transport/kvaser_windows.v` | `canOpenChannel` / `canWrite` / `canReadWait` | `canGetNumberOfChannels` |
| PEAK | PCAN-Basic (`PCANBasic.dll`) | `transport/pcan_windows.v` | `CAN_Initialize` / `CAN_Write` / `CAN_Read` | `CAN_GetValue(PCAN_ATTACHED_CHANNELS)` |
| Vector | XL Driver Library (`vxlapi64.dll`) | `transport/xl_windows.v` *(not implemented)* | `xlOpenPort` / `xlCanTransmit` / `xlReceive` | `xlGetDriverConfig` |

Each implements the existing `transport.Bus` interface, so callers don't change.
`discover_windows.v` grows from "virtual buses only" to also enumerate attached
channels via the calls above (the "vendor enum later" TODO already in that file).
Interface strings would extend the `open()` dispatcher, e.g. `kvaser:0`, `pcan:USB1`,
`vector:0:1` — alongside the existing `udp:`/`inproc:`.

**FD note:** `transport.CanFrame` is classic CAN 2.0 today; the PCAN Pro FD and Vector
are the CAN-FD devices, relevant when the FD work (64-byte payload, BRS) lands.
