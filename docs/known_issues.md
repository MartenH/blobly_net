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

- 🔴 **Native file dialog hangs the whole app under WSLg (XDG Desktop Portal) — FIXED via
  `GUI_NO_PORTAL`.** Symptom: opening *any* file requester (Open Log / Open Project / Add DBC(s)…),
  picking a file and pressing OK froze the entire app — the window could still be moved by the WM but
  every button was dead, and it had to be killed from the shell. Root cause (nailed by a `gdb`
  backtrace of the hung **main thread**): gui's native dialog prefers the **XDG Desktop Portal**
  (`org.freedesktop.portal.FileChooser`) over D-Bus when `gui_portal_available()` is true, and its
  `portal_wait_response()` (`nativebridge/portal_linux.c`) does a **synchronous 120 s D-Bus poll on the
  UI thread** for the `Response` signal — which never arrives under WSLg, so the UI thread wedges in
  `portal_wait_response → __poll` forever. It is **not** GC / fork / zenity related (all chased and
  ruled out — the dialog never reaches zenity when the portal is "available"); "it used to work"
  because older gui used the zenity backend. **Fix:** `gui-no-portal-fallback.patch` adds a
  `GUI_NO_PORTAL` escape hatch to `gui_portal_available()` (truthy → returns 0 → falls back to the
  working zenity backend; `0`/unset keep the portal). **The app auto-detects WSL** (`src/main.v`
  `is_wsl()` — `WSL_DISTRO_NAME`/`WSL_INTEROP` or `microsoft`/`wsl` in `/proc/sys/kernel/osrelease`)
  and sets `GUI_NO_PORTAL=1` there, so it works on any launch (not just `run.sh`); real Linux desktops
  keep the portal. An explicit `GUI_NO_PORTAL=0` (or `=1`) always wins. Requires **zenity** installed
  (already a runtime dep). Debugging note: `gdb`
  cannot *run* this Boehm app (ptrace breaks the GC's signal-based stop-the-world), but **attaching to
  an already-hung process to snapshot stacks works fine** — that's what cracked it. The process is
  named `main` (run.sh does `v run src/main.v`), so use `pgrep -f cantester_v/src/main`, not
  `cantester`. See `docs/v_patches/gui-no-portal-fallback.patch`.
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
- 🔴 **CRASH: only use glyphs the bundled font can OUTLINE in `gui.text`. Colour-emoji / unsupported
  glyphs crash the release build.** vglyph's glyph path (`glyph_atlas.v` `load_glyph`) requires a
  vector outline (`glyph.outline.n_points > 0`). A glyph the font lacks an outline for — a **colour
  emoji** (loaded as an embedded bitmap, e.g. `💾`) or a dingbat the bundled font doesn't carry
  (`✎` U+270E, `⚙` U+2699) — has `n_points == 0`. In a **`-g`/debug** build that hits an explicit
  `panic('FT_Outline_Translate requires loaded outline, got empty')`; in a **release** build the
  `$if debug` guard is compiled out, so it proceeds on the empty/bitmap glyph and **corrupts memory →
  `invalid memory access`, usually with a bogus deep `v_stable_sort` backtrace** (the backtrace is
  misleading — the real fault is the glyph). Symptom that bit us: the Generators panel's `💾 Save`
  button crashed `./build/cantester` for the user. **Rule: only use glyphs you've SEEN render in a
  screenshot.** Verified-safe set in this app: `▸ ▾ ● ＋ × … ▶` + the activity-bar icons
  `☰ ▽ ⊞ ⊙ ▷ ⌗ ∿ ▦ ➤ ⎍ ✚ Σ ╱`. Known-UNSAFE in the bundled font: `💾 ✎ ⚙`. (The toolbar's
  `🌙 📂 ⏺` happen to have outlines in this font, so not all emoji are unsafe — but don't assume; test.)
  Diagnose deterministically with a `-g` build: `v -g … && ./build/<app>_dbg` panics on the first bad
  glyph with the vglyph message. ⚠️ Caveat: a `-g` build also panics on a **pre-existing latent** empty
  glyph somewhere in the always-rendered UI (a whitespace/decorative glyph) — that one is benign in
  release (FT translate of 0 points is a no-op), distinct from the colour-emoji corruption above. The
  real upstream fix is the vglyph whitespace-glyph guard (captured in `docs/windows_build.md`); until
  it's applied on Linux, just avoid unsupported glyphs.
- 🟡 **An `on_click` `gui.row` used as a *row child* stretches and shoves its following siblings to
  the far right.** Everything is `fit` by default (`SizingType` zero value is `.fit`; `gui.text`
  single-line is `fit_fit`; `ContainerCfg.sizing` defaults to `fit_fit`), and the container honours
  `cfg.sizing` — yet a clickable `gui.row` (one with `on_click`) does NOT pack to content like its
  text/button siblings: it expands, pushing a trailing button (e.g. `⚙ Scaffold`, a channel `✕`) to
  the panel's right edge. Explicit `sizing: fit_fit` / `min/max_width` on that clickable row did NOT
  fix it. **Fix: don't make a `gui.row` clickable for a small glyph/label — use `gui.button`
  instead** (a button with `on_click` *does* size to content and packs left, as the `＋ DBC` / `✕`
  sub-row proves). See the Buses + Simulation node rows in `src/main.v` (enable ☑/☐ and the node-name
  expander are buttons, not on_click rows). A `tooltip`-only row (`on_mouse_move`, no `on_click`) does
  NOT stretch, so it's specifically the click handler. Report upstream.
- 🟡 **`gui.button` stays highlighted (focus colour) after a click.** A button's `amend_layout` paints
  `color_focus` whenever `w.is_focus(id_focus)` — and a clicked button keeps focus, so it reads as
  "stuck blue/pressed". Two fixes: (a) call `w.set_id_focus(0)` at the end of the click handler (used
  for the Send button), or (b) simplest for mouse-only action buttons, set **`id_focus: 0`** — since
  `is_focus()` is `id_focus > 0 && id_focus == arg`, `is_focus(0)` is *always false*, so the button is
  never painted focused (and still clicks fine via the mouse; it just isn't keyboard-tabbable). We use
  `id_focus: 0` on the Buses/Bus Config/Simulation action buttons. Keep real ids on inputs/selects.
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
- 🟡 **`xdotool` synthetic keyboard/middle-click input never reaches `gui.input` (WSLg).** Related to
  the above: when driving the app for automated verification (`scripts/shot.sh` workflow),
  `xdotool type` / `key` / middle-click-paste focus the input (it highlights) but no text arrives —
  sokol under XWayland doesn't see the synthetic XTEST key events. Mouse *clicks* (tab switching,
  buttons, checkboxes) DO work. Workaround for verifying input-dependent behaviour: temporarily seed
  the App-struct field default (e.g. `trace_filter2 string = '700'`), build to a throwaway binary,
  screenshot, revert — exercises the same render path without typing.

## Rendering stack (sokol / vglyph / GL)

- 🟠 **NEW 2026-06-13 — the leak is the `data_grid`'s per-cell `text_width` (vglyph layout
  build), NOT the glyph-render path, and it reproduces on native Windows (msys2/mingw) — so
  it is NOT Linux-only.** Full hunt on the W1 msys2 build: cantester leaks **~1 MB/s
  unbounded** (+460 MB / 8 min, **C-side** — survives forced `gc_collect`). Bisected with
  minimal gui repros: `cmd/mem_leak_repro` (changing text) = **flat** on Windows;
  `cmd/mem_leak_canvas` (draw_canvas polyline) = **flat**; **`cmd/mem_leak_grid`** (a gui
  `data_grid` of 30×8 cells) = **LEAKS ~2.5 MB/s — and *static* cells leak just as fast** (so
  it's NOT glyph-atlas churn; static = cache hits). Instrumented vglyph `prune_cache`: the
  layout cache **plateaus ~10k (eviction works)** and the glyph atlas stays **1 page** — both
  bounded. ⇒ the leak is **per `layout_text` (per `text_width` cache-MISS)**, which the
  data_grid triggers ~4 800×/s by re-measuring every cell every frame for column auto-sizing.
  Source-read every C object in vglyph's pango build path — `PangoLayout` (`g_object_unref`),
  font descriptions (×2 sites), attr lists, the layout iter, tab arrays — **all free
  correctly**, so it's a **subtle unfreed pango/glib allocation**, not an obvious missing
  `free`. **NEXT — do this on WSL** (Windows profiling is a dead end: Dr. Memory 2.6 crashes
  internally on Win11 build 26200; mingw/DWARF defeats the MSVC-symbol Windows tools):
  `valgrind --leak-check=full --show-leak-kinds=all` (or `heaptrack`) on `mem_leak_grid` with
  `MEM_REPRO=changing CANTESTER_RUN_MS=20000` → names the exact `pango_*_new`/`malloc` stack
  with real symbols ⇒ a high-value **vglyph PR**. Mitigation (no root cause needed): make the
  trace grid stop re-measuring unchanged cells (fixed/cached column widths). Repros:
  `cmd/mem_leak_grid`, `cmd/mem_leak_canvas` (both `MEM_REPRO=changing|static`).
- 🟠 **UPDATE 2026-06-13 (WSL valgrind+heaptrack hunt) — the leak is GC-managed V memory, NOT a
  nameable C/pango `free()`. The "valgrind will name a `pango_*_new` line" premise is REFUTED.**
  Ran the requested `valgrind --leak-check=full` and `heaptrack` on `cmd/mem_leak_grid`
  (`MEM_REPRO=changing`) plus direct RSS / `gc_memory_use()` / `/proc/<pid>/smaps` instrumentation.
  Findings, each independently cross-checked:
  - **It IS a real, unbounded leak on Linux/WSL** (refines the 2026-06-13 "doesn't reproduce"
    downgrade above — that was too few samples). Direct RSS climbs ~2–4 MB/s; over 185 s the
    `gc_memory_use()` **floor** rises monotonically (≈55→350 MB troughs) and keeps going — and it
    **survives a forced `gc_collect()` every 2 s** (51→221 MB at 90 s), so the retained memory is
    genuinely **reachable**, not GC lag.
  - **It is GC-managed V memory, not libc/C malloc.** `smaps` diff (early vs late): the **only**
    growing mapping is `[anon]` (+137 MB); `[heap]` (libc) is **flat**, and the `[anon]` growth
    tracks `gc_memory_use` (boehm heap) 1:1. heaptrack (which only sees libc malloc, not boehm's
    `GC_malloc`) confirms: leaked-allocation **count is flat** (~25 200 whether 10 s/396 frames or
    30 s/1481 frames) and a 30 s−10 s leak **diff is +9.7 KB total** (~0.5 KB/s). valgrind agrees:
    its only growing bucket is **"possibly lost"** (15.9 MB — boehm blocks reached via interior
    pointers); **"still reachable" 22.8 MB / 12 009 blocks ≈ the bounded layout cache** (below).
  - **The vglyph layout cache is correctly BOUNDED and IRRELEVANT.** Instrumented `ts.cache.len`:
    it plateaus at ~12 000 (age-eviction works). Dropping `eviction_age` 5000→1000 ms shrank the
    cache ~5× (≈2 580) but the **leak rate was unchanged** ⇒ the leak is **independent of cache
    size** — it accrues **per unique rendered string** (~600 B each, retained for process life),
    *outside* the cache, at layout-create/draw time. Clearing the evicted `CachedLayout.layout`
    before `delete` did **not** help (confirms it's not the cached Layout arrays being retained).
  - **Pure-V can't reproduce it ⇒ it's intrinsic to the real Pango+render path.** A minimal
    `map[u64]&Big` churn (12 000-deep window, fresh heap object/iter, even with embedded `voidptr`/
    C-pointer members and interior-pointer-rich arrays to mimic `Layout`/`Item`) is **FLAT** at
    13–31 MB over 5.8 M iterations. So it is **not** generic boehm/map-churn or conservative-GC
    false-retention — it requires the real `vglyph` glyph **render** path (reaffirms the 2026-06-07
    "vglyph renderer, not Pango layout, not the GL driver" diagnosis).
  - **The ONE real C leak valgrind found is one-time startup**, not the climb: 424 KB / 742 blocks
    `definitely lost` in `gui.initialize_fonts → vglyph.add_font_file → pango_fc_font_map_cache_clear
    → FcFontSetList` (fontconfig font-set not freed at init). Worth a tiny upstream fix, but it
    fires **once** and does not grow.
  - **`-gc boehm_leak` now builds — and says the memory is REACHABLE, not unreachable-leaked.**
    `v -gc boehm_leak` is the right tool (boehm find-leak + allocation backtraces; the local libgc
    *does* have `KEEP_BACK_PTRS`), but it failed to compile this GUI code via **two real V autofree
    codegen bugs** that also break plain `-autofree` — both **fixed locally in `~/v`** (see below).
    With those fixed, the boehm_leak build runs and reports **~0 unreachable-leaked objects at any
    runtime** (3 s and 9 s both → 0; only ~20 one-time startup bits like `gui__init`/
    `locale_register`) **while RSS still grows ~2 MB/s**. So the growth is **reachable to the GC**
    (matches "survives forced `gc_collect`") — no missing `free()`/`delete` will reach it.
  - **It is NOT interior-pointer false-retention** (`GC_ALL_INTERIOR_POINTERS=0` → +132 MB vs +127
    MB, no change), and the back-graph height is tiny (1–4 back-edges) ⇒ retained via **short,
    full-pointer chains** (≈1–2 hops from a root). Two candidate readings remain, both fit the data
    (reachable, full-ptr, short chain, per-unique-content with `static` flat, pure-V can't repro):
    (a) **conservative-GC false-retention** — stray heap/stack bit patterns (some f64 / glyph data /
    coords) alias live allocation base addresses and pin dead per-string Layout/render allocations;
    (b) a **genuine retained reference inside the C render state that boehm conservatively scans**
    (gg/sokol/Pango buffers holding a V pointer per draw). Pure-V churn can't reproduce it, so it
    needs the real Pango+`gg`/sokol render path either way. Both are **GC-precision / render-path**
    problems, **not a missing `free()`** — so the lever is reducing unique per-frame render work, not
    a deletion. Distinguishing (a) vs (b) needs the live-allocation/root dump noted below.
  - **Two V compiler bugs found+fixed (upstream candidates, in `~/v`, zero effect on normal
    `-gc boehm` builds — the changed code only runs under `-autofree`/`-gc boehm_leak`):**
    1. `parser/assign.v` — `x := f() or {…}`'s `is_or` flag (which tells autofree to skip the var,
       since C declares it *after* the `or` block) was set only under `pref.autofree`, not under
       `boehm_leak` (which also does scope-cleanup) → `free(&x)` emitted inside `x`'s own `or` block
       (`'result'/'head'/'new_text' undeclared`). Fix: also set it when `gc_mode == .boehm_leak`.
    2. `gen/c/autofree.v` — an early `return`/`continue` mid-scope freed vars declared *later* in the
       same scope (e.g. `vglyph.GlyphAtlas.grow_page`'s `new_staging_*`: `'new_staging_back'
       undeclared`). Fix: thread the cleanup position (`cur_pos`) into `autofree_scope_vars2` and
       skip any var with `obj.pos.pos > cur_pos`. (This one fixes plain `-autofree` too.)
  - **BISECTION (2026-06-13, `cmd/mem_leak_grid` via env-gated vglyph stubs + forced-GC `live=`
    probe, 30 rows / 30 s):** localized the leak by disabling render path stages one at a time:
    | variant | what runs | live MB growth/30s |
    |---|---|---|
    | baseline | full | **+90** |
    | no-draw (skip `renderer.draw_layout`) | layout build+cache, **no glyph render** | **+90 (identical)** |
    | no-layout (stub `text_width`/`draw_text`, no Pango) | gui tree machinery only | **+34** |
    | empty-layout (cache churn, `Layout{}` instead of Pango build) | cache, no build | +51 |
    | zero-evict (vmemset the evicted Layout's array backings) | full + zero on evict | **+90 (no change)** |
    Conclusions: **(1)** glyph rendering is NOT the leak (no-draw == baseline) — *refutes the
    2026-06-07 "vglyph renderer" diagnosis*. **(2)** It splits ~⅔ `text layout-build` (`layout_text`)
    + ~⅓ `gui per-frame tree machinery` (present even with all text stubbed). **(3)** It is NOT the
    *cached* Layout being stale-retained — zeroing evicted layout backings changed nothing. **(4)** It
    scales with row count (1→40 rows: +11→+105 MB) ⇒ per-rendered-cell.
  - **Verdict — conservative-GC retention of per-frame churn, not one freeable line.** On 64-bit,
    false-retention from *numeric data* is implausible, so this is **stale real pointers in
    churned/reused backing memory** that boehm scans — *exactly* the class gui's `gc.v` documents and
    fights (`array_clear`/`layout_clear`/`view_clear` zero backing because V's `.clear()` leaves stale
    pointers; there's even a `_gc_lint_test.v` enforcing it **for gui files only**). The residual leak
    is the transient pointer churn inside `vglyph.layout_text` (Pango iteration → per-run arrays/
    strings/hit-test rects, **no zeroing discipline in vglyph**) plus gui-tree-build churn. So it is
    **fixable only by pervasively applying the zero-on-free discipline through the hot path**
    (whack-a-mole), *not* by adding a single `free()`/`delete`. This is the structural tax of V's
    conservative Boehm GC under an immediate-mode GUI redrawing unique content every frame — the gui
    author building dedicated anti-false-retention tooling is itself evidence it's an ongoing battle in
    this stack, not a one-off bug.
- 🟢 **ROOT CAUSE NAILED 2026-06-13 — it is a V *closure* leak, not generic conservative-GC
  retention. (Supersedes the "whack-a-mole / structural tax" verdict above.)** Bisected with a
  fast headless harness (driving `gui.data_grid()` in a loop, no window — reproduces the leak at
  ~50 KB/call, linear to 3 GB) plus minimal isolations:
  - **`vglyph` is fully exonerated**: `Context.layout_text` in a loop is flat (RSS 17 MB/360k
    calls); real layouts churned through a bounded age-evicted cache plateau (~261 MB/1.6M).
  - A plain `column` of 30 `text()` rows is **flat**; the data_grid leaks. The one thing the
    data_grid does that text doesn't: it builds **23+ capturing closures per call** (event
    handlers; one captures the whole `rows` array).
  - **Minimal 20-line repro:** a loop creating `h := fn [big] (...)` that captures a heap array and
    dropping it → **live grows 0→2 GB linearly**; the identical loop *without* the closure is
    **dead flat**. ⇒ **a V closure that captures data is never reclaimed by the GC.**
  - **Mechanism (V source):** `gen/c/fn.v` allocates each closure's captured context with
    `memdup_uncollectable` (`GC_MALLOC_UNCOLLECTABLE`) — memory the GC never frees. It is reclaimed
    only by `closure_try_destroy` (`vlib/builtin/closure/`), which V emits **only for temporary
    closures passed straight to a call**, never for **stored** closures (gui event handlers in the
    view/Shape tree). So every per-frame stored closure permanently leaks its context, which roots
    its captured data. Confirmed: switching the context to collectable `memdup` drops the data_grid
    headless leak from **3 GB → 0**.
  - **Two V-side fixes were prototyped; both hit real Boehm walls (so the proper fix is a non-trivial
    V-runtime project, captured for upstream):**
    1. **`closure_try_destroy` + `GC_FREE` + gui calls it in `layout_clear`.** Validated *flat* on the
      minimal repro (single- and multi-threaded). But in the real gui it **double-frees**
      ("Duplicate large block deallocation") — gui pools/reuses `Layout`/`Shape` objects
      (`scratch_pools.v`), so a stale closure pointer can be destroyed after its slot was reused.
      (A second bug found+fixed en route: plain `free()` is a **no-op under `-gc boehm`** —
      `allocation.c.v` only frees under `gcboehm_leak` — so `closure_try_destroy` never actually
      freed; it must `GC_FREE`.)
    2. **Collectable context + register the trampoline pages as GC roots (`GC_add_roots`) +
      `try_destroy` clears the slot only (no `GC_FREE`, so double-free is impossible).** Validated
      flat + double-destroy-safe on the repro, but the real app **premature-frees** (crash in
      `v_stable_sort`'s comparator closure) — almost certainly Boehm's `GC_MAX_ROOT_SETS` cap
      silently dropping later page roots, so some contexts aren't scanned and get collected mid-use.
  - **✅ FIXED 2026-06-13 — frame-epoch closure reclamation.** Two earlier V-side attempts failed
    (GC_FREE → double-free with gui's transient sharing; collectable + per-page `GC_add_roots` →
    premature free, `GC_MAX_ROOT_SETS`). The working fix (`docs/v_patches/closure-gc-leak-fix.patch`
    + `gui-closure-reclaim.patch`):
    - **V:** closure contexts are now **collectable** (`memdup`), kept reachable for the GC via a
      scanned table `g_closure_live` (so a live closure's context is never collected). New API:
      `closure.begin_frame_build()`/`end_frame_build()` (frame-stamp closures created during a view
      build) and `closure.reclaim_frames(keep)` (drop everything `keep`+ frames old — clears the
      trampoline slot + the GC ref, no `GC_FREE`, so it's idempotent and can never double-free).
      Closures created outside a view build (app setup, event handlers) get a sentinel frame and are
      never auto-reclaimed.
    - **gui:** `window_update.v` calls `begin_frame_build()` → generate view → `end_frame_build()` →
      … → `reclaim_frames(2)` each `update()`. `keep=2` protects the current + previous frame's
      handlers. Contract: handlers must be created per-frame (immediate-mode norm).
    - **Validated:** data_grid headless went 3 GB → 0; the live GUI over 180 s / 3400 frames now has a
      **flat closure table (~2258)**, **bounded `live` (46–126 MB)** and **RSS plateaus (~401 MB)** —
      vs the unfixed linear climb (live → 364 MB, RSS → 803 MB). Closure correctness (sort/map/filter/
      captured, double-destroy) intact; no closure-test regression. Minimal repro:
      `docs/v_patches/closure_leak_repro.v`.
    - These are **upstream candidates for V + vlang/gui** (the leak hits any immediate-mode V GUI).
      Also kept: the two autofree/`boehm_leak` codegen fixes (`docs/v_patches/`).
  - **Mitigations (unchanged, all real):** lower trace fps; fewer unique strings (e.g. fewer
    timestamp decimals); Pause/Stop; cache/freeze column widths so the grid stops re-measuring.
  - **Windows caveat:** commit da3f79a called the Windows leak "C-side, survives `gc_collect`"
    (+460 MB/8 min). That was inferred from **RSS** — but boehm never returns freed pages to the OS,
    and the GC heap is anonymous (looks "C-side" in a process monitor), so RSS can't tell GC-heap
    growth from a true C leak. **Re-measure Windows with `gc_memory_use()` (live, post-`gc_collect`),
    not RSS**, before concluding it's a different (C) leak — on Linux the same symptom is GC memory.
- 🟡 **DOWNGRADED 2026-06-13 (was "🔴 DEFINITIVE libgallium" — REFUTED by a direct control).**
  The 2026-06-12 note below claimed the leak "IS the Mesa GL driver (`libgallium`) on the per-frame
  TEXTURED-draw path" — concluded from heaptrack symbols. That conclusion **does not survive a
  decisive control experiment**, and the claim is retracted. Two independent reasons:
  - **Plausibility:** `libgallium` is the shared core of *every* Mesa driver (llvmpipe/d3d12/iris/…)
    on WSLg — in the path of every GL app that draws text. A real 1.5–2 MB/s per-frame textured-draw
    leak there would be one of the most-reported WSLg bugs in existence. It isn't.
  - **`cmd/textured_control` (the control):** a pure-textured-draw app — a **static** in-memory
    texture uploaded ONCE, drawn as 30 quads at **changing positions** every frame (~60 fps),
    **no vglyph / no Pango / no text shaping** — i.e. exactly the path the note blamed, minus the
    glyph stack. **Result: RSS is FLAT** — 138→139 MB over ~2 800 frames (≈85 000 textured quads),
    hardware GL. If libgallium leaked on textured draws this would climb; it doesn't. So the
    rects-flat / text-climbs differential the note leaned on does **not** isolate Mesa — it merely
    swaps in vglyph's whole glyph-render path, which is the real variable.
  - **The original repro no longer reproduces the unbounded climb either** (same box, 2026-06-13):
    `cmd/mem_leak_repro` `MEM_REPRO=changing`, RSS sampled from `/proc/self|pid/status` — **hardware
    GL: flat** 226→228 MB over 90 s / 645 unique-string frames (≈0.02 MB/s drift); **software GL
    (llvmpipe): a bounded warmup** 188→215 MB in 20 s then ~215→225 decelerating (≈0.2 MB/s and
    falling — classic cache-fill plateau), NOT the claimed 273→521 MB / 2.7 min @ ~1.5 MB/s. At
    1.5 MB/s a 90 s run would have shown +135 MB; we saw +2 MB.
  - **Why the heaptrack story was wrong (again):** "bytes resident in libgallium at exit" is the GL
    driver's normal working set / caches, freed only on clean teardown — the *exact* mis-attribution
    already retracted on 2026-06-07 (see below). heaptrack symbols answer "where do un-freed bytes
    sit at exit", not "what grows unbounded over time"; only direct RSS-over-time answers the latter,
    and direct RSS is flat/bounded here.
  - **Honest current status:** there may be a **bounded** warmup cache-fill on the Linux text path
    (tens of MB, plateaus) — there is **no evidence** of an unbounded per-frame libgallium leak in
    the current environment (Mesa 25.2.8). If a long live session ever climbs unboundedly again,
    re-measure with **direct RSS over time**, reproduce in `cmd/textured_control` (textured, no text)
    to test Mesa, and only then trust a heaptrack attribution. Whatever the 2026-06-12 run saw, it is
    not reproducing, so a confirmed-driver-bug label is unsafe. Mitigations if it recurs: lower trace
    fps, Pause/Stop. Controls: `v -enable-globals -path "@vlib|@vmodules|modules" run
    cmd/textured_control/textured_control.v` (`REPRO_MODE=textured|textured_static|rects`, prints
    its own VmRSS); text path `cmd/mem_leak_repro` (`MEM_REPRO=changing|static`).
- 🟡 **(historical; its vglyph-renderer conclusion is REINSTATED — the 2026-06-12 libgallium
  "correction" that displaced it is itself refuted, see the 2026-06-13 downgrade above)** Memory
  grows when the trace shows *changing* values — diagnosed as vglyph rendering unique text strings
  (Pango/FreeType render path), NOT the GL driver and NOT our code. RSS was seen climbing ~1.5 MB/s
  whenever live values are on screen (sim/replay/live trace); FLAT when idle (event-driven refresh →
  no redraw). (Note: this ~1.5 MB/s climb also did not reproduce on the 2026-06-13 re-measure —
  treat the rate as environment/session-dependent, the *path* as the durable finding.) Final diagnosis
  **2026-06-07, by direct RSS measurement + minimal repros** (two earlier guesses were wrong — see the
  retraction note below). The evidence:
  - GC is **on** (boehm; `gc_collect()` works) and the **V heap is bounded** (`gc_memory_use()` ~16–50 MB
    flat). Not the GC, not our V allocations.
  - **Minimal repro `cmd/mem_leak_repro`** (a gui window redrawing 30 text rows ~7 fps, *no* CAN/sim):
    `MEM_REPRO=changing` (unique strings each frame) → **RSS climbs**; `MEM_REPRO=static` (fixed strings)
    → **RSS plateaus**. A third control — a `gg` app drawing only rectangles (no text) — stays **flat**.
    ⇒ the leak is the **text path**, and specifically rendering *new* strings (cache misses), not the GL
    draw path and not cantester logic.
  - heaptrack **diff** (changing − static) puts the extra allocations in
    `gui__layout_wrap_text → vglyph__Context_layout_text → vglyph__build_layout_from_pango →
    pango_layout_get_iter` — i.e. building a fresh Pango layout per unique string. The net-retained
    bytes are many small allocations in the Pango/FreeType/fontconfig layout path (changing numbers miss
    vglyph's by-text layout cache, so every redraw reshapes from scratch).
  - **⚠️ RETRACTION:** an earlier version of this note blamed the **Mesa/gallium GL driver** (heaptrack
    showed `libgallium` "leaked" via `_sg_gl_draw`). That was a **misread**: with `CANTESTER_RUN_MS`'s
    hard `exit(0)`, the GL driver's normal **working set** (freed only on clean teardown) is counted by
    heaptrack as "leaked". Run **directly**, the rects-only `gg` app's RSS is **flat** — the GL path does
    NOT leak. Lesson: trust **direct RSS over time**, not heaptrack-at-`exit(0)`, for driver/working-set
    questions.
  - **Cross-platform — ⚠️ VERIFIED it does NOT reproduce on native Windows (W1, 2026-06-06).** Matched
    4-min `cmd/mem_leak_repro` runs: **both** modes plateau after a ~30 s ramp; `changing` sits ~26 MB
    higher (bounded cache-fill) but its **post-ramp slope matches `static`** (~0.025 MB/s baseline
    drift). Data (Private MB): `changing` 162→196 (30 s)→201 (230 s); `static` 152→170 (30 s)→175
    (230 s). ⇒ the unbounded climb is **Linux-specific** — refutes the "probably leaks the same way" guess.
  - **NARROWED to vglyph's RENDERER, not Pango (2026-06-07, by isolation loops):** ruled the layout
    path OUT — a raw-Pango loop (`pango_layout_new`/`set_text`/`set_font_description`/`get_metrics`/
    `get_iter`, changing text) is **flat** at 14 MB over 250 k iters, and **vglyph's own
    `Context.layout_text`** in a loop (with *and* without width/wrapping) is **flat** at ~19 MB over
    200 k+ iters. The GUI leaks only because it also **renders** the layout. So the leak is in vglyph's
    **glyph render path** (`Renderer.draw_layout` → `get_or_load_glyph` → atlas/`FT_Load_Glyph`), which
    retains per-frame for *changing* content on Linux but not Windows. NOT Pango/fontconfig layout, NOT
    the GL driver, NOT our code. Pinpointing the exact retained allocation needs isolating the renderer
    with a GL context (follow-up); candidate: glyph-cache/atlas churn from sub-pixel-positioned variants
    as text shifts, or a per-draw allocation, that the Linux FreeType/atlas path doesn't free.
  - **Mitigations:** lower the trace repaint rate (toolbar 3/5/10 fps → fewer reshapes); Pause/Stop;
    restart long sessions. Reduce unique strings (e.g. fewer decimals on the live timestamp) to slow it.
    A real fix is in the Linux Pango/fontconfig path (or a vglyph workaround there) — and since native
    Windows is unaffected, the **production target is clear**; this mainly bites long WSL/Linux sessions.
  - Profiling: avoid a `-g` build (only draws 1 frame under WSLg). `CANTESTER_RUN_MS=N` exits cleanly.
    heaptrack diff: `heaptrack_print -d <static.gz> -a 1 -p 0 <changing.gz>`.
- 🟢 **SEPARATE cross-platform leak — undrained `queue_command` frames piling up — FIXED 2026-06-12.**
  Distinct from the vglyph one above (this is *our* code, and it bites **Windows** too, where vglyph is
  clean). `rx_loop`/`replay_loop` called `w.queue_command(fn [frames] …)` every flush; gui's
  `window.commands` list is drained only by the main loop's `flush_commands`, so **when rendering stalls
  (occluded/minimised window, or the "no window that renders anything" case) the commands pile up, each
  holding a clone of the batched frames** → unbounded RSS with no rendering. Isolation that pinned it:
  a **headless** sim + `record()`-style accumulation (no GUI) **plateaus** (trace/grouped/plot_hist all
  trim correctly) — so the data path is clean and the growth was purely the queued closures. **Fix:**
  frames go into a **bounded** `App.inbox` (drops oldest past `rx_inbox_cap`) and **at most one** drain
  command is ever pending (`drain_queued`); `drain_inbox` records them on the UI thread. Memory is now
  capped regardless of whether the UI is draining. (`src/main.v` `rx_loop`/`replay_loop`/`drain_inbox`.)
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

## CI (GitHub Actions — Windows)

`.github/workflows/windows.yml` builds the app on `windows-latest` (MSVC + vcpkg) and is
green + fast (cold ≈43 min, warm ≈2 min). Getting there hit three runner realities
(2026-06-09):

- 🔴 **V will NOT self-compile on the runner — CI must DOWNLOAD a prebuilt V.**
  `makev.bat` HANGS at `Compiling v_stage.exe with v_win_bootstrap.exe` (the bootstrap V
  *executing* V's codegen), independent of the bootstrap compiler (tcc **or** clang), the
  final compiler (tcc **or** MSVC, via `-msvc`), the disk (slow `C:` **or** fast `D:` with
  `TMP` there too), and Defender on/off — every combo timed out (we gave it up to 90 min;
  locally the same build is ~100 s, so it's the runner environment, not V-on-Windows). And
  there's no prebuilt to fall back on: V's newest *release* is `0.5.1` (2026-03-09), which
  PREDATES the `vlib/yaml` that `modules/project` imports → `cannot import module yaml`.
  **Fix:** build V locally (where it works) and have CI download it — the workflow pulls a
  zipped de365a1 V from this repo's **`v-toolchain`** release (`v-de365a1-windows.zip`,
  v.exe + vlib at the zip root). Re-mint that asset if the V pin ever moves.
- 🟡 **vcpkg builds pango/freetype FROM SOURCE on the runner** (it is *not* warm-cached on
  the image, contrary to assumption). Cache its binary archives
  (`VCPKG_DEFAULT_BINARY_CACHE` + `actions/cache`): cold ≈35 min, then restored in seconds.
- ⚪ **A `D:` + space in a step `name:` invalidates the whole workflow.** YAML reads
  `name: ... D: disk` as a nested mapping → "workflow file issue" / HTTP 422 on dispatch.
  Quote any step name containing a colon-space. (Bitten twice.)

## Our code (cantester)

- 🟢 **`candb.encode` rounding bug.** `i64(x + 0.5)` truncated negatives toward zero (`-4.5 → -4`),
  so `encode(-5.0)` produced `-4`. Caught by `candb_test.v::test_signed_negative`. Fixed with
  `math.round` (round half away from zero). Reminder: keep testing module logic in isolation.
- 🟠 **Headless launch crashes in `v_stable_sort` (no display only).** Running the GUI with no
  `DISPLAY` (`DISPLAY= ./build/cantester …`) logs `LINUX_X11_OPEN_DISPLAY_FAILED` then aborts with
  `v_stable_sort: invalid memory access` inside gui's degraded first render (the dump shows gui's
  View-State/struct-size stats). It reproduces on builds BEFORE the Trace/Graphics work too, so it's
  pre-existing and **display-only** — the app runs fine with a real display. Likely a gui/sokol
  failure path rendering with a half-initialised GL/state, not our logic. Separately found while
  here: V's `.sort(a.id < b.id)` on `[]candb.Message` (structs containing the `Signal.values` map)
  can fault — the Symbol Browser now sorts message *ids* (a plain `[]u32` sort) via an id→index map
  instead of moving the structs. Caveat: GUI launches from the agent shell are flaky (the harness
  kills the windowed process; headless runs execute), so verify GUI changes from an interactive shell.
