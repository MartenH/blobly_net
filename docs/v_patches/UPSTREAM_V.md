# Upstream vlang/v — capturing closures leak their captured context under `-gc boehm`

Two pieces, ready to paste: a **GitHub Issue** (organized to V's bug-report form fields) and a **Pull
Request** (title + body). Patch file: `closure-gc-leak-fix.patch`. Minimal repro: `closure_leak_repro.v`.

> Conventions used here (verified against vlang/v): the bug report is a GitHub **issue form** whose
> required fields are *Describe the bug · Reproduction Steps · Expected Behavior · Current Behavior ·
> Possible Solution · Additional Information/Context · V version · Environment details*. PR/commit
> titles are **`module: description`** (lowercase), e.g. `builtin: preserve array capacity ...`.

---

# ───────────────  ISSUE  ───────────────

## Describe the bug

A closure that **captures** data (`fn [x] (...) { ... }`) never has its captured context reclaimed by
the GC when the closure is **stored** (assigned to a variable, returned, kept in a collection, used as
a struct-field event handler, …). Programs that create capturing closures repeatedly — most importantly
any **immediate-mode GUI** that rebuilds handler closures every frame — grow in memory without bound.

## Reproduction Steps

Self-contained, runnable (`v run closure_leak.v`):

```v
module main

fn main() {
	for n in 0 .. 2_000_000 {
		big := []int{len: 200, init: index + n} // ~1.6 KB heap array, new each iteration
		// Capture `big` in a stored closure, use it once, drop it:
		h := fn [big] (x int) int { return big[x % big.len] }
		_ = h(n % 200)
		if n % 400_000 == 0 {
			gc_collect() // force a full collection so `live` = truly reachable memory
			println('n=${n:8}  live=${gc_memory_use() / 1024 / 1024} MB')
		}
	}
}
```

Control (no leak): replace the two closure lines with a direct read — `_ = big[n % 200]`.

## Expected Behavior

Both versions allocate the same `big` each iteration and drop it; after each `gc_collect()` the
unreferenced arrays should be reclaimed, so `live` stays roughly flat (as it does for the control).

```
n=       0  live=0 MB
n= 1600000  live=0 MB
final       live=0 MB     # control (no closure)
```

## Current Behavior

With the closure, `live` climbs **linearly to ~2 GB** and never plateaus (≈1 KB/iteration: the closure
context plus the captured array it pins). The control is flat at ~0 MB.

```
n=       0  live=0 MB
n=  800000  live=805 MB
n= 1600000  live=1611 MB
final       live=2014 MB  # with closure
```

## Possible Solution

The captured context is allocated **uncollectable** and only reclaimed for closures the codegen treats
as temporary:

- `vlib/v/gen/c/fn.v` emits `builtin__memdup_uncollectable(...)` for the context — memory the GC never
  collects.
- It is freed only by `closure_try_destroy`, which `fn.v` emits **only for temporary closures passed
  straight into a call** (~line 2437). Stored closures are never destroyed → their context leaks for
  the process lifetime. (Separately, `closure_try_destroy` calls `free()`, which is a **no-op under
  `-gc boehm`**, so even that path only reclaimed the trampoline slot, not the context.)

Proposed fix (see the linked PR): allocate the context **collectably** (`memdup`) and keep each live
closure's context reachable via a GC-scanned table, so it's collected once the closure is gone; add an
opt-in frame-epoch reclamation API (`begin_frame_build`/`end_frame_build`/`reclaim_frames`) for
long-running frame-based apps (an immediate-mode GUI calls it once per frame). Non-frame programs behave
exactly as today.

## Additional Information/Context

Found while building a long-running GUI on vlang/gui: per-frame event-handler closures leaked ~1.3 MB/s
unbounded. Bisected to this with the SSCCE above (closure leaks; identical array churn without a closure
is flat). The fix takes the GUI's `live` from a linear climb (→ 364 MB / 4 min) to bounded (46–126 MB).

Two simpler fixes were tried and **fail** (documented so they aren't re-suggested):
1. Have the app `GC_FREE` the context via `closure_try_destroy` → **double-free** when transient
   closure pointers are shared/duplicated (an explicit free can't be made idempotent here).
2. Make the context collectable and register the trampoline pages as GC roots (`GC_add_roots`) →
   **premature free** in a real app, because Boehm's `GC_MAX_ROOT_SETS` silently stops registering
   after enough pages, so later contexts go unscanned and are collected mid-use.

## V version

`V 0.5.1 4dbcba6` (built from source). *(Run `v version` / `v up` to fill in for the real submission.)*

## Environment details (OS name and version, etc.)

Linux x86-64 (WSL2, Ubuntu 24.04), `-gc boehm` (default), `cc gcc`. *(Run `v doctor` for the real
submission.)*

---

# ───────────────  PULL REQUEST  ───────────────

## Title

```
builtin: collect captured closure contexts under -gc boehm (fix unbounded stored-closure leak)
```

*(Touches `vlib/builtin/closure/closure.c.v` and `vlib/v/gen/c/fn.v`; `builtin` is the primary module.)*

## Body

### Problem

Capturing closures (`fn [x] (...)`) leak their captured context whenever the closure is stored, under
the default `-gc boehm`. `gen/c/fn.v` allocates the context with `memdup_uncollectable`, and the only
reclaimer — `closure_try_destroy` — is emitted only for temporary closures (and used `free()`, a no-op
in boehm mode, so it didn't free the context anyway). Minimal repro / measurements: see the linked
issue (closure → `live` 0→2 GB; identical array churn without a closure → flat).

### Fix

Make the context **collectable** and keep it reachable through a GC-scanned table while the closure is
live; reclaim it by clearing the trampoline slot and dropping the table entry (no explicit free).

- `gen/c/fn.v`: `memdup_uncollectable` → `memdup`.
- `vlib/builtin/closure/closure.c.v`:
  - `g_closure_live map[voidptr]ClosureLiveInfo` (`{ctx, frame}`). The `ctx` in the GC-scanned map
    value keeps the collectable context alive while the closure lives (the trampoline slot that also
    points at it is in an mmap page the GC doesn't scan).
  - `closure_create` inserts; `closure_try_destroy` removes + returns the slot to the free list — **no
    `GC_FREE`**, so it's idempotent and can never double-free; the GC reclaims the context.
  - New (public, `@[markused]`) API: `try_destroy(c)`, `begin_frame_build()`, `end_frame_build()`,
    `reclaim_frames(keep u32)`, `live_count()`. Closures created outside a `begin/end_frame_build`
    window get a sentinel frame and are never auto-reclaimed (so app-setup/event-handler closures are
    untouched).

### Why not simpler

- `closure_try_destroy` + real `GC_FREE`, called by the app → **double-free** with shared transient
  closures (no idempotent explicit free).
- collectable + per-page `GC_add_roots` → **premature free** (`GC_MAX_ROOT_SETS` cap drops later page
  roots). The table+epoch design avoids both.

### Compatibility / risk

- Programs that never call the new API behave as before (closures still aren't auto-reclaimed, but now
  via a collectable table instead of uncollectable memory — same order of memory, no behavior change).
- Per-closure cost: one map insert on create / delete on destroy (under the existing closure mutex).
- The bootstrap-sensitive thunk byte-tables are untouched; `v self` rebuilds cleanly.

### Validation

- SSCCE: `live` 2 GB → 0 with reclamation.
- Closure correctness unchanged: sort comparators, `map`/`filter`, captured-string closures invoked in
  a loop, and double/triple `try_destroy` all pass.
- Companion vlang/gui change (one call per frame in `Window.update()`): a live `data_grid`
  (180 s / 3400 frames) goes from unbounded `live` (→ 364 MB) to bounded (46–126 MB), RSS plateaus.

Open to reshaping the API (e.g. a single `set_frame(u32)` instead of `begin/end_frame_build`) if
preferred.
