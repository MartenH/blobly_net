# CAN hardware on Windows

Windows has no OS-level CAN standard, so each vendor is its own backend. This is what
Blobly Net supports there, how it is addressed, and how far the support has actually been
verified. (On Linux the kernel owns the adapter and everything is SocketCAN — see
[can_hardware.md](can_hardware.md).)

## What is supported

| vendor | interface string | library | status |
|---|---|---|---|
| **PEAK PCAN** | `pcan:PCAN_USBBUS1@500000` | `PCANBasic.dll` | ✅ verified on hardware |
| **Kvaser** | `kvaser:0@500000` | `canlib32.dll` | ✅ verified on hardware |
| **Vector XL** | `vector:1@500000` | `vxlapi64.dll` | ✅ verified on hardware |
| slcan (USB-serial) | `slcan:COM5@500000` | none — serial | ❌ not implemented |

Classic CAN on all three. **CAN-FD is refused, not truncated**, on the Windows vendor
backends: a bench that silently dropped 56 of 64 payload bytes is worse than one that says no.

Software buses (`inproc:`, `udp:`) work on Windows exactly as on Linux and need no driver.

### What "verified" means here

By hand, on one bench, on the date given — **not** by CI. Nothing in CI opens a CAN channel;
no runner has an adapter, and for Vector no runner may even hold `vxlapi64.dll`, which cannot
be redistributed. The Windows job proves the code **compiles and links**: enough to catch a
signature that drifted, not enough to catch a bitrate that never reaches the transceiver.

- **PCAN + Kvaser, 2026-06-18** — cross-vendor on one 500 kbit/s bus (Kvaser Leaf Light v2 ↔
  PCAN-USB Pro FD): Kvaser TX `0x123#DEADBEEF` → PCAN RX byte-identical, and PCAN TX
  `0x456#CAFE` → Kvaser RX, via `cmd/can_smoke`. Two vendor stacks agreeing on the wire is
  itself the oracle.
- **Vector, 2026-08-19** — VN1630A (serial 545980), Channel 1 → Channel 3 over real
  transceivers (CANpiggy 1057Gcap → on-board 1051cap) at 500 kbit/s: **43,773 frames sent and
  received, none malformed**, sequence-checked end to end. That is ~4,400 frames/s, a
  saturated wire for eight data bytes — 111 bits per frame caps 500 kbit/s at ~4,504/s.
  One adapter, one bitrate, two channels of one device wired to each other; not a vehicle bus.

The **ABI is the exception**: 14 `_Static_assert`s pin every struct size and offset used by
the Vector backend, and those are compile-time, so the mingw job checks them on every push.
`vxlapi.h` (25.20.14) was read for each typedef and signature — `XLstatus` is `short`,
`XLportHandle` is `long` (32-bit here), `XLevent` is 48 bytes, `XLchannelConfig` 227,
`XLdriverConfig` 14576 — but the header is **not** included at build time, because we cannot
depend on a library we may not redistribute.

## Interface strings

```
pcan:PCAN_USBBUS1      # PEAK channel handle name (or pcan:usb1)
kvaser:0               # Kvaser channel number
kvaser:virtual0        # Kvaser SOFTWARE virtual channel (no hardware needed)
vector:1               # Vector APPLICATION channel, as Vector Hardware Manager numbers them
vector:1@250000        # …at 250 kbit/s
vector:1@500000,silent # …listen-only: the transceiver never acknowledges
```

A channel added through Discover starts silent on purpose: the 500 kbit/s default is a guess
until somebody confirms it, and a node joining a live bus at the wrong bitrate floods error
frames. There is no Vector software-virtual bus in Blobly Net — use `inproc:` for driver-free
work. (Vector's own virtual channels exist and `cmd/vectorcheck --selftest` uses them.)

A project `Channel` already carries `bitrate`, `fd`, `data_bitrate`, `sample_point`,
`timing{brp,tseg1,tseg2,sjw}` and `listen_only`; each backend maps those onto its vendor init
call — PCAN's `TPCANBaudrate` enum for standard rates, or raw `timing{}` for a custom BTR.

## Why a backend per vendor

On **Linux**, CAN is an OS service: SocketCAN lives in the kernel behind one standard API
(`AF_CAN`), which is why `transport/socketcan_linux.v` is thin. On **Windows** a vendor's
driver package makes the device work and ships the vendor's user-mode DLL, but each exposes
its own proprietary API.

| | Linux | Windows |
|---|---|---|
| CAN API | one kernel standard (`AF_CAN`) | none — per-vendor DLLs |
| What the user installs | (kernel has it) | vendor driver package |
| What Blobly Net needs | one SocketCAN backend | one backend **per vendor** |

## The seam

Callers depend only on `transport.Bus` (`send`/`recv`/`close`) and `transport.open(iface) !Bus`.
The dispatcher is per-OS: `open_linux.v` handles `inproc:` / `udp:` / SocketCAN;
`open_windows.v` handles `inproc:` / `udp:` / `pcan:` / `kvaser:` / `vector:` and errors
otherwise. Each backend is one `transport/<vendor>_windows.v` file — V gates it to Windows by
the `_windows.v` suffix, as with `socketcan_linux.v` — so a new vendor is additive and never
compiles off-Windows.

## No SDK, no MSVC: the DLL is loaded at runtime

Each backend declares the function prototypes it needs from the vendor's documented ABI and
resolves them with `LoadLibraryW`/`GetProcAddress` through a small `*_shim.h`. So:

- no import `.lib`, so mingw/MSYS2 is enough and MSVC is never required;
- nothing of the vendor's is redistributed — the user installs the driver, we bind to it if
  present and give a clean error if not;
- all three vendor APIs are plain C, so there is no C++ ABI to match.

## Per-vendor notes

**PCAN (PEAK)** — `PCANBasic.dll`; about six calls (`CAN_Initialize`, `CAN_Uninitialize`,
`CAN_Read`, `CAN_Write`, `CAN_GetStatus`, `CAN_GetErrorText`). Frames are
`TPCANMsg{ID u32; MSGTYPE u8; LEN u8; DATA [8]u8}`, with extended/RTR carried in the
MSGTYPE flags. The free driver has no software virtual channel, so testing needs the adapter.

**Kvaser (CANlib)** — `canlib32.dll` (`canInitializeLibrary`, `canOpenChannel`,
`canSetBusParams`, `canBusOn`, `canWrite`, `canReadWait`, `canBusOff`, `canClose`).
`canSetBusParams` takes bitrate plus segment timing, so `timing{}` maps straight onto it.
**Software virtual channels** (`kvaser:virtual0`) exercise the backend with no bus at all.

**Vector (XL Driver Library)** — `vxlapi64.dll`, the most verbose of the three
(`xlOpenDriver`, `xlGetApplConfig`, `xlGetChannelMask`, `xlOpenPort`, `xlCanSetChannelBitrate`,
`xlCanSetChannelOutput`, `xlActivateChannel`, `xlCanTransmit`, `xlReceive`, `xlClosePort`,
`xlCloseDriver`). Three things are specific to it:

- **Addressed by application channel**, because that is what `xlGetApplConfig` and
  `xlGetChannelMask` take and what Vector Hardware Manager numbers. `vector:1` is the channel
  the operator sees in that dialog.
- **`vxlapi64.dll` is a separate download from the hardware drivers** and does not install
  onto the search path: its installer puts it under
  `C:\Users\Public\Documents\Vector\XL Driver Library <version>\bin`. The loader tries the
  bare name first, then that directory. A bench can have a healthy VN device and Vector
  Hardware Manager installed with no XL library present at all.
- **`,silent` reaches the transceiver** — ACK-free output is set *before* the channel is
  activated, the only ordering that is safe against a running vehicle. A project's
  `listen_only:` is translated to it, and `cmd/vectorcheck --channel N` defaults to silent.
  On every other backend `listen_only` does not reach the transceiver, so the adapter still
  ACKs what it hears. What it DOES do everywhere, since #117, is stop this process
  transmitting: `transport.open` hands back a bus that refuses to send on a silenced wire, so
  no emitter can route around it. Two tiers, and the tooltip states both.

**slcan** — not implemented. CANable / CANtact / USBtin appear as a COM port speaking an
ASCII line protocol (`O` open, `S6` 500k, `t<id><len><data>`, `T…` for 29-bit); no DLL and no
SDK, and it would work identically on Linux and Windows.

## Checking a bench

`cmd/vectorcheck` is the Vector one: `--list` shows application channels with hardware
assigned, `--probe` shows what the driver reports as present, `--selftest` proves the backend
on Vector's own virtual channels with no hardware, and `--pair A,B` transmits on one channel
and verifies every frame arrives on another. It is silent by default — it will not
acknowledge on a bus until you ask it to.

For PCAN and Kvaser, `cmd/can_smoke` opens a channel and does a TX/RX round trip. Kvaser's
virtual channels make that possible with nothing plugged in.

What good looks like: `transport.open(...)` returns without error (DLL found, channel opens,
bus on); frames Blobly Net sends appear byte-identical in a second tool on the same bus —
`python-can` with the matching backend is the established oracle, as `sut/` does for decoding —
and a bitrate mismatch or missing termination shows up as no RX or bus-off, which is expected
rather than a bug in the backend.

## Pending

- **CAN-FD on Vector** — needs the V4 interface and a different event structure
  ([ROADMAP](../ROADMAP.md)).
- **slcan** — vendor-neutral, cross-platform, no DLL; the cheapest path to real frames on a
  bench with no vendor adapter at all.

## Bus health (fault ladder)

Every backend now reports the controller's fault ladder (warning / error-passive / **BUS-OFF**)
through one decode in `modules/transport/health.v`: PCAN via `CAN_GetStatus`, Kvaser via
`canReadStatus`, Vector from its chip state. The Buses panel colors the row (`BOFF` red) and
the Log narrates transitions. The decoders are pinned to the vendors' header constants by unit
tests; **the live paths are NOT yet hand-verified on hardware** — the same bench pass that
verified each backend's I/O should provoke a bus-off (short CANH/CANL, or a lone node
transmitting) and confirm the row turns red and the Log speaks.
