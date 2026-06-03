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
- 🟡 **`v test` mangles a `-path` with `|`.** `v -path "@vlib|@vmodules|modules" test modules/` fails
  (`/bin/sh: @vmodules: not found`, `modules: Permission denied`) because the test runner re-invokes
  `v` per file and the `|`-separated path leaks into a shell unquoted. Workaround: run `v test
  modules/<name>/` **without** `-path` — it resolves as long as the module's own imports don't need the
  local `modules` dir on the path (candb/sampledb tests are fine). This is what `scripts/setup_env.sh`
  does. For building/running (not testing), `-path` is still required (see the local-module note above).
- ⚪ **`cannot copy map: call move or clone`.** Assigning a `map` value into a struct field (e.g.
  `sig.values = vals`) errors — V won't implicitly copy a map. Use `vals.move()` (transfers ownership,
  cheap) or `vals.clone()` (deep copy) explicitly. Same applies when storing maps built locally.
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

- 🟢 **Blank/black window under WSLg — FIXED on Ubuntu 24.04 (Mesa 25.2.8).** Historically (22.04,
  Mesa 23.2) the GPU GL passthrough (d3d12) drew frames but never composited, so the window showed
  blank; the workaround was software GL (`LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe`). On 24.04
  with Mesa 25.x the d3d12 core-profile path works and our sokol app renders with **hardware GL**, so
  `scripts/run.sh` now defaults to hardware GL; pass `CANTESTER_SOFTWARE_GL=1` to force the software
  fallback. Verified 2026-06-03 (docs/gui_validation/phase5_dbc_decode.png).
- ⚪ sokol `LINUX_X11_QUERY_SYSTEM_DPI_FAILED` on launch → falls back to 96 DPI. Harmless.
- 🟢 **vglyph/sokol need many native dev libs** that aren't installed by default (freetype,
  harfbuzz, fribidi, fontconfig, pango, glib, dbus, atk, atk-bridge, atspi, GL, X11). Resolved by
  installing the full set (listed in CLAUDE.md → System dependencies). Packaging friction, not code.

## Environment (WSL2 / kernel)

- 🟢 **RESOLVED on Ubuntu 24.04 (Mesa 25.x): sokol hardware GL no longer crashes the D3D12 driver.**
  The migration worked — our app now runs on hardware GL (see the blank-window entry above). The
  investigation below is kept for the record (it explains *why* 22.04/Mesa 23.2 failed). Original
  2026-06-03 notes (it was NOT "broken WSL"):
  - **Hardware GL works**: `glmark2` renders its scenes fine on `D3D12 (Intel Arc 140T)`, no crash.
    `/dev/dxg` present, `glxinfo` shows GL 4.2 **Compatibility** profile, direct rendering Yes.
  - **App-specific failures:** `glxgears` (ancient fixed-function GL) → black; **our sokol app** →
    black + `D3D12: Removing Device` (GPU TDR reset, blacks out the Windows display; recover with
    `wsl --shutdown`).
  - **Root cause:** sokol requests a **GL 4.1 _core_ profile** context (sokol_app.h: defaults to 4.x +
    `GLX_CONTEXT_CORE_PROFILE_BIT_ARB`). Mesa 23.2's D3D12 driver only does the **compatibility**
    profile well; its **core-profile** path is buggy and crashes the device. glmark2 works because it
    uses the compatibility profile.
  - **Likely fix:** newer Mesa (kisak-mesa PPA → 24.x) where the d3d12 core path is much improved —
    *userspace only, no kernel change*. (Kernel is fine: `CONFIG_DXGKRNL=y`, config-wsl based. The
    `CONFIG_UDMABUF`/dzn-Vulkan gaps are real but not the cause, since glmark2 already composites.)
    Forcing compat via `MESA_GL_VERSION_OVERRIDE` is unreliable because sokol hard-requests the core
    profile mask; patching sokol's profile request is the other (invasive) option.
  - **⚠️ Each hardware-GL test of our app resets the GPU (TDR) and blacks out the display.** Only
    retest deliberately, ideally right after a `wsl --shutdown`.
  - **Newer Mesa on 22.04 is a dead end:** kisak-mesa PPA dropped jammy (InRelease only, no packages),
    so 22.04 is stuck at Mesa 23.2. To get Mesa 24.x (improved d3d12 core path → likely fixes our app's
    hardware GL), move to **Ubuntu 24.04** (ships Mesa 24.x natively). The custom CAN kernel still
    applies — WSL2 shares one kernel across all distros (`.wslconfig`), so only userspace changes.
  - **Verdict (for now):** keep `LIBGL_ALWAYS_SOFTWARE=1` (llvmpipe) — stable, fine for this 2D app
    (60fps, 1000+ widgets). Hardware GL is optional polish; revisit on Ubuntu 24.04.
    `scripts/run.sh` honours `CANTESTER_SOFTWARE_GL=0` to retry hardware after a Mesa upgrade.


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
