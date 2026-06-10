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
modules/transport/          Bus interface (transport.v) + SocketCAN backend (socketcan_linux.v) +
                            cross-platform UDP-multicast software bus (udpbus.v) — the vcan stand-in
modules/isotp/              ISO-TP: Channel interface (isotp.v) + Linux kernel backend (kernel_linux.v)
modules/uds/                UDS diagnostic client over isotp (pure V, + tests)   (Phase 6)
modules/canlog/             candump .log parse/format (pure V, + tests)          (Phase 7)
modules/mf4/                native-V ASAM MF4 reader: DZ-compressed + MLSD/VLSD CAN-FD -> canlog
                            entries (pure V, no asammdf; + tests vs samples/demo.mf4)  (Phase 7)
modules/sim/                simulation engine: SimEcu/Engine + signal generators + the native
                            SUT ECU (twin of can_sut.py, verified vs Python golden)  (Phase 11)
modules/player/             replay engine: plays a []canlog.LogEntry recording at recorded
                            cadence x speed, play/pause/stop/seek/loop; caller supplies the
                            clock via due(now_ms) (pure V, hermetic tests)           (Phase 8)
dbc/cantester.dbc           real DBC describing the SUT's messages    (Phase 5)
cmd/dashboard/              throwaway GUI capability demo
cmd/signal_decode/          frame -> signals visualizer demo
cmd/dbc_decode/             load a DBC + decode one frame (machine-readable; oracle diff)
cmd/mf4_dump/               native-V MF4 reader smoke/oracle-diff (count, unique IDs, frames)
cmd/sim_smoke/              run the native simulated SUT ECU on the in-proc bus, verify end-to-end
cmd/isotp_smoke/            send one ISO-TP PDU, print the reply (multi-frame smoke)
cmd/uds_smoke/              drive the UDS client vs sut/uds_server.py
sut/can_sut.py              Python virtual SUT (emits/answers frames on vcan0)
sut/dbc_oracle.py           independent stdlib DBC parser+decoder (cross-validates candb)
sut/uds_server.py           Python virtual UDS server (stdlib ISO-TP) — oracle for modules/uds
sut/mf4_bridge.py           MF4<->candump bridge: convert/tomf4/frames/semantic-diff (needs .venv-tools)
scripts/setup_mf4_tools.sh  build .venv-tools (asammdf) + fetch real J1939 MF4/DBC samples
scripts/run.sh              build+run with WSLg software-GL workaround
scripts/setup_vcan.sh       bring up vcan0 (sudo)
scripts/shot.sh             screenshot the running app window (xdotool search + import -window)
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
| `mf4`                  | asammdf                     | ASAM MF4 log read (CAN frames)|
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

### Windows build (W1) — ✅ DONE (2026-06-05). Full recipe: `docs/windows_build.md`
The GUI **builds + renders natively on Windows** (mingw-w64 gcc) and the driver-free
virtual-first flow works (Python SUT over the UDP software bus). Idle render ≈ **0.3% CPU** (16-core) —
the WSLg GL-translation tax is gone. **Backend correction:** the W1 plan assumed D3D11, but vlang/gui's
shaders are **GLSL-only** (`gui/shaders_glsl.v`), so gui requires sokol's **GL backend** (`SOKOL_GLCORE`,
V's default); D3D11 would need a gui-side HLSL shader port (deferred — and unnecessary, GL perf is already
great). First-ever native Windows run of vlang/gui surfaced several real upstream bugs (gui Win32 C
bridge, a `titlebar_dark` pre-init abort, a vglyph whitespace-glyph panic, and V's sokol glue never
wiring D3D11) — all captured with upstream-style patches in `docs/windows_build.md` (manifest) for
contributing back to V/gui. **Smart App Control** (if enforced) blocks unsigned local builds and must be
turned Off (irreversible). Original handoff notes below (toolchain **mingw-w64 (gcc) via MSYS2**;
**virtual-first**, no real CAN HW yet):
- **Clone onto native NTFS** (e.g. `C:\dev\cantester_v`), NOT `\\wsl$\…` (the 9p FS is slow + has
  line-ending/permission quirks). Sync via the GitHub remote (`MartenH/cantester_v`).
- **Use a DEDICATED, isolated MSYS2** for this project — `pacman` is global per MSYS2 root, so install a
  *second* MSYS2 root (e.g. `C:\dev\msys64-ct`) and do all installs there. **Do NOT pollute the user's
  personal MSYS2.**
- In that dedicated MINGW64 shell: `pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf
  mingw-w64-x86_64-freetype mingw-w64-x86_64-harfbuzz mingw-w64-x86_64-fribidi
  mingw-w64-x86_64-fontconfig mingw-w64-x86_64-pango mingw-w64-x86_64-glib2`. Smaller dep set than Linux
  — **no X11/mesa/dbus/atk** (those were Linux desktop bits). Then V (clone+`make.bat` or prebuilt) +
  put `gui`/`vglyph` in `~/.vmodules`, and `v -cc gcc -path "@vlib|@vmodules|modules" run src/main.v`.
- **No vcan on Windows** → use `transport/udpbus.v` (the cross-platform localhost UDP-multicast software
  bus, built on the Linux side) instead of `vcan0` for the virtual-first flow.
- Risks: gui is immature + its author left → expect link/dep friction; check the gui repo for Windows
  notes. Native file dialogs are native Win32 (no zenity needed). Fallback escape hatch if gui blocks:
  **imgui+implot** (MSVC-friendly; user has experience).

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
   0xFFFF "not-available" sentinel is filtered). DONE: `modules/canlog` (V candump `.log` parse/format,
   pure-V + tests) and a GUI **"Open Log"** action (toolbar) that loads a `.log` direct-to-trace —
   decodes via the DBC and times relative to the first frame (`samples/demo.log` shipped as a demo).
   DONE: **MF4-aware open** — the GUI opens `.mf4` too (toolbar filter + `.mf4` detection in
   `load_log`). To keep the demo non-J1939 (J1939 needs PGN matching, deferred), `mf4_bridge.py` gained
   **`tomf4`** (candump `.log` → MF4 via python-can's `MF4Writer`); we minted `samples/demo.mf4` from
   `samples/demo.log` (round-trips identically, decodes against `cantester.dbc`) and ship it.
   DONE 2026-06-07: **native-V MF4 reader `modules/mf4`** — the GUI now opens `.mf4` with **zero
   Python** (the bridge was only the bootstrap). It parses MDF 4.x directly: DZ-compressed data blocks
   (zlib inflate + zip_type-1 byte de-transposition), DL/HL data lists, and three DataBytes layouts —
   MLSD (type 5, inline, Vector classic CAN), VLSD (type 1, separate length-prefixed signal-data block,
   Vector **CAN-FD**), and fixed inline arrays (python-can). Master time read as int-ns × a linear
   CCBLOCK (or float secs). Returns `[]canlog.LogEntry`, so `load_log` reuses the same trace path.
   Validated **frame-for-frame against asammdf** on a real 62 324-frame J1939+CAN-FD recording (id+data
   identical, timestamps within sub-µs) — and it reads the VLSD CAN-FD groups asammdf **fails** on
   ("Wrong signal data block reference"). `cmd/mf4_dump` is the oracle-diff CLI. `modules/mf4` tests run
   vs `samples/demo.mf4`.
   TODO: a timed *player* (replay onto vcan0 at recorded cadence); **J1939 PGN-aware lookup in `candb`**
   so the real CSS J1939 MF4s decode (their DBC IDs carry priority+PGN+source-addr — exact-id match =
   0 frames, PGN match = ~8k).
8. 🚧 **Operating modes + replay player** — per-bus modes **Off / Monitor / Replay**.
   **DONE 2026-06-10: `modules/player` + GUI replay wiring.** The GUI-free player replays a
   `[]canlog.LogEntry` recording (`.log` and native `.mf4` both yield it — shared `load_entries`
   helper) at recorded cadence × a speed factor, with play/pause/stop/seek/loop. Hermetic by
   design: the caller supplies the clock via `due(now_ms)` (same pattern as
   `sim.Engine.due_frames`), 13 simulated-clock tests; a 1 µs epsilon absorbs f64 epoch-offset
   error at exact-boundary ticks. Wired into **Start/Stop**: `start_measurement` matches on mode —
   replay channels open their bus and spawn `replay_loop`, which loads the recording in-thread,
   `bus.send()`s frames at cadence, records them as **TX** rows (same batched-repaint scheme as
   rx_loop, respects Pause), shows live progress / loop count in the Buses-panel note, and
   auto-stops with "replay finished" at the end. Monitoring the same iface on another channel shows
   the replay via the normal RX path — like a real node on the wire. `projects/replay-demo.yml`
   loops `samples/demo.log` on an in-proc bus (zero drivers/Python; GUI-verified at exactly the
   recorded 20 frames/s). TODO: transport-control UI (per-channel play/pause/seek/speed — the
   player API supports it; no GUI surface yet). Earlier UI work: trace scrollbar + uncapped history
   (newest-first ordering = inherent "follow"); gui exposes no public scroll-to-bottom, so a
   bottom-anchored autoscroll would need a gui patch.
9. 🔜 **Project/config files (`.yml`) + menus** — a gui `menubar`; **File** first: New / Open Project /
   Save / Save As / Open Recording / **Open Recent** / Exit (later: Bus, View, Tools, Help). The project
   file (vlib `yaml`; fall back to vlib `toml` if yaml proves too thin) is the single source of truth
   for the bus setup: `channels[]`, each with name/type(can|canfd)/interface/bitrate (+ fd/
   data_bitrate/sample_point/`timing{brp,tseg1,tseg2,sjw}`)/`mode`(off|monitor|replay)/listen_only/
   `databases[]` (DBCs) and a `replay{source,speed,loop}` block. For `vcan0` the bitrate/timing are
   nominal; for real `can0` they map to `ip link set can0 type can bitrate … sample-point …`. This moves
   DBC association from the hardcoded startup load + `CANTESTER_DBC` env into per-channel `databases`,
   and stores a recent-projects list for Open Recent. Full schema sketch was proposed 2026-06-04.
   A **Bus/Channel tree** panel (gui `tree`, see `view_tree.v`) renders the project's channels: one
   node per channel with an **enable checkbox** and a **state colour** (green = running/ok, red =
   bus-off or error frames seen, amber = warning, grey = disabled/stopped), expandable to per-channel
   stats (RX/TX/error-frame counts, bus load). It's the live front-end of Start/Stop (Phase 8): the
   checkbox sets `enabled`; the colour reflects measurement state. (CAN error frames come from
   SocketCAN's `CAN_RAW_ERR_FILTER`; vcan rarely emits them, so the wiring lands before real `can0`.)
10+. Scripting/sequences (conventional test cases), more panels/plotting; then LIN + Ethernet
   (DoIP/SOME-IP) backends behind the same `Bus`/`Channel` abstractions (see Platform support).
11. 🔜 **Simulation (networks + simulated ECUs)** — turn the tester into a conventional sim host:
   simulated ECUs and the tester's own functions all attach to shared **virtual networks** (the
   database lives on the network, not the ECU), in one process, **driver-free by default** (an
   in-process bus backend), with the Python SUT as the oracle that proves the native protocol stack
   first. Behaviour is **declarative-from-DBC** (an ECU sends the messages whose DBC transmitter is it,
   signals via simple generators + a config UDS server). Full design + phasing: **`docs/
   simulation_architecture.md`** (agreed 2026-06-07). Phase 1 = an `inproc:` `transport` backend.
   **DONE 2026-06-07 (Phases 1–3.5):** (1) `transport/inproc.v` — driver-free in-process bus
   (`open('inproc:CAN1')`, process-global hub, needs `-enable-globals`, now in run.sh); (2) `candb`
   exposes the transmitter node / ext / `GenMsgCycleTime` / `BU_` node list +
   `messages_from(node)`; (3) `modules/sim` — `Gen` signal generators (const/sine/sawtooth/counter/
   stepmod), `SimEcu`/`Engine` (cyclic `due_frames` + request/response `on_frame`, pure+testable,
   plus `run_for` live), and `sut_ecu()` the **native twin of `can_sut.py`** — **verified
   byte-for-byte against Python golden vectors** (the gate passed); (3.5) wired into the GUI:
   `simulate: [SUT]` on a channel spawns the engine on its own in-proc bus instance alongside the
   monitor, so the tester sees simulated traffic via the normal RX path. `projects/sim-demo.yml`
   runs the SUT ECU with **no Python, no vcan, no drivers** — verified in the GUI (Powertrain+Heartbeat
   @10Hz decoded live, Send 0x101→0x102 answered). **DONE (Phase 5 — diagnostics):**
   `isotp/software.v` — a pure-V ISO-TP state machine (SF + multi-frame FF/CF/FC) over any
   `transport.Bus`, so diagnostics work on the in-proc bus / Windows with no kernel CAN_ISOTP;
   `uds/server.v` — native UDS server (twin of `uds_server.py`: 0x10/0x22-RDBI/0x3E + negatives,
   17-byte VIN forces multi-frame). **Verified in-process** (no Python, no kernel ISO-TP):
   `uds.Client` ↔ `uds.Server` over software ISO-TP — session, single+multi-frame RDBI, tester
   present, negative response all pass. NEXT: wire the UDS server into a simulated node in the GUI;
   per-signal generator config in the project `.yml`; then LIN/Eth.

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

**Runtime dep — `zenity`** (apt: `zenity`): gui's `native_open_dialog` (used by the toolbar **Open
Log** button) has no GTK/portal of its own on Linux — it shells out to `zenity` (or `kdialog`). Without
it the bridge returns `.error` and the app silently falls back to the typed log-path box, so the file
picker just won't appear. Installed here (4.0.1); opens under WSLg fine (the `libEGL/MESA ZINK` warnings
it prints are benign GL-accel noise — the dialog still renders). Not needed on Windows/macOS (native
pickers there). `scripts/setup_env.sh` should install it alongside the dev libs.

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
  out of the box; `CANTESTER_LOG` env pre-fills the path. **gui's `native_open_dialog` is wired too**;
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
  stream **identically**, and all 60 frames decode against `cantester.dbc` (EngineSpeed 1913 rpm, etc.).
  Shipped `samples/demo.mf4` (un-ignored). Builds clean. NEXT MF4 step (when wanted): J1939 PGN-aware
  lookup in `candb` so the real CSS J1939 recordings decode; then a timed player onto vcan0.
- 2026-06-05: **Phase 9 foundation — project config + Buses panel + Start/Stop + File menu (slice 1).**
  New GUI-free `modules/project` (vlib `yaml`) parses a project `.yml` → `Project{channels[]}` (each
  with interface/bitrate/timing/mode/listen_only/enabled/databases/replay; defaults + built-in
  fallback; 6 tests). Ships `projects/demo.yml` (CAN1 vcan0 monitor + disabled CAN2 vcan1 replay). The
  app is now **config-driven**: it loads the project at startup (env `CANTESTER_PROJECT`) instead of
  hardcoding vcan0, and DBCs come from the channels (not the old `CANTESTER_DBC`). A global **Start/
  Stop** (top-left, conventional measurement lifecycle) opens/closes enabled *monitor* channels per
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
  format. Shipped `projects/demo-udp.yml`. **Verified on Linux:** `python3 sut/can_sut.py udp` +
  a V `transport.open('udp')` client interoperate — 0x100/0x700 received and decoded (EngineSpeed
  etc.). This same flow runs on Windows with zero drivers once the GUI builds (W1). Run:
  `python3 sut/can_sut.py udp` + `CANTESTER_PROJECT=projects/demo-udp.yml ./scripts/run.sh`.
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
  `MsgAgg`). Dev helpers: `scripts/shot.sh` + `CANTESTER_AUTOSTART=1` for the screenshot loop.
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
  Shipped `projects/replay-demo.yml` (loops samples/demo.log on `inproc:` — zero drivers).
  **Verified in the GUI**: 1 channel attached, green dot, trace streaming TX 0x100/0x700 decoded
  via the DBC, and the TX counter advanced 124 frames in 6 s ≈ the recording's exact 20 frames/s.
  Gotcha re-learned: `v ... | head` makes `$?` head's rc — the build had silently not rewritten
  build/cantester (stale Jun-8 binary, "0 channels attached") until rebuilt + timestamp-checked.
  NEXT (Phase 8 rest): per-channel transport-control UI (play/pause/seek/speed — player API ready);
  replay direct-to-trace sink (no bus) for offline review at cadence.
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
