// CANTester — main application window (Phase 3).
//
// A live CAN tester shell: opens vcan0, reads frames on a background thread into
// a trace table, decodes known IDs into signals via `candb`, and sends frames
// from a small form. Run the Python virtual SUT (sut/can_sut.py) to give it
// traffic. Logic lives in modules/ (transport, candb, sampledb); this file is
// the view + glue.
module main

import gui
import sync
import time
import transport
import candb
import sampledb

const iface = 'vcan0'
const max_trace = 1000 // rows retained in memory
const max_shown = 250  // newest rows rendered

struct TraceRow {
	seq  int
	t_ms f64
	dir  string // 'RX' | 'TX'
	id   u32
	ext  bool
	dlc  int
	data []u8
	name string // decoded message name, or ''
}

@[heap]
struct App {
mut:
	mtx       sync.Mutex
	bus       &transport.SocketCanBus = unsafe { nil }
	connected bool
	status    string
	t0        i64
	// shared with RX thread (guard with mtx): trace, counts, last_pt, paused
	trace    []TraceRow
	seq      int
	rx_count int
	tx_count int
	paused   bool
	last_pt  []u8
	// send form (UI thread only)
	send_id   string = '101'
	send_data string = 'AABBCC'
}

fn main() {
	mut window := gui.window(
		title:   'CANTester — CAN'
		state:   &App{}
		width:   1040
		height:  640
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

// rx_loop runs on a background thread: block for frames and append to the trace.
fn rx_loop(mut app App) {
	for app.connected {
		frame := app.bus.recv(200) or { continue } // 'timeout' or transient
		app.mtx.lock()
		if !app.paused {
			app.push('RX', frame)
			if frame.id == sampledb.powertrain().id {
				app.last_pt = frame.data.clone()
			}
		}
		app.mtx.unlock()
	}
}

// push appends a row. Caller must hold mtx.
fn (mut app App) push(dir string, f transport.CanFrame) {
	app.seq++
	if dir == 'RX' {
		app.rx_count++
	} else {
		app.tx_count++
	}
	name := if m := sampledb.lookup(f.id) { m.name } else { '' }
	app.trace << TraceRow{
		seq:  app.seq
		t_ms: f64(time.ticks() - app.t0)
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
}

// start_ui_timer re-arms a short timer so the view redraws and picks up new
// frames from the RX thread (~20 fps). Keeps all gui calls on the UI thread.
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

	// Snapshot shared state quickly under lock, then build the view unlocked.
	app.mtx.lock()
	rx := app.rx_count
	tx := app.tx_count
	paused := app.paused
	pt := app.last_pt.clone()
	n := app.trace.len
	start := if n > max_shown { n - max_shown } else { 0 }
	mut rows := []gui.GridRow{cap: n - start}
	for i := n - 1; i >= start; i-- {
		r := app.trace[i]
		rows << gui.GridRow{
			id:    '${r.seq}'
			cells: {
				'time': '${r.t_ms:.0f}'
				'dir':  r.dir
				'id':   if r.ext { '0x${r.id:08X}' } else { '0x${r.id:03X}' }
				'dlc':  '${r.dlc}'
				'data': hex(r.data)
				'name': r.name
			}
		}
	}
	app.mtx.unlock()

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_medium
		spacing: 8
		content: [
			toolbar(app, rx, tx, paused),
			gui.row(
				sizing:  gui.fill_fill
				spacing: 10
				content: [
					gui.column(
						sizing:  gui.fill_fill
						content: [
							window.data_grid(
								id:         'trace'
								max_height:  f32(h) - 170
								columns:    [
									gui.GridColumnCfg{ id: 'time', title: 'Time(ms)', width: 80, align: .end },
									gui.GridColumnCfg{ id: 'dir', title: 'Dir', width: 50 },
									gui.GridColumnCfg{ id: 'id', title: 'ID', width: 100 },
									gui.GridColumnCfg{ id: 'dlc', title: 'DLC', width: 50, align: .end },
									gui.GridColumnCfg{ id: 'data', title: 'Data', width: 230 },
									gui.GridColumnCfg{ id: 'name', title: 'Message', width: 130 },
								]
								rows:           rows
								on_cell_format: trace_cell_format
							),
						]
					),
					signals_panel(pt),
				]
			),
			send_panel(app),
		]
	)
}

fn toolbar(app &App, rx int, tx int, paused bool) gui.View {
	dot := if app.connected { '🟢' } else { '🔴' }
	return gui.row(
		v_align: .middle
		sizing:  gui.fill_fit
		spacing: 12
		content: [
			gui.text(text: 'CANTester', text_style: gui.theme().b1),
			gui.text(text: '${dot} ${app.status}', text_style: gui.theme().n4),
			gui.text(text: 'RX ${rx}  TX ${tx}', text_style: gui.theme().n4),
			gui.button(
				id_focus: 100
				content:  [gui.text(text: if paused { '▶ Resume' } else { '⏸ Pause' })]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.mtx.lock()
					a.paused = !a.paused
					a.mtx.unlock()
				}
			),
			gui.button(
				id_focus: 101
				content:  [gui.text(text: '🗑 Clear')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.mtx.lock()
					a.trace = []TraceRow{}
					a.mtx.unlock()
				}
			),
		]
	)
}

fn signals_panel(pt []u8) gui.View {
	mut lines := []gui.View{}
	lines << gui.text(text: 'Signals — 0x100 Powertrain', text_style: gui.theme().b3)
	if pt.len == 8 {
		for s in sampledb.powertrain().signals {
			lines << gui.text(text: '${s.name}: ${s.physical(pt):.1f} ${s.unit}',
				text_style: gui.theme().n4)
		}
	} else {
		lines << gui.text(text: '(waiting for 0x100 frames…)', text_style: gui.theme().n4)
	}
	return gui.column(
		width:   300
		sizing:  gui.fixed_fill
		padding: gui.padding_medium
		spacing: 5
		color:   gui.Color{30, 30, 40, 255}
		radius:  6
		content: lines
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
				width:           240
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
	mut clean := s.trim_space().trim_string_left('0x').trim_string_left('0X')
	mut v := u32(0)
	for c in clean {
		d := hex_digit(c) or { continue }
		v = v * 16 + u32(d)
	}
	return v
}

fn hex_to_bytes(s string) []u8 {
	mut clean := s.replace(' ', '').trim_string_left('0x')
	if clean.len % 2 != 0 {
		clean = '0' + clean
	}
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
