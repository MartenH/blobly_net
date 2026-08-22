<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
  <img src="docs/logo-light.png" alt="Blobly Net" width="480">
</picture>

An automotive bus tester written in [V](https://vlang.io). It exercises a System Under
Test (SUT) over **CAN**, and over **Ethernet** using the automotive protocols that run on it
(**DoIP**, **SOME/IP**) — send and observe traffic, run diagnostics, script test cases,
simulate ECUs, and read back logs — **virtual first** (Linux `vcan0`), with real hardware as
a drop-in.

> ## ⚠ Very early in development
>
> This is a single-author project still in its **design phase** — not a product, and not
> something to rely on yet. Specifically:
>
> - **Maturity varies a lot between features.** The protocol engine in `modules/` is
>   [unit-tested and runs in CI](#how-its-tested) on every push; a fair amount of the rest has
>   only ever been exercised on the
>   author's own bench, against the author's own boards. Some of it is **effectively untested**,
>   and a feature existing here is not a claim that it is correct.
> - **Formats and interfaces will change** — `.blobnet` projects, and the wire formats shared
>   with blobly_emb. Releases are tagged, but a version number is not yet a compatibility
>   promise.
> - **It has had no users but the author**, so expect missing validation, unhandled edge cases
>   and error paths nobody has walked.
>
> It is used daily against real hardware and is genuinely useful — but go in expecting to hit
> things, and please [open an issue](../../issues) when you do.

**Two ways to drive it, over the same engine:** the **GUI** for interactive work, and
**[headless](#headless--scripted-no-gui)** — Lua test scripts and CLI tools with no window and
no display, which is how it runs in CI. The protocol engine lives in `modules/` and imports no
GUI code, so scripted use is a first-class path, not a cut-down one. (The reverse isn't claimed:
editing a DBC or watching a live plot needs the GUI.)

![Blobly Net — live trace, decoded signals and real-time plots](docs/screenshots/overview.png)

*The `restbus-2vcan` project on two virtual CAN networks. The **origin** column says who put
each frame on the wire: `TX-S` is our own rest-of-bus simulation (Powertrain, BodyStatus,
Heartbeat, and the Response it answered with), `TX` is the tester's own Request, and `RX` is
everything Blobly Net did not send — here a stand-in chassis ECU running as a separate process
on `vcan0` (WheelSpeeds, BrakeStatus). On a bench that same `RX` is the device under test; the
label means "not ours", and cannot tell a stand-in from silicon. The plots mix the two sources
on one timeline.*

## Get it

**[Releases](../../releases)** carry a Windows zip and a Linux tar.gz per version, each under
one top-level folder — no GitHub sign-in, no expiry. (Ignore the `v-toolchain` entry — that is
CI's prebuilt compiler; if no `v0.x` release is listed yet, the first tag has not been cut —
use the Actions route below.) Both bundle the demo projects, DBCs, sample logs, the docs the
Help panel renders, a `README.txt` and a `VERSION.txt`. The **Windows zip is self-contained**
(mingw runtime DLLs included; run the bundled `register_blobnet_win.ps1` to make `.blobnet`
files open in the app). The **Linux tar.gz needs the distro runtime**:
`sudo apt install libglfw3 libfreetype6 libgl1`. Which version you have: `VERSION.txt`, the
window title, or `./blobly_net --version` — on Windows the exe is a GUI-subsystem program, so
pipe it (`blobly_net.exe --version | more`).
**Vendor CAN libraries are never bundled** — `vxlapi64.dll`, `PCANBasic.dll`, `canlib32.dll`
come with the vendor's own driver installs (the Vector XL terms forbid redistributing it).
Every release is cut from a tag the release workflow verifies against reviewed `main` and
against the version in `v.mod`, which is the same value the binary decodes and reports.

**Between releases (Windows)** — CI still builds the bundle on every push to `main` (pull
requests compile-validate but publish no artifact, so every downloadable bundle comes from
reviewed `main`). Take it from **[Actions](../../actions/workflows/windows.yml)** → the latest
`windows-build` run **on `main`** → the **`blobly_net-windows-x64`** artifact. Unzip and run
`blobly_net.exe` — same self-contained contents as a release zip, minus the top-level folder.
Two caveats: downloading an artifact requires being signed in to GitHub, and artifacts expire
(~90 days), so use a recent run.

**Linux / WSL2 from source** — it's two commands, see [Build & run](#build--run) below.

**macOS** — not built or tested.

## What it does

**Buses & transport**
- **CAN / CAN-FD** — SocketCAN on Linux; PCAN, Kvaser and Vector XL on Windows (see the
  hardware/OS matrix below). CAN-FD on SocketCAN and the software buses; the Windows vendor
  backends refuse an FD frame rather than truncating it.
- **Software buses** for driver-free tests — in-process (`inproc:`) and UDP multicast, so the
  whole test suite runs with no hardware and no drivers.
- **Ethernet** — **DoIP** (UDS over TCP) and **SOME/IP** (incl. an RPC client), over ordinary
  TCP/UDP sockets. Automotive *PHYs* (100BASE-T1 and similar) and TSN are out of scope.
- **LIN** — 🧭 [planned](ROADMAP.md), not implemented yet

**Diagnostics**
- **ISO-TP** (ISO 15765-2) and a **UDS client** over it
- **DoIP** (ISO 13400) — UDS over TCP, tester side and entity (server) side
- **Firmware flashing** — `cmd/flash` and the GUI Flash panel, UDS download with 0x29 auth
- **Shell panel** — an interactive console to the target over CAN

**Databases & decoding**
- **DBC** parse, decode, encode — multiplexing and value tables included
- **DBC editor** in the GUI — forms, a bit-matrix grid, live save, read-only while running
- **`candump -l` logs** and a native **ASAM MDF4** (`.mf4`) reader

**Simulation** ([manual](docs/simulation.md))
- **Simulated ECUs** in-process — cyclic senders, signal generators (sine, sawtooth, counter,
  step), request/response rules and per-ECU UDS servers, so tests need no hardware
- **Rest bus** from a real recording — replay a capture with the ECU under test subtracted by
  DBC sender, so it cannot argue with a recording of itself
- **Multi-bus replay** — several recorded buses onto several live ones from one clock, because
  the timing *between* buses is what a gateway polices
- **Fault injection** — drop, bad CRC, frozen counter, out-of-range, applied around end-to-end
  protection rather than after it

**Scripting & automation**
- **Embedded Lua** with a test-framework prelude, and a **headless runner** for CI
- **Projects** are `.blobnet` files (YAML) describing buses, channels and databases

**Trace & analysis**
- Live trace with signal decode, a send panel, and telemetry capture
- **Trace chart** — handler/thread swimlanes, a derived idle lane, execution-vs-response bars
- **Cross-core time correlation** — a satellite core's block carries its measured clock offset
- **System panel** — a read-only view of a blobly_emb `system.toml`

### CAN hardware — and why the same adapter is named differently per OS

The **same physical adapter** is reached through a **different software stack** depending on where
Blobly Net runs, so the interface string differs too:

| | Linux / **WSL2** | native Windows |
|---|---|---|
| **PEAK PCAN** | ✅ kernel `peak_usb` → SocketCAN `can0` | ✅ PCAN-Basic DLL → `pcan:PCAN_USBBUS1@500000` |
| **Kvaser** | ✅ kernel `kvaser_usb` → SocketCAN `can0` | ✅ CANlib DLL → `kvaser:0@500000` |
| **Vector** (VN16xx…) | ❌ no mainline driver | ✅ XL Driver Library → `vector:1@500000` (HW-verified on a VN1630A; add `,silent` to listen without acknowledging) |
| CAN-FD | PCAN ✅ · Kvaser Leaf Light v2 is classic-only | PCAN ✅ · Kvaser and Vector refuse FD rather than truncating |

- **On Linux and WSL2** the *kernel* owns the adapter and presents it as a **SocketCAN netdev**
  (`can0`), so Blobly Net just uses SocketCAN — no vendor SDK involved.
- **On native Windows** there is no SocketCAN, so the adapter is reached through the **vendor's
  userspace DLL**, loaded at runtime (no SDK to build against; you do need the vendor driver).
- **WSL2 needs one extra step:** USB isn't exposed by default, so attach the adapter with
  `usbipd-win` first — `scripts/usbip.sh attach <busid>` — after which the kernel driver creates
  `can0` exactly as on native Linux.

Full detail, including the WSL kernel requirements:
[can_hardware.md](docs/can_hardware.md) · [windows_can_hardware.md](docs/windows_can_hardware.md).

**Diagnostics** — **UDS** over **ISO-TP** (ISO 15765-2), plus a **flashing** tool that
drives a UDS firmware-download session against a [blobly_emb](docs/blobly_emb_synergies.md)
bootloader.

**Databases & signals** — a native **DBC** parser (`candb`) with a **DBC editor** in the
GUI: decode/encode signals, value tables, multiplexing, and a canonical writer so a
save/load cycle never drifts a file (git diffs show real changes only).

**Simulation** — simulated ECUs that send and answer frames, so tests need no hardware.

**Logs & replay** — `candump -l` files, native **ASAM MDF4** (`.mf4`) reading, and **replay**
of a recording at its original cadence.

**Observability** — a **trace/telemetry** view of a running SUT (handler and thread
swimlanes, CPU load), and a read-only **System** panel showing the modelled network.

![Two-core trace swimlane from a live STM32H755, with an interactive shell to the target](docs/screenshots/trace-multicore-h755.png)

*A dual-core **STM32H755** traced live over SocketCAN. Handler lanes on top (`c0` = the CM7's
`LoadFast`/`LoadMid`/`Governor`/`LoadSlow`, `c1` = the CM4's `M4Load`/`M4Churn`), RTOS thread
lanes below with their priorities, a derived idle lane, and preemption cut-links joining a
preempted thread to what displaced it. Both cores share **one** timeline: each stamps records
from its own free-running clock, so the target measures the offset per dump and the header
reports it —* `1/1 satellite core(s) time-corrected (±608 µs)` *— rather than silently implying
the lanes are comparable. Below, the **Shell** panel talks to the target over CAN (`bmc` is an
on-target DWT benchmark: cycles, CPI, stalls).*

> ### ⚠ This screenshot needs the other half — which isn't released yet
>
> The **trace swimlane**, **Shell**, **Flash** and **System** panels don't test an arbitrary
> ECU: they speak wire formats implemented by
> [**blobly_emb**](docs/blobly_emb_synergies.md), the companion embedded stack that runs on the
> target. They are the group at the bottom of the activity bar (`Cht`/`Fsh`/`Shl`/`Sys`),
> deliberately separated there for this reason.
>
> **blobly_emb is not publicly released yet**, so today those four panels have nothing to talk
> to. Everything else on this page — CAN and CAN-FD, DBC decode/encode and the editor, ISO-TP,
> UDS, DoIP, SOME/IP, simulated ECUs, logs, replay and Lua scripting — is standalone and works
> against any target, or against no hardware at all.

**Scripting** — **Lua** test scripts with a small test framework, runnable headless in
CI or live in the GUI.

The GUI is a native **Dear ImGui + ImPlot** application (`cmd/blobly_net`). The **protocol
engine** underneath it is equally reachable without a display — see
[headless](#headless--scripted-no-gui) — though the interactive editors (DBC, project/bus
config) and the live plots exist only in the GUI.

## Build & run

**Linux, including WSL2** — Ubuntu 24.04 is what this is developed on. Under WSL2 the GUI
renders through **WSLg**, so there's no X server to set up, but hardware GL wants a current Mesa
(25.x is known good; older Mesa crashed the GPU path). **Native Windows is a different
toolchain** — MSYS2/mingw, not these scripts. The recipe is
[`windows.yml`](.github/workflows/windows.yml), which CI runs on every push; or just take the
[prebuilt bundle](#get-it). macOS is not built or tested.

```sh
scripts/setup_env.sh           # installs toolchain + deps (V, C/C++, GLFW, FreeType)
scripts/run_gui.sh            # build + run the GUI
```

To reproduce the screenshot above — no hardware, no drivers, nothing else to start:

```sh
BLOBLY_PROJECT=projects/sim-demo.blobnet BLOBLY_AUTOSTART=1 scripts/run_gui.sh
```

The simulated ECUs are native (`modules/sim`) and run in-process.

### Dependencies

`setup_env.sh` installs these for you; the lists are here for anyone building by hand. **The CI
workflows are the source of truth** — they build from nothing on a clean runner every push, so
if this drifts, believe them.

**Linux** (Debian/Ubuntu) — mirrors [`ci.yml`](.github/workflows/ci.yml):

```sh
sudo apt install g++ pkg-config libglfw3-dev libfreetype-dev libgl1-mesa-dev
```

**Native Windows** — MSYS2 `MINGW64`, mirroring
[`windows.yml`](.github/workflows/windows.yml). More than the Linux set, because the glyph
rasterizer and text stack are not system libraries there:

```sh
pacman -S git mingw-w64-x86_64-{gcc,pkgconf,glfw,freetype,harfbuzz,glib2,fribidi,fontconfig}
```

Plus the V compiler on both. For Windows, [`.github/workflows/windows.yml`](.github/workflows/windows.yml)
is the full recipe — it runs on every push, so unlike a hand-written walkthrough it cannot quietly
drift. Or skip building entirely and take the [prebuilt bundle](#get-it).

## Headless / scripted (no GUI)

The engine is GUI-free by design, so the whole tool runs without a window — no display, no
GLFW, nothing to click. This is how it runs in CI.

**Lua test scripts** (diagnostics, raw frames, DBC signals) against a simulated bus and ECU.
No hardware, no display; non-zero exit if any test fails:

```sh
scripts/runtests.sh tests/diag_basic.lua tests/bus_signals.lua
# => 10 passed, 0 failed, 0 script error(s)
```

Point it at a different project with `--project projects/<name>.blobnet`. The full Lua API is
in the **[scripting & test guide](docs/scripting.md)**.

**CLI tools** — each runs standalone via
`v -enable-globals -path "@vlib|@vmodules|modules" run cmd/<tool>/<file>.v`:

| tool | what | |
|---|---|---|
| `flash` | drive a UDS firmware download against a blobly_emb bootloader | † |
| `trace_dump` | freeze + dump a target's trace rings and decode the records | † |
| `dbc_decode` | decode one CAN frame to physical signal values | |
| `mf4_dump` | parse an ASAM MDF4 log and summarise its frames | |
| `loadtest` | data-plane benchmark across many concurrent buses | |

† needs a **blobly_emb** target, which is [not released yet](#-this-screenshot-needs-the-other-half--which-isnt-released-yet).

**CI** (`.github/workflows/`) runs `v -enable-globals test modules/` plus
`scripts/runtests.sh` — no display involved. See [How it's tested](#how-its-tested).

## How it's tested

Worth being explicit, since [maturity varies](#-very-early-in-development) — this is the
evidence behind that warning.

**Automated on every push:**

| layer | what | where |
|---|---|---|
| **Unit tests** | 32 test files, ~870 assertions across every module | `v -enable-globals test modules/` |
| **Golden byte vectors** | wire formats are pinned to exact bytes — SOME/IP headers, trace records, the simulated ECU's frames — and the same vectors exist on the blobly_emb side, so neither repo can drift alone | inside the unit tests |
| **Headless integration** | 4 Lua suites drive real diagnostics and signal traffic against an in-process bus, simulated ECU and the native UDS server | `scripts/runtests.sh` |
| **GUI build** | the ImGui app compile-links on Linux and Windows | `ci.yml`, `windows.yml` |

**Not automated — done by hand, and worth knowing about:**

- **Cross-checked against independent implementations.** Decoders are diffed against cantools
  (DBC), asammdf (MDF4) and a hand-written Python ECU, so a V decoder is never validated only by
  the matching V encoder. These are the [oracles in `sut/`](sut/README.md); they are not in CI.
- **Hardware.** PCAN, Kvaser and Vector adapters are verified on real buses, and target-facing
  features against STM32 boards on the author's bench. CI runners have none of it, so none of
  this is gated — and for Vector a runner could not be, since the XL library may not be
  redistributed. Every vendor ✅ means *verified by hand, on the bench and date named in*
  [windows_can_hardware.md](docs/windows_can_hardware.md); CI proves those backends compile and
  link, nothing more.

**The gaps, plainly:** there is **no automated GUI testing** — CI proves the app builds, not that
a panel behaves. The Windows job **builds but runs no tests**. And every hardware and oracle check
above is manual, so a regression there is caught only when someone next runs it.

## Docs

**Using it**
- [scripting.md](docs/scripting.md) — Lua scripting + the headless test runner
- [dbc_editor.md](docs/dbc_editor.md) — the DBC editor
- [project_editing.md](docs/project_editing.md) — projects, buses and channels
- [bus_config_dialog.md](docs/bus_config_dialog.md) — bus/hardware configuration

**Design**
- [ethernet_architecture.md](docs/ethernet_architecture.md) — DoIP / SOME/IP
- [simulation_architecture.md](docs/simulation_architecture.md) — simulated ECUs
- [blobly_emb_synergies.md](docs/blobly_emb_synergies.md) — the SUT-side companion project

**Platform & troubleshooting**
- [can_hardware.md](docs/can_hardware.md) — real CAN adapters ·
  [windows_can_hardware.md](docs/windows_can_hardware.md) — PCAN/Kvaser/Vector on Windows,
  and what is verified by hand rather than by CI
- [known_issues.md](docs/known_issues.md) — gotchas (V / GUI / environment / CI)

**Project**
- [CLAUDE.md](CLAUDE.md) — architecture & decisions (the guide for coding agents)
- [ROADMAP.md](ROADMAP.md) — what's next, planned, and out of scope
- [CONTRIBUTING.md](CONTRIBUTING.md) — issues welcome; PRs not yet (design phase)

## License

MIT — see [LICENSE](LICENSE).
