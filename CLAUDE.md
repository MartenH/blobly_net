# CANTester (V) — project guide for Claude

An automotive bus tester written in **V (vlang)**. Long-term goal: test a SUT (System
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
v.mod                  module manifest
src/main.v             entry point
src/gui/               GUI code            (later)
src/transport/         SocketCAN + iface   (later)
src/sut/               virtual SUT sim     (later)
scripts/setup_vcan.sh  brings up vcan0 (sudo) (later)
```

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

- `scripts/run.sh` — **preferred**: build & run with WSLg software-GL workaround applied.
- `v run src/main.v` — raw build & run (blank window under WSLg — see gotcha below).
- `v version` — toolchain check.
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
