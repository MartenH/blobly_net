# Real CAN hardware — Kvaser / PEAK / Vector across Linux, WSL, Windows

Support differs sharply by vendor *and* OS. Two adapters are **verified against real
hardware** — a **Kvaser Leaf Light v2** (classic CAN) and a **PCAN-USB Pro FD** (CAN-FD),
tested cross-vendor on one bus. **Vector** is listed for comparison: no backend
exists today, and the XL one is [planned, not written](../ROADMAP.md).

## Support matrix

| | Kvaser Leaf Light v2 | PCAN-USB Pro FD | Vector (VN16xx/…) |
|---|---|---|---|
| **Native Linux** | ✅ mainline `kvaser_usb` → `can0` (SocketCAN) | ✅ mainline `peak_usb` → `can0`/`can1` | ❌ no mainline driver |
| **WSL2** | ⚠️ `usbipd-win` + WSL-kernel driver | ⚠️ same | ❌ — |
| **Native Windows** | vendor SDK — Kvaser **CANlib** | vendor SDK — PEAK **PCAN-Basic** | vendor SDK — Vector **XL Driver Library** |
| **CAN-FD** | classic only | ✅ FD | ✅ FD |

**Takeaway:** Kvaser and PEAK are the two best-supported vendors (in-tree SocketCAN
drivers) and the two this project supports today. Vector has no mainline Linux driver at
all, so it is Windows-SDK-only by nature — not a candidate for Linux/WSL work either way.

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

**FD note:** `transport.CanFrame` carries CAN-FD (`fd`/`brs`, up to 64 payload bytes), and
**SocketCAN sends it** — the socket asks for `CAN_RAW_FD_FRAMES` at open and falls back to
classic-only when the interface declines, so an FD send on a classic interface fails at write()
rather than going out truncated. Verified end-to-end on **vcan0 at `mtu 72`**, replaying 29,275
CAN-FD frames from a real vehicle capture: our reader saw `fd=29275 brs=29275`, 26,370 payloads
over 8 bytes, 64-byte maximum — and `candump -x` (can-utils, an independent implementation)
captured the same 29,275 frames with `[16]`/`[32]`/`[48]` payloads and the `B` (BRS) flag.
Receive was checked the other way round, with `cansend vcan0 '123##1…'` decoding correctly.

A virtual FD bus needs the `vcan` module, which the stock WSL2 kernel does **not** ship
(`CONFIG_CAN_VCAN` is not set) — see the note below. The **PCAN and Kvaser backends do not**: they write classic
frames and now refuse an FD frame outright. The PCAN Pro FD and Vector are the FD-capable
devices, so those backends are where the remaining work is.


## CAN on WSL2 — the kernel does not ship `vcan`

The stock WSL2 kernel has `CONFIG_CAN=m` and `CONFIG_CAN_RAW=m`, but **`CONFIG_CAN_VCAN` is not
set** and no `vcan.ko` exists, so `ip link add type vcan` cannot work and neither can any USB CAN
driver (`peak_usb`, `kvaser_usb` are absent too). Anything needing SocketCAN — including
`scripts/setup_vcan.sh` — fails on a stock install, whatever those scripts claim.

Building just the module is enough; the kernel itself does not have to be replaced, because
`CONFIG_MODULES=y` and there is no `MODULE_SIG_FORCE`. Three details decide whether it loads:

```sh
sudo apt install -y flex bison libssl-dev libelf-dev dwarves bc cpio
git clone --depth 1 -b linux-msft-wsl-$(uname -r | cut -d- -f1) \
    https://github.com/microsoft/WSL2-Linux-Kernel && cd WSL2-Linux-Kernel
zcat /proc/config.gz > .config
./scripts/config --module CONFIG_CAN_VCAN --module CONFIG_CAN_VXCAN
make olddefconfig
make LOCALVERSION= -j$(nproc)          # LOCALVERSION= is NOT optional, see below
modinfo -F vermagic drivers/net/can/vcan.ko   # must equal `uname -r` + " SMP preempt mod_unload modversions"
sudo modprobe can-dev && sudo insmod drivers/net/can/vcan.ko
sudo ip link add dev vcan0 type vcan && sudo ip link set vcan0 mtu 72 && sudo ip link set up vcan0
```

- **`LOCALVERSION=`** — without it the build stamps `…-WSL2+` and `insmod` refuses the module.
  `setlocalversion` looks for a tag named `v<KERNELVERSION>`; Microsoft's tag is
  `linux-msft-wsl-<version>`, so it never matches and the script marks the tree "past a tag"
  with `+`. Setting `LOCALVERSION` (even to empty) skips that suffix. `touch .scmversion` does
  **not** work on 6.6 — that support was removed from the script.
- **A full `make`, not `modules_prepare`** — WSL ships no `/lib/modules/$(uname -r)/build` and no
  `Module.symvers`, and the vermagic ends in `modversions`, so the symbol CRCs have to come from
  a real build of the tree.
- **`cpio`** is needed by `CONFIG_IKHEADERS`. If you cannot install it,
  `./scripts/config --disable CONFIG_IKHEADERS` is safe: it only embeds a headers tarball and
  changes no struct layout, vermagic or symbol CRC.
- **`mtu 72`** is what makes vcan CAN-FD capable. Nothing else is required for FD.

Nothing persists across `wsl --shutdown` except the built `.ko`, so the `insmod` and `ip link`
steps run once per session.
