# Blobly Net — historical status log

> **Archive. Not maintained, not authoritative.** This is the dated development log that used
> to live in `CLAUDE.md`, moved out on 2026-07-22 so the agent guide could be short enough to
> stay true. Entries are point-in-time notes: many describe tools, files and decisions that have
> since changed (most visibly the GUI, which moved from `vlang/gui` + `src/main.v` to Dear ImGui
> + `cmd/blobly_net` on 2026-07-06). Read it as history, never as current state.
>
> For what is true **now**, see [CLAUDE.md](../CLAUDE.md). For what changed and when, `git log`
> is the real record.

## Status log

> **Keep this current in the PR that lands the work.** This file is the only memory a new
> agent session has, so an out-of-date log is worse than none — the next session trusts it.
> On 2026-07-22 a ~2.5-week gap (#19–#54) had to be reconstructed from `git log`; don't
> repeat that. Entries are appended **oldest-first** (newest at the bottom).

- 2026-06-03: Plan approved. Repo was empty (LICENSE only).
- 2026-06-03: Phase 0 — V 0.5.1 built+installed, trivial program runs. gui module installed.
  Skeleton created (v.mod, src/main.v, README, .gitignore). Minimal window written.
- 2026-06-03: BLOCKED — gui build fails: vglyph needs native deps (freetype/harfbuzz/fribidi/
  fontconfig/pango/glib). Awaiting apt install (needs sudo). User opted for passwordless sudo.
- 2026-06-03: UNBLOCKED — installed full native dep set (text shaping + dbus/atk accessibility
  + GL/X11). `src/main.v` compiles and renders a Blobly Net window under WSLg.
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
  hardware GL (`BLOBLY_SOFTWARE_GL=1` is now the fallback). V rebuilt at commit de365a1 (still
  0.5.1). **Corrected a CAN false-alarm:** `modprobe vcan` fails + `/lib/modules` empty looked like
  "stock kernel, no CAN", but `.wslconfig` → `bzImage-can.new` compiles CAN in (`=y`); AF_CAN bind +
  cansend/candump loopback on vcan0 PASS. CAN is fully operational. Doc'd the socket-probe-not-lsmod
  rule. Next: Phase 5 (DBC parsing) + big-endian in candb.
- 2026-06-03: **Phase 5 DBC parsing DONE & VERIFIED.** `candb` now: (a) Motorola/big-endian bit order
  in raw_value/set_raw/owns (Intel was the only order before) — anchored by a textbook 0x1234 vector;
  (b) `dbc.v` parser for BO_/SG_/VAL_/CM_ → Database, with value tables (enums) + comments, Signal
  gained minimum/maximum/values/label(). Authored `dbc/blobly_net.dbc` mirroring the SUT (0x100/0x700/
  0x101/0x102). Cross-validation: V tests prove DBC == hand-coded `sampledb` layout AND decodes a frame
  identically; `cmd/dbc_decode` + `sut/dbc_oracle.py` (independent stdlib DBC impl) agree on 1800 random
  decodes and on a live SUT 0x100 frame. NOT yet wired into the GUI (still uses sampledb) — next step.
  Note: passwordless sudo (/etc/sudoers.d/blobly_net) did NOT transfer to this box, so cantools couldn't
  be apt/pip-installed; the hand-written Python oracle covers the cross-check instead.
- 2026-06-03: **DBC wired into the GUI.** `src/main.v` loads `dbc/blobly_net.dbc` at startup into
  `App.db` (env override `BLOBLY_DBC`; falls back to `sampledb.catalog()` if the file is missing);
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
- 2026-06-04: **`modules/canlog` + GUI "Open Log" DONE & VERIFIED.** New pure-V `modules/canlog`
  (`parse_line`/`parse`/`load_file`/`format_line`) reads the candump `.log` line format
  `(<ts>) <iface> <id>#<hexdata>` (standard vs extended by id hex width, empty payload, `#R` RTR,
  skips blanks/`#`-comments) into `[]LogEntry{t_s, iface, transport.CanFrame}`; 10 hermetic tests
  incl. round-trip. GUI: toolbar gains a log-path input + **📂 Open Log** button; `load_log()` pauses
  live RX, resets the trace, and replays the file *direct-to-trace* (`App.push` refactored to
  `record(dir, frame, t_ms)` so log frames keep their recorded time, normalised to the first frame).
  It decodes through the DBC exactly like live traffic — verified on a real 60-frame candump capture
  from `sut/can_sut.py` (30×0x100 + 30×0x700; EngineSpeed/VehicleSpeed/CoolantTemp/Gear all decode).
  Shipped `samples/demo.log` (un-ignored via `samples/*` + `!samples/demo.log`) so the action works
  out of the box; `BLOBLY_LOG` env pre-fills the path. **gui's `native_open_dialog` is wired too**;
  its Linux backend shells out to `zenity`/`kdialog`, so we `apt install zenity` (4.0.1, now a runtime
  dep + in `setup_env.sh`) to make the real picker appear — verified it opens under WSLg. If the picker
  is ever unavailable (`.error`) the app falls back to the typed log-path box. Builds clean,
  `v test modules/canlog/` green. TODO: timed player (replay onto vcan0 at recorded cadence) +
  MF4-aware open via the bridge.
- 2026-06-04: **MF4-aware "Open Log" DONE & VERIFIED (non-J1939 first).** The GUI now opens `.mf4`
  too: `load_log` detects a `.mf4` path and shells out to `sut/mf4_bridge.py convert` (`os.execute`,
  prefers `.venv-tools/bin/python`) to bridge MF4 → a temp candump `.log`, then replays it
  direct-to-trace exactly like a `.log`; the toolbar picker filter now lists `log` + `mf4`. Deliberately
  **did NOT start with J1939**: the only MF4 samples we had (CSS Electronics `parked/driving.mf4`) are
  J1939, whose DBC message IDs embed priority+PGN+source-addr, so `candb.lookup` (exact id) matches **0**
  of 150k frames (PGN-ignoring-SA match would catch ~8k) — that needs J1939 PGN-aware lookup, deferred.
  Instead we made a sample we control: added **`tomf4`** to `mf4_bridge.py` (candump `.log` → MF4 via
  **python-can** `MF4Writer`; `python-can` 4.6.1 added to `.venv-tools` + `setup_mf4_tools.sh`) and
  minted `samples/demo.mf4` from `samples/demo.log`. Verified: `tomf4`→`convert` round-trips the frame
  stream **identically**, and all 60 frames decode against `blobly_net.dbc` (EngineSpeed 1913 rpm, etc.).
  Shipped `samples/demo.mf4` (un-ignored). Builds clean. NEXT MF4 step (when wanted): J1939 PGN-aware
  lookup in `candb` so the real CSS J1939 recordings decode; then a timed player onto vcan0.
- 2026-06-05: **Phase 9 foundation — project config + Buses panel + Start/Stop + File menu (slice 1).**
  New GUI-free `modules/project` (vlib `yaml`) parses a project `.yml` → `Project{channels[]}` (each
  with interface/bitrate/timing/mode/listen_only/enabled/databases/replay; defaults + built-in
  fallback; 6 tests). Ships `projects/demo.blobnet` (CAN1 vcan0 monitor + disabled CAN2 vcan1 replay). The
  app is now **config-driven**: it loads the project at startup (env `BLOBLY_PROJECT`) instead of
  hardcoding vcan0, and DBCs come from the channels (not the old `BLOBLY_DBC`). A global **Start/
  Stop** (top-left, measurement lifecycle) opens/closes enabled *monitor* channels per
  channel (each its own RX thread, closes itself on stop); `do_send` TXes on the first running channel.
  New **Buses** panel (narrow left): per-channel enable checkbox + state-colour dot (green running /
  amber enabled-stopped / grey disabled / red errored). New gui **menubar** — **File**: New / Open
  Project… / Save (stub) / Open Recording… / Open Recent (stub) / Exit (`sapp.quit`). Trace got a
  compact font + small headers. **Verified by screenshotting the running app** (`import -window` +
  `xdotool`; see known_issues). **Found a gui bug:** centered text doesn't render, so `gui.button`
  labels come out blank — rebuilt the Send control as a clickable left-aligned `gui.row` (doc'd in
  known_issues). TODO (Phase 8): wire `mode: replay` into a real `modules/player`; persist Open Recent;
  Save Project; multi-bus trace column.
- 2026-06-05: **Trace UX + render-perf pass.** (a) **Signals panel follows the trace selection** (any
  ID via a new `App.sel_id`, set on row-click in both views) instead of the hardcoded 0x100 demo; (b)
  **multi-expand** — the grouped trace's single `expand_id` became an `expanded map[u32]bool` set, so
  expanding one ID no longer collapses another. (c) **Render perf:** profiling the running app (measure
  *instantaneous* CPU via `/proc/<pid>/stat` deltas, NOT `ps %cpu` — a lifetime average that ramps) the
  app hit ~147% with the SUT feeding ~40 frames/s. Root cause is **not our code** (`-cc gcc -cflags -O2`
  was just as heavy) — it's the **GL frame submission under WSLg's translation** (~100ms/frame), and
  `w.queue_command` **forces a full GL frame per call**, so one wake per CAN frame = bus-rate repaints.
  Fix: `rx_loop` **batches frames and repaints at a bounded rate** (`App.fps`, a toolbar **3/5/10 fps
  dropdown**, default 5 ≈ ~45% of one core ≈ ~3% in Win11 Task-Manager ÷16). CPU scales with repaint
  rate, ~independent of traffic; the data_grid is ~1/3 of a frame's cost, the rest is the GL floor +
  recomposing every panel (gui immediate-mode, no subtree memoization). Also fixed the trace ring buffer
  (`delete(0)` shifted ~1000 elems/frame, O(n)) → amortised bulk trim (overrun 25%, slice back). Note:
  the 1000-frame cap bounds only the **display** buffer — a future **record** sink (write-side of Open
  Log) would tap the full RX stream, uncapped. All measured by screenshotting/flooding (`cangen`) the
  running app. Next: Windows port planning (see Platform support).
- 2026-06-05: **Windows port kickoff — virtual-first.** Decided (with user): Windows target is
  **virtual-first** (no real CAN HW yet), toolchain **mingw-w64/gcc via MSYS2** (not MSVC), and the
  Windows dev session will be a **separate clone on native NTFS** synced via the GitHub remote, using a
  **dedicated isolated MSYS2 root** (don't pollute the user's personal one). Added a "Windows build
  (W1)" handoff section above. Built **W2: `transport/udpbus.v`** — a cross-platform localhost
  **UDP-multicast** software bus implementing the same `Bus` interface (the `vcan0` stand-in for
  Windows): every participant joins the group and sees every frame; per-instance `src` id filters our
  own multicast echoes (loopback must be ON for same-host peers). Pure V (vlib `net`, which exposes
  `join_multicast_group`/`set_multicast_loop`), so it runs on Windows unchanged; verified on Linux (2
  hermetic tests: cross-instance delivery + self-filter, incl. extended/RTR). TODO to make it usable:
  (a) wire it behind the project `interface:` (e.g. `udp:group:port` selects udpbus vs SocketCAN);
  (b) give `sut/can_sut.py` a matching UDP mode so the virtual SUT runs driver-free on Windows.
- 2026-06-05: **W2 integration DONE — virtual-first works over the software bus, end to end.** Added a
  platform-gated dispatcher `transport.open(iface) !Bus` (`open_linux.v`: `udp[:group[:port]]`→udpbus
  else SocketCAN; `open_windows.v`: udp only, errors on `vcan`) so `open_socketcan` stays referenced
  ONLY in `_linux` (seam intact). The GUI now stores the backend as `?transport.Bus` (was a concrete
  `&SocketCanBus`) and calls `transport.open(ch.iface)` — so a channel's `interface:` selects the
  backend; nothing in `src/main.v` names a Linux type anymore. `sut/can_sut.py` gained a **UDP mode**
  (`SocketCanBus`/`UdpBus` behind one send/recv contract; `udp[:group[:port]]`) matching udpbus's wire
  format. Shipped `projects/demo-udp.blobnet`. **Verified on Linux:** `python3 sut/can_sut.py udp` +
  a V `transport.open('udp')` client interoperate — 0x100/0x700 received and decoded (EngineSpeed
  etc.). This same flow runs on Windows with zero drivers once the GUI builds (W1). Run:
  `python3 sut/can_sut.py udp` + `BLOBLY_PROJECT=projects/demo-udp.blobnet ./scripts/run.sh`.
- 2026-06-05: **W1 DONE — GUI builds + RENDERS natively on Windows, virtual-first verified.** Stood up
  the whole toolchain isolated under `C:\dev` (dedicated `msys64-ct` MSYS2 + mingw-w64 gcc 16/pkgconf/
  pango/glib/freetype/harfbuzz/fribidi/fontconfig; V 0.5.1 @ de365a1 via `makev.bat`+tcc; gui@68b9302 +
  vglyph in `vmodules-ct` via `VMODULES`). **First-ever native-Windows run of vlang/gui** surfaced and
  fixed real upstream bugs: gui's Win32 C bridge (`readback_windows.c` missing `COBJMACROS`,
  `dialog_windows.c` missing `<wchar.h>`/`<stdio.h>` — gcc 16 implicit-decl errors); `titlebar_dark()`
  calling `sapp.win32_get_hwnd()` before `sapp.run()` → `_sapp.valid` abort (guarded with
  `sapp.isvalid()`); vglyph panicking on whitespace glyphs (`outline.n_points==0`). **Key finding:**
  gui's shaders are **GLSL-only**, so it requires sokol's **GL backend** — the W1 "D3D11" premise was
  wrong; D3D11 needs a gui HLSL shader port (deferred, and unneeded: native GL idle ≈**0.3% CPU** on a
  16-core box, the WSLg translation tax gone). While chasing D3D11 I also found V's sokol glue never
  wires D3D11 at all (`glue_environment`/`glue_swapchain` only do metal/gl) — a genuine upstream V bug,
  captured (reverted) in the manifest. Also: **V's `v.pkgconfig` doesn't relocate a `.pc` `prefix=`** →
  feed system `pkgconf`'s flags via `-cflags`/`-ldflags`. **Smart App Control** (enforced) hard-blocks
  unsigned local exes — user turned it Off (irreversible). **Verified by screenshot** (full dock layout,
  trace/Buses/Signals/Send panels, crisp pango text) and the virtual-first UDP flow end-to-end (V
  `transport.open('udp:…')` client received the SUT's 0x100/0x700 over the software bus, driver-free).
  All vendored patches are upstream-style (no project tags) for contributing back to V/gui/vglyph. Full
  recipe + patch manifest: **`docs/windows_build.md`**; gotchas in `docs/known_issues.md`. Build:
  `scripts\build_win.ps1`. NEXT: optionally press ▶ Start in the live GUI to watch frames; later, gui
  HLSL shaders → D3D11 (+ the V glue fix); real CAN HW; the rest of the roadmap.
- 2026-06-06: **Dense theme + Directory-Opus colour theme + per-byte trace highlight.** Centralised all
  look&feel into one block in `src/main.v`: `ui_size_*` (type scale, one knob for font/size — see how
  `font_variants()` flows a single `text_style.family` to every derived style), `trace_row/header_height`
  (dense grid), and a `Palette` struct fed to `make_theme()` (`make_theme` replaced `compact_theme`).
  Two palettes: **opus-light** (default) matched to the user's real DOpus *Windows Colors* — white
  255/255/255 lists, 204 frames, 109 listview gridlines (data-grid carries its own `color_border`),
  `#0078d4` selection (pale via blending). Finding: DOpus `.dlt` themes are **ZIP+`theme.xml`** and
  `.oxc` configs are XML — the sage tint people see is the *Windows* chrome (syscols), not an Opus value.
  Trace: signal/message text now black (was green); grouped view splits the payload into 8 byte cells
  with a **conventional yellow change-highlight that fades** over `byte_fade_steps` (per-ID `byte_age` in
  `MsgAgg`). Dev helpers: `scripts/shot.sh` + `BLOBLY_AUTOSTART=1` for the screenshot loop.
- 2026-06-07: **Native-V MF4 reader (`modules/mf4`) + MF4 replay in the GUI, no Python.** Reverse-
  engineered ASAM MDF4 v4.20 (DZ-compressed) by raw-parsing the binary, then ported to pure V:
  IDBLOCK/HD/DG/CG/CN walk, **DZ inflate (`compress.zlib`) + zip_type-1 byte de-transposition**, DL/HL
  data lists, struct **composition** recursion (the `CAN_DataFrame.*` sub-channels live under a parent
  CN, not the flat chain), and three DataBytes layouts: **MLSD** (inline, classic CAN), **VLSD**
  (separate length-prefixed block, **CAN-FD**), and fixed inline arrays (python-can). Master time =
  int-ns × linear CCBLOCK (or float secs); master found by `cn_type==2`, not name (Vector `t` /
  python-can `time`). `load_log` now parses `.mf4` natively → `[]canlog.LogEntry` (dropped the
  `mf4_to_log` Python shell-out). **Validated frame-for-frame vs asammdf** on a real **62 324-frame
  J1939+CAN-FD** log (id+data identical, ts sub-µs) — and it reads the **VLSD CAN-FD groups asammdf
  cannot** ("Wrong signal data block reference"). `cmd/mf4_dump` = oracle-diff CLI; `modules/mf4` tests
  vs `samples/demo.mf4`. The real `Logging*.mf4` files are the user's **private data — NOT committed**
  (used locally for validation only). Verified in the GUI: opened the J1939 file → 62 324 frames stream
  the trace with per-byte highlights, CAN-FD payloads (DLC 16/20/32/48) intact. NEXT: timed replay
  *player* (Phase 8) onto vcan0/udpbus at recorded cadence; J1939 PGN-aware `candb` lookup for decode.
- 2026-06-07: **Memory-leak hunt + Trace filter + Graphics panel.** (a) **Leak — final answer:** the
  steady RSS growth while live values are on screen is **Linux-only** (VERIFIED clear on native Windows
  W1 — both changing/static plateau) and lives in **vglyph's glyph RENDER path**, NOT Pango layout and
  NOT the GL driver. Trail (full detail in `docs/known_issues.md`): GC is on + V heap bounded (~50 MB);
  a heaptrack-at-`exit(0)` reading first mis-blamed Mesa/gallium (that was GL working-set freed only on
  clean teardown — retracted); direct RSS + minimal repros then nailed it — raw Pango
  (`new`/`set_text`/`font_desc`/`metrics`/`iter`, changing text) is FLAT at 14 MB/250k iters, vglyph's
  `Context.layout_text` (±wrapping) is FLAT at ~19 MB/200k+, a rects-only `gg` app is FLAT — only the
  path that also **renders** (the GUI) leaks, and only for *changing* (cache-miss) strings. So it's
  glyph/atlas churn under Linux FreeType, per new string. `cmd/mem_leak_repro` reproduces it
  (`MEM_REPRO=changing` climbs, `static` plateaus). Production (native Windows) is unaffected;
  mitigations: lower trace fps, Pause/Stop. Exact retained alloc needs renderer-with-GL isolation
  (follow-up). (b) **Trace filter:** a Filter row above the grid (both views) — case-insensitive
  substring on ID/name/Ch/(all-view)data, with a ✕ clear; verified `CAN2` → only CAN2 msgs. (c)
  **Graphics panel** (tabbed with Signals): plots the trace-selected message's signals over the recorded
  history as auto-scaled coloured polylines + a value legend (`gui.draw_canvas`/`dc.polyline`,
  re-tessellates on new frames). Verified live: 0x100 sines, 0x301 BrakePressure sawtooth + BrakePedal
  sine. NEXT (deferred): renderer-leak exact line; plot real-time x-axis / per-signal toggle.
- 2026-06-10: **Phase 8 replay player DONE & VERIFIED (core).** New GUI-free `modules/player`:
  replays a `[]canlog.LogEntry` recording at recorded cadence × speed with play/pause/stop/seek/
  loop; the caller supplies the playback clock via `due(now_ms)` (sim.Engine pattern) so the module
  is hermetic — 13 simulated-clock tests (cadence, tick granularity, speed, pause/resume, loop
  period = duration, zero-duration guard, seek both ways, fp-epsilon boundaries). GUI:
  `start_measurement` now matches on channel mode; `mode: replay` opens the bus and spawns
  `replay_loop` (recording loaded in-thread via the new shared `load_entries()` — also re-used by
  Open Log; frames sent at cadence and recorded as TX rows with rx_loop's batched-repaint scheme;
  live "replay N% / loop N" note in the Buses panel; "replay finished" + channel auto-stop).
  Shipped `projects/replay-demo.blobnet` (loops samples/demo.log on `inproc:` — zero drivers).
  **Verified in the GUI**: 1 channel attached, green dot, trace streaming TX 0x100/0x700 decoded
  via the DBC, and the TX counter advanced 124 frames in 6 s ≈ the recording's exact 20 frames/s.
  Gotcha re-learned: `v ... | head` makes `$?` head's rc — the build had silently not rewritten
  build/blobly_net (stale Jun-8 binary, "0 channels attached") until rebuilt + timestamp-checked.
  NEXT (Phase 8 rest): per-channel transport-control UI (play/pause/seek/speed — player API ready);
  replay direct-to-trace sink (no bus) for offline review at cadence.
- 2026-06-10: **Graphics strip-chart window + own panel; Trace (filter) is now an opt-in watch list.**
  (a) The Graphics plot scrolls like a strip chart: a **fixed time window** ([latest − win, latest],
  toolbar-style `select` 5/10/30/60 s, `App.plot_win`) slides as frames arrive — old samples drop off
  the left edge instead of compressing the x-scale; short captures fill from the right.
  `plot_max_points` raised to 2000 (60 s @ 20 Hz). (b) Graphics moved out of the Signals tab group
  into its **own panel below Signals** (right column: Signals / Graphics / Send / Stats) — visible by
  default. (c) **Trace (filter) starts EMPTY**: rows appear only for IDs in the new `App.watch` set
  or a NON-empty typed filter (`trace_pass` predicate). A **＋ <id>** button (shown when a Trace
  message is selected) adds it; each watched ID renders as a **chip with ✕** to remove (id_focus
  500+). All click-driven — no typing needed (xdotool-friendly too). VERIFIED live on sim-demo:
  10 s window slid 25.8–35.8s → 60.2–70.2s with constant span; ＋ 0x100 → only Powertrain in the
  filtered view (chip shown), ✕ → empty again. Note: trace clicks toggle expand AND select — fixed
  screen coords hit the inserted signal sub-rows on later clicks (debug eprintln confirmed; not a bug).
- 2026-06-10: **Graphics panel: real timeline + per-signal legend checkboxes.** The plot's x-axis is
  now a true **timeline**: samples are positioned by recorded time (`TraceRow.t_ms`, shared per-PDU
  sample clock), not sample index — uneven frame spacing shows as uneven spacing — with 4 vertical
  grid divisions in the canvas and **time labels** (start/quarters/end, seconds) in a width-matched
  row below it (gui's `DrawContext` has no text API, so labels live outside the canvas; empty
  `fill` rows act as spacers). The legend is now **per-signal checkboxes** (`App.plot_off`, key
  `'<id>:<signal>'`, default all-on; id_focus 400+) — untick a signal to drop its polyline; colours
  stay stable per signal index. Panel got `id_scroll` (7300) + a shorter canvas (0.15×h, cap 240)
  so timeline+legend fit; longer PDUs scroll. VERIFIED live on the replay demo: timeline reads
  0.4s→39.0s across the gridlines, and unticking EngineSpeed removes exactly the blue polyline
  (crop-zoom screenshot). Debug tip re-learned: `pkill -f <name>` from a Bash tool call kills its
  own wrapping shell (the command line contains the pattern) — kill by `ps`+pid instead.
- 2026-06-10: **Second trace panel "Trace (filter)" + bigger default window.** `trace_panel` refactored
  into `trace_view(which)` (0 = main, 1 = filtered): the new dockable **Trace (filter)** panel renders
  the SAME trace buffer through its **own independent filter** (`App.trace_filter2`) and selection
  (`selection2`) — conventional "keep the full trace and a filtered slice open side by side". Shared:
  trace data, grouped/all view mode (toolbar), expand state, Signals-panel follow (clicking either
  trace drives it). Per-panel: filter string + ✕, grid ids (`ftrace_*`), focus ids (32/33), distinct
  placeholder. Default layout now stacks **Trace over Trace (filter)** in the middle column (drag to
  re-tab if preferred); default window upped 1180×680 → **1500×920** so all panels fit. VERIFIED by
  screenshot: bottom filtered to `700` → only Heartbeat; top unfiltered → both messages. Gotcha doc'd
  in known_issues: `xdotool` synthetic typing/middle-paste never reaches gui.input under WSLg (clicks
  work) — verify input-dependent behaviour by temporarily seeding the App field default in a throwaway
  build.
- 2026-06-10: **J1939 PGN decode + native CANedge (unfinalized/unsorted) MF4 + Diagnostics panel.**
  (a) `candb.j1939_pgn()` (PDU1 drops the destination byte; priority/SA never count) +
  `Database.lookup_frame(id, ext)` — exact id first, PGN fallback for 29-bit frames; all GUI decode
  paths use it. (b) `modules/mf4` now reads the files CANedge loggers actually produce: `UnFinMF `
  magic, stale cycle counts (derived from data length), last-DT clamp/extend, **unsorted DG demux**
  (record-id-prefixed interleaved CGs) incl. **VLSD channel GROUPS** (CANedge's DataBytes: cn_data
  names the VLSD CG; offsets index its concatenated length-prefixed records), `cn_bit_offset`
  honoured (CANedge bit-packs), separate IDE channel. **Validated vs the 2026-06-04 asammdf ground
  truth** on the real CSS J1939 driving log: 145 534 frames, EngineSpeed 913–1762 rpm ×19 584 via
  PGN match (exact id = 0); guarded regression test skips when the git-ignored sample is absent
  (fetch: scripts/setup_mf4_tools.sh). (c) **Diagnostics GUI panel** (Phase 6): own dock group;
  buttons run uds.Client over software ISO-TP from a worker thread; channels with simulated nodes
  also spawn the native uds.Server (`diag_server_loop`, rx 0x7E0/tx 0x7E8) — multi-frame VIN read
  verified in the GUI on sim-demo, ISO-TP frames visible in the Trace. Gotcha: gui.button labels
  need min/max_width + h_align .left or they render blank (the known centered-text bug) — that, not
  dock tabs, was why the first attempt showed an "empty" panel.
- 2026-06-13: **MEMORY LEAK ROOT-CAUSED & FIXED — it was a V *closure* leak.** The long-running RSS
  growth (data_grid / live trace) is **not** vglyph or conservative-GC false-retention (earlier
  guesses, all retracted in `docs/known_issues.md`). Root cause: **V never reclaims a capturing
  closure's context** (`memdup_uncollectable`, freed only for temporary closures), so vlang/gui —
  which rebuilds capturing event-handler closures every frame — leaked them unboundedly. 20-line
  repro: `docs/v_patches/closure_leak_repro.v`. **FIX = frame-epoch closure reclamation**: collectable
  contexts + a GC-scanned table in V + `begin_frame_build`/`end_frame_build`/`reclaim_frames` API,
  called once per frame in gui's `window_update.v`. Validated: live GUI 180 s went from unbounded
  (live → 364 MB) to **bounded (46–126 MB, RSS plateaus ~401 MB)**; real app on sim-demo plateaus
  ~318 MB. **⚠️ The fix lives in LOCAL patches to `~/v` and `~/.vmodules/gui`, NOT in this repo's
  build** — captured in `docs/v_patches/*.patch`. **Do NOT `v up` / re-pin V or update gui without
  re-applying them** (recipe: `docs/v_patches/README.md`); on a fresh box they must be re-applied to
  get the leak-free build. Also fixed: `WindowCfg.sample_count` (gui MSAA — `src/main.v` needs it to
  build) + two autofree/`-gc boehm_leak` codegen bugs. GitHub-ready upstream issue/PR drafts (V + gui)
  in `docs/v_patches/UPSTREAM_*.md` — **NOT yet filed** (user will file manually). Full story +
  the two failed fix attempts: `docs/known_issues.md` (Rendering stack, "ROOT CAUSE / ✅ FIXED").
- 2026-06-14: **Custom/triggerable message sending — Tier 1 (Interactive Generators) DONE & VERIFIED.**
  Discussed how to give professional "key on" / interactive sends WITHOUT shipping a compiler; agreed a
  tiered roadmap (Tier 1 declarative interactive generators → Tier 2 reactive sim nodes [already built]
  → Tier 3 declarative sequences → Tier 4 embedded **Lua 5.4** vendored+compiled-in, only if truly
  needed; CAPL is itself a bytecode VM, so Lua is the right fit, not a native compiler). Implemented
  Tier 1: a declarative **`senders:`** block per channel in `modules/project` (new `Sender` +
  `SenderSig` structs; `parse_sender`/`parse_hex_bytes`; serialized in `save.v` so they round-trip;
  tests in project_test.v + save_test.v). Each sender = name + optional single-char **key** +
  frame def (`message:` DBC-name → id/dlc with `signals:` encoded onto it, OR explicit `id:`/`data:`)
  + **trigger** (manual | key | cyclic + `cycle_ms`). GUI (`src/main.v`): `SenderRT` flattened in
  `App.senders` (built in `build_sim_nodes`); `build_sender_frame` (DBC-encode), `fire_sender`
  (UI-thread TX via `app.push`), `handle_hotkey` wired to the new gui **`WindowCfg.on_event`** global
  hook (skips when an input is focused via `w.id_focus()`); cyclic senders driven by one `gen_loop`
  thread spawned in `start_measurement` (own bus per iface, TX via the bounded inbox). New **Generators**
  dock panel (one left-aligned button per sender — gui's centered-label-blank bug — showing key + bus +
  id; cyclic labelled with period) + activity-bar icon + View-menu entry. Demo: `projects/sim-demo.blobnet`
  CAN1 gained 4 senders. **VERIFIED in the GUI** (screenshot): cyclic `0x123 DEADBEEF` auto-fires as TX
  and is seen back as RX (like a real node); hotkey **`p`** sent Request `0x101` (ReqCode=1 encoded) and
  the simulated SUT answered Response `0x102` — full round-trip, status "sent Ping ECU (Request)".
  Tiers 2–4 captured in memory for later. TODO (Tier 1 polish): per-sender target-bus override in the
  panel; live signal-value editing in the panel (currently fixed from the .yml); manual-button verify
  was inferred from the shared `fire_sender` path (key + cyclic directly verified).
- 2026-06-14: **Generators in-panel editor DONE & VERIFIED.** The Generators panel is now a full editor
  (mirrors the Simulation panel's inline-edit pattern): senders grouped by channel, each row = fire
  button (`▸ name [key]`) · edit toggle (`✎`/`▾`) · remove (`✕`); per-channel **＋ Add** and a top
  **💾 Save**. The inline editor (`sender_editor`, opened via `App.gen_edit['ci:si']`) edits name, key
  (1 char), trigger (manual|key|cyclic select), cycle_ms (cyclic only), the DBC **message** (select of
  `(raw id/data)` + all DBC message names) and either the message's **per-signal values** (one input
  per `Signal`, shown with its unit, current value from the sender or 0) or, for raw senders, the
  **id + hex data**. Setters (`set_sender_*`, `add_sender`, `remove_sender`) mutate the project model
  (`proj.channels[ci].senders[si]` — the source of truth) then `build_senders()` to refresh the live
  flattened `App.senders` (so buttons/hotkeys/cyclic loop update immediately); `SenderRT` gained `sidx`
  (within-channel index) to map edits back. **Save** reuses `do_save_project` (sender serialization
  already round-trips, save_test.v). **Verified in the GUI** (screenshots): editor shows ReqCode=1 live
  for the Ping sender; ＋ Add created a "New sender" with its editor auto-opened. Note: gui.input typing
  isn't testable via xdotool under WSLg (known issue), so value-edit *typing* was verified by code path
  (identical to the proven sim-editor `on_text_changed`), not synthetic input; clicks (fire/add/remove/
  toggle) and rendering verified live. ⚠ Caveat (pre-existing, not new): Save rewrites the whole project
  `.yml` via `to_yaml`, which **drops comments** + reformats — fine for app-authored files, lossy on
  hand-commented demos like sim-demo.yml (so I did NOT click Save on it during verification).
- 2026-06-14: **FIX: Generators panel crashed release build — colour-emoji/unsupported glyph in
  `gui.text`.** User hit `invalid memory access` (bogus deep `v_stable_sort` backtrace) opening the
  Generators panel. Root cause: vglyph's `load_glyph` needs a vector outline; the panel's `💾 Save`
  (colour emoji → embedded bitmap, `n_points==0`) — plus `✎`/`⚙` (dingbats the bundled font lacks) —
  have no outline. A `-g` build panics explicitly (`FT_Outline_Translate … got empty`); release
  compiles out the `$if debug` guard and corrupts memory instead. Fix: replaced with screenshot-
  verified-safe glyphs (`💾`→`Save`, `✎`→`…`, `⚙`→`…`, `✕`→`×`). **Verified stable in a RELEASE build**
  through Add / message-select / open-editor / cyclic-fire (no crash, panic-count 0). Full rule + the
  safe/unsafe glyph sets + the deterministic `-g` repro are in `docs/known_issues.md` (vlang/gui
  section, 🔴 glyph-outline crash). Note: a `-g` build ALSO panics on a **pre-existing latent** empty
  glyph in the always-rendered UI (benign in release) — separate from this; real fix is the vglyph
  whitespace-glyph patch (`docs/windows_build.md`), not yet applied on Linux. Pre-existing `⚙ Scaffold`
  in the Simulation panel uses `⚙` too (renders only when a node is expanded) — left as-is (not my
  regression), flagged for cleanup.
- 2026-06-14: **FIX: dragging any dock splitter crashed — the CLOSURE-RECLAIM patch freed a live
  drag handler.** Same misleading `v_stable_sort` backtrace; a **gdb** backtrace showed the real fault:
  a **NULL fn-pointer call** at `view_splitter.v:560` (`core.on_change`) during `splitter_on_drag_move`.
  Root cause (NOT a regression from the generators work — reproduced on the pre-generators commit too):
  the local **`gui-closure-reclaim.patch`**. During a drag gui keeps invoking the *mousedown frame's*
  captured callbacks (stored in `view_state.mouse_lock`) across the rebuilds the drag triggers; those
  callbacks capture a per-frame `SplitterCore` whose `on_change` is a per-frame dock closure.
  `reclaim_frames(2)` freed that still-live closure after 2 frames → NULL call. **Proven** by disabling
  `reclaim_frames` (crash gone) then re-enabling with the fix. **Fix:** skip reclamation while
  `window.mouse_is_locked()` (any active drag) — defer it until mouse-up; the short drag's few frames of
  closures are freed on the next idle frame, so the leak fix is intact. Updated `gui-closure-reclaim.patch`.
  Separately **applied the Linux `vglyph-empty-outline.patch`** (`glyph_atlas.v`): empty-outline glyphs
  (whitespace / unsupported) no longer panic (debug) or corrupt memory (release) — the Linux counterpart
  of the Windows "patch #4", which had never been applied here (so a `-g` build panicked on frame 1 on a
  whitespace glyph, masking real bugs). Both are LOCAL patches (`docs/v_patches/`, reapply on a fresh box
  — see README); **verified in a RELEASE build**: aggressive multi-splitter drags, no crash. ⚠ Takeaway:
  the `v_stable_sort` backtrace is GARBAGE under our patched build — always get a real stack via
  `gdb -batch -ex run -ex 'bt 40' --args ./build/<app>_dbg` (the `-g` build) before theorising.
- 2026-06-14: **Drove the Codex review chain on V PR #27446 (closure leak) + synced the fixes into
  `~/v`.** Codex (auto-review bot, on `vlang/v` only — NOT gui) flagged issues each round; addressed
  three real ones with validated commits on the PR branch: `8e709d6a` clear live-map value before
  `delete` (map.delete leaves the GC-scanned value slot → `ctx` stayed rooted), `508b6499` thread-local
  frame-build state (a worker-thread closure built during the UI frame-build window could be wrongly
  reclaimed → dangling), `6ab4d3e1` owner-scoped reclamation (consequence of the thread-local change:
  one build thread could collect another's). Each: `v self` clean + closure tests pass; 👍 + in-thread
  reply on every Codex comment. **Deferred** Codex's slot-reuse/stale-double-destroy finding (needs a
  per-slot generation counter; pre-existing, harmless for single-handle use) to a follow-up — do it only
  if the PR's direction is accepted. Codex re-reviews the full diff each round and re-lists already-fixed
  items, so it won't auto-👍 while anything is deferred → GGRei makes the manual call. **Synced all three
  fixes into `~/v`** (now on the PR branch — see Pinned versions) and rebuilt: `v self` clean, closure
  tests pass, **blobly_net rebuilt + splitter-drag smoke clean**. These fixes close a latent dangling-
  closure risk in our own app (rx/sim/gen worker threads create `queue_command` closures during UI frame
  builds). Filed gui PRs earlier this session: gui#60 (titlebar), gui#61 (MSAA). Codex isn't on gui, so
  those get human review.
- 2026-06-14: **Upstreaming + gui pin-bump assessment.** `vlang/gui` is **actively maintained again**:
  native **Windows support** merged to `main` (2026-06-11→13, JalonSolov/GGRei/CreeperFace/Dylan Donnell)
  + Windows CI; README says "active development". Filed two gui PRs from the MartenH fork:
  **[gui#60](https://github.com/vlang/gui/pull/60)** (titlebar_dark `sapp.isvalid()` guard — still present
  on main, `v fmt`-clean) and **[gui#61](https://github.com/vlang/gui/pull/61)** (`WindowCfg.sample_count`
  MSAA — was a local-only patch; gg already supports it). **Did NOT file:** the gcc-16 compile fixes
  (`win_patches #01/#02`) — already upstream in main's native-Windows work (verified COBJMACROS +
  `<stdio.h>`/`<wchar.h>` present); and the `splitter_emit_change` NULL-`on_change` guard — that field is
  `@[required]` so it's only NULL because of OUR closure-reclaim patch (not a stock bug; lives as our local
  caller guard). Already-open (not gui): vglyph **#4** (empty-outline) + **#5** still OPEN/unmerged → keep
  the local vglyph patch; V **#27446** (closure leak) DRAFT. **Pin-bump assessment (68b9302 → main 26f7784):
  GREEN** — both local gui patches (`gui-closure-reclaim` incl. drag guard, `gui-msaa-sample-count`) apply
  clean, `window_update.v` didn't drift, and the app **builds + runs** against gui `main` + patches
  (isolated VMODULES; layout renders, trace streams, splitter-drag safe). Bumping the pin is low-risk and
  would shed the gcc-16 local patches + gain active maintenance; drop the MSAA patch once gui#61 merges.
  Details: `docs/upstreaming.md` (status table), `docs/windows_build.md` (manifest banner).
- 2026-06-17: **Manual UI scale (DPI workaround) DONE & VERIFIED.** On HiDPI screens the whole UI rendered
  tiny — root cause is the benign-looking sokol log `LINUX_X11_QUERY_SYSTEM_DPI_FAILED … assuming default
  96.0`: under WSLg/X11 sokol can't read the system DPI, so `sapp.dpi_scale()` returns 1.0 → `gg.Context.scale`
  **and** vglyph's `scale_factor` (captured independently at init) both stay 1.0 → everything draws 1:1
  device-pixel. There is **no real DPI to read back**, so we expose a **manual scale multiplier** instead
  (the standard workaround). Implementation is **app-side**, matching the "one knob restyles the whole UI"
  design (`src/main.v`): a process global `g_ui_scale` (globals already on for the in-proc bus) multiplies
  (a) every theme size/padding/spacing/radius in `make_theme`, (b) the explicit grid row/header heights and
  the activity-bar icon size, and (c) ~120 hand-set widget pixel literals (input width/height, activity-bar
  width, tree indents, label min-widths) via two helpers `sc(v)` / `scpad(t,r,b,l)`; the window is created at
  `1500×920 × scale`. Text scales because vglyph just renders bigger glyphs at the larger px size. Set at
  startup via **`BLOBLY_UI_SCALE`** (accepts `1.5` or `150%`, clamped 0.75–3.0) or live from the toolbar
  **scale** dropdown (100–300%, rebuilds the theme like the dark/light toggle). At 100% every `sc()`/`scpad()`
  is a no-op, so the unscaled look is byte-identical to before. **Verified by screenshot at 150%** (uniform
  enlargement; activity-bar icons no longer clip; input boxes scale correctly; clean run, no panics).
  **Why NOT a gui/gg patch:** the "true DPI" route (`window.ui.scale`) is private *and* a trap — gg would
  draw scaled into a framebuffer sokol already sized at 1×, clipping the right/bottom; making it correct
  means coordinating the backing-store size too (a sokol/gg concern, high effort, low certainty under WSLg's
  no-HiDPI-backing-store). The clean upstream feature would instead be a gui `ThemeCfg.scale`/`theme.scaled()`
  (multiply theme sizes in `theme_maker`) — it'd also scale gui-internal chrome the app can't reach, but
  WON'T cover gui's fixed widget-style consts (we already override button/data_grid padding) nor the app's
  hand-set literals. Decided to keep it app-side (no pin/patch risk); a `ThemeCfg.scale` PR is a possible
  later contribution (gui is active again). The scale is a per-session setting (env or toolbar) and is
  deliberately **NOT persisted**: DPI scaling is inherently **per-monitor**, not per-machine or per-project —
  the right value depends on which display the window is currently on and would ideally change live when the
  window moves between monitors. So a static stored value (project `.yml` or a per-machine prefs file) is the
  wrong model; the live dropdown is the pragmatic surface. A future "proper" per-monitor version would react
  to display changes — which is exactly the sokol/gg DPI plumbing we chose to skip. Good enough for now.
  **Window scaling:** the window is created at `1500×920 × scale` at startup, and the live **scale** dropdown
  now also resizes the window by the same ratio (`new = current × newscale/oldscale`, so it respects manual
  resizes) so content density stays constant. That needed one new local gui patch —
  `docs/v_patches/gui-window-resize.patch`: `pub fn (mut Window) resize(w, h int)`, a one-line wrapper over
  the already-public `gg.Context.resize()` (gui's `Window.ui` is private, so the app couldn't reach it). This
  is a clean gui API-gap fill (a real upstream candidate), NOT the DPI workaround itself. Verified live under
  WSLg/X11 (programmatic `resize(1000,700)` took the window 1500×920 → 1000×700 exactly).
- 2026-06-18: **Phase 10 / Tier 4 — embedded Lua scripting DONE & VERIFIED (foundation).** Added a
  scripting **replacement** via an embedded **Lua 5.4.7** interpreter — built ahead of the Tier 1–3
  sequence DSL because the user wanted scriptable *diagnostic tests* first. **Why Lua not Python**
  (asked & answered this session): Lua is an *extension language* designed to be embedded — ~250 KB
  of dependency-free C that compiles into our binary with the existing C-interop path and links on
  both Linux and mingw-w64 with no runtime install; CPython would mean shipping a whole interpreter +
  stdlib, fighting the GIL, refcount lifetime and a hard-to-sandbox ambient environment. Lua is also
  GIL-free, trivially sandboxable, and its coroutines map onto our host-supplied-clock test sequences
  (the `due(now_ms)` pattern). Python stays where it already earns its keep — the **SUT/oracle side**
  (`can_sut.py`, `uds_server.py`). CAPL itself is a bytecode VM, so Lua is the right shape; we build
  CAPL-*capability*, not a CAPL parser. **Build:** Lua 5.4.7 source **vendored + committed**
  (`thirdparty/lua`, ~60 files, 944 KB; standalone `lua.c`/`luac.c` dropped) and compiled into the
  binary via a single-TU amalgamation `ct_lua_amalg.c` (5.4.7 ships no `onelua.c`), wired by V
  `#flag` (`-DLUA_USE_LINUX -lm -ldl`). `modules/lua` = a thin typed V facade over Lua's **macro**
  C-API through flat `ctlua_*` wrappers in `ct_lua_shim.h` (same pattern as `socketcan_shim.h`; the
  host `&Env` is stashed in `lua_getextraspace`, byte-clean strings cross the boundary). `modules/
  script` = an `Env` exposing scalar/string **host primitives** wired to the GUI-free stack
  (uds/isotp/transport/candb) + a **Lua prelude** that builds the ergonomic professional API:
  `test()` + `check.equal|truthy|between|nrc`, `uds.open():session/read_did/tester_present/raw`,
  `bus.send/recv/send_message`, `decode()`, and byte helpers (`tohex`/`fromhex`/`u16be`). Design
  keeps the V↔C surface scalar-only: e.g. `bus.send_message` iterates the signal table **in Lua**
  calling `__encode_signal` per signal (no Lua-table reads from C); only `decode()` builds a table
  from C. **Headless runner `cmd/script`** (`scripts/runtests.sh`) loads a project, brings the same
  engine the GUI uses up driver-free (sim ECUs + native `uds.Server` over software ISO-TP on the
  in-proc bus), runs the `.lua` files and reports pass/fail with a **non-zero exit on failure**
  (CI-ready). VERIFIED **10/10** vs `projects/sim-demo.blobnet` — `tests/diag_basic.lua` (session, VIN
  multi-frame, serial, SW ver, tester-present, NRC 0x31) + `tests/bus_signals.lua` (cyclic RX,
  decode-range, encode→send→decode round-trip, 0x101→0x102 request/response). **GUI Script panel**
  (toggle-only, `ƒ` activity-bar icon): file input + ▶ Run + one-click sample buttons; runs against
  the **live measurement** on a worker thread; output is buffered in `env.log_lines` and dumped in
  one `queue_command` when the run finishes — deliberately NOT streamed per-line, which would need a
  closure capturing `mut w` (V can't). **GUI-VERIFIED** by screenshot: ▶ Run on `diag_basic.lua` →
  "6 passed, 0 failed" with the VIN, and the `0x7E0` ISO-TP request frames appear in the Trace.
  Hermetic tests added: `modules/lua` (host callback, error propagation, byte-clean NUL payload) +
  `modules/script` (prelude + framework counts + decode + `check.nrc`). Gotchas (also in memory):
  (a) `v test` shell-splits `-path "@vlib|@vmodules|modules"` on its per-file re-exec — run module
  tests **without** `-path` (V auto-resolves `modules/` from `v.mod`); (b) any `fn test_*` is treated
  as a test by V, so name helpers `sample_*`; (c) hit the documented `pkill -f <pat>` self-kill twice
  (the tool's own cmdline contains the pattern) — kill by pid or `pkill -x <comm>`. NEXT (Tier 4
  rest): coroutine-based wait/expect sequences (Tier 3 *on* Lua), a sandbox (drop os/io) for
  untrusted scripts, on_message/on_timer event callbacks, more UDS services; a project `scripts:`
  block + recent-scripts; JUnit-XML output for CI. ⚠ The vendored Lua is plain MIT-licensed source
  (notice in `lua.h`); `thirdparty/lua/README.md` records provenance + upgrade steps.
- 2026-06-18: **CI stood up (Linux + Windows) + user docs.** Root-caused the failing Windows CI: NOT
  caching — `windows.yml` pointed `V_ASSET` at `v-closurefix-windows.zip` which was never minted, so
  `gh release download` failed in 22 s. **New `.github/workflows/ci.yml` (Linux, green on first run):**
  `test` job = `v test modules/` (20/20, incl. `lua`/`script`) + headless Lua tests
  (`scripts/runtests.sh`) on the in-proc sim; `gui-build` job = gui+vglyph pinned + the two
  build-required patches (`gui-msaa-sample-count`, `gui-window-resize` — verified to apply clean to
  68b9302) → compile-link `src/main.v`. V via `vlang/setup-v@v1.4 check-latest` (the 0.5.1 *release*
  predates vlib/yaml; same approach vlang/gui's own CI uses). **Windows `windows.yml`:** fixed the MSVC
  job (repoint to the existing `v-de365a1-windows.zip`; drop closure-reclaim — needs a closure-API V;
  add `gui-window-resize`) — now **green** (first run also bootstrapped + published the
  `vcpkg-pango-x64-windows.zip` deps asset, so later runs are ~15 min); **added a `build-mingw`
  (MSYS2/pacman, no vcpkg) job** — green. `modules/lua/lua.v`: gated `-lm`/`-ldl` to `linux` so the
  vendored Lua links under MSVC/mingw (MSVC's linker rejects `-l*`). All 4 jobs pass. **User docs:**
  `docs/scripting.md` (headless runner + full Lua API), README refresh (Docs index, killed the stale
  "Phase 0/1"). Risk noted: `setup-v check-latest` tracks bleeding-edge V — pin to a built-from-source
  commit if it ever breaks the Linux jobs.
- 2026-06-18: **Windows real-CAN-HW backends — PCAN + Kvaser IMPLEMENTED (not yet HW-verified).** Per
  the user (has PCAN + Kvaser adapters; Vector machine intermittently). Both behind the existing
  `transport.Bus` seam, Windows-only (`_windows.v`), vendor DLL loaded at **runtime via
  LoadLibrary/GetProcAddress → NO SDK, NO import lib, mingw OR MSVC**: `transport/pcan_windows.v` +
  `pcan_shim.h` (PCANBasic.dll) and `transport/kvaser_windows.v` + `kvaser_shim.h` (canlib32.dll),
  wired into `open_windows.v` (`pcan:<ch>[@<bitrate>]` / `kvaser:<ch>[@<bitrate>]`; bitrate carried in
  the iface string since `transport.open(iface)` gets no Channel cfg — default 500k; mapped to PCAN
  BTR0BTR1 / Kvaser canBITRATE_* codes). **Compile-verified FROM WSL** by cross-compiling the transport
  module to a real Windows x64 PE (`v -os windows -cc x86_64-w64-mingw32-gcc`; linked with no vendor
  .lib, confirming the LoadLibrary approach) — and compile-checked in the Windows CI (full GUI build).
  Linux build unaffected (`_windows.v` excluded; transport tests still 3/3). **NOT run against
  hardware** (no adapter/driver on the dev box). Owner verification (driver install, Kvaser virtual
  channel = test with NO adapter connected, PCAN needs the physical bus, python-can cross-check) +
  status: `docs/windows_can_hardware.md`. The ABI is from vendor docs — watch for struct-packing /
  status-code surprises on real silicon. TODO: slcan (serial, cross-platform) + Vector (XL API) backends.
- 2026-06-18: **Windows PCAN + Kvaser backends HW-VERIFIED.** Drivers installed (Kvaser Drivers for
  Windows → `canlib32.dll` + virtual channels; `winget install PEAKSystem.PEAKDrivers` → `PCANBasic.dll`).
  Cross-vendor + bidirectional on a shared 500k bus (Kvaser Leaf Light v2 ↔ PCAN-USB Pro FD) via
  `cmd/can_smoke`: Kvaser TX `0x123#DEADBEEF` → PCAN RX byte-identical, AND PCAN TX `0x456#CAFE` →
  Kvaser RX — each backend does send+recv on real silicon; the two vendor stacks agreeing on the wire
  IS the cross-vendor oracle. Defaults `kvaser:0` / `pcan:PCAN_USBBUS1` worked first try — **no ABI /
  struct-packing surprises**. Two enabling fixes: `cmd/can_smoke` switched from the Linux-only
  `open_socketcan()` to the agnostic `transport.open()` (so it runs on Windows) + flushes each RX (live
  headless capture); and the mingw build needed `gui-window-resize.patch` synced into `setup_win.ps1`
  (+ `win_patches/07`) — the WSL side left it `docs/v_patches`-only, so a fresh local Windows build
  failed on `unknown method gui.Window.resize` (CI already applied it). NEXT (optional): GUI smoke via
  `projects/hw-crossvendor.blobnet` + python-can oracle; then slcan + Vector.
- 2026-06-19: **Validated GGRei's upstream closure fix (v#27483 + gui#62) as a replacement for our
  local patches.** v#27483 ("builtin: add closure lifetime reclamation") is GGRei's cleaned-up recovery
  of our #27446 work, against master, with a proper **`closure.Lifetime` API** (`new_lifetime()` →
  `frame`/`reclaim`/`reclaim_all`/`dispose`/`suspend`/`untracked`) + Cgen non-escape auto-cleanup;
  gui#62 ("reclaim layout callback lifetimes") uses it in `Window.update()` and **pins persistent
  callbacks** (animations/hover/async grid+listbox/CRUD/drag-reorder) instead of our minimal
  `reclaim_frames(2)` + mouse-lock guard. **Tested in isolation** (built V from the PR into /tmp,
  gui#62 + vglyph into a separate VMODULES, blobly_net built with NO local closure patches — only the
  two build-required gui API patches sample-count + window-resize): compiles clean, and live sim-demo
  **RSS plateaus ~315 MB** (10s 279→ 90s 315 → flat 315.7 MB over the last minute), matching our
  patched build's ~318 MB and unlike the unfixed unbounded climb. **Recommendation: adopt when both
  merge** (gui#62 depends on v#27483; both OPEN) and drop our two local closure patches; keep the
  sample-count/window-resize gap-fills. Our Linux CI (`setup-v check-latest`) will pick up v#27483
  automatically once merged.
- 2026-06-19: **Scripting Tier 4 extended — sequences, reactive callbacks, more UDS.** (a) **UDS
  services** added to BOTH `uds.Client` and the native `uds.Server` (so they're testable headless):
  **0x2E WriteDataByIdentifier**, **0x27 SecurityAccess** (server hands a demo seed `11 22 33 44`,
  validates key = `uds.security_key(seed)` = seed XOR 0xFF; `unlocked` flag; wrong key → NRC 0x35),
  **0x19 sub 0x02 ReadDTCInformation** (canned DTC records). Hermetic `modules/uds/server_test.v`
  (write+read, unlock, bad-key, DTC). (b) **Lua prelude** gained sequence helpers `expect(channel,id,
  timeout)` / `expect_signal(channel,id,sig,want,timeout)` (blocking wait-for, want = value or
  predicate) and a reactive event loop `on_message(channel,id,fn)` / `on_timer(period,fn)` /
  `run(duration)` — built in Lua over `bus.recv` + a new host `__now_ms()` (monotonic clock); no raw
  coroutines exposed (Lua's are available for advanced use). uds object gained `:write_did`,
  `:security_access(level[,keyfn])` (default keyfn = the sim's XOR-0xFF algo), `:read_dtcs([mask])`.
  (c) New scripts `tests/diag_advanced.lua` (write/security/DTC) + `tests/sequences.lua` (expect /
  on_message / on_timer). **VERIFIED headless 17/17** vs sim-demo (event loop healthy: 15 heartbeats +
  14 timer ticks over 1.5 s @ 100 ms); module tests 4/4; GUI still builds. Docs: `docs/scripting.md`
  updated (UDS table + Sequences/Reactive sections). Gotcha: V has no `...spread` in an array literal
  — build the slice with `mut req := [...]; req << key`. TODO (Tier 4 rest): sandbox (drop os/io) for
  untrusted scripts; project `scripts:` block + recent-scripts; JUnit-XML for CI; DID↔signal mapping.
- 2026-06-19: **Help links kept in-app (no surprise browser) + closure leak fix ADOPTED from upstream.**
  (a) **Help link handler:** gui's markdown opens any non-anchor link via `os.open_uri()` = the OS
  browser (gui is single-window — sokol_app — so it genuinely can't pop a 2nd app window; the only real
  extra windows are native file pickers + a browser from a markdown link). Added `help_link_handler` via
  `w.set_link_handler()` in `on_init`: real `http(s)://` still open in the browser; relative/internal
  links are handled in-app (switch Help page if it names one, else swallow — never a browser). Made
  quickstart.md's Examples reference a real `[Examples](examples)` link to exercise it. (b) **Closure
  leak fix is UPSTREAM** — GGRei's [vlang/v#27483] (closure `Lifetime` API, merge `1a2d0e5b`) +
  [vlang/gui#62] (uses it in `Window.update()`, merge `7a20a6ac`) both merged. **Validated the adopted
  stack** (built V from #27483 + gui `7a20a6a`, blobly_net with NO local closure patches — only
  `sample-count`/`window-resize`/vglyph): builds clean, live sim-demo **RSS plateaus ~330 MB** (flat
  90→120 s), leak gone. **Repo adoption:** Linux `ci.yml` gui pin `68b9302 → 7a20a6a`; CLAUDE.md Pinned
  versions + `docs/v_patches/README.md` mark `closure-gc-leak-fix.patch` + `gui-closure-reclaim.patch`
  SUPERSEDED (and the gcc-16 `01`/`02` are upstream at the new pin too — only 03/06/window-resize/vglyph
  remain). **Windows CI/build stays `68b9302`** (its prebuilt `de365a1` V predates the closure API; the
  leak is Linux-only so Windows is unaffected — bump once a master-built V Windows asset is minted). TODO:
  update the live `~/v`→master + `~/.vmodules/gui`→`7a20a6a` (drop patches) for the local dev build.
  DONE same day: live `~/v` rebuilt on master `c0624b2`, `~/.vmodules/gui` → `7a20a6a` (closure
  patches dropped, only sample-count/window-resize re-applied); local build 21/21 + 17/17 + runs.
- 2026-06-19: **FIX: Trace "blank lines below the dock text" after moving docks — was an app bug, not
  gui.** Root-caused from a user screenshot: `trace_view` sized the data_grid with
  `max_height: f32(window_height) - 158` — a WINDOW-height cap tuned for the default layout. When a
  dock rearrangement made the Trace panel TALLER than `window_height-158` (e.g. closing other panels so
  Trace fills the column), the cap stopped the grid short → blank gap below it. Fix: drop `max_height`
  (and the `window_size()`-derived `grid_h`) entirely — `gui.data_grid`'s default `sizing: fill_fill`
  already bounds it to its actual dock container, so it now tracks the panel height in any layout.
  Verified by screenshot: default layout unchanged; with Trace made full-height the grid fills to the
  bottom (previously ~110 px blank). gui is single-window + the dock TREE mutation is sound, so this was
  ours, not gui. (Only `trace_view` had the window-height grid sizing; other window_size() uses are the
  activity bar + the scale-dropdown resize, both fine.)
- 2026-06-19: **FIX: tabbed dock groups rendered a big blank gap above their content (gui patch).**
  User hit it dragging Trace(filter) onto Graphics with the whole dock highlighted (the center/tabify
  drop → a group with 2+ panel tabs). Root-caused (deterministic repro: any `dock_panel_group` with 2+
  panel_ids): gui's per-tab **separator** is `column(width:1, sizing: fixed_fill, …)` — a height-**fill**
  child inside the **fit-height** `dock_tab_bar` row. A fill child in a fit row makes the row balloon
  (~150 px), pushing the content down → the blank. It only appears with 2+ tabs (the separator is added
  between tabs), which is why single-panel default layouts never showed it, and why it looked like a
  "moving docks" glitch. NOT our code (confirmed: same gap whether plot or ftrace was the selected tab)
  and NOT a regression from the gui bump (the buggy line is identical in 68b9302 and 7a20a6a). **Fix:**
  `docs/v_patches/gui-dock-tab-separator.patch` — separator → `fixed_fixed` height 20 (definite height,
  no fill → the bar fits the tabs; divider still visible). Verified by screenshot: tabbed group content
  now sits directly under the tab bar. Applies clean to BOTH pins; wired into ci.yml + windows.yml (both
  jobs) + setup_win.ps1 (`win_patches/08`) + applied to live `~/.vmodules/gui`. (vlang/gui is
  effectively stagnant, so a local patch — not an upstream wait — is the right call; still a clean
  upstream candidate.)
- 2026-06-19: **Known bug RESOLVED by the gui bump: centered text in buttons no longer renders blank.**
  The long-standing "`gui.button` labels come out blank when wider than the text / centered `gui.text`
  draws nothing" bug (confirmed on the old pin `68b9302`, both WSLg + native Windows) is **fixed on
  `7a20a6a`** — verified with a minimal standalone repro (default-centered button label renders). So the
  gui bump (done for the closure leak fix) also fixed this. The `h_align: .left` workarounds
  (`diag_button`, Send/Generators/Script panel buttons) are now optional — they still work; revert to
  centered `gui.button` if/when a centered look is wanted. Doc'd in `docs/known_issues.md`.
- 2026-06-19: **Data-plane load benchmark (`cmd/loadtest`) — threading scales, data plane is not the
  bottleneck.** Headless harness (no GUI): N buses, each a producer + consumer thread (consumer DBC-
  decodes), at a target/max rate; reports throughput / drops / cores / RSS. Built to validate the
  "20+ CAN + a couple Eth" question before the GUI ceiling muddies it. Results on this 16-core box
  (in-proc bus, decode ON, 20 buses): **8k/s/bus (157k/s agg = saturated classic CAN) → 0 drops, 1.7
  cores, 43 MB**; 20k/s/bus (393k/s) → 5.1 cores; 40k/s/bus (784k/s) → 10.9 cores; all **flat 43 MB,
  ~0% drops**. Max flood ≈ **830k frames/s aggregate** ceiling. Findings: (1) realistic load (a fully
  saturated 20-bus system) is trivial — <2 cores, 43 MB; (2) the data plane scales ~linearly to ~800k
  frames/s, ~5× a saturated 20-bus classic-CAN system; (3) **memory is flat regardless of rate** (the
  in-proc bus's drop-on-full bounds it — `inproc_queue_cap` 8192/sub; no leak); (4) the ceiling is V
  `chan` throughput/contention, NOT decode (decode ~4.3M signals/s and parallelizes — counter-intuitively
  decode-ON out-throughputs decode-OFF in max-flood because decode work off the channel lock cuts
  producer/consumer contention); (5) per-bus threading parallelizes well (CPU grows with load across
  cores). **Conclusion: keep per-bus I/O threads + single-threaded GUI w/ bounded repaint; the GUI is
  the real ceiling, not the data plane.** Future scaling work (if ever) is the display/record split +
  bounded buffers, not more threads. Note: this benchmarks the in-proc simulation path; real HW buses
  are ~8k/s/bus max (kernel/driver-bound) so 20 of them ≈ 160k/s = the trivial case above.
- 2026-06-19: **Toolbar stutter-spinner — visual GUI-render health/jank indicator.** Small rotating
  arc in the toolbar (next to the running/stopped status). `spinner_view` draws it via `gui.draw_canvas`
  + `dc.arc`/`dc.circle`; the angle is **time-based** (`time.ticks()`, ~1 rev/s) so it shows true frame
  timing — a smooth spin = healthy render loop, a jerk/jump = a frame stutter. Our render is event-
  driven/on-demand (gui `refresh_layout` flags; not a 60fps loop), so a new `spin_loop` thread (spawned
  in `start_measurement`, exits on `!app.running`) requests `update_window()` ~30×/s **while running**
  to drive a steady repaint cadence. Stopped = a faint static track ring, no thread, no idle cost.
  `draw_canvas.version` is u64 and time-bucketed (`ticks/16`) so it re-tessellates each frame while
  spinning. Note: forcing ~30 fps repaint while running raises CPU (esp. under WSLg's GL tax — which is
  exactly what the spinner makes visible); it's only while running. gui (7a20a6a) has NO spinner widget
  (the screenshot in chat was a newer gui/go-gui showcase) so this is a custom one. (go-gui's "animated
  math curves" — rose/lissajous/lemniscate/hypotrochoid — are just parametric equations = not
  copyrightable; addable later as styles with zero code-copying if eye-candy is wanted; a plain arc is
  the clearest stutter cue.)
- 2026-06-19: **FIX: Graphics waveforms "stretched / moved independently" — per-window auto-scale
  breathing.** User saw plotted signals (sines) stretch/rescale vertically and independently as they
  scrolled. Root cause: `draw_one_series` recomputed each signal's y min/max from the **visible sliding
  window every frame** — so as a peak/trough scrolled off, the local span changed and the waveform
  rescaled (and each signal did it independently). The x-axis was already correct (shared `times`, time-
  based `x = (t-wstart)/win`), so this was purely the y-scale. **Fix:** an **expand-only running y-range
  per `<id>:<signal>`** (`App.plot_range`, widened in the decode/recompute loop, never shrinks) used for
  scaling instead of the per-window extremes → a stable scale: a scrolling sine keeps constant amplitude
  (one brief settle as full amplitude is first seen, then fixed). Reset with the trace Clear / on new
  data. Threaded `shown_min`/`shown_max` through the draw closure → `draw_signals` → `draw_one_series`.
  Verified by screenshot: 0x100 Powertrain's 6 signals scroll with steady amplitude (no breathing).
- 2026-06-19: **FIX: Graphics zoom-out blanked the WHOLE window (render-buffer overflow).** User: after
  ~a number of seconds running, pressing the Graphics `−` (zoom out, e.g. 10s→30s) blanked the entire
  window — not just the plot. Process stayed ALIVE, RSS normal (~312 MB), and a `-g` (asserts-on) build
  printed **no panic** → not a logic bug. Root cause: `draw_one_series` emitted **one polyline vertex
  per sample**; zooming out widens the window so (once deep history fills) it pulls 1000+ samples/signal
  × 6 signals into the polylines → the tessellated triangles **silently overflow gui's shared render
  buffer**, so the whole frame draws nothing, every frame (the wide window persists → permanent blank).
  "Works for a while" = time for history to accumulate; the zoom-out is the tipping action. **Fix
  (`draw_one_series`):** decimate the drawn polyline to **~1 point per horizontal pixel** (stride =
  `series.len / int(cw)`; you can't resolve more, and it bounds the vertex count regardless of
  zoom/history), step-hold uses the previous EMITTED sample, and lighter `.butt`/`.bevel` joins (fewer
  triangles than `.round`). `plot_xs/ys` stay full-length so the hover marker is unaffected. **Verified**
  by temporarily defaulting the window to 60 s (worst case) + ~48 s history (well past the failure
  point): the plot renders instead of blanking. NOTE: gui silently blanking the whole window on a
  vertex-buffer overflow (no clip/warn) is itself a gui robustness gap — candidate upstream report; the
  app-side point cap is the right fix regardless. xdotool can't reliably click gui's tiny zoom buttons
  under WSLg (verified via the 60 s default instead).
- 2026-06-20: **Filed the gui robustness gap upstream — [gui#65](https://github.com/vlang/gui/pull/65).**
  Followed the blank-window root cause (gg sets up sokol-gl with the default 64k-vertex buffer, shared by
  ALL triangles in a frame; overflow → sokol-gl silently drops the whole frame → blank, no error). The PR
  extends gui's existing render guard (`render_validate.v`) with a **cumulative per-frame triangle-vertex
  budget**: `emit_renderer_if_valid` counts `DrawSvg` vertices (`triangles.len/2`) into a new
  `Window.frame_triangle_vertices` (reset in `Window.update` beside `array_clear(renderers)`) and **skips**
  a batch that would push the frame past `max_frame_triangle_vertices = 49152` (64k − 16k chrome headroom)
  with a one-time warning, instead of overflowing. Factored the warn-once into `render_guard_warn_once`
  (reused by the validity guard, no behavior change). **Tests** (`_render_test.v`): single oversized batch
  skipped; cumulative medium batches accepted until overflow (the exact blank pattern); non-triangle
  renderer unaffected — and **verified the tests FAIL when the budget is removed** (they genuinely hit the
  guard). Ran gui's render test suite via the clone (`v test`, VMODULES=~/.vmodules, vglyph resolved): green.
  This is **defense-in-depth, NOT a build dependency** — our app-side `draw_one_series` decimation remains
  the primary fix; gui#65 just makes any future over-feed degrade gracefully (drop excess + warn) instead of
  blanking. PR notes a follow-up: check `sgl.error()` to surface `SGL_ERROR_VERTICES_FULL`. Logged in
  `docs/upstreaming.md`. **Codex P1 follow-up (addressed):** stencil-clipped SVG groups draw the mask
  geometry TWICE per frame (`draw_clipped_svg_group` step 1 stencil-write + step 3 stencil-clear) plus
  content once, so a ~24k-mask+24k-content group passed the 49,152 cap but emitted ~72k → could still
  blank. Fixed: `emit_renderer_if_valid` now budgets `is_clip_mask` DrawSvg vertices at **2×** (matches
  real SGL emissions); added 2 regression tests on the clipped path (skip-when-doubled-overflows +
  consumes-2×), verified to fail without the 2× accounting. **Codex P2 follow-up (addressed):** skipping
  only an over-budget clip mask left its content queued, and the draw path treats "content but no mask"
  as draw-UNCLIPPED → visibly wrong rendering. Fixed order-independently: emit **poisons** the whole
  `clip_group` when any part is budget-skipped (`Window.frame_poisoned_clip_groups`, reset per frame) and
  skips later group geometry; `draw_clipped_svg_group` **drops the whole poisoned group** (covers content
  queued before the mask). So an over-budget clipped group simply doesn't render that frame (warned) instead
  of rendering unclipped. Regression test + verified-fails-without-poison.
- 2026-06-21: **gui#65 REWORKED to draw-pass budgeting after a self-run `/code-review high`.** A
  high-effort review (8 finder angles via subagents) of the emit-time guard found a real bug it
  introduced: `frame_poisoned_clip_groups` was keyed globally by `clip_group`, but clip-group ids are
  **per-SVG-local** (`svg/tessellate.v` resets the counter each `tessellate()`), so one over-budget
  clipped SVG would wrongly drop every OTHER clipped SVG sharing the same local id; plus print_raster
  re-emits via `render_layout` without resetting the new counters (stale budget → missing print
  geometry), and filtered SVG content was counted but rendered offscreen (over-count). Root cause:
  emit-time budgeting counts *queued* geometry, not actual sokol-gl emissions — which is also why it
  needed the 2× clip-mask heuristic and the poison map. **Fix (Codex's original "group-level budgeting
  in the draw path" suggestion):** moved metering into the DRAW pass — `frame_triangle_vertices` resets
  at the top of `renderers_draw()` (covers print_raster for free), `admit_triangle_vertices()` is called
  at the real emission sites (`draw_svg_batch` per-renderer, `draw_triangles_gradient` per-call), and
  `draw_clipped_svg_group` budgets the whole consecutive run **atomically** via `group_triangle_vertices()`
  (mask counted 2× for stencil write+clear, content 1×) — per-run, so repeated clip ids never interfere
  and a group is all-or-nothing. Removed the poison map, the emit-time block, and the 2× heuristic.
  No perf penalty (rides existing loops, drops the per-frame map). Scope unchanged: only unbounded DrawSvg
  geometry metered; bounded chrome covered by the 16k reserve. Tests retargeted at the pure helpers
  (`admit_triangle_vertices`/`group_triangle_vertices`), each verified to fail when the cap or 2× is
  removed. Pushed to the PR branch; design explained on the PR thread. **Cleanup follow-up:** dropped
  the dead `if .len == 0 { init }` guard in `render_guard_warn_once` (V auto-inits map struct fields —
  verified: the warn path writes `render_guard_warned` on a zero-value `Window{}` and all render tests
  pass), and made the cumulative-budget test derive its batch size from `max_frame_triangle_vertices`
  (with an explicit `2*half > budget` assert) so retuning the const can't silently invalidate it.
- 2026-06-20: **FIX: Graphics strip chart stuttered — it advanced per-sample, not with wall-clock.**
  User: the plot "stutters a bit", expected super-smooth. Root cause: the screen repaints ~30 fps
  (`spin_loop`) but the PLOT only moved when a new sample of the selected message arrived — `plot_version`
  (the draw_canvas cache key) was keyed to THIS message's sample count, and `t_end` (the strip-chart's
  right edge) was pinned to `hist.last().t_s`. So between samples the plot was served from cache (frozen),
  and each new sample snapped it forward one inter-sample gap → scroll quantized to the message's frame
  rate (e.g. 10–20 jumps/s) instead of the 30 fps repaint. **Fix (oscilloscope-style):** while LIVE
  (`app.running && !app.paused`), anchor `t_end` to **wall-clock now** (`f32(f64(time.ticks()-app.t0)/1000)`,
  same clock as the samples, clamped ≥ last sample) so the waveform slides continuously and new samples
  enter at the right edge; and fold a **~30 Hz wall-clock bucket** (`time.ticks()/33`) into `plot_version`
  so the canvas re-tessellates each repaint to reposition. Stopped/paused/loaded → bucket 0 + `t_end` =
  last sample, so the chart holds still (a loaded log doesn't scroll off). Affordable now that
  `draw_one_series` decimates to ~pixel-width points, and `spin_loop` already forces 30 fps full repaints
  while running. Verified: renders correctly, plot actively scrolls (≈15.5k px changed between two shots);
  perceived smoothness is for the user to confirm on the live display. Knob: raise both `33`s (and
  spin_loop's 33 ms) to ~16 for 60 fps if 30 isn't smooth enough (costs more under WSLg's GL tax).
  **Follow-up (same day): startup "horizontal drift" — fill clamp.** With the wall-clock anchor, before a
  full `win` of history exists, `wstart = now − win` advanced every frame so the partial trace slid left
  as the window filled (the "scales horizontally" drift the user saw in the first seconds). Fix:
  `wstart := if t_end > win { t_end - win } else { 0 }` — pin the left edge at t=0 until the window is
  full, so the trace draws in **left→right** (strip-chart-recorder warm-up), reaching the right edge
  exactly as the window fills, then scrolls. Verified by screenshot (~40% filled, left-pinned, at ~4 s).
  The remaining VERTICAL settle (a sine's amplitude "drifts" until the first peak+trough are seen) is the
  expand-only y auto-range learning the range — kept as-is (user agreed: "it's sort of auto scaling").
  DBC ranges are full sensor scales ([0|16383] rpm, [-40|215] °C) so pinning to them would make real
  swings tiny; auto-fit is the right visual, and the one-time first-cycle settle is inherent to it.
- 2026-06-26: **PROJECT RENAMED `cantester` → `blobly_net` (full rebrand).** The GitHub repo was renamed
  `cantester_v` → `blobly_net`; user chose a full product rebrand (not just repo refs). Swept 68 files
  (266 edits) with ordered literal replacements: `cantester_v`→`blobly_net` (repo slug), `CANTESTER_`→
  **`BLOBLY_`** (12 env vars: BLOBLY_PROJECT/DBC/SOFTWARE_GL/AUTOSTART/UI_SCALE/LOG/GCFORCE/MEMLOG/RUN_MS/
  *_SHIM_H), `CANTester`→**`Blobly Net`** (window title, README, Help), `cantester`→`blobly_net` (v.mod
  module name, binary `build/blobly_net`, DBC file). **`dbc/cantester.dbc` → `dbc/blobly_net.dbc`** (git mv;
  all projects/*.yml + tests reference the new path; internal VERSION "blobly_net-1.0"). **Landmine handled:**
  `CANTESTERV0SUT001` is the SUT's **VIN** (test fixture, NOT the brand — its 17-char length forces multi-
  frame ISO-TP); rebranded to **`BLOBLYNETV0SUT001`** which is also exactly 17 chars (CANTESTER→BLOBLYNET is
  9→9), so the UDS multi-frame tests stay valid (server.v + uds_server.py + inproc_diag_test + diag_basic.lua
  + docs all updated consistently). **Deliberately LEFT:** internal C symbol prefixes `ct_`/`ctlua_`
  (ct_lua_amalg.c, ct_lua_shim.h, ct_pcan/ct_kvaser) — an abbreviation, not literally "cantester", and
  renaming C symbols is high-churn/low-visibility; offer separately if wanted. Git remote → `MartenH/
  blobly_net`. **Verified:** GUI builds + renders (title "Blobly Net — …"), full module suite 21/21, headless
  Lua runner 17/17 (VIN reads back BLOBLYNETV0SUT001 over multi-frame ISO-TP). Local checkout dir kept as
  `cantester_v` (renaming it would orphan the session/memory paths; GitHub repo name is independent).
- 2026-06-29: **Phase E1 — Ethernet DoIP diagnostics FOUNDATION DONE & VERIFIED (headless, no HW).**
  First automotive-Ethernet protocol, picked as the next subject (CAN HW is off-site). DoIP (ISO 13400)
  is **UDS-over-IP**, so it reuses the whole UDS stack via the same carrier-swap seam CAN uses: new
  **`modules/doip`** — `doip.v` (generic-header framing + routing-activation / diagnostic-message /
  vehicle-announcement builders+parsers, 8 hermetic tests) · `client.v` **`DoipClient` implements
  `isotp.Channel`** (tx_id/rx_id = tester/ECU logical addresses), so `uds.new_client(open_doip(...)!)`
  speaks UDS over Ethernet **unchanged** · `server.v` `DoipServer` = a TCP/UDP entity that's
  **uds-AGNOSTIC** (takes a `handler fn([]u8)[]u8` callback; the caller wires `uds.Server.handle`), so
  `doip` imports neither uds nor isotp and stays a leaf transport. **No virtual device, no driver,
  every platform** — runs on real localhost TCP/UDP (port 13400). `cmd/doip_smoke` drives the full
  flow V-tester ↔ V-entity (routing activation → session 0x10 → RDBI VIN 0xF190 → NRC 0x31) + UDP
  vehicle discovery (0x0001→0x0004) — **ALL CHECKS PASSED**; `modules/doip/net_test.v` is the hermetic
  uds-free networking test (kept globals-free so `v test modules/doip/` needs no `-enable-globals`).
  **Independent scapy oracle** `sut/doip_server.py` (scapy `automotive.doip` `UDS_DoIPSocket`, in
  `.venv-doip` via `scripts/setup_doip_oracle.sh`): an independent DoIP+UDS stack interoperates with
  our V entity on the wire — routing activation, session, multi-byte VIN RDBI, negative response all
  pass. Full module suite **23/23** (`v -enable-globals test modules/`). Design: `docs/
  ethernet_architecture.md`. Gotchas: (a) V's `~` promotes `u8`→`int` (`~0x02` = −3, not 0xFD) — mask
  with `u8(~x)` in header build/validate; (b) `spawn` needs a **reference** arg, so `new_server` returns
  `&DoipServer` (and its fields are module-private, so the cmd can't build the pointer itself); (c)
  scapy's plain `DoIPSocket` does NOT auto-wrap bare `UDS()` (sends raw UDS bytes) — use
  **`UDS_DoIPSocket`** for UDS-over-DoIP. **Codex review (PR #1) — 2 P2s addressed:** (1) server now
  **requires routing activation before dispatching diagnostics** (per-connection `activated` flag; a
  `0x8001` before a successful `0x0005`/`0x0006` is dropped, not forwarded to the UDS handler); (2)
  `read_message` **caps the advertised `payload_length`** (`doip.max_payload_len` = 64 KiB) before
  allocating, so a hostile/buggy peer can't force a multi-GB allocation or a hang on a body that never
  arrives. Both have regression tests in `net_test.v` (raw-TCP diag-without-activation → no reply;
  oversized header → connection rejected). **Full Codex review chain + self high-effort `/code-review`
  on PR #1 (7 fix commits, all real, all regression-tested) — MERGED:** (P2) `parse()` cast u32
  `payload_length`→int *before* the bounds check, so ≥2^31 wrapped negative, defeated the truncation
  guard and panicked on the slice — remotely triggerable via `serve_udp_once` (UDP, no cap, `or{}`
  can't catch a panic); fixed at root (cap inside `parse()` before any int()/slice). (P2) NACK
  diagnostic messages for a foreign **target** (≠ entity addr). (P2) NACK a **spoofed source** (≠ the
  activated source) after activation. (P2) deny **re-activation** with a different source (ISO 13400
  code 0x02) so the source guard can't be bypassed. (P2) **client** validates response addressing
  (`dm.source==c.target && dm.target==c.source`) — mirror of the server guard. (P3) smoke counts a
  bad SW-version response as a failure. Plus a reuse/efficiency pass (`encoding.binary` for all BE
  packing — matches `modules/mf4`; zero-copy `read_ptr` receive path; dropped a reassemble-then-reparse
  double-clone). **Deferred by design:** single-connection server (one tester at a time; thread-per-
  conn would need locking around the non-thread-safe `uds.Server`) — documented in
  `docs/ethernet_architecture.md` "Known limitations". V gotcha learned: a local `port` shadowing the
  module const `doip.port` miscompiled (tcc "'port' undeclared") — name locals distinctly. NEXT (E2): wire `doip:<host>[:port]` into `transport.open()` +
  project config + the GUI Diagnostics panel (already speaks `isotp.Channel`); then E3 = `modules/someip`
  (service discovery + RPC, its own oracle — does NOT reuse the UDS stack).
- 2026-06-29: **Phase E2 — DoIP wired into the app (config + Start/Stop + Diagnostics panel) DONE &
  VERIFIED.** `modules/project`: a `type: doip` channel with `interface: doip:<host>[:<port>]` +
  `tester_address`/`ecu_address` (logical addrs, default 0x0E80/0x1000); `Channel.is_doip()` +
  `doip_endpoint()` parse it (bare `doip`/host-only fall back to 127.0.0.1:13400), addresses
  round-trip through `save.v` (only emitted for DoIP channels), 2 new tests. **Deliberate deviation
  from the E1 plan's wording:** DoIP is NOT plumbed into `transport.open()` — that returns a
  `transport.Bus` (CAN-frame pipe) and DoIP has no frames to monitor; the carrier-swap seam is one
  level up at `isotp.Channel` (where `DoipClient` already plugs in), so DoIP is wired at the
  diagnostics layer. `src/main.v`: `start_measurement` branches on `is_doip()` before the CAN
  mode-match (no Bus/RX thread); if the channel hosts a simulated ECU it spawns `doip_server_loop`
  (native `DoipServer` wrapping `uds.default_server()` over real localhost TCP/UDP, short-timeout
  TCP+UDP poll, exits on the running flag). The Diagnostics panel resolves the first running channel
  to a `DiagTarget`; `open_diag_channel()` returns `doip.open_doip(...)` for DoIP else software
  ISO-TP, so `uds.Client` (and every diag button) rides either carrier unchanged; the panel header
  (`diag_target_label`) shows the live carrier. `projects/doip-demo.blobnet` (single DoIP channel,
  `simulate: [SUT]`) runs the entity driver-free. **Verified end-to-end**: GUI launched with the demo
  + `BLOBLY_AUTOSTART=1` served the entity on 127.0.0.1:13400 and an external UDS client read VIN
  `BLOBLYNETV0SUT001` over Ethernet (the GUI's own diag buttons use the identical client path); full
  suite **23/23**; `cmd/doip_smoke` still all-green. NEXT (E3): `modules/someip` (SOME-IP header +
  RPC + SD service discovery over UDP multicast; its own sim service + oracle, does NOT reuse UDS).
  Optional E2 polish: per-channel diag target selection in the panel (today it picks the first
  running channel); a GUI screenshot of the DoIP diag flow.
- 2026-06-30: **DoIP simulated network + Discovery panel DONE & VERIFIED (follow-up to E2, branch
  `doip-discovery`).** Architecture note settled with the user: there is **no "Eth bus"** analog of
  `transport.Bus` — Ethernet is switched point-to-point (TCP) + multicast (UDP), not a broadcast wire,
  and the OS exposes it as **sockets**, not a frame pipe. So we don't write an adapter backend (unlike
  SocketCAN): `net.dial_tcp/udp` already drive the physical NIC, and reaching a real DoIP ECU is just
  putting its IP in the channel (`doip:192.168.x.y:13400`) — same code path as the `127.0.0.1` sim. The
  only place the raw adapter matters is **passive pcap-style capture** (a real candump analog), deferred.
  (1) **Simulated network:** a `doip` channel now carries a per-entity identity (`vin` + `eid`); a
  network is just several `doip` channels. `modules/doip` got `default_vin`/`default_eid` + a
  `server_cfg(logical,vin,eid)` constructor (read-only `ServerCfg` fields stay out of callers' reach);
  `modules/project` parses+round-trips `vin`/`eid`; `doip_server_loop` builds each entity's cfg from its
  channel. `projects/doip-network-demo.blobnet` = 3 entities (Gateway/EngineECU/BodyECU) on 127.0.0.1/2/3
  :13400 (the 127.0.0.0/8 loopback-as-subnet trick), each a distinct VIN+logical address. (2)
  **Discovery:** `doip.discover(host,port,timeout)` (+ `VehicleInfo`/`parse_vehicle_announcement`) sends a
  UDP vehicle-id request and parses the announcement (unicast — works on loopback + a known gateway IP;
  subnet broadcast can layer later). (3) **DoIP GUI panel** (`⊕` activity-bar icon): **Discover** scans
  running DoIP channels + an optional manual `host[:port]` on a worker thread, lists entities (VIN /
  logical / endpoint); **Use** points diagnostics at one (its announced logical addr → ECU target);
  **Auto** clears it. Diagnostics targeting refactored so an explicit selection (`diag_sel`) wins else
  first-running (`resolve_diag_target`/`diag_target_for`/`diag_label_for`); selection+entities cleared on
  Stop/load. **Verified**: `doip.discover()` returns all 3 demo entities with distinct VIN/logical/EID;
  GUI launches with the network demo (⊕ glyph + panel safe, clean run); full suite **23/23**. NOT
  screenshot-verified click-through of the panel (blind xdotool coords under WSLg unreliable) — mechanics
  verified via the module API + the proven diag_button render path. NEXT: subnet-broadcast discovery; then
  E3 `modules/someip`.
- 2026-06-30: **Graphics panel reworked to a build-up "watch list" (multi-frame) + scaled Y-axis;
  cpuload sim cadence.** The Graphics plot was a quick-watch that auto-followed the Trace selection
  (showed the clicked frame's signals) with no Y-axis scale. Reworked into an explicit **watch list**:
  the plot shows exactly the signals you've **added** (and stays put as you click around the Trace),
  accumulated across **any number of frames**. Add via a discoverable **`＋ Plot`** (green) / **`✕ Drop`**
  (red) per signal in the Signals panel + **`＋ Plot all`** per frame; **Clear** in the Graphics header
  empties it. New `App.plot_watch []PlotPin` (id/ext/signal) is the source of truth; `plot_panel` builds
  its plotted set from it (each signal pulls history+timeline from ITS own message — `plot_series`/
  `plot_times` are now per-series `[][]f32`, since cross-frame signals have different cadences). Added a
  **Y-axis label column** (left of the canvas, gridline-aligned): **shared** mode scales all visible
  signals to one range with numeric labels (+ the common unit when homogeneous — e.g. CpuLoad shows
  0–100 %); a header **⊞ Shared / ⊟ Fit each** toggle flips to per-signal autoscale (Y labels become
  0–100 % normalised). Legend = one clickable row per signal (whole row toggles show/hide; a nested
  clickable child broke the row layout — keep it flat); pinned signals show their `0xID` source.
  `dbc/cpuload.dbc` gained **`GenMsgCycleTime` 500 ms** so the native sim actually transmits CpuLoad
  (cycle_ms 0 = event-driven, never auto-sent → empty trace); shipped `projects/cpuload-sim.blobnet`
  (driver-free CpuLoad demo) + `projects/scale-cpuload.blobnet` (monitor blobly_emb's real CpuLoad on vcan0).
  **VERIFIED by screenshot** (sim-demo + cpuload-sim, real click workflow): added EngineSpeed (0x100) +
  BrakePressure (0x301) → both persist across Trace clicks ("2 signals / 2 frames"); CpuLoad cores plot
  with a 0–95 % unit-labelled axis. ⚠️ **Debugging lesson (cost hours):** a throwaway test harness that
  force-set `sel_id` at startup (frame 0) made `plot_panel`'s `window.find_layout_by_id('plot_root')` run
  before the dock layout existed → gui segfault (garbage `v_stable_sort` backtrace). It looked like a V/
  cpuload/software-GL bug and sent me reverting `~/v` (c0624b2↔5bc4b1a) — all red herrings. The real plot
  is fine in normal use (the `if sel_id < 0` guard returns a `plot_root`-bearing hint from frame 0, so the
  measure never runs early). **Verify GUI behaviour via real interaction (xdotool clicks work; typing
  doesn't), never a forced-state shortcut; and `v_stable_sort` backtraces are garbage — gdb the `-g`
  build.** `~/v` left at the known-good **c0624b2** (the 5bc4b1a "regression" was unproven — the harness,
  not V); recheck the newer V (cgen-v3 / scalable-GC commits) in ~2 weeks. Also captured
  `docs/blobly_emb_synergies.md` (tester↔ECU synergies; `candb` is the one clear shared-vmodule candidate).
- 2026-07-02: **Telemetry trace viewer (blobly_emb runtime observability, blobly_emb/docs/telemetry.md P5) — foundation
  DONE & VERIFIED live.** New GUI-free **`modules/telem`** decodes the ECU's self-observability frames
  byte-for-byte (cross-validated against `blobly_emb/comm/{telem,trace}`'s own encode vectors AND against
  real bytes on the wire): **HandlerStat** (0x7E4, live per-handler last/max/count), **Record** (0x7E5,
  captured per-invocation start_us/cpu_us), **LoadDetail** (0x7E1), + the **TraceCmd/Rsp** control
  (0x7E2/0x7E3, cmd/rsp not UDS) and a **CSV handler manifest** (`id,partition,core,fb,handler,period_us`
  — resolves the target's 1-byte global handler_id → FB/handler/core/period; loaded next to the DBC via a
  new project `manifest:` channel field or `BLOBLY_MANIFEST`). CSV not TOML: vlib `toml` rejects
  `[[array-of-tables]]`, and CSV matches the doc's table + is trivial for loom2v to emit. **GUI: a new
  Trace Chart dock panel (`≣`)** — a **TRACE32 `trace.chart.tasks`-style swimlane**: one lane per handler
  (or grouped **by FB**, a header toggle), each Record a coloured bar at `start_us` × width `cpu_us`,
  faint lane separators, overran/saturated bars red-outlined; **Arm/Dump** buttons send the TraceCmd so
  the target streams its buffer (records only stream on a host `dump` — the target captures continuously
  but read-out is host-driven). `telem_ingest` decodes 0x7E4/0x7E5 from the RX stream in `record()`.
  **VERIFIED live end-to-end** against `blobly_emb/examples/trace_demo` on vcan0 (no HW): built + ran the
  demo (3 handlers 5/10/20 ms), monitored it in blobly_net, cansent the dump → **384 records streamed and
  rendered as Light.on_5ms / Medium.on_10ms / Heavy.on_20ms lanes** (screenshot-confirmed), handler_ids
  resolved via `manifests/trace-demo.csv`. Shipped `projects/trace-demo.blobnet` + `manifests/trace-demo.csv`.
  Module suite 25/25 (telem 2 files). ⚠ `src/` is single-file (`src/main.v`) — every build target is
  `src/main.v`, so the view lives IN main.v, NOT a separate `src/*.v` (a 2nd file needs `v run src`, which
  none of run.sh/CI/build_win use). NEXT (blobly_emb/docs/telemetry.md P5 rest): pan/zoom + hover on the swimlane; live
  HandlerStat gauges/sparklines; period/jitter histogram; overrun/deadline markers; load reconstruction;
  ISO-TP bulk dump; ThreadX preemption view — same records/manifest feed them all.
- 2026-07-03: **Trace Chart rework — zoom/scroll + honest single-core semantics (PR #14 branch
  `telemetry-trace-viewer`).** Two rounds on the swimlane. (a) First a zoom/pan toolbar (PR #13, merged);
  (b) then a rework after user feedback that flat/wide buttons, a missing timeline, and physically-
  impossible parallel bars looked wrong. Grounded in `blobly_emb/docs/telemetry.md`: on the **cooperative
  loom a handler runs to completion, never preempted by another FB**, so on ONE core handlers are strictly
  **sequential** (only different cores run in parallel), and **gaps are idle** (no idle task in this model —
  the loop polls/sleeps). Changes: **lane grouping is now 3-way — by CORE (default) / FB / handler**
  (`tchart_group`); by-core is one lane per core so bars can't overlap = exclusivity is visible, resolving
  the "threads can't run at once" concern (my earlier synthetic demo data had overlaps — unrealistic; a
  cooperative sim yields sequential records). **Buttons are real chrome-styled `gui.button`** (was flat
  `clickable_label`). **Proper timeline** — vertical gridline quarters in the canvas + a 5-tick ms label
  row that scrolls with it (Graphics-panel style). **Horizontal zoom + a native bottom scrollbar**: the
  canvas is drawn at `view_w × tchart_zoom_f` inside a `scroll_mode: .horizontal_only` column with
  `scrollbar_cfg_x{overflow: .visible}` (Zoom In/Out/Fit + a %); dropped the old ◀/▶/view-window math
  (`tchart_start`/`tchart_span`). **Idle** = alternating lane backgrounds make gaps obvious (title says
  "gaps = idle"). **Preemption**: preempted-flag records get a diagonal hatch — but the 8-byte Record
  only carries the *flag*, not `response_us`, so the preempted *interval* can't be drawn; that needs the
  **12-byte preemptive record (telemetry.md P4, not built)**. VERIFIED live vs an injected cooperative
  capture on vcan0 (24 sequential records): by-core single-lane no-overlap, per-handler 3 lanes, overrun
  red outline, preempt hatch, Zoom In → 400% + canvas widens, bottom scrollbar drags to pan (0→15.9 ms).
  (Merged as PR #13 zoom/scroll + PR #14 rework — both user-approved.)
- 2026-07-03: **GUI toolkit eval — WINDOWS BUILD CHECK: GREEN (the gating step; done on the Windows
  machine).** Ran the `libs/vgui` spike natively on Windows 11 (dedicated MSYS2 `C:\dev\msys64-ct`,
  mingw-w64 **gcc 16.1.0**, V 0.5.1 `c0624b2`, Intel Arc / **OpenGL 4.6**). All four open questions
  answered ✅: (1) **cimgui/cimplot + GLFW compile clean** under mingw — `build_deps.sh` ran unmodified
  (`pacman -S mingw-w64-x86_64-glfw` gives static `libglfw3.a`), built `libvgui_c.a` (only deprecation
  warnings); (2) **`#flag windows` resolves to a SELF-CONTAINED exe** — deps are only system DLLs
  (kernel32/user32/gdi32/shell32/opengl32/msvcrt), no MinGW runtime; flags = static glfw `-l:libglfw3.a`
  + `-lstdc++ -static -static-libstdc++ -static-libgcc` + win32 libs (verified with both gcc & g++
  drivers); (3) **multi-viewport spawns real native Win32 windows** — the single process owns 2
  top-level windows (`EnumWindows`-verified): main GLFW window + a detached **`Trace Chart`** OS window
  rendering the ImPlot swimlane outside the main rect (drag to 2nd monitor); both render correctly
  (Trace table + colored swimlane bars/overrun/preemption) — full-desktop capture in
  `libs/vgui/shots/windows_multiviewport.png`; (4) **idle CPU 0.5 %/core (~0.03 % of 16-core), ~84 MB**
  event-driven — beats WSLg's ~4 %, on par with gui's ~0.3 %. **The migrate/stay gate is CLEARED →
  recommendation stands: migrate, phased.** ⚠️ **Two findings fixed/flagged along the way:** (a) the
  WSL session's `.gitignore` pattern `examples/**/trace_chart` **also matched the `examples/trace_chart/`
  source dir**, so the example the WSL side thought it committed was silently NEVER added — I
  reconstructed `examples/trace_chart/trace_chart.v` (Trace table + swimlane, env knobs
  `VGUI_POLL`/`VGUI_FRAMES`/`VGUI_SHOT`) and scoped the ignore to the binary (`examples/*/trace_chart`
  + `.exe`); (b) **`v … run` panics on Windows** driving the C compiler (`array.push_many: new len
  exceeds max_int` in `os__windows_execute_command_line`, from MSYS bash *and* PowerShell) — a V bug,
  not vgui (blobly_net's own build is fine; the C compile+link are correct when run directly). Added
  **`libs/vgui/build_win.sh`** (2-step: V→C, then gcc compile + g++ link) as the reproducible Windows
  recipe; worth a minimal `v bug` report. MSVC (`cl`) not exercised (mingw is primary; nice-to-have).
  Results written into `docs/gui_toolkit_evaluation.md` + `libs/vgui/README.md`. NOT committed yet
  (awaiting user's say-so per the no-merge-without-approval feedback). **Windows deps installed this
  session:** `mingw-w64-x86_64-glfw` + `mingw-w64-x86_64-cmake` + `git` into `C:\dev\msys64-ct`.
- 2026-07-03: **GUI toolkit evaluation — Dear ImGui + ImPlot spike (branch `gui-toolkit-eval`; NOT
  merged).** Motivated by the user's worry that `vlang/gui` is **structurally single-window** (sokol_app
  owns one OS window) — a ceiling for a professional-class multi-monitor tool — plus gui's stagnation/patch
  burden. Since the engine is GUI-free, a swap is a `src/main.v` rewrite, not a rearchitecture. Spiked
  **V → Dear ImGui (docking/multi-viewport) + ImPlot** via a new reusable **`libs/vgui`** V module (clean
  V API over a curated *scalar* C ABI `vgui_glue.cpp` on **cimgui + cimplot** + a GLFW/GL3 backend — same
  facade pattern as `modules/lua`; learned from but did NOT reuse `nsauzede/vig`, whose hand-mirrored
  `ImGuiIO` rots on imgui bumps). **Both scary unknowns CLEARED on Linux/WSL:** (1) **multi-window works
  under WSLg** — 3 simultaneous real X11 windows, the Trace Chart swimlane landing on the user's **second
  monitor** (gui can't); (2) **CPU is matchable to gui** — event-driven `glfwWaitEvents` ≈ 4 %@1-2fps
  (→~0 pure-wait) vs the naive-poll **340 %** trap. Ported the **Trace Chart swimlane to imgui+ImPlot**
  (`libs/vgui/examples/trace_chart`): the swimlane is an ImPlot plot with **native drag-pan / scroll-zoom
  / double-click-fit / time axis** — replaces the whole hand-rolled zoom-buttons+scrollbar and looks
  *better* than the gui version. Gotchas: all imgui TUs must share one config (`IMGUI_DISABLE_OBSOLETE_
  FUNCTIONS` changes `sizeof(ImGuiIO)` → "Mismatched struct layout!" abort); imgui 1.92.8 swapped
  `AddRect` thickness/flags; `import -window` blanks the main GL window under WSLg (use the `VGUI_SHOT`
  glReadPixels-GL_BACK dump). Findings + migrate/stay recommendation (lean **migrate**, phased) +
  the **Windows-build-check next step**: `docs/gui_toolkit_evaluation.md`; module/build/README:
  `libs/vgui/`. Pinned: cimgui `053280d` (imgui `b61e563` = 1.92.8), cimplot `999ce3e`, GLFW 3.3.10.
  Screenshots in `libs/vgui/shots/`. Build-verified reproducibly from the repo (`build_deps.sh` +
  example). **Decision gated on the Windows build** (mingw/msvc: does cimgui/cimplot+GLFW compile, does
  the `#flag windows` link resolve, do native Win32 viewports spawn, idle CPU) — the user will drive that
  on the Windows machine. **Feedback captured this session:** do NOT merge PRs without the user's explicit
  say-so (get green, then ask).
- 2026-07-05: **Project editing in the GUI — schema v2 + Configuration editor + per-bus Trace (vgui,
  branch `vgui-migration`).** Verified the Windows-pushed vgui build runs on Linux first (stale
  `libvgui_c.a` needed `DEPS=1` — the incoming commits added `vgui_tree_node_open` to the C glue; noted
  in `run_gui.sh`). Then, per an agreed design (`docs/project_editing.md` + 6 mermaid example configs):
  a user can now build a `.blobnet` **from a blank project entirely in the GUI**. Concept model agreed
  with the user: **merged "Bus"** entity (not a 3-tier Network/Channel/Adapter split) with an optional
  **`network`** grouping label; DBC attaches to the bus; a **dedicated stopped-only Configuration editor**
  (not inline). (1) **`modules/project` schema v2**: `Channel` gained `adapter`/`address`/`network`/
  `protocol`; `iface` is now DERIVED via `compose_iface(adapter,address)` (virtual→`inproc:`, vcan/
  socketcan→raw, udp/pcan/kvaser/doip→`scheme:`). Parser accepts BOTH v2 (`buses:` + adapter/address)
  and v1 (`channels:` + `interface:`/`type:`, decomposed back) — full back-compat; `schema_version` 1→2
  so older builds warn. `to_yaml` emits v2. Tests: v2 round-trip + legacy-load + compose/decompose
  inverse (`v test modules/project/` green). (2) **main.v**: `load_project` split into `set_project` +
  reusable **`rebuild_from_proj()`** (the editor mutates `app.proj`, the runtime `app.chans` is derived
  — one source of truth, so Save captures edits); `gen_dirty`→**`dirty`** project-wide (● in toolbar).
  **File menu**: New / Open… / Save / Save As… / Configure… (Configure disabled while running). (3)
  **In-imgui file browser** (`draw_filebrowser`, no native dialog — imgui has none; `os.ls` nav +
  `*.blobnet`/`.dbc`/`.csv` filter + save-name) for Open/Save-As/Add-DBC/Add-manifest. (4) **Configuration
  editor** (`draw_config`, stopped-only floating window): per-bus name/network/adapter-picker/address/
  protocol/bitrate/mode/listen-only/enabled + DBC list add-remove + manifest + DoIP addrs/vin + replay
  block; ＋Add bus / Remove; Save→`.blobnet`. `commit_cfg` flushes edit buffers into the model (called by
  `save_project`, fixing a latent Save-loses-edits path). (5) **Trace per-bus view**: `show: [All][bus…]`
  toggle-chips (`bus_chips`, from the configured buses, network-labelled) on BOTH Trace panels
  (`trace_bus`/`ftrace_bus`), so `Trace→vcan0` + `Trace(filter)→vcan1` show disjoint traffic — the natural
  2-vcan layout. Made the trace `ch` column coherent (TX rows were `inproc:CAN1`, now the bus NAME like RX)
  so chips filter correctly. **Verification**: schema is unit-tested; a headless **`BLOBLY_SELFTEST_CONFIG`**
  smoke drives the real editor methods (New→add 2 buses→edit→add DBC→Save As→reload) and asserts the
  round-trip = PASS (the editor's widgets can't be clicked under WSLg, and — key finding — with imgui
  **multi-viewport** ON the floating editor/browser are SEPARATE OS windows that `VGUI_SHOT`'s glReadPixels
  can't capture, so the self-test covers the logic while screenshots cover the docked Trace chips). Shipped
  **`projects/restbus-2vcan.blobnet`** (v2-schema example: 2 vcan buses, DBC + simulated transmitters each,
  a 0x101→0x102 on-demand reply on vcan0 — the user's real-ECU-with-2-vcans restbus case) + Open Example
  entry. Dev hook `BLOBLY_SHOW_CONFIG=1` opens the editor at startup. Committed `279f002`.
- 2026-07-05: **Config-editor UX round (user feedback).** (a) **vgui glue additions** (`libs/vgui`,
  DEPS rebuild): `begin_closable(title, open) (vis, open)` → a close **[X]** in the window title bar;
  `set_item_tooltip`/`help_marker` (a dim "(?)" with a hover tooltip). (b) **Configuration editor is now
  a tree** — each bus is a `tree_node_open` with an **enable checkbox on the header row** (toggle without
  expanding), expanding to the fields; `+ Add bus` adds a node. (c) **Tooltips** (`help_marker`) on
  adapter/network/mode/bitrate/listen-only/DBC/manifest/DoIP fields explaining each. (d) **Adapter
  Discover** — a per-bus Discover button enumerates the machine's interfaces for the chosen adapter
  (`discover_addresses`: vcan/socketcan from `/sys/class/net` ARPHRD_CAN type 280; virtual suggests
  names; PCAN/Kvaser need the Windows driver) and lists them as click-to-fill chips — answers "which
  vcans/HW do I have?". (e) **Close [X] on every panel** — all ~19 dockable panels use `begin_closable`
  storing the open state back into their `show_*` flag (7 read-only `draw_*` fns became `mut app`).
  Verified: build clean, config self-test still PASS, close-X visible on docked panels (screenshot),
  editor tree renders no-crash. **Learned (from a user save):** Save over a shipped/hand-commented demo
  (e.g. sim-demo.blobnet) is **lossy** — `to_yaml` reformats + drops comments; the user editing an Open
  Example and Saving rewrites that repo file. Restored sim-demo; consider nudging Example edits toward
  Save As. Committed `c3e40cf` + polish `4d243da` (collapsed tree, header remove, dropped the stray
  DoIP "Discover" from the Buses panel → "Configure…" button instead).
- 2026-07-05: **Discover-interfaces dialog (matches the old vlang/gui app's UX) + PCAN-on-WSL insight.**
  User (real PCAN-USB Pro FD moved to WSL) showed the OLD app's rich bus-discovery dialog and asked why
  the new per-bus Discover was so weak. **Key hardware fact:** a PEAK/Kvaser device on Linux/WSL is
  exposed by the kernel SocketCAN driver (`peak_usb`) as **canN interfaces** — the dual-channel PCAN =
  `can0` + `can1` (dmesg: "PCAN-USB Pro FD … channel 0 → can0, channel 1 → can1"). So on Linux the
  **`socketcan` adapter** is correct, NOT the Windows-only `pcan`/`kvaser` DLL backends (whose Discover
  returns [] there — why the user "could only see the USB interface"). Built a proper **Discover dialog**
  (`draw_discover_dialog`, its own window): `read_can_ifaces()` reads `/sys/class/net` for each CAN iface
  with a rich label — USB **product** (`device/../product` = "PCAN-USB Pro FD"), bus path
  (`busnum-devpath` = "1-1"), link **state** (`operstate` = down) — plus vcan, a UDP software bus
  (`239.63.42.1:20000`, the udpbus default), and an in-process SIM net; `discover_all()` marks entries
  already in the project. The dialog has per-row **tick boxes + ＋ Add ticked**, **＋ vcan** / **＋ Sim
  net** quick-adds, Refresh, and a tip that PCAN/Kvaser show as SocketCAN on Linux. `add_bus_spec(adapter,
  address)` + `unique_bus_name` append a bus (used by ＋ Add bus, Add-ticked, quick-adds). Opened via a
  **Discover…** button in the config editor. Also: the enable checkbox now shows **"— disabled"** in the
  bus's tree header (visible feedback; the user thought it "did nothing" — it's the persisted attach-on-
  Start flag, no live effect while stopped). **Verified**: `discover_all()` on this box lists
  `can0/can1 · PCAN-USB Pro FD [1-1] · down`, `vcan0 · virtual CAN [added]`, `udp`, `SIM` — byte-matching
  the old app's screenshot; build clean, config self-test PASS. Committed `062aa4d` (+ tree-collapse fix
  `4b386ea`: `ImGui::TreeNode` hashes the ID from the whole label, so `##` re-keys the node when the
  visible adapter/address changes → collapses; use `###` for a stable id — also fixed the Network panel
  node whose label carried live RX). **Follow-up refinement:** removed the weak per-bus "Discover → found
  chips" (fragile: imgui ignores an external buffer write while the address field is focused, and it's
  redundant — the dialog's tick + Add-ticked IS how you turn can0 into a bus); and made the **adapter
  picker platform-aware** (`available_adapters`: Linux shows virtual/vcan/socketcan/udp/doip, Windows
  virtual/udp/pcan/kvaser/doip, always keeping a bus's current adapter) so `pcan`/`kvaser` no longer
  appear on WSL where they can't work. Committed `955bb69`.
- 2026-07-05: **Fix sluggish UI (window close/reflow took ~1-2s).** The event-driven loop waited
  `glfwWaitEventsTimeout(0.5)` per idle frame, so imgui's animations (window close, dock reflow, tab/
  hover fades) — which need CONTINUOUS frames — played at ~2fps and took ~1-2s to settle. Fix
  (`libs/vgui/vgui_glue.cpp`, DEPS rebuild): after each frame, sample activity (`io.MouseDown/Wheel/
  Delta`, `WantTextInput`, `IsAnyItemActive`); if active, set a `g_busy_frames=45` countdown; while it's
  >0, `vgui_running` waits `1/60`s (smooth 60fps), else the cheap `0.5`s idle wait. So interactions +
  animations render at full rate for ~0.75s after the last input, then idle CPU drops back. (Running
  measurements were already ~30fps via spin_loop's wake.) Committed `5ac4f1d`.
- 2026-07-05: **Channel shows "down" (red) when the CAN iface is actually DOWN.** User: a socketcan
  channel said "running" (green) while nothing was sent — because SocketCAN lets you `bind()` a DOWN
  interface, so `transport.open()` + the RX thread succeed and the app marked it `running` even though
  the link can't tx/rx. Added `iface_link_up(adapter, address)` — reads IFF_UP (bit 0) from
  `/sys/class/net/<if>/flags` for socketcan/vcan (software backends always true); `Chan.link_down` is set
  at Start and re-checked each `rx_loop` iteration (~5/s) so it flips green↔red live as the user brings
  the iface up/down. `chan_state` now returns a red **"down"** when `running && link_down`. Verified vs
  real hardware: `can0` (flags 0x40080, IFF_UP 0) → down/red; `vcan0` (0x81, IFF_UP 1) → run/green.
  (Root cause of the user's "nothing sent, no errors": can0/can1 were never `ip link set … up` — both
  DOWN with no bitrate. Separately noted: TX failures only surface in the Log panel — a follow-up could
  put them in the always-visible toolbar status.) NOT yet committed.
- 2026-06-30: **Distributable bundle + browser-rendered Help.** Two gaps closed so a freshly-downloaded
  build runs the sim out of the box. (a) **Bundle:** Windows CI (`windows.yml` msvc + mingw) now uploads
  a runnable folder — `blobly_net.exe` (+ DLLs on msvc) alongside `projects/`, `dbc/`, `samples/` and a
  `packaging/README.txt` — instead of a bare exe. The app **resolves resource paths relative to the
  executable** (chdir to the exe dir at startup if the CWD lacks `projects/` but the exe dir has it), and
  the **first-run default project is now `projects/sim-demo.blobnet`** (driver-free in-proc sim) instead of
  `demo.yml` (vcan0, needs a driver) — so double-click → ▶ Start just works, no hardware/Python. (b)
  **Help in the browser:** gui is single-window and its in-panel markdown is crude, so the Help panel
  gained an **"Open in browser"** button — `markdown.to_html()` (vlang/**markdown**, md4c) renders ALL
  help pages into one styled HTML doc written to a temp file + `os.open_uri()` → a real, nicely-typeset
  second window. NEW build dep **vlang/markdown `ef2f101`** (not a gui dep) added to all 3 GUI-build CI
  jobs (clone-pinned like gui/vglyph). Verified: local build clean; `markdown.to_html()` renders the real
  help docs to well-formed HTML (11 headings / 16 list items / code / links); app launches on the new
  sim-demo default without crash. Avoided the `↗` glyph in the button label (vglyph no-outline crash
  rule). **Codex PR #5 review (4×P2, 5×P3 across rounds) addressed:** markdown added to the fresh-setup
  scripts (pinned `ef2f101`); chdir-to-bundle skips when an explicit project override is given (relative
  `BLOBLY_PROJECT`/CLI arg keeps resolving against the user CWD); bundle stages `tests/` (Script-panel
  sample scripts); **mingw bundle ships its ldd-resolved `/mingw64/bin` runtime DLLs** so it too runs on a
  clean machine; relative help links stripped to text for the browser doc; the browser Help HTML is written to a
  per-user, 0700 `os.cache_dir()/blobly_net/help.html` (not shared /tmp — no symlink-preplant);
  Open Example menu gained DoIP + CPU-load entries (both ship in the bundle); the bundle ships LICENSE +
  THIRD-PARTY notices. **WSL help-open:** `os.open_uri`
  finds no Linux browser under WSL → route to the Windows browser via `wslview`/`explorer.exe` (wslpath
  UNC, launched through `os.new_process` so backslashes survive). TODO: Linux/AppImage bundle (the Linux
  CI job is compile-only today).
- 2026-06-30: **Windows memory leak FIXED — the packages were built with pre-closure-fix V.** User hit a
  fast unbounded leak on BOTH Windows builds (msvc + mingw) → Boehm GC `Too many heap sections`; WSL was
  fine. Root cause: it's the **V capturing-closure-context leak** (the 2026-06-13 bug), and the *fix*
  (master V's `closure.Lifetime` API + gui#62 calling it) had only been adopted on **Linux** (gui
  `7a20a6a` + master `~/v`). **Windows CI/build were still pinned to prebuilt V `de365a1` + gui `68b9302`**
  — both predate the fix — so every Windows package leaked. The CLAUDE.md note claiming "the leak is
  Linux-only so Windows is unaffected" was **backwards** (it was based on the retracted 2026-06-07 vglyph
  theory): the leak is platform-independent V codegen; only the *fix* was Linux-only. Fix: build Windows
  with **master V** + gui **`7a20a6a`**, mirroring Linux. No prebuilt master V exists for Windows (vlang/v
  weeklies stale since Feb, release is 0.5.1), so we use a **prebuilt master-V Windows asset**:
  compiling V on the runner WEDGES the runner's C compiler (the documented makev.bat hang — and the
  app build with bleeding-edge tip hung too), so we mint `v-c0624b2-windows.zip` (V master pinned to
  the validated Linux commit `c0624b2`, built on a Windows box via `v self` + uploaded to the
  `v-toolchain` release) and **CI just downloads it** (`windows.yml`, both msvc+mingw). **Local**
  `setup_win.ps1` pins V to `c0624b2` (`git checkout c0624b2` + `v self`, NOT `v up` to tip). gui
  `68b9302 → 7a20a6a` in both; **dropped win-patches 01/02** (gcc-16 C-bridge, now upstream at 7a20a6a),
  kept 03/04/06/07/08 (verified to apply on a clean 7a20a6a). Why pin `c0624b2` not tip: bleeding-edge
  master can carry regressions (a tip build hung the app compile); `c0624b2` is the exact commit the
  Linux build runs leak-free. ⚠ Pending: maintainer mints+uploads the asset, then CI build + on-box
  leak-verify.
- 2026-07-01: **Project files renamed `.yml` → `.blobnet`** (family scheme: blobly_net projects =
  `.blobnet`, blobly_emb configs = `.blobemb`; each tool's extension names its owner + implies its
  format — net is YAML, emb is TOML). The **content is unchanged YAML** — `project.load` reads by
  content, so `.yml`/`.yaml` still load (back-compat). `git mv`'d all 9 `projects/*.yml` → `*.blobnet`;
  swept ~45 refs across `src/`, `cmd/`, `scripts/`, `docs/`, CI. App surfaces updated: Open Project
  dialog + Save As default extension + filters (`blobnet` first, then `yml`/`yaml`), Open Example
  paths, first-run default + `bundle_marker` (`sim-demo.blobnet`), `cli_project_arg` accepts
  `.blobnet`. **Verified:** GUI builds, all cmd tools build, module suite 21/21, headless Lua runner
  **17/17** vs the renamed `sim-demo.blobnet` (loader parses it as YAML). Historical status-log
  mentions of the old `.yml` names left as-is (accurate history). NOT yet OS-associated on Windows
  (double-click → app) — a later step (register `.blobnet` → blobly_net.exe).

- 2026-07-06 → 07-21: **~30 PRs (#19–#54) that this log missed** — recorded retrospectively on
  2026-07-22. The work below landed without a status-log entry, so a fresh session reading this
  file had a ~2.5-week-stale picture of the project. Grouped by theme:
  - **Trace chart** (#21, #24–#35, #44, #45): decode blobly_emb's `entity_id` record format +
    config-driven frame ids; derived **idle lane**; FB bars show EXECUTION (not the response-time
    envelope); preempt hatch is **thread-only** and marks the **cut**, not the slice body;
    thread lanes show RTOS **priority** (manifest 5th column); preemption **cut-links**
    (victim → preemptor); micro-gaps = switch overhead, not idle; **wall-consistent** thread bars
    (ISR-chopped chunks + visible READY); stable lane order; dump **retry + drain** with a 1 s
    budget; **per-core** thread ids ((core,tid) keying for the two-core swimlane); **multi-block**
    dump (read blocks until the format says stop, transport-neutral).
  - **Shell panel** (#37–#39): an interactive console to the target over CAN, with copy/paste,
    clear, and real selectable scrollback.
  - **Flash** (#46–#48): `cmd/flash` host flasher (UDS programming session over ISO-TP), then a
    shared `modules/flash` session + the **GUI Flash panel**; **0x29 challenge/response auth**
    replaces 0x27 seed/key, with an adaptive path that flashes a keyless boot without auth.
    BLBT passthrough: mkimage-wrapped images transfer as-is.
  - **SOME/IP** (#49, #53, #54): E3 core — 16-byte header codec + envelope validation with
    golden vectors; an **oracle** pinning the FULL blobly_emb request datagram (not just the
    header slice), reserved client-id 0 rejected, request session-liveness rule; then the
    **RPC client + eth shell** in the GUI — the host half of blobly_emb's P3.
  - **DBC editor** (#50, #51): P1a — the **canonical `candb` serializer** (`modules/candb/
    dbc_write.v`) so a save/load cycle never drifts a file and git diffs show real changes only;
    P1b — the **panel**: forms, bit-matrix grid, live-loop save, read-only while running, with
    reader locking/quiescence worked out over 7 review rounds. See `docs/dbc_editor.md`.
  - **System viewer** (#52): `modules/sysview` + the read-only **System panel** — parses a
    blobly_emb `system.toml` (buses, once-declared cross-node signals with producers, nodes and
    their identity blocks) plus each node's `ecu.toml`. Deliberately a **viewer, not an editor**.
  - **Other** (#12, #19, #22, #23, #36, #40–#43): `LoadDetail` (0x7E1) multi-window load +
    overruns; Generators overhaul + DBC-typed inputs + collapsible trees + searchable browser
    Help; ISO-TP **CF sequence-number validation**; manifest handler/thread ids widened to u16
    (14-bit entity-id space); socketcan **EINTR retry** carrying errno up; Graphics y-axes go
    ImPlot-native; the H755 bench project; `M4LoadFrame` (0x201), the first cross-core signal.
- 2026-08-12: **Watcher postmortem — five silent ways to miss a codex review (net#84).** Over one
  session a review sat unread for 26 minutes and six findings sat unhandled while a watcher
  reported zero. None of the causes were visible from the outside; each command succeeded and
  returned nothing. (1) A detached shell job (`( ... & )`) fires into nothing, so the harness
  never wakes — twice, once for over an hour. (2) A hardcoded repo path made a waiter poll a PR
  number in the WRONG repository: `gh` returns nothing, "no pending checks" passes trivially,
  and it reports CI DONE on an empty result. (3) No notion of codex ERRORING ("Something went
  wrong") — the watcher waited out a 33-minute timeout for a review that was never coming.
  (4) No notion of comment AGE, so a 90-minute-old failure was replayed as fresh, twice.
  (5) THE ROOT CAUSE of the 26-minute miss: **pagination**. The API returns 30 items per page
  ASCENDING, so an un-paginated read drops the NEWEST comments — 38 existed, 30 came back, and
  the missing 8 were the ones being waited for. A `--arg` "fix" written in between made it worse:
  `gh api --jq` takes one argument, so passing jq's own flag exits 1 with no stdout and silently
  disabled the channel it was meant to read. Fixes and the resulting invariants are in
  CLAUDE.md ("Polling a codex review"); the diagnosis was wrong twice before pagination was
  found, having first blamed the reviews channel and then the time-scoping.
- 2026-08-12: **Watcher postmortem, part 2 — the reaction was a red herring; the verdict is the comment.** After the five
  silent failures above, two more hid a green review on net#84 for 38 minutes. (6) The verdict was believed to be
  deliverable ONLY as a 👍 reaction, which the watcher never polled. That turned out to be a red
  herring: the reaction cannot be used at all — it carries no reviewed SHA, and GitHub will not
  re-create an identical reaction, so no freshness test can ever pass on a later round. The
  clean result arrived as a reaction AND as a comment naming the head, one second apart. (7) The verdict comment that does exist is multi-line with
  `Reviewed commit:` in the MIDDLE, and the matcher piped it through `tail -1`, comparing the
  head SHA against the footer — it could never have matched, so every comment-delivered verdict
  would have been missed too. Both fixed and self-tested against the known-clean PR, which now
  reports in seconds. The lesson underneath all seven: the watcher was only ever tested against
  "did it stay quiet", never against "can it detect what it exists to detect" — a ten-second
  self-test against a state with a known answer would have caught most of them.
- 2026-08-12: **Watcher postmortem, part 3 — a failing `gh` read as "nothing waiting".** The
  count pipeline `gh api ... | awk` yields AWK's exit status, so an auth or API failure (gh
  returns 1 or 4 and prints nothing) made awk print `0` and succeed — indistinguishable from
  "no findings", which is the precise false-negative the whole section exists to prevent. Found
  by codex on the blobly_emb twin, fixed in the watcher, and verified by running it with a
  broken token: it now reports GH FAILED rather than clean. Two smaller ones alongside:
  `commits/<sha>/check-runs` pages are OBJECTS, not arrays, so the array-count recipe counts an
  object's keys; and the section as copied into blobly_emb linked a `docs/history.md` that does
  not exist there.

- 2026-08-17: FIVE watcher defects in one session (net#108/#109/#110), every one a SILENT WRONG
  ANSWER — a watcher reporting "nothing waiting" while an answer sat on GitHub — and three of
  them inside the mechanism whose whole purpose is to prevent silent wrong answers. The
  invariants they produced are in `CLAUDE.md`'s *Polling a codex review*; this is why that
  section is phrased so defensively.
  (1) WRONG CHANNEL: polled `issues/N/comments` for a verdict while six reviews across two PRs
  had landed as REVIEWS, each naming the head it was asked about (#108 at 96e9deadde, c80ba1d8c7,
  b255321830, 8b74922671; #109 at f8a818426e, 2b9e782153). Five watchers timed out at 60 minutes
  reporting nothing.
  (2) WRONG ID SPACE: the finding counter compared REVIEW-comment ids against an ISSUE-comment
  baseline — different sequences, so the count was permanently 0 and two real findings on #108
  sat unread for an hour.
  (3) WRONG FIELD: #109 round 7 delivered its only finding in the review BODY with zero inline
  comments, and a watcher counting comments reported "clean" on a round with a real defect in it.
  (4) WRONG CHANNEL AGAIN, OPPOSITE DIRECTION: the fix for (1) read reviews ONLY, then sat a full
  hour through a CLEAN verdict on #109 58f96ebd63 — clean results arrive as an issue comment
  ("Didn't find any major issues") and it had landed within minutes. The original version would
  have caught it; each was right about the half it was built from and blind to the other.
  (5) CRASH INDISTINGUISHABLE FROM FAILURE: editing the watcher while an instance ran (already
  forbidden) killed it with a bash syntax error, exit 2 — the code the script used for "review
  FAILED". A self-inflicted crash announced a failure that never happened.
  The `CLAUDE.md` section was rewritten three times that evening and grew 54 -> 93 lines before
  being cut back to invariants, which codex flagged on #110 as the guide taking on operational
  history. The pattern throughout: a description of an answer's shape, believed instead of the
  artifact, and never tested against the case not yet seen.
