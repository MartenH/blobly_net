// textured_control — the DECISIVE control for the "libgallium leaks on the
// per-frame textured-draw path" claim (docs/known_issues.md → Rendering, the
// 🔴 DEFINITIVE 2026-06-12 note).
//
// That note rests on: (a) direct RSS climbs unbounded under WSLg, and (b)
// heaptrack attributes the unfreed bytes to libgallium. But (b) is the SAME
// tool that produced a *retracted* false libgallium positive on 2026-06-07,
// and the headline rects-flat / text-climbs differential does NOT isolate Mesa
// from vglyph — going rects→text swaps in vglyph's whole glyph-render path too.
//
// This control removes vglyph/Pango/text ENTIRELY and exercises only the thing
// the note blames: per-frame TEXTURED draws through the same sokol→Mesa GL
// backend. A static in-memory texture (uploaded ONCE), drawn as N quads at
// CHANGING positions every frame (mimicking text shifting). No string shaping,
// no glyph atlas, no FreeType.
//
//   RSS climbs unbounded  → Mesa really does leak on textured draws; the
//                           DEFINITIVE note stands, "not fixable in our code".
//   RSS plateaus          → libgallium is exonerated AGAIN; the leak is vglyph's
//                           glyph path (the 2026-06-07 answer), and the 🔴 note
//                           must be downgraded.
//
// Modes (env REPRO_MODE, default `textured`):
//   textured        : N textured quads at CHANGING positions  (the real test)
//   textured_static : N textured quads at FIXED positions      (draw vs geometry)
//   rects           : N filled rects at changing positions     (the note's flat baseline)
//
// The app prints its OWN VmRSS (/proc/self/status) + V heap every 2 s, so the
// time series is self-contained — no external Task-Manager watching needed.
//
// Run:    v -enable-globals -path "@vlib|@vmodules|modules" run cmd/mem_leak_repro/textured_control.v
//   REPRO_MODE=rects <same>   /   REPRO_MODE=textured_static <same>
// BLOBLY_RUN_MS=N exits cleanly after N ms (for heaptrack/valgrind).
module main

import gg
import os
import time

const tex_w = 64
const tex_h = 64
const n_quads = 30 // matches the 30 rows of the text repro

struct App {
mut:
	gg   &gg.Context = unsafe { nil }
	img  int
	n    int
	mode string
	last i64
}

fn main() {
	mode := os.getenv_opt('REPRO_MODE') or { 'textured' }
	mut app := &App{ mode: mode, last: time.ticks() }
	app.gg = gg.new_context(
		bg_color:     gg.white
		width:        560
		height:       400
		window_title: 'textured_control — mode=${mode} — watch VmRSS vs V heap'
		init_fn:      init
		frame_fn:     frame
		user_data:    app
	)
	if ms := os.getenv_opt('BLOBLY_RUN_MS') {
		spawn fn (n int) {
			time.sleep(n * time.millisecond)
			exit(0)
		}(ms.int())
	}
	println('mode=${mode} — drawing ${n_quads} ${mode} per frame; V heap stays bounded, watch VmRSS.')
	app.gg.run()
}

fn init(mut app App) {
	// One static RGBA texture, uploaded ONCE. A simple checker so it's a real
	// sampled texture, not a flat fill the driver might short-circuit.
	mut px := []u8{len: tex_w * tex_h * 4}
	for y in 0 .. tex_h {
		for x in 0 .. tex_w {
			i := (y * tex_w + x) * 4
			on := ((x >> 3) + (y >> 3)) & 1 == 1
			v := if on { u8(230) } else { u8(40) }
			px[i] = v
			px[i + 1] = u8(x * 4)
			px[i + 2] = u8(y * 4)
			px[i + 3] = 255
		}
	}
	app.img = app.gg.new_streaming_image(tex_w, tex_h, 4, pixel_format: .rgba8)
	mut si := app.gg.get_cached_image_by_idx(app.img)
	si.update_pixel_data(unsafe { &u8(&px[0]) })
}

fn frame(mut app App) {
	app.n++
	app.gg.begin()
	changing := app.mode != 'textured_static'
	for i in 0 .. n_quads {
		// jitter positions per frame (changing geometry) like text shifting
		mut x := f32(20 + (i % 6) * 88)
		mut y := f32(10 + (i / 6) * 70)
		if changing {
			x += f32((app.n * 3 + i * 17) % 40)
			y += f32((app.n * 2 + i * 11) % 30)
		}
		if app.mode == 'rects' {
			app.gg.draw_rect_filled(x, y, 60, 48, gg.rgb(u8(40 + i * 7), 90, 160))
		} else {
			app.gg.draw_image_by_id(x, y, 60, 48, app.img)
		}
	}
	app.gg.end()

	now := time.ticks()
	if now - app.last >= 2000 {
		app.last = now
		rss := rss_mb()
		// On Windows there is no /proc → rss_mb() returns -1; watch Task Manager's
		// "Working set"/"Memory" column instead. V-heap still prints (GC bound check).
		rss_str := if rss < 0 { 'n/a→TaskMgr' } else { '${rss}' }
		println('  ${app.mode:16} frame=${app.n:7}  VmRSS=${rss_str} MB  V-heap=${gc_memory_use() / 1024 / 1024} MB')
	}
}

// rss_mb reads this process's resident set size from /proc/self/status (Linux);
// returns -1 where that file doesn't exist (e.g. Windows — use Task Manager).
fn rss_mb() int {
	txt := os.read_file('/proc/self/status') or { return -1 }
	for line in txt.split_into_lines() {
		if line.starts_with('VmRSS:') {
			// "VmRSS:    123456 kB"
			fields := line.fields()
			if fields.len >= 2 {
				return fields[1].int() / 1024
			}
		}
	}
	return -1
}
