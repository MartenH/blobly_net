# CANTester (V) — project guide for Claude

A CANoe-like automotive bus tester written in **V (vlang)**. Long-term goal: test a SUT (System
Under Test) over **CAN / Ethernet / LIN** and the protocols on them. **Starting with CAN only**, and
**virtual first** (no real hardware yet). Build incrementally: get the GUI up first, then add features.

## 🆕 Fresh setup / new session — START HERE

This repo is the **single source of truth** — a new Claude session on a new machine has NO prior
memory (the old `~/.claude` memory does not transfer); everything needed is in git: this file +
`docs/known_issues.md` + the scripts.

Bootstrap a fresh box in one shot:
```sh
./scripts/setup_env.sh          # installs V + gui native deps + can-utils, builds, brings up vcan0, runs tests
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
modules/transport/          SocketCAN backend + Bus interface         (Phase 2)
dbc/cantester.dbc           real DBC describing the SUT's messages    (Phase 5)
cmd/dashboard/              throwaway GUI capability demo
cmd/signal_decode/          frame -> signals visualizer demo
cmd/dbc_decode/             load a DBC + decode one frame (machine-readable; oracle diff)
sut/can_sut.py              Python virtual SUT (emits/answers frames on vcan0)
sut/dbc_oracle.py           independent stdlib DBC parser+decoder (cross-validates candb)
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
| `isotp`   (future)     | can-isotp                   | ISO-TP segmentation           |
| `uds`     (future)     | udsoncan                    | UDS diagnostics               |
| `doip`/`someip` (fut.) | scapy automotive            | Ethernet protocols            |

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
6+. UDS diagnostics (ISO-TP is built into the kernel), scripting/sequences, panels;
   then LIN + Ethernet (DoIP/SOME-IP) backends behind the same `Bus` abstraction.

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

Passwordless sudo scoped to `apt-get`, `modprobe`, `ip` via `/etc/sudoers.d/cantester`.

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
