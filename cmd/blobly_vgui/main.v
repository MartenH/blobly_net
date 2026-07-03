// blobly_vgui — the Dear ImGui + ImPlot frontend for blobly_net (phased migration off
// vlang/gui; see docs/gui_toolkit_evaluation.md).
//   Phase 1: live decoded Trace + Trace Chart swimlane, docked in one window.
//   Phase 2: menu bar (File/View) + Start/Stop measurement lifecycle + a Buses panel with
//            per-channel enable + state colour + RX counts. Channels open on ▶ Start, not
//            at boot. All engine work reuses the GUI-free modules (project/transport/candb/
//            telem) unchanged; gui's src/main.v stays the shipping app until parity.
//
// Build: eval/vgui/build_deps.sh  then
//   v -enable-globals -cc gcc -path "@vlib|@vmodules|modules|eval" run cmd/blobly_vgui/main.v
// Project via BLOBLY_PROJECT (default projects/trace-demo.blobnet). Env: VGUI_WAKE_MS cap.
module main

import os
import sync
import time
import project
import transport
import candb
import telem
import vgui

const trace_cap = 2000
const telem_cap = 20000

struct TraceRow {
	t_ms f64
	ch   string
	id   u32
	ext  bool
	rtr  bool
	name string
	data []u8
}

struct TRec {
	ch  int
	rec telem.Record
}

// Chan is one project channel's live state (the Buses panel row + Start/Stop target).
struct Chan {
	name  string
	iface string
	mode  string
	doip  bool
mut:
	enabled bool
	rx      u64
	running bool
}

fn (c Chan) monitorable() bool {
	return c.enabled && c.mode == 'monitor' && !c.doip
}

struct App {
mut:
	mu           sync.Mutex
	chans        []Chan
	trace        []TraceRow
	trecs        []TRec
	rx           u64 // total across channels
	rev          u64
	running      bool
	dbs          []candb.Database
	manifest     telem.Manifest
	has_manifest bool
	t0           i64
	wake_ms      i64
	last_wake    i64
	proj_path    string
	proj_name    string
	// panel visibility (View menu)
	show_buses    bool = true
	show_trace    bool = true
	show_tchart   bool = true
	show_signals  bool = true
	show_graphics bool = true
	// Signals selection + Graphics watch list (UI-thread only; RX never touches these)
	sel_id  int = -1 // selected message id (-1 = none)
	sel_ext bool
	watch   []Watch // signals plotted in Graphics
}

// Watch identifies one plotted signal.
struct Watch {
	id  u32
	ext bool
	sig string
}

fn (app &App) is_watched(id u32, ext bool, sig string) bool {
	for w in app.watch {
		if w.id == id && w.ext == ext && w.sig == sig {
			return true
		}
	}
	return false
}

fn (mut app App) toggle_watch(id u32, ext bool, sig string) {
	for i, w in app.watch {
		if w.id == id && w.ext == ext && w.sig == sig {
			app.watch.delete(i)
			return
		}
	}
	app.watch << Watch{id, ext, sig}
}

fn (app &App) find_message(id u32, ext bool) ?candb.Message {
	for db in app.dbs {
		if m := db.lookup_frame(id, ext) {
			return m
		}
	}
	return none
}

fn (a &App) lookup_name(id u32, ext bool) string {
	for db in a.dbs {
		if m := db.lookup_frame(id, ext) {
			return m.name
		}
	}
	return ''
}

// start opens every enabled, monitorable channel on its own RX thread.
fn (mut app App) start() {
	if app.running {
		return
	}
	app.running = true
	for ci, ch in app.chans {
		if !ch.monitorable() {
			continue
		}
		app.chans[ci].running = true
		spawn rx_loop(app, ci, ch.iface)
	}
}

// stop signals the RX threads to exit (they re-check on the recv timeout).
fn (mut app App) stop() {
	app.running = false
	for ci in 0 .. app.chans.len {
		app.chans[ci].running = false
	}
}

fn rx_loop(app &App, ci int, iface string) {
	mut bus := transport.open(iface) or {
		eprintln('rx ${iface}: ${err}')
		mut a := unsafe { app }
		a.mu.lock()
		a.chans[ci].running = false
		a.mu.unlock()
		return
	}
	mut a := unsafe { app }
	chname := a.chans[ci].name
	for a.running && a.chans[ci].enabled {
		f := bus.recv(200) or { continue }
		t_ms := f64(time.ticks() - a.t0)
		name := a.lookup_name(f.id, f.extended)
		a.mu.lock()
		a.trace << TraceRow{t_ms, chname, f.id, f.extended, f.rtr, name, f.data.clone()}
		if a.trace.len > trace_cap {
			a.trace = a.trace[a.trace.len - trace_cap..].clone()
		}
		if a.has_manifest && !f.extended && !f.rtr && f.data.len == 8 && f.id == telem.id_record {
			a.trecs << TRec{ci, telem.decode_record(f.data)}
			if a.trecs.len > telem_cap {
				a.trecs = a.trecs[a.trecs.len - telem_cap..].clone()
			}
			a.rev++
		}
		a.chans[ci].rx++
		a.rx++
		a.mu.unlock()
		now := time.ticks()
		if now - a.last_wake >= a.wake_ms {
			a.last_wake = now
			vgui.wake()
		}
	}
	bus.close()
	a.mu.lock()
	a.chans[ci].running = false
	a.mu.unlock()
}

fn hex(b []u8) string {
	mut p := []string{cap: b.len}
	for x in b {
		p << '${x:02X}'
	}
	return p.join(' ')
}

const lane_palette = [
	[u8(66), 135, 245],
	[u8(76), 175, 80],
	[u8(245), 166, 35],
	[u8(233), 80, 80],
	[u8(155), 100, 210],
	[u8(0), 172, 193],
	[u8(233), 110, 170],
	[u8(140), 160, 60],
]

fn main() {
	proj_path := os.getenv_opt('BLOBLY_PROJECT') or { 'projects/trace-demo.blobnet' }
	proj := project.load(proj_path) or {
		eprintln('load ${proj_path}: ${err}')
		return
	}
	mut wake_ms := os.getenv('VGUI_WAKE_MS').i64()
	if wake_ms <= 0 {
		wake_ms = 33
	}
	max_frames := os.getenv('VGUI_FRAMES').int()
	shot := os.getenv('VGUI_SHOT')

	mut app := &App{
		t0:        time.ticks()
		wake_ms:   wake_ms
		proj_path: proj_path
		proj_name: proj.name
	}
	for ch in proj.channels {
		app.chans << Chan{
			name:    ch.name
			iface:   ch.iface
			mode:    ch.mode.str()
			doip:    ch.is_doip()
			enabled: ch.enabled
		}
		for dbpath in ch.databases {
			if db := candb.load_dbc_file(dbpath) {
				app.dbs << db
			} else {
				eprintln('dbc ${dbpath}: ${err}')
			}
		}
		if ch.manifest != '' && !app.has_manifest {
			if m := telem.load_manifest(ch.manifest) {
				app.manifest = m
				app.has_manifest = true
			} else {
				eprintln('manifest ${ch.manifest}: ${err}')
			}
		}
	}
	// default the Signals selection to the first DBC message (so it decodes on launch)
	for db in app.dbs {
		if db.messages.len > 0 {
			app.sel_id = int(db.messages[0].id)
			app.sel_ext = db.messages[0].ext
			break
		}
	}
	println('blobly_vgui: ${proj.name} — ${app.chans.len} channel(s), ${app.dbs.len} DBC(s), manifest=${app.has_manifest}. Press Start.')

	if !vgui.init('blobly_net — ${proj.name} (imgui/ImPlot)', 1500, 850, true) {
		eprintln('vgui.init failed')
		return
	}
	if os.getenv('BLOBLY_AUTOSTART') != '' {
		app.start()
	}

	mut frame := 0
	for vgui.running() {
		frame++
		last := max_frames > 0 && frame >= max_frames
		if last && shot != '' {
			vgui.dump_ppm(shot)
		}

		app.mu.lock()
		rx := app.rx
		rows := app.trace.clone()
		trecs := app.trecs.clone()
		chans := app.chans.clone()
		app.mu.unlock()

		vgui.frame_begin()
		draw_menubar(mut app, rx)
		build_layout()

		if app.show_buses {
			draw_buses(mut app, chans)
		}
		if app.show_trace {
			draw_trace(app, rows, rx)
		}
		if app.show_tchart {
			draw_tchart(app, trecs)
		}
		if app.show_signals {
			draw_signals(mut app, rows)
		}
		if app.show_graphics {
			draw_graphics(app, rows)
		}

		vgui.frame_end()
		if last {
			eprintln('rendered ${frame} frames; RX ${rx}')
			break
		}
	}
	app.stop()
	vgui.shutdown()
}

fn draw_menubar(mut app App, rx u64) {
	if vgui.menu_bar_begin() {
		if vgui.menu_begin('File') {
			if vgui.menu_item('Exit') {
				vgui.quit()
			}
			vgui.menu_end()
		}
		if vgui.menu_begin('View') {
			app.show_buses = vgui.menu_item_check('Buses', app.show_buses)
			app.show_trace = vgui.menu_item_check('Trace', app.show_trace)
			app.show_tchart = vgui.menu_item_check('Trace Chart', app.show_tchart)
			app.show_signals = vgui.menu_item_check('Signals', app.show_signals)
			app.show_graphics = vgui.menu_item_check('Graphics', app.show_graphics)
			vgui.menu_end()
		}
		vgui.text('   ')
		if app.running {
			if vgui.small_button('Stop') {
				app.stop()
			}
		} else {
			if vgui.small_button('Start') {
				app.start()
			}
		}
		vgui.same_line()
		if app.running {
			vgui.text_colored(90, 200, 120, 'running')
		} else {
			vgui.text_colored(210, 120, 120, 'stopped')
		}
		vgui.same_line()
		vgui.text('· RX ${rx} · ${app.proj_name}')
		vgui.menu_bar_end()
	}
}

// channel state colour + short ASCII label (imgui's default font is ASCII-only):
// green run / amber idle (enabled, not measuring) / grey off (disabled).
fn chan_state(c Chan) (u8, u8, u8, string) {
	if !c.enabled {
		return u8(140), u8(140), u8(145), 'off '
	}
	if c.running {
		return u8(90), u8(200), u8(120), 'run '
	}
	return u8(220), u8(170), u8(70), 'idle'
}

fn draw_buses(mut app App, chans []Chan) {
	vgui.begin('Buses')
	vgui.text('${app.proj_name} · ${chans.len} channel(s)')
	vgui.separator_text('channels')
	for i, c in chans {
		new := vgui.checkbox('##en${i}', c.enabled)
		if new != c.enabled {
			app.mu.lock()
			app.chans[i].enabled = new
			// enabling a channel mid-run spawns its RX thread; disabling lets it exit
			if new && app.running && c.monitorable() && !app.chans[i].running {
				app.chans[i].running = true
				spawn rx_loop(app, i, app.chans[i].iface)
			}
			app.mu.unlock()
		}
		vgui.same_line()
		r, g, b, label := chan_state(c)
		vgui.text_colored(r, g, b, label)
		vgui.same_line()
		vgui.text('${c.name}  ${c.iface}  [${c.mode}]  RX ${c.rx}')
	}
	vgui.end()
}

fn draw_trace(app &App, rows []TraceRow, rx u64) {
	vgui.begin('Trace')
	vgui.text('RX ${rx} · ${rows.len} shown · ${vgui.fps():.0}fps')
	vgui.separator_text('frames (newest first)')
	if vgui.table_begin('trace', 5) {
		vgui.table_col('t (ms)')
		vgui.table_col('ch')
		vgui.table_col('id')
		vgui.table_col('name')
		vgui.table_col('data')
		vgui.table_headers()
		mut i := rows.len - 1
		mut shown := 0
		for i >= 0 && shown < 200 {
			r := rows[i]
			idw := if r.ext { '0x${r.id:08X}' } else { '0x${r.id:03X}' }
			vgui.table_row()
			vgui.table_cell('${r.t_ms:.1}')
			vgui.table_cell(r.ch)
			vgui.table_cell(idw)
			vgui.table_cell(r.name)
			vgui.table_cell(if r.rtr { 'RTR' } else { hex(r.data) })
			i--
			shown++
		}
		vgui.table_end()
	}
	vgui.end()
}

// build_layout docks the five panels once: Buses (left) | Trace (centre) | a right
// column stacked Trace Chart / Signals / Graphics.
fn build_layout() {
	root := vgui.dock_root()
	if root == 0 {
		return // already laid out (persisted in imgui.ini)
	}
	mut rest := u32(0)
	buses := vgui.dock_split(root, vgui.dock_left, 0.15, &rest)
	mut center := u32(0)
	right := vgui.dock_split(rest, vgui.dock_right, 0.34, &center)
	mut rmid := u32(0)
	chart := vgui.dock_split(right, vgui.dock_up, 0.30, &rmid)
	mut graphics := u32(0)
	signals := vgui.dock_split(rmid, vgui.dock_up, 0.58, &graphics)
	vgui.dock_window('Buses', buses)
	vgui.dock_window('Trace', center)
	vgui.dock_window('Trace Chart', chart)
	vgui.dock_window('Signals', signals)
	vgui.dock_window('Graphics', graphics)
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
	vgui.begin('Signals')
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
	for s in m.active_signals(data) {
		watched := app.is_watched(u32(app.sel_id), app.sel_ext, s.name)
		nw := vgui.checkbox('##w_${m.id}_${s.name}', watched)
		if nw != watched {
			app.toggle_watch(u32(app.sel_id), app.sel_ext, s.name)
		}
		vgui.same_line()
		lbl := s.label(data)
		extra := if lbl != '' { ' (${lbl})' } else { '' }
		unit := if s.unit != '' { ' ${s.unit}' } else { '' }
		vgui.text('${s.name} = ${s.physical(data):.3}${unit}${extra}')
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
			xs << f32(r.t_ms)
			ys << f32(sig.physical(r.data))
		}
	}
	return xs, ys
}

// draw_graphics plots the watched signals over the trace history as ImPlot lines
// (native pan/zoom/legend/tooltip).
fn draw_graphics(app &App, rows []TraceRow) {
	vgui.begin('Graphics')
	if app.watch.len == 0 {
		vgui.text_dim('tick a signal in the Signals panel to plot it')
		vgui.end()
		return
	}
	vgui.text('${app.watch.len} signal(s) · drag = pan · scroll = zoom')
	if vgui.plot_begin('##sigplot', 260) {
		for w in app.watch {
			xs, ys := app.build_series(rows, w)
			if xs.len > 0 {
				vgui.plot_line('0x${w.id:X}.${w.sig}', xs, ys)
			}
		}
		vgui.plot_end()
	}
	vgui.end()
}

fn draw_tchart(app &App, trecs []TRec) {
	vgui.begin('Trace Chart')
	if app.has_manifest {
		labels, bars, span := build_swimlane(app, trecs)
		vgui.text('${trecs.len} records · ${labels.len} handlers · gaps = idle')
		vgui.text_dim('drag = pan · scroll = zoom · double-click = fit')
		if bars.len > 0 {
			vgui.swimlane('##swim', labels, bars, span)
		} else {
			vgui.text_dim('waiting for Record frames (0x7E5)')
		}
	} else {
		vgui.text_dim('no telemetry manifest on any channel')
	}
	vgui.end()
}

fn build_swimlane(app &App, trecs []TRec) ([]string, []vgui.Bar, f32) {
	if trecs.len == 0 {
		return []string{}, []vgui.Bar{}, f32(1)
	}
	mut lane_of := map[u8]int{}
	mut labels := []string{}
	for tr in trecs {
		id := tr.rec.handler_id
		if id !in lane_of {
			lane_of[id] = labels.len
			labels << app.manifest.label(id)
		}
	}
	mut tmin := f32(3.4e38)
	mut tmax := f32(0)
	for tr in trecs {
		s := f32(tr.rec.start_us)
		e := s + f32(tr.rec.cpu_us)
		if s < tmin {
			tmin = s
		}
		if e > tmax {
			tmax = e
		}
	}
	span := if tmax > tmin { tmax - tmin } else { f32(1) }
	mut bars := []vgui.Bar{cap: trecs.len}
	for tr in trecs {
		r := tr.rec
		li := lane_of[r.handler_id]
		c := lane_palette[li % lane_palette.len]
		bars << vgui.Bar{
			t0:        f32(r.start_us) - tmin
			dur:       f32(r.cpu_us)
			lane:      li
			color:     vgui.rgba(c[0], c[1], c[2], 235)
			warn:      if (r.flags & (telem.flag_overran | telem.flag_saturated)) != 0 { 1 } else { 0 }
			preempted: if (r.flags & telem.flag_preempted) != 0 { 1 } else { 0 }
		}
	}
	return labels, bars, span
}
