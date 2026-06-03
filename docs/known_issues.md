# Known issues & gotchas (by layer)

Categorized so we always know **whose** problem a given symptom is — our code, the V compiler,
vlang/gui, the rendering stack, or the environment. Update as we hit (and fix) things.

Status key: 🔴 open · 🟡 worked around · 🟢 fixed · ⚪ benign/expected

---

## V language / compiler / tooling

- 🟡 **Local module not found.** `import candb` (a module under `./modules/`) fails with
  `cannot import module "candb" (not found)` when compiling a file in `cmd/…`. V's `-path`
  *replaces* the default lookup order, so the working incantation re-lists the defaults:
  `v -path "@vlib|@vmodules|modules" run <file>`. Baked into `scripts/run.sh`. Plain `v run`
  on a file that imports a local module will fail without it. (Tooling ergonomics, not a bug.)
- ⚪ `draw_canvas.version` is `u64` — passing an `int` errors (`cannot assign … expected u64`).
  Just cast: `version: u64(app.ticks)`.
- 🟡 **C interop parse friction.** `&char(s.str)` cast and no-arg C funcs used inside an expression
  (`(x & C.mask()) | …`) both gave `unexpected token )`. Fixes: pass `s.str` to a `&u8` C param;
  define stable C constants (e.g. CAN flag masks) as V `const`s instead of calling C accessors.
  For larger C surfaces, generate bindings with **c2v** (https://github.com/vlang/c2v) rather than
  hand-writing — keep the hand shim only for tiny surfaces (like `modules/transport`'s ~40 lines).

## vlang/gui

- ⚪ **data_grid columns are fixed px width and clamp to `max_width` (default 600).** They don't
  auto-stretch to fill the container. To make a column fill: compute its width from the window size
  AND raise its `max_width` (we set 4000). Also, column widths are cached per grid `id` and ignore
  later `cfg.width` changes — so for responsive re-flow we fold the window-width bucket into the grid
  `id` (`trace_grouped_${w/25}`), which refreshes the cache on resize. See `src/main.v`.
- ⚠️ **An always-on animation timer can block interactive column resizing.** We originally drove the
  ~20fps redraw with a re-arming `TweenAnimation`; that appeared to interfere with header drag-resize.
  Fixed by refreshing event-driven instead: the RX thread hands frames to the UI via
  `w.queue_command(...)` (the sanctioned cross-thread bridge) which calls `update_window()`. No timer,
  no mutex (all state mutates on the UI thread). Resize should be re-tested by the user.
- 🟢 **`gui.input` stretches vertically inside a `fill_fill` container.** Its interior is a
  `fill_fill` row with no intrinsic height, so in a filling column/panel the field balloons into a
  huge box. The clean fix: give the input an explicit **`height`** + **`sizing: gui.fixed_fixed`** +
  a tight **`padding`** (the theme's default `padding_medium` is too tall for ~32px and clips the
  text). Working values: `height: 34, padding: gui.Padding{4, 8, 4, 8}, sizing: gui.fixed_fixed` —
  text renders centered, no clip. (`max_height`-only clamps the box but mis-positions/clips the text.)
  See `send_panel` in `src/main.v`. Note: `gui.Sizing` is `{width, height}` (e.g. `fill_fit` =
  fill-width, fit-height).
- 🟡 **data_grid detail rows are fixed to one row's height.** `on_detail_row_view` content is placed
  in a container hard-coded to `height: row_height` (`view_data_grid_rows.v:51`), so multi-line detail
  content overflows and overlaps the next row. Use it only for single-line detail. For our expandable
  trace we instead **insert signal rows as normal grid rows** under the frame (toggled via
  `on_selection_change` + `active_row_id`), which reflows correctly. See `src/main.v` grouped view.

## Rendering stack (sokol / vglyph / GL)

- 🟡 **Blank/black window under WSLg.** Default GPU GL passthrough (d3d12) draws frames but never
  composites — window shows blank despite thousands of frames drawn. Fix: force software GL
  `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` (in `scripts/run.sh`). sokol/WSLg interaction.
- ⚪ sokol `LINUX_X11_QUERY_SYSTEM_DPI_FAILED` on launch → falls back to 96 DPI. Harmless.
- 🟢 **vglyph/sokol need many native dev libs** that aren't installed by default (freetype,
  harfbuzz, fribidi, fontconfig, pango, glib, dbus, atk, atk-bridge, atspi, GL, X11). Resolved by
  installing the full set (listed in CLAUDE.md → System dependencies). Packaging friction, not code.

## Environment (WSL2 / kernel)

- 🔴 **Hardware GL is broken on this WSL → we use software GL (llvmpipe).** Investigated 2026-06-03:
  - The GPU *renders*: `/dev/dxg` present; `glxinfo` shows `direct rendering: Yes`, renderer
    `D3D12 (Intel Arc 140T)`, GL 4.2. So it's not "no GPU."
  - But accelerated GLX content **never composites** — `glxgears` on hardware GL is solid black (not
    app-specific), and our app on hardware GL logs `D3D12: Removing Device` + `invalid memory access`
    (Mesa's d3d12 driver crashes the device after ~110 frames).
  - **Vulkan hardware path missing** too: after installing `mesa-vulkan-drivers`, the only working
    Vulkan device is `llvmpipe` (software); the real GPU ICD (dozen/D3D12→Vulkan) isn't present, so
    Zink can't run.
  - Root cause: incomplete WSLg GPU userspace — `/usr/lib/wsl/lib` only has `libd3d12*.so` (a standard
    WSLg also ships the Mesa GL frontend + a dzn Vulkan ICD there). This is the "non-standard WSL"
    missing rendering bits.
  - Kernel side looks complete: `CONFIG_DXGKRNL=y`, `/dev/dxg` works, config is `Microsoft/config-wsl`
    based (i.e. stock-equivalent). `CONFIG_UDMABUF` is off (no `/dev/udmabuf`) — candidate fix for the
    no-composite, but stock config-wsl also has it off, so unproven. The `Removing Device` crash is a
    *userspace/host-GPU* failure, not a missing kernel module — a kernel rebuild alone won't fix it.
  - Most-likely real cause: **Mesa 23.2.1 (Ubuntu 22.04) is too old for the Intel Arc 140T (2024+ GPU)**
    under WSL D3D12 passthrough. Highest-likelihood fix = newer Mesa (kisak-mesa PPA → 24.x). Other
    levers: `CONFIG_UDMABUF=y` (cheap, low odds), pick the NVIDIA GPU instead, standard WSLg.
  - **⚠️ Do NOT re-test hardware GL casually:** the device-removal crash resets the host GPU (TDR) and
    blacks out the Windows display(s); recover with `wsl --shutdown`. Retest only deliberately.
  - **Verdict:** keep `LIBGL_ALWAYS_SOFTWARE=1` (llvmpipe) — stable, fine for this 2D app (60fps with
    1000+ widgets). `scripts/run.sh` honours `CANTESTER_SOFTWARE_GL=0` to try hardware once env is fixed.


- 🟢 **`vcan` "won't load" was a non-issue.** `modprobe vcan` → ENOEXEC because the stale `.ko` in
  /lib/modules predates the running kernel (custom WSL2 build). BUT the running kernel has
  `CONFIG_CAN_VCAN=y`, `CONFIG_CAN_RAW=y`, `CONFIG_CAN_ISOTP=y` — all **built-in** (verified via
  `/proc/config.gz`). So no modprobe is needed at all:
  `sudo ip link add dev vcan0 type vcan && sudo ip link set up vcan0` just works. The `.ko` is
  irrelevant; ignore it. `scripts/setup_vcan.sh` no longer calls modprobe.

## Our code (cantester)

- 🟢 **`candb.encode` rounding bug.** `i64(x + 0.5)` truncated negatives toward zero (`-4.5 → -4`),
  so `encode(-5.0)` produced `-4`. Caught by `candb_test.v::test_signed_negative`. Fixed with
  `math.round` (round half away from zero). Reminder: keep testing module logic in isolation.
