# Windows real-CAN hardware support — design

Status: **DESIGN ONLY (2026-06-18)** — no backend code yet. This documents how real
CAN adapters (PCAN / Kvaser / Vector) and the vendor-neutral `slcan` path will slot
into CANTester on Windows, behind the existing `transport.Bus` seam. Owner has PCAN
+ Kvaser hardware on hand and intermittent access to a Vector machine.

## Why there's work to do at all

On **Linux**, CAN is an OS service: SocketCAN lives in the kernel and exposes ONE
standard API (`AF_CAN` socket). Bring up `can0`/`vcan0` and every SocketCAN-aware
program talks to it the same way — which is why `transport/socketcan_linux.v` is thin.

**Windows has no OS-level CAN standard.** Installing a vendor's driver makes the
device work and ships the vendor's **user-mode DLL**, but each vendor exposes its
*own* proprietary API. So the end user installs a driver and is done; CANTester, by
contrast, needs a **per-vendor backend** that loads that DLL and calls its functions.

| | Linux | Windows |
|---|---|---|
| CAN API | one kernel standard (`AF_CAN`) | none — per-vendor DLLs |
| What the user installs | (kernel has it) | vendor driver package |
| What CANTester needs | one SocketCAN backend | one backend **per vendor** |

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
kvaser:virtual0        # Kvaser SOFTWARE virtual channel (no hardware needed)
vector:CANcaseXL:0     # Vector app/channel
vector:virtual         # Vector virtual CAN bus
slcan:COM5@500000      # USB-serial slcan adapter on a COM port
```

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

## Phasing

1. **P1 — PCAN backend** (`transport/pcan_windows.v` + `pcan_shim.h`,
   `open_windows.v` branch, bitrate map). Establishes the LoadLibrary pattern + the
   verification recipe. Owner verifies on the PCAN adapter.
2. **P2 — Kvaser backend**; use a virtual channel to self-test before hardware.
3. **P3 — slcan backend** (serial; cross-platform — also usable on Linux).
4. **P4 — Vector backend** when a Vector machine is available.

Each phase: backend compiles in Windows CI (gate), then owner runs the verification
plan above and reports results back into the status log.
