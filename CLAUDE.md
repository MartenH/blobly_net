# CANTester (V) — project guide for Claude

A CANoe-like automotive bus tester written in **V (vlang)**. Long-term goal: test a SUT (System
Under Test) over **CAN / Ethernet / LIN** and the protocols on them. **Starting with CAN only**, and
**virtual first** (no real hardware yet). Build incrementally: get the GUI up first, then add features.

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
modules/candb/              CAN signal db: messages, signals, bit encode/decode (+ tests)
modules/transport/          SocketCAN backend + Bus interface         (Phase 2)
cmd/dashboard/              throwaway GUI capability demo
cmd/signal_decode/          frame -> signals visualizer demo
sut/                        Python virtual SUT / reference oracle      (Phase 2+)
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

0. Toolchain & skeleton — install V + gui, project layout, trivial build.
1. **Minimal GUI window** ⟵ current milestone.
2. SocketCAN transport (vcan0) + CLI smoke test vs candump/cansend.
3. Wire CAN into GUI — live trace table + send panel.
4. Virtual SUT simulator on vcan0.
5. DBC database & signals.
6+. UDS diagnostics, scripting/sequences, panels; then LIN + Ethernet backends.

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
- **`docs/known_issues.md`** — categorized gotchas (V / gui / rendering / env / our code). Check it
  first when something breaks, and add new findings there under the right layer.
- vcan setup (later): `scripts/setup_vcan.sh`; cross-check with `candump vcan0` / `cansend vcan0 ...`.

## Pinned versions (fill in once a working combo is confirmed)

- V: 0.5.1 (commit 4dbcba6), built from source to `~/v`, symlinked `~/.local/bin/v`.
- vlang/gui: commit 68b9302 (2026-05-11), in `~/.vmodules/gui`. Depends on `vglyph`.
- **CONFIRMED WORKING**: builds clean, window renders under WSLg (X11/sokol backend).

## System dependencies (all installed via apt)

`vlang/gui` → `vglyph` + sokol need these dev libs. Full list:
`pkg-config libfreetype-dev libharfbuzz-dev libfribidi-dev libfontconfig1-dev
libpango1.0-dev libglib2.0-dev libdbus-1-dev libatk1.0-dev libatk-bridge2.0-dev
libatspi2.0-dev libgl1-mesa-dev libx11-dev libxcursor-dev libxrandr-dev
libxinerama-dev libasound2-dev` (plus libxi/libxtst pulled in as deps).

Benign at runtime: sokol `LINUX_X11_QUERY_SYSTEM_DPI_FAILED` → falls back to 96 DPI.

**WSLg blank-window gotcha (IMPORTANT):** default GPU GL passthrough (d3d12) draws frames
but composites a BLANK/black window under WSLg. Fix = force Mesa software rendering:
`LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe`. Always launch via `scripts/run.sh`,
which sets this. Confirmed via screenshots: hardware GL = black, software GL = full UI.

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
  in docs/gui_validation/. Next: Phase 2 transport code + Python SUT (no-regret, while kernel fixed).
