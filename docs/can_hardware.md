# Real CAN hardware — Kvaser / PEAK / Vector across Linux, WSL, Windows

Support differs sharply by vendor *and* OS. Four vendors are **verified against real
hardware** — Kvaser (a Leaf Light v2, classic; a USBcan Pro 5xHS, FD), PEAK (PCAN-USB Pro FD),
Vector (a VN1630A, Windows-only because there is no mainline Linux XL driver) and CANsub (a
CSS Electronics CANsub.4, a USB *network* adapter reached identically from Linux and Windows
with no driver at all); the dates and runs are in
[`windows_can_hardware.md`](windows_can_hardware.md).

## Support matrix

| | Kvaser (Leaf Light v2, USBcan Pro 5xHS) | PCAN-USB Pro FD | Vector (VN16xx/…) | CANsub (CSS Electronics) |
|---|---|---|---|---|
| **Native Linux** | ✅ mainline `kvaser_usb` → `can0` (SocketCAN) | ✅ mainline `peak_usb` → `can0`/`can1` | ❌ no mainline driver | ✅ `cansub:<id>/1` — a network device, no driver |
| **WSL2** | ⚠️ `usbipd-win` + WSL-kernel driver | ⚠️ same | ❌ — | ✅ same (it is on the network, not USB-passthrough) |
| **Native Windows** | vendor SDK — Kvaser **CANlib** | vendor SDK — PEAK **PCAN-Basic** | vendor SDK — Vector **XL Driver Library** | ✅ the same string, the same code |
| **CAN-FD** | Leaf Light v2 classic only; USBcan Pro 5xHS ✅ FD to 8 Mbit/s | ✅ FD | ✅ FD | ✅ FD (64-byte BRS at 2 Mbit/s) |

**Takeaway:** Kvaser and PEAK are the two with in-tree SocketCAN drivers, so on Linux and WSL
they need no vendor code; Vector has no mainline Linux driver at all, so it is reached through
its Windows SDK only; CANsub is neither — it is a network device, and the one hardware backend
that works from Linux without SocketCAN (`cansub:<device-id>/1@500000`).

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

> **Kvaser, PEAK and Vector are all built and hardware-verified** — use the `kvaser:` /
> `pcan:` / `vector:` interface prefixes (and `cansub:` for the network adapter, on either OS).
> [`windows_can_hardware.md`](windows_can_hardware.md) is the current, detailed reference
> for the Windows path (DLL loading, bitrate mapping, listen-only, and what an `slcan`
> fallback would take — it is not implemented).

| Vendor | SDK | File | Key calls (open/tx/rx) | Discovery |
|---|---|---|---|---|
| Kvaser | CANlib (`canlib32.dll`) | `transport/kvaser_windows.v` | `canOpenChannel` / `canWrite` / `canReadWait` | `canGetNumberOfChannels` |
| PEAK | PCAN-Basic (`PCANBasic.dll`) | `transport/pcan_windows.v` | `CAN_Initialize` / `CAN_Write` / `CAN_Read` | `CAN_GetValue(PCAN_ATTACHED_CHANNELS)` |
| Vector | XL Driver Library (`vxlapi64.dll`) | `transport/vector_windows.v` (+ `vector_shim.h`, where the open/config calls live) | `xlOpenPort` / `xlCanTransmit`(`Ex`) / `xlReceive`, `xlCanReceive` | `xlGetDriverConfig` |

Each implements the existing `transport.Bus` interface, so callers don't change.
`discover_windows.v` enumerates Kvaser, PCAN and Vector channels alongside the software buses.
The `open()` dispatcher accepts `pcan:`, `kvaser:`, `vector:` and `cansub:` beside
`inproc:`/`udp:` — e.g. `kvaser:0`, `pcan:PCAN_USBBUS1@500000`, `vector:1@500000,silent`
(Vector channels are numbered from 1).

**FD note:** `transport.CanFrame` carries CAN-FD (`fd`/`brs`, up to 64 payload bytes), and
**SocketCAN sends it** — the socket asks for `CAN_RAW_FD_FRAMES` at open and falls back to
classic-only when the interface declines, so an FD send on a classic interface fails at write()
rather than going out truncated. Verified end-to-end on **vcan0 at `mtu 72`** against a real vehicle
capture: every FD frame arrived with its flags intact, payloads up to the 64-byte maximum, and
`candump -x` (can-utils, an independent implementation) saw the same frames with the `B` (BRS)
flag set.
Receive was checked the other way round, with `cansend vcan0 '123##1…'` decoding correctly.

A virtual FD bus needs the `vcan` module, which the stock WSL2 kernel does **not** ship
(`CONFIG_CAN_VCAN` is not set) — see the note below.

**Every vendor backend carries FD**, and each spells it the same way: the data rate in the address
is what asks for it. `vector:1@500000/2000000`, `kvaser:0@500000/2000000` and
`pcan:PCAN_USBBUS1@500000/2000000`, hardware-verified on a VN1630A, a USBcan Pro 5xHS and a
PCAN-USB Pro FD respectively — the first two to an 8 Mbit/s data phase, PCAN cross-vendor against
the Kvaser at 1, 2, 4 and 8 Mbit/s. A *classic* channel refuses an FD frame rather than truncating
it, on all three.


## CAN on WSL2 — the kernel does not ship `vcan`

The stock WSL2 kernel has `CONFIG_CAN=m` and `CONFIG_CAN_RAW=m`, but **`CONFIG_CAN_VCAN` is not
set** and no `vcan.ko` exists, so `ip link add type vcan` cannot work and neither can any USB CAN
driver (`peak_usb`, `kvaser_usb` are absent too). Anything needing SocketCAN — including
`scripts/setup_vcan.sh` — fails on a stock install, whatever those scripts claim.

A **custom** WSL2 kernel is a different case and a common one here: built with
`CONFIG_CAN_VCAN=y`, vcan needs no module at all. It then appears in no `lsmod` listing, and
such a build often ships no `/lib/modules/$(uname -r)` for `modprobe` to search — so both of the
usual "is vcan available?" tests say no while `ip link add type vcan` succeeds. That is why
`setup_vcan.sh` decides by creating an interface and only goes looking for a module when the
create fails.

**`scripts/build_vcan_module.sh` does all of this**, and is idempotent — it exits early when vcan
already works and skips the build when a module with the right vermagic is already there. It is
the RARE one: once, and again after a kernel upgrade. The per-session command is
`scripts/setup_vcan.sh`, which loads what the build produced and brings the interfaces up:

```sh
./scripts/build_vcan_module.sh        # build the module (once, and after a kernel upgrade)
./scripts/setup_vcan.sh               # EVERY SESSION: load it + bring up vcan0/vcan1 at mtu 72
./scripts/build_vcan_module.sh --build # build only, touch nothing on the running system
```

By hand, or to understand what the script does: building just the module is enough — the kernel
itself does not have to be replaced, because `CONFIG_MODULES=y` and there is no
`MODULE_SIG_FORCE`. Three details decide whether it loads:

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
