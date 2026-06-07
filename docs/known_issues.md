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
  **When a module's test DOES need the local path** (e.g. `mf4` imports `transport`+`canlog`), use a
  `:`-separated path, which survives the unquoted shell because `:` isn't a metachar:
  `v -path '@vlib:@vmodules:modules' test modules/mf4/mf4_test.v` — green where the `|` form dies.
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
- 🟡 **Centered text doesn't render — `gui.button` labels come out blank when wider than the text.**
  A `gui.text` whose container centers it on the main axis (`h_align: .center`) draws *nothing* on our
  pinned gui. Because `gui.button` hard-defaults its content to centered (`ButtonCfg.h_align = .center`),
  **a `gui.button` with a text label renders as an empty box whenever its width exceeds the label**
  (toolbar buttons render because their row packs them to content width). Confirmed on BOTH WSLg and
  **native Windows** (GL), so it's a gui bug, not a rendering-stack one. Left-aligned text always renders.
  **Cleanest fix (preferred): you CAN use `gui.button` in panels — just pass `h_align: .left` so the
  label draws, and cap the width with `min_width`/`max_width` (a button in a `fill` column otherwise
  stretches full-width — "very long"). See the Send control in `src/main.v` (`gui.button` with
  `h_align: .left`, `min_width`/`max_width: 90`).** This supersedes the older workaround (a hand-styled
  clickable `gui.row`), which also worked but used hardcoded colors so it didn't follow the theme. NOTE:
  a fit-sized (`sizing: fit_fit`) lone row child does NOT shrink to content here — use `min/max_width`.
  Worth reporting upstream / checking on a gui bump.
- 🟢 **Screenshotting the running app for visual verification.** `import -window <wid>` (ImageMagick)
  + `xdotool search --name CANTester` capture the live window under WSLg — invaluable when iterating
  on layout you can't otherwise see. Set `XCURSOR_THEME=Adwaita XCURSOR_SIZE=24` first. Caveats: pick
  the newest window id (`| tail -1`) since stale `v run`/`src/main` instances linger (kill by
  `ps -eo pid,args | grep -E 'cantester|src/main'`, NOT `pkill -f build/cantester` — that matches your
  own shell and kills it); and xdotool clicking is unreliable (title-bar offset), so screenshot, don't
  drive. **`scripts/shot.sh [out.png]`** wraps the whole capture (search newest wid + `import`). For a
  deterministic *live-data* loop, launch with **`CANTESTER_AUTOSTART=1`** (begins measurement on launch,
  so the trace is populated without a Start click). Clicking that DOES work for toggling views/expanding
  rows: `xdotool windowfocus $wid` then `mousemove --window $wid X Y click --window $wid 1` —
  `windowactivate` is what fails under WSLg, `windowfocus` succeeds.
- 🟡 **Keyboard copy/paste/cut/undo don't fire in `gui.input` on Linux/X11 (incl. WSLg).** The
  clipboard itself is fine — V's `clipboard` module round-trips and the WSLg bridge works both ways
  (`printf X | clip.exe` → `cb.paste()` returns X; `to_clipboard` → `powershell Get-Clipboard` sees
  it). The break is in **key-event matching**: `view_input.v` handles paste in its `on_char` branch as
  `event.modifiers == .ctrl && char_code == ctrl_v` where `ctrl_v = 0x16` (the SYN control code that
  Windows/macOS deliver for Ctrl+V). But **sokol's X11 backend ignores `XLookupString`'s string**
  (`sokol_app.h`: `XLookupString(&ev->xkey, NULL, 0, &keysym, NULL)`) and derives the char from the
  *keysym* via `_sapp_x11_keysym_to_unicode` — so Ctrl+V arrives as `char_code = 0x76` ('v') + ctrl
  modifier, which never matches `0x16`. Same for ctrl+c/x/z and data_grid Ctrl-C copy
  (`view_data_grid_events.v` also tests `char_code == ctrl_c`). This is upstream (gui/sokol), in the
  pinned `~/.vmodules/gui` (NOT in our repo), so a local edit wouldn't be tracked or survive a gui
  reinstall — the real fix is upstream (match `ctrl + base-letter` too, or read `XLookupString`'s
  buffer). **Workarounds:** (1) the toolbar **Open Log** uses the native file picker (zenity), so you
  don't need to paste a path; (2) middle-click paste / typing still work. If keyboard paste in our
  inputs becomes important, add an `on_key_down` shim on those inputs that calls `gui.from_clipboard()`
  on Ctrl+V and rewrites the bound state.

## Rendering stack (sokol / vglyph / GL)

- 🟠 **Memory grows while redrawing under WSLg — it's the Mesa/gallium GL driver, not our code.**
  RSS climbs ~1–1.5 MB/s whenever the app redraws with live data (sim/replay/live trace); FLAT when
  idle (event-driven refresh → no redraw → no growth). **Pinned by heaptrack + valgrind massif
  (2026-06-07)** — earlier guesses (V heap / vglyph) were WRONG:
  - GC is **on** (boehm; `gc_collect()` works) and the **V heap is bounded** (`gc_memory_use()`
    oscillates ~42–66 MB). So it is **not** the GC and **not** our V allocations.
  - heaptrack's **leaked-memory** stacks are almost entirely `libgallium-25.2.8` (Mesa's GL driver)
    reached through the per-frame draw path: `_sg_gl_draw ← _sgl_draw ← sokol__sgl__draw ←
    gg__Context_end ← gui__frame_fn` — i.e. sokol's draw call into the GL driver, which allocates per
    draw and never frees. ~45 MB leaked over ~250 k draw-path calls in a 22 s / 1237-frame run.
  - Reproduces on **both** software GL (llvmpipe) **and** hardware GL (d3d12) — both go through Mesa
    gallium. (The vglyph fontconfig/Pango calls heaptrack also showed are **temporary** —
    allocated+freed — not the leak; the one 8.4 MB `vglyph__new_atlas_page` is the one-time glyph-atlas
    texture, not growth.)
  - **DECISIVE isolation:** a throwaway ~30-line `gg` app drawing 40 rectangles/frame — *no* cantester
    code, *no* vglyph, *no* text — **also leaks ~27 MB in libgallium in 18 s**, stack entirely Mesa.
    So it is the **bare sokol→Mesa GL draw path**, independent of our app and of text rendering.
  - **Production note (don't over-claim "it's just the environment"):** sokol and Mesa *are* production
    libraries — but sokol here is only the *caller* (a standard `glDraw`); the bytes are allocated and
    held *inside Mesa's GL driver*. WHICH GL driver runs is platform-specific: WSLg → **Mesa**
    (llvmpipe/d3d12, leaks here); native **Linux** desktop → also **Mesa** (iris/radeonsi) so it
    **could** leak too; native **Windows** → the GPU vendor's OpenGL ICD (not Mesa) → different code
    path, **unverified**; macOS → Apple GL. Since *both* Mesa backends leak, it's likely in shared
    Mesa/gallium code or a sokol draw pattern Mesa mishandles — **not** safely "WSL-only."
  - **To nail it / next steps:** (1) Mesa **dbgsym** to resolve the `libgallium` `???` frames →
    name the function (gallium-core `st_*`/`util_*` vs a backend) — needs the ddebs repo (`apt update`
    + write `/etc/apt`), which the scoped sudo here can't do; (2) test the **native Windows (W1)** build
    — the empirically decisive one for the deploy target; (3) file the **minimal `gg` repro** upstream
    (sokol or Mesa). Mitigations meanwhile: lower trace fps (3/5/10), Pause/Stop, restart long sessions.
  - Repro/profile: build `-g` makes the window draw only 1 frame under WSLg (avoid `-g` here); profile
    the normal build: `CANTESTER_RUN_MS=22000 heaptrack ./build/cantester` then
    `heaptrack_print -l 1 -p 0 -a 0 <file>`. `CANTESTER_RUN_MS=N` exits cleanly for the profiler.
- 🟢 **Blank/black window under WSLg — FIXED on Ubuntu 24.04 (Mesa 25.2.8).** Historically (22.04,
  Mesa 23.2) the GPU GL passthrough (d3d12) drew frames but never composited, so the window showed
  blank; the workaround was software GL (`LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe`). On 24.04
  with Mesa 25.x the d3d12 core-profile path works and our sokol app renders with **hardware GL**, so
  `scripts/run.sh` now defaults to hardware GL; pass `CANTESTER_SOFTWARE_GL=1` to force the software
  fallback. Verified 2026-06-03 (docs/gui_validation/phase5_dbc_decode.png).
- ⚪ sokol `LINUX_X11_QUERY_SYSTEM_DPI_FAILED` on launch → falls back to 96 DPI. Harmless.
- 🔴 **Each repaint is ~100ms of CPU under WSLg → live updates must be rate-limited.** Profiling the
  running app (measure *instantaneous* CPU via `/proc/<pid>/stat` utime+stime delta, NOT `ps %cpu`
  which is a lifetime average that ramps): idle ≈ 2%, but with the SUT feeding ~40 frames/s the app hit
  **~147%**. Root cause isn't our code — a `-cc gcc -cflags -O2` build was just as heavy as the TCC one,
  so it's the **GL frame submission under WSLg's GL translation** (d3d12/zink), ~100ms per frame vs
  ~5ms on native. The trap: `w.queue_command` (the cross-thread bridge) **forces a full GL frame per
  call**, so one wake per CAN frame = bus-rate repaints = CPU meltdown. CPU scales linearly with the
  *repaint* rate (measured: 2fps→22%, 5fps→45%, 10fps→107%), independent of `update_window`. **Fix:**
  `rx_loop` batches frames thread-locally and wakes the UI once per `rx_flush_ms` (200ms ≈ 5fps),
  decoupling repaint rate from bus rate — every frame is still recorded. On real hardware (cheap GL) the
  cap could be much higher. User clicks (Send, row-select) repaint immediately — only the live RX stream
  is throttled — a toolbar **dropdown picks 3/5/10 fps** (`App.fps`, default 5 ≈ ~45% of one core here;
  3 ≈ ~30%, 10 ≈ ~107%). `-prod` builds fail on a
  vglyph warning-as-error (FT_GlyphRec cast), so use `-cc gcc -cflags -O2` for an optimized build (won't
  help this, but helps compute paths). **Where the per-frame cost goes** (measured by swapping the trace
  `data_grid` for a trivial text view at 3fps): grid ≈ ~1/3 (30%→19%), the other ~2/3 is the GL-frame
  floor + recomposing every panel each frame (gui immediate-mode rebuilds the whole view tree regardless
  of what changed — there's no subtree memoization). So no single cheap win; the fps cap is the lever,
  and a native (non-WSLg) build with real GL would be far lighter. In Win11 Task-Manager terms (÷ logical
  cores, 16 here) ~30%/core ≈ ~2%.
- 🟡 **Mouse pointer disappears over XWayland windows (WSLg-wide, not ours).** Symptom: the pointer
  vanishes while hovering a Linux GUI window but the Windows desktop cursor is fine. **Confirmed
  WSLg-wide** (2026-06-04): it's gone over `xeyes`/`glxgears` too, not just our sokol app, and is
  independent of GL mode — `CANTESTER_SOFTWARE_GL=1` doesn't help, nor does pinning
  `XCURSOR_THEME`/`XCURSOR_SIZE` (a red-herring fix we tried and reverted; the cursor theme install
  that pulled in Adwaita via zenity correlated in time but is not the cause). Nothing in this repo can
  fix it. **Fix = restart the WSLg session from Windows:** `wsl --shutdown` (PowerShell/cmd), then
  reopen the distro; run `wsl --update` first if it persists. It's a known WSLg/WSLg-compositor
  glitch, occasionally triggered by suspend/resume or display changes.
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

## Windows (native build — W1)

Full recipe + vendored-patch manifest: **`docs/windows_build.md`**. The headline
gotchas (first-ever native Windows run of vlang/gui, 2026-06-05):

- 🟡 **Smart App Control blocks locally-built unsigned exes.** If SAC is *enforced*
  (`HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState==1`),
  freshly built `cantester.exe` is hard-blocked ("An Application Control policy has
  blocked this file"). No per-app allowlist, won't trust self-signed certs → native
  dev needs SAC turned **Off** (Settings → Windows Security → App & browser control),
  which is **irreversible** (re-enable needs a Windows reset). V/tcc themselves run;
  only no-reputation app binaries get blocked, per-hash, sometimes a few builds in.
- 🟡 **V's `v.pkgconfig` doesn't relocate a `.pc` `prefix=`.** mingw `.pc` files say
  `prefix=/mingw64`; system `pkgconf` redefines it to the real relocated root but
  V's built-in resolver doesn't → bogus `-I/mingw64/...` and "Cannot find freetype2".
  Fix: feed the system `pkgconf`'s flags via `-cflags`/`-ldflags` (`scripts/build_win.ps1`).
- 🔴 **gui requires the sokol GL backend (its shaders are GLSL-only).** On D3D11 the
  HLSL compiler rejects gui's GLSL (`error X1504: invalid preprocessor command
  'version'`). Native Windows uses `SOKOL_GLCORE` (V's default). D3D11 would need a
  gui-side HLSL shader port — deferred; not needed for perf (native GL idle ≈0.3% CPU,
  the WSLg GL-translation tax is gone). NOTE: V's sokol glue also never wired D3D11 at
  all (`glue_environment`/`glue_swapchain` only do metal/gl) — an upstream V bug
  documented in `windows_build.md` for when gui gains HLSL shaders.
- ⚪ **gcc 16 strictness + gui's untested Win32 C bridge.** `nativebridge/*_windows.c`
  needed `#define COBJMACROS` (before `<d3d11.h>`) and `<stdio.h>`/`<wchar.h>` (for
  `_snwprintf`) to compile; vglyph's debug build panicked on whitespace glyphs
  (`outline.n_points==0`). All patched (see the manifest).
- ⚪ **No console output from the GUI exe when piped/redirected.** It's a console-
  subsystem app, but stderr is fully buffered to a pipe/file and a C `abort()`
  discards the buffer → silent exit. Run it in a *real* terminal (unbuffered) or under
  `gdb` (mingw gdb) to see panics/sokol logs; `gdb -ex run -ex bt` was the workhorse
  for this bring-up.
- 🔴 **The window's [X]/close button doesn't quit the app on Windows.** Clicking the
  title-bar close (or otherwise hitting `WM_CLOSE`) doesn't terminate the process — only
  **File ▸ Exit** (`sapp.quit()`) does. So instances linger and pile up (kill via Task
  Manager or `Stop-Process -Name cantester`). Almost certainly sokol/gui not wiring
  `WM_CLOSE`→quit on the Win32 backend (untested there). TODO: handle the close/quit
  request (sokol `sapp_request_quit`/`on_event .quit_requested`, or a Win32 `WM_CLOSE`
  hook) so the X closes the app. Not seen on Linux/X11.

## Our code (cantester)

- 🟢 **`candb.encode` rounding bug.** `i64(x + 0.5)` truncated negatives toward zero (`-4.5 → -4`),
  so `encode(-5.0)` produced `-4`. Caught by `candb_test.v::test_signed_negative`. Fixed with
  `math.round` (round half away from zero). Reminder: keep testing module logic in isolation.
