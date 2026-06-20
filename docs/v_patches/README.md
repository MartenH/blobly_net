# Local V + gui patches (upstream candidates)

> **✅ 2026-06-19 — THE CLOSURE LEAK FIX IS NOW UPSTREAM. `closure-gc-leak-fix.patch`
> and `gui-closure-reclaim.patch` below are SUPERSEDED** and are no longer applied on
> Linux. GGRei's cleaned-up version merged as **[vlang/v#27483]** (closure `Lifetime`
> API, merge `1a2d0e5b`) + **[vlang/gui#62]** (uses it in `Window.update()`, merge
> `7a20a6ac`). Adoption: **V** = master via `setup-v check-latest` (has the API);
> **gui pin** bumped `68b9302 → 7a20a6ac` (Linux ci.yml + local dev). Validated:
> cantester builds with NO closure patches and live RSS plateaus ~330 MB (was
> unbounded). The gcc-16 C-bridge patches (`01`/`02`) are also upstream at that pin
> now (native-Windows work) — only `03-titlebar`, `06-sample-count`,
> `gui-window-resize`, and the vglyph patches remain. **Windows CI/build stays on
> `68b9302`**: its prebuilt `de365a1` V predates the closure API, so gui#62 won't
> compile there until a master-built V Windows asset is minted — and the leak is
> Linux-only, so Windows loses nothing. The two patch files are kept for history /
> the old Windows pin.

Patches found/applied while hunting **and fixing** the data_grid memory leak (see
`docs/known_issues.md` → Rendering stack, 2026-06-13). Three patches:

> **Design note:** `RFC_closures.md` argues the *end-state* fix — make V closures GC-visible (fat
> `{fn, …captures}` values; trampoline synthesised only at the C-FFI boundary, à la Go/Rust), which
> eliminates the stored×high-churn leak class structurally and removes the manual reclaim API below.
> The patches here are the **interim** fix that works under the current closure ABI.

## `closure-gc-leak-fix.patch` — THE LEAK FIX (V: `closure.c.v` + `gen/c/fn.v` + `markused.v` + `cgen.v`)

> **2026-06-14 — now mirrors upstream PR [vlang/v#27446].** This patch is regenerated from the PR
> branch `fix-closure-context-leak` (base `ed17e5fb`) and bundles all six commits' closure work,
> including three review-hardening fixes added while addressing Codex review:
> (1) **clear the live-map value before `delete`** (map.delete zeroes only the key; the GC-scanned
> value slot lingered, keeping `ctx` rooted); (2) **thread-local frame-build state**
> (`g_closure_frame`/`g_closure_in_build` are `@[thread_local]` so a worker-thread closure created
> during the UI thread's frame build is never wrongly reclaimed); (3) **owner-scoped reclamation**
> (each frame-stamped closure records an owner id; `reclaim_frames` only collects its own). Fixes 1–3
> matter to this app (our rx/sim/gen worker threads create `queue_command` closures during UI frame
> builds). **Known deferred follow-up:** the idempotent-destroy guard doesn't detect a stale
> double-destroy after a trampoline slot is reused (needs a per-slot generation counter) — tracked on
> the PR, out of scope here, and harmless for single-handle usage. **`~/v` tracks the PR branch
> directly** (HEAD `641b093` + the three fixes as a working-tree delta), so it is no longer at the old
> `de365a1` pin — see CLAUDE.md "Pinned versions".

Fixes the root cause: **V never reclaimed captured closure contexts** (allocated `memdup_uncollectable`,
freed only for temporary closures), so an immediate-mode GUI that rebuilds capturing event handlers
every frame leaked them unboundedly. The fix makes closure contexts **collectable** and keeps each live
closure's context reachable via a GC-scanned table (`g_closure_live`), and adds a **frame-epoch
reclamation** API:
- `closure.begin_frame_build()` / `end_frame_build()` — mark a frame's view build; only closures
  created in that window are eligible for reclamation (app-setup / event-handler closures are left
  alone).
- `closure.reclaim_frames(keep)` — reclaim closures created `keep`+ frames ago (clears the trampoline
  slot, drops the GC ref → the GC collects the context). Idempotent; never double-frees.
- `closure.try_destroy(c)` — reclaim one closure immediately (still used by V for temporaries).

Apply with `gui-closure-reclaim.patch` (gui calls begin/end/reclaim per frame). Validated: the
data_grid leak goes from **unbounded (live → 364 MB / 3 GB headless)** to **bounded** (live ~50–126 MB,
closure table flat, RSS plateaus); closure correctness (sort/map/filter/captured) intact. Minimal
repro: `closure_leak_repro.v`.

## `gui-closure-reclaim.patch` — gui side (`window_update.v`)

Calls `closure.begin_frame_build()` before generating the view, `end_frame_build()` after composing the
layout, and `closure.reclaim_frames(2)` at the end of each `update()`. `keep=2` protects the current and
previous frame's handlers. **Contract:** event handlers must be created per-frame in the view function
(the immediate-mode norm); don't hoist one closure and reuse the same value across frames.

**Drag guard (2026-06-14):** reclamation is **skipped while `window.mouse_is_locked()`** (an in-progress
drag — splitter, scrollbar, slider, dock-redock, text-select). During a drag gui stores the *mousedown
frame's* captured callbacks in `view_state.mouse_lock` and keeps invoking them across the rebuilds the
drag triggers; those callbacks capture per-frame state (e.g. a `SplitterCore` whose `on_change` is a
per-frame dock closure). Without the guard, `reclaim_frames(2)` frees that still-live closure after 2
frames, so the next drag event calls a **NULL fn pointer** → crash (it surfaced as a *bogus*
`v_stable_sort` backtrace; the real fault is `view_splitter.v:560 core.on_change`). The few frames'
closures that pile up during a short drag are reclaimed on the first idle frame after mouse-up.

## `vglyph-empty-outline.patch` — vglyph (`glyph_atlas.v`)

`load_glyph` required a vector outline (`glyph.outline.n_points > 0`) before `FT_Outline_Translate`. An
**empty outline is legal** — whitespace (space), and any glyph the font has no outline for (a colour
emoji loaded as a bitmap, or a missing glyph). The original code **panicked in debug** and, in
**release** (`$if debug` compiled out), fed the empty outline to `FT_Outline_Translate`/`FT_Render_Glyph`
→ memory corruption / `invalid memory access` (again a misleading `v_stable_sort` backtrace). The patch
guards the translate/render on `n_points > 0` and reloads an empty-outline glyph as a direct (empty)
bitmap, which the existing zero-size-bitmap branch handles. This is the Linux counterpart of the
Windows-build "patch #4" (`docs/windows_build.md`) — apply it on Linux too. **App rule (see
`docs/known_issues.md`):** still only use glyphs the bundled font can render — this patch makes the
missing ones *blank* instead of *crashing*, but a button labelled with an invisible glyph is still a bug.

## `gui-msaa-sample-count.patch` — gui (`window.v`)

Adds a `sample_count` field to `WindowCfg` and forwards it to `gg.new_context` (sokol MSAA).
`src/main.v` passes `sample_count: 4` to antialias the Graphics-panel polylines; without this patch the
app fails to build (`unknown field 'sample_count'`). Default `1` (off) — inert for any app that doesn't
set it.

## `gui-window-resize.patch` — gui (`window_api.v`)

Adds `pub fn (mut Window) resize(width, height int)` — a one-line wrapper over the already-public
`gg.Context.resize()` (which implements the per-platform resize: macOS / Windows / X11; no-op on
Wayland). gg has the capability but `gui.Window.ui` is private, so an app can't drive a runtime resize
without it. `src/main.v` uses it so the toolbar **scale** dropdown grows/shrinks the window by the same
ratio as the UI scale (the DPI workaround — see CLAUDE.md 2026-06-17), keeping content density constant.
Pure addition, inert for any app that doesn't call it. **Clean upstream candidate** (fills a real gui API
gap, not a workaround) — verified live under WSLg/X11 (1500×920 → 1000×700 on a programmatic call).

## `autofree-boehm_leak-fixes.patch` — two `-autofree`/`-gc boehm_leak` codegen bugs

Found while getting `-gc boehm_leak` to compile the GUI (the diagnostic that cracked the root cause).
**Inert for the normal build** (`scripts/run.sh` uses default `-gc boehm`, which doesn't run autofree
scope-cleanup).

## `autofree-boehm_leak-fixes.patch`

Two independent fixes (both needed before `v -gc boehm_leak` will compile the GUI):

1. **`parser/assign.v`** — the `is_or` flag on `x := f() or { … }` vars (which tells autofree to
   skip them, since C declares the var *after* the `or` block) was set only under `pref.autofree`.
   `-gc boehm_leak` *also* runs scope-cleanup (`needs_scope_cleanup()` is true for it) but never got
   `is_or`, so it emitted `free(&x)` inside `x`'s own `or` block → `'result'/'head'/'new_text'
   undeclared`. Fix: set `is_or` when `gc_mode == .boehm_leak` too.

2. **`gen/c/autofree.v`** — an early `return`/`continue` in the middle of a scope freed vars that are
   declared *later* in the same scope (e.g. `vglyph.GlyphAtlas.grow_page`'s `new_staging_*` →
   `'new_staging_back' undeclared`). Fix: thread the cleanup position (`cur_pos`) into
   `autofree_scope_vars2` and skip any var with `obj.pos.pos > cur_pos`. **This also fixes plain
   `-autofree`** for the same pattern (regression-tested: early-return with later-declared vars now
   compiles and runs correctly).

## `gui-no-portal-fallback.patch` — gui (`nativebridge/portal_linux.c`) — NATIVE DIALOG HANG FIX

> **2026-06-15.** Fixes the file-requester hang: opening **any** native dialog (Open Log / Open Project /
> Add DBC(s)…) and dismissing it froze the whole app (window still movable by the WM, but every button
> dead; killable only from the shell).

gui's native dialog prefers the **XDG Desktop Portal** (`org.freedesktop.portal.FileChooser`) over
D-Bus when `gui_portal_available()` is true, falling back to zenity/kdialog otherwise. Its portal path
(`portal_wait_response`) does a **synchronous 120 s D-Bus poll** on the UI thread waiting for the portal
`Response` signal. Under **WSLg** that signal never matches/arrives, so the UI thread wedges in
`portal_wait_response → __poll` forever (confirmed by a `gdb` backtrace of the hung main thread). It is
**not** GC/fork/zenity related — those were red herrings; the dialog never reaches zenity at all when the
portal is "available". The patch adds an escape hatch: `gui_portal_available()` returns 0 when
**`GUI_NO_PORTAL`** is truthy (a value other than `0`/empty), so gui uses the working zenity backend.
**The app sets this automatically on WSL** — `src/main.v` `is_wsl()` defaults `GUI_NO_PORTAL=1` when it
detects WSL, so it works regardless of launch method; real Linux desktops keep the portal. An explicit
`GUI_NO_PORTAL=0`/`=1` always overrides.

> **Considered and rejected:** `GC_set_handle_fork(1)` in `cmain.v` (Boehm fork-safety). Tried while
> mis-diagnosing the dialog hang as a fork/GC race; it did nothing (the cause was the portal, above) and
> guards a scenario that never occurs here — the only `fork` is `os.new_process`'s fork+**exec** of
> zenity, and exec wipes the child while the parent is unaffected by fork. Reverted; `~/v` stays pristine.

## Reapply (after any V rebuild / re-pin)

> **V base note (2026-06-14):** `closure-gc-leak-fix.patch` is now generated against base
> **`ed17e5fb`** (the parent of PR #27446's first commit), NOT the old `de365a1` pin. On a fresh box,
> check out V at `ed17e5fb` (`git -C ~/v checkout ed17e5fb`) before applying — or, simplest, just check
> out the PR branch directly (`git -C ~/v fetch https://github.com/MartenH/v fix-closure-context-leak &&
> git -C ~/v checkout FETCH_HEAD`), which already contains commits 1–5 of the leak fix; then only
> `autofree-boehm_leak-fixes.patch` remains to apply on the V side. This box's `~/v` is already on the
> PR branch (HEAD `641b093` + the 3 review fixes as a working-tree delta), so the `git apply` below is
> for a fresh checkout, not this one.

```sh
P=/home/mahi/repos/cantester_v/docs/v_patches
cd ~/v
git checkout ed17e5fb                          # base the closure patch is generated against
git apply $P/closure-gc-leak-fix.patch        # THE leak fix (V side, = PR #27446)
git apply $P/autofree-boehm_leak-fixes.patch  # diagnostic-only codegen fixes
./v self                                       # rebuild the compiler
cd ~/.vmodules/gui
git apply $P/gui-closure-reclaim.patch         # gui side of the leak fix (+ drag/mouse-lock guard)
git apply $P/gui-msaa-sample-count.patch       # WindowCfg.sample_count (src/main.v needs it to build)
git apply $P/gui-window-resize.patch           # Window.resize() — toolbar scale dropdown resizes the window
git apply $P/gui-no-portal-fallback.patch      # GUI_NO_PORTAL escape hatch (file-dialog hang under WSLg)
cd ~/.vmodules/vglyph
git apply $P/vglyph-empty-outline.patch        # don't crash on empty-outline glyphs (whitespace/emoji)
```

> **Note (this box, 2026-06-15):** `~/v` is upstream master `7134f48` with `closure-gc-leak-fix.patch` +
> `autofree-boehm_leak-fixes.patch` applied as a working-tree delta (NOT the PR branch — the patches
> apply cleanly to master, so no `ed17e5fb`/PR-branch checkout was needed), rebuilt via `./v self`.
> Module-side: `gui-closure-reclaim`, `gui-msaa-sample-count`, `gui-no-portal-fallback` (gui) and
> `vglyph-empty-outline` (vglyph). So this box now carries the **full leak-free set**. Verified: the
> `cmd/mem_leak_grid` changing-rows V-heap is bounded (~95–149 MB sawtooth, flat trend) instead of
> climbing.

## Build a leak-profiling binary

```sh
v -gc boehm_leak -enable-globals -path "@vlib|@vmodules|modules" -o build/mem_leak_grid \
  cmd/mem_leak_grid/mem_leak_grid.v
MEM_REPRO=changing CANTESTER_RUN_MS=6000 ./build/mem_leak_grid    # prints boehm leak backtraces
```

[vlang/v#27446]: https://github.com/vlang/v/pull/27446
