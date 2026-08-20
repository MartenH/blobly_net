module main

import os
import project
import transport
import candb
import vgui

// examples lists the shipped projects for the File > Open Example menu.
const examples = [
	['Simulation demo (driver-free)', 'projects/sim-demo.blobnet'],
	['Restbus — 2x vcan (real ECU)', 'projects/restbus-2vcan.blobnet'],
	['Virtual bench (vcan0)', 'projects/demo.blobnet'],
	['Telemetry / Trace Chart (vcan0)', 'projects/trace-demo.blobnet'],
	['CPU-load sim (driver-free)', 'projects/cpuload-sim.blobnet'],
	['DoIP diagnostics', 'projects/doip-demo.blobnet'],
	['Replay demo', 'projects/replay-demo.blobnet'],
]

// draw_activity_bar is the VS Code-style vertical strip of panel toggles on the far left.
// Each button toggles a panel's visibility and is tinted when the panel is shown.
fn draw_activity_bar(mut app App) {
	// fixed dark strip (same in light + dark themes, like VS Code) with a tight inner
	// padding so the 3-char labels aren't clipped
	vgui.activity_style_push()
	vgui.push_window_padding(4 * app.ui_scale, 6 * app.ui_scale)
	vgui.child_wh('##activity', 60 * app.ui_scale, 0)
	vgui.push_frame_padding(4 * app.ui_scale, 6 * app.ui_scale)
	// Grouped into logical sections separated by a rule, alphabetical within each group:
	// setup · trace · filtered-trace (its own) · signal views · send · diagnostics · tools ·
	// blobly_emb target (LAST — those panels only work against a blobly_emb SUT, which is not
	// the common case; keeping them together stops them cluttering the generic CAN workflow).
	// --- setup ---
	if vgui.toggle_button('Bus', app.show_buses, -1) {
		app.show_buses = !app.show_buses
	}
	// One way in. This used to open a READ-ONLY summary sitting one click from
	// Buses ▸ "Configure…", which is the actual editor — two near-identical names, only one of
	// which could change anything.
	if vgui.toggle_button('Cfg', app.show_config, -1) {
		app.set_config_open(!app.show_config)
	}
	if vgui.toggle_button('Sim', app.show_sim, -1) {
		app.show_sim = !app.show_sim
	}
	if vgui.toggle_button('Sym', app.show_symbols, -1) {
		app.show_symbols = !app.show_symbols
	}
	vgui.separator()
	// --- trace ---
	if vgui.toggle_button('Trc', app.show_trace, -1) {
		app.show_trace = !app.show_trace
	}
	vgui.separator()
	// --- filtered trace (on its own) ---
	if vgui.toggle_button('FTr', app.show_ftrace, -1) {
		app.show_ftrace = !app.show_ftrace
	}
	vgui.separator()
	// --- signal views ---
	if vgui.toggle_button('Gfx', app.show_graphics, -1) {
		app.show_graphics = !app.show_graphics
	}
	if vgui.toggle_button('Sig', app.show_signals, -1) {
		app.show_signals = !app.show_signals
	}
	vgui.separator()
	// --- send ---
	if vgui.toggle_button('Gen', app.show_gen, -1) {
		app.show_gen = !app.show_gen
	}
	vgui.separator()
	// --- diagnostics ---
	if vgui.toggle_button('Dia', app.show_diag, -1) {
		app.show_diag = !app.show_diag
	}
	if vgui.toggle_button('Dbc', app.show_dbc, -1) {
		app.show_dbc = !app.show_dbc
	}
	vgui.set_item_tooltip('DBC Editor')
	if vgui.toggle_button('DoI', app.show_doip, -1) {
		app.show_doip = !app.show_doip
	}
	if vgui.toggle_button('Net', app.show_network, -1) {
		app.show_network = !app.show_network
	}
	vgui.separator()
	// --- tools --- (Help is in the menu bar, not here — it's an action, not a panel)
	if vgui.toggle_button('Log', app.show_log, -1) {
		app.show_log = !app.show_log
	}
	if vgui.toggle_button('Lua', app.show_script, -1) {
		app.show_script = !app.show_script
	}
	if vgui.toggle_button('Sta', app.show_stats, -1) {
		app.show_stats = !app.show_stats
	}
	vgui.separator()
	// --- blobly_emb target --- these speak blobly_emb's own protocols (trace records +
	// manifest, the shell wire, the bootloader), so they are useless against an arbitrary
	// CAN bus. Grouped last, with tooltips saying so.
	if vgui.toggle_button('Cht', app.show_tchart, -1) {
		app.show_tchart = !app.show_tchart
	}
	vgui.set_item_tooltip('Trace Chart — blobly_emb handler/thread swimlanes')
	if vgui.toggle_button('Fsh', app.show_flash, -1) {
		app.show_flash = !app.show_flash
	}
	vgui.set_item_tooltip('Flash — UDS download to a blobly_emb bootloader')
	if vgui.toggle_button('Shl', app.show_shell, -1) {
		app.show_shell = !app.show_shell
	}
	vgui.set_item_tooltip('Shell — console to a blobly_emb target over CAN')
	if vgui.toggle_button('Sys', app.show_sys, -1) {
		app.show_sys = !app.show_sys
	}
	vgui.set_item_tooltip('System viewer — blobly_emb system.toml / ecu.toml')
	vgui.pop_style_var(1) // frame padding
	vgui.child_end()
	vgui.pop_style_var(1) // window padding
	vgui.activity_style_pop()
}

fn draw_menubar(mut app App, rx u64) {
	if vgui.menu_bar_begin() {
		if vgui.menu_begin('File') {
			if vgui.menu_item('New') {
				app.new_project()
			}
			if vgui.menu_item('Open...') {
				app.open_browser('open')
			}
			if vgui.menu_item('Save') {
				app.save_project()
			}
			if vgui.menu_item('Save As...') {
				app.open_browser('saveas')
			}
			vgui.separator()
			if app.running {
				vgui.text_dim('Configure... (stop to edit)')
			} else if vgui.menu_item('Configure...') {
				app.show_config = true
				app.sync_cfg_bufs()
			}
			if vgui.menu_begin('Open Example') {
				for ex in examples {
					if vgui.menu_item(ex[0]) {
						app.load_project(ex[1])
					}
				}
				vgui.menu_end()
			}
			if vgui.menu_item('Reload project') {
				if app.proj_path != '' {
					app.load_project(app.proj_path)
				}
			}
			vgui.separator()
			if vgui.menu_item('Exit') {
				vgui.quit()
			}
			vgui.menu_end()
		}
		if vgui.menu_begin('View') {
			app.show_buses = vgui.menu_item_check('Buses', app.show_buses)
			app.show_sim = vgui.menu_item_check('Simulation', app.show_sim)
			app.show_symbols = vgui.menu_item_check('Symbols', app.show_symbols)
			// through the same helper: hiding it from HERE also skips draw_config's close-time
			// apply, and this path was missed when the activity-bar one was fixed
			cfg_on := vgui.menu_item_check('Configuration', app.show_config)
			if cfg_on != app.show_config {
				app.set_config_open(cfg_on)
			}
			app.show_trace = vgui.menu_item_check('Trace', app.show_trace)
			app.show_ftrace = vgui.menu_item_check('Trace (filter)', app.show_ftrace)
			app.show_signals = vgui.menu_item_check('Signals', app.show_signals)
			app.show_graphics = vgui.menu_item_check('Graphics', app.show_graphics)
			app.show_diag = vgui.menu_item_check('Diagnostics', app.show_diag)
			app.show_dbc = vgui.menu_item_check('DBC Editor', app.show_dbc)
			app.show_doip = vgui.menu_item_check('DoIP Discovery', app.show_doip)
			app.show_network = vgui.menu_item_check('Network', app.show_network)
			app.show_gen = vgui.menu_item_check('Generators', app.show_gen)
			app.show_script = vgui.menu_item_check('Script', app.show_script)
			app.show_stats = vgui.menu_item_check('Statistics', app.show_stats)
			app.show_log = vgui.menu_item_check('Log', app.show_log)
			// panels that only work against a blobly_emb SUT — grouped so the generic
			// CAN workflow above stays uncluttered
			vgui.separator_text('blobly_emb target')
			app.show_tchart = vgui.menu_item_check('Trace Chart', app.show_tchart)
			app.show_flash = vgui.menu_item_check('Flash', app.show_flash)
			app.show_shell = vgui.menu_item_check('Shell', app.show_shell)
			app.show_sys = vgui.menu_item_check('System', app.show_sys)
			vgui.menu_end()
		}
		if vgui.menu_begin('Settings') {
			vgui.separator_text('repaint cap')
			for f in [5, 10, 30, 60] {
				if vgui.menu_item('${f} fps') {
					app.wake_ms = i64(1000 / f)
				}
			}
			vgui.separator_text('UI scale')
			// 75 exists for the opposite problem the maximized window solves: on a small screen
			// the panels fight for room, and shrinking the UI is cheaper than closing one.
			for s in [75, 100, 125, 150, 175] {
				if vgui.menu_item('${s}%') {
					app.ui_scale = f32(s) / 100.0
					vgui.set_font_scale(app.ui_scale)
				}
			}
			vgui.menu_end()
		}
		if vgui.menu_begin('Help') {
			if vgui.menu_item('Documentation (opens in browser)') {
				app.open_help_in_browser()
			}
			vgui.menu_end()
		}
		vgui.menu_bar_end()
	}
}

// draw_toolbar is the button/status strip BELOW the menu bar (Start/Stop, live status,
// Pause/Clear/Record, theme).
fn draw_toolbar(mut app App, rx u64, txs string) {
	// breathing room below the menu bar + inset from the left edge (host has zero padding)
	vgui.indent_y(7 * app.ui_scale)
	vgui.indent_x(8 * app.ui_scale)
	// primary action — big and colour-coded (started/stopped a lot): green Start / red Stop
	bw := 110 * app.ui_scale
	bh := 40 * app.ui_scale
	if app.running {
		if vgui.button_big('Stop', 190, 70, 70, bw, bh) {
			app.stop()
			app.notify('stopped')
		}
	} else {
		if vgui.button_big('Start', 45, 150, 90, bw, bh) {
			app.start()
			app.notify('started')
		}
	}
	vgui.same_line()
	if app.running {
		vgui.text_colored(90, 200, 120, 'running')
	} else {
		vgui.text_colored(210, 120, 120, 'stopped')
	}
	vgui.same_line()
	// Unsaved FILE-tab text counts as modified too. It lives in its own buffer, so without this
	// the toolbar read clean while an edit sat waiting in a closed window.
	dirtymark := if app.dirty || app.cfg_text_dirty { ' ●' } else { '' }
	vgui.text('· RX ${rx}  ${txs}  ·  ${app.proj_name}${dirtymark}   ')
	vgui.same_line()
	if vgui.button(if app.paused { 'Resume' } else { 'Pause' }) {
		app.paused = !app.paused
	}
	vgui.same_line()
	if vgui.button('Clear') {
		app.clear_trace()
	}
	vgui.same_line()
	if vgui.button(if app.recording { 'Stop Rec' } else { 'Record' }) {
		app.toggle_record()
	}
	vgui.same_line()
	if vgui.button(if app.dark { 'Light' } else { 'Dark' }) {
		app.dark = !app.dark
		vgui.set_theme(app.dark)
	}
	vgui.separator()
}

// draw_symbols is the Symbol Browser: a searchable tree of every DBC message and its
// signals (bit layout, scaling, unit, range).
fn draw_symbols(mut app App) {
	vis, op := vgui.begin_closable('Symbols', app.show_symbols)
	app.show_symbols = op
	if !vis {
		vgui.end()
		return
	}
	vgui.set_next_item_width(220)
	vgui.input_text('search', mut app.symbol_filter_buf)
	filt := vgui.buf_str(app.symbol_filter_buf).to_lower()
	vgui.separator_text('messages / signals')
	mut seen := map[u64]bool{}
	for db in app.dbs {
		for m in db.messages {
			key := (u64(m.id) << 1) | if m.ext { u64(1) } else { u64(0) }
			if key in seen {
				continue
			}
			seen[key] = true
			mut hit := filt == '' || m.name.to_lower().contains(filt)
				|| idstr(m.id, m.ext).to_lower().contains(filt)
			if !hit {
				for s in m.signals {
					if s.name.to_lower().contains(filt) {
						hit = true
						break
					}
				}
			}
			if !hit {
				continue
			}
			// "+flt" adds this message to the Trace (filter) watch list (idempotent)
			if vgui.small_button('+flt##fadd${m.id}_${m.ext}') {
				app.add_fwatch(m.id, m.ext)
			}
			vgui.same_line()
			hdr := '${idstr(m.id, m.ext)}  ${m.name}  (${m.signals.len} sig)###sym${m.id}_${m.ext}'
			if vgui.tree_node(hdr) {
				for s in m.signals {
					off := if s.offset != 0 { '+${s.offset}' } else { '' }
					unit := if s.unit != '' { ' ${s.unit}' } else { '' }
					vgui.text('    ${s.name}  [bit ${s.start_bit}:${s.length}]  ×${s.factor}${off}${unit}  [${s.minimum}..${s.maximum}]')
				}
				vgui.tree_pop()
			}
		}
	}
	vgui.end()
}

// selftest_config drives the Configuration editor's real methods headlessly (the widgets
// can't be clicked under WSLg) and asserts the written .blobnet round-trips. Gated by
// BLOBLY_SELFTEST_CONFIG; prints PASS/FAIL + the file, then main() returns.
fn selftest_config(mut app App) {
	tmp := os.join_path(os.temp_dir(), 'blobly_selftest.blobnet')
	os.rm(tmp) or {}
	// New → blank
	app.new_project()
	mut ok := selftest_check('new project has 0 buses', app.proj.channels.len == 0)
	// bus 0: a vcan monitor bus with a DBC
	app.add_bus()
	app.cfg_bufs[0].name_buf = mkbuf('CAN0', 48)
	app.cfg_bufs[0].network_buf = mkbuf('Powertrain', 48)
	app.cfg_bufs[0].address_buf = mkbuf('vcan0', 64)
	app.set_adapter(0, 'vcan')
	app.add_dbc(0, 'dbc/blobly_net.dbc')
	// bus 1: a DoIP endpoint
	app.add_bus()
	app.cfg_bufs[1].name_buf = mkbuf('Diag', 48)
	app.cfg_bufs[1].address_buf = mkbuf('127.0.0.1:13400', 64)
	app.set_adapter(1, 'doip')
	// Save As → write, then reload and verify the round-trip
	app.save_as(tmp)
	rp := project.load(tmp) or {
		println('SELFTEST_CONFIG: FAIL (reload: ${err})')
		return
	}
	ok = selftest_check('2 buses', rp.channels.len == 2) && ok
	if rp.channels.len == 2 {
		c0 := rp.channels[0]
		ok = selftest_check('c0 name CAN0', c0.name == 'CAN0') && ok
		ok = selftest_check('c0 network Powertrain', c0.network == 'Powertrain') && ok
		ok = selftest_check('c0 adapter vcan', c0.adapter == 'vcan') && ok
		ok = selftest_check('c0 address vcan0', c0.address == 'vcan0') && ok
		ok = selftest_check('c0 iface vcan0', c0.iface == 'vcan0') && ok
		ok = selftest_check('c0 dbc attached', c0.databases == ['dbc/blobly_net.dbc']) && ok
		c1 := rp.channels[1]
		ok = selftest_check('c1 name Diag', c1.name == 'Diag') && ok
		ok = selftest_check('c1 is doip', c1.is_doip()) && ok
		ok = selftest_check('c1 adapter doip', c1.adapter == 'doip') && ok
		ok = selftest_check('c1 address host:port', c1.address == '127.0.0.1:13400') && ok
	}
	println(if ok { 'SELFTEST_CONFIG: PASS' } else { 'SELFTEST_CONFIG: FAIL' })
	println('--- discover_all() ---')
	for d in app.discover_all() {
		mark := if d.added { ' [added]' } else { '' }
		println('  ${d.address}   ${d.adapter} · ${d.desc}${mark}')
	}
	println('--- written ${tmp} ---')
	println(os.read_file(tmp) or { '' })
}

fn selftest_check(name string, cond bool) bool {
	if !cond {
		eprintln('  FAIL: ${name}')
	}
	return cond
}

// draw_stats: totals + per-channel RX counters.
fn draw_stats(mut app App, chans []Chan, rx u64, txs string) {
	vis, op := vgui.begin_closable('Statistics', app.show_stats)
	app.show_stats = op
	if !vis {
		vgui.end()
		return
	}
	vgui.text('RX ${rx}    ${txs}    ${vgui.fps():.0} fps    trace ${app.trace.len}')
	vgui.separator_text('per channel')
	if vgui.table_begin('stats', 4) {
		vgui.table_setup_col('channel', 90)
		vgui.table_setup_col('iface', 120)
		vgui.table_setup_col('state', 56)
		vgui.table_setup_col('RX', 0)
		vgui.table_freeze_top()
		vgui.table_headers()
		for c in chans {
			state := if c.running {
				'run'
			} else if c.enabled {
				'idle'
			} else {
				'off'
			}
			vgui.table_row()
			vgui.table_cell(c.name)
			vgui.table_cell(c.iface)
			vgui.table_cell(state)
			vgui.table_cell('${c.rx}')
		}
		vgui.table_end()
	}
	vgui.end()
}

// draw_log: the scrolling status/event log.
fn draw_log(mut app App) {
	vis, op := vgui.begin_closable('Log', app.show_log)
	app.show_log = op
	if !vis {
		vgui.end()
		return
	}
	app.mu.lock()
	logs := app.logs.clone()
	app.mu.unlock()
	vgui.child_begin('##loglines', 0)
	for l in logs {
		vgui.text(l)
	}
	vgui.child_end()
	vgui.end()
}

// build_layout docks the five panels once: Buses (left) | Trace (centre) | a right
// column stacked Trace Chart / Signals / Graphics.
fn build_layout() {
	root := vgui.dock_root()
	if root == 0 {
		return
	}
	mut rest := u32(0)
	buses := vgui.dock_split(root, vgui.dock_left, 0.16, &rest)
	mut center := u32(0)
	right := vgui.dock_split(rest, vgui.dock_right, 0.34, &center)
	// centre column: Trace(s) on top, a Log strip at the bottom
	mut cbot := u32(0)
	ctop := vgui.dock_split(center, vgui.dock_up, 0.76, &cbot)
	// right column: Trace Chart (top) / mid tab group / bottom tab group
	mut rmid := u32(0)
	chart := vgui.dock_split(right, vgui.dock_up, 0.26, &rmid)
	mut bottom := u32(0)
	midnode := vgui.dock_split(rmid, vgui.dock_up, 0.5, &bottom)
	// left column tabs
	vgui.dock_window('Buses', buses)
	vgui.dock_window('Network', buses)
	vgui.dock_window('Simulation', buses)
	vgui.dock_window('Symbols', buses)
	vgui.dock_window('Statistics', buses)
	// centre: Trace + Trace (filter) tabs; Log below
	vgui.dock_window('Trace', ctop)
	vgui.dock_window('Trace (filter)', ctop)
	vgui.dock_window('Log', cbot)
	// right column
	vgui.dock_window('Trace Chart', chart)
	vgui.dock_window('Signals', midnode)
	vgui.dock_window('Diagnostics', midnode)
	vgui.dock_window('Shell', midnode)
	vgui.dock_window('DBC Editor', midnode) // beside the live Trace: edit, watch re-decode
	vgui.dock_window('System', midnode)
	vgui.dock_window('Flash', midnode)
	vgui.dock_window('DoIP Discovery', midnode)
	vgui.dock_window('Graphics', bottom)
	vgui.dock_window('Generators', bottom)
	vgui.dock_window('Script', bottom)
	// Help is not a panel — it's the Help menu's "Documentation" action, which opens the docs in
	// the system browser.
	vgui.dock_finish(root)
}

// latest_data returns the payload of the newest trace row matching (id, ext), or [].
fn latest_data(rows []TraceRow, id u32, ext bool) []u8 {
	mut i := rows.len - 1
	for i >= 0 {
		if rows[i].id == id && rows[i].ext == ext {
			return rows[i].data
		}
		i--
	}
	return []u8{}
}

// draw_signals: pick a DBC message; decode its signals from the latest matching frame.
// A checkbox per signal adds/removes it from the Graphics watch list.
fn draw_signals(mut app App, rows []TraceRow) {
	vis, op := vgui.begin_closable('Signals', app.show_signals)
	app.show_signals = op
	if !vis {
		vgui.end()
		return
	}
	vgui.separator_text('messages')
	vgui.child_begin('##msglist', 108)
	mut seen := map[u64]bool{}
	for db in app.dbs {
		for m in db.messages {
			key := (u64(m.id) << 1) | if m.ext { u64(1) } else { u64(0) }
			if key in seen {
				continue // both DBCs may define the same message
			}
			seen[key] = true
			lbl := '0x${m.id:X}  ${m.name}'
			is_sel := app.sel_id == int(m.id) && app.sel_ext == m.ext
			if vgui.selectable(lbl, is_sel) {
				app.sel_id = int(m.id)
				app.sel_ext = m.ext
			}
		}
	}
	vgui.child_end()
	vgui.separator_text('signals')
	if app.sel_id < 0 {
		vgui.text_dim('select a message above')
		vgui.end()
		return
	}
	m := app.find_message(u32(app.sel_id), app.sel_ext) or {
		vgui.text_dim('message not in DBC')
		vgui.end()
		return
	}
	data := latest_data(rows, u32(app.sel_id), app.sel_ext)
	if data.len == 0 {
		vgui.text('${m.name}: no frame received yet')
		vgui.end()
		return
	}
	vgui.text('${m.name}')
	if vgui.table_begin('sigs', 4) {
		vgui.table_col('') // plot checkbox
		vgui.table_col('signal')
		vgui.table_col('value')
		vgui.table_col('unit')
		vgui.table_headers()
		for s in m.active_signals(data) {
			vgui.table_row()
			vgui.table_next_col()
			watched := app.is_watched(u32(app.sel_id), app.sel_ext, s.name)
			nw := vgui.checkbox('##w_${m.id}_${s.name}', watched)
			if nw != watched {
				app.toggle_watch(u32(app.sel_id), app.sel_ext, s.name)
			}
			vgui.table_cell(s.name)
			lbl := s.label(data)
			valstr := if lbl != '' {
				'${s.physical(data):.3} (${lbl})'
			} else {
				'${s.physical(data):.3}'
			}
			vgui.table_cell(valstr)
			vgui.table_cell(s.unit)
		}
		vgui.table_end()
	}
	vgui.end()
}

// build_series decodes the watched signal across the trace history -> (time ms, value).
fn (app &App) build_series(rows []TraceRow, w Watch) ([]f32, []f32) {
	m := app.find_message(w.id, w.ext) or { return []f32{}, []f32{} }
	mut sig := candb.Signal{}
	mut found := false
	for s in m.signals {
		if s.name == w.sig {
			sig = s
			found = true
			break
		}
	}
	if !found {
		return []f32{}, []f32{}
	}
	mut xs := []f32{}
	mut ys := []f32{}
	for r in rows {
		if r.id == w.id && r.ext == w.ext && r.data.len > 0 {
			xs << f32(r.t_ms / 1000.0) // seconds — the plot x-axis is t (s)
			ys << f32(sig.physical(r.data))
		}
	}
	return xs, ys
}

// draw_graphics plots the watched signals over the trace history as ImPlot lines
// (native pan/zoom/legend/tooltip).
fn draw_graphics(mut app App, rows []TraceRow) {
	vis, op := vgui.begin_closable('Graphics', app.show_graphics)
	app.show_graphics = op
	if !vis {
		vgui.end()
		return
	}
	if app.watch.len == 0 {
		vgui.text_dim('tick a signal in the Signals panel to plot it (or right-click a Trace row)')
		vgui.end()
		return
	}
	// plotted signals: each a chip that REMOVES it from the plot on click (a real remove from the
	// watch set — distinct from clicking the plot legend, which only hides/shows the line).
	if vgui.small_button('Clear') {
		app.watch = []
		vgui.end()
		return
	}
	vgui.same_line()
	vgui.text_dim('remove:')
	mut rm := -1
	for i, w in app.watch {
		vgui.same_line()
		if vgui.small_button('${idstr(w.id, w.ext)}.${w.sig} x##rmw${i}') {
			rm = i
		}
	}
	if rm >= 0 {
		app.watch.delete(rm)
	}
	// time window: a fixed span you watch (a scrolling strip chart), not the whole history.
	vgui.text_dim('window:')
	for wsec in [f32(1), 5, 10, 30, 0] {
		vgui.same_line()
		lbl := if wsec == 0 { 'full' } else { '${int(wsec)}s' }
		if vgui.toggle_button('${lbl}##pw${int(wsec)}', app.plot_win == wsec, 0) {
			app.plot_win = wsec
		}
	}
	// Y-axis: "Multi" gives each signal its own real-value axis (up to 3, so a small-amplitude
	// signal keeps real values instead of being squashed by a large one); "Shared" = one axis.
	vgui.same_line()
	vgui.text_dim(' · Y:')
	vgui.same_line()
	if vgui.toggle_button('Multi##ymulti', app.plot_multi, 0) {
		app.plot_multi = true
	}
	vgui.same_line()
	if vgui.toggle_button('Shared##yshared', !app.plot_multi, 0) {
		app.plot_multi = false
	}
	// The y-axes are ImPlot-native — the right-click menu owns them and its state persists
	// (SetupAxis only overrides flags when the program CHANGES them, which we never do).
	// The one non-obvious step is that Auto-Fit must go off before Min/Max stick.
	vgui.same_line()
	vgui.help_marker('Each y-axis is live-fitted by default. To take one over: right-click the axis, untick Auto-Fit, then set Min/Max (e.g. 0/100 for a load %). The small checkboxes lock that end against pan/zoom. Drag axis = pan, scroll = zoom, double-click = fit once.')
	// x-window right edge: wall-clock NOW while live, so the strip chart slides on real time
	// (not only when a sample arrives); the latest sample time when stopped/paused/loaded, so
	// it holds still. Samples and `now` share one clock BY CONSTRUCTION: both come from
	// app.since_ms(), so the chart's right edge cannot drift from the rows' stamps.
	mut xmax := f64(0)
	if app.running && !app.paused {
		xmax = app.since_s()
	} else {
		for r in rows {
			if app.is_watched_frame(r.id, r.ext) && f64(r.t_ms) / 1000.0 > xmax {
				xmax = f64(r.t_ms) / 1000.0
			}
		}
	}
	xmin := if app.plot_win > 0 { xmax - f64(app.plot_win) } else { f64(0) }
	xhi := if app.plot_win > 0 { xmax } else { f64(0) } // 0/0 → full autofit
	n_yaxes := if app.plot_multi { imin(3, app.watch.len) } else { 1 }
	if vgui.plot_begin_multi('##sigplot', -1, xmin, xhi, n_yaxes) { // -1 = fill panel height
		// crosshair readout: value shown in the legend is at the cursor x when hovering the
		// plot, else the latest sample — a live per-signal value beside each name.
		hovered := vgui.plot_is_hovered()
		mx := if hovered { f32(vgui.plot_mouse_x()) } else { f32(0) }
		for i, w in app.watch {
			xs, ys := app.build_series(rows, w)
			if xs.len == 0 {
				continue
			}
			xr := if hovered { mx } else { xs[xs.len - 1] } // cursor x, or latest
			val := value_at(xs, ys, xr)
			// display "name = value"; the ###id keeps the ImPlot series identity/colour stable
			// even though the shown value changes each frame.
			label := '0x${w.id:X}.${w.sig} = ${val:.2f}###g${w.id}_${w.ext}_${w.sig}'
			axis := if app.plot_multi { imin(i, 2) } else { 0 } // signal 0/1/2 → Y1/Y2/Y3
			vgui.plot_line_axis(label, xs, ys, axis)
		}
		vgui.plot_end()
	}
	vgui.end()
}

// imin is a small int min helper.
fn imin(a int, b int) int {
	return if a < b { a } else { b }
}

// value_at linearly interpolates the series (xs,ys) at x (clamped to the ends). Used for the
// Graphics crosshair readout.
fn value_at(xs []f32, ys []f32, x f32) f32 {
	n := xs.len
	if n == 0 {
		return 0
	}
	if x <= xs[0] {
		return ys[0]
	}
	if x >= xs[n - 1] {
		return ys[n - 1]
	}
	for i in 1 .. n {
		if xs[i] >= x {
			d := xs[i] - xs[i - 1]
			t := if d != 0 { (x - xs[i - 1]) / d } else { f32(0) }
			return ys[i - 1] + t * (ys[i] - ys[i - 1])
		}
	}
	return ys[n - 1]
}

// is_watched_frame reports whether any plotted signal comes from this frame id.
fn (app &App) is_watched_frame(id u32, ext bool) bool {
	for w in app.watch {
		if w.id == id && w.ext == ext {
			return true
		}
	}
	return false
}

fn printable(b []u8) string {
	mut s := ''
	for c in b {
		s += if c >= 0x20 && c < 0x7f { c.ascii_str() } else { '.' }
	}
	return s
}

// draw_shell is the target's CAN shell: a scrollback plus one input line pinned at the bottom.
// Enter sends the line as ONE raw frame on the manifest's shell `in` id; the response streams
// back as an ISO-TP block on `out` (host flow-controls on `fc`) — the trace-dump wire, reused.
// Line editing is entirely client-side: backspace/delete/cursor are native ImGui, Up/Down are
// console_input's history. The target only ever sees complete lines (<= 8 chars, one frame).
fn draw_shell(mut app App) {
	vis, op := vgui.begin_closable('Shell', app.show_shell)
	app.show_shell = op
	if !vis {
		vgui.end()
		return
	}
	// the eth RPC shell (manifest `ethmod,shell,method`) needs NO CAN channel:
	// it dials the board's UDP endpoint directly, Start or not
	eth := app.eth_method != 0 && app.eth_someip.service != 0
	// NOTE (codex #65): absence of manifest metadata does NOT mean "no shell endpoint".
	// ShellFrames.or_defaults() — which the worker itself calls — supplies 0x7F0/0x7F2/0x7F1,
	// so a legacy manifest (no `# shell frames` section) and a manifest-less project both
	// reach a default-configured target. The GUI must follow the module's interpretation
	// instead of redefining zero-valued ids as unavailable, so this is a HINT, not a gate.
	if !eth && app.manifest.shell.input == 0 {
		vgui.text_dim('no shell frames declared — using the defaults (0x7F0/0x7F2/0x7F1)')
	}
	if !app.running && !eth {
		vgui.text_dim('press Start (the shell needs the channel open to reach the target)')
		vgui.end()
		return
	}
	app.mu.lock()
	lines := app.shell_lines.clone()
	busy := app.shell_busy
	follow := app.shell_follow
	app.shell_follow = false
	app.mu.unlock()
	// the scrollback fills the panel minus one input row at the bottom (negative child height);
	// the text inside is a read-only InputTextMultiline — real mouse selection + Ctrl+A/Ctrl+C
	// (the input line below has the same native clipboard handling out of the box).
	vgui.child_begin('##shellout', -30 * app.ui_scale)
	vgui.console_text('##shelltext', lines.join('\n'), lines.len)
	if follow {
		vgui.scroll_bottom()
	}
	vgui.child_end()
	if eth {
		vgui.set_next_item_width(130 * app.ui_scale)
		vgui.input_text('##ethtarget', mut app.eth_target_buf)
		vgui.same_line()
		vgui.text_dim('board ip — SOME/IP method 0x${app.eth_method.hex()} :${app.eth_someip.port}')
	}
	vgui.set_next_item_width(-40 * app.ui_scale)
	if vgui.console_input('##shellin', mut app.shell_buf) {
		line := vgui.buf_str(app.shell_buf).trim_space()
		app.shell_buf[0] = 0
		if line == 'clear' {
			// a terminal's clear is a CLIENT operation — the scrollback is ours, not the target's
			app.mu.lock()
			app.shell_lines.clear()
			app.mu.unlock()
		} else if line != '' {
			if busy {
				app.shell_append('(busy — previous command still running)')
			} else if eth {
				// snapshot target AND identity HERE: the worker must not read
				// the UI's mutable buffer, and rebuild_from_proj (a project
				// switch mid-command) clears eth_someip/eth_method under it
				spawn shell_worker_eth(app, line, vgui.buf_str(app.eth_target_buf).trim_space(),
					app.eth_someip, app.eth_method)
			} else {
				spawn shell_worker(app, line)
			}
		}
	}
	if busy {
		vgui.same_line()
		vgui.text_dim('…')
	}
	vgui.end()
}

// shell_append adds one echo/response chunk to the Shell scrollback (thread-safe, capped).
fn (mut app App) shell_append(s string) {
	app.mu.lock()
	for l in s.split_into_lines() {
		app.shell_lines << l
	}
	if app.shell_lines.len > 500 {
		app.shell_lines = app.shell_lines[app.shell_lines.len - 500..].clone()
	}
	app.shell_follow = true
	app.mu.unlock()
	vgui.wake()
}

// ---- Flash (UDS firmware download through the blobly bootloader) ----

fn (mut app App) flash_append(line string) {
	app.mu.lock()
	app.flash_log << line
	app.mu.unlock()
	vgui.wake()
}

// GuiFlashSink adapts modules/flash progress to the panel's log + block counter.
struct GuiFlashSink {
mut:
	app &App = unsafe { nil }
}

fn (mut s GuiFlashSink) note(msg string) {
	mut a := unsafe { s.app }
	a.flash_append(msg)
}

fn (mut s GuiFlashSink) block(done int, total int) {
	mut a := unsafe { s.app }
	a.mu.lock()
	a.flash_done = done
	a.flash_total = total
	a.mu.unlock()
	vgui.wake()
}

fn draw_flash(mut app App) {
	vis, op := vgui.begin_closable('Flash', app.show_flash)
	app.show_flash = op
	if !vis {
		vgui.end()
		return
	}
	if !app.running {
		vgui.text_dim('press Start (needs the blobly bootloader on the bus)')
		vgui.end()
		return
	}
	app.mu.lock()
	busy := app.flash_busy
	log := app.flash_log.clone()
	done := app.flash_done
	total := app.flash_total
	app.mu.unlock()
	vgui.set_next_item_width(340)
	vgui.input_text('image', mut app.flash_img_buf)
	vgui.same_line()
	if vgui.button('Browse…') && !busy {
		app.open_browser('flash')
	}
	vgui.set_next_item_width(90)
	vgui.input_text('base', mut app.flash_base_buf)
	vgui.same_line()
	vgui.set_next_item_width(50)
	vgui.input_text('req', mut app.flash_req_buf)
	vgui.same_line()
	vgui.set_next_item_width(50)
	vgui.input_text('rsp', mut app.flash_rsp_buf)
	vgui.same_line()
	vgui.set_next_item_width(40)
	vgui.input_text('ver', mut app.flash_ver_buf)
	// enter boot: the running APP's shell `boot` command (bootcell + reset).
	// Silence is the ack — the boot manager answers the UDS ids afterwards.
	if vgui.button('Enter boot mode') && !busy {
		sh := app.manifest.shell.or_defaults()
		iface := app.trace_iface()
		if iface == '' {
			app.flash_append('(no running channel)')
		} else if app.tx_on(iface, transport.CanFrame{
			id:       sh.input
			extended: trace_ext(sh.input)
			data:     'boot'.bytes()
		})
		{
			app.flash_append('> boot (no reply expected — the reset IS the ack)')
		} else {
			app.flash_append('(send failed on ${iface})')
		}
	}
	vgui.same_line()
	if vgui.button_big('Flash', 190, 120, 45, 120, 0) && !busy {
		path := vgui.buf_str(app.flash_img_buf)
		base := u32(('0x' + vgui.buf_str(app.flash_base_buf)).u64())
		req := u32(('0x' + vgui.buf_str(app.flash_req_buf)).u64())
		rsp := u32(('0x' + vgui.buf_str(app.flash_rsp_buf)).u64())
		ver := u32(vgui.buf_str(app.flash_ver_buf).u64())
		if path == '' {
			app.flash_append('(pick an image first)')
		} else {
			spawn flash_worker(app, path, base, req, rsp, ver)
		}
	}
	if busy {
		vgui.same_line()
		if total > 0 {
			vgui.text_dim('transferring ${done}/${total} blocks (${done * 100 / total}%)')
		} else {
			vgui.text_dim('working…')
		}
	}
	vgui.separator_text('log (newest last)')
	vgui.child_begin('##flashlog', 0)
	for line in log {
		vgui.text(line)
	}
	vgui.child_end()
	vgui.end()
}

fn draw_diag(mut app App) {
	vis, op := vgui.begin_closable('Diagnostics', app.show_diag)
	app.show_diag = op
	if !vis {
		vgui.end()
		return
	}
	if !app.running {
		vgui.text_dim('press Start (needs a UDS server on the bus)')
		vgui.end()
		return
	}
	app.mu.lock()
	busy := app.diag_busy
	log := app.diag_log.clone()
	app.mu.unlock()
	// Which ECU are we talking to? With per-ECU servers there is no longer one answer, and the
	// panel used to assume 0x7E0/0x7E8 — unreachable for every other configured target.
	targets := app.diag_targets()
	// Follow the SELECTION, not the position: if the list changed under us, find where the
	// chosen target went rather than keeping an index that now names something else.
	if app.diag_sel_key != '' {
		app.diag_sel = targets.index(targets.filter(it.key == app.diag_sel_key)[0] or {
			DiagTarget{}
		})
	}
	if app.diag_sel < 0 || app.diag_sel >= targets.len {
		app.diag_sel = 0
	}
	if targets.len > 1 {
		app.diag_sel = vgui.combo('target', targets.map(it.label), app.diag_sel)
	} else if targets.len == 1 {
		vgui.text_dim('target: ${targets[0].label}')
	}
	if app.diag_sel >= 0 && app.diag_sel < targets.len {
		app.diag_sel_key = targets[app.diag_sel].key
	}
	vgui.separator()
	if vgui.button('Session') && !busy {
		spawn diag_worker(app, 'session', u16(0), app.diag_sel_key)
	}
	vgui.same_line()
	if vgui.button('Read VIN') && !busy {
		spawn diag_worker(app, 'vin', u16(0), app.diag_sel_key)
	}
	vgui.same_line()
	if vgui.button('Tester Present') && !busy {
		spawn diag_worker(app, 'tp', u16(0), app.diag_sel_key)
	}
	vgui.set_next_item_width(70)
	vgui.input_text('DID', mut app.diag_did_buf)
	vgui.same_line()
	if vgui.button('Read DID') && !busy {
		did := u16(('0x' + vgui.buf_str(app.diag_did_buf)).u64())
		spawn diag_worker(app, 'did', did, app.diag_sel_key)
	}
	if busy {
		vgui.same_line()
		vgui.text_dim('busy…')
	}
	vgui.separator_text('responses (newest last)')
	vgui.child_begin('##diaglog', 0)
	for line in log {
		vgui.text(line)
	}
	vgui.child_end()
	vgui.end()
}

// ---- Script (Lua, on a worker thread) ----
fn (mut app App) script_push(line string) {
	app.mu.lock()
	app.script_log << line
	app.mu.unlock()
}

fn (mut app App) script_done() {
	app.mu.lock()
	app.script_busy = false
	app.mu.unlock()
	vgui.wake()
}

fn draw_script(mut app App) {
	vis, op := vgui.begin_closable('Script', app.show_script)
	app.show_script = op
	if !vis {
		vgui.end()
		return
	}
	app.mu.lock()
	busy := app.script_busy
	log := app.script_log.clone()
	app.mu.unlock()
	vgui.set_next_item_width(240)
	vgui.input_text('.lua', mut app.script_path_buf)
	vgui.same_line()
	if vgui.button('Run') && !busy {
		// reserve the dbs-reader slot HERE, before the spawn: a worker that
		// hasn't been scheduled yet hasn't registered, and an edit could slip
		// into that gap (the worker releases it in its defer)
		app.mu.lock()
		app.dbc_readers++
		app.mu.unlock()
		spawn script_worker(app, vgui.buf_str(app.script_path_buf))
	}
	if busy {
		vgui.same_line()
		vgui.text_dim('running…')
	}
	vgui.separator_text('output')
	vgui.child_begin('##scriptlog', 0)
	for line in log {
		vgui.text(line)
	}
	vgui.child_end()
	vgui.end()
}
