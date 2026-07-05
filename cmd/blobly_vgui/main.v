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
import sim
import script
import canlog
import mf4
import doip
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
	name         string
	network      string // grouping label (v2)
	adapter      string // transport backend (v2): virtual|vcan|socketcan|udp|pcan|kvaser|doip
	address      string // adapter-specific address (v2)
	iface        string
	mode         string
	typ          string
	bitrate      int
	data_bitrate int
	listen_only  bool
	databases    []string
	manifest     string
	doip         bool
mut:
	enabled   bool
	rx        u64
	running   bool
	link_down bool // real CAN iface is administratively DOWN (bound but can't tx/rx)
}

fn (c Chan) monitorable() bool {
	return c.enabled && c.mode == 'monitor' && !c.doip
}

struct App {
mut:
	mu           sync.Mutex
	chans        []Chan
	trace        []TraceRow
	gcount       map[string]u64 // persistent per-group frame totals (survive the ring trim)
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
	dark      bool = true // theme
	ui_scale  f32  = 1.0
	paused    bool
	recording bool
	rec       []canlog.LogEntry // captured while recording; written on stop
	tx_count  u64
	logs      []string             // Log panel (status/events, newest last)
	doip_ents []doip.VehicleInfo   // DoIP Discovery results
	// panel visibility (View menu)
	// Default workspace is intentionally minimal: Buses + Trace + Log. Everything else is
	// off and toggled on via the activity bar / View menu (its dock slot is still reserved).
	show_buses    bool = true
	show_sim      bool
	show_symbols  bool
	show_trace    bool = true
	show_ftrace   bool
	show_tchart   bool
	show_signals  bool
	show_graphics bool
	show_send      bool
	show_diag      bool
	show_gen       bool
	show_script    bool
	show_busconfig bool
	show_doip      bool
	show_network   bool
	show_stats     bool
	show_log       bool = true
	show_help      bool
	// Signals selection + Graphics watch list (UI-thread only; RX never touches these)
	sel_id        int = -1 // selected message id (-1 = none)
	sel_ext       bool
	watch         []Watch // signals plotted in Graphics
	trace_grouped bool = true // Trace: grouped-by-id (expandable) vs chronological
	trace_bus     string      // main Trace: show only this bus (channel name); '' = all
	ftrace_bus    string      // Trace (filter) panel: show only this bus; '' = all
	fwatch        []FrameId   // Trace (filter) watch list — frames added from Trace/Symbols
	// TX buses — one open bus per channel iface, created at Start. Generators fire on their
	// own target bus (its channel, or a `bus:` override); the Send panel defaults to
	// send_iface (the first monitor channel).
	tx_buses      map[string]transport.Bus
	send_iface    string
	send_id_buf   []u8
	send_data_buf []u8
	trace_filter_buf  []u8 // Trace substring filter
	trace_grouped2    bool // second Trace (filter) panel: own view mode
	trace_filter2_buf []u8 // second Trace (filter) panel: own filter
	symbol_filter_buf []u8 // Symbol Browser search
	log_path_buf      []u8 // Open Recording path (.log/.mf4)
	doip_host_buf     []u8 // DoIP manual discover host[:port]
	// Diagnostics (UDS on a worker thread)
	diag_did_buf []u8
	// Script (Lua on a worker thread)
	script_path_buf []u8
	senders         []SenderRT // flattened project senders (Generators)
	gen_bufs        []GenBuf   // per-sender editable fields (parallel to senders)
	dirty       bool       // project (config or generators) changed since load/save (● modified)
	proj            project.Project // the loaded project, kept so Save can persist edits
	// Configuration editor (stopped-only) + its per-bus edit buffers (parallel to proj.channels)
	show_config bool
	cfg_bufs    []CfgBuf
	// Discover-interfaces dialog (add buses from detected transports)
	disc_open bool
	disc_list []DiscoveredIface
	disc_tick []bool // parallel to disc_list
	// File browser (Open / Save As / attach DBC / attach manifest)
	fb_open     bool   // browser window shown
	fb_save     bool   // true = save mode (filename input), false = open mode
	fb_dir      string // current directory
	fb_name_buf []u8   // filename (save mode)
	fb_ext      string // extension filter ('.blobnet' | '.dbc' | '' = recordings)
	fb_target   string // action on OK: 'open' | 'saveas' | 'dbc:<ci>' | 'manifest:<ci>'
	sims            []SimCfg   // per-channel in-process simulation workloads
	sim_enabled     map[string]bool // '<iface>:<node>' -> enabled (Simulation panel)
	sim_gen         u64             // bumped when sim_enabled changes -> sim_loop rebuilds
	// worker-thread outputs (guarded by mu)
	diag_log    []string
	diag_busy   bool
	script_log  []string
	script_busy bool
}

// SenderRT is a project sender bound to its channel iface (Generators panel).
struct SenderRT {
	iface string
mut:
	sender project.Sender
}

// target is the bus (channel iface) this generator transmits on: an explicit `bus:`
// override if set, else the sender's own channel.
fn (sr SenderRT) target() string {
	return if sr.sender.bus != '' { sr.sender.bus } else { sr.iface }
}

// GenBuf holds a generator's editable text fields (parallel to App.senders).
struct GenBuf {
mut:
	name_buf []u8
	key_buf  []u8
	id_buf   []u8 // raw (non-DBC) generators: CAN id (hex)
	data_buf []u8 // raw generators: payload (hex)
}

// CfgBuf holds one bus's editable text fields in the Configuration editor (parallel to
// app.proj.channels). Enums (adapter/mode/protocol) and checkboxes edit the model directly;
// only the free-text fields need a buffer.
struct CfgBuf {
mut:
	name_buf    []u8
	network_buf []u8
	address_buf []u8
	bitrate_buf []u8
	manifest_buf []u8
	dbc_buf     []u8 // "+ Add DBC" typed-path fallback
	// DoIP
	tester_buf []u8
	ecu_buf    []u8
	vin_buf    []u8
	// Replay
	replay_src_buf   []u8
	replay_speed_buf []u8
}

// SimCfg is one channel's in-process simulation workload (simulated ECUs + its DBC).
struct SimCfg {
	iface string
	db    candb.Database
	nodes []project.NodeCfg
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

// FrameId identifies one CAN frame (id + 29-bit flag) for the Trace (filter) watch list.
struct FrameId {
	id  u32
	ext bool
}

// chan_name_for maps a bus iface back to its channel name (the Trace `ch` column value),
// falling back to the iface if unmatched.
fn (app &App) chan_name_for(iface string) string {
	for c in app.chans {
		if c.iface == iface {
			return c.name
		}
	}
	return iface
}

fn (app &App) is_fwatched(id u32, ext bool) bool {
	for f in app.fwatch {
		if f.id == id && f.ext == ext {
			return true
		}
	}
	return false
}

// add_fwatch adds a frame to the Trace (filter) watch list (no-op if already present).
fn (mut app App) add_fwatch(id u32, ext bool) {
	if !app.is_fwatched(id, ext) {
		app.fwatch << FrameId{id, ext}
		app.notify('added ${idstr(id, ext)} to Trace (filter)')
	}
}

fn (mut app App) remove_fwatch(id u32, ext bool) {
	for i, f in app.fwatch {
		if f.id == id && f.ext == ext {
			app.fwatch.delete(i)
			return
		}
	}
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
		app.chans[ci].link_down = !iface_link_up(ch.adapter, ch.address)
		spawn rx_loop(app, ci, ch.iface)
		// open a TX bus for this channel's iface (each generator fires on its target bus)
		if ch.iface !in app.tx_buses {
			if b := transport.open(ch.iface) {
				app.tx_buses[ch.iface] = b
			}
		}
		if app.send_iface == '' {
			app.send_iface = ch.iface // Send panel default = first monitor channel
		}
	}
	// a generator may target a bus whose channel isn't itself monitored — open those too
	for sr in app.senders {
		tgt := sr.target()
		if tgt != '' && tgt !in app.tx_buses {
			if b := transport.open(tgt) {
				app.tx_buses[tgt] = b
			}
		}
	}
	// spawn the in-process simulation workloads (driver-free sim ECUs + a UDS server)
	for sc in app.sims {
		spawn sim_loop(app, sc)
		spawn diag_server_loop(app, sc.iface)
	}
	spawn gen_loop(app) // cyclic senders
}

// stop signals the RX threads to exit (they re-check on the recv timeout).
fn (mut app App) stop() {
	app.running = false
	for ci in 0 .. app.chans.len {
		app.chans[ci].running = false
	}
	for _, mut b in app.tx_buses {
		b.close()
	}
	app.tx_buses = map[string]transport.Bus{}
	app.send_iface = ''
}

// notify appends a line to the Log panel (thread-safe).
fn (mut app App) notify(msg string) {
	app.mu.lock()
	app.logs << msg
	if app.logs.len > 500 {
		app.logs = app.logs[app.logs.len - 500..].clone()
	}
	app.mu.unlock()
	vgui.wake()
}

// tx sends a frame on the default TX bus (send_iface) and records it as a TX trace row.
fn (mut app App) tx(f transport.CanFrame) bool {
	return app.tx_on(app.send_iface, f)
}

// tx_on sends a frame on the bus `iface` (a channel iface) and records it as a TX row on
// that bus. Generators use this to fire on their own target bus rather than a single
// global send bus.
fn (mut app App) tx_on(iface string, f transport.CanFrame) bool {
	mut b := app.tx_buses[iface] or {
		app.notify('TX failed: no open bus for ${iface}')
		return false
	}
	b.send(f) or {
		app.notify('TX failed: ${err}')
		return false
	}
	name := app.lookup_name(f.id, f.extended)
	chn := app.chan_name_for(iface) // trace `ch` column is the bus NAME (matches RX rows)
	tms := f64(time.ticks() - app.t0)
	app.mu.lock()
	if !app.paused {
		app.trace << TraceRow{tms, chn, 'TX', f.id, f.extended, f.rtr, name, f.data.clone()}
		if app.trace.len > trace_cap {
			app.trace = app.trace[app.trace.len - trace_cap..].clone()
		}
		app.gcount[gkey('TX', chn, f.id, f.extended)]++
	}
	if app.recording {
		app.rec << canlog.LogEntry{tms / 1000.0, iface, f}
	}
	app.tx_count++
	app.mu.unlock()
	vgui.wake()
	return true
}

fn (mut app App) clear_trace() {
	app.mu.lock()
	app.trace = []
	app.gcount = map[string]u64{}
	app.trecs = []
	app.rx = 0
	app.tx_count = 0
	for i in 0 .. app.chans.len {
		app.chans[i].rx = 0
	}
	app.mu.unlock()
}

// toggle_record starts capturing frames, or stops and writes them to a candump .log.
fn (mut app App) toggle_record() {
	if app.recording {
		app.mu.lock()
		entries := app.rec.clone()
		app.rec = []
		app.recording = false
		app.mu.unlock()
		mut lines := []string{cap: entries.len}
		for e in entries {
			lines << canlog.format_line(e)
		}
		os.write_file('recording.log', lines.join('\n') + '\n') or {
			app.notify('record write failed: ${err}')
			return
		}
		app.notify('recorded ${entries.len} frames -> recording.log')
	} else {
		app.mu.lock()
		app.rec = []
		app.recording = true
		app.mu.unlock()
		app.notify('recording…')
	}
}

// load_recording replaces the trace with a candump .log or ASAM .mf4 file.
fn (mut app App) load_recording(path string) {
	entries := if path.to_lower().ends_with('.mf4') {
		mf4.load_file(path) or {
			app.notify('mf4 ${path}: ${err}')
			return
		}
	} else {
		canlog.load_file(path) or {
			app.notify('log ${path}: ${err}')
			return
		}
	}
	t0 := if entries.len > 0 { entries[0].t_s } else { 0.0 }
	app.mu.lock()
	app.trace = []
	app.gcount = map[string]u64{}
	for e in entries {
		f := e.frame
		name := app.lookup_name(f.id, f.extended)
		app.trace << TraceRow{(e.t_s - t0) * 1000.0, e.iface, 'RX', f.id, f.extended, f.rtr, name, f.data.clone()}
		if app.trace.len > trace_cap {
			app.trace = app.trace[app.trace.len - trace_cap..].clone()
		}
		app.gcount[gkey('RX', e.iface, f.id, f.extended)]++
	}
	app.mu.unlock()
	app.notify('loaded ${entries.len} frames from ${os.base(path)}')
}

fn doip_worker(app &App, host string) {
	mut a := unsafe { app }
	mut h := host
	mut port := 13400
	if host.contains(':') {
		parts := host.split(':')
		h = parts[0]
		port = parts[1].int()
	}
	info := doip.discover(h, port, 1200) or {
		a.notify('DoIP discover ${host}: ${err}')
		return
	}
	a.mu.lock()
	a.doip_ents << info
	a.mu.unlock()
	a.notify('DoIP: found VIN ${info.vin}')
	vgui.wake()
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

// merge_dbs loads + concatenates a channel's DBCs into one Database (for the sim engine).
fn merge_dbs(paths []string) candb.Database {
	mut msgs := []candb.Message{}
	mut nodes := []string{}
	for p in paths {
		if db := candb.load_dbc_file(p) {
			msgs << db.messages
			nodes << db.nodes
		}
	}
	return candb.Database{
		messages: msgs
		nodes:    nodes
	}
}

fn gen_of(g project.GenCfg) sim.Gen {
	return match g.typ {
		'sine' { sim.gen_sine(g.offset, g.amplitude, g.freq, g.phase) }
		'sawtooth' { sim.gen_sawtooth(g.min, g.max, g.period) }
		'counter' { sim.gen_counter(g.start, g.step, g.modulo) }
		'stepmod' { sim.gen_stepmod(g.period, g.count, g.base) }
		else { sim.gen_const(g.value) }
	}
}

fn build_node(db candb.Database, cfg project.NodeCfg) sim.SimEcu {
	if cfg.signals.len == 0 && cfg.responses.len == 0 {
		return sim.build_ecu(db, cfg.name)
	}
	mut gens := map[string]sim.Gen{}
	for g in cfg.signals {
		gens[g.signal] = gen_of(g)
	}
	mut rules := []sim.ResponseRule{}
	for r in cfg.responses {
		rules << sim.ResponseRule{
			req_id:     r.request
			resp_id:    r.response
			byte_index: r.byte
			add:        r.add
		}
	}
	return sim.build_configured_ecu(db, cfg.name, gens, rules)
}

// sim_loop runs a channel's simulated ECUs on its bus: emit cyclic frames + answer
// request/response rules. Driver-free on inproc:, real on vcan0/can0.
fn sim_loop(app &App, sc SimCfg) {
	a := unsafe { app }
	mut bus := transport.open(sc.iface) or {
		eprintln('sim ${sc.iface}: ${err}')
		return
	}
	mut engine := sim.Engine{}
	mut local_gen := u64(0) // rebuild when a.sim_gen changes (ECU enable/disable)
	mut built := false
	t0 := time.ticks()
	for a.running {
		if !built || a.sim_gen != local_gen {
			built = true
			local_gen = a.sim_gen
			a.mu.lock()
			mut enabled := map[string]bool{}
			for k, v in a.sim_enabled {
				enabled[k] = v
			}
			a.mu.unlock()
			engine = sim.Engine{}
			for n in sc.nodes {
				if enabled['${sc.iface}:${n.name}'] or { true } {
					engine.ecus << build_node(sc.db, n)
				}
			}
		}
		now_ms := f64(time.ticks() - t0)
		for f in engine.due_frames(now_ms) {
			bus.send(f) or {}
		}
		if frame := bus.recv(5) {
			for resp in engine.on_frame(frame) {
				bus.send(resp) or {}
			}
		}
	}
	bus.close()
}

// gen_loop fires cyclic senders at their cycle_ms while the measurement runs.
fn gen_loop(app &App) {
	mut a := unsafe { app }
	mut last := map[int]i64{}
	for a.running {
		now := time.ticks()
		mut fire := []int{}
		a.mu.lock()
		for i, sr in a.senders {
			if sr.sender.trigger == 'cyclic' && sr.sender.cycle_ms > 0 {
				lf := last[i] or { i64(0) }
				if now - lf >= i64(sr.sender.cycle_ms) {
					last[i] = now
					fire << i
				}
			}
		}
		a.mu.unlock()
		for i in fire {
			a.fire_index(i)
		}
		time.sleep(8 * time.millisecond)
	}
}

// diag_server_loop runs the native UDS server (mirror of the tester: rx 0x7E0, tx 0x7E8)
// so the Diagnostics panel + Lua scripts work driver-free against simulated channels.
fn diag_server_loop(app &App, iface string) {
	a := unsafe { app }
	mut ch := isotp.open_software(iface, diag_rx_id, diag_tx_id, false) or { return }
	mut srv := uds.default_server()
	for a.running {
		req := ch.recv(50) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
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
		// track the real link state so a bound-but-DOWN iface shows "down" (red), not "run",
		// and flips to green the moment the user brings it up (ip link set … up).
		down := !iface_link_up(a.chans[ci].adapter, a.chans[ci].address)
		if down != a.chans[ci].link_down {
			a.mu.lock()
			a.chans[ci].link_down = down
			a.mu.unlock()
			vgui.wake()
		}
		f := bus.recv(200) or { continue }
		t_ms := f64(time.ticks() - a.t0)
		name := a.lookup_name(f.id, f.extended)
		a.mu.lock()
		if !a.paused {
			a.trace << TraceRow{t_ms, chname, 'RX', f.id, f.extended, f.rtr, name, f.data.clone()}
			if a.trace.len > trace_cap {
				a.trace = a.trace[a.trace.len - trace_cap..].clone()
			}
			a.gcount[gkey('RX', chname, f.id, f.extended)]++
			if a.has_manifest && !f.extended && !f.rtr && f.data.len == 8 && f.id == telem.id_record {
				a.trecs << TRec{ci, telem.decode_record(f.data)}
				if a.trecs.len > telem_cap {
					a.trecs = a.trecs[a.trecs.len - telem_cap..].clone()
				}
				a.rev++
			}
		}
		if a.recording {
			a.rec << canlog.LogEntry{t_ms / 1000.0, chname, f}
			if a.rec.len > 200000 {
				a.rec = a.rec[a.rec.len - 200000..].clone()
			}
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

// load_ui_font replaces imgui's blocky default (ProggyClean) with a real TTF: VGUI_FONT
// if set, else the first available system monospace (DejaVu Sans Mono / Consolas). Keeping
// it monospace keeps the hex/data columns aligned.
fn load_ui_font() {
	mut candidates := []string{}
	env := os.getenv('VGUI_FONT')
	if env != '' {
		candidates << env
	}
	candidates << [
		'/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
		'/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
		'/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf',
		'C:/Windows/Fonts/consola.ttf',
		'C:/Windows/Fonts/segoeui.ttf',
	]
	sz := os.getenv('VGUI_FONT_SIZE').int()
	size := if sz > 0 { f32(sz) } else { f32(16) }
	for f in candidates {
		if f != '' && os.exists(f) {
			if vgui.add_font(f, size) {
				return
			}
		}
	}
}

// load_project (re)loads a project into the app: stops any measurement, clears the
// project-derived state, and rebuilds channels / DBCs / sims / senders. Keeps the input
// buffers + panel layout. Used at startup and by File > Open Example / Reload.
// load_project loads a project file: stop, reset the session buffers, parse into
// app.proj, then derive the runtime view (rebuild_from_proj). On a parse error the current
// project is left untouched.
fn (mut app App) load_project(path string) {
	app.stop()
	proj := project.load(path) or {
		eprintln('load ${path}: ${err}')
		app.notify('load failed: ${err}')
		return
	}
	app.set_project(proj, path)
}

// set_project installs a parsed project (from a file, New, or a reload), resetting the
// session buffers and rebuilding the runtime view. path == '' marks an unsaved project.
fn (mut app App) set_project(proj project.Project, path string) {
	app.mu.lock()
	app.trace = []
	app.gcount = map[string]u64{}
	app.trecs = []
	app.diag_log = []
	app.script_log = []
	app.watch = []
	app.fwatch = []
	app.rx = 0
	app.proj_path = path
	app.proj_name = proj.name
	app.proj = proj
	app.dirty = false
	app.mu.unlock()
	app.rebuild_from_proj()
}

// rebuild_from_proj derives the runtime view (chans, dbs, sims, senders, manifest, default
// selection) from app.proj. Called after a load and after any config/generator edit, so the
// live panels reflect the edited model. Must be called while stopped (no RX threads running).
fn (mut app App) rebuild_from_proj() {
	proj := app.proj
	app.mu.lock()
	app.chans = []
	app.dbs = []
	app.sims = []
	app.senders = []
	app.gen_bufs = []
	app.has_manifest = false
	app.manifest = telem.Manifest{}
	app.sel_id = -1
	app.mu.unlock()
	for ch in proj.channels {
		app.chans << Chan{
			name:         ch.name
			network:      ch.network
			adapter:      ch.adapter
			address:      ch.address
			iface:        ch.iface
			mode:         ch.mode.str()
			typ:          ch.typ
			bitrate:      ch.bitrate
			data_bitrate: ch.data_bitrate
			listen_only:  ch.listen_only
			databases:    ch.databases.clone()
			manifest:     ch.manifest
			doip:         ch.is_doip()
			enabled:      ch.enabled
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
			}
		}
		for s in ch.senders {
			app.senders << SenderRT{
				iface:  ch.iface
				sender: s
			}
			app.gen_bufs << GenBuf{
				name_buf: mkbuf(s.name, 48)
				key_buf:  mkbuf(s.key, 2)
				id_buf:   mkbuf('${s.id:X}', 24)
				data_buf: mkbuf(hex(s.data), 96)
			}
		}
		nodes := ch.all_nodes()
		if ch.enabled && nodes.len > 0 {
			app.sims << SimCfg{
				iface: ch.iface
				db:    merge_dbs(ch.databases)
				nodes: nodes
			}
		}
	}
	for db in app.dbs {
		if db.messages.len > 0 {
			app.sel_id = int(db.messages[0].id)
			app.sel_ext = db.messages[0].ext
			break
		}
	}
}

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

fn main() {
	proj_path := os.getenv_opt('BLOBLY_PROJECT') or { 'projects/trace-demo.blobnet' }
	mut wake_ms := os.getenv('VGUI_WAKE_MS').i64()
	if wake_ms <= 0 {
		wake_ms = 33
	}
	max_frames := os.getenv('VGUI_FRAMES').int()
	shot := os.getenv('VGUI_SHOT')

	mut app := &App{
		t0:      time.ticks()
		wake_ms: wake_ms
	}
	app.send_id_buf = mkbuf('101', 24)
	app.send_data_buf = mkbuf('01', 64)
	app.diag_did_buf = mkbuf('F190', 16)
	app.script_path_buf = mkbuf('tests/diag_basic.lua', 256)
	app.trace_filter_buf = mkbuf('', 64)
	app.trace_filter2_buf = mkbuf('', 64)
	app.symbol_filter_buf = mkbuf('', 64)
	app.log_path_buf = mkbuf('samples/demo.log', 256)
	app.doip_host_buf = mkbuf('127.0.0.1', 64)
	app.load_project(proj_path)
	println('blobly_vgui: ${app.proj_name} — ${app.chans.len} channel(s), ${app.dbs.len} DBC(s), manifest=${app.has_manifest}. Press Start.')

	// Headless self-test of the Configuration editor: drive the real methods (New → add bus →
	// edit fields → add DBC → Save As) and assert the written .blobnet round-trips. Exits after.
	// The editor's widgets can't be clicked under WSLg, so this smoke covers the logic instead.
	if os.getenv('BLOBLY_SELFTEST_CONFIG') != '' {
		selftest_config(mut app)
		return
	}

	if !vgui.init('blobly_net — ${app.proj_name} (imgui/ImPlot)', 1500, 850, true) {
		eprintln('vgui.init failed')
		return
	}
	load_ui_font()
	if os.getenv('BLOBLY_THEME') == 'light' {
		app.dark = false
		vgui.set_theme(false)
	}
	// Dev hook: open the Configuration editor at startup (it can't be reached via synthetic
	// typing under WSLg, so this is how it gets screenshot-verified). Mirrors BLOBLY_AUTOSTART.
	if os.getenv('BLOBLY_SHOW_CONFIG') != '' {
		app.show_config = true
	}
	// Autostart defers the measurement start until the GL context has SETTLED. On Windows the
	// GPU driver maps/unmaps its own DLL data sections during the first presented frames; if a
	// worker thread triggers a Boehm GC collection inside that window, the collector faults
	// scanning a mid-remap driver data root (SIGSEGV in GC_mark_from, thirdparty/libgc). Starting
	// after ~`autostart_frame` presented frames clears the race. A human pressing Start is always
	// well past this, so it only matters for BLOBLY_AUTOSTART / automated runs. Override with
	// BLOBLY_AUTOSTART_FRAME.
	autostart_frame := if os.getenv('BLOBLY_AUTOSTART') != '' {
		n := os.getenv('BLOBLY_AUTOSTART_FRAME').int()
		if n > 0 { n } else { 30 }
	} else {
		0
	}
	// BLOBLY_FOCUS=PanelName brings that panel's tab to the front once at startup (test/dev aid).
	focus_panel := os.getenv('BLOBLY_FOCUS')

	mut frame := 0
	for vgui.running() {
		frame++
		// During the autostart settle window, wake the loop so those frames render back-to-back
		// (the event-driven wait would otherwise pace them ~0.5s apart before any RX thread exists).
		if autostart_frame > 0 && frame < autostart_frame {
			vgui.wake()
		}
		if autostart_frame > 0 && frame == autostart_frame {
			app.start()
		}
		last := max_frames > 0 && frame >= max_frames
		if last && shot != '' {
			vgui.dump_ppm(shot)
		}

		app.mu.lock()
		rx := app.rx
		rows := app.trace.clone()
		gcount := app.gcount.clone()
		trecs := app.trecs.clone()
		chans := app.chans.clone()
		app.mu.unlock()

		vgui.frame_begin()
		if focus_panel != '' && frame == 3 {
			vgui.set_window_focus(focus_panel)
		}
		draw_menubar(mut app, rx)
		// activity bar spans the full height on the far left (VS Code style); the toolbar
		// and dockspace live in a right-hand pane beside it (not above it).
		draw_activity_bar(mut app)
		vgui.same_line()
		vgui.child_fill('##right')
		draw_toolbar(mut app, rx)
		vgui.dockspace()
		vgui.child_end()
		build_layout()

		if app.show_buses {
			draw_buses(mut app, chans)
		}
		if app.show_sim {
			draw_sim(mut app)
		}
		if app.show_symbols {
			draw_symbols(mut app)
		}
		if app.show_busconfig {
			draw_busconfig(mut app, chans)
		}
		if app.show_stats {
			draw_stats(mut app, chans, rx)
		}
		if app.show_trace {
			draw_trace(mut app, rows, gcount, rx)
		}
		if app.show_ftrace {
			draw_ftrace(mut app, rows, gcount)
		}
		if app.show_log {
			draw_log(mut app)
		}
		if app.show_tchart {
			draw_tchart(mut app, trecs)
		}
		if app.show_signals {
			draw_signals(mut app, rows)
		}
		if app.show_graphics {
			draw_graphics(mut app, rows)
		}
		if app.show_send {
			draw_send(mut app)
		}
		if app.show_diag {
			draw_diag(mut app)
		}
		if app.show_doip {
			draw_doip(mut app)
		}
		if app.show_network {
			draw_network(mut app, chans)
		}
		if app.show_gen {
			draw_gen(mut app)
		}
		if app.show_script {
			draw_script(mut app)
		}
		if app.show_help {
			draw_help(mut app)
		}
		if app.show_config {
			draw_config(mut app)
		}
		if app.disc_open {
			draw_discover_dialog(mut app)
		}
		if app.fb_open {
			draw_filebrowser(mut app)
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

// draw_activity_bar is the VS Code-style vertical strip of panel toggles on the far left.
// Each button toggles a panel's visibility and is tinted when the panel is shown.
fn draw_activity_bar(mut app App) {
	// fixed dark strip (same in light + dark themes, like VS Code) with a tight inner
	// padding so the 3-char labels aren't clipped
	vgui.activity_style_push()
	vgui.push_window_padding(4 * app.ui_scale, 6 * app.ui_scale)
	vgui.child_wh('##activity', 60 * app.ui_scale, 0)
	vgui.push_frame_padding(4 * app.ui_scale, 6 * app.ui_scale)
	if vgui.toggle_button('Bus', app.show_buses, -1) {
		app.show_buses = !app.show_buses
	}
	if vgui.toggle_button('Sim', app.show_sim, -1) {
		app.show_sim = !app.show_sim
	}
	if vgui.toggle_button('Sym', app.show_symbols, -1) {
		app.show_symbols = !app.show_symbols
	}
	if vgui.toggle_button('Cfg', app.show_busconfig, -1) {
		app.show_busconfig = !app.show_busconfig
	}
	if vgui.toggle_button('Trc', app.show_trace, -1) {
		app.show_trace = !app.show_trace
	}
	if vgui.toggle_button('FTr', app.show_ftrace, -1) {
		app.show_ftrace = !app.show_ftrace
	}
	if vgui.toggle_button('Cht', app.show_tchart, -1) {
		app.show_tchart = !app.show_tchart
	}
	if vgui.toggle_button('Sig', app.show_signals, -1) {
		app.show_signals = !app.show_signals
	}
	if vgui.toggle_button('Gfx', app.show_graphics, -1) {
		app.show_graphics = !app.show_graphics
	}
	if vgui.toggle_button('Snd', app.show_send, -1) {
		app.show_send = !app.show_send
	}
	if vgui.toggle_button('Dia', app.show_diag, -1) {
		app.show_diag = !app.show_diag
	}
	if vgui.toggle_button('DoI', app.show_doip, -1) {
		app.show_doip = !app.show_doip
	}
	if vgui.toggle_button('Net', app.show_network, -1) {
		app.show_network = !app.show_network
	}
	if vgui.toggle_button('Gen', app.show_gen, -1) {
		app.show_gen = !app.show_gen
	}
	if vgui.toggle_button('Lua', app.show_script, -1) {
		app.show_script = !app.show_script
	}
	if vgui.toggle_button('Sta', app.show_stats, -1) {
		app.show_stats = !app.show_stats
	}
	if vgui.toggle_button('Log', app.show_log, -1) {
		app.show_log = !app.show_log
	}
	if vgui.toggle_button('Hlp', app.show_help, -1) {
		app.show_help = !app.show_help
	}
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
			app.show_busconfig = vgui.menu_item_check('Bus Config', app.show_busconfig)
			app.show_trace = vgui.menu_item_check('Trace', app.show_trace)
			app.show_ftrace = vgui.menu_item_check('Trace (filter)', app.show_ftrace)
			app.show_tchart = vgui.menu_item_check('Trace Chart', app.show_tchart)
			app.show_signals = vgui.menu_item_check('Signals', app.show_signals)
			app.show_graphics = vgui.menu_item_check('Graphics', app.show_graphics)
			app.show_send = vgui.menu_item_check('Send', app.show_send)
			app.show_diag = vgui.menu_item_check('Diagnostics', app.show_diag)
			app.show_doip = vgui.menu_item_check('DoIP Discovery', app.show_doip)
			app.show_network = vgui.menu_item_check('Network', app.show_network)
			app.show_gen = vgui.menu_item_check('Generators', app.show_gen)
			app.show_script = vgui.menu_item_check('Script', app.show_script)
			app.show_stats = vgui.menu_item_check('Statistics', app.show_stats)
			app.show_log = vgui.menu_item_check('Log', app.show_log)
			app.show_help = vgui.menu_item_check('Help', app.show_help)
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
			for s in [100, 125, 150, 175] {
				if vgui.menu_item('${s}%') {
					app.ui_scale = f32(s) / 100.0
					vgui.set_font_scale(app.ui_scale)
				}
			}
			vgui.menu_end()
		}
		vgui.menu_bar_end()
	}
}

// draw_toolbar is the button/status strip BELOW the menu bar (Start/Stop, live status,
// Pause/Clear/Record, theme).
fn draw_toolbar(mut app App, rx u64) {
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
	dirtymark := if app.dirty { ' ●' } else { '' }
	vgui.text('· RX ${rx}  TX ${app.tx_count}  ·  ${app.proj_name}${dirtymark}   ')
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

// channel state colour + short ASCII label (imgui's default font is ASCII-only):
// grey off (disabled) / red down (attached but the CAN iface is DOWN) / green run / amber idle.
fn chan_state(c Chan) (u8, u8, u8, string) {
	if !c.enabled {
		return u8(140), u8(140), u8(145), 'off '
	}
	if c.running {
		if c.link_down {
			return u8(215), u8(90), u8(90), 'down' // iface DOWN — bound but can't tx/rx
		}
		return u8(90), u8(200), u8(120), 'run '
	}
	return u8(220), u8(170), u8(70), 'idle'
}

// draw_sim lists the in-process simulation workload: each channel's simulated ECUs,
// expandable to their signal generators + request/response rules.
fn draw_sim(mut app App) {
	vis, op := vgui.begin_closable('Simulation', app.show_sim)
	app.show_sim = op
	if !vis {
		vgui.end()
		return
	}
	if app.sims.len == 0 {
		vgui.text_dim('no simulated ECUs in this project')
		vgui.end()
		return
	}
	vgui.text_dim('tick to enable/disable an ECU live')
	for sc in app.sims {
		vgui.separator_text(sc.iface)
		for node in sc.nodes {
			key := '${sc.iface}:${node.name}'
			en := app.sim_enabled[key] or { true }
			nen := vgui.checkbox('##simen_${key}', en)
			if nen != en {
				app.mu.lock()
				app.sim_enabled[key] = nen
				app.sim_gen++
				app.mu.unlock()
			}
			vgui.same_line()
			hdr := '${node.name}  (${node.signals.len} sig / ${node.responses.len} resp)###${key}'
			if vgui.tree_node(hdr) {
				for g in node.signals {
					vgui.text('    ${g.signal}: ${g.typ}')
				}
				for r in node.responses {
					vgui.text('    ${r.request} -> ${r.response}')
				}
				vgui.tree_pop()
			}
		}
	}
	vgui.end()
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

// rel_path makes an absolute path relative to the cwd when it lives under it, so a saved
// project references e.g. `dbc/foo.dbc` rather than an absolute machine-specific path.
fn rel_path(p string) string {
	cwd := os.getwd()
	if p.starts_with(cwd + '/') {
		return p[cwd.len + 1..]
	}
	return p
}

// open_browser opens the file browser for a target action:
//   'open'          — load a project (.blobnet)
//   'saveas'        — Save As (.blobnet, filename input)
//   'dbc:<ci>'      — attach a DBC to bus ci (.dbc)
//   'manifest:<ci>' — attach a telemetry manifest to bus ci (.csv)
fn (mut app App) open_browser(target string) {
	app.fb_target = target
	app.fb_save = target == 'saveas'
	app.fb_ext = if target == 'open' || target == 'saveas' {
		'.blobnet'
	} else if target.starts_with('dbc') {
		'.dbc'
	} else if target.starts_with('manifest') {
		'.csv'
	} else {
		''
	}
	mut dir := if app.proj_path != '' { os.dir(app.proj_path) } else { 'projects' }
	if !os.is_dir(dir) {
		dir = '.'
	}
	app.fb_dir = os.abs_path(dir)
	initname := if app.fb_save && app.proj_path != '' { os.file_name(app.proj_path) } else { '' }
	app.fb_name_buf = mkbuf(initname, 128)
	app.fb_open = true
}

// browser_confirm runs the pending target action with the chosen path, then closes.
fn (mut app App) browser_confirm(path string) {
	t := app.fb_target
	app.fb_open = false
	if t == 'open' {
		app.load_project(path)
	} else if t == 'saveas' {
		app.save_as(path)
	} else if t.starts_with('dbc:') {
		app.add_dbc(t['dbc:'.len..].int(), path)
	} else if t.starts_with('manifest:') {
		app.set_manifest(t['manifest:'.len..].int(), path)
	}
}

// draw_filebrowser is a small self-contained file picker (no native dialog — imgui has
// none, and WSL isn't the primary target). Lists the current directory, navigates on click,
// filters by extension, and (save mode) takes a filename.
fn draw_filebrowser(mut app App) {
	title := if app.fb_target == 'open' {
		'Open Project'
	} else if app.fb_target == 'saveas' {
		'Save Project As'
	} else if app.fb_target.starts_with('dbc') {
		'Attach DBC'
	} else {
		'Attach Manifest'
	}
	vgui.set_next_window(260, 140, 560, 520)
	if !vgui.begin('${title}##filebrowser') {
		vgui.end()
		return
	}
	vgui.text('dir: ${app.fb_dir}')
	if vgui.small_button('.. up') {
		app.fb_dir = os.dir(app.fb_dir)
	}
	vgui.same_line()
	if vgui.small_button('projects/') {
		p := os.abs_path('projects')
		if os.is_dir(p) {
			app.fb_dir = p
		}
	}
	filt := if app.fb_ext != '' { '(*${app.fb_ext})' } else { '' }
	vgui.same_line()
	vgui.text_dim(filt)
	vgui.separator()

	entries := os.ls(app.fb_dir) or { []string{} }
	mut dirs := []string{}
	mut files := []string{}
	for e in entries {
		full := os.join_path(app.fb_dir, e)
		if os.is_dir(full) {
			dirs << e
		} else if app.match_ext(e) {
			files << e
		}
	}
	dirs.sort()
	files.sort()
	mut nav := ''
	mut chosen := ''
	vgui.child_begin('fb_list', 300)
	for d in dirs {
		if vgui.selectable('[dir]  ${d}', false) {
			nav = os.join_path(app.fb_dir, d)
		}
	}
	for f in files {
		if vgui.selectable('      ${f}', false) {
			if app.fb_save {
				app.fb_name_buf = mkbuf(f, 128)
			} else {
				chosen = os.join_path(app.fb_dir, f)
			}
		}
	}
	vgui.child_end()
	vgui.separator()
	if app.fb_save {
		vgui.set_next_item_width(300)
		vgui.input_text('name', mut app.fb_name_buf)
		vgui.same_line()
		if vgui.button('Save') {
			name := vgui.buf_str(app.fb_name_buf)
			if name != '' {
				chosen = os.join_path(app.fb_dir, name)
			}
		}
		vgui.same_line()
	}
	if vgui.button('Cancel') {
		app.fb_open = false
	}
	vgui.end()
	// apply navigation / selection after end() so the imgui stack stays balanced
	if nav != '' {
		app.fb_dir = nav
	}
	if chosen != '' {
		app.browser_confirm(chosen)
	}
}

// match_ext reports whether a filename passes the browser's current extension filter.
// The project filter also accepts legacy `.yml`/`.yaml`; an empty filter accepts anything.
fn (app &App) match_ext(name string) bool {
	if app.fb_ext == '' {
		return true
	}
	n := name.to_lower()
	if n.ends_with(app.fb_ext) {
		return true
	}
	if app.fb_ext == '.blobnet' && (n.ends_with('.yml') || n.ends_with('.yaml')) {
		return true
	}
	return false
}

// available_adapters is the adapter-picker list for THIS platform — only backends that
// actually work here (SocketCAN/vcan are Linux; PCAN/Kvaser are Windows). `current` is always
// included so a project authored on another OS still shows (and can keep) its adapter.
fn available_adapters(current string) []string {
	mut list := $if windows {
		['virtual', 'udp', 'pcan', 'kvaser', 'doip']
	} $else {
		['virtual', 'vcan', 'socketcan', 'udp', 'doip']
	}
	if current !in list {
		list << current
	}
	return list
}

// adapter_tip is the tooltip text explaining an adapter (shown via the "(?)" help marker).
fn adapter_tip(a string) string {
	return match a {
		'virtual' { 'In-process software bus (driver-free). The address is a bus NAME you invent (CAN1, CAN2…); buses with the same name are the same wire. Runs anywhere, no drivers.' }
		'vcan' { 'Linux virtual CAN (SocketCAN). The address is a kernel interface like vcan0. Create them with scripts/setup_vcan.sh, then Discover to list them.' }
		'socketcan' { 'Real Linux CAN hardware (SocketCAN). The address is an interface like can0. Bring it up with: ip link set can0 up type can bitrate 500000.' }
		'udp' { 'Cross-platform UDP-multicast software bus. The address is group:port (e.g. 239.0.0.1:5000). Lets separate processes/hosts share a virtual wire.' }
		'pcan' { 'PEAK PCAN hardware (Windows). The address is a channel like PCAN_USBBUS1. Discovery needs the PEAK driver on Windows.' }
		'kvaser' { 'Kvaser hardware (Windows). The address is a channel index (0, 1…). Discovery needs the Kvaser driver on Windows.' }
		'doip' { 'Diagnostics over Ethernet (ISO 13400) — NOT a CAN bus. The address is host:port (default 127.0.0.1:13400); set the tester/ECU logical addresses below.' }
		else { '' }
	}
}

// CanIface is one CAN interface found on the machine (Linux /sys/class/net).
struct CanIface {
	name    string
	is_vcan bool
	desc    string // e.g. "PCAN-USB Pro FD [1-1] · down" (real) or "virtual CAN" (vcan)
}

// read_can_ifaces enumerates the machine's CAN interfaces with a human description: for
// real hardware, the USB product name + bus path + link state (so the two channels of a
// dual PCAN read as "can0 … PCAN-USB Pro FD [1-1]" / "can1 …"). Linux-only (/sys); [] else.
fn read_can_ifaces() []CanIface {
	mut out := []CanIface{}
	names := os.ls('/sys/class/net') or { return out }
	for name in names {
		typ := os.read_file('/sys/class/net/${name}/type') or { continue }
		if typ.trim_space() != '280' { // ARPHRD_CAN
			continue
		}
		is_vcan := name.starts_with('vcan')
		mut desc := 'virtual CAN'
		if !is_vcan {
			base := '/sys/class/net/${name}'
			product := (os.read_file('${base}/device/../product') or { '' }).trim_space()
			state := (os.read_file('${base}/operstate') or { '' }).trim_space()
			busnum := (os.read_file('${base}/device/../busnum') or { '' }).trim_space()
			devpath := (os.read_file('${base}/device/../devpath') or { '' }).trim_space()
			mut parts := [if product != '' { product } else { 'CAN' }]
			if busnum != '' && devpath != '' {
				parts << '[${busnum}-${devpath}]'
			}
			if state != '' {
				parts << '· ${state}'
			}
			desc = parts.join(' ')
		}
		out << CanIface{
			name:    name
			is_vcan: is_vcan
			desc:    desc
		}
	}
	out.sort(a.name < b.name)
	return out
}

// DiscoveredIface is one transport the Discover dialog offers to add as a bus.
struct DiscoveredIface {
	adapter string
	address string
	desc    string
	added   bool // already present in the project
}

// discover_all builds the Discover list: every CAN interface (real + vcan) plus the
// cross-platform software transports (a UDP bus and an in-process sim net), marking those
// already in the project.
fn (app &App) discover_all() []DiscoveredIface {
	mut out := []DiscoveredIface{}
	for ci in read_can_ifaces() {
		adapter := if ci.is_vcan { 'vcan' } else { 'socketcan' }
		out << DiscoveredIface{
			adapter: adapter
			address: ci.name
			desc:    ci.desc
			added:   app.iface_added(adapter, ci.name)
		}
	}
	udp := '${transport.udp_default_group}:${transport.udp_default_port}'
	out << DiscoveredIface{
		adapter: 'udp'
		address: udp
		desc:    'software bus'
		added:   app.iface_added('udp', udp)
	}
	out << DiscoveredIface{
		adapter: 'virtual'
		address: 'SIM'
		desc:    'in-process simulation'
		added:   app.iface_added('virtual', 'SIM')
	}
	return out
}

// iface_link_up reports whether a real CAN interface (socketcan/vcan) is administratively
// UP (IFF_UP in /sys/class/net/<if>/flags). Software backends (inproc/udp/doip) have no
// kernel interface and are always usable → true. An unreadable flags file → assume up
// (don't cry wolf on a platform without /sys).
fn iface_link_up(adapter string, address string) bool {
	if adapter != 'socketcan' && adapter != 'vcan' {
		return true
	}
	raw := os.read_file('/sys/class/net/${address}/flags') or { return true }
	mut t := raw.trim_space()
	if t.starts_with('0x') || t.starts_with('0X') {
		t = t[2..]
	}
	mut v := u64(0)
	for c in t {
		d := if c >= `0` && c <= `9` {
			u64(c - `0`)
		} else if c >= `a` && c <= `f` {
			u64(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			u64(c - `A`) + 10
		} else {
			continue
		}
		v = v * 16 + d
	}
	return (v & 0x1) != 0 // IFF_UP
}

// iface_added reports whether the project already has a bus on this adapter+address.
fn (app &App) iface_added(adapter string, address string) bool {
	target := project.compose_iface(adapter, address)
	for c in app.proj.channels {
		if c.iface == target {
			return true
		}
	}
	return false
}

// adapter_hint is the grey placeholder shown next to a bus's address field.
fn adapter_hint(a string) string {
	return match a {
		'virtual' { 'CAN1 — in-process bus name (driver-free sim)' }
		'vcan' { 'vcan0 — Linux virtual CAN' }
		'socketcan' { 'can0 — real Linux CAN hardware' }
		'udp' { '239.0.0.1:5000 — group:port software bus' }
		'pcan' { 'PCAN_USBBUS1 — PEAK channel' }
		'kvaser' { '0 — Kvaser channel index' }
		'doip' { '127.0.0.1:13400 — host:port' }
		else { '' }
	}
}

// parse_u16_hex reads a 16-bit address ("0x"-hex or bare hex), returning deflt when empty.
fn parse_u16_hex(s string, deflt u16) u16 {
	mut t := s.trim_space().trim('"')
	if t == '' {
		return deflt
	}
	if t.starts_with('0x') || t.starts_with('0X') {
		t = t[2..]
	}
	mut v := u32(0)
	for c in t {
		d := if c >= `0` && c <= `9` {
			u32(c - `0`)
		} else if c >= `a` && c <= `f` {
			u32(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			u32(c - `A`) + 10
		} else {
			continue
		}
		v = v * 16 + d
	}
	return u16(v & 0xFFFF)
}

// sync_cfg_bufs rebuilds the per-bus edit buffers to parallel app.proj.channels (on open,
// and after add/remove bus/DBC).
fn (mut app App) sync_cfg_bufs() {
	app.cfg_bufs = []
	for ch in app.proj.channels {
		mut rsrc := ''
		mut rspeed := '1'
		if r := ch.replay {
			rsrc = r.source
			rspeed = '${r.speed}'
		}
		app.cfg_bufs << CfgBuf{
			name_buf:         mkbuf(ch.name, 48)
			network_buf:      mkbuf(ch.network, 48)
			address_buf:      mkbuf(ch.address, 64)
			bitrate_buf:      mkbuf('${ch.bitrate}', 12)
			manifest_buf:     mkbuf(ch.manifest, 128)
			dbc_buf:          mkbuf('', 128)
			tester_buf:       mkbuf('0x${ch.tester_addr:X}', 12)
			ecu_buf:          mkbuf('0x${ch.ecu_addr:X}', 12)
			vin_buf:          mkbuf(ch.vin, 20)
			replay_src_buf:   mkbuf(rsrc, 128)
			replay_speed_buf: mkbuf(rspeed, 12)
		}
	}
}

// commit_cfg flushes all bus edit buffers into app.proj (called before Save and before any
// structural change so edits aren't lost). No-op if the buffers are out of sync.
fn (mut app App) commit_cfg() {
	if app.cfg_bufs.len != app.proj.channels.len {
		return
	}
	for i in 0 .. app.proj.channels.len {
		b := app.cfg_bufs[i]
		mut ch := &app.proj.channels[i]
		ch.name = vgui.buf_str(b.name_buf)
		ch.network = vgui.buf_str(b.network_buf)
		ch.address = vgui.buf_str(b.address_buf)
		ch.iface = project.compose_iface(ch.adapter, ch.address)
		ch.manifest = vgui.buf_str(b.manifest_buf)
		br := vgui.buf_str(b.bitrate_buf).int()
		if br > 0 {
			ch.bitrate = br
		}
		if ch.adapter == 'doip' {
			ch.tester_addr = parse_u16_hex(vgui.buf_str(b.tester_buf), ch.tester_addr)
			ch.ecu_addr = parse_u16_hex(vgui.buf_str(b.ecu_buf), ch.ecu_addr)
			vin := vgui.buf_str(b.vin_buf)
			if vin == '' || vin.len == 17 {
				ch.vin = vin
			}
		}
		if ch.mode == .replay {
			spd := vgui.buf_str(b.replay_speed_buf).f64()
			repeat := if r := ch.replay { r.repeat } else { false }
			ch.replay = project.Replay{
				source: vgui.buf_str(b.replay_src_buf)
				speed:  if spd > 0 { spd } else { 1.0 }
				repeat: repeat
			}
		}
	}
}

// add_bus appends a default driver-free virtual bus (the from-scratch building block).
fn (mut app App) add_bus() {
	n := app.proj.channels.len + 1
	app.add_bus_spec('virtual', 'CAN${n}')
}

// add_bus_spec appends a bus for a specific adapter+address (used by + Add bus, the Discover
// dialog's Add-ticked, and the quick-add buttons). The name defaults to the address.
fn (mut app App) add_bus_spec(adapter string, address string) {
	app.commit_cfg()
	base := if address != '' { address } else { adapter }
	app.proj.channels << project.Channel{
		name:    app.unique_bus_name(base)
		adapter: adapter
		address: address
		iface:   project.compose_iface(adapter, address)
		typ:     'can'
		mode:    .monitor
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_from_proj()
}

// unique_bus_name returns `base`, or base_2/base_3/… if the name is already taken.
fn (app &App) unique_bus_name(base string) string {
	mut name := base
	mut n := 2
	for {
		mut taken := false
		for c in app.proj.channels {
			if c.name == name {
				taken = true
				break
			}
		}
		if !taken {
			return name
		}
		name = '${base}_${n}'
		n++
	}
	return base
}

// refresh_discovery re-scans the machine's transports for the Discover dialog.
fn (mut app App) refresh_discovery() {
	app.disc_list = app.discover_all()
	app.disc_tick = []bool{len: app.disc_list.len}
}

// next_free_vcan returns the first vcanN not already in the project (for the + vcan quick-add).
fn (app &App) next_free_vcan() string {
	for n in 0 .. 32 {
		addr := 'vcan${n}'
		if !app.iface_added('vcan', addr) {
			return addr
		}
	}
	return 'vcan0'
}

// draw_discover_dialog is the "Discover interfaces" dialog (mirrors the old app): it lists
// every detected transport — real CAN hardware (with product/state), vcan, a UDP bus, an
// in-process sim net — with tick boxes and + Add ticked, plus + vcan / + Sim net quick-adds.
fn draw_discover_dialog(mut app App) {
	vgui.set_next_window(200, 130, 640, 460)
	vis, op := vgui.begin_closable('Discover interfaces', app.disc_open)
	app.disc_open = op
	if !vis {
		vgui.end()
		return
	}
	if vgui.button('Refresh') {
		app.refresh_discovery()
	}
	vgui.same_line()
	if vgui.button('+ vcan') {
		app.add_bus_spec('vcan', app.next_free_vcan())
		app.refresh_discovery()
	}
	vgui.same_line()
	if vgui.button('+ Sim net') {
		app.add_bus_spec('virtual', app.unique_bus_name('SIM'))
		app.refresh_discovery()
	}
	vgui.same_line()
	if vgui.button('+ Add ticked') {
		for k, d in app.disc_list {
			if k < app.disc_tick.len && app.disc_tick[k] && !d.added {
				app.add_bus_spec(d.adapter, d.address)
			}
		}
		app.refresh_discovery()
	}
	vgui.separator()
	if app.disc_list.len == 0 {
		vgui.text_dim('click Refresh to scan for interfaces')
	}
	for k, d in app.disc_list {
		if d.added {
			vgui.text_dim('   [added]   ${d.address}   ${d.adapter} · ${d.desc}')
			continue
		}
		t := if k < app.disc_tick.len { app.disc_tick[k] } else { false }
		nt := vgui.checkbox('##dt${k}', t)
		if nt != t && k < app.disc_tick.len {
			app.disc_tick[k] = nt
		}
		vgui.same_line()
		vgui.text('${d.address}   ${d.adapter} · ${d.desc}')
	}
	vgui.separator()
	vgui.text_dim('Tip: a PCAN/Kvaser device on Linux/WSL appears here as SocketCAN (canN) — add those, not the pcan/kvaser adapter (Windows-only).')
	vgui.end()
}

fn (mut app App) remove_bus(i int) {
	if i < 0 || i >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	app.proj.channels.delete(i)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_from_proj()
}

// set_adapter changes a bus's transport backend, recomposing its iface and keeping the
// can/doip protocol coherent.
fn (mut app App) set_adapter(i int, a string) {
	if i < 0 || i >= app.proj.channels.len {
		return
	}
	app.proj.channels[i].adapter = a
	if a == 'doip' {
		app.proj.channels[i].typ = 'doip'
	} else if app.proj.channels[i].typ == 'doip' {
		app.proj.channels[i].typ = 'can'
	}
	app.proj.channels[i].iface = project.compose_iface(a, vgui.buf_str(app.cfg_bufs[i].address_buf))
	app.dirty = true
	app.rebuild_from_proj()
}

fn (mut app App) set_protocol(i int, pr string) {
	app.proj.channels[i].typ = pr
	app.proj.channels[i].fd = pr == 'canfd'
	app.dirty = true
}

fn (mut app App) set_mode(i int, md string) {
	app.proj.channels[i].mode = project.mode_from(md)
	app.dirty = true
	app.rebuild_from_proj()
}

fn (mut app App) add_dbc(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	app.proj.channels[ci].databases << rel_path(path)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_from_proj()
}

fn (mut app App) remove_dbc(ci int, di int) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	if di < 0 || di >= app.proj.channels[ci].databases.len {
		return
	}
	app.commit_cfg()
	app.proj.channels[ci].databases.delete(di)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_from_proj()
}

fn (mut app App) set_manifest(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	app.proj.channels[ci].manifest = rel_path(path)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_from_proj()
}

// draw_config is the dedicated Configuration editor (File → Configure…): add/edit/remove
// buses, pick adapters, attach DBCs. Stopped-only; Save persists to the .blobnet.
fn draw_config(mut app App) {
	vgui.set_next_window(120, 90, 720, 620)
	vis, op := vgui.begin_closable('Configuration', app.show_config)
	app.show_config = op
	if !vis {
		vgui.end()
		return
	}
	if app.running {
		vgui.text_dim('Measurement running — Stop to edit the configuration.')
		if vgui.button('Close') {
			app.show_config = false
		}
		vgui.end()
		return
	}
	if app.cfg_bufs.len != app.proj.channels.len {
		app.sync_cfg_bufs()
	}
	if vgui.button('+ Add bus') {
		app.add_bus()
	}
	vgui.same_line()
	if vgui.button('Discover...') {
		app.refresh_discovery()
		app.disc_open = true
	}
	vgui.same_line()
	if vgui.button('Save') {
		app.save_project()
	}
	vgui.same_line()
	if vgui.button('Close') {
		app.show_config = false
	}
	if app.dirty {
		vgui.same_line()
		vgui.text_colored(230, 170, 70, '● modified')
	}
	vgui.separator()
	if app.proj.channels.len == 0 {
		vgui.text_dim('no buses — click "+ Add bus" to start a configuration')
		vgui.end()
		return
	}
	for i in 0 .. app.proj.channels.len {
		if app.draw_bus_editor(i) {
			break // a bus was removed — indices shifted, redraw next frame
		}
	}
	vgui.end()
}

// draw_bus_editor renders one bus as a tree node: an enable checkbox + a header summary on
// the collapsed row, expanding to the editable fields. Returns true if the bus was removed
// (indices shifted — the caller stops iterating this frame). Enum/checkbox edits apply to
// app.proj live; text fields are flushed by commit_cfg on Save / structural change.
fn (mut app App) draw_bus_editor(i int) bool {
	ch := app.proj.channels[i]
	// header row: enable checkbox + the tree node (name · adapter:address · network)
	en := vgui.checkbox('##cfgen${i}', ch.enabled)
	if en != ch.enabled {
		app.proj.channels[i].enabled = en
		app.dirty = true
	}
	vgui.same_line()
	vgui.set_item_tooltip('enable this bus (attached on Start)')
	nm := vgui.buf_str(app.cfg_bufs[i].name_buf)
	addr := if ch.address != '' { ':${ch.address}' } else { '' }
	net := if ch.network != '' { '  ·  ${ch.network}' } else { '' }
	dis := if ch.enabled { '' } else { '   — disabled' } // visible feedback for the enable checkbox
	// header: collapsible tree node + a remove button that works whether expanded or not.
	// Use ### so the imgui ID is fixed to `bus<i>` — the visible label (adapter/address/name)
	// changes as you edit, and with plain ## that would re-key the node and collapse it.
	open := vgui.tree_node('${nm}   [${ch.adapter}${addr}]${net}${dis}###bus${i}')
	vgui.same_line()
	if vgui.small_button('remove##crm${i}') {
		if open {
			vgui.tree_pop()
		}
		app.remove_bus(i)
		return true
	}
	if !open {
		return false
	}
	// name · network
	vgui.set_next_item_width(160)
	if vgui.input_text('name##cn${i}', mut app.cfg_bufs[i].name_buf) {
		app.dirty = true
	}
	vgui.same_line()
	vgui.set_next_item_width(140)
	if vgui.input_text('network##cnw${i}', mut app.cfg_bufs[i].network_buf) {
		app.dirty = true
	}
	vgui.same_line()
	vgui.help_marker('Optional label grouping buses of one logical vehicle network. Buses that share a network name are grouped in the Buses tree and the Trace bus chips.')
	// adapter picker + tooltip (only backends usable on this platform)
	vgui.text('adapter:')
	vgui.same_line()
	vgui.help_marker(adapter_tip(ch.adapter))
	for a in available_adapters(ch.adapter) {
		vgui.same_line()
		if vgui.toggle_button('${a}##ad${i}_${a}', ch.adapter == a, 0) {
			app.set_adapter(i, a)
		}
	}
	// address (type it, or add detected interfaces via the Discover... dialog above)
	vgui.set_next_item_width(220)
	if vgui.input_text('address##cad${i}', mut app.cfg_bufs[i].address_buf) {
		app.proj.channels[i].address = vgui.buf_str(app.cfg_bufs[i].address_buf)
		app.proj.channels[i].iface = project.compose_iface(ch.adapter, app.proj.channels[i].address)
		app.dirty = true
	}
	vgui.same_line()
	vgui.text_dim(adapter_hint(ch.adapter))

	if ch.adapter == 'doip' {
		vgui.set_next_item_width(90)
		if vgui.input_text('tester##ct${i}', mut app.cfg_bufs[i].tester_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.set_next_item_width(90)
		if vgui.input_text('ecu##ce${i}', mut app.cfg_bufs[i].ecu_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('DoIP logical addresses (ISO 13400): the tester (source) and ECU (target), e.g. 0x0E80 / 0x1000. They replace the CAN diagnostic id pair.')
		vgui.set_next_item_width(180)
		if vgui.input_text('vin##cv${i}', mut app.cfg_bufs[i].vin_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('17-character VIN reported by this entity in vehicle announcements (only used when this DoIP bus hosts a simulated entity).')
	} else {
		vgui.text('protocol:')
		for pr in ['can', 'canfd'] {
			vgui.same_line()
			if vgui.toggle_button('${pr}##pr${i}_${pr}', ch.typ == pr, 0) {
				app.set_protocol(i, pr)
			}
		}
		vgui.same_line()
		vgui.set_next_item_width(90)
		if vgui.input_text('bitrate##cb${i}', mut app.cfg_bufs[i].bitrate_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('Nominal bit rate in bit/s (e.g. 500000). For virtual/vcan buses this is informational; for real hardware it configures the interface.')
		vgui.text('mode:')
		vgui.same_line()
		vgui.help_marker('off = configured but not attached · monitor = observe live traffic · replay = play a recording onto the bus.')
		for md in ['off', 'monitor', 'replay'] {
			vgui.same_line()
			if vgui.toggle_button('${md}##md${i}_${md}', ch.mode.str() == md, 0) {
				app.set_mode(i, md)
			}
		}
		vgui.same_line()
		lo := vgui.checkbox('listen-only##lo${i}', ch.listen_only)
		if lo != ch.listen_only {
			app.proj.channels[i].listen_only = lo
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('Listen-only: never transmit (no ACKs) — passive monitoring of a live bus.')
		if ch.mode == .replay {
			vgui.text('replay:')
			vgui.same_line()
			vgui.set_next_item_width(220)
			if vgui.input_text('source##rs${i}', mut app.cfg_bufs[i].replay_src_buf) {
				app.dirty = true
			}
			vgui.same_line()
			vgui.set_next_item_width(56)
			if vgui.input_text('x speed##rsp${i}', mut app.cfg_bufs[i].replay_speed_buf) {
				app.dirty = true
			}
			vgui.same_line()
			loopv := if r := ch.replay { r.repeat } else { false }
			nl := vgui.checkbox('loop##rl${i}', loopv)
			if nl != loopv {
				src := vgui.buf_str(app.cfg_bufs[i].replay_src_buf)
				spd := vgui.buf_str(app.cfg_bufs[i].replay_speed_buf).f64()
				app.proj.channels[i].replay = project.Replay{
					source: src
					speed:  if spd > 0 { spd } else { 1.0 }
					repeat: nl
				}
				app.dirty = true
			}
		}
	}
	// databases
	vgui.text('databases:')
	vgui.same_line()
	vgui.help_marker('DBC files describing this bus/network — used to decode frames into signals and to drive the simulated ECUs.')
	for di, dbp in ch.databases {
		vgui.text('   ${dbp}')
		vgui.same_line()
		if vgui.small_button('x##dbrm${i}_${di}') {
			app.remove_dbc(i, di)
			vgui.tree_pop()
			return true
		}
	}
	if vgui.small_button('+ Add DBC##adddbc${i}') {
		app.open_browser('dbc:${i}')
	}
	// manifest
	vgui.set_next_item_width(220)
	if vgui.input_text('manifest##cmf${i}', mut app.cfg_bufs[i].manifest_buf) {
		app.proj.channels[i].manifest = vgui.buf_str(app.cfg_bufs[i].manifest_buf)
		app.dirty = true
	}
	vgui.same_line()
	if vgui.small_button('...##mfbrowse${i}') {
		app.open_browser('manifest:${i}')
	}
	vgui.same_line()
	vgui.help_marker('Optional telemetry handler manifest (CSV) — resolves handler ids to FB/handler/core for the Trace Chart.')
	vgui.tree_pop()
	return false
}

// draw_busconfig shows each channel's configuration (type, bitrate/timing, DBCs, manifest).
fn draw_busconfig(mut app App, chans []Chan) {
	vis, op := vgui.begin_closable('Bus Config', app.show_busconfig)
	app.show_busconfig = op
	if !vis {
		vgui.end()
		return
	}
	for c in chans {
		vgui.separator_text('${c.name}  (${c.iface})')
		vgui.text('type: ${c.typ}    mode: ${c.mode}    enabled: ${c.enabled}')
		if c.doip {
			vgui.text('DoIP endpoint (Ethernet diagnostics)')
		} else {
			du := if c.data_bitrate > 0 { '  data ${c.data_bitrate}' } else { '' }
			vgui.text('bitrate: ${c.bitrate}${du}    listen-only: ${c.listen_only}')
		}
		if c.databases.len > 0 {
			vgui.text('dbc: ${c.databases.join(', ')}')
		}
		if c.manifest != '' {
			vgui.text('manifest: ${c.manifest}')
		}
	}
	vgui.end()
}

// draw_doip: discover DoIP entities on a host (or a running DoIP channel).
fn draw_doip(mut app App) {
	vis, op := vgui.begin_closable('DoIP Discovery', app.show_doip)
	app.show_doip = op
	if !vis {
		vgui.end()
		return
	}
	vgui.set_next_item_width(160)
	vgui.input_text('host', mut app.doip_host_buf)
	vgui.same_line()
	if vgui.button('Discover') {
		app.mu.lock()
		app.doip_ents = []
		app.mu.unlock()
		spawn doip_worker(app, vgui.buf_str(app.doip_host_buf))
	}
	app.mu.lock()
	ents := app.doip_ents.clone()
	app.mu.unlock()
	vgui.separator_text('entities')
	if ents.len == 0 {
		vgui.text_dim('none — Discover a DoIP host (default 127.0.0.1:13400)')
	}
	for e in ents {
		vgui.text('VIN ${e.vin}   logical 0x${e.logical_address:04X}')
	}
	vgui.end()
}

// draw_stats: totals + per-channel RX counters.
fn draw_stats(mut app App, chans []Chan, rx u64) {
	vis, op := vgui.begin_closable('Statistics', app.show_stats)
	app.show_stats = op
	if !vis {
		vgui.end()
		return
	}
	vgui.text('RX ${rx}    TX ${app.tx_count}    ${vgui.fps():.0} fps    trace ${app.trace.len}')
	vgui.separator_text('per channel')
	if vgui.table_begin('stats', 4) {
		vgui.table_setup_col('channel', 90)
		vgui.table_setup_col('iface', 120)
		vgui.table_setup_col('state', 56)
		vgui.table_setup_col('RX', 0)
		vgui.table_freeze_top()
		vgui.table_headers()
		for c in chans {
			state := if c.running { 'run' } else if c.enabled { 'idle' } else { 'off' }
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

// draw_help: a short in-app usage reference.
fn draw_help(mut app App) {
	vis, op := vgui.begin_closable('Help', app.show_help)
	app.show_help = op
	if !vis {
		vgui.end()
		return
	}
	vgui.separator_text('blobly_vgui — imgui/ImPlot frontend')
	vgui.text('Start/Stop runs the measurement on the enabled channels.')
	vgui.text('The activity bar (far left) and the View menu toggle panels.')
	vgui.text('File > Open Example switches projects; Settings sets fps + UI scale.')
	vgui.separator_text('panels')
	vgui.text('Buses / Bus Config   channel enable, state, and configuration')
	vgui.text('Simulation           in-process simulated ECUs (driver-free)')
	vgui.text('Symbols              DBC message / signal browser (searchable)')
	vgui.text('Trace / Trace(filter) live frames — all or grouped, filterable')
	vgui.text('Signals              decode selected message; tick to plot')
	vgui.text('Graphics             ImPlot live signal plots')
	vgui.text('Trace Chart          telemetry handler swimlane')
	vgui.text('Send / Generators    transmit raw frames / fire project senders')
	vgui.text('Diagnostics / DoIP   UDS + DoIP discovery')
	vgui.text('Script               run a Lua test file')
	vgui.separator_text('toolbar')
	vgui.text('Pause freezes the trace · Clear empties it · Record writes recording.log')
	vgui.text('Open loads a candump .log or ASAM .mf4 into the trace.')
	vgui.end()
}

fn draw_buses(mut app App, chans []Chan) {
	vis, op := vgui.begin_closable('Buses', app.show_buses)
	app.show_buses = op
	if !vis {
		vgui.end()
		return
	}
	vgui.text('${app.proj_name} · ${chans.len} channel(s)')
	// The Buses panel is the runtime VIEW (enable/state); add/remove/edit a bus lives in the
	// Configuration editor (stopped-only).
	if app.running {
		vgui.text_dim('Stop to configure buses')
	} else if vgui.button('Configure...') {
		app.show_config = true
		app.sync_cfg_bufs()
	}
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

// draw_network shows the bus topology: each channel (bus) and everything attached to it —
// the tester's own functions (Monitor / Send / Diagnostics), simulated ECUs, and generators
// grouped by the bus they actually transmit on. The CANoe "Simulation Setup" analog.
fn draw_network(mut app App, chans []Chan) {
	vis, op := vgui.begin_closable('Network', app.show_network)
	app.show_network = op
	if !vis {
		vgui.end()
		return
	}
	vgui.text_dim('each bus and what is attached to it')
	if chans.len == 0 {
		vgui.text_dim('no channels in this project')
		vgui.end()
		return
	}
	for ci, c in chans {
		r, g, b, st := chan_state(c)
		vgui.text_colored(r, g, b, '*')
		vgui.same_line()
		if vgui.tree_node_open('${c.name}   ${c.iface}   [${c.mode}]   ${st.trim_space()}   RX ${c.rx}###net${ci}') {
			mut any := false
			// tester functions this tool runs on the bus
			mut tf := []string{}
			if c.monitorable() {
				tf << 'Monitor'
			}
			if app.send_iface == c.iface {
				tf << 'Send'
			}
			for sc in app.sims {
				if sc.iface == c.iface {
					tf << 'Diagnostics (UDS 0x7E0->0x7E8)'
					break
				}
			}
			if tf.len > 0 {
				vgui.text('    Tester:  ${tf.join('  ·  ')}')
				any = true
			}
			// simulated ECUs on this bus
			for sc in app.sims {
				if sc.iface != c.iface {
					continue
				}
				for n in sc.nodes {
					vgui.text('    ECU:     ${n.name}')
					any = true
				}
			}
			// generators that transmit on this bus (after Part-1 routing they group correctly)
			for sr in app.senders {
				if sr.target() != c.iface {
					continue
				}
				s := sr.sender
				desc := if s.message != '' { s.message } else { 'id 0x${s.id:X}' }
				trig := match s.trigger {
					'cyclic' { 'cyclic ${s.cycle_ms}ms' }
					'key' { 'key ${s.key}' }
					else { 'manual' }
				}
				vgui.text('    Gen:     ${s.name}  (${desc}, ${trig})')
				any = true
			}
			if c.mode == 'replay' {
				vgui.text('    Replay:  playing recording')
				any = true
			}
			if !any {
				vgui.text_dim('    (nothing attached)')
			}
			vgui.tree_pop()
		}
	}
	vgui.end()
}

fn draw_trace(mut app App, rows []TraceRow, gcount map[string]u64, rx u64) {
	vis, op := vgui.begin_closable('Trace', app.show_trace)
	app.show_trace = op
	if !vis {
		vgui.end()
		return
	}
	if vgui.small_button(if app.trace_grouped { 'View: grouped' } else { 'View: all' }) {
		app.trace_grouped = !app.trace_grouped
	}
	vgui.same_line()
	vgui.text('RX ${rx} · ${vgui.fps():.0}fps')
	vgui.same_line()
	vgui.set_next_item_width(200)
	vgui.input_text('filter', mut app.trace_filter_buf)
	vgui.same_line()
	if vgui.small_button('Clear') {
		app.clear_trace()
	}
	vgui.set_next_item_width(200)
	vgui.input_text('.log/.mf4', mut app.log_path_buf)
	vgui.same_line()
	if vgui.small_button('Open') {
		app.load_recording(vgui.buf_str(app.log_path_buf))
	}
	// add the selected frame (click a row) to the Trace (filter) watch list
	if app.sel_id >= 0 {
		vgui.same_line()
		sid := u32(app.sel_id)
		sext := app.sel_ext
		if vgui.small_button('+ Add ${idstr(sid, sext)} to filter') {
			app.add_fwatch(sid, sext)
		}
	}
	if app.chans.len > 1 {
		app.trace_bus = bus_chips(app.chans, app.trace_bus, 't')
	}
	brows := filter_bus(rows, app.trace_bus)
	filt := vgui.buf_str(app.trace_filter_buf).to_lower()
	if app.trace_grouped {
		vgui.separator_text('by id (click to expand · click row to select)')
		draw_trace_grouped(mut app, brows, gcount, filt)
	} else {
		vgui.separator_text('frames (newest first)')
		draw_trace_all('trace', brows, filt)
	}
	vgui.end()
}

// draw_ftrace is the "Trace (filter)" watch list: it shows ONLY the frames you've added
// (via "+ Add to filter" in the Trace panel, or "+" in Symbols), over the same buffer.
fn draw_ftrace(mut app App, rows []TraceRow, gcount map[string]u64) {
	vis, op := vgui.begin_closable('Trace (filter)', app.show_ftrace)
	app.show_ftrace = op
	if !vis {
		vgui.end()
		return
	}
	if vgui.small_button(if app.trace_grouped2 { 'View: grouped' } else { 'View: all' }) {
		app.trace_grouped2 = !app.trace_grouped2
	}
	vgui.same_line()
	vgui.set_next_item_width(180)
	vgui.input_text('find', mut app.trace_filter2_buf)
	vgui.same_line()
	if vgui.small_button('Clear watch') {
		app.fwatch = []
	}
	// watched-frame chips (click one to remove it from the list)
	if app.fwatch.len == 0 {
		vgui.text_dim('empty — select a frame in Trace and click "+ Add to filter", or "+" in Symbols')
	} else {
		vgui.text('watching:')
		for f in app.fwatch {
			nm := app.lookup_name(f.id, f.ext)
			vgui.same_line()
			if vgui.small_button('${idstr(f.id, f.ext)} ${nm} x##fw${f.id}_${f.ext}') {
				app.remove_fwatch(f.id, f.ext)
			}
		}
	}
	if app.chans.len > 1 {
		app.ftrace_bus = bus_chips(app.chans, app.ftrace_bus, 'f')
	}
	vgui.separator()
	if app.fwatch.len == 0 {
		vgui.end()
		return
	}
	// restrict to watched frames + optional bus, then apply the optional text find
	frows := filter_bus(rows.filter(app.is_fwatched(it.id, it.ext)), app.ftrace_bus)
	filt := vgui.buf_str(app.trace_filter2_buf).to_lower()
	if app.trace_grouped2 {
		draw_trace_grouped(mut app, frows, gcount, filt)
	} else {
		draw_trace_all('ftrace', frows, filt)
	}
	vgui.end()
}

// bus_chips renders "show: [All] [bus…]" toggle-chips from the configured buses (labelled
// network/name when a network label is set) and returns the selected bus name ('' = all).
// `key` disambiguates the two Trace panels' widget ids.
fn bus_chips(chans []Chan, cur string, key string) string {
	mut sel := cur
	vgui.text('show:')
	vgui.same_line()
	if vgui.toggle_button('All##bc${key}', cur == '', 0) {
		sel = ''
	}
	for c in chans {
		label := if c.network != '' { '${c.network}/${c.name}' } else { c.name }
		vgui.same_line()
		if vgui.toggle_button('${label}##bc${key}_${c.name}', cur == c.name, 0) {
			sel = if cur == c.name { '' } else { c.name }
		}
	}
	return sel
}

// filter_bus keeps only rows whose channel (name) matches `bus`; '' = all.
fn filter_bus(rows []TraceRow, bus string) []TraceRow {
	if bus == '' {
		return rows
	}
	return rows.filter(it.ch == bus)
}

fn idstr(id u32, ext bool) string {
	return if ext { '0x${id:08X}' } else { '0x${id:03X}' }
}

// trace_pass: case-insensitive substring match over id / name / ch / dir / data.
fn trace_pass(r TraceRow, filt string) bool {
	if filt == '' {
		return true
	}
	hay := '${idstr(r.id, r.ext)} ${r.name} ${r.ch} ${r.dir} ${hex(r.data)}'.to_lower()
	return hay.contains(filt)
}

fn draw_trace_all(id string, rows []TraceRow, filt string) {
	if vgui.table_begin(id, 6) {
		vgui.table_setup_col('t (ms)', 66)
		vgui.table_setup_col('ch', 52)
		vgui.table_setup_col('dir', 34)
		vgui.table_setup_col('id', 82)
		vgui.table_setup_col('name', 150)
		vgui.table_setup_col('data', 0) // stretch
		vgui.table_freeze_top()
		vgui.table_headers()
		mut i := rows.len - 1
		mut shown := 0
		for i >= 0 && shown < 300 {
			r := rows[i]
			i--
			if !trace_pass(r, filt) {
				continue
			}
			shown++
			vgui.table_row()
			vgui.table_cell('${r.t_ms:.1}')
			vgui.table_cell(r.ch)
			vgui.table_cell(r.dir)
			vgui.table_cell(idstr(r.id, r.ext))
			vgui.table_cell(r.name)
			vgui.table_cell(if r.rtr { 'RTR' } else { hex(r.data) })
		}
		vgui.table_end()
	}
}

struct GAgg {
mut:
	dir   string
	ch    string
	id    u32
	ext   bool
	count int
	last  TraceRow
}

// gkey is the stable per-group identity used for both the grouped-view rows and the
// persistent all-time frame count (App.gcount). Keep in sync with draw_trace_grouped.
fn gkey(dir string, ch string, id u32, ext bool) string {
	return '${dir}|${ch}|${id}|${ext}'
}

// grouped: one collapsible row per (dir, ch, id), expand to decode its latest signals.
// Rows are sorted by a STABLE key (id, then dir) so they never jump as the ring trims —
// the order is fixed by identity, not by which frame arrived most recently.
fn draw_trace_grouped(mut app App, rows []TraceRow, gcount map[string]u64, filt string) {
	mut agg := map[string]GAgg{}
	for r in rows {
		if !trace_pass(r, filt) {
			continue
		}
		k := '${r.dir}|${r.ch}|${r.id}|${r.ext}'
		mut g := agg[k] or { GAgg{r.dir, r.ch, r.id, r.ext, 0, r} }
		g.count++
		g.last = r
		agg[k] = g
	}
	mut groups := agg.values()
	groups.sort_with_compare(fn (a &GAgg, b &GAgg) int {
		if a.id != b.id {
			return if a.id < b.id { -1 } else { 1 }
		}
		if a.dir != b.dir {
			return if a.dir < b.dir { -1 } else { 1 }
		}
		return if a.ch < b.ch { -1 } else if a.ch > b.ch { 1 } else { 0 }
	})
	if vgui.table_begin('gtrace', 5) {
		vgui.table_setup_col('id / name', 210)
		vgui.table_setup_col('ch', 52)
		vgui.table_setup_col('dir', 34)
		vgui.table_setup_col('count', 60)
		vgui.table_setup_col('data', 0)
		vgui.table_freeze_top()
		vgui.table_headers()
		for g in groups {
			r := g.last
			vgui.table_row()
			vgui.table_next_col()
			// ### keys the tree id on identity only, so the live label / sort don't reset it.
			open := vgui.tree_node_table('${idstr(g.id, g.ext)}  ${r.name}###${g.dir}|${g.ch}|${g.id}|${g.ext}')
			// clicking a row selects that frame (drives Signals/Graphics + "Add to filter")
			if vgui.is_item_clicked() {
				app.sel_id = int(g.id)
				app.sel_ext = g.ext
			}
			vgui.table_cell(g.ch)
			vgui.table_cell(g.dir)
			// all-time total (survives the ring trim); fall back to the window count.
			total := gcount[gkey(g.dir, g.ch, g.id, g.ext)] or { u64(g.count) }
			vgui.table_cell('${total}')
			vgui.table_cell(if r.rtr { 'RTR' } else { hex(r.data) })
			if open {
				if m := app.find_message(g.id, g.ext) {
					for s in m.active_signals(r.data) {
						lbl := s.label(r.data)
						extra := if lbl != '' { ' (${lbl})' } else { '' }
						unit := if s.unit != '' { ' ${s.unit}' } else { '' }
						vgui.table_row()
						vgui.table_next_col()
						vgui.text('    ${s.name}')
						vgui.table_next_col()
						vgui.table_next_col()
						vgui.table_next_col()
						vgui.table_cell('${s.physical(r.data):.3}${unit}${extra}')
					}
				}
				vgui.tree_pop()
			}
		}
		vgui.table_end()
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
	vgui.dock_window('Bus Config', buses)
	vgui.dock_window('Statistics', buses)
	// centre: Trace + Trace (filter) tabs; Log below
	vgui.dock_window('Trace', ctop)
	vgui.dock_window('Trace (filter)', ctop)
	vgui.dock_window('Log', cbot)
	// right column
	vgui.dock_window('Trace Chart', chart)
	vgui.dock_window('Signals', midnode)
	vgui.dock_window('Send', midnode)
	vgui.dock_window('Diagnostics', midnode)
	vgui.dock_window('DoIP Discovery', midnode)
	vgui.dock_window('Graphics', bottom)
	vgui.dock_window('Generators', bottom)
	vgui.dock_window('Script', bottom)
	vgui.dock_window('Help', bottom)
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
			valstr := if lbl != '' { '${s.physical(data):.3} (${lbl})' } else { '${s.physical(data):.3}' }
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
			xs << f32(r.t_ms)
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
	vis, op := vgui.begin_closable('Send', app.show_send)
	app.show_send = op
	if !vis {
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

// ---- Generators (interactive send blocks) ----
// Always visible and editable regardless of run state; Start/Stop only gates *firing*.
// Add / remove / edit happen in the session; Save persists them to the project .blobnet.
fn draw_gen(mut app App) {
	vis, op := vgui.begin_closable('Generators', app.show_gen)
	app.show_gen = op
	if !vis {
		vgui.end()
		return
	}
	if vgui.button('+ Add generator') {
		app.add_generator()
	}
	vgui.same_line()
	if vgui.button('Save to project') {
		app.save_project()
	}
	if app.dirty {
		vgui.same_line()
		vgui.text_colored(230, 170, 70, '● modified')
	}
	if app.running {
		vgui.text_dim('edit freely · Send now fires once · cyclic auto-repeats while running')
	} else {
		vgui.text_dim('edit freely · press Start to fire')
	}
	if app.senders.len == 0 {
		vgui.text_dim('no generators — click "+ Add generator"')
		vgui.end()
		return
	}
	for i, sr in app.senders {
		vgui.separator()
		// keep the model in sync with the edit buffers (name/key are UI-thread-only fields)
		app.senders[i].sender.name = vgui.buf_str(app.gen_bufs[i].name_buf)
		app.senders[i].sender.key = vgui.buf_str(app.gen_bufs[i].key_buf)
		s := app.senders[i].sender
		// name · key · remove
		vgui.set_next_item_width(200)
		if vgui.input_text('name##gn${i}', mut app.gen_bufs[i].name_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.set_next_item_width(36)
		if vgui.input_text('key##gk${i}', mut app.gen_bufs[i].key_buf) {
			app.dirty = true
		}
		vgui.same_line()
		if vgui.small_button('remove##rm${i}') {
			app.remove_generator(i)
			break // indices shifted — redraw next frame
		}
		// fire: Send now only fires while running (stopped = editable, just no TX)
		if app.running {
			if vgui.button('Send now##${i}') {
				app.fire_index(i)
			}
		} else {
			vgui.text_dim('Send now (start to fire)')
		}
		vgui.same_line()
		vgui.text('fires:')
		vgui.same_line()
		if vgui.toggle_button('manual##${i}', s.trigger == 'manual', 0) {
			app.set_trigger(i, 'manual')
		}
		vgui.same_line()
		if vgui.toggle_button('on key##${i}', s.trigger == 'key', 0) {
			app.set_trigger(i, 'key')
		}
		vgui.same_line()
		if vgui.toggle_button('cyclic##${i}', s.trigger == 'cyclic', 0) {
			app.set_trigger(i, 'cyclic')
		}
		if s.trigger == 'cyclic' {
			vgui.same_line()
			cm := if s.cycle_ms > 0 { s.cycle_ms } else { 100 }
			vgui.text('every ${cm} ms')
			vgui.same_line()
			if vgui.small_button('-##c${i}') {
				app.set_cycle(i, if cm > 60 { cm - 50 } else { 10 })
			}
			vgui.same_line()
			if vgui.small_button('+##c${i}') {
				app.set_cycle(i, cm + 50)
			}
		}
		// target bus: which wire this generator transmits on (defaults to its own channel)
		if app.chans.len > 1 {
			cur := app.senders[i].target()
			vgui.text('bus:')
			for ci, c in app.chans {
				vgui.same_line()
				if vgui.toggle_button('${c.name}##b${i}_${ci}', c.iface == cur, 0) {
					app.set_sender_bus(i, if c.iface == sr.iface { '' } else { c.iface })
				}
			}
		}
		// payload: DBC message -> per-signal values; raw -> id + data hex
		if s.message != '' {
			vgui.text('message ${s.message} · signal values:')
			for j, ss in s.signals {
				vgui.set_next_item_width(150)
				if vgui.input_double('${ss.name}##sig${i}_${j}', unsafe { &app.senders[i].sender.signals[j].value }) {
					app.dirty = true
				}
			}
		} else {
			vgui.set_next_item_width(70)
			if vgui.input_text('id##id${i}', mut app.gen_bufs[i].id_buf) {
				app.dirty = true
			}
			vgui.same_line()
			vgui.set_next_item_width(260)
			if vgui.input_text('data (hex)##dt${i}', mut app.gen_bufs[i].data_buf) {
				app.dirty = true
			}
		}
	}
	vgui.end()
}

// add_generator appends a new raw generator to the session, targeting the first channel.
// Session-only until Save writes it to the project.
fn (mut app App) add_generator() {
	iface := if app.chans.len > 0 { app.chans[0].iface } else { '' }
	app.mu.lock()
	app.senders << SenderRT{
		iface:  iface
		sender: project.Sender{
			name:    'New generator'
			id:      0x100
			trigger: 'manual'
		}
	}
	app.gen_bufs << GenBuf{
		name_buf: mkbuf('New generator', 48)
		key_buf:  mkbuf('', 2)
		id_buf:   mkbuf('100', 24)
		data_buf: mkbuf('', 96)
	}
	app.dirty = true
	app.mu.unlock()
	if app.running && iface != '' && iface !in app.tx_buses {
		if b := transport.open(iface) {
			app.tx_buses[iface] = b
		}
	}
}

// remove_generator drops generator `i` from the session.
fn (mut app App) remove_generator(i int) {
	app.mu.lock()
	if i >= 0 && i < app.senders.len {
		app.senders.delete(i)
		if i < app.gen_bufs.len {
			app.gen_bufs.delete(i)
		}
		app.dirty = true
	}
	app.mu.unlock()
}

// sync_senders_into_proj flushes the Generators panel edit buffers into app.proj so a Save
// persists them (a sender belongs to its channel; its `bus:` override travels as a field).
fn (mut app App) sync_senders_into_proj() {
	app.mu.lock()
	defer { app.mu.unlock() }
	for i in 0 .. app.senders.len {
		if app.senders[i].sender.message == '' && i < app.gen_bufs.len {
			app.senders[i].sender.id = u32(('0x' + vgui.buf_str(app.gen_bufs[i].id_buf)).u64())
			app.senders[i].sender.data = parse_hex_bytes(vgui.buf_str(app.gen_bufs[i].data_buf))
		}
	}
	mut p := app.proj
	for ci in 0 .. p.channels.len {
		mut ss := []project.Sender{}
		for sr in app.senders {
			if sr.iface == p.channels[ci].iface {
				ss << sr.sender
			}
		}
		p.channels[ci].senders = ss
	}
	app.proj = p
}

// save_project writes the whole project to its file (config + generators). An unsaved
// project (no path) routes to Save As. Reformats the .blobnet — comments are not preserved.
fn (mut app App) save_project() {
	if app.proj_path == '' {
		app.open_browser('saveas')
		return
	}
	app.commit_cfg() // flush Configuration-editor buffers (no-op if the editor never opened)
	app.sync_senders_into_proj()
	app.mu.lock()
	p := app.proj
	path := app.proj_path
	app.mu.unlock()
	p.save(path) or {
		app.notify('save failed: ${err}')
		return
	}
	app.dirty = false
	app.notify('saved -> ${path}')
}

// save_as sets the path (from the browser) and saves.
fn (mut app App) save_as(path string) {
	mut p := path
	if !p.ends_with('.blobnet') && !p.ends_with('.yml') && !p.ends_with('.yaml') {
		p += '.blobnet'
	}
	app.proj_path = p
	app.proj.name = app.proj_name
	app.save_project()
}

// new_project resets to a blank, unsaved project (0 buses) — the from-scratch entry point.
fn (mut app App) new_project() {
	app.stop()
	app.set_project(project.Project{ name: 'untitled' }, '')
	app.notify('new project — add buses in Configure…')
}

fn (mut app App) set_trigger(i int, t string) {
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.trigger = t
		if t == 'cyclic' && app.senders[i].sender.cycle_ms <= 0 {
			app.senders[i].sender.cycle_ms = 100
		}
	}
	app.mu.unlock()
}

fn (mut app App) set_cycle(i int, ms int) {
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.cycle_ms = ms
	}
	app.mu.unlock()
}

// set_sender_bus points generator `i` at a target bus ('' = its own channel). A newly
// targeted bus is opened if the measurement is running and it isn't open yet.
fn (mut app App) set_sender_bus(i int, bus string) {
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.bus = bus
		tgt := app.senders[i].target()
		if app.running && tgt != '' && tgt !in app.tx_buses {
			if b := transport.open(tgt) {
				app.tx_buses[tgt] = b
			}
		}
	}
	app.mu.unlock()
}

// fire_index sends generator `i`'s CURRENT (edited) frame once. DBC-message generators
// encode the edited signal values; raw generators use the edited id/data hex fields.
fn (mut app App) fire_index(i int) {
	if i < 0 || i >= app.senders.len {
		return
	}
	s := app.senders[i].sender
	mut id := s.id
	mut ext := s.ext
	mut data := []u8{}
	if s.message != '' {
		mut found := false
		for db in app.dbs {
			for m in db.messages {
				if m.name != s.message {
					continue
				}
				id = m.id
				ext = m.ext
				data = []u8{len: m.dlc}
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
		if !found {
			app.notify('generator: message "${s.message}" not in any DBC')
			return
		}
	} else if i < app.gen_bufs.len {
		id = u32(('0x' + vgui.buf_str(app.gen_bufs[i].id_buf)).u64())
		data = parse_hex_bytes(vgui.buf_str(app.gen_bufs[i].data_buf))
	}
	app.tx_on(app.senders[i].target(), transport.CanFrame{
		id:       id
		extended: ext
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

fn draw_tchart(mut app App, trecs []TRec) {
	vis, op := vgui.begin_closable('Trace Chart', app.show_tchart)
	app.show_tchart = op
	if !vis {
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
