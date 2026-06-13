# Upstream vlang/gui — per-frame event-handler closures leak unboundedly

Two pieces, ready to paste: a free-form **Issue** and a **Pull Request** (title + body). Patch:
`gui-closure-reclaim.patch` (`window_update.v`). **Depends on the V fix in `UPSTREAM_V.md`** (it calls
the new `builtin.closure` reclamation API), so file/land that first and link it here.

> vlang/gui has no issue/PR templates and uses free-form, descriptive titles (e.g. *"Fix notification
> render-thread blocking…"*), so this is plain prose rather than a form.

---

# ───────────────  ISSUE  ───────────────

**Title:** Memory grows unboundedly — every per-frame event-handler closure leaks its captured context

### What happens

Any long-running gui app whose view rebuilds **capturing** event handlers each frame
(`on_click: fn [row, ...] (...) { ... }`) grows in memory without bound. The `data_grid` is the worst
case (20+ capturing closures per call, one capturing the whole `rows` array), but it affects any view
using capturing handlers — the immediate-mode norm.

Measured on a live `data_grid` redrawing changing rows: `live` (post-`gc_collect`) climbs linearly,
~1.3 MB/s, no plateau (≈46 → 364 MB over ~4 min; RSS 259 → 803 MB).

### Root cause

It's a V runtime issue (see vlang/v issue — link), not gui logic: V allocates a capturing closure's
context as GC-uncollectable and only frees it for *temporary* closures, never for **stored** ones. gui
stores a fresh handler closure on (essentially) every Shape every frame, so each frame permanently
leaks all its handler contexts. Bisected with a headless `data_grid()` loop (no window): it leaks
~50 KB/call, linear to multiple GB; `vglyph` and the rest of the layout/text path are flat.

### Reproduction

Any view with per-frame capturing handlers redrawn continuously; a `data_grid` over changing rows shows
it fastest. (Minimal V-level repro in the linked vlang/v issue.)

---

# ───────────────  PULL REQUEST  ───────────────

**Title:** Fix unbounded memory leak from per-frame event-handler closures

### Body

Depends on vlang/v PR `builtin: collect captured closure contexts under -gc boehm` (link), which adds a
frame-epoch closure-reclamation API to `builtin.closure`. This wires gui into it: one bracket around the
view build plus one reclaim call per frame, in `Window.update()` (`window_update.v`):

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
  app-setup callbacks (`link_handler`, data-source callbacks, …) and event-handler-created closures get
  a sentinel frame and are never auto-reclaimed.
- `reclaim_frames(2)` frees handlers from 2+ frames ago; `keep=2` protects the current and previous
  frame (the previous one may still be the live/dispatched tree until this update commits).

**Contract (worth a doc line):** event handlers must be created per-frame in the view function — the
immediate-mode norm gui already follows. Don't hoist one closure and pass the same value across many
frames; it would be reclaimed and dangle.

### Validation

- Headless `data_grid()` loop: 3 GB → **0**.
- Live `data_grid` (180 s / 3400 frames): `live` bounded **46–126 MB**, closure table flat (~2258), RSS
  plateaus (~401 MB) — vs the unfixed linear climb. No crash; handler dispatch correctness intact.

### Rejected alternative

Walking the layout tree in `layout_clear` and `try_destroy`-ing each Shape's `EventHandlers` closures —
only catches closures that reach a Shape (many gui closures live in the View tree or are captured by
other closures and never become a Shape handler), so it left most of the leak in place. The frame-epoch
approach is content-agnostic and complete.
