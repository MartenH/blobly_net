# CANTester (V) — project guide for Claude

An automotive bus tester written in **V (vlang)**. Long-term goal: test a SUT (System
Under Test) over **CAN / Ethernet / LIN** and the protocols on them. **Starting with CAN only**, and
**virtual first** (no real hardware yet). Build incrementally: get the GUI up first, then add features.

## 🆕 Fresh setup / new session — START HERE

This repo is the **single source of truth** — a new Claude session on a new machine has NO prior
memory (the old `~/.claude` memory does not transfer); everything needed is in git: this file +
`docs/known_issues.md` + the scripts.

Bootstrap a fresh box in one shot:
```sh
sudo ./scripts/setup_sudoers.sh   # optional: scoped passwordless sudo (apt-get/ip/modprobe) so the below won't prompt
./scripts/setup_env.sh            # installs V + gui native deps + can-utils, builds, brings up vcan0, runs tests
```
Then run the app:
```sh
./scripts/run.sh                       # HARDWARE GL (now the default — works on 24.04 / Mesa 24.x+)
CANTESTER_SOFTWARE_GL=1 ./scripts/run.sh   # software-GL fallback (always works; for old Mesa)
python3 sut/can_sut.py vcan0            # virtual ECU, in another terminal
```
**Context:** we moved off Ubuntu 22.04 → **24.04** specifically to get **Mesa 24.x**, because 22.04's
Mesa 23.2 crashed the GPU on our sokol hardware-GL path (full story in `docs/known_issues.md`).
**RESOLVED 2026-06-03:** on 24.04 + **Mesa 25.2.8** (OpenGL 4.5), hardware GL renders correctly under
WSLg — so `scripts/run.sh` now defaults to hardware GL. Software GL stays a one-env-var fallback if
hardware ever regresses; it's perfectly fine for this 2D app.

**⚠️ CAN is built into this kernel (`=y`), NOT a module.** Don't be fooled: `modprobe vcan` fails with
"Module vcan not found" and `/lib/modules/<ver>/` is empty — that is EXPECTED, not breakage. The custom
WSL kernel (`.wslconfig` → `bzImage-can.new`) compiles CAN/vcan in (`CONFIG_CAN=y`, `CONFIG_CAN_VCAN=y`).
Verify CAN actually works with a socket probe, not `lsmod`/`modprobe`:
`python3 -c "import socket;s=socket.socket(socket.AF_CAN,socket.SOCK_RAW,socket.CAN_RAW);s.bind(('vcan0',));print('CAN OK')"`
or `cansend vcan0 123#DEADBEEF` + `candump vcan0`. If `.wslconfig` points to a stock MS kernel instead,
THEN CAN is genuinely absent — check `zcat /proc/config.gz | grep CONFIG_CAN`.

Note: some patterns were adapted from a private reference project — **never name external/private
projects anywhere in this repo** (re-implement generically).

## Decisions (locked)

- **Language:** V (vlang). Beta — expect compiler/runtime rough edges.
- **GUI:** [vlang/gui](https://github.com/vlang/gui) — immediate-mode, thread-safe state, tables/grids.
  Immature; if it won't build/render, fall back to `vlang/gg` then `vlang/ui`.
  **VALIDATED** for our needs via `cmd/dashboard` (throwaway demo): production-grade `data_grid`
  (sort/filter/page/freeze/group/aggregate/inline-edit/conditional-format/CSV-XLSX-PDF export),
  `draw_canvas` anti-aliased `polyline` (caps/joins) for plots, and smooth live updates at ~25fps.
  Screenshots in `docs/gui_validation/`. Caveat: extreme trace volume (10k+ rows @ 1000 msg/s)
  not yet stress-tested — a `data_source` virtualized grid exists for that; revisit in Phase 3.
- **Virtual CAN:** Linux **vcan0** via **SocketCAN** (C-interop over `<linux/can.h>`), behind a
  transport interface so swapping to real `can0` hardware later is a drop-in. WSL2 kernel has `vcan.ko`.
- **First milestone:** minimal GUI window (prove V + gui + WSLg render), then iterate.

## Risk posture

V is beta + gui is immature → **spike-first, verify after every step**. Build the smallest thing, run
it, confirm, then grow. **Pin the working V + gui versions** once found (record below). Keep CAN/engine
logic **free of GUI imports** so the GUI stays swappable and the engine is independently testable.

## Architecture (target)

```
GUI (vlang/gui)            thin, replaceable — trace view, send panel
App / engine              channels, routing, trace buffer, send scheduler   (no GUI imports)
Database (DBC)            frames <-> named signals                          (later)
Transport interface       open/read/write CAN frames
  +-- SocketCAN backend   vcan0 now, can0 later
  +-- LIN / Ethernet      (future)
vcan0 (kernel)  <--->  Virtual SUT simulator (separate process on vcan0)
```

## Project layout

```
v.mod                       module manifest
src/main.v                  GUI entry point (thin consumer of modules)
modules/candb/              CAN signal db: messages, signals, bit en/decode + DBC parser (+ tests)
modules/sampledb/           hand-coded message catalog (being superseded by DBC loading)
modules/transport/          Bus interface (transport.v) + Linux SocketCAN backend (socketcan_linux.v)
modules/isotp/              ISO-TP: Channel interface (isotp.v) + Linux kernel backend (kernel_linux.v)
modules/uds/                UDS diagnostic client over isotp (pure V, + tests)   (Phase 6)
dbc/cantester.dbc           real DBC describing the SUT's messages    (Phase 5)
cmd/dashboard/              throwaway GUI capability demo
cmd/signal_decode/          frame -> signals visualizer demo
cmd/dbc_decode/             load a DBC + decode one frame (machine-readable; oracle diff)
cmd/isotp_smoke/            send one ISO-TP PDU, print the reply (multi-frame smoke)
cmd/uds_smoke/              drive the UDS client vs sut/uds_server.py
sut/can_sut.py              Python virtual SUT (emits/answers frames on vcan0)
sut/dbc_oracle.py           independent stdlib DBC parser+decoder (cross-validates candb)
sut/uds_server.py           Python virtual UDS server (stdlib ISO-TP) — oracle for modules/uds
sut/mf4_bridge.py           asammdf MF4 -> candump/.asc converter + semantic diff (needs .venv-tools)
scripts/setup_mf4_tools.sh  build .venv-tools (asammdf) + fetch real J1939 MF4/DBC samples
scripts/run.sh              build+run with WSLg software-GL workaround
scripts/setup_vcan.sh       bring up vcan0 (sudo)
docs/gui_validation/        screenshots proving gui capabilities
```

### Module convention
Split reusable, GUI-free logic into its own `modules/<name>/` as soon as it earns independence
(isolated tests, importable by both `cmd/` tools and the GUI). `src/` (GUI) and `cmd/` (CLI) are
thin consumers. Prefer many small focused modules over a monolith.

**Mirror the Python automotive stack's boundaries** — they're a proven decomposition, and since the
SUT is Python, each V module gets a direct counterpart to verify against:
| V module (ours)        | Python counterpart (oracle) | Concern                       |
|------------------------|-----------------------------|-------------------------------|
| `transport`            | python-can                  | bus I/O (SocketCAN/vcan0)     |
| `candb`                | cantools                    | DBC parse + signal en/decode  |
| `isotp`                | can-isotp / stdlib CAN_ISOTP| ISO-TP segmentation           |
| `uds`                  | udsoncan / stdlib server    | UDS diagnostics               |
| `doip`/`someip` (fut.) | scapy automotive            | Ethernet protocols            |

### Platform support (WSL/Linux now, Windows later) — KEEP THE SEAM CLEAN
We develop on **WSL2/Linux** and the bus backends are Linux-specific (SocketCAN raw + kernel
CAN_ISOTP, via `<linux/can.h>`). **Native Windows support is a later goal**, so all OS-specific code
must stay isolated behind a platform-agnostic interface — never let `linux/*` headers or syscalls leak
into shared code. The convention:
- **Agnostic** API + interface lives in the unsuffixed file (e.g. `transport/transport.v` defines
  `Bus`; `isotp/isotp.v` defines `Channel` + `open()` contract). Callers depend ONLY on these.
- **OS-specific** backends live in `*_linux.v` (V gates compilation by the `_linux.v`/`_windows.v`
  suffix), so they never compile into the wrong target. Linux backends today: `transport/
  socketcan_linux.v`, `isotp/kernel_linux.v` (+ their `*_shim.h`).
- **Windows later** = add `*_windows.v` implementing the SAME interface. Note: Windows has no kernel
  ISO-TP, so its `isotp` backend will be a **software** ISO-TP state machine over a vendor CAN driver
  (PCAN/Vector/SocketCAN-over-IP) — which is also useful on Linux for real hardware that lacks kernel
  ISO-TP. `uds`/`candb` are already pure-V and portable. When adding a backend, put platform code ONLY
  in suffixed files and keep the interface untouched.

## Environment (verified 2026-06-03)

- WSL2, kernel 6.6.123. `vcan.ko` present. `can-utils` NOT installed (needs `sudo apt`).
- Graphics: `libGL`/`libX11` present, `DISPLAY=:0` + Wayland (WSLg). `gcc 11.4`.

## Phased roadmap

0. ✅ Toolchain & skeleton — install V + gui, project layout, trivial build.
1. ✅ Minimal GUI window.
2. ✅ SocketCAN transport (vcan0) + CLI smoke test vs candump/cansend.
4. ✅ Virtual SUT (Python) on vcan0 + candb cross-validation.
3. ✅ Wire CAN into GUI — live trace table, signal decode, send panel.  ⟵ done
5. ✅ **DBC database & signals** — `candb` parses real `.dbc` files (BO_/SG_/VAL_/CM_), Intel +
   Motorola bit order, value tables; `dbc/cantester.dbc` matches the SUT; cross-validated vs an
   independent Python oracle. The GUI loads the DBC at startup (sampledb is now just a fallback);
   trace/signals decode from it and show value-table labels live.
6. 🚧 **UDS diagnostics over ISO-TP** — FOUNDATION DONE: `modules/isotp` (kernel CAN_ISOTP socket
   behind a platform-agnostic `Channel`) + `modules/uds` (client: 0x10 session, 0x22 RDBI, 0x3E,
   negative-response/0x78-pending handling). Verified end-to-end vs `sut/uds_server.py` (stdlib).
   Still TODO: a Diagnostics GUI panel, more services (0x19 DTCs, 0x2E write, 0x27 security), and
   DID↔signal mapping via the DBC.
7. 🚧 **Log replay** — real recordings are ASAM **MF4** (CANedge/CSS Electronics), paired with a DBC.
   DONE: `sut/mf4_bridge.py` (asammdf) converts MF4 → candump `.log` and **semantically diffs** two
   recordings (canonical frame stream, not bytes — MF4 is never byte-equal); validated our `candb`
   decode == asammdf on a real J1939 driving log (EngineSpeed/WheelBasedVehicleSpeed, once the J1939
   0xFFFF "not-available" sentinel is filtered). TODO: `modules/canlog` (V candump parse/format) + a
   player (replay onto vcan0 AND direct-to-trace), then a GUI "open log" action. (Native MF4-in-V is a
   later option; the Python bridge is the path for now.)
8+. Scripting/sequences (conventional test cases), more panels/plotting; then LIN + Ethernet
   (DoIP/SOME-IP) backends behind the same `Bus`/`Channel` abstractions (see Platform support).

## Build / run

- `scripts/run.sh [target.v]` — **preferred**: build & run a target (default `src/main.v`) with the
  WSLg software-GL workaround AND the local-module `-path` applied. e.g.
  `scripts/run.sh cmd/signal_decode/decode.v`.
- `v -path "@vlib|@vmodules|modules" run <file>` — raw equivalent (need `-path` for local modules;
  need software-GL env for the GUI under WSLg — see `docs/known_issues.md`).
- `v test modules/<name>/` — run a module's tests.

### Debugging (VS Code)
`.vscode/launch.json` has gdb configs ("Debug GUI (main window)", "Debug demo: …"). They build with
`v -g` (source-level symbols — breakpoints map to `.v` lines) and set the software-GL env so the
window isn't blank. Requires the **C/C++ extension** (`ms-vscode.cpptools`) for the `cppdbg` type.
Verified: a breakpoint at `main__main` resolves to `src/main.v` and stops there.

## References

- V docs: https://docs.vlang.io/introduction.html  ·  vlang/gui: https://github.com/vlang/gui
- **gui maintenance:** the original gui author has left V and is rebuilding the same design in Go at
  https://github.com/go-gui-org/go-gui. So vlang/gui may stagnate (we pinned commit 68b9302); treat
  go-gui as a reference for API *intent*/docs since it mirrors the same concepts. Risk to watch:
  future V versions breaking the pinned gui. The CAN/engine logic is deliberately GUI-free so the GUI
  stays replaceable if needed.
- **GUI fallback options** (if vlang/gui's immaturity keeps costing us). We chose vlang/gui for being
  *native V*, app-like, with real text shaping (vglyph) and a production-grade `data_grid`. If we
  switch, the strongest fallback is **Dear ImGui** via the `cimgui` C bindings (V can wrap C) —
  battle-tested, huge ecosystem, and **ImPlot** is best-in-class for real-time signal plots (very
  relevant once we do heavy plotting). Trade-offs: it's a C++ FFI layer to wrap/build, has a
  "debug-tool" aesthetic, and weaker typography. **Key caveat:** ImGui is *also* GPU-rendered, so it
  would hit the **same WSLg hardware-GL wall** — not an escape from that. Other V options: `vlang/ui`
  (older, native-ish widgets) and raw `vlang/gg` (build your own widgets). Decision stays vlang/gui
  for now; revisit ImGui+ImPlot if gui blocks us or when the plotting phase demands more.
- **`docs/known_issues.md`** — categorized gotchas (V / gui / rendering / env / our code). Check it
  first when something breaks, and add new findings there under the right layer.
- vcan setup (later): `scripts/setup_vcan.sh`; cross-check with `candump vcan0` / `cansend vcan0 ...`.

## Pinned versions (fill in once a working combo is confirmed)

- V: 0.5.1 (built from source to `~/v`, symlinked `~/.local/bin/v`). Original pin 4dbcba6; the
  24.04 box rebuilt at commit **de365a1** — still reports `0.5.1`, builds + tests pass, so the drift
  is cosmetic. Re-pin to de365a1 unless a regression surfaces.
- vlang/gui: commit 68b9302 (2026-05-11), in `~/.vmodules/gui`. Depends on `vglyph`.
- Mesa: **25.2.8** on Ubuntu 24.04.4 (OpenGL 4.5 Compatibility) — hardware GL works under WSLg.
- **CONFIRMED WORKING**: builds clean, window renders under WSLg with **hardware GL** (sokol backend).

## System dependencies (all installed via apt)

`vlang/gui` → `vglyph` + sokol need these dev libs. Full list:
`pkg-config libfreetype-dev libharfbuzz-dev libfribidi-dev libfontconfig1-dev
libpango1.0-dev libglib2.0-dev libdbus-1-dev libatk1.0-dev libatk-bridge2.0-dev
libatspi2.0-dev libgl1-mesa-dev libx11-dev libxcursor-dev libxrandr-dev
libxinerama-dev libasound2-dev` (plus libxi/libxtst pulled in as deps).

Benign at runtime: sokol `LINUX_X11_QUERY_SYSTEM_DPI_FAILED` → falls back to 96 DPI.

**WSLg blank-window gotcha (HISTORICAL — fixed on 24.04):** on Ubuntu 22.04 (Mesa 23.2) the GPU GL
passthrough (d3d12) drew frames but composited a BLANK/black window under WSLg; the workaround was
forcing Mesa software rendering (`LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe`). On **24.04 +
Mesa 25.2.8 hardware GL renders correctly**, so `scripts/run.sh` now defaults to hardware GL; pass
`CANTESTER_SOFTWARE_GL=1` to re-enable the software fallback if a future Mesa regresses.

Passwordless sudo scoped to `apt-get`, `ip`, `modprobe` via `/etc/sudoers.d/cantester`. This is the
one bit of machine state NOT in git, so it does **not** transfer to a fresh box — re-create it once
per machine with `sudo ./scripts/setup_sudoers.sh` (generates the drop-in and `visudo -c`-validates it
before installing, so a typo can't lock you out). Without it, `setup_env.sh`/`setup_vcan.sh` will
prompt for a password.

## Status log

- 2026-06-03: Plan approved. Repo was empty (LICENSE only).
- 2026-06-03: Phase 0 — V 0.5.1 built+installed, trivial program runs. gui module installed.
  Skeleton created (v.mod, src/main.v, README, .gitignore). Minimal window written.
- 2026-06-03: BLOCKED — gui build fails: vglyph needs native deps (freetype/harfbuzz/fribidi/
  fontconfig/pango/glib). Awaiting apt install (needs sudo). User opted for passwordless sudo.
- 2026-06-03: UNBLOCKED — installed full native dep set (text shaping + dbus/atk accessibility
  + GL/X11). `src/main.v` compiles and renders a CANTester window under WSLg.
- 2026-06-03: Diagnosed blank-window-under-WSLg (GL passthrough doesn't composite); fix =
  software GL (`LIBGL_ALWAYS_SOFTWARE=1`), wrapped in `scripts/run.sh`. Verified by screenshot
  + by user. **Phase 1 DONE & VERIFIED.**
- 2026-06-03: Decisions — SUT/reference side will be **Python** (mature automotive stack as an
  independent verification oracle); virtual bus stays **vcan0/SocketCAN** (primary). vcan kernel
  module won't load here: modules built 13:52 predate the running kernel rebuilt 20:34 (Jun 2) →
  MODVERSIONS CRC mismatch (ENOEXEC). User to rebuild+install matching modules to unblock.
- 2026-06-03: **GUI VALIDATED** — built `cmd/dashboard` demo (live signal data_grid + anti-aliased
  line chart, conditional formatting, ~25fps). Confirms vlang/gui is the right choice. Screenshots
  in docs/gui_validation/.
- 2026-06-03: `modules/candb` (signal en/decode + 7 tests) and `cmd/signal_decode` (frame→signals
  bit-layout visualizer, byte-exact). Dev tooling: VS Code tasks + gdb launch.json, docs/known_issues.md.
- 2026-06-03: **vcan0 unblocked** — CAN is built into the kernel (=y), no modprobe/rebuild needed.
- 2026-06-03: **Phase 2 transport DONE & VERIFIED** — `modules/transport` (SocketCAN via tiny C shim
  + `Bus` interface) and `cmd/can_smoke`. Frames verified both ways on vcan0 vs candump/cansend
  (standard + 29-bit extended).
- 2026-06-03: **Python virtual SUT DONE & VERIFIED** — `sut/can_sut.py` (stdlib AF_CAN): emits
  Powertrain 0x100 @10Hz + heartbeat 0x700, answers 0x101→0x102. Cross-check PASSED: V `candb` and an
  independent Python decoder produce identical physical values for the SUT's 0x100 frame.
- 2026-06-03: **Phase 3 DONE & VERIFIED** — `src/main.v` is now the real app: opens vcan0, RX on a
  background thread → live trace data_grid (decoded Message column via `sampledb`/`candb`), a live
  Signals panel for 0x100, and a Send form. Verified live against the SUT (RX streaming; GUI Send of
  0x101 → SUT 0x102 reply confirmed via candump + RX/TX counters). New `modules/sampledb` message
  catalog (decode demo refactored to share it). Screenshot docs/gui_validation/phase3_live_trace.png.
  Threading: RX thread mutates shared state under `sync.Mutex`; a ~20fps UI timer redraws (all gui
  calls stay on the UI thread).
- 2026-06-03: **Expandable grouped trace** — `src/main.v` now has two trace views (toggle): chronological
  "all", and "grouped" (one row per ID, click to expand into indented signal rows: Signal/Value/Raw/
  Interpretation — J1939-trace style). Signals are inserted as real grid rows (gui's built-in detail
  rows are fixed to one row height — see known_issues), toggled via on_selection_change/active_row_id.
  Added `desc` to candb.Signal. Screenshot docs/gui_validation/trace_expand_signals.png.
- 2026-06-03: Trace fills window width (flexible Data column; window-width folded into grid id so
  columns re-flow on resize; raised gui's 600px max_width). Replaced the always-on animation timer
  with event-driven refresh (RX thread → `w.queue_command` → UI thread; no mutex) — also removes
  suspected interference with header drag-resize. Columns are resizable/reorderable (gui default),
  sorting disabled on the live trace.
- 2026-06-03: **Dock layout VALIDATED** (`cmd/dock_demo`) — gui's `dock_layout` does resizable splits,
  tabbed panel groups, a data_grid nested in a panel, working inputs/buttons, and drag-to-redock with
  drop-zone preview + layout persistence. Solid under WSLg. Screenshots docs/gui_validation/dock_*.png.
  → Greenlit to refactor `src/main.v` into a dockable panel layout (Trace/Signals/Send/… panels).
- 2026-06-03: GUI is dockable (Trace/Signals/Send/Statistics panels); fixed gui.input sizing quirk.
  Hardware-GL investigation: GPU works (glmark2) but our sokol app crashes Mesa 23.2's d3d12 core
  profile → **migrating to Ubuntu 24.04 for Mesa 24.x**. Added `scripts/setup_env.sh` (one-shot
  bootstrap) + this handoff section so a fresh session/distro can rebuild everything. Repo is the
  source of truth (memory doesn't transfer). Next after migration: confirm hardware GL, then Phase 5.
- 2026-06-03: **App refactored to dock layout** — `src/main.v` is now a global toolbar over a
  `dock_layout` with panels: Trace (grouped/all grid, inline signal expand), Signals (live 0x100
  decode), Send (form), Statistics (counters). Panels split/tab/drag-redock/close; layout persisted
  in `app.dock_root`. Verified live vs SUT (RX streaming, inline expand, all panels updating).
  Screenshot docs/gui_validation/app_dockable.png. Next: Phase 5 (DBC parsing) / more panels.
- 2026-06-03: **Migration to 24.04 complete & hardware GL WORKS.** Fresh 24.04.4 box, Mesa 25.2.8
  (OpenGL 4.5). User confirmed hardware GL renders under WSLg → flipped `scripts/run.sh` to default
  hardware GL (`CANTESTER_SOFTWARE_GL=1` is now the fallback). V rebuilt at commit de365a1 (still
  0.5.1). **Corrected a CAN false-alarm:** `modprobe vcan` fails + `/lib/modules` empty looked like
  "stock kernel, no CAN", but `.wslconfig` → `bzImage-can.new` compiles CAN in (`=y`); AF_CAN bind +
  cansend/candump loopback on vcan0 PASS. CAN is fully operational. Doc'd the socket-probe-not-lsmod
  rule. Next: Phase 5 (DBC parsing) + big-endian in candb.
- 2026-06-03: **Phase 5 DBC parsing DONE & VERIFIED.** `candb` now: (a) Motorola/big-endian bit order
  in raw_value/set_raw/owns (Intel was the only order before) — anchored by a textbook 0x1234 vector;
  (b) `dbc.v` parser for BO_/SG_/VAL_/CM_ → Database, with value tables (enums) + comments, Signal
  gained minimum/maximum/values/label(). Authored `dbc/cantester.dbc` mirroring the SUT (0x100/0x700/
  0x101/0x102). Cross-validation: V tests prove DBC == hand-coded `sampledb` layout AND decodes a frame
  identically; `cmd/dbc_decode` + `sut/dbc_oracle.py` (independent stdlib DBC impl) agree on 1800 random
  decodes and on a live SUT 0x100 frame. NOT yet wired into the GUI (still uses sampledb) — next step.
  Note: passwordless sudo (/etc/sudoers.d/cantester) did NOT transfer to this box, so cantools couldn't
  be apt/pip-installed; the hand-written Python oracle covers the cross-check instead.
- 2026-06-03: **DBC wired into the GUI.** `src/main.v` loads `dbc/cantester.dbc` at startup into
  `App.db` (env override `CANTESTER_DBC`; falls back to `sampledb.catalog()` if the file is missing);
  trace name lookup, the inline signal-expand, and the Signals panel all decode from the DBC, and now
  render VAL_ value-table labels (e.g. `Gear 1.0 (First)`, `CruiseOn (On)`). Verified live vs SUT with
  hardware GL — screenshot docs/gui_validation/phase5_dbc_decode.png (note the unit reads "degC" from
  the DBC, not sampledb's "°C", proving the swap). Stats panel shows the DB source + message count.
- 2026-06-04: **Phase 6 ISO-TP + UDS foundation DONE & VERIFIED.** Confirmed kernel `CAN_ISOTP=y`
  works on vcan0 (Python loopback, multi-frame). New `modules/isotp`: a platform-agnostic `Channel`
  interface (`isotp.v`) + Linux kernel-socket backend (`kernel_linux.v` + `isotp_shim.h`); kernel does
  SF/FF/CF + flow control (verified via candump: FF `10 14`, FC `30 00 00`, CFs). New `modules/uds`:
  client for 0x10/0x22/0x3E with positive/negative-response + 0x78-pending handling (8 hermetic tests
  via a mock Channel). `sut/uds_server.py` (stdlib ISO-TP) is the oracle. End-to-end PASS (`cmd/
  uds_smoke`): session, multi-frame VIN read, EngineSpeed DID → 1600 rpm, tester-present, and a
  negative response (0x31 requestOutOfRange) surfaced correctly. **Platform seam honoured** per user
  directive: OS-specific code isolated in `*_linux.v` (also renamed `transport/socketcan.v` →
  `socketcan_linux.v`); added a "Platform support" section so Windows can drop in a `*_windows.v`
  software-ISO-TP backend later. Next: Diagnostics GUI panel + more UDS services.
- 2026-06-04: **candb multiplexing modelled** (prep for replaying real OBD2/J1939 logs, which need it).
  Signal gains is_multiplexor/is_multiplexed/multiplexor_value; DBC parses `M` / `m<N>` / `m<N>M`
  (extended) markers; `Message.active_signals(data)` returns only the signals present for the current
  multiplexor value. GUI (trace expand + Signals panel) now iterates active_signals so muxed messages
  render correctly. Tests cover parse + selection. Decision (2026-06-04): real recordings come as
  **MF4** (CANedge/CSS Electronics ecosystem) paired with a DBC; we'll ingest them via a **Python
  `asammdf` bridge** (convert MF4 → candump/.asc) rather than a native V MF4 parser, then replay
  through `modules/canlog` (next) onto vcan0 or direct-to-trace. Real-data sources: comma.ai opendbc,
  CSS Electronics sample data, nberlette/canbus.
- 2026-06-04: **MF4 bridge + real-data validation DONE.** `scripts/setup_mf4_tools.sh` builds
  `.venv-tools` (asammdf) and fetches real CSS Electronics J1939 samples (parked + driving MF4 + demo
  DBC) into `samples/` (git-ignored binaries). `sut/mf4_bridge.py`: `convert` MF4→candump `.log`,
  `frames` (canonical dump), `diff` (SEMANTIC diff — compares the (id,ext,data) stream + timestamps
  within tolerance, since two MF4s of identical traffic are never byte-equal: start-time/history/
  offsets/zlib-DZ all vary). Extracted 145k–150k real frames; **candb decode == asammdf** on the real
  driving log (EngineSpeed 913–1761 rpm ×19584, WheelBasedVehicleSpeed 19–88 km/h ×1958) after
  filtering the J1939 `0xFFFF` "not-available" sentinel — asammdf drops those (valid count matched
  exactly). This enables the round-trip test: SUT replays MF4 → we record MF4 → `mf4_bridge diff` ==
  empty. **Found a candb TODO:** flag J1939 not-available (all-0xFF) signal values. Next: `modules/
  canlog` + player + GUI "open log".
