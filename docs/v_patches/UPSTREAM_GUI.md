# Upstream vlang/gui issue/PR — per-frame event-handler closures leak unboundedly

Draft text for an issue (and optional PR) against [vlang/gui](https://github.com/vlang/gui).
Patch: `gui-closure-reclaim.patch` (`window_update.v`). Depends on the V fix in `UPSTREAM_V.md`.

---

## Title

Memory grows unboundedly: every per-frame event-handler closure leaks its captured context

## Labels

Bug, Memory

## Summary

Any long-running gui app whose view rebuilds **capturing** event handlers each frame
(`on_click: fn [row, ...] (...) { ... }`) grows in memory without bound. The `data_grid` is the worst
case — it attaches 20+ capturing closures per call (one captures the entire `rows` array) — but it
affects any view that uses capturing handlers, which is the immediate-mode norm.

Measured on a live `data_grid` redrawing changing rows: **`live` (post-`gc_collect`) climbs linearly,
~1.3 MB/s, with no plateau** (e.g. 46 → 364 MB over ~4 min; RSS 259 → 803 MB).

## Root cause

It's a V runtime issue (see the companion vlang/v report), not a gui logic bug: V allocates a capturing
closure's captured context as GC-**uncollectable** and only frees it for *temporary* closures, never for
**stored** ones. gui stores a fresh handler closure on (essentially) every Shape every frame, so each
frame permanently leaks all its handler contexts. Bisected with a headless `data_grid()` loop (no
window): it leaks ~50 KB per call, linear to multiple GB; `vglyph` and the rest of the layout/text path
are flat.

## Fix (PR `gui-closure-reclaim.patch`, depends on the V fix)

The V fix adds a frame-epoch reclamation API (`builtin.closure`: `begin_frame_build`,
`end_frame_build`, `reclaim_frames`). gui calls it once per frame in `Window.update()`
(`window_update.v`):

```v
import builtin.closure

fn (mut window Window) update() {
	window.lock()
	...
	closure.begin_frame_build()          // frame-stamp closures created during the view build
	mut view := window.view_generator(window)
	...
	layout_clear(mut window.layout)
	window.layout = window.compose_layout(mut view)
	closure.end_frame_build()
	window.build_renderers(...)
	window.unlock()

	view_clear(mut view)
	closure.reclaim_frames(2)             // reclaim handlers 2+ frames old (dead in immediate mode)
	...
}
```

- `begin/end_frame_build` mark the view-build window so only closures created there are eligible —
  app-setup callbacks (`link_handler`, data-source callbacks, etc.) and event-handler-created closures
  get a sentinel and are never auto-reclaimed.
- `reclaim_frames(2)` frees handlers from 2+ frames ago; `keep=2` protects the current and previous
  frame (the previous one may still be the live/dispatched tree until this update commits).

**Contract:** event handlers must be created per-frame in the view function (the immediate-mode norm).
Don't hoist one closure and reuse the same value across many frames — it would be reclaimed and dangle.
(This matches how gui examples are written.)

## Validation

- Headless `data_grid()` loop: 3 GB → **0**.
- Live `data_grid` (180 s / 3400 frames): `live` **bounded 46–126 MB**, the closure table flat (~2258),
  RSS plateaus (~401 MB) — vs the unfixed linear climb. No crash; handler dispatch correctness intact.

## Notes

- This is the dominant unbounded leak we found while building a long-running CANoe-style app on gui;
  with it fixed the app's RSS plateaus instead of climbing.
- Alternative considered: walking the layout tree in `layout_clear` and `try_destroy`-ing each Shape's
  `EventHandlers` closures. Rejected — it only catches closures that reach a Shape (many gui closures
  live in the View tree / are captured by other closures and never become a Shape handler), so it left
  most of the leak in place. The frame-epoch approach is content-agnostic and complete.
