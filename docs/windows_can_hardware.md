# Windows real-CAN hardware support — design

Status: **PCAN + Kvaser backends HW-VERIFIED 2026-06-18.** Cross-vendor, bidirectional
send/recv on a shared 500 kbit/s bus (Kvaser Leaf Light v2 ↔ PCAN-USB Pro FD): Kvaser
TX `0x123#DEADBEEF` → PCAN RX byte-identical, and PCAN TX `0x456#CAFE` → Kvaser RX,
via `cmd/can_smoke` (defaults `kvaser:0` / `pcan:PCAN_USBBUS1` worked first try). The two
vendor stacks agreeing on the wire is itself the cross-vendor oracle.
This documents how real CAN adapters (PCAN / Kvaser / Vector) and the vendor-neutral
`slcan` path slot into Blobly Net on Windows, behind the existing `transport.Bus`
seam. PCAN and Kvaser are hardware-verified; **Vector is implemented, cross-compiled and
run on Windows, but not yet exercised against a bus** — see below.

- **Done:** `transport/pcan_windows.v` + `pcan_shim.h`, `transport/kvaser_windows.v`
  + `kvaser_shim.h`, wired into `open_windows.v` (`pcan:` / `kvaser:` prefixes).
  Both are LoadLibrary-based (no SDK). **Cross-compiled to a real Windows x64 PE
  from WSL** (mingw-w64) and compile-checked in the Windows CI — but **not yet run
  against hardware** (no adapter/driver on the dev box).
- **Vector (`vector:`):** `transport/vector_windows.v` + `vector_shim.h`, wired into
  `open_windows.v`. Addressed by APPLICATION channel (`vector:1`), because that is what
  `xlGetApplConfig`/`xlGetChannelMask` take and what Vector Hardware Manager shows — the
  alternative is reproducing `XLdriverConfig`, a packed struct whose exact size decides
  where its channel array starts, and getting that wrong reads out of bounds instead of
  failing. Classic CAN only; an FD frame is refused, not truncated.
  - Cross-compiled from WSL with mingw-w64 to a real Windows x64 PE, and the shim compiles
    clean under `-Wall -Wextra` against the actual `windows.h`. `_Static_assert` pins
    `sizeof(XLevent) == 48` at build time rather than trusting a comment.
  - `cmd/vectorcheck` was RUN on this Windows host (WSL interop) and correctly reported the
    real blocker below. What is still unproven is everything past `xlOpenPort`: no frame has
    gone in or out.

  **What is missing on this bench (2026-08-19):** the VN1630A and its kernel driver are fine —
  `Get-PnpDevice` shows `VN1630A` and the Vector services as `OK`, and Vector Hardware Manager
  is installed — but **`vxlapi64.dll` is not on the system at all** (not in `System32`, not
  under either `Program Files`). The XL Driver Library is a separate free download from
  Vector; the hardware/config install does not include it. Until it is there, `vector:` opens
  will report exactly that.

- **Pending:** owner runs the verification below; slcan backend later.

## Why there's work to do at all

On **Linux**, CAN is an OS service: SocketCAN lives in the kernel and exposes ONE
standard API (`AF_CAN` socket). Bring up `can0`/`vcan0` and every SocketCAN-aware
program talks to it the same way — which is why `transport/socketcan_linux.v` is thin.

**Windows has no OS-level CAN standard.** Installing a vendor's driver makes the
device work and ships the vendor's **user-mode DLL**, but each vendor exposes its
*own* proprietary API. So the end user installs a driver and is done; Blobly Net, by
contrast, needs a **per-vendor backend** that loads that DLL and calls its functions.

| | Linux | Windows |
|---|---|---|
| CAN API | one kernel standard (`AF_CAN`) | none — per-vendor DLLs |
| What the user installs | (kernel has it) | vendor driver package |
| What Blobly Net needs | one SocketCAN backend | one backend **per vendor** |

## The seam (unchanged)

Callers depend only on `transport.Bus` (`send`/`recv`/`close`) and on
`transport.open(iface) !Bus`. The dispatcher is split per OS:

- `open_linux.v` → `inproc:` / `udp:` / else SocketCAN (`vcan0`,`can0`).
- `open_windows.v` → today: `inproc:` / `udp:` only; errors otherwise.

New Windows backends are **additive**: each is a `transport/<vendor>_windows.v` file
(V gates it to Windows by the `_windows.v` suffix, exactly like `socketcan_linux.v`),
implementing `Bus`, and `open_windows.v` gains a prefix branch. **Nothing in shared
code or on Linux changes.** Linux stays green; the backends never compile off-Windows.

### Interface strings (project `.yml` `interface:`)

```
pcan:PCAN_USBBUS1      # PEAK channel handle name (or pcan:usb1)
kvaser:0               # Kvaser channel number
vector:1               # Vector APPLICATION channel, as numbered in Vector Hardware Manager
vector:1@250000        # …at 250 kbit/s
vector:1@500000,silent # …listen-only: the transceiver never acknowledges
kvaser:virtual0        # Kvaser SOFTWARE virtual channel (no hardware needed)
slcan:COM5@500000      # USB-serial slcan adapter on a COM port  (not implemented)
```

The two `vector:` spellings this file used to show — `vector:CANcaseXL:0` and
`vector:virtual` — were sketches from before the backend existed, and the shipped parser
rejects both. A Vector channel is addressed by its application channel number; there is no
Vector software-virtual bus here (use `inproc:` for driver-free work).

The existing `Channel` config already carries everything a backend needs:
`bitrate`, `fd`, `data_bitrate`, `sample_point`, `timing{brp,tseg1,tseg2,sjw}`,
`listen_only`. Each backend maps these to its vendor init call (e.g. PCAN's
`TPCANBaudrate` enum for standard rates, or the raw `timing{}` for custom BTR).

## No SDK, no MSVC: load the DLL at runtime

We **do not** need the vendor SDK as a build dependency and **do not** need MSVC.
Each backend declares the handful of function prototypes itself (from the vendor's
documented ABI) and resolves them from the DLL at runtime via
`LoadLibraryW`/`GetProcAddress` (a tiny `*_shim.h`, same style as
`socketcan_shim.h`). Consequences:

- No import `.lib`, so the mingw/MSYS2 toolchain is fine (no MSVC-only `.lib`).
- Nothing of the vendor's to redistribute — the user installs the driver, which
  brings the DLL. We just bind to it if present (and surface a clean error if not).
- The C APIs of all three vendors are plain C (no C++ ABI), so this is clean.

## Per-vendor notes

### PCAN (PEAK) — do FIRST (reference backend)
- DLL: `PCANBasic.dll`. ~6 calls: `CAN_Initialize`, `CAN_Uninitialize`,
  `CAN_Read`, `CAN_Write`, `CAN_GetStatus`, `CAN_GetErrorText`.
- Frames: `TPCANMsg{ ID u32; MSGTYPE u8; LEN u8; DATA [8]u8 }` ↔ our `CanFrame`
  (MSGTYPE flags carry extended/RTR). Standard bitrates via the `TPCANBaudrate`
  enum (`PCAN_BAUD_500K`, …); custom rates exist but the enum covers our cases.
- No software virtual channel in the free driver → needs the physical adapter to test.
- Friendliest, permissive, widely used → the template the others copy.

### Kvaser (CANlib) — do SECOND
- DLL: `canlib32.dll`. Calls: `canInitializeLibrary`, `canOpenChannel`,
  `canSetBusParams`, `canBusOn`, `canWrite`, `canReadWait`, `canBusOff`, `canClose`.
- **Virtual channels in software** (`kvaser:virtual0`) → exercise the backend with
  NO physical bus; great for dev and possibly CI on a Windows runner.
- `canSetBusParams` takes bitrate + segment timing → maps directly from `timing{}`.

### Vector (XL Driver Library) — do LAST
- DLL: `vxlapi64.dll`. More verbose: `xlOpenDriver`, `xlGetChannelMask`,
  `xlOpenPort`, `xlActivateChannel`, `xlReceive`, `xlCanTransmit`, `xlDeactivateChannel`,
  `xlClosePort`, `xlCloseDriver`.
- Has a **virtual CAN bus** for testing. Licensing/ecosystem friction is the
  highest; access is intermittent → lowest priority.

### slcan (USB-serial) — vendor-neutral fallback, anytime
- Hardware: CANable / CANtact / USBtin (~$30). Shows up as a **virtual COM port**;
  ASCII line protocol (`O` open, `S6` 500k, `t<id><len><data>`, `T…` for 29-bit).
- **No vendor DLL, no SDK** — just serial I/O (vlib has serial, or a tiny COM shim).
  Works identically on Linux and Windows. `python-can` has an `slcan` backend as the
  oracle. Strong candidate for the *first real frames on real wire* with least friction.

## Verification plan (owner runs on Windows)

Backends can be **written** here but **not verified against hardware from Linux**
(same constraint as the Windows CI jobs). On the Windows box:

1. **Compile**: the Windows CI (MSVC + MSYS2 jobs) already compile-checks any new
   `*_windows.v` — so the backend can't silently rot, even unverified against HW.
2. **Loopback / two-channel**: a two-channel adapter (or two adapters on one bus, or
   a vendor virtual channel) → open two `Bus`es, `send` on one, `recv` on the other.
3. **python-can cross-check** (the established oracle pattern): run `python-can` with
   the matching backend (`pcan`/`kvaser`/`vector`/`slcan`) on the same adapter and
   diff the frame stream — exactly how `sut/can_sut.py` cross-validates today.
4. **GUI smoke**: point a project `.yml` channel at `pcan:…`, press ▶ Start, confirm
   live trace + decode, and a Send round-trips against a second node / `candump`-equiv.

## Owner verification steps (run on Windows)

Prereq: a Blobly Net Windows build — the **`blobly_net-windows-x64`** bundle from the
latest `windows-build` run on `main` (Actions tab; unzip, it is self-contained). Then:

### Kvaser — testable with NO hardware connected (virtual channel)
1. Install the **Kvaser drivers** (Kvaser Drivers for Windows — free). This adds
   `canlib32.dll` *and* software **virtual channels**.
2. Open **Kvaser Device Guide** and note a **virtual channel's number** (virtuals
   are listed alongside physical ones, e.g. channel 0/1).
3. Loopback over the virtual bus — two Blobly Net channels on the same number:
   ```yaml
   channels:
     - { name: KV, interface: "kvaser:0@500000", mode: monitor }      # the number from step 2
     - { name: KVTX, interface: "kvaser:0@500000", mode: monitor }
   ```
   Send on one (Generators/Send panel or a Lua `bus.send`), see it on the other.
4. **python-can cross-check** (oracle): `pip install canlib` (Kvaser's Python) or
   use `python-can` with `interface="kvaser", channel=0`; transmit/receive and diff
   against Blobly Net's trace.

### PCAN — needs the physical adapter
1. Install the **PEAK PCAN driver** (free) → brings `PCANBasic.dll`.
2. Plug in the PCAN-USB adapter on a **terminated, powered** bus (or two PCAN
   channels back-to-back).
3. Project channel:
   ```yaml
   channels:
     - { name: PCAN, interface: "pcan:PCAN_USBBUS1@500000", mode: monitor }
   ```
   ▶ Start → confirm live trace + decode; Send a frame and see it answered by a
   second node (or another tool: `python-can` with `interface="pcan"`).

### What "good" looks like
- `transport.open("pcan:…"/"kvaser:…")` returns without error (DLL found, channel
  opens, bus-on).
- Frames sent by Blobly Net appear in `python-can` (same adapter/bus) byte-identical,
  and vice-versa — the established SUT-oracle pattern.
- Bitrate mismatch or missing termination shows up as no RX / bus-off — expected.

Report results (and any ABI surprises — struct packing, status codes) back into the
CLAUDE.md status log so the backend can be corrected; the code is written from the
documented ABI but unverified against silicon.

## Phasing

1. **P1 — PCAN backend** ✅ implemented + **HW-verified 2026-06-18** (TX+RX on real bus).
2. **P2 — Kvaser backend** ✅ implemented + **HW-verified 2026-06-18** (TX+RX on real bus).
3. **P3 — slcan backend** (serial; cross-platform — also usable on Linux). TODO.
4. **P4 — Vector backend** when a Vector machine is available. TODO.

Each phase: backend compiles in Windows CI (gate), then owner runs the verification
above and reports results back into the status log.
