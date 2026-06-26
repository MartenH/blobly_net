# 👋 Read me on Windows (handoff — 2026-06-18)

Picking this up on the Windows machine? Here's the state and the next moves.

## State
- **CI is green** (Linux + Windows MSVC + Windows MSYS2/mingw). The Windows jobs
  compile the full GUI, so the build recipe is known-good.
- **PCAN + Kvaser hardware backends are merged** (`transport/pcan_windows.v`,
  `transport/kvaser_windows.v`) and **compile** on both Windows toolchains — but
  they have **NOT been run against hardware yet**. That's the job here.
- No SDK needed: the vendor DLLs are loaded at runtime. You DO need the **vendor
  drivers installed** (you said they weren't yet).

## Do this, in order

### 0. Build Blobly Net on Windows
- mingw: `scripts\build_win.ps1` (see [windows_build.md](windows_build.md) for the
  one-time toolchain setup), **or** download the `blobly_net-mingw-x64` /
  `blobly_net-msvc-x64` artifact from the latest green CI run.

### 1. Kvaser FIRST — it needs NO adapter connected
- Install the **Kvaser Drivers for Windows** (free) → installs `canlib32.dll` + the
  software **virtual channels**.
- Open **Kvaser Device Guide**, note a **virtual channel number** (e.g. 0 or 1).
- Loopback over the virtual bus — make a project `.yml` (adjust the channel number):
  ```yaml
  project: { name: kvaser-virtual, version: 1 }
  channels:
    - { name: KV,   type: can, interface: "kvaser:0@500000", mode: monitor,
        databases: ["dbc/blobly_net.dbc"] }
    - { name: KVTX, type: can, interface: "kvaser:0@500000", mode: monitor }
  ```
  Run `scripts\run.ps1` (or the built exe) with `BLOBLY_PROJECT` pointed at it,
  ▶ Start, then send a frame (Send/Generators panel, or a Lua `bus.send("KVTX", …)`)
  and confirm it shows up on `KV`. This proves the whole Kvaser path with no wiring.

### 2. PCAN — needs the physical adapter
- Install the **PEAK PCAN driver** (free) → `PCANBasic.dll`.
- Plug the PCAN-USB adapter onto a **terminated, powered** bus (or two PCAN channels
  back-to-back). Project channel: `interface: "pcan:PCAN_USBBUS1@500000"`.
- ▶ Start → live trace + decode; Send a frame and confirm RX on the other node.

### 3. Cross-check against python-can (the oracle, like the SUT)
- `pip install python-can`; transmit/receive with `interface="kvaser"` /
  `"pcan"`, channel matching above, and diff against Blobly Net's trace.

## If something's off
- The shims are written from the **documented** vendor ABI, unverified on silicon.
  Likely suspects if frames are wrong: struct packing in `pcan_shim.h` /
  `kvaser_shim.h`, a status-code constant, or the bitrate code map.
- Full detail + the "what good looks like" checklist:
  **[windows_can_hardware.md](windows_can_hardware.md)**.
- Jot findings into the CLAUDE.md status log so the next session can correct the shim.

## Also worth a look while here
- Press ▶ Start in the GUI and try the **Script** panel (`ƒ` icon) — run
  `tests\diag_basic.lua` against a sim channel. See [scripting.md](scripting.md).
