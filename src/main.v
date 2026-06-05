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
import sokol.sapp
import transport
import candb
import canlog
import sampledb
import project

const max_trace = 1000 // ring-buffer cap on retained frames (all are scrollable)
const default_fps = 5  // trace repaint rate; user-tunable (3/5/10) from the toolbar
const fps_options = ['3 fps', '5 fps', '10 fps']

// flush_ms_for converts a repaint rate (fps) to the RX batch/repaint interval.
// The UI refresh rate — not the bus frame rate — sets the CPU cost, because each
// repaint forces a full GL frame (very expensive under WSLg's GL translation).
// Cost is spread across the whole view (data_grid ~1/3, rest = GL floor +
// recomposing all panels). See rx_loop + docs/known_issues.md.
fn flush_ms_for(fps int) i64 {
	return if fps > 0 { i64(1000 / fps) } else { i64(1000 / default_fps) }
}

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

// ChannelRT is the live runtime state of one configured channel (bus).
struct ChannelRT {
mut:
	bus      ?transport.Bus // backend (SocketCAN or udp software bus); none until opened
	running  bool
	err      bool // open failed / bus error
	rx_count int
	tx_count int
	note     string
}

@[heap]
struct App {
mut:
	dock_root      &gui.DockNode = unsafe { nil }
	proj           project.Project // bus setup (loaded from a .yml; built-in default fallback)
	proj_source    string
	rt             []ChannelRT // runtime per proj.channels (parallel index)
	running        bool        // measurement started?
	db             candb.Database // message catalog (loaded from DBC, sampledb fallback)
	db_source      string
	status         string
	t0             i64
	trace     []TraceRow
	grouped   map[u32]MsgAgg
	order     []u32
	seq       int
	rx_count  int
	tx_count  int
	paused    bool
	mode      string = 'grouped' // 'grouped' | 'all'
	expanded  map[u32]bool // grouped-trace IDs currently expanded (multi-select)
	sel_id    i64 = -1     // message ID the Signals panel inspects (trace selection)
	selection gui.GridSelection
	send_id   string = '101'
	send_data string = 'AABBCC'
	log_path  string // candump .log to open from the toolbar
	fps       int = default_fps // trace repaint rate (toolbar dropdown)
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
			// Load the project (bus setup) — env override, else the default file,
			// else a built-in single-vcan0 default so the app always runs.
			proj_path := os.getenv_opt('CANTESTER_PROJECT') or { 'projects/demo.yml' }
			if p := project.load(proj_path) {
				app.proj = p
				app.proj_source = proj_path
			} else {
				app.proj = project.default_project()
				app.proj_source = 'built-in default (${err})'
			}
			app.rt = []ChannelRT{len: app.proj.channels.len}
			app.load_databases()
			app.log_path = os.getenv_opt('CANTESTER_LOG') or { '' }
			app.status = 'stopped — press ▶ Start (${app.proj.channels.len} channel(s))'
			w.update_view(main_view)
		}
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

// Buses (narrow left) | Trace (centre) | Signals / Send / Statistics stacked
// (right) — each its own panel. They can still be tabbed/dragged by the user.
fn default_layout() &gui.DockNode {
	right := gui.dock_split('r1', .vertical, 0.22, gui.dock_panel_group('g_sig', ['signals'],
		'signals'), gui.dock_split('r2', .vertical, 0.66, gui.dock_panel_group('g_send', ['send'],
		'send'), gui.dock_panel_group('g_stats', ['stats'], 'stats')))
	mid := gui.dock_split('mid', .horizontal, 0.66, gui.dock_panel_group('g_trace', ['trace'],
		'trace'), right)
	return gui.dock_split('root', .horizontal, 0.17, gui.dock_panel_group('g_buses', ['buses'],
		'buses'), mid)
}

// load_databases loads the message catalog from the first channel that names a
// DBC; falls back to the hand-coded sampledb so the app still decodes.
fn (mut app App) load_databases() {
	for ch in app.proj.channels {
		if ch.databases.len > 0 {
			if db := candb.load_dbc_file(ch.databases[0]) {
				app.db = db
				app.db_source = ch.databases[0]
				return
			}
		}
	}
	app.db = candb.Database{
		messages: sampledb.catalog()
	}
	app.db_source = 'sampledb (no DBC in project)'
}

// start_measurement attaches every enabled monitor channel: opens its bus and
// spawns an RX thread. (Replay channels are wired in a later phase.)
fn start_measurement(mut w gui.Window) {
	mut app := w.state[App]()
	if app.running {
		return
	}
	mut opened := 0
	for i, ch in app.proj.channels {
		app.rt[i].err = false
		app.rt[i].note = ''
		if !ch.enabled {
			app.rt[i].note = 'disabled'
			continue
		}
		if ch.mode != .monitor {
			app.rt[i].note = '${ch.mode} (not yet wired)'
			continue
		}
		if bus := transport.open(ch.iface) {
			app.rt[i].bus = bus
			app.rt[i].running = true
			app.rt[i].note = 'monitoring'
			opened++
			spawn fn [i] (mut w gui.Window) {
				rx_loop(i, mut w)
			}(mut w)
		} else {
			app.rt[i].err = true
			app.rt[i].note = 'open failed: ${err}'
		}
	}
	app.running = true
	app.status = 'running — ${opened} channel(s) attached'
}

// stop_measurement signals every running channel's RX thread to exit; each
// thread closes its own bus on the way out (avoids closing under a blocked recv).
fn stop_measurement(mut w gui.Window) {
	mut app := w.state[App]()
	for i in 0 .. app.rt.len {
		if app.rt[i].running {
			app.rt[i].running = false
			app.rt[i].note = 'stopped'
		}
	}
	app.running = false
	app.status = 'stopped'
}

// rx_loop reads frames and hands them to the UI in **batches**, not one-by-one.
// Each w.queue_command wakes sokol and forces a full GL frame (~tens of ms under
// WSLg's GL translation), so one wake per frame pegs the CPU on a busy bus. We
// instead accumulate frames in a thread-local batch and flush every rx_flush_ms
// — every frame is still recorded, but the UI repaints at a bounded rate. The
// batch is moved into the closure, so all state mutates on the UI thread (no locks).
fn rx_loop(idx int, mut w gui.Window) {
	app := w.state[App]()
	mut bus := app.rt[idx].bus or { return }
	mut batch := []transport.CanFrame{}
	mut last_flush := time.ticks()
	for app.rt[idx].running {
		flush_ms := flush_ms_for(app.fps) // live: reflects the toolbar dropdown
		if frame := bus.recv(int(flush_ms)) {
			batch << frame
		}
		now := time.ticks()
		if batch.len > 0 && now - last_flush >= flush_ms {
			last_flush = now
			frames := batch.clone()
			batch.clear()
			w.queue_command(fn [frames, idx] (mut w gui.Window) {
				mut a := w.state[App]()
				if a.paused {
					return
				}
				a.rt[idx].rx_count += frames.len
				for f in frames {
					a.push('RX', f)
				}
				w.update_window()
			})
		}
	}
	bus.close()
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
	// Trim in bulk, not per-frame: delete(0) shifts the whole array every frame
	// (O(n)) and dominates CPU on a busy bus. Let it overrun by 1/4, then slice
	// back to the cap — amortised O(1) per frame.
	if app.trace.len > max_trace + max_trace / 4 {
		app.trace = app.trace[app.trace.len - max_trace..].clone()
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
			menu_bar(mut window),
			toolbar(mut window),
			gui.dock_layout(
				id:               'dock'
				root:             app.dock_root
				panels:           [
					gui.DockPanelDef{ id: 'trace', label: 'Trace', content: [trace_panel(mut window)] },
					gui.DockPanelDef{ id: 'buses', label: 'Buses', content: [buses_panel(app)] },
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

// menu_bar is the top menubar. File covers projects + recordings + exit; the
// other menus are scaffolded for later (Phase 9). Project/Recording opens reuse
// the native picker (zenity on Linux) with the typed-path/log box as fallback.
fn menu_bar(mut window gui.Window) gui.View {
	return window.menubar(
		id_focus: 90
		items:    [
			gui.MenuItemCfg{
				id:      'file'
				text:    'File'
				submenu: [
					gui.MenuItemCfg{
						id:     'file.new'
						text:   'New Project'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							if a.running {
								stop_measurement(mut w)
							}
							a.proj = project.default_project()
							a.proj_source = 'new (built-in default)'
							a.rt = []ChannelRT{len: a.proj.channels.len}
							a.load_databases()
							a.status = 'new project — press ▶ Start'
						}
					},
					gui.MenuItemCfg{
						id:     'file.open'
						text:   'Open Project…'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							w.native_open_dialog(
								title:   'Open Project (.yml)'
								filters: [gui.NativeFileFilter{ name: 'Projects', extensions: ['yml', 'yaml'] }]
								on_done: fn (r gui.NativeDialogResult, mut w gui.Window) {
									if r.status == .ok && r.paths.len > 0 {
										open_project(r.path_strings()[0], mut w)
									}
								}
							)
						}
					},
					gui.MenuItemCfg{
						id:     'file.save'
						text:   'Save Project'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							a.status = 'Save Project: not implemented yet'
						}
					},
					gui.MenuItemCfg{
						id:        'sep1'
						separator: true
					},
					gui.MenuItemCfg{
						id:     'file.rec'
						text:   'Open Recording…'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							w.native_open_dialog(
								title:   'Open Recording (.log / .mf4)'
								filters: [gui.NativeFileFilter{ name: 'CAN recordings', extensions: ['log', 'mf4'] }]
								on_done: fn (r gui.NativeDialogResult, mut w gui.Window) {
									if r.status == .ok && r.paths.len > 0 {
										load_log(r.path_strings()[0], mut w)
									}
								}
							)
						}
					},
					gui.MenuItemCfg{
						id:      'file.recent'
						text:    'Open Recent'
						submenu: [
							gui.MenuItemCfg{
								id:     'file.recent.none'
								text:   '(none yet)'
								action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {}
							},
						]
					},
					gui.MenuItemCfg{
						id:        'sep2'
						separator: true
					},
					gui.MenuItemCfg{
						id:     'file.exit'
						text:   'Exit'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut _ gui.Window) {
							sapp.quit()
						}
					},
				]
			},
		]
	)
}

// open_project loads a project file, rebuilds the runtime, and reloads DBCs.
fn open_project(path string, mut w gui.Window) {
	mut app := w.state[App]()
	if app.running {
		stop_measurement(mut w)
	}
	p := project.load(path) or {
		app.status = 'open project failed: ${err}'
		return
	}
	app.proj = p
	app.proj_source = path
	app.rt = []ChannelRT{len: p.channels.len}
	app.load_databases()
	app.status = 'loaded ${p.name} (${p.channels.len} ch) — press ▶ Start'
	w.update_window()
}

fn toolbar(mut window gui.Window) gui.View {
	app := window.state[App]()
	dot := if app.running { '🟢' } else { '⚪' }
	return gui.row(
		v_align: .middle
		sizing:  gui.fill_fit
		spacing: 10
		content: [
			gui.button(
				id_focus: 103
				content:  [gui.text(text: '▶ Start')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					start_measurement(mut w)
				}
			),
			gui.button(
				id_focus: 104
				content:  [gui.text(text: '■ Stop')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					stop_measurement(mut w)
				}
			),
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
					a.expanded = map[u32]bool{}
					a.sel_id = -1
				}
			),
			gui.text(text: 'screen', text_style: gui.theme().n4),
			window.select(
				id:        'fps'
				id_focus:  105
				select:    ['${app.fps} fps']
				options:   fps_options
				min_width: 76
				max_width: 92
				on_select: fn (sel []string, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					if sel.len > 0 {
						a.fps = sel[0].all_before(' ').int()
					}
				}
			),
			gui.input(
				id_focus:        13
				text:            app.log_path
				width:           220
				height:          30
				padding:         gui.Padding{4, 8, 4, 8}
				sizing:          gui.fixed_fixed
				placeholder:     'path/to/capture.log or .mf4'
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
						title:   'Open CAN recording (candump .log or ASAM .mf4)'
						filters: [gui.NativeFileFilter{ name: 'CAN recordings', extensions: ['log', 'mf4'] }]
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
			expanded := id in app.expanded
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
			scrollbar:           .visible
			row_height:          22
			header_height:       24
			text_style:          trace_text_style()
			text_style_header:   trace_text_style()
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
					id := rid.u32()
					a.sel_id = i64(id) // Signals panel follows the selected message
					if id in a.expanded {
						a.expanded.delete(id) // toggle this ID; others stay expanded
					} else {
						a.expanded[id] = true
					}
				}
			}
			on_cell_format:      trace_cell_format
		)
	}
	// Newest first: the latest frame sits at the top, so a live trace "follows"
	// without any scroll math; scroll down to review the retained history.
	for i := app.trace.len - 1; i >= 0; i-- {
		r := app.trace[i]
		rows << gui.GridRow{
			id:    '${r.seq}:${r.id}' // seq keeps it unique; id lets selection drive Signals
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
		scrollbar:      .visible
		row_height:     22
		header_height:  24
		text_style:     trace_text_style()
		text_style_header: trace_text_style()
		columns:        [
			tcol('time', 'Time(ms)', 80, .end),
			tcol('dir', 'Dir', 50, .start),
			tcol('id', 'ID', 110, .start),
			tcol('dlc', 'DLC', 50, .end),
			tcol('data', 'Data', 300, .start),
			tcol('name', 'Message', 150, .start),
		]
		rows:                rows
		selection:           app.selection
		on_selection_change: fn (selection gui.GridSelection, mut _ gui.Event, mut w gui.Window) {
			mut a := w.state[App]()
			a.selection = selection
			parts := selection.active_row_id.split(':')
			if parts.len == 2 {
				a.sel_id = i64(parts[1].u32()) // Signals follows the clicked frame's ID
			}
		}
		on_cell_format:      trace_cell_format
	)
}

// signals_panel decodes the message currently selected in the Trace (any ID),
// live. Click a row in either trace view to inspect its signals here.
fn signals_panel(app &App) gui.View {
	mut lines := []gui.View{}
	if app.sel_id < 0 {
		lines << gui.text(text: 'Signals', text_style: gui.theme().b3)
		lines << gui.text(text: '(click a message in the Trace)', text_style: gui.theme().n4)
		return gui.column(sizing: gui.fill_fill, padding: gui.padding_medium, spacing: 5, content: lines)
	}
	id := u32(app.sel_id)
	agg := app.grouped[id] or { MsgAgg{} }
	msg := app.db.lookup(id) or {
		lines << gui.text(text: 'Signals — ${hexid(id, agg.ext)}', text_style: gui.theme().b3)
		lines << gui.text(text: '(no DBC message for this ID)', text_style: gui.theme().n4)
		return gui.column(sizing: gui.fill_fill, padding: gui.padding_medium, spacing: 5, content: lines)
	}
	data := agg.last
	lines << gui.text(text: 'Signals — ${hexid(id, agg.ext)} ${msg.name}', text_style: gui.theme().b3)
	if data.len > 0 {
		for s in msg.active_signals(data) {
			label := s.label(data)
			suffix := if label != '' { ' (${label})' } else { '' }
			lines << gui.text(text: '${s.name}: ${s.physical(data):.1f} ${s.unit}${suffix}',
				text_style: gui.theme().n4)
		}
	} else {
		lines << gui.text(text: '(waiting for frames…)', text_style: gui.theme().n4)
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
			gui.text(text: 'Channels: ${app.proj.channels.len}', text_style: gui.theme().n4),
			gui.text(text: 'Database: ${app.db.messages.len} msgs', text_style: gui.theme().n4),
			gui.text(text: 'DB source: ${app.db_source}', text_style: gui.theme().n4),
			gui.text(text: 'Project: ${app.proj.name} (${app.proj_source})', text_style: gui.theme().n4),
		]
	)
}

// buses_panel lists the project's channels (buses): a click-to-toggle enable
// box, a state-colour dot, the name/interface, and live RX/TX counts. It's the
// front-end of Start/Stop — enable a channel, then Start attaches it.
fn buses_panel(app &App) gui.View {
	mut rows := []gui.View{}
	rows << gui.text(text: 'Buses', text_style: gui.theme().b3)
	for i, ch in app.proj.channels {
		rt := app.rt[i] or { ChannelRT{} }
		dot_style := gui.TextStyle{
			...trace_text_style()
			color: channel_color(ch, rt, app.running)
		}
		rows << gui.row(
			v_align: .middle
			spacing: 5
			padding: gui.padding_none
			content: [
				gui.text(text: '●', text_style: dot_style),
				gui.checkbox(
					id_focus:         u32(200 + i)
					select:           ch.enabled
					label:            '${ch.name}  ${ch.iface}'
					text_style:       trace_text_style()
					text_style_label: trace_text_style()
					padding:          gui.Padding{0, 4, 0, 4}
					on_click:         fn [i] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
						mut a := w.state[App]()
						a.proj.channels[i].enabled = !a.proj.channels[i].enabled
					}
				),
			]
		)
	}
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		spacing: 2
		content: rows
	)
}

// channel_color: green running, red errored, amber enabled-but-stopped, grey off.
fn channel_color(ch project.Channel, rt ChannelRT, running bool) gui.Color {
	if !ch.enabled {
		return gui.Color{120, 120, 120, 255}
	}
	if rt.err {
		return gui.Color{220, 90, 90, 255}
	}
	if rt.running {
		return gui.Color{120, 220, 150, 255}
	}
	return gui.Color{210, 180, 90, 255}
}

fn send_panel(app &App) gui.View {
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		spacing: 6
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
						height:          30
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
						width:           150
						height:          30
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
			// NOTE: gui.button's content label fails to render when nested in a
			// dock panel (toolbar buttons are fine), so the Send control is a
			// styled clickable row — same approach gui's own checkbox uses.
			gui.row(
				id_focus:     12
				sizing:       gui.fit_fit
				color:        gui.Color{72, 84, 110, 255}
				color_border: gui.Color{110, 130, 170, 255}
				size_border:  1
				radius:       5
				v_align:      .middle
				padding:      gui.Padding{7, 18, 7, 18}
				on_click:     fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					do_send(mut w)
				}
				content:      [
					gui.text(text: 'Send', text_style: gui.theme().n2),
				]
			),
		]
	)
}

fn do_send(mut w gui.Window) {
	mut app := w.state[App]()
	// Transmit on the first running channel that has an open bus.
	mut idx := -1
	for i in 0 .. app.rt.len {
		if app.rt[i].running && app.rt[i].bus != none {
			idx = i
			break
		}
	}
	if idx < 0 {
		app.status = 'not running — press ▶ Start to send'
		return
	}
	id := parse_hex_u32(app.send_id)
	frame := transport.CanFrame{
		id:       id
		extended: id > 0x7ff
		data:     hex_to_bytes(app.send_data)
	}
	mut bus := app.rt[idx].bus or { return }
	bus.send(frame) or {
		app.status = 'send failed: ${err}'
		return
	}
	app.rt[idx].tx_count++
	app.push('TX', frame)
}

// mf4_to_log bridges an ASAM MF4 recording to a candump `.log` via the Python
// asammdf bridge (`sut/mf4_bridge.py convert`), returning the temp `.log` path.
// MF4 is a heavy binary container, so we don't parse it natively in V (see
// CLAUDE.md Phase 7) — the mature asammdf/python-can stack does the extraction.
fn mf4_to_log(mf4 string) !string {
	py := if os.exists('.venv-tools/bin/python') { '.venv-tools/bin/python' } else { 'python3' }
	out := os.join_path(os.temp_dir(), 'cantester_mf4_open.log')
	res := os.execute('${py} sut/mf4_bridge.py convert "${mf4}" "${out}"')
	if res.exit_code != 0 {
		return error(res.output.trim_space())
	}
	return out
}

// load_log opens a candump `.log` (or an MF4 recording, bridged to `.log`) and
// shows it as a static capture: live RX is paused and the trace is reset so the
// recording stands alone, with each frame stamped by its recorded timestamp. The
// grouped view keeps every unique ID + count; the chronological view shows the
// tail (max_trace cap).
fn load_log(path string, mut w gui.Window) {
	mut app := w.state[App]()
	p := path.trim_space()
	if p.len == 0 {
		app.status = 'no file picker here — type a log/mf4 path and press Enter'
		return
	}
	// MF4 → candump .log via the asammdf bridge (blocks briefly on convert).
	mut src := p
	if p.to_lower().ends_with('.mf4') {
		app.status = 'converting ${os.base(p)} via asammdf bridge…'
		w.update_window()
		src = mf4_to_log(p) or {
			app.status = 'MF4 open failed: ${err}'
			return
		}
	}
	entries := canlog.load_file(src) or {
		app.status = 'open failed: ${err}'
		return
	}
	app.paused = true
	app.log_path = p
	app.trace = []TraceRow{}
	app.grouped = map[u32]MsgAgg{}
	app.order = []u32{}
	app.expanded = map[u32]bool{}
	app.sel_id = -1
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

// trace_text_style is a compact font for the dense trace grid.
fn trace_text_style() gui.TextStyle {
	return gui.TextStyle{
		...gui.theme().n4
		size: 13
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
