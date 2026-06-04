// CANTester — main application window.
//
// Live CAN tester on vcan0, built as a dockable workspace (gui dock_layout):
//   - Trace panel: grouped (one row per ID, click to expand into decoded signal
//     rows) or chronological "all" — toggled from the toolbar.
//   - Signals panel: live decode of 0x100 Powertrain.
//   - Send panel: transmit a frame.
//   - Statistics panel: bus counters.
// Panels can be split, tabbed, dragged to re-dock, and closed; the layout tree
// is persisted in app state. Run sut/can_sut.py to feed it traffic.
//
// Threading: a background thread blocks on bus.recv and hands each frame to the
// UI thread via w.queue_command. All app state mutates on the UI thread (no locks).
module main

import gui
import os
import time
import transport
import candb
import canlog
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
	bus       &transport.SocketCanBus = unsafe { nil }
	dock_root &gui.DockNode           = unsafe { nil }
	db        candb.Database // message catalog (loaded from DBC, sampledb fallback)
	db_source string
	connected bool
	status    string
	t0        i64
	trace     []TraceRow
	grouped   map[u32]MsgAgg
	order     []u32
	seq       int
	rx_count  int
	tx_count  int
	paused    bool
	mode      string = 'grouped' // 'grouped' | 'all'
	expand_id i64    = -1
	selection gui.GridSelection
	send_id   string = '101'
	send_data string = 'AABBCC'
	log_path  string // candump .log to open from the toolbar
}

fn main() {
	mut window := gui.window(
		title:   'CANTester — CAN'
		state:   &App{}
		width:   1180
		height:  680
		on_init: fn (mut w gui.Window) {
			mut app := w.state[App]()
			app.t0 = time.ticks()
			app.dock_root = default_layout()
			// Load the message catalog from a real DBC; fall back to the
			// hand-coded sampledb so the app still runs if the file is missing.
			dbc_path := os.getenv_opt('CANTESTER_DBC') or { 'dbc/cantester.dbc' }
			if db := candb.load_dbc_file(dbc_path) {
				app.db = db
				app.db_source = dbc_path
			} else {
				app.db = candb.Database{
					messages: sampledb.catalog()
				}
				app.db_source = 'sampledb (DBC load failed)'
			}
			app.log_path = os.getenv_opt('CANTESTER_LOG') or { '' }
			app.status = 'opening ${iface}…'
			w.update_view(main_view)
			if bus := transport.open_socketcan(iface) {
				app.bus = bus
				app.connected = true
				app.status = 'connected to ${iface}'
				spawn fn (mut w gui.Window) {
					rx_loop(mut w)
				}(mut w)
			} else {
				app.status = 'open ${iface} failed: ${err} (run scripts/setup_vcan.sh)'
			}
		}
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

// Trace (left) | Signals / Send / Statistics stacked (right) — each its own
// panel so all are visible. They can still be tabbed/dragged by the user.
fn default_layout() &gui.DockNode {
	return gui.dock_split('root', .horizontal, 0.62, gui.dock_panel_group('g_trace', ['trace'],
		'trace'), gui.dock_split('r1', .vertical, 0.32, gui.dock_panel_group('g_sig', ['signals'],
		'signals'), gui.dock_split('r2', .vertical, 0.64, gui.dock_panel_group('g_send', ['send'],
		'send'), gui.dock_panel_group('g_stats', ['stats'], 'stats'))))
}

fn rx_loop(mut w gui.Window) {
	app := w.state[App]()
	bus := app.bus
	for app.connected {
		frame := bus.recv(200) or { continue }
		w.queue_command(fn [frame] (mut w gui.Window) {
			mut a := w.state[App]()
			if !a.paused {
				a.push('RX', frame)
				w.update_window()
			}
		})
	}
}

// push records a live frame, stamping it with the current wall-clock offset.
fn (mut app App) push(dir string, f transport.CanFrame) {
	app.record(dir, f, f64(time.ticks() - app.t0))
}

// record appends a frame to the trace + grouped aggregate at an explicit time
// (ms). Live capture passes "now"; log replay passes the recorded timestamp.
fn (mut app App) record(dir string, f transport.CanFrame, t_ms f64) {
	app.seq++
	if dir == 'RX' {
		app.rx_count++
	} else {
		app.tx_count++
	}
	name := if m := app.db.lookup(f.id) { m.name } else { '' }
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

fn main_view(mut window gui.Window) gui.View {
	w, h := window.window_size()
	app := window.state[App]()

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_medium
		spacing: 8
		content: [
			toolbar(app),
			gui.dock_layout(
				id:               'dock'
				root:             app.dock_root
				panels:           [
					gui.DockPanelDef{ id: 'trace', label: 'Trace', content: [trace_panel(mut window)] },
					gui.DockPanelDef{ id: 'signals', label: 'Signals', content: [signals_panel(app)] },
					gui.DockPanelDef{ id: 'send', label: 'Send', content: [send_panel(app)] },
					gui.DockPanelDef{ id: 'stats', label: 'Statistics', content: [stats_panel(app)] },
				]
				on_layout_change: fn (nr &gui.DockNode, mut w gui.Window) {
					mut a := w.state[App]()
					a.dock_root = unsafe { nr }
				}
				on_panel_select:  fn (group_id string, panel_id string, mut w gui.Window) {
					mut a := w.state[App]()
					a.dock_root = gui.dock_tree_select_panel(a.dock_root, group_id, panel_id)
				}
				on_panel_close:   fn (panel_id string, mut w gui.Window) {
					mut a := w.state[App]()
					a.dock_root = gui.dock_tree_remove_panel(a.dock_root, panel_id)
				}
			),
		]
	)
}

fn toolbar(app &App) gui.View {
	dot := if app.connected { '🟢' } else { '🔴' }
	return gui.row(
		v_align: .middle
		sizing:  gui.fill_fit
		spacing: 10
		content: [
			gui.text(text: 'CANTester', text_style: gui.theme().b1),
			gui.text(text: '${dot} ${app.status}', text_style: gui.theme().n4),
			gui.text(text: 'RX ${app.rx_count}  TX ${app.tx_count}', text_style: gui.theme().n4),
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
				content:  [gui.text(text: if app.paused { '▶ Resume' } else { '⏸ Pause' })]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.paused = !a.paused
				}
			),
			gui.button(
				id_focus: 102
				content:  [gui.text(text: '🗑 Clear')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.trace = []TraceRow{}
					a.grouped = map[u32]MsgAgg{}
					a.order = []u32{}
					a.expand_id = -1
				}
			),
			gui.input(
				id_focus:        13
				text:            app.log_path
				width:           220
				height:          30
				padding:         gui.Padding{4, 8, 4, 8}
				sizing:          gui.fixed_fixed
				placeholder:     'path/to/capture.log'
				on_enter:        fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					a := w.state[App]()
					load_log(a.log_path, mut w)
				}
				on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
					mut a := w.state[App]()
					a.log_path = s
				}
			),
			gui.button(
				id_focus: 14
				content:  [gui.text(text: '📂 Open Log')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					// Try a native file picker; on a box without one (e.g. WSLg
					// with no zenity/kdialog) the bridge returns .error, so we
					// fall back to the path typed in the box.
					typed := w.state[App]().log_path
					w.native_open_dialog(
						title:   'Open CAN log (candump .log)'
						filters: [gui.NativeFileFilter{ name: 'CAN logs', extensions: ['log'] }]
						on_done: fn [typed] (result gui.NativeDialogResult, mut w gui.Window) {
							match result.status {
								.ok {
									paths := result.path_strings()
									if paths.len > 0 {
										load_log(paths[0], mut w)
									}
								}
								.cancel {}
								.error {
									if typed.trim_space().len > 0 {
										load_log(typed, mut w)
									} else {
										mut a := w.state[App]()
										a.status = 'no file picker (install zenity) — type a log path + Enter'
									}
								}
							}
						}
					)
				}
			),
		]
	)
}

fn trace_panel(mut window gui.Window) gui.View {
	_, h := window.window_size()
	app := window.state[App]()
	grouped := app.mode == 'grouped'
	grid_h := f32(h) - 130

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
				if m := app.db.lookup(id) {
					for s in m.active_signals(a.last) {
						raw := s.raw_value(a.last)
						label := s.label(a.last)
						value := if label != '' {
							'${s.physical(a.last):.2f} ${s.unit} (${label})'
						} else {
							'${s.physical(a.last):.2f} ${s.unit}'
						}
						rows << gui.GridRow{
							id:    's:${id}:${s.name}'
							cells: {
								'id':    '       ${s.name}'
								'name':  value
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
		return window.data_grid(
			id:                  'trace_grouped'
			sizing:              gui.fill_fill
			max_height:          grid_h
			columns:             [
				tcol('id', 'ID / Signal', 200, .start),
				tcol('name', 'Message / Value', 150, .start),
				tcol('dlc', 'DLC / Raw', 90, .end),
				tcol('data', 'Data / Interpretation', 300, .start),
				tcol('count', 'Count', 70, .end),
				tcol('time', 'Last(ms)', 90, .end),
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
	}
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
	return window.data_grid(
		id:             'trace_all'
		sizing:         gui.fill_fill
		max_height:     grid_h
		columns:        [
			tcol('time', 'Time(ms)', 80, .end),
			tcol('dir', 'Dir', 50, .start),
			tcol('id', 'ID', 110, .start),
			tcol('dlc', 'DLC', 50, .end),
			tcol('data', 'Data', 300, .start),
			tcol('name', 'Message', 150, .start),
		]
		rows:           rows
		on_cell_format: trace_cell_format
	)
}

fn signals_panel(app &App) gui.View {
	ptmsg := app.db.lookup(0x100) or { sampledb.powertrain() }
	pt := (app.grouped[ptmsg.id] or { MsgAgg{} }).last
	mut lines := []gui.View{}
	lines << gui.text(text: 'Signals — 0x100 ${ptmsg.name}', text_style: gui.theme().b3)
	if pt.len == 8 {
		for s in ptmsg.active_signals(pt) {
			label := s.label(pt)
			suffix := if label != '' { ' (${label})' } else { '' }
			lines << gui.text(text: '${s.name}: ${s.physical(pt):.1f} ${s.unit}${suffix}',
				text_style: gui.theme().n4)
		}
	} else {
		lines << gui.text(text: '(waiting for 0x100 frames…)', text_style: gui.theme().n4)
	}
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		spacing: 5
		content: lines
	)
}

fn stats_panel(app &App) gui.View {
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		spacing: 5
		content: [
			gui.text(text: 'Bus statistics', text_style: gui.theme().b3),
			gui.text(text: 'RX frames: ${app.rx_count}', text_style: gui.theme().n4),
			gui.text(text: 'TX frames: ${app.tx_count}', text_style: gui.theme().n4),
			gui.text(text: 'Unique IDs: ${app.order.len}', text_style: gui.theme().n4),
			gui.text(text: 'Interface: ${iface}', text_style: gui.theme().n4),
			gui.text(text: 'Database: ${app.db.messages.len} msgs', text_style: gui.theme().n4),
			gui.text(text: 'DB source: ${app.db_source}', text_style: gui.theme().n4),
		]
	)
}

fn send_panel(app &App) gui.View {
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		spacing: 8
		content: [
			gui.text(text: 'Transmit a frame', text_style: gui.theme().b3),
			gui.row(
				v_align: .middle
				sizing:  gui.fill_fit
				spacing: 6
				content: [
					gui.text(text: 'id', text_style: gui.theme().n4),
					gui.input(
						id_focus:        10
						text:            app.send_id
						width:           90
						height:          34
						padding:         gui.Padding{4, 8, 4, 8}
						sizing:          gui.fixed_fixed
						placeholder:     'hex id'
						on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
							mut a := w.state[App]()
							a.send_id = s
						}
					),
				]
			),
			gui.row(
				v_align: .middle
				sizing:  gui.fill_fit
				spacing: 6
				content: [
					gui.text(text: 'data', text_style: gui.theme().n4),
					gui.input(
						id_focus:        11
						text:            app.send_data
						width:           200
						height:          34
						padding:         gui.Padding{4, 8, 4, 8}
						sizing:          gui.fixed_fixed
						placeholder:     'hex bytes'
						on_enter:        fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							do_send(mut w)
						}
						on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
							mut a := w.state[App]()
							a.send_data = s
						}
					),
				]
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
	app.push('TX', frame)
}

// load_log opens a candump `.log` file and shows it as a static capture:
// live RX is paused and the trace is reset so the recording stands alone, with
// each frame stamped by its recorded timestamp. The grouped view keeps every
// unique ID + count; the chronological view shows the tail (max_trace cap).
fn load_log(path string, mut w gui.Window) {
	mut app := w.state[App]()
	p := path.trim_space()
	if p.len == 0 {
		app.status = 'no file picker here — type a log path and press Enter'
		return
	}
	entries := canlog.load_file(p) or {
		app.status = 'open log failed: ${err}'
		return
	}
	app.paused = true
	app.log_path = p
	app.trace = []TraceRow{}
	app.grouped = map[u32]MsgAgg{}
	app.order = []u32{}
	app.expand_id = -1
	app.rx_count = 0
	app.tx_count = 0
	app.seq = 0
	// candump stamps absolute epoch seconds; show times relative to the first
	// frame so the Time(ms) column reads 0, 100, 200… not a huge epoch value.
	t0_log := if entries.len > 0 { entries[0].t_s } else { 0.0 }
	for e in entries {
		app.record('RX', e.frame, (e.t_s - t0_log) * 1000.0)
	}
	app.status = 'loaded ${entries.len} frames from ${os.base(p)} (paused — Resume for live)'
	w.update_window()
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

// tcol builds a trace column: resizable + reorderable (gui defaults), NOT
// sortable (sorting a live trace would reshuffle the streaming rows), and with
// max_width lifted from gui's 600 default so it can be widened freely.
fn tcol(id string, title string, width f32, align gui.HorizontalAlign) gui.GridColumnCfg {
	return gui.GridColumnCfg{
		id:        id
		title:     title
		width:     width
		align:     align
		sortable:  false
		max_width: 4000
	}
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
	clean := s.replace(' ', '').trim_string_left('0x')
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
