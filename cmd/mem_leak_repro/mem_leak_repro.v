// mem_leak_repro — minimal reproducer for the steady memory growth seen when the
// trace shows live (constantly changing) values. No cantester logic, no CAN, no
// simulation — just a gui window that redraws ~7 rows of text on a timer.
//
// Modes (env MEM_REPRO=changing|static, default changing):
//   - changing : each row's text contains a counter, so every redraw is a NEW
//                string → misses vglyph's by-text layout cache → OS RSS climbs.
//   - static   : the rows are fixed strings → cache hits → RSS plateaus.
// The printed **V heap** (gc_memory_use, GC-managed) stays bounded in BOTH modes;
// the growth is below V (C-land).
//
// FINAL DIAGNOSIS (see docs/known_issues.md → Rendering, for the full trail):
//   - It is **Linux-only** — VERIFIED it does NOT reproduce on native Windows
//     (both modes plateau there). So it is not portable vglyph/Pango code.
//   - It is in vglyph's **glyph RENDER path**, not Pango layout: isolation loops
//     show raw Pango and vglyph's `Context.layout_text` are both flat for changing
//     text; only the path that also RENDERS (this app) leaks. So rendering *new*
//     strings each frame on Linux retains memory (glyph/atlas churn under FreeType),
//     while re-rendering the same strings (static) does not.
//   - NOT the GL driver (a rects-only gg control is flat), NOT V/GC, NOT our code.
//
// Run:    v -enable-globals -path "@vlib|@vmodules|modules" run cmd/mem_leak_repro/mem_leak_repro.v
// Static: MEM_REPRO=static  <same>
// Profile diff (Linux): heaptrack each mode, then
//   heaptrack_print -d <static.gz> -a 1 -p 0 <changing.gz>   # shows the text-only allocs
// CANTESTER_RUN_MS=N exits after N ms (clean finalize for heaptrack/valgrind).
module main

import gui
import os
import time

@[heap]
struct App {
mut:
	n      int
	static bool
}

fn main() {
	is_static := (os.getenv_opt('MEM_REPRO') or { 'changing' }) == 'static'
	mut win := gui.window(
		title:   'mem_leak_repro — watch OS RSS vs the printed V heap'
		state:   &App{ static: is_static }
		width:   560
		height:  400
		on_init: fn (mut w gui.Window) {
			w.update_view(view)
			// redraw ~7 fps so the (changing) text is reshaped each frame
			spawn fn (mut w gui.Window) {
				mut last := time.ticks()
				for {
					time.sleep(140 * time.millisecond)
					mut a := w.state[App]()
					a.n++
					if time.ticks() - last >= 2000 {
						last = time.ticks()
						mode := if a.static { 'static ' } else { 'changing' }
						println('  ${mode} frame=${a.n:6}  V-heap=${gc_memory_use() / 1024 / 1024} MB  → now check OS RSS')
					}
					w.update_window()
				}
			}(mut w)
		}
	)
	if ms := os.getenv_opt('CANTESTER_RUN_MS') {
		spawn fn (n int) {
			time.sleep(n * time.millisecond)
			exit(0)
		}(ms.int())
	}
	println('mode=${os.getenv_opt('MEM_REPRO') or { 'changing' }} — V heap stays bounded; watch OS RSS (Task Manager / Linux VmRSS).')
	win.run()
}

fn view(mut w gui.Window) gui.View {
	a := w.state[App]()
	mut rows := []gui.View{}
	for i in 0 .. 30 {
		text := if a.static {
			'row ${i}  fixed label  value=12345  t=1.2345  0xABCD'
		} else {
			// unique every redraw → new vglyph layout each time
			'row ${i}  value=${(a.n * 7 + i * 131) % 100000}  t=${f64(a.n) * 0.137 + f64(i):.4f}  0x${u32(a.n + i):06X}'
		}
		rows << gui.text(text: text)
	}
	return gui.column(content: rows)
}
