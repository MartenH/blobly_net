# Local V + gui patches (upstream candidates)

Patches found/applied while hunting **and fixing** the data_grid memory leak (see
`docs/known_issues.md` → Rendering stack, 2026-06-13). Three patches:

## `closure-gc-leak-fix.patch` — THE LEAK FIX (V: `closure.c.v` + `gen/c/fn.v`)

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

## `gui-msaa-sample-count.patch` — gui (`window.v`)

Adds a `sample_count` field to `WindowCfg` and forwards it to `gg.new_context` (sokol MSAA).
`src/main.v` passes `sample_count: 4` to antialias the Graphics-panel polylines; without this patch the
app fails to build (`unknown field 'sample_count'`). Default `1` (off) — inert for any app that doesn't
set it.

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

## Reapply (after any V rebuild / re-pin)

```sh
P=/home/mahi/repos/cantester_v/docs/v_patches
cd ~/v
git apply $P/closure-gc-leak-fix.patch        # THE leak fix (V side)
git apply $P/autofree-boehm_leak-fixes.patch  # diagnostic-only codegen fixes
./v self                                       # rebuild the compiler
cd ~/.vmodules/gui
git apply $P/gui-closure-reclaim.patch         # gui side of the leak fix
git apply $P/gui-msaa-sample-count.patch       # WindowCfg.sample_count (src/main.v needs it to build)
```

## Build a leak-profiling binary

```sh
v -gc boehm_leak -enable-globals -path "@vlib|@vmodules|modules" -o build/mem_leak_grid \
  cmd/mem_leak_grid/mem_leak_grid.v
MEM_REPRO=changing CANTESTER_RUN_MS=6000 ./build/mem_leak_grid    # prints boehm leak backtraces
```
