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
import isotp
import uds
import script
import vgui

const diag_tx_id = u32(0x7E0)
const diag_rx_id = u32(0x7E8)

const trace_cap = 2000
const telem_cap = 20000

struct TraceRow {
	t_ms f64
	ch   string
	dir  string // 'RX' | 'TX'
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
	show_send     bool = true
	show_diag     bool = true
	show_gen      bool = true
	show_script   bool = true
	// Signals selection + Graphics watch list (UI-thread only; RX never touches these)
	sel_id        int = -1 // selected message id (-1 = none)
	sel_ext       bool
	watch         []Watch // signals plotted in Graphics
	trace_grouped bool    // Trace: grouped-by-id (expandable) vs chronological
	// TX bus (Send / Generators) — opened on the first monitor channel at Start
	send_bus      ?transport.Bus
	send_iface    string
	send_id_buf   []u8
	send_data_buf []u8
	// Diagnostics (UDS on a worker thread)
	diag_did_buf []u8
	// Script (Lua on a worker thread)
	script_path_buf []u8
	senders         []SenderRT // flattened project senders (Generators)
	// worker-thread outputs (guarded by mu)
	diag_log    []string
	diag_busy   bool
	script_log  []string
	script_busy bool
}

// SenderRT is a project sender bound to its channel iface (Generators panel).
struct SenderRT {
	iface  string
	sender project.Sender
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
		// open a TX bus on the first monitor channel (Send / Generators)
		if app.send_iface == '' {
			if b := transport.open(ch.iface) {
				app.send_bus = b
				app.send_iface = ch.iface
			}
		}
	}
}

// stop signals the RX threads to exit (they re-check on the recv timeout).
fn (mut app App) stop() {
	app.running = false
	for ci in 0 .. app.chans.len {
		app.chans[ci].running = false
	}
	if mut b := app.send_bus {
		b.close()
	}
	app.send_bus = none
	app.send_iface = ''
}

// tx sends a frame on the TX bus and records it as a TX trace row.
fn (mut app App) tx(f transport.CanFrame) bool {
	mut b := app.send_bus or { return false }
	b.send(f) or { return false }
	name := app.lookup_name(f.id, f.extended)
	app.mu.lock()
	app.trace << TraceRow{f64(time.ticks() - app.t0), app.send_iface, 'TX', f.id, f.extended, f.rtr, name, f.data.clone()}
	app.rx++ // count TX in the total too
	app.mu.unlock()
	vgui.wake()
	return true
}

// mkbuf returns a fixed-size NUL-terminated input buffer seeded with `s`.
fn mkbuf(s string, size int) []u8 {
	mut b := []u8{len: size}
	for i, c in s {
		if i < size - 1 {
			b[i] = c
		}
	}
	return b
}

// parse_hex_bytes parses "DE AD BE" / "DEADBE" into bytes.
fn parse_hex_bytes(s string) []u8 {
	clean := s.replace(' ', '').replace('\t', '')
	mut out := []u8{}
	mut i := 0
	for i + 1 < clean.len + 1 && i + 2 <= clean.len {
		out << u8(('0x' + clean[i..i + 2]).u64())
		i += 2
	}
	return out
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
		a.trace << TraceRow{t_ms, chname, 'RX', f.id, f.extended, f.rtr, name, f.data.clone()}
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
	// flatten project senders (Generators) + seed the input buffers
	for ch in proj.channels {
		for s in ch.senders {
			app.senders << SenderRT{ch.iface, s}
		}
	}
	app.send_id_buf = mkbuf('101', 24)
	app.send_data_buf = mkbuf('01', 64)
	app.diag_did_buf = mkbuf('F190', 16)
	app.script_path_buf = mkbuf('tests/diag_basic.lua', 256)
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
			draw_trace(mut app, rows, rx)
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
		if app.show_send {
			draw_send(mut app)
		}
		if app.show_diag {
			draw_diag(mut app)
		}
		if app.show_gen {
			draw_gen(mut app)
		}
		if app.show_script {
			draw_script(mut app)
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
			app.show_send = vgui.menu_item_check('Send', app.show_send)
			app.show_diag = vgui.menu_item_check('Diagnostics', app.show_diag)
			app.show_gen = vgui.menu_item_check('Generators', app.show_gen)
			app.show_script = vgui.menu_item_check('Script', app.show_script)
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
	if !vgui.begin('Buses') {
		vgui.end()
		return
	}
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

fn draw_trace(mut app App, rows []TraceRow, rx u64) {
	if !vgui.begin('Trace') {
		vgui.end()
		return
	}
	if vgui.small_button(if app.trace_grouped { 'View: grouped' } else { 'View: all' }) {
		app.trace_grouped = !app.trace_grouped
	}
	vgui.same_line()
	vgui.text('RX ${rx} · ${vgui.fps():.0}fps')
	if app.trace_grouped {
		vgui.separator_text('by id (click to expand signals)')
		draw_trace_grouped(app, rows)
	} else {
		vgui.separator_text('frames (newest first)')
		draw_trace_all(rows)
	}
	vgui.end()
}

fn idstr(id u32, ext bool) string {
	return if ext { '0x${id:08X}' } else { '0x${id:03X}' }
}

fn draw_trace_all(rows []TraceRow) {
	if vgui.table_begin('trace', 6) {
		vgui.table_col('t (ms)')
		vgui.table_col('ch')
		vgui.table_col('dir')
		vgui.table_col('id')
		vgui.table_col('name')
		vgui.table_col('data')
		vgui.table_headers()
		mut i := rows.len - 1
		mut shown := 0
		for i >= 0 && shown < 200 {
			r := rows[i]
			vgui.table_row()
			vgui.table_cell('${r.t_ms:.1}')
			vgui.table_cell(r.ch)
			vgui.table_cell(r.dir)
			vgui.table_cell(idstr(r.id, r.ext))
			vgui.table_cell(r.name)
			vgui.table_cell(if r.rtr { 'RTR' } else { hex(r.data) })
			i--
			shown++
		}
		vgui.table_end()
	}
}

// grouped: one collapsible row per (dir, ch, id); expand to decode its latest signals.
fn draw_trace_grouped(app &App, rows []TraceRow) {
	mut order := []string{}
	mut counts := map[string]int{}
	mut lasts := map[string]TraceRow{}
	for r in rows {
		k := '${r.dir}|${r.ch}|${r.id}|${r.ext}'
		if k !in counts {
			order << k
		}
		counts[k]++
		lasts[k] = r
	}
	for k in order {
		r := lasts[k]
		hdr := '${r.dir}  ${idstr(r.id, r.ext)}  ${r.name}  x${counts[k]}  ${hex(r.data)}##${k}'
		if vgui.tree_node(hdr) {
			if m := app.find_message(r.id, r.ext) {
				for s in m.active_signals(r.data) {
					lbl := s.label(r.data)
					extra := if lbl != '' { ' (${lbl})' } else { '' }
					unit := if s.unit != '' { ' ${s.unit}' } else { '' }
					vgui.text('    ${s.name} = ${s.physical(r.data):.3}${unit}${extra}')
				}
			}
			vgui.tree_pop()
		}
	}
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
	chart := vgui.dock_split(right, vgui.dock_up, 0.28, &rmid)
	mut bottom := u32(0)
	midnode := vgui.dock_split(rmid, vgui.dock_up, 0.5, &bottom)
	vgui.dock_window('Buses', buses)
	vgui.dock_window('Trace', center)
	vgui.dock_window('Trace Chart', chart)
	// tab groups: [Signals | Send | Diagnostics] over [Graphics | Generators | Script]
	vgui.dock_window('Signals', midnode)
	vgui.dock_window('Send', midnode)
	vgui.dock_window('Diagnostics', midnode)
	vgui.dock_window('Graphics', bottom)
	vgui.dock_window('Generators', bottom)
	vgui.dock_window('Script', bottom)
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
	if !vgui.begin('Signals') {
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
	if !vgui.begin('Graphics') {
		vgui.end()
		return
	}
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

// ---- Send ----
fn draw_send(mut app App) {
	if !vgui.begin('Send') {
		vgui.end()
		return
	}
	if !app.running {
		vgui.text_dim('press Start to enable sending')
		vgui.end()
		return
	}
	vgui.text('bus ${app.send_iface}')
	vgui.set_next_item_width(70)
	vgui.input_text('id (hex)', mut app.send_id_buf)
	vgui.same_line()
	vgui.set_next_item_width(220)
	vgui.input_text('data (hex)', mut app.send_data_buf)
	if vgui.button('Send') {
		id := u32(('0x' + vgui.buf_str(app.send_id_buf)).u64())
		data := parse_hex_bytes(vgui.buf_str(app.send_data_buf))
		app.tx(transport.CanFrame{
			id:   id
			data: data
		})
	}
	vgui.end()
}

// ---- Generators (project senders) ----
fn draw_gen(mut app App) {
	if !vgui.begin('Generators') {
		vgui.end()
		return
	}
	if app.senders.len == 0 {
		vgui.text_dim('no senders defined in the project')
		vgui.end()
		return
	}
	if !app.running {
		vgui.text_dim('press Start to fire senders')
		vgui.end()
		return
	}
	for i, sr in app.senders {
		s := sr.sender
		if vgui.button('Fire##${i}') {
			app.fire_sender(sr)
		}
		vgui.same_line()
		key := if s.key != '' { ' [${s.key}]' } else { '' }
		vgui.text('${s.name}${key} · ${s.trigger}')
	}
	vgui.end()
}

fn (mut app App) fire_sender(sr SenderRT) {
	s := sr.sender
	mut id := s.id
	mut data := s.data.clone()
	if s.message != '' {
		mut found := false
		for db in app.dbs {
			for m in db.messages {
				if m.name != s.message {
					continue
				}
				id = m.id
				if data.len == 0 {
					data = []u8{len: m.dlc}
				}
				for ss in s.signals {
					for sig in m.signals {
						if sig.name == ss.name {
							sig.encode(mut data, ss.value)
							break
						}
					}
				}
				found = true
				break
			}
			if found {
				break
			}
		}
	}
	app.tx(transport.CanFrame{
		id:       id
		extended: s.ext
		data:     data
	})
}

// ---- Diagnostics (UDS over software ISO-TP, on a worker thread) ----
fn (mut app App) diag_push(line string) {
	app.mu.lock()
	app.diag_log << line
	if app.diag_log.len > 200 {
		app.diag_log = app.diag_log[app.diag_log.len - 200..].clone()
	}
	app.mu.unlock()
}

fn (app &App) diag_iface() string {
	for c in app.chans {
		if c.monitorable() && c.running {
			return c.iface
		}
	}
	return ''
}

fn diag_worker(app &App, kind string, did u16) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.diag_busy {
		a.mu.unlock()
		return
	}
	a.diag_busy = true
	a.mu.unlock()
	iface := a.diag_iface()
	mut ch := isotp.open_software(iface, diag_tx_id, diag_rx_id, false) or {
		a.diag_push('open ${iface}: ${err}')
		a.mu.lock()
		a.diag_busy = false
		a.mu.unlock()
		vgui.wake()
		return
	}
	mut c := uds.new_client(ch)
	match kind {
		'session' {
			c.diagnostic_session(0x03) or {
				a.diag_push('session: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('session 0x03 OK')
		}
		'vin' {
			r := c.read_data_by_identifier(0xF190) or {
				a.diag_push('VIN: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('VIN = ${r.bytestr()}')
		}
		'tp' {
			c.tester_present() or {
				a.diag_push('tester present: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('tester present OK')
		}
		'did' {
			r := c.read_data_by_identifier(did) or {
				a.diag_push('DID ${did:04X}: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('DID ${did:04X} = ${hex(r)}  "${printable(r)}"')
		}
		else {}
	}
	a.diag_done()
}

fn (mut app App) diag_done() {
	app.mu.lock()
	app.diag_busy = false
	app.mu.unlock()
	vgui.wake()
}

fn printable(b []u8) string {
	mut s := ''
	for c in b {
		s += if c >= 0x20 && c < 0x7f { c.ascii_str() } else { '.' }
	}
	return s
}

fn draw_diag(mut app App) {
	if !vgui.begin('Diagnostics') {
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
	if vgui.button('Session') && !busy {
		spawn diag_worker(app, 'session', u16(0))
	}
	vgui.same_line()
	if vgui.button('Read VIN') && !busy {
		spawn diag_worker(app, 'vin', u16(0))
	}
	vgui.same_line()
	if vgui.button('Tester Present') && !busy {
		spawn diag_worker(app, 'tp', u16(0))
	}
	vgui.set_next_item_width(70)
	vgui.input_text('DID', mut app.diag_did_buf)
	vgui.same_line()
	if vgui.button('Read DID') && !busy {
		did := u16(('0x' + vgui.buf_str(app.diag_did_buf)).u64())
		spawn diag_worker(app, 'did', did)
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

fn script_worker(app &App, path string) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.script_busy {
		a.mu.unlock()
		return
	}
	a.script_busy = true
	a.script_log = []
	a.mu.unlock()
	mut chans := []script.ChanInfo{}
	first_db := if a.dbs.len > 0 { a.dbs[0] } else { candb.Database{} }
	for ch in a.chans {
		chans << script.ChanInfo{
			name:  ch.name
			iface: ch.iface
			db:    first_db
		}
	}
	mut env := script.new_env(chans) or {
		a.script_push('env init: ${err}')
		a.script_done()
		return
	}
	env.run_file(path) or { a.script_push('error: ${err}') }
	a.script_push('${env.passed()}/${env.total()} passed, ${env.failed()} failed')
	env.close()
	a.script_done()
}

fn (mut app App) script_done() {
	app.mu.lock()
	app.script_busy = false
	app.mu.unlock()
	vgui.wake()
}

fn draw_script(mut app App) {
	if !vgui.begin('Script') {
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

fn draw_tchart(app &App, trecs []TRec) {
	if !vgui.begin('Trace Chart') {
		vgui.end()
		return
	}
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
