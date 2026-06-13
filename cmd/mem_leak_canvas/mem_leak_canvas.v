// mem_leak_canvas — isolate the gui draw_canvas polyline re-tessellation path.
// Mirrors the cantester Graphics panel and NOTHING else (no CAN, no text rows): a
// single draw_canvas drawing one polyline, re-tessellated every frame.
//
// Modes (env MEM_REPRO=changing|static, default changing):
//   - changing : version moves every frame → on_draw runs + the polyline geometry
//                changes → re-tessellate every frame (the cantester live-plot case).
//   - static   : version fixed → cache hit, on_draw skipped after the first frame.
// If `changing` climbs and `static` is flat, the leak is in gui's draw_canvas /
// polyline / SGL path (an upstream gui issue). If BOTH are flat, the cantester leak
// is NOT the canvas — it's a data structure (uncapped plot history / record buffer).
//
// Run:    v -enable-globals -path "@vlib|@vmodules|modules" run cmd/mem_leak_canvas/mem_leak_canvas.v
// Static: MEM_REPRO=static <same>
module main

import gui
import os
import time
import math

@[heap]
struct App {
mut:
	n      int
	static bool
}

fn main() {
	is_static := (os.getenv_opt('MEM_REPRO') or { 'changing' }) == 'static'
	mut win := gui.window(
		title:  'mem_leak_canvas — draw_canvas re-tessellation'
		state:  &App{ static: is_static }
		width:  720
		height: 460
		on_init: fn (mut w gui.Window) {
			w.update_view(view)
			spawn fn (mut w gui.Window) {
				mut last := time.ticks()
				for {
					time.sleep(50 * time.millisecond) // ~20 fps churn
					mut a := w.state[App]()
					a.n++
					if time.ticks() - last >= 2000 {
						last = time.ticks()
						mode := if a.static { 'static ' } else { 'changing' }
						println('  ${mode} frame=${a.n:6}  V-heap=${gc_memory_use() / 1024 / 1024} MB')
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
	println('mode=${os.getenv_opt('MEM_REPRO') or { 'changing' }} — watch OS RSS (WorkingSet).')
	win.run()
}

fn view(mut w gui.Window) gui.View {
	a := w.state[App]()
	n := a.n
	is_static := a.static
	canvas := gui.draw_canvas(
		id:      'plot'
		version: if is_static { u64(1) } else { u64(n) } // changing → re-tessellate each frame
		width:   700
		height:  420
		on_draw: fn [n, is_static] (mut dc gui.DrawContext) {
			cw := dc.width
			ch := dc.height
			phase := if is_static { f32(0) } else { f32(n) * 0.1 }
			mut pts := []f32{cap: 400}
			for i in 0 .. 200 {
				x := cw * f32(i) / 199.0
				y := ch * 0.5 + ch * 0.4 * f32(math.sin(f64(i) * 0.1 + f64(phase)))
				pts << x
				pts << y
			}
			dc.polyline(pts, gui.Color{60, 120, 220, 255}, 1.5, .round, .round)
		}
	)
	return gui.column(content: [canvas])
}
