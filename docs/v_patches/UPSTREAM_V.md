# Upstream V issue/PR — capturing closures are never garbage-collected under `-gc boehm`

Draft text for an issue (and optional PR) against [vlang/v](https://github.com/vlang/v).
Patches: `closure-gc-leak-fix.patch` (the fix), `closure_leak_repro.v` (the repro).

---

## Title

`-gc boehm`: capturing closures (`fn [x] () {}`) leak their captured context forever when stored

## Labels

Bug, Memory, GC, Closures

## V version

`v 0.5.1 4dbcba6` (Linux/x86-64, `-gc boehm`, the default).

## What happens

A closure that **captures** data (`fn [captured] (...) { ... }`) never has its captured-context
reclaimed by the GC. Programs that create capturing closures repeatedly — most importantly any
**immediate-mode GUI** that rebuilds event-handler closures every frame — grow in memory without bound.

## Minimal reproduction

```v
// closure_leak.v  —  run: v -path . run closure_leak.v
module main

import os

fn rss_mb() int {
	s := os.read_file('/proc/self/status') or { return -1 }
	for line in s.split_into_lines() {
		if line.starts_with('VmRSS:') {
			return line.fields()[1].int() / 1024
		}
	}
	return -1
}

fn main() {
	noclo := os.getenv('NOCLO') != ''
	mut sink := 0
	for n in 0 .. 2_000_000 {
		big := []int{len: 200, init: index + n} // ~1.6 KB heap array
		if noclo {
			sink += big[n % big.len] // control: same array, NO closure
		} else {
			h := fn [big] (x int) int { return big[x % big.len] } // captures big
			sink += h(n % 200) // use + drop
		}
		if n % 400_000 == 0 {
			gc_collect()
			println('n=${n:8} live=${gc_memory_use() / 1024 / 1024}MB RSS=${rss_mb()}MB')
		}
	}
	println('final live=${gc_memory_use() / 1024 / 1024}MB')
}
```

Results:

| run | `live` (GC heap, post-`gc_collect`) |
|-----|--------------------------------------|
| default (closure)   | **0 → ~2 GB, linear** |
| `NOCLO=1` (control) | **flat at ~0 MB** |

The captured array is collected fine on its own; only the version that wraps it in a closure leaks.
So it is the closure **context** that is never freed, not the captured data.

## Root cause

`vlib/v/gen/c/fn.v` allocates each closure's captured context with `memdup_uncollectable`
(`GC_MALLOC_UNCOLLECTABLE`) — memory the Boehm GC never collects:

```v
g.write('builtin__closure__closure_create(${fn_name}, (${ctx_struct}*) builtin__memdup_uncollectable(...)')
```

It is reclaimed only by `closure_try_destroy` (`vlib/builtin/closure/closure.c.v`), which the codegen
emits **only for temporary closures passed straight to a call and immediately discarded**
(`fn.v` ~line 2437). Closures that are **stored** (assigned to a struct field, returned, kept in a
collection — e.g. UI event handlers) are never destroyed, so their uncollectable context leaks for the
lifetime of the process.

(Note: `closure_try_destroy` itself also does not actually free under `-gc boehm` — it calls `free()`,
which is a no-op in boehm mode, so even the temporary path only reclaimed the *slot*, not the context.)

## Proposed fix (PR `closure-gc-leak-fix.patch`)

Make closure contexts **collectable** and keep each live closure's context reachable through a
GC-scanned table, then add an opt-in **frame-epoch** reclamation API for long-running frame-based apps:

- `gen/c/fn.v`: `memdup_uncollectable` → `memdup` (collectable context).
- `vlib/builtin/closure/closure.c.v`:
  - `g_closure_live map[voidptr]ClosureLiveInfo` — maps each live closure to `{ctx, frame}`. The `ctx`
    pointer stored in the GC-scanned map value keeps the (now collectable) context alive while the
    closure lives; the trampoline slot that also points at it lives in an mmap page the GC does not
    scan, so this table is what makes collectable contexts safe.
  - `closure_create` inserts into the table; `closure_try_destroy` removes from it and returns the slot
    to the free list (no `GC_FREE` → idempotent, can never double-free; the GC reclaims the context).
  - New API:
    - `begin_frame_build()` / `end_frame_build()` — frame-stamp closures created during a frame's view
      build. Closures created outside this window (app setup, event handlers) get a sentinel frame and
      are never auto-reclaimed.
    - `reclaim_frames(keep u32)` — reclaim every frame-stamped closure created `keep`+ frames ago.
    - `try_destroy(c voidptr)` — reclaim one closure immediately (also exposed publicly).
    - `live_count() int` — introspection.

This keeps non-frame programs behaving exactly as before (closures still "leak" if never reclaimed,
since nothing calls the new API — but now via a collectable table rather than uncollectable memory),
while giving immediate-mode UIs a way to bound closure memory. See the companion vlang/gui change.

### Why not simpler approaches (both tried, both fail)

1. **`closure_try_destroy` + `GC_FREE` it from the app** — works in isolation but **double-frees**
   ("Duplicate large block deallocation") when an app shares/duplicates transient closure pointers; an
   explicit free can't be made idempotent here.
2. **Collectable context + register the trampoline pages as GC roots (`GC_add_roots`)** — works on the
   repro but **premature-frees** in a real app (crash in a sort comparator's closure), because Boehm's
   `GC_MAX_ROOT_SETS` silently stops registering after enough pages, so later contexts aren't scanned.

The table approach avoids both (no explicit free → no double-free; one GC-scanned map → no roots cap).

## Validation

- Repro above: `live` 2 GB → **0** with reclamation.
- Closure correctness (sort comparators, `map`/`filter`, captured-string closures invoked in a loop,
  double/triple `try_destroy`) unchanged.
- Real immediate-mode GUI (vlang/gui data_grid, 180 s / 3400 frames): unbounded live (→ 364 MB) →
  **bounded (46–126 MB)**, RSS plateaus.
- `v self` rebuilds; the bootstrap-sensitive closure thunk tables are untouched.

Happy to open the PR if the maintainers are OK with the API shape (or adapt it — e.g. fold
`begin/end_frame_build` into a single `set_frame(u32)`).
