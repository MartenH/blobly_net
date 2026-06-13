# Local V compiler patches (upstream candidates)

Patches applied to the local V install (`~/v`, pinned at `4dbcba6` / reports `0.5.1`) while hunting
the data_grid memory leak (see `docs/known_issues.md` → Rendering stack, 2026-06-13). They fix two
real V codegen bugs in the **autofree / `-gc boehm_leak`** path. **Both are inert for our normal
build** (`scripts/run.sh` uses the default `-gc boehm`, which does not run autofree scope-cleanup),
so they only matter when you want a leak-profiling build.

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
cd ~/v
git apply /home/mahi/repos/cantester_v/docs/v_patches/autofree-boehm_leak-fixes.patch
./v self          # rebuild the compiler
```

## Build a leak-profiling binary

```sh
v -gc boehm_leak -enable-globals -path "@vlib|@vmodules|modules" -o build/mem_leak_grid \
  cmd/mem_leak_grid/mem_leak_grid.v
MEM_REPRO=changing CANTESTER_RUN_MS=6000 ./build/mem_leak_grid    # prints boehm leak backtraces
```
