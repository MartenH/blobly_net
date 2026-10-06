module main

import os
import vgui

// PlotAuto is a dev hook, inert unless BLOBLY_PLOT is set: at frame BLOBLY_PLOT_FRAME (default
// 90) it does what a right-click on every Trace group carrying the message does — "Add <signal>
// to Graphics" — and selects the newest such row in the Signals panel, for the headless
// screenshot (VGUI_FRAMES / VGUI_SHOT cannot click). `BLOBLY_PLOT=0x100:EngineSpeed`.
struct PlotAuto {
mut:
	id    u32
	sig   string
	frame int
	done  bool
}

fn (mut app App) plot_auto_init() {
	spec := os.getenv('BLOBLY_PLOT')
	if spec == '' {
		app.plot_auto.done = true
		return
	}
	parts := spec.split(':')
	if parts.len != 2 {
		app.plot_auto.done = true
		return
	}
	app.plot_auto.id = u32(parts[0].trim_space().parse_uint(0, 32) or { 0 })
	app.plot_auto.sig = parts[1].trim_space()
	n := os.getenv('BLOBLY_PLOT_FRAME').int()
	app.plot_auto.frame = if n > 0 { n } else { 90 }
	app.show_graphics = true
	app.show_signals = true
}

// plot_auto_step runs once per frame from the main loop, with the frame's row snapshot.
fn (mut app App) plot_auto_step(rows []TraceRow, frame int) {
	if app.plot_auto.done {
		return
	}
	vgui.wake() // frames keep coming, so the hook fires on a quiet project too
	if frame < app.plot_auto.frame {
		return
	}
	app.plot_auto.done = true
	mut seen := map[string]bool{}
	for i := rows.len - 1; i >= 0; i-- {
		r := rows[i]
		if r.someip || r.id != app.plot_auto.id || !r.has_payload() {
			continue
		}
		k := r.gkey()
		if k in seen {
			continue
		}
		if seen.len == 0 {
			app.sel_id = int(r.id)
			app.sel_ext = r.ext
			app.sel_tp = r.tp
			app.sel_wire = r.wire
			app.sel_da = r.tp_da
			app.sel_msg = ''
		}
		seen[k] = true
		app.add_watch(r.id, r.ext, r.tp, r.wire, r.tp_da, app.plot_auto.sig)
	}
}
