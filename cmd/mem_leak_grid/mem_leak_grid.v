// mem_leak_grid — isolate the gui data_grid render path. Mirrors the blobly_net Trace
// grid (same columns) and NOTHING else: a data_grid of ~30 rows, redrawn ~20 fps.
//
// Modes (env MEM_REPRO=changing|static, default changing):
//   - changing : cell values change every frame (live-trace case).
//   - static   : fixed cell values.
// If `changing` climbs and `static` is flat, the leak is in gui's data_grid render
// (an upstream gui issue). If both are flat, the data_grid is innocent too, and the
// blobly_net leak is gui's whole-tree per-frame composition (scales with panel count).
//
// Run: v -enable-globals -path "@vlib|@vmodules|modules" run cmd/mem_leak_grid/mem_leak_grid.v
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
		title:  'mem_leak_grid — data_grid changing rows'
		state:  &App{ static: is_static }
		width:  860
		height: 560
		on_init: fn (mut w gui.Window) {
			w.update_view(view)
			spawn fn (mut w gui.Window) {
				mut last := time.ticks()
				for {
					time.sleep(50 * time.millisecond) // ~20 fps
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
	if ms := os.getenv_opt('BLOBLY_RUN_MS') {
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
	st := a.static
	mut rows := []gui.GridRow{}
	for i in 0 .. 30 {
		val := if st { 12345 } else { (n * 7 + i * 131) % 100000 }
		t := if st { f64(1.2345) } else { f64(n) * 0.137 + f64(i) }
		rows << gui.GridRow{
			id:    'r${i}'
			cells: {
				'time':  '${t:.6f}'
				'ch':    'CAN1'
				'count': if st { '1' } else { '${n}' }
				'id':    '0x${u32(0x100 + i):03X}'
				'name':  'Msg${i}'
				'dlc':   '8'
				'dir':   'Rx'
				'data':  if st { 'DE AD BE EF 00 11 22 33' } else { '${u32(val):08X} ${u32(n + i):08X}' }
			}
		}
	}
	grid := w.data_grid(
		id:            'grid'
		sizing:        gui.fill_fill
		row_height:    18
		header_height: 20
		columns:       [
			gui.GridColumnCfg{ id: 'time', title: 'Time(s)', width: 90, align: .end },
			gui.GridColumnCfg{ id: 'ch', title: 'Ch', width: 50, align: .start },
			gui.GridColumnCfg{ id: 'count', title: 'Count', width: 60, align: .end },
			gui.GridColumnCfg{ id: 'id', title: 'ID', width: 90, align: .start },
			gui.GridColumnCfg{ id: 'name', title: 'Name', width: 90, align: .start },
			gui.GridColumnCfg{ id: 'dlc', title: 'DLC', width: 50, align: .end },
			gui.GridColumnCfg{ id: 'dir', title: 'Dir', width: 50, align: .start },
			gui.GridColumnCfg{ id: 'data', title: 'Data', width: 300, align: .start },
		]
		rows:          rows
	)
	return gui.column(content: [grid])
}
