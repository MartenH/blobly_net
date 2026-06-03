// CANTester — main application window (Phase 3+).
//
// A live CAN tester shell on vcan0. Two trace views:
//   - Grouped: one row per CAN ID (latest data), expandable (▸) into decoded
//     signals — name / value / raw / interpretation, via `candb` + `sampledb`.
//   - All: chronological scroll of every frame.
// Plus a send form. Run sut/can_sut.py to feed it traffic. Logic lives in
// modules/ (transport, candb, sampledb); this file is view + glue.
module main

import gui
import sync
import time
import transport
import sampledb

const iface = 'vcan0'
const max_trace = 1000
const max_shown = 250

struct TraceRow {
	seq  int
	t_ms f64
	dir  string
	id   u32
	ext  bool
	dlc  int
	data []u8
	name string
}

// MsgAgg is the latest state of one CAN ID, for the grouped view.
struct MsgAgg {
mut:
	id      u32
	ext     bool
	last    []u8
	count   int
	last_ms f64
	name    string
}

@[heap]
struct App {
mut:
	mtx       sync.Mutex
	bus       &transport.SocketCanBus = unsafe { nil }
	connected bool
	status    string
	t0        i64
	// shared with RX thread (guard with mtx)
	trace    []TraceRow
	grouped  map[u32]MsgAgg
	order    []u32
	seq      int
	rx_count int
	tx_count int
	paused   bool
	// UI-thread only
	mode      string = 'grouped' // 'grouped' | 'all'
	expand_id i64    = -1         // grouped frame currently expanded into signals
	selection gui.GridSelection
	send_id   string = '101'
	send_data string = 'AABBCC'
}

fn main() {
	mut window := gui.window(
		title:   'CANTester — CAN'
		state:   &App{}
		width:   1100
		height:  660
		on_init: fn (mut w gui.Window) {
			mut app := w.state[App]()
			app.t0 = time.ticks()
			app.status = 'opening ${iface}…'
			w.update_view(main_view)
			if bus := transport.open_socketcan(iface) {
				app.bus = bus
				app.connected = true
				app.status = 'connected to ${iface}'
				spawn rx_loop(mut app)
			} else {
				app.status = 'open ${iface} failed: ${err} (run scripts/setup_vcan.sh)'
			}
			start_ui_timer(mut w)
		}
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

fn rx_loop(mut app App) {
	for app.connected {
		frame := app.bus.recv(200) or { continue }
		app.mtx.lock()
		if !app.paused {
			app.push('RX', frame)
		}
		app.mtx.unlock()
	}
}

// push records a frame into both the chronological trace and the grouped map.
// Caller must hold mtx.
fn (mut app App) push(dir string, f transport.CanFrame) {
	app.seq++
	if dir == 'RX' {
		app.rx_count++
	} else {
		app.tx_count++
	}
	t_ms := f64(time.ticks() - app.t0)
	name := if m := sampledb.lookup(f.id) { m.name } else { '' }
	app.trace << TraceRow{
		seq:  app.seq
		t_ms: t_ms
		dir:  dir
		id:   f.id
		ext:  f.extended
		dlc:  f.data.len
		data: f.data.clone()
		name: name
	}
	if app.trace.len > max_trace {
		app.trace.delete(0)
	}
	if f.id !in app.grouped {
		app.order << f.id
	}
	app.grouped[f.id] = MsgAgg{
		id:      f.id
		ext:     f.extended
		last:    f.data.clone()
		count:   (app.grouped[f.id] or { MsgAgg{} }).count + 1
		last_ms: t_ms
		name:    name
	}
}

fn start_ui_timer(mut w gui.Window) {
	w.animation_add(mut gui.TweenAnimation{
		id:       'ui_tick'
		from:     0
		to:       1
		duration: 50 * time.millisecond
		on_value: fn (_ f32, mut _ gui.Window) {}
		on_done:  fn (mut w gui.Window) {
			start_ui_timer(mut w)
		}
	})
}

fn main_view(mut window gui.Window) gui.View {
	w, h := window.window_size()
	mut app := window.state[App]()

	grouped := app.mode == 'grouped'
	app.mtx.lock()
	rx := app.rx_count
	tx := app.tx_count
	paused := app.paused
	mut rows := []gui.GridRow{}
	if grouped {
		for id in app.order {
			a := app.grouped[id] or { continue }
			expanded := app.expand_id == i64(id)
			chevron := if expanded { '▼' } else { '▶' }
			rows << gui.GridRow{
				id:    '${id}'
				cells: {
					'id':    '${chevron} ${hexid(id, a.ext)}'
					'name':  a.name
					'dlc':   '${a.last.len}'
					'data':  hex(a.last)
					'count': '${a.count}'
					'time':  '${a.last_ms:.0f}'
				}
			}
			if expanded {
				if m := sampledb.lookup(id) {
					for s in m.signals {
						raw := s.raw_value(a.last)
						rows << gui.GridRow{
							id:    's:${id}:${s.name}'
							cells: {
								'id':    '       ${s.name}'
								'name':  '${s.physical(a.last):.2f} ${s.unit}'
								'dlc':   '0x${raw:X}'
								'data':  s.desc
								'count': ''
								'time':  ''
							}
						}
					}
				}
			}
		}
	} else {
		n := app.trace.len
		start := if n > max_shown { n - max_shown } else { 0 }
		for i := n - 1; i >= start; i-- {
			r := app.trace[i]
			rows << gui.GridRow{
				id:    '${r.seq}'
				cells: {
					'time': '${r.t_ms:.0f}'
					'dir':  r.dir
					'id':   hexid(r.id, r.ext)
					'dlc':  '${r.dlc}'
					'data': hex(r.data)
					'name': r.name
				}
			}
		}
	}
	app.mtx.unlock()

	grid_h := f32(h) - 150
	trace := if grouped {
		window.data_grid(
			id:                  'trace_grouped'
			max_height:          grid_h
			columns:             [
				gui.GridColumnCfg{ id: 'id', title: 'ID / Signal', width: 200 },
				gui.GridColumnCfg{ id: 'name', title: 'Message / Value', width: 150 },
				gui.GridColumnCfg{ id: 'dlc', title: 'DLC / Raw', width: 90, align: .end },
				gui.GridColumnCfg{ id: 'data', title: 'Data / Interpretation', width: 300 },
				gui.GridColumnCfg{ id: 'count', title: 'Count', width: 70, align: .end },
				gui.GridColumnCfg{ id: 'time', title: 'Last(ms)', width: 90, align: .end },
			]
			rows:                rows
			selection:           app.selection
			on_selection_change: fn (selection gui.GridSelection, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				a.selection = selection
				rid := selection.active_row_id
				if rid.len > 0 && !rid.starts_with('s:') {
					id := i64(rid.u32())
					a.expand_id = if a.expand_id == id { i64(-1) } else { id }
				}
			}
			on_cell_format:      trace_cell_format
		)
	} else {
		window.data_grid(
			id:             'trace_all'
			max_height:     grid_h
			columns:        [
				gui.GridColumnCfg{ id: 'time', title: 'Time(ms)', width: 80, align: .end },
				gui.GridColumnCfg{ id: 'dir', title: 'Dir', width: 50 },
				gui.GridColumnCfg{ id: 'id', title: 'ID', width: 110 },
				gui.GridColumnCfg{ id: 'dlc', title: 'DLC', width: 50, align: .end },
				gui.GridColumnCfg{ id: 'data', title: 'Data', width: 250 },
				gui.GridColumnCfg{ id: 'name', title: 'Message', width: 150 },
			]
			rows:           rows
			on_cell_format: trace_cell_format
		)
	}

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_medium
		spacing: 8
		content: [
			toolbar(app, rx, tx, paused),
			trace,
			send_panel(app),
		]
	)
}

fn toolbar(app &App, rx int, tx int, paused bool) gui.View {
	dot := if app.connected { '🟢' } else { '🔴' }
	return gui.row(
		v_align: .middle
		sizing:  gui.fill_fit
		spacing: 10
		content: [
			gui.text(text: 'CANTester', text_style: gui.theme().b1),
			gui.text(text: '${dot} ${app.status}', text_style: gui.theme().n4),
			gui.text(text: 'RX ${rx}  TX ${tx}', text_style: gui.theme().n4),
			gui.button(
				id_focus: 100
				content:  [gui.text(text: 'View: ${app.mode}')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.mode = if a.mode == 'grouped' { 'all' } else { 'grouped' }
				}
			),
			gui.button(
				id_focus: 101
				content:  [gui.text(text: if paused { '▶ Resume' } else { '⏸ Pause' })]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.mtx.lock()
					a.paused = !a.paused
					a.mtx.unlock()
				}
			),
			gui.button(
				id_focus: 102
				content:  [gui.text(text: '🗑 Clear')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.mtx.lock()
					a.trace = []TraceRow{}
					a.grouped = map[u32]MsgAgg{}
					a.order = []u32{}
					a.mtx.unlock()
					a.expand_id = -1
				}
			),
		]
	)
}

fn send_panel(app &App) gui.View {
	return gui.row(
		v_align: .middle
		sizing:  gui.fill_fit
		spacing: 8
		content: [
			gui.text(text: 'Send  id', text_style: gui.theme().n4),
			gui.input(
				id_focus:        10
				text:            app.send_id
				width:           90
				sizing:          gui.fixed_fit
				placeholder:     'hex id'
				on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
					mut a := w.state[App]()
					a.send_id = s
				}
			),
			gui.text(text: 'data', text_style: gui.theme().n4),
			gui.input(
				id_focus:        11
				text:            app.send_data
				width:           250
				sizing:          gui.fixed_fit
				placeholder:     'hex bytes'
				on_enter:        fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					do_send(mut w)
				}
				on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
					mut a := w.state[App]()
					a.send_data = s
				}
			),
			gui.button(
				id_focus: 12
				content:  [gui.text(text: '➤ Send')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					do_send(mut w)
				}
			),
		]
	)
}

fn do_send(mut w gui.Window) {
	mut app := w.state[App]()
	if !app.connected {
		return
	}
	id := parse_hex_u32(app.send_id)
	frame := transport.CanFrame{
		id:       id
		extended: id > 0x7ff
		data:     hex_to_bytes(app.send_data)
	}
	app.bus.send(frame) or {
		app.status = 'send failed: ${err}'
		return
	}
	app.mtx.lock()
	app.push('TX', frame)
	app.mtx.unlock()
}

fn trace_cell_format(row gui.GridRow, _ int, col gui.GridColumnCfg, value string, mut _ gui.Window) gui.GridCellFormat {
	if col.id == 'dir' && value == 'TX' {
		return gui.GridCellFormat{
			has_text_color: true
			text_color:     gui.Color{240, 200, 90, 255}
		}
	}
	if col.id == 'name' && value.len > 0 {
		return gui.GridCellFormat{
			has_text_color: true
			text_color:     gui.Color{120, 220, 150, 255}
		}
	}
	return gui.GridCellFormat{}
}

fn hexid(id u32, ext bool) string {
	return if ext { '0x${id:08X}' } else { '0x${id:03X}' }
}

fn hex(data []u8) string {
	mut s := ''
	for i, b in data {
		if i > 0 {
			s += ' '
		}
		s += '${b:02X}'
	}
	return s
}

fn parse_hex_u32(s string) u32 {
	clean := s.trim_space().trim_string_left('0x').trim_string_left('0X')
	mut v := u32(0)
	for c in clean {
		d := hex_digit(c) or { continue }
		v = v * 16 + u32(d)
	}
	return v
}

fn hex_to_bytes(s string) []u8 {
	mut clean := s.replace(' ', '').trim_string_left('0x')
	mut out := []u8{}
	mut hi := -1
	for c in clean {
		d := hex_digit(c) or { continue }
		if hi < 0 {
			hi = d
		} else {
			out << u8(hi * 16 + d)
			hi = -1
		}
	}
	return out
}

fn hex_digit(c u8) ?int {
	return match c {
		`0`...`9` { int(c - `0`) }
		`a`...`f` { int(c - `a` + 10) }
		`A`...`F` { int(c - `A` + 10) }
		else { none }
	}
}
