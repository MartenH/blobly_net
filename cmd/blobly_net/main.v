// blobly_net — the Dear ImGui + ImPlot frontend for blobly_net (phased migration off
// vlang/gui; see docs/gui_toolkit_evaluation.md).
//   Phase 1: live decoded Trace + Trace Chart swimlane, docked in one window.
//   Phase 2: menu bar (File/View) + Start/Stop measurement lifecycle + a Buses panel with
//            per-channel enable + state colour + RX counts. Channels open on ▶ Start, not
//            at boot. All engine work reuses the GUI-free modules (project/transport/candb/
//            telem) unchanged; gui's src/main.v stays the shipping app until parity.
//
// Build: libs/vgui/build_deps.sh  then
//   v -enable-globals -cc gcc -path "@vlib|@vmodules|modules|libs" run cmd/blobly_net/main.v
// Project: argv[1] (a .blobnet path — the Windows file association passes it), else
// BLOBLY_PROJECT, else projects/sim-demo.blobnet (driver-free, runs on a clean machine —
// the old trace-demo default needed vcan0 + a blobly_emb target). Env: VGUI_WAKE_MS cap.
module main

import os
import math
import strings
import markdown
import sync
import time
import project
import transport
import wiretap
import candb
import sysview
import telem
import isotp
import uds
import flash
import sim
import script
import canlog
import mf4
import doip
import someip
import net as vnet
import vgui

const diag_tx_id = u32(0x7E0)
const diag_rx_id = u32(0x7E8)

const trace_cap = 2000

// Where a frame came from, OBSERVED rather than declared. On a normal bench three parties put
// frames on one wire — us as tester, us as the simulated surroundings, and the real ECU — and
// they all arrive at the monitor identically. Deriving the label from the project ("this id
// belongs to a sim node") would paint a real ECU's frame as simulated the moment it shares an
// id with one of ours, which is the single collision most worth catching.
// The labels and the matching live in modules/wiretap, where they can be tested: this file is
// compile-linked by CI but never run by it.
// Identities for emissions made while the trace is paused: tracked (so their echoes are still
// recognised as ours) but with no row to mark. They come from the TOP of the range, which the
// row counter — one increment per appended row — can never reach, so the two can never collide
// and row_index_locked maps them to -1 without a special case. They must still be UNIQUE: with
// one shared value, retracting a failed send would forget an unrelated emission that was still
// waiting for its echo.
const ghost_base = u64(1) << 63

const org_tst = wiretap.tst
const org_sim = wiretap.sim
const org_rep = wiretap.rep
const org_bus = wiretap.bus

struct TraceRow {
	t_ms f64
	ch   string
	// TST | SIM | REP | BUS. Replaces the old RX/TX: direction is a FUNCTION of origin (the
	// first three are outbound, BUS is inbound), so a separate column carried no information —
	// while `dir` answered "did I press send", never "whose frame is this".
	origin string
	id     u32
	ext    bool
	rtr    bool
	name   string
	data   []u8
	// End-to-end violation on a RECEIVED frame ('' = none, or not a protected message).
	// Carried on the row rather than computed at draw time because it depends on the PREVIOUS
	// frame's counter — a verdict the trace cannot reconstruct once the frames are just rows.
	e2e string
mut:
	// Stable identity, so an echo arriving later can confirm THIS row: the trace is a ring
	// trimmed by re-slicing, which moves every index.
	seq u64
	// An outbound row is written at emit, so it states intent. `confirmed` means the frame came
	// back off the wire; `missed` means its window closed without it. Those disagree in every
	// bench failure worth catching — CAN needs an ACK from at least one other node, so a lone
	// node's frames never reach the wire at all, and the same goes for a wrong bitrate, swapped
	// CANH/CANL or a down link.
	confirmed bool
	missed    bool
}


struct TRec {
	ch     int
	core   int // the block's core (from its header) — authoritative for lane grouping (esp. idle)
	abs_us u64 // start_us folded across epoch re-anchors (µs; u64 so a long capture can't wrap)
	rec    telem.Record
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
	spawning  bool // rx_loop spawned but its bus not open yet (double-click guard)
	link_down bool // real CAN iface is administratively DOWN (bound but can't tx/rx)
}

fn (c Chan) monitorable() bool {
	return c.enabled && c.mode == 'monitor' && !c.doip
}

struct App {
mut:
	mu          sync.Mutex
	chans       []Chan
	trace       []TraceRow
	// Emissions still waiting for their echo, and the bookkeeping that lets one confirm its own
	// row: `trace_seq` is the next row's identity, `trace_base` the identity of trace[0].
	taps        wiretap.Ring
	trace_seq   u64
	trace_base  u64
	ghost_seq   u64 // identities for emissions made while paused (see ghost_base)
	tx_mutexes  map[string]&sync.Mutex // per-interface send order (see TapBus.tx_mu)
	// Guards tx_mutexes ALONE, deliberately not app.mu: open_tap is called with app.mu held
	// (set_sender_bus retargets a generator mid-run under the lock), and app.mu is not
	// reentrant — taking it again inside the tap constructor deadlocked the GUI thread.
	tx_map_mu   sync.Mutex
	gcount      map[string]u64 // persistent per-group frame totals (survive the ring trim)
	trecs       []TRec
	rx          u64 // total across channels
	rev         u64
	running     bool
	dbs         []candb.Database // all loaded DBCs (union; trace/symbol decode)
	dbs_paths   []string         // resolved file path per dbs entry (editor save target)
	dbc_readers int              // live workers reading app.dbs lock-free (rx loops);
	// the editor stays read-only until 0 — app.running clears BEFORE workers exit
	dbs_by_iface map[string][]candb.Database // per-channel DBCs (generator message picker scope)
	manifest     telem.Manifest
	has_manifest bool
	t0           i64
	wake_ms      i64
	last_wake    i64
	proj_path    string
	proj_name    string
	dark         bool = true // theme
	ui_scale     f32  = 1.0
	paused       bool
	recording    bool
	rec          []canlog.LogEntry // captured while recording; written on stop
	tx_count     u64
	logs         []string           // Log panel (status/events, newest last)
	doip_ents    []doip.VehicleInfo // DoIP Discovery results
	// panel visibility (View menu)
	// Default workspace is intentionally minimal: Buses + Trace + Log. Everything else is
	// off and toggled on via the activity bar / View menu (its dock slot is still reserved).
	show_buses     bool = true
	show_sim       bool
	show_symbols   bool
	show_trace     bool = true
	show_ftrace    bool
	show_tchart    bool
	show_signals   bool
	show_graphics  bool
	show_diag      bool
	show_gen       bool
	show_script    bool
	show_doip      bool
	show_network   bool
	show_stats     bool
	show_log       bool              = true
	help_cache     map[string]string = map[string]string{} // markdown file -> contents (read once)
	// Signals selection + Graphics watch list (UI-thread only; RX never touches these)
	sel_id        int = -1 // selected message id (-1 = none)
	sel_ext       bool
	watch         []Watch // signals plotted in Graphics
	plot_win      f32  = 5    // Graphics x-window in seconds (0 = full history / autofit)
	plot_multi    bool = true // Graphics Y: per-signal real axes (up to 3) vs one shared axis
	trace_grouped bool = true // Trace: grouped-by-id (expandable) vs chronological
	trace_bus     string    // main Trace: show only this bus (channel name); '' = all
	ftrace_bus    string    // Trace (filter) panel: show only this bus; '' = all
	fwatch        []FrameId // Trace (filter) watch list — frames added from Trace/Symbols
	// TX buses — one open bus per channel iface, created at Start. Generators fire on their
	// own target bus (its channel, or a `bus:` override); the Send panel defaults to
	// send_iface (the first monitor channel).
	tx_buses          map[string]transport.Bus
	send_iface        string
	qs_iface          string // Quick send target bus (a channel iface); '' = send_iface default
	send_id_buf       []u8
	send_data_buf     []u8
	trace_filter_buf  []u8 // Trace substring filter
	trace_grouped2    bool // second Trace (filter) panel: own view mode
	trace_filter2_buf []u8 // second Trace (filter) panel: own filter
	symbol_filter_buf []u8 // Symbol Browser search
	log_path_buf      []u8 // Open Recording path (.log/.mf4)
	doip_host_buf     []u8 // DoIP manual discover host[:port]
	// Diagnostics (UDS on a worker thread)
	diag_did_buf []u8
	diag_sel     int // which DiagTarget the panel addresses (index into the CURRENT list)
	// The selected target's LABEL, which is what the worker resolves by. An index is not an
	// identity: a hosted entity can lose its listener between the click and the worker running,
	// the list is rebuilt without it, and the same index then addresses a DIFFERENT ECU whose
	// answers are reported as the selected one's.
	diag_sel_key string
	diag_plan    []DiagTarget // what start() actually spawned, per bus
	// Hosted DoIP entities, by interface. Held so Stop can close the listeners: an entity that
	// outlived Stop would keep port 13400 bound, and the next Start would fail to bind against
	// the previous run of the same application.
	doip_hosts map[string]&doip.DoipServer
	// Which RUN a worker belongs to. app.running alone is not enough: Stop and Start inside a
	// supervisor's sleep leave it observing `true` throughout, so it survives into the next run
	// holding a server Stop already closed — and then deregisters the LIVE supervisor's target
	// and competes with it to bind. Incremented by every Start; a worker exits when it differs.
	run_gen u64
	// The Configuration window's File tab: the project's own TEXT, edited in place.
	//
	// Text and not a re-serialisation, because `to_yaml()` does not preserve comments and this
	// file is where a bench setup is explained to the next person. Saving re-writes exactly
	// what is in the box; `parse()` is used only to refuse a file that would not load.
	cfg_tab      int // 0 = buses, 1 = file
	cfg_text     []u8
	cfg_text_len int    // bytes loaded, to notice when the box is nearly full
	cfg_err      string // parse error holding back a save ('' = the text parses)
	cfg_loaded   string // which path cfg_text holds ('' = nothing loaded)
	// Whether the text has been TYPED IN since it was loaded. Without it there was no way to
	// tell "showing the file" from "showing edits", so every staleness question had the wrong
	// answer: a project switch or a structured Save left old YAML on screen that Save would
	// then write over the new file.
	cfg_text_dirty bool
	cfg_chans      int // channels the text yields; cached, because parsing per frame is not free

	// Script (Lua on a worker thread)
	script_path_buf []u8
	senders         []SenderRT      // flattened project senders (Generators)
	gen_bufs        []GenBuf        // per-sender editable fields (parallel to senders)
	dirty           bool            // project (config or generators) changed since load/save (● modified)
	proj            project.Project // the loaded project, kept so Save can persist edits
	// Configuration editor (stopped-only) + its per-bus edit buffers (parallel to proj.channels)
	show_config bool
	cfg_bufs    []CfgBuf
	// Discover-interfaces dialog (add buses from detected transports)
	disc_open bool
	disc_list []DiscoveredIface
	disc_tick []bool // parallel to disc_list
	// File browser (Open / Save As / attach DBC / attach manifest)
	fb_open     bool            // browser window shown
	fb_save     bool            // true = save mode (filename input), false = open mode
	fb_dir      string          // current directory
	fb_name_buf []u8            // filename (save mode)
	fb_ext      string          // extension filter ('.blobnet' | '.dbc' | '' = recordings)
	fb_target   string          // action on OK: 'open' | 'saveas' | 'dbc:<ci>' | 'manifest:<ci>'
	sims        []SimCfg        // per-channel in-process simulation workloads
	sim_enabled map[string]bool // sim_key(channel, node) -> enabled (Simulation panel)
	sim_gen     u64             // bumped when sim_enabled changes -> sim_loop rebuilds
	// worker-thread outputs (guarded by mu)
	diag_log        []string
	diag_busy       bool
	script_log      []string
	script_busy     bool
	trace_busy      bool   // a trace-dump transfer is in flight (single-flight guard)
	trace_recording bool   // Record toggle: the target's capture is armed (optimistic)
	trace_status    string // last dump status line, shown by the Trace Chart
	trace_freeze    string // last TraceRsp state/cause (why it froze: trigger vs stop), from rx_loop
	cursor_a        f64    // Trace Chart measurement markers A/B (µs); the swimlane drags them
	cursor_b        f64
	cursor_span     f64 // the span the cursors were placed for — re-seat A/B when a new dump loads
	// Shell (the target's CAN command line; one worker spawn per submitted line)
	show_shell        bool
	show_dbc          bool
	dbc_ed            DbcEd
	show_sys          bool
	sys_path_buf      []u8
	sys               sysview.System
	sys_loaded        bool
	sel_ecu           string // selected node in the System panel's ECU master-detail
	shell_buf         []u8 // the input line (persistent; edited in place by console_input)
	eth_target_buf    []u8 // the eth shell's board ip (session-only; manifest carries the port)
	eth_shell_session u16  // persists across commands: a fresh client restarting at session 1
	// would let a late reply to a timed-out command complete the NEXT one
	eth_someip   telem.SomeipIdent // the eth shell's identity (its OWN slot — see rebuild)
	eth_method   u16               // the eth shell's method id (0 = no eth shell)
	shell_lines  []string          // scrollback (guarded by mu; the worker appends)
	shell_busy   bool              // single-flight: one command in flight at a time
	shell_follow bool              // new output arrived — pin the scrollback to the bottom next frame
	// Flash (UDS firmware download THROUGH the blobly bootloader — modules/flash;
	// the bootloader itself is not field-updatable by design, docs/bootloader.md)
	show_flash     bool
	flash_img_buf  []u8     // image path: a wrapped mkimage .img or a raw .bin
	flash_base_buf []u8     // app-slot base address, hex (bootmap.h APP_BASE)
	flash_req_buf  []u8     // boot rx id, hex
	flash_rsp_buf  []u8     // boot tx id, hex
	flash_ver_buf  []u8     // sw_version, decimal (raw .bin only — .img carries its own)
	flash_log      []string // milestones + errors (guarded by mu; the worker appends)
	flash_busy     bool     // single-flight: one download at a time
	flash_done     int      // transfer progress, blocks (worker-updated)
	flash_total    int
}

// SenderRT is a project sender bound to its channel iface (Generators panel).
struct SenderRT {
mut:
	iface  string // the bus this generator fires on (a channel iface); rebound if the iface changes
	chan   string // the CHANNEL that owns it — two channels can share one iface, and only the
	              // name says which of them a generator's frames belong to
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
	name_buf     []u8
	network_buf  []u8
	address_buf  []u8
	bitrate_buf  []u8
	manifest_buf []u8
	dbc_buf      []u8 // "+ Add DBC" typed-path fallback
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
	// The channel this entry came FROM, whole. Recovering it by interface picks the first
	// match, and two channels can share one interface string — a `type: doip` channel with no
	// `interface:` keeps the CAN default `vcan0`, so a lookup could hand the DoIP entity a CAN
	// channel's identity and mark its diagnostic target as CAN, leaving the hosted entity
	// unreachable. The carrier is read from here, never re-derived.
	pch project.Channel
	db    candb.Database
	nodes []project.NodeCfg
	// Protection to CHECK on this bus, from the channel's `verify:` block. Separate from the
	// nodes because the ECU under test is the one a rest-bus deliberately does not simulate.
	verify []project.ProtectCfg
	// The database PATHS this entry attached, so a recording can rebuild that entry's own view
	// from the currently-loaded (edited) databases rather than an interface-wide merge.
	db_paths []string
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

// add_watch plots a signal (idempotent — no-op if already plotted). Used by the Trace
// right-click, which adds without removing an already-plotted signal.
fn (mut app App) add_watch(id u32, ext bool, sig string) {
	for w in app.watch {
		if w.id == id && w.ext == ext && w.sig == sig {
			return
		}
	}
	app.watch << Watch{id, ext, sig}
}

// app_icon renders the 32×32 RGBA window/taskbar icon: an accent-blue rounded square with
// three dashed "trace" lines (a bus-monitor motif). Procedural — no image file to embed.
fn app_icon() []u8 {
	sz := 32
	rad := 6
	mut px := []u8{len: sz * sz * 4}
	for y in 0 .. sz {
		for x in 0 .. sz {
			i := (y * sz + x) * 4
			// rounded corners: clamp to the nearest corner centre, drop pixels outside the radius
			cx := if x < rad {
				rad
			} else if x >= sz - rad {
				sz - 1 - rad
			} else {
				x
			}
			cy := if y < rad {
				rad
			} else if y >= sz - rad {
				sz - 1 - rad
			} else {
				y
			}
			dx := x - cx
			dy := y - cy
			if dx * dx + dy * dy > rad * rad {
				px[i], px[i + 1], px[i + 2], px[i + 3] = u8(0), 0, 0, 0
				continue
			}
			mut r := u8(0x1e)
			mut g := u8(0x88)
			mut b := u8(0xe5)
			// three light dashed trace lines across the middle
			if (y == 10 || y == 16 || y == 22) && x > 4 && x < sz - 4 && x % 3 != 0 {
				r, g, b = u8(0xea), u8(0xf2), u8(0xff)
			}
			px[i], px[i + 1], px[i + 2], px[i + 3] = r, g, b, u8(255)
		}
	}
	return px
}

// FrameId identifies one CAN frame (id + 29-bit flag) for the Trace (filter) watch list.
struct FrameId {
	id  u32
	ext bool
}

// chan_name_for maps a bus iface back to its channel name (the Trace `ch` column value),
// falling back to the iface if unmatched.
fn (app &App) chan_name_for(iface string) string {
	// CANONICAL on both sides. A tap keys on the canonical address (`inproc` and `inproc:CAN`
	// are one hub), so an exact comparison against the configured string failed for a channel
	// written the short way: its Quick Send, Shell, Flash and dump rows were labelled with the
	// expanded interface, and selecting that channel filtered them straight out again.
	want := transport.canonical_iface(iface)
	for c in app.chans {
		if transport.canonical_iface(c.iface) == want {
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

// NOTE concurrency: the DBC editor mutates app.dbs ONLY while stopped
// (read-only during a measurement), so these lock-free reads never race the
// editor — and load_recording may call them while holding app.mu.
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

// open_transport opens `iface`, appending the vendor bitrate (`@<rate>`) for pcan/kvaser
// buses so the driver uses the configured rate. The logical KEY stays the raw iface —
// tx_buses, sender targets and channels all key on it consistently — and only the physical
// open carries the suffix. Non-vendor buses (socketcan/vcan configure bitrate via `ip link`;
// inproc/udp have none) open unchanged.
// Untapped: the only caller is the monitor loop, which never emits. Everything that DOES emit
// goes through open_tap so the trace can say whose frame it is.
fn (app &App) open_transport(iface string) !transport.Bus {
	return transport.open(app.bitrate_iface(iface))
}

// bitrate_iface returns `iface` with the vendor bitrate suffix (`@<rate>`) for a pcan/kvaser
// channel configured at a non-default rate, else `iface` unchanged. Used wherever a channel's
// physical bus is opened — transport.open (via open_transport) AND isotp.open_software (the
// diagnostics ISO-TP paths) — so UDS reaches the vendor driver at the configured bitrate too.
// bitrate_iface finds the channel owning this interface and applies its configured rate.
// The per-channel rule lives in project.Channel.iface_with_bitrate, shared with the runner.
fn (app &App) bitrate_iface(iface string) string {
	for c in app.chans {
		if c.iface == iface {
			return project.Channel{
				iface:   c.iface
				adapter: c.adapter
				bitrate: c.bitrate
			}.iface_with_bitrate()
		}
	}
	return iface
}

// start opens every enabled, monitorable channel on its own RX thread.
fn (mut app App) start() {
	if app.running {
		return
	}
	// flush any unsaved editor edits into the model + runtime view first, so the measurement
	// attaches to exactly what the Configuration editor shows (not stale buffered values).
	if app.dirty {
		app.apply_edits()
	}
	if app.cfg_text_dirty {
		// Text edits are NOT folded in automatically: the file is the authority for everything
		// the structured editor cannot express, and guessing that a half-typed YAML buffer
		// should become the running configuration is the wrong default. Say so instead.
		app.notify('note: the Configuration ▸ File tab has unsaved text — it is not part of this run')
	}
	// unsaved DBC-editor edits exist only in the app.dbs union — sims and the
	// per-channel generator databases still hold the on-disk definitions, so a
	// measurement would encode with one schema and decode with another.
	// (Ghost entries for paths a project swap detached are pruned first —
	// the panel may be closed, and a ghost would wedge Start forever.)
	for pth, _ in app.dbc_ed.dirty.clone() {
		if app.dbs_paths.index(pth) < 0 {
			app.dbc_ed.dirty.delete(pth)
			app.notify('unsaved DBC edits for detached ${os.file_name(pth)} were discarded')
		}
	}
	// An edit still in the field is not in the dirty map yet, so it would slip past the check
	// below AND miss the measurement's schema. The click that starts the run is also the click
	// that ends the edit, and the toolbar is drawn first — so resolve it here.
	app.resolve_pending_bit_edit()
	for _, d in app.dbc_ed.dirty {
		if d {
			app.notify('DBC editor has unsaved edits — Save or Revert them before starting')
			return
		}
	}
	// Pending echoes belong to the run that is ending: an emission from just before the last
	// Stop would otherwise sit at the front of this run's ring, where an identical healthy frame
	// claims it and the new run's own record then expires as never sent. Done HERE, not in
	// stop(), because stop() runs while the emitters are still winding down — a worker mid
	// -iteration can append after the reset and put the stale record back. Nothing of ours is
	// emitting yet at this point. (A trace Clear is different: same run, so those records stay.)
	// Under the mutex: a worker from the previous run can still be inside note_emit or
	// claim_echo_locked, and an unsynchronised assignment would race the ring's backing array.
	app.mu.lock()
	app.taps = wiretap.Ring{}
	app.mu.unlock()
	app.running = true
	app.run_gen++
	for ci, ch in app.chans {
		if !ch.monitorable() {
			continue
		}
		// running is set by rx_loop once its bus is OPEN. Setting it here made it mean "about to
		// start": the simulation emits its first cyclic frames immediately, and with inproc —
		// which broadcasts only to already-attached subscribers — those frames genuinely had no
		// listener, yet were tracked as if one existed and later marked as never sent.
		app.chans[ci].link_down = !iface_link_up(ch.adapter, ch.address)
		// the same guard the mid-run toggle uses: disabling and re-enabling while this open is
		// still pending would otherwise start a SECOND loop for one channel, and both would
		// claim against the same monitor index — one gets the echo, the other files its copy
		// under the device under test
		app.chans[ci].spawning = true
		spawn rx_loop(app, ci, ch.iface, app.run_gen)
		// A TX bus per CHANNEL (each generator fires on its target bus), plus one anonymous tap
		// per wire for the paths with no particular channel — Quick Send, diagnostics, shell.
		if tx_bus_key(ch.name, ch.iface) !in app.tx_buses {
			if b := app.open_tap_on(ch.iface, org_tst, ch.name) {
				app.tx_buses[tx_bus_key(ch.name, ch.iface)] = b
			}
		}
		if tx_bus_key('', ch.iface) !in app.tx_buses {
			if b := app.open_tap(ch.iface, org_tst) {
				app.tx_buses[tx_bus_key('', ch.iface)] = b
			}
		}
		if app.send_iface == '' {
			app.send_iface = ch.iface // Send panel default = first monitor channel
		}
	}
	// a generator may target a bus whose channel isn't itself monitored — open those too
	for sr in app.senders {
		tgt := sr.target()
		if tgt != '' && tx_bus_key(sr.chan, tgt) !in app.tx_buses {
			if b := app.open_tap_on(tgt, org_tst, sr.chan) {
				app.tx_buses[tx_bus_key(sr.chan, tgt)] = b
			}
		}
	}
	// spawn the in-process simulation workloads (driver-free sim ECUs + a UDS server)
	for sc in app.sims {
		// DoIP carries diagnostics, not frames. sim_loop would call transport.open('doip:…'),
		// which on Linux falls through to SocketCAN, logs a failure and exits the thread — the
		// no-hardware demo trying to open its Ethernet endpoint as a CAN interface.
		if sc.pch.is_doip() {
			continue
		}
		if sc.nodes.len > 0 {
			spawn sim_loop(app, sc) // a verify-only channel has nothing to transmit
		}
	}
	// Diagnostics are per BUS, decided ONCE. Two channel entries may share an interface, and
	// resolving them per entry produced a duplicate default responder on the second pass while
	// the panel independently re-resolved and listed targets startup had rejected. The plan is
	// computed here, spawned from here, and stored for the panel to read — one answer to "what
	// is running on this wire".
	app.diag_plan = []
	mut seeded := []string{}
	for sc in app.sims {
		for w in sim.validate_verify(sc.db, sc.verify) {
			app.notify('${sc.iface}: ${w}')
		}
		// DoIP is hosted from the project, not from here — see start_doip_hosts().
		if sc.pch.is_doip() {
			continue
		}
		if sc.nodes.len == 0 {
			// A verify-only channel WATCHES a real bus. Starting the built-in 0x7E0/0x7E8
			// server on it would put our diagnostic responses on the wire beside the ECU under
			// test's — a collision on the bench this configuration exists to observe.
			continue
		}
		if sc.iface in seeded {
			continue
		}
		seeded << sc.iface
		mut peers := []project.NodeCfg{}
		// Which CHANNEL each node came from, BY POSITION. Diagnostics are seeded once per bus,
		// but two entries can share that bus and sim_key() puts the channel in the key, so a
		// server keyed on the wrong entry's channel reads a key the panel never writes. Keyed
		// by node NAME this went wrong again: names are not unique across a bus, so two "SUT"s
		// collapsed onto one owner. UdsNode.src indexes back into `peers`, which is exact.
		mut owners := []project.Channel{}
		for other in app.sims {
			// A DoIP entry is here only so the Simulation panel can show its ECU. Its nodes are
			// not CAN peers: a disabled `type: doip` channel with no `interface:` inherits
			// vcan0, and copied rx/tx on its node would then start a CAN responder for a
			// channel that is switched off.
			if other.pch.is_doip() {
				continue
			}
			if other.iface == sc.iface {
				peers << other.nodes
				for _ in other.nodes {
					owners << other.pch
				}
			}
		}
		for w in sim.validate_uds(peers) {
			app.notify(w)
		}
		mut diag_nodes := sim.uds_nodes(peers)
		if diag_nodes.len == 0 {
			spawn diag_server_loop(app, sc.iface) // the built-in default for this bus
			app.diag_plan << DiagTarget{
				key:   diag_key_can(sc.iface, diag_tx_id, diag_rx_id)
				label: 'default on ${sc.iface}  (0x${diag_tx_id:X}/0x${diag_rx_id:X})'
				iface: sc.iface
				chan:  sc.pch.name
				rx:    diag_tx_id
				tx:    diag_rx_id
			}
			continue
		}
		// Configure a per-ECU server and you own diagnostics on this bus: the default does NOT
		// also run, or the two would both answer whenever their ids overlapped.
		for mut u in diag_nodes {
			own := if u.src >= 0 && u.src < owners.len { owners[u.src] } else { sc.pch }
			spawn uds_node_loop(app, own, sc.iface, u.name, u.rx, u.tx, u.ext, u.server)
			app.diag_plan << DiagTarget{
				key:   diag_key_can(sc.iface, u.rx, u.tx)
				label: '${u.name}  (0x${u.rx:X}/0x${u.tx:X})'
				iface: sc.iface
				chan:  own.name // this node's OWN channel, not the first one on the wire
				rx:    u.rx
				tx:    u.tx
				ext:   u.ext
			}
		}
	}
	// DoIP hosts start LAST. Their supervisors publish targets from their own threads as soon
	// as a bind succeeds — a localhost bind is fast enough to land mid-loop — and the CAN plan
	// above appends to the same array without the lock. Finishing that construction first is
	// what makes the unlocked appends safe, rather than adding a lock to every one of them.
	app.start_doip_hosts()
	spawn gen_loop(app) // cyclic senders
}

// start_doip_hosts supervises every DoIP channel that simulates an ECU — enabled or not.
//
// Driven from the PROJECT rather than app.sims, because a channel disabled when the project
// loaded is excluded from app.sims entirely: there would be no supervisor, and enabling it
// later would leave the entity permanently idle with no worker to notice.
fn (mut app App) start_doip_hosts() {
	for c in app.proj.channels {
		if !c.is_doip() {
			continue
		}
		nodes := c.all_nodes()
		for w in sim.validate_uds_doip(nodes) {
			app.notify('${c.name}: ${w}')
		}
		if nodes.len == 0 {
			// Tester-only, as the headless runner treats it: a channel that simulates no ECU
			// exists to address an EXTERNAL one. Hosting would bind the endpoint and answer
			// with stock data, so a bench would read results from an ECU nobody asked for.
			app.notify('${c.name}: DoIP tester only (no simulated entity)')
			continue
		}
		ent := sim.doip_entity(c, nodes) or {
			app.notify('${c.name}: ${err}')
			app.notify('${c.name}: DoIP entity NOT started')
			continue
		}
		if ent.extra > 0 {
			app.notify('${c.name}: ${ent.extra + 1} UDS nodes on one DoIP entity; serving "${ent.node}" (0x${c.ecu_addr:04X})')
		}
		// Which node's tick in the Simulation panel switches this entity on and off. The
		// shorthand `simulate: [SUT]` configures no `uds:` block, so doip_entity() serves the
		// built-in server and returns an empty node name — keying enablement on that alone
		// meant unticking SUT in the shipped demos did nothing at all.
		key := if ent.node != '' { ent.node } else { nodes[0].name }
		spawn doip_watch(app, c, ent, key, app.run_gen)
	}
}

// doip_watch owns one entity's socket for the life of a run: it binds while the channel and
// its ECU are ticked, and closes when either is not.
//
// It never blocks on accept. accept_and_serve() applies its timeout to ACCEPTING and then
// serves the connection until the peer disconnects or the 60-second idle timeout, so a
// supervisor that also served could not observe a toggle while a tester held the session open —
// the "offline" ECU went on answering. Serving happens in doip_serve(); close() from here
// interrupts it, which is what makes switching an ECU off actually take effect.
fn doip_watch(app &App, pch project.Channel, ent sim.DoipEntity, key string, gen u64) {
	mut a := unsafe { app }
	host, port := pch.doip_endpoint()
	cfg := ent.cfg // built by sim.doip_entity, so the GUI announces exactly as headless does
	mut hst := &sim.DoipHost{
		server: ent.server
	}
	mut srv := &doip.DoipServer(unsafe { nil })
	mut bound := false
	mut warned := false
	// This RUN only. Checked with running, so a supervisor that slept through a Stop/Start pair
	// exits instead of acting on a run that is not its own.
	for a.running && a.run_gen == gen {
		want := a.doip_should_host(pch, key)
		if bound && !want {
			srv.close() // interrupts an in-progress session, not just the accept
			bound = false
			// Let a later failure speak again: cleared only on a successful bind, toggling off
			// and on to retry a held port produced no Log line at all, leaving the channel idle
			// and silent — which is what this PR set out to stop.
			warned = false
			// Generation-checked here TOO. Guarding only the bind-failure path left this one:
			// an old watcher between its close() and this call, while a Stop/Start/re-enable
			// published a replacement, would deregister the NEW run's live listener.
			a.doip_forget_if_current(pch, ent, gen)
			a.notify('${pch.name}: DoIP entity stopped — ${host}:${port} released')
		} else if !want || !bound {
			if want && !bound {
				// Rebuild the announcement from what the server SERVES now: a tester may have
				// written 0xF190 since the last bind, and the startup cfg would advertise the
				// original while the server returned the new one.
				mut cur := cfg
				if v := hst.server.dids[u16(0xF190)] {
					// Rebuild only the VIN. server_cfg() carries identity alone, so using it
					// here silently reset announce_count/interval/to to their defaults — an
					// ECU configured silent would start announcing after a toggle.
					cur = doip.ServerCfg{
						...cfg
						vin: v.bytestr()
					}
				}
				if s := a.doip_bind(cur, host, port, mut hst) {
					srv = s
					bound = true
					warned = false
					// Decide and publish ATOMICALLY. Checking first and publishing after leaves a
					// window: Stop can run between them, snapshot an empty host map, and this
					// socket is then inserted behind it — leaking past Stop and failing the
					// next Start against itself. doip_publish_if_current does both under the
					// same mutex Stop takes.
					if !a.doip_publish_if_current(pch, ent, srv, gen, key) {
						srv.close()
						bound = false
					} else {
						spawn doip_serve(app, mut srv)
						spawn doip_udp_worker(app, mut srv)
						// Power-on announcements, in the background: count × interval is 1.5s
						// by default and Start must not block on it.
						spawn doip_announce_worker(app, mut srv, pch.name)
						// cur.vin, not ent.announce: a tester may have written 0xF190 since
						// Start, and naming the startup VIN here would report an identity the
						// entity neither announces nor serves — the split this PR exists to
						// prevent, in the surface an operator actually reads.
						a.notify('${pch.name}: DoIP entity on ${host}:${port}, logical address 0x${pch.ecu_addr:04X}, VIN ${cur.vin}')
					}
				} else {
					// The generation again — an old supervisor that lost the bind race to a
					// new run would otherwise run this path and deregister the NEW run's live
					// listener, target and channel state. Checked inside the bare `else` so
					// `err` stays in scope.
					if a.running && a.run_gen == gen && !warned {
						// Once, not every tick. And DROP the target: whatever the cause, we are
						// not listening — leaving it selectable would point the panel at
						// whatever else owns that endpoint and report the wrong ECU's answers.
						a.notify('${pch.name}: cannot bind ${host}:${port} — ${err}')
						a.doip_forget_if_current(pch, ent, gen)
						warned = true
					}
				}
			}
			time.sleep(200 * time.millisecond)
			continue
		}
		time.sleep(200 * time.millisecond)
	}
	if bound {
		srv.close()
	}
}

// doip_announce_worker sends the power-on announcements, reporting a failure to the Log rather
// than dropping it — a silent ECU that was supposed to announce is exactly the thing a bench
// would waste an hour on.
fn doip_announce_worker(app &App, mut s doip.DoipServer, name string) {
	mut a := unsafe { app }
	s.announce() or { a.notify('${name}: announce failed: ${err}') }
}

// doip_serve runs one bound entity's TCP side until it is closed.
fn doip_serve(app &App, mut s doip.DoipServer) {
	mut a := unsafe { app }
	for a.running && !s.is_stopping() {
		s.accept_and_serve(200) or { continue } // a timeout is the normal case
	}
}

// doip_udp_worker answers vehicle-identification requests, so Discover finds the entity.
// Exits on is_stopping() as well as app.running, which the next Start REUSES: a worker that had
// not yet observed the brief false would otherwise hot-spin against its own closed sockets.
fn doip_udp_worker(app &App, mut s doip.DoipServer) {
	mut a := unsafe { app }
	for a.running && !s.is_stopping() {
		s.serve_udp_once(200) or { continue }
	}
}

// doip_publish_if_current publishes a freshly bound entity, but ONLY if this run still wants
// it — the test and the publication happen under one lock, so Stop cannot interleave between
// them and leave a listener behind its own snapshot. Returns false when the caller should close
// what it just bound.
fn (mut app App) doip_publish_if_current(pch project.Channel, ent sim.DoipEntity, srv &doip.DoipServer, gen u64, key string) bool {
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if !app.running || app.run_gen != gen {
		return false
	}
	if ci := app.chan_index_locked(pch) {
		if !app.chans[ci].enabled {
			return false
		}
	}
	if key != '' {
		if !(app.sim_enabled[sim_key(pch, key)] or { true }) {
			return false
		}
	}
	app.doip_hosts['${pch.name}|${pch.iface}'] = srv
	if ci := app.chan_index_locked(pch) {
		app.chans[ci].running = true
	}
	tgt := DiagTarget{
		key:     diag_key_doip(pch)
		label:   '${ent.node_label()} on ${pch.name}  (DoIP 0x${pch.ecu_addr:04X})'
		iface:   pch.iface
		carrier: script.carrier_of(pch)
	}
	if !app.diag_plan.any(it.key == tgt.key) {
		app.diag_plan << tgt
	}
	return true
}

// doip_is_hosted reports whether THIS application currently has the entity listening.
fn (app &App) doip_is_hosted(name string, iface string) bool {
	a := unsafe { app }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	return '${name}|${iface}' in a.doip_hosts
}

// doip_host_failed reports whether THIS channel is one we are meant to host and are not.
//
// By channel identity, not by interface: an interface-wide lookup answered "simulated" for a
// TESTER-ONLY channel that merely shares an endpoint with a hosted peer — an alias using a
// different tester_address to exercise another role — so scripts lost a perfectly good channel
// that the Diagnostics panel and the headless runner both expose. Sixth defect in this change
// from an interface string standing in for a channel; see chan_index_locked.
fn (app &App) doip_host_failed(name string, iface string) bool {
	mut a := unsafe { app }
	mut simulated := false
	for c in a.proj.channels {
		if c.name == name && c.iface == iface && c.is_doip() {
			simulated = c.all_nodes().len > 0
			break
		}
	}
	if !simulated {
		return false // tester-only: nothing for us to host, so nothing can have failed
	}
	if !a.running {
		// Nothing is hosted when nothing is running. Calling that "failed" made a script run
		// before Start stall 750ms per DoIP channel and then drop every one of them, reporting
		// "unknown channel" with nothing in the Log to explain it.
		return false
	}
	// PENDING is not FAILED. A supervisor polls every 200ms, so a channel enabled live — or a
	// script started immediately after Start — can be legitimately mid-bind. Treating that as
	// failure removed the channel from the script environment PERMANENTLY, and uds.open()
	// reported it unknown while the listener appeared a moment later. Give the bind its window.
	for _ in 0 .. 15 {
		if a.doip_is_hosted(name, iface) {
			return false
		}
		time.sleep(50 * time.millisecond)
	}
	return true
}

// doip_forget deregisters an entity that is no longer listening, so nothing offers it.
// doip_forget_if_current deregisters ONLY if this run still owns the entry, checking and
// mutating under ONE lock. The previous version checked, unlocked, then called doip_forget
// which re-locked — so a Stop and Start landing in that gap let a stale supervisor delete the
// NEW run's host entry and target. A function named "_if_current" that releases the lock
// before acting is not atomic; it just looks it.
// diag_key_doip / diag_key_can name a target uniquely. Interface + address, never the label.
fn diag_key_doip(pch project.Channel) string {
	return 'doip|${pch.iface}|${pch.name}|0x${pch.ecu_addr:04X}'
}

fn diag_key_can(iface string, rx u32, tx u32) string {
	return 'can|${iface}|0x${rx:X}/0x${tx:X}'
}

fn (mut app App) doip_forget_if_current(pch project.Channel, ent sim.DoipEntity, gen u64) {
	app.mu.lock()
	if app.running && app.run_gen == gen {
		app.forget_locked(pch, ent)
	}
	app.mu.unlock()
}

// forget_locked is the mutation itself. Caller holds app.mu.
fn (mut app App) forget_locked(pch project.Channel, ent sim.DoipEntity) {
	app.doip_hosts.delete('${pch.name}|${pch.iface}')
	if ci := app.chan_index_locked(pch) {
		app.chans[ci].running = false
	}
	// By the target's OWN label, not by endpoint. Two simulated channels can share an endpoint
	// and ECU address — two shorthand channels on the defaults — and exactly one of them binds.
	// An endpoint predicate then let the FAILING supervisor delete the successful channel's
	// target while its server stayed live: the panel loses an entity that is answering.
	mine := diag_key_doip(pch)
	app.diag_plan = app.diag_plan.filter(it.key != mine)
}

// doip_bind opens one entity and links it to its handler. The handler must exist before
// new_server() and the server before the handler can reach it, so the link is made after.
fn (mut app App) doip_bind(cfg doip.ServerCfg, host string, port int, mut hst sim.DoipHost) !&doip.DoipServer {
	handler := fn [mut hst] (req []u8) []u8 {
		return hst.handle(req)
	}
	mut s := doip.new_server(cfg, handler)
	hst.entity = s
	// The REAL error. Flattening it to "someone else owns it" sent people looking for a port
	// conflict when the host was not a local address, the family was unavailable, or the
	// address was malformed — none of which clear by waiting.
	s.listen(host, port)!
	return s
}

// chan_index_locked finds the runtime channel a project channel refers to.
//
// Identity is name AND interface. The interface string alone is NOT an identity — `type: doip`
// with no `interface:` keeps the CAN default `vcan0`, so two unrelated channels can share it —
// and substituting one for the other produced four separate defects in this change. One
// definition, so there is one place left to get it wrong. Caller holds app.mu.
fn (app &App) chan_index_locked(pch project.Channel) ?int {
	for ci in 0 .. app.chans.len {
		if app.chans[ci].name == pch.name && app.chans[ci].iface == pch.iface {
			return ci
		}
	}
	return none
}

// doip_should_host reports whether this entity should be listening right now: its channel
// ticked in Buses AND its ECU ticked in Simulation.
// chan_enabled reports a channel's LIVE tick from the Buses panel.
fn (app &App) chan_enabled(pch project.Channel) bool {
	a := unsafe { app }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if ci := a.chan_index_locked(pch) {
		return a.chans[ci].enabled
	}
	return pch.enabled // not started yet: the project's own value is all there is
}

fn (app &App) doip_should_host(pch project.Channel, key string) bool {
	a := unsafe { app }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if ci := a.chan_index_locked(pch) {
		if !a.chans[ci].enabled {
			return false
		}
	}
	if key != '' {
		return a.sim_enabled[sim_key(pch, key)] or { true }
	}
	return true
}

// sim_key names one simulated ECU. The interface alone is not an identity — a CAN channel and a
// `type: doip` channel can resolve to the same string and simulate the same node name, and the
// shared `<iface>:<node>` entry then made unticking one close the other. Seventh defect in this
// change from that substitution.
fn sim_key(pch project.Channel, node string) string {
	return '${pch.name}|${pch.iface}:${node}'
}

// stop signals the RX threads to exit (they re-check on the recv timeout) and tears down the
// hosted DoIP entities, whose sockets must be released before another Start can bind them.
fn (mut app App) stop() {
	// The run flag FIRST. A supervisor that is unbound and has just decided to rebind would
	// otherwise insert a fresh listener AFTER the snapshot below, escape this close, and
	// survive into the next Start — whose own bind would then fail against it.
	app.running = false
	// Then close: the serve loops block in accept for up to 200ms, and close() interrupts them
	// so the port is released now rather than whenever the last worker notices.
	// Snapshot under the lock the supervisor uses: it inserts and deletes entries as channels
	// are toggled, so iterating this map unlocked can race a concurrent write — and a listener
	// rebound between the read and the reset would escape the close entirely.
	app.mu.lock()
	mut hosted := []&doip.DoipServer{}
	for _, ds in app.doip_hosts {
		hosted << ds
	}
	app.doip_hosts = map[string]&doip.DoipServer{}
	app.mu.unlock()
	for mut ds in hosted {
		ds.close()
	}
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

// reset_trace_locked empties the trace and everything keyed to it. Caller holds app.mu.
fn (mut app App) reset_trace_locked() {
	app.trace = []
	app.gcount = map[string]u64{}
	// The pending records STAY. An echo already in flight is still ours, and dropping the record
	// would turn the next few of our own frames into BUS rows, recording entries and verifier
	// input. Row identities are monotonic and trace_base makes the old ones unresolvable, so a
	// surviving record suppresses its echo without confirming a row that came later.
	app.trace_base = app.trace_seq
}

// push_row_locked appends a row, stamps its identity and trims the ring. Caller holds app.mu.
fn (mut app App) push_row_locked(row TraceRow) u64 {
	seq := app.trace_seq
	app.trace_seq++
	mut r := row
	r.seq = seq
	app.trace << r
	if app.trace.len > trace_cap {
		drop := app.trace.len - trace_cap
		app.trace = app.trace[drop..].clone()
		app.trace_base += u64(drop)
	}
	return seq
}

// row_index_locked maps a row identity to its current position, or -1 once the ring has trimmed
// it away. Caller holds app.mu.
fn (app &App) row_index_locked(seq u64) int {
	// Every comparison in u64, and the ghost range rejected BEFORE any narrowing: V's int is
	// 32 bits, so int(ghost_base - 0) wraps to a small number — the first paused emissions were
	// resolving to rows 0, 1, 2 and marking healthy pre-pause traffic as never sent.
	if seq >= ghost_base || seq < app.trace_base {
		return -1
	}
	off := seq - app.trace_base
	return if off < u64(app.trace.len) { int(off) } else { -1 }
}

// expire_pending_locked marks the rows whose frame never came back off the wire.
fn (mut app App) expire_pending_locked(now_ms f64) {
	for seq in app.taps.expire(now_ms) {
		i := app.row_index_locked(seq)
		if i >= 0 {
			app.trace[i].missed = true
		}
	}
}

// note_emit records a frame we are about to put on the wire: one row stating intent, and one
// pending echo. Called BEFORE the send — the RX thread can see the frame the instant the driver
// takes it, and a pending entry added afterwards would arrive too late to claim its own echo.
fn (mut app App) note_emit(iface string, chan_name string, origin string, f transport.CanFrame) u64 {
	t_ms := f64(time.ticks() - app.t0)
	app.mu.lock()
	// Under the lock, not before it. The dbc_readers drain covers the RX loops, which register
	// as lock-free readers; a tapped emitter — a simulated ECU, a diagnostic or flash worker
	// still draining after Stop — is not in that lifecycle, so resolving a name outside the
	// mutex could read app.dbs while a configuration edit replaces it.
	chn := if chan_name != '' { chan_name } else { app.chan_name_for(iface) }
	name := app.lookup_name(f.id, f.extended)
	app.expire_pending_locked(t_ms)
	// Paused: the emission is STILL tracked so its echo is recognised as ours — otherwise a
	// paused trace would feed our own frames to the E2E verifier as the ECU's and log them to
	// the recording twice — it simply has no row to confirm.
	mut seq := ghost_base + app.ghost_seq
	app.ghost_seq++
	if !app.paused {
		seq = app.push_row_locked(TraceRow{
			t_ms:   t_ms
			ch:     chn
			origin: origin
			id:     f.id
			ext:    f.extended
			rtr:    f.rtr
			name:   name
			data:   f.data.clone()
		})
		app.gcount[gkey(origin, chn, f.id, f.extended)]++
	}
	// ALWAYS record what we sent, on any backend that could echo — the emission is ours whether
	// or not a monitor happens to be open at this instant, and the sim emits its first frames
	// while the rx loops are still opening. Attributing those to the device under test breaks
	// the one promise this column makes.
	//
	// The monitor list rides along instead of gating: it says who could have seen this frame,
	// which decides who may claim it and whether "never came back" is evidence of anything. Asked
	// NOW rather than when the bus was opened, since a channel disabled mid-run takes its monitor
	// with it.
	if transport.echoes_own_sends(iface) {
		watchers := app.monitors_locked(iface)
		for missed in app.taps.note(seq, iface, f, t_ms, watchers) {
			i := app.row_index_locked(missed)
			if i >= 0 {
				app.trace[i].missed = true
			}
		}
	}
	// Rate-limited exactly like the rx path: a simulation emitting hundreds of frames a second
	// would otherwise post an event per frame and hold the UI at the traffic rate.
	now := time.ticks()
	if now - app.last_wake >= app.wake_ms {
		app.last_wake = now
		app.mu.unlock()
		vgui.wake()
	} else {
		app.mu.unlock()
	}
	return seq
}

// note_sent records a frame that actually reached the driver. Separate from note_emit so a send
// that FAILED never appears in a recording as though it had gone out.
fn (mut app App) note_sent(iface string, chan_name string, f transport.CanFrame) {
	app.mu.lock()
	if app.recording {
		// the LOGICAL channel, like the trace row: two channels can share one interface, and a
		// recording that says `vcan0` cannot be replayed back into the one that sent it
		chn := if chan_name != '' { chan_name } else { app.chan_name_for(iface) }
		app.rec << canlog.LogEntry{f64(time.ticks() - app.t0) / 1000.0, chn, f}
		// the same bounded window rx_loop keeps: with the echo now suppressed, a simulation's
		// own traffic arrives HERE, and this is the path a long recording actually grows on
		if app.rec.len > 200000 {
			app.rec = app.rec[app.rec.len - 200000..].clone()
		}
	}
	app.mu.unlock()
}

// retract_emit takes back an emission the driver refused. The row stays and is marked: the frame
// did not reach the wire, which is exactly what the mark says — but the pending record goes, so
// expiry does not report it a second time.
fn (mut app App) retract_emit(seq u64) {
	app.mu.lock()
	app.taps.forget(seq)
	i := app.row_index_locked(seq)
	if i >= 0 {
		app.trace[i].missed = true
	}
	app.mu.unlock()
}

// claim_echo_locked confirms the emission this frame is the echo of, and reports whether it
// found one. The matching rules (one-shot, oldest first, width-exact) and why they are what they
// are live in modules/wiretap. Caller holds app.mu.
fn (mut app App) claim_echo_locked(monitor int, iface string, f transport.CanFrame, t_ms f64) bool {
	app.expire_pending_locked(t_ms)
	app.taps.claim(monitor, iface, f, t_ms) or { return false }
	return true
}

// TapBus wraps a bus we EMIT on, so every frame leaving the app is attributed exactly once,
// wherever it was sent from. Stamping at the transport seam rather than at each call site means
// a new emitter cannot forget: simulated ECUs, the ISO-TP diagnostic servers, the tester's own
// sends and anything added later all pass through here.
struct TapBus {
mut:
	// Serialises note+send for ONE interface across every tapped bus on it. Registration order
	// has to be wire order: the matcher claims oldest-first, so if a thread is descheduled
	// between registering and transmitting, another thread's byte-identical frame can go out
	// first and have its echo credited to the wrong row — and then a failed or unechoed send
	// marks the successful row instead. A bus is serial anyway, so this costs nothing real.
	tx_mu  &sync.Mutex
	inner  transport.Bus
	app    &App
	iface  string
	chan_name string // logical channel, '' = derive from the interface
	origin string
}

fn (mut t TapBus) send(frame transport.CanFrame) ! {
	// What the WIRE will carry, not what the caller asked for: classic CAN takes 8 bytes and the
	// backends truncate silently, so a 12-byte Quick Send would be recorded whole, never match
	// its own 8-byte echo, and show up as a false BUS row plus an unconfirmed TST one.
	wire := transport.wire_frame(t.iface, frame)
	t.tx_mu.lock()
	defer {
		t.tx_mu.unlock()
	}
	// BEFORE the send: a monitor thread can see the frame the instant the driver takes it, and a
	// record added afterwards arrives too late to claim its own echo.
	seq := t.app.note_emit(t.iface, t.chan_name, t.origin, wire)
	// `wire`, not `frame`: on a backend that would carry the extra bytes (inproc, udp) sending
	// the original makes the echo disagree with the record in the other direction.
	t.inner.send(wire) or {
		t.app.retract_emit(seq)
		return err
	}
	t.app.note_sent(t.iface, t.chan_name, wire)
}

fn (mut t TapBus) recv(timeout_ms int) !transport.CanFrame {
	return t.inner.recv(timeout_ms)
}

fn (mut t TapBus) close() {
	t.inner.close()
}

// open_tap opens a bus whose sends are attributed to `origin`.
// `chan_name` names the LOGICAL channel emitting, for the case where two channel entries share one
// physical interface: deriving it from the interface always picks the first, so the second
// channel's simulated nodes would show up attributed to its neighbour. '' = derive (the tester
// paths — generators, diagnostics, shell, flash, scripts — are not per-channel).
fn (app &App) open_tap_on(iface string, origin string, chan_name string) !transport.Bus {
	// The bitrate suffix is an OPEN-time detail of the VENDOR backends, not part of a bus's
	// identity: chan_name_for and the pending records both key on the logical name, so a caller
	// that already carries `pcan:…@250000` (the script engine's ChanInfo does) would otherwise
	// label its rows with the physical open string and split them from every other row on the
	// same bus. Only there: nothing else uses `@` as syntax, and `inproc:bench@A` is a bus NAME
	// — stripping it universally sent every emitter to a different hub than the monitor.
	// Identity is the CANONICAL address: `inproc` and `inproc:CAN` are one hub, and keying them
	// separately means a frame reaches the monitor but cannot claim its own record. The physical
	// open still takes the caller's spelling.
	logical := transport.canonical_iface(if transport.vendor_iface(iface) {
		iface.all_before('@')
	} else {
		iface
	})
	inner := transport.open(app.bitrate_iface(if transport.vendor_iface(iface) {
		iface.all_before('@')
	} else {
		iface
	}))!
	return &TapBus{
		tx_mu:  app.tx_mutex(logical)
		inner:  inner
		app:    unsafe { app }
		iface:     logical
		chan_name: chan_name
		origin:    origin
	}
}

fn (app &App) open_tap(iface string, origin string) !transport.Bus {
	return app.open_tap_on(iface, origin, '')
}

// tx_mutex returns the send lock for an interface, creating it on first use. One per interface:
// every tapped bus on the same wire shares it, so note+send stay in order relative to each other
// without coupling unrelated buses.
fn (app &App) tx_mutex(iface string) &sync.Mutex {
	mut a := unsafe { app }
	// tx_map_mu, NOT app.mu — see the field comment: a caller may already hold app.mu here.
	a.tx_map_mu.lock()
	defer {
		a.tx_map_mu.unlock()
	}
	if m := a.tx_mutexes[iface] {
		return m
	}
	m := &sync.Mutex{}
	m.init()
	a.tx_mutexes[iface] = m
	return m
}

// monitors_locked lists the rx_loops actually reading this interface — the sockets an echo could
// arrive at. The SAME predicate that decides which channels get an rx_loop —
// `enabled` alone counts an `off` or `replay` channel a generator may target, whose sends nothing
// could ever confirm. Caller holds app.mu.
fn (app &App) monitors_locked(iface string) []int {
	mut out := []int{}
	want := transport.canonical_iface(iface)
	for i, c in app.chans {
		if transport.canonical_iface(c.iface) == want && c.monitorable() && c.running {
			out << i
		}
	}
	return out
}

// tx sends a frame on the default TX bus (send_iface) and records it as a TX trace row.
fn (mut app App) tx(f transport.CanFrame) bool {
	return app.tx_on(app.send_iface, f)
}

// tx_bus_key identifies a tester bus by the CHANNEL that owns it as well as its interface: two
// channels can share one wire, and a tap opened without the name attributes every frame to
// whichever channel happens to be listed first.
fn tx_bus_key(chan_name string, iface string) string {
	// LENGTH-PREFIXED, so the key is injective. A plain 'a|b' is not: a channel named
	// 'A|inproc:X' on 'inproc:Y' and a channel 'A' on 'inproc:X|inproc:Y' produce the same
	// string, and the second would then transmit through the first one's tap — onto the wrong
	// virtual bus, attributed to the wrong channel. Both values are accepted by the project
	// editor and the inproc parser, so nothing upstream rules this out.
	return '${chan_name.len}:${chan_name}|${iface}'
}

// tx_on sends a frame on the bus `iface` (a channel iface) and records it as a TX row on
// that bus. Generators use this to fire on their own target bus rather than a single
// global send bus; `chan_name` is the owning channel, '' where the caller has no particular one.
fn (mut app App) tx_on(iface string, f transport.CanFrame) bool {
	return app.tx_on_chan('', iface, f)
}

fn (mut app App) tx_on_chan(chan_name string, iface string, f transport.CanFrame) bool {
	mut b := app.tx_buses[tx_bus_key(chan_name, iface)] or {
		// fall back to the anonymous tap for this wire — a Quick Send or a diagnostic path has
		// no owning channel, and a generator whose channel was renamed mid-run still transmits
		app.tx_buses[tx_bus_key('', iface)] or {
			app.notify('TX failed: no open bus for ${iface}')
			return false
		}
	}
	// The row, the recording and the pending echo are the tap's job (open_tap), so they happen
	// for every emitter rather than only for the ones that remember to log.
	b.send(f) or {
		app.notify('TX failed: ${err}')
		return false
	}
	app.mu.lock()
	app.tx_count++
	app.mu.unlock()
	return true
}

fn (mut app App) clear_trace() {
	app.mu.lock()
	app.reset_trace_locked()
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
	// Verify while building the rows. Entries arrive in time order and the project already
	// supplies the protection configuration, so a recording can be checked exactly as live
	// traffic is — otherwise a violation visible during a run vanished the moment it was saved
	// and reopened, and a capture taken elsewhere could not be checked at all.
	// A recording stores whatever label the writer used — the channel's display NAME for our
	// own live captures, and a bare 'can' from an MF4 import — never the project's interface
	// string. Keying the sets by iface alone therefore matched nothing and every imported frame
	// came back with an empty verdict, which is what the previous attempt at this did.
	mut verifiers := map[string]sim.VerifySet{}
	mut alias := map[string]string{} // recorded label -> project iface
	for sc in app.sims {
		// A DoIP entry carries no frames and no `verify:`, so it must not create a verifier set
		// for its interface: an empty one made `verifiers.len == 1` false and an unlabelled MF4
		// import stopped resolving to the single simulated bus.
		if sc.pch.is_doip() {
			continue
		}
		// Per ENTRY, from the CURRENTLY LOADED databases. Two things have to hold at once: an
		// entry must see only its own DBCs (an interface-wide merge let a same-named message on
		// a neighbour's database win, leaving this entry's id unchecked after reopening a
		// capture that was checked live), and unsaved editor changes must be reflected, since
		// app.dbs already drives naming and decoding everywhere else in the UI.
		live := merge_dbs_from(app.loaded_dbs_for(sc.db_paths))
		mut vs := verifiers[sc.iface] or { sim.VerifySet{} }
		// `verify:` ONLY — the ECU under test's messages, never our own.
		//
		// A candump log carries no direction, so a recording made while we were transmitting
		// replays our TX frames as if received. Checking a message the simulation itself sends
		// then reports false failures — worse when loopback puts the same frame in twice and
		// one counter value is checked as though it arrived twice. What the bench is asking
		// about is the other side's protection, and that is exactly what `verify:` describes.
		vs.merge_into(sim.verifiers_for(live, [], sc.verify)) // conflicts already reported at start

		verifiers[sc.iface] = vs
		alias[sc.iface] = sc.iface
		for c in app.chans {
			if c.iface == sc.iface {
				alias[c.name] = sc.iface
			}
		}
	}
	// A single simulated bus is unambiguous, so an unrecognised label (an MF4's 'can') resolves
	// to it rather than going unchecked. With several, a label we cannot place is left alone —
	// guessing which bus a frame came from would attach verdicts to the wrong sender.
	only := if verifiers.len == 1 { verifiers.keys()[0] } else { '' }
	app.mu.lock()
	app.reset_trace_locked()
	for e in entries {
		f := e.frame
		name := app.lookup_name(f.id, f.extended)
		mut viol := ''
		if !f.rtr {
			ifc := alias[e.iface] or { only }
			if mut vs := verifiers[ifc] {
				if k := vs.resolve(app.dbs_for(ifc), f.id, f.extended) {
					if mut ver := vs.by_key[k] {
						viol = ver.check(f.data).str()
						vs.by_key[k] = ver
					}
				}
				verifiers[ifc] = vs
			}
		}
		// REP, not BUS: these frames were never on this bench's wire. A candump log carries no
		// origin at all, so we cannot say whether a given line was the recorder's tester, its
		// simulation or the ECU — and claiming one would be a guess dressed as a fact.
		app.push_row_locked(TraceRow{
			t_ms:   (e.t_s - t0) * 1000.0
			ch:     e.iface
			origin: org_rep
			id:     f.id
			ext:    f.extended
			rtr:    f.rtr
			name:   name
			data:   f.data.clone()
			e2e:    viol
		})
		app.gcount[gkey(org_rep, e.iface, f.id, f.extended)]++
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
// merge_dbs delegates to candb.merge_files — the single implementation shared with the
// headless runner, which used to dedupe differently and so simulated a different catalogue.
fn merge_dbs(paths []string) candb.Database {
	return candb.merge_files(paths)
}

// build_node delegates to sim.from_project — the single implementation. This file, cmd/script
// and cmd/sim_startup_check each carried a byte-identical copy, so a change here (like adding
// end-to-end protection) reached the GUI and silently skipped the headless runner CI uses.
fn build_node(db candb.Database, cfg project.NodeCfg) sim.SimEcu {
	return sim.from_project(db, cfg)
}

// sim_loop runs a channel's simulated ECUs on its bus: emit cyclic frames + answer
// request/response rules. Driver-free on inproc:, real on vcan0/can0.
fn sim_loop(app &App, sc SimCfg) {
	a := unsafe { app }
	mut bus := app.open_tap_on(sc.iface, org_sim, sc.pch.name) or {
		eprintln('sim ${sc.iface}: ${err}')
		return
	}
	mut engine := sim.Engine{}
	// Alive counters for the whole run, not just across one rebuild: an ECU switched OFF leaves
	// the engine, so state kept only in the previous engine is lost and switching it back on
	// restarts its counter at zero — a backward jump a checking receiver rejects.
	mut counters := map[string]int{}
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
			engine.save_counters(mut counters) // fold the outgoing engine's counts in first
			engine = sim.Engine{}
			for n in sc.nodes {
				if enabled[sim_key(sc.pch, n.name)] or { true } {
					engine.ecus << build_node(sc.db, n)
				}
			}
			engine.restore_counters(counters)
		}
		// ONE fault source, the module's table — the same one Lua writes through sim.fault().
		// The panel used to write a map on App that only the panel read, so a script launched
		// from the Script panel reported success and changed nothing on the bus.
		sim.apply_injected(sc.iface, mut engine)
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
		// Resolve emissions whose echo never came. Expiry is otherwise driven only by the next
		// emission or the next received frame, so on a bus that falls silent — a disconnected
		// bench, the very case the mark is for — the last rows stayed unresolved forever.
		a.mu.lock()
		a.expire_pending_locked(f64(time.ticks() - a.t0))
		a.mu.unlock()
		time.sleep(8 * time.millisecond)
	}
}

// diag_server_loop runs the native UDS server (mirror of the tester: rx 0x7E0, tx 0x7E8)
// so the Diagnostics panel + Lua scripts work driver-free against simulated channels.
// uds_node_loop answers one simulated ECU's diagnostic requests on its own addresses.
fn uds_node_loop(app &App, pch project.Channel, iface string, name string, rx u32, tx u32, ext bool, srv uds.Server) {
	a := unsafe { app }
	mut s := srv
	key := sim_key(pch, name)
	mut ch := &isotp.SoftChannel(unsafe { nil })
	mut open := false
	defer {
		if open {
			ch.close()
		}
	}
	for a.running {
		a.mu.lock()
		on := a.sim_enabled[key] or { true }
		a.mu.unlock()
		if !on {
			// CLOSE it, do not merely stop answering. Two things go wrong otherwise, and the
			// previous two attempts each fixed one: leaving recv running answers a First Frame
			// with Flow Control, so the "offline" ECU is still visible on the wire; and merely
			// skipping recv leaves requests queued on the open channel, which are answered
			// late once the ECU comes back. A closed channel does neither.
			if open {
				ch.close()
				open = false
			}
			time.sleep(50 * time.millisecond)
			continue
		}
		if !open {
			// on a TAPPED bus: an ISO-TP response is several CAN frames, and a simulated ECU
			// answering diagnostics must be attributed like any other thing we transmit.
			// pch: this node's OWN channel — two entries can share one interface, and the
			// simulated ECUs of the second must not be attributed to the first.
			tapped := a.open_tap_on(iface, org_sim, pch.name) or {
				time.sleep(200 * time.millisecond)
				continue
			}
			ch = isotp.on_bus(tapped, a.bitrate_iface(iface), tx, rx, ext) or {
				time.sleep(200 * time.millisecond)
				continue
			}
			open = true
		}
		req := ch.recv(50) or { continue }
		resp := s.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
}

fn diag_server_loop(app &App, iface string) {
	a := unsafe { app }
	tapped := a.open_tap(iface, org_sim) or { return }
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), diag_rx_id, diag_tx_id, false) or {
		return
	}
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

// `gen` is the measurement run this loop belongs to. Without it, a Stop→Start inside the 200 ms
// receive timeout leaves the OLD loop running beside the new one on the same channel index: both
// see every frame, the first claims our emission for that index, and the second's copy is then
// classified as the device under test's — logged, recorded and verified as external traffic.
fn rx_loop(app &App, ci int, iface string, gen u64) {
	mut bus := app.open_transport(iface) or {
		eprintln('rx ${iface}: ${err}')
		mut a := unsafe { app }
		a.mu.lock()
		// Same generation guard as the teardown below: opening can fail slowly, so a PREVIOUS
		// run's failure can land after the new loop has opened and published readiness. Clearing
		// the flag then would leave the current run with a monitor nobody counts — every emission
		// after it recorded as having no watcher, and its echo read as the ECU's.
		if a.run_gen == gen {
			a.chans[ci].running = false
			a.chans[ci].spawning = false // release the guard, or it can never be re-enabled
		}
		a.mu.unlock()
		return
	}
	mut a := unsafe { app }
	a.mu.lock()
	// Only for the run we belong to. Opening a bus takes time, so a loop from the PREVIOUS run
	// can arrive here after a restart — and since the teardown below is generation-guarded, the
	// flag it set would stay true with nobody reading: note_emit would then count a watcher that
	// does not exist and mark healthy traffic as never having reached the wire.
	if a.run_gen != gen {
		a.mu.unlock()
		bus.close()
		return
	}
	// The bus is open: from here a frame we emit can actually come back to us, which is what
	// `running` promises to note_emit's "is anyone watching?" check.
	a.chans[ci].running = true
	a.chans[ci].spawning = false
	a.dbc_readers++ // this loop reads app.dbs lock-free (lookup_name per frame)
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.dbc_readers--
		a.mu.unlock()
	}
	chname := a.chans[ci].name
	// Built from the SAME `protect:` entries the simulation stamps with, so a project describes
	// each protected message once and both directions follow it. A separate "check this on
	// receive" declaration would let the two drift, and the drift would read as an ECU fault.
	// EVERY SimCfg on this interface, not the first. Two channel entries may share a bus — the
	// diagnostics setup already handles that — and stopping at the first meant later entries'
	// protected messages were never checked, or were checked against the wrong layout.
	mut verifiers := sim.VerifySet{}
	for sc in a.sims {
		if sc.iface != iface {
			continue
		}
		for w in verifiers.merge_into(sim.verifiers_for(sc.db, sc.nodes, sc.verify)) {
			a.notify('${iface}: ${w}')
		}
	}
	// the TraceRsp id is config-static (the manifest is only mutated while stopped, so it can't
	// change under a running RX loop) — resolve it once, not per frame in the hot path.
	rsp_id := a.manifest.frames.or_defaults().rsp
	for a.running && a.run_gen == gen && a.chans[ci].enabled {
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
		// Is this the echo of something WE just put on the wire? Every backend delivers our own
		// sends to the monitor's separate bus instance (transport.test_inproc_cross_delivery
		// pins it), so without this the tester and our simulated ECUs arrive here looking
		// exactly like the device under test. Claiming the echo CONFIRMS the row written at
		// emit instead of adding a second one, and keeps our own frames out of both the
		// recording and the E2E verifier — whose per-message counter would otherwise see one
		// message twice and report a jump the ECU never made.
		a.mu.lock()
		ours := a.claim_echo_locked(ci, transport.canonical_iface(iface), f, t_ms)
		a.mu.unlock()
		name := a.lookup_name(f.id, f.extended)
		// Verify protection on the way in. Done here, on the RX thread that already owns the
		// frame, because the check is stateful — it needs the previous counter for this id —
		// and a stateful check spread across draw calls would depend on what the user scrolled.
		mut viol := ''
		// Not our own echo (see above), and not remote frames: an RTR request carries NO payload, so the missing bytes read as
		// zero and a request on a protected id was labelled !CRC — or, repeated, !CNT stalled.
		// A verdict about bytes that were never sent says nothing about the sender.
		if !f.rtr && !ours {
			if k := verifiers.resolve(a.dbs_for(iface), f.id, f.extended) {
				if mut ver := verifiers.by_key[k] {
					v := ver.check(f.data)
					verifiers.by_key[k] = ver
					viol = v.str()
				}
			}
		}
		a.mu.lock()
		if !a.paused && !ours {
			a.push_row_locked(TraceRow{
				t_ms:   t_ms
				ch:     chname
				origin: org_bus
				id:     f.id
				ext:    f.extended
				rtr:    f.rtr
				name:   name
				data:   f.data.clone()
				e2e:    viol
			})
			a.gcount[gkey(org_bus, chname, f.id, f.extended)]++
			// The capture dump now arrives as an ISO-TP block on 0x7E5 (not raw per-record
			// frames): trace_dump_worker reassembles + decodes it on demand. The raw ISO-TP
			// frames still show in the trace table above.
		}
		// A TraceRsp (per core) reports the capture state + freeze CAUSE — the only way to tell a
		// trigger-frozen dump from a manual stop. Update it even while the table is paused: the
		// freeze status is independent of the row capture, and it's what you watch during a pause.
		if f.id == rsp_id && f.data.len >= 8 {
			a.trace_freeze = trace_rsp_status(telem.decode_trace_rsp(f.data))
		}
		if a.recording && !ours {
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
	// Only if this run is still the current one. A loop that exited because the generation moved
	// on would otherwise clear a flag the NEW loop just set, and every emission after that would
	// see no watcher: its echo classified as the device under test's, recorded twice and fed to
	// the verifier, while the monitor was in fact running the whole time.
	if a.run_gen == gen {
		a.chans[ci].running = false
		a.chans[ci].spawning = false
		// Whatever we emitted while this loop was the observer can no longer be answered by it.
		// Its records stay claimable (an echo may already be queued in the socket) but earn no
		// verdict: the watcher was removed, so silence proves nothing.
		//
		// Inside the generation guard: a stale loop exiting after a restart would otherwise
		// strip the CURRENT run's records for the same channel index — whose monitor is alive
		// and watching — and a genuinely missing frame would then retire without a mark.
		a.taps.drop_monitor(ci)
	}
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
	// Convenience: if a system.toml sits next to the project (the system_full layout),
	// load it into the System panel and open it — so the per-ECU dashboard is one click
	// away instead of a manual Browse/Load. Non-system projects (sim-demo) are unaffected.
	if path != '' {
		// The old project's system model is stale on EVERY successful switch — not only when
		// the new project happens to have a sibling. Leaving it set made draw_buses annotate
		// the new project's interfaces with the PREVIOUS system's ECUs (wrong topology), and
		// a malformed sibling would show the old nodes as if they were this project's. So
		// clear unconditionally, then autoload + open only on success (codex #65).
		app.sys = sysview.System{}
		app.sys_loaded = false
		app.sel_ecu = ''
		app.show_sys = false
		sys_cand := os.join_path(os.dir(path), 'system.toml')
		if os.is_file(sys_cand) {
			app.load_system(sys_cand)
			app.show_sys = app.sys_loaded
		}
	}
}

// set_project installs a parsed project (from a file, New, or a reload), resetting the
// session buffers and rebuilding the runtime view. path == '' marks an unsaved project.
// resolve_asset resolves a project-relative asset path (a DBC or manifest) against the
// project file's directory first, so a .blobnet's relative paths work regardless of the
// launch directory; it falls back to the path as-given (launch-dir relative) for projects
// that reference assets relative to the repo root. Absolute paths are used unchanged.
// resolve_asset delegates to project.resolve_asset — one implementation, shared with the
// headless runner, which had none and so loaded an empty database for any project kept outside
// the repository.
fn (app &App) resolve_asset(path string) string {
	return project.resolve_asset(os.dir(app.proj_path), path)
}

fn (mut app App) set_project(proj project.Project, path string) {
	// Warn HERE, not in load_project: this is the function that abandons the File tab's buffer
	// (via cfg_invalidate below), so every caller is covered — File ▸ New bypassed a warning
	// placed in load_project — and load_project's error path returns before reaching this, so
	// the log no longer claims text was discarded by a load that then failed.
	if app.cfg_text_dirty {
		app.notify('discarded unsaved Configuration ▸ File text from ${os.base(app.proj_path)}')
	}
	// A fault armed against the OLD project must not survive into a new one. Keys carry the
	// interface, node and message name, and a different project reusing all three would
	// silently start with frames dropped or corrupted — as if the tool were broken.
	sim.clear_all()
	app.cfg_invalidate() // a different project: the File tab must not keep the old one's text
	app.mu.lock()
	app.reset_trace_locked()
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
	// drop editor state carried over from the previous project — stale cfg_bufs would otherwise
	// be flushed into the newly loaded project by the next commit_cfg (same channel count = no
	// resync in draw_config); stale discovery results belong to the old machine view.
	app.cfg_bufs = []
	app.disc_list = []
	app.disc_tick = []
	app.mu.unlock()
	app.rebuild_from_proj()
}

// rebuild_from_proj derives the runtime view (chans, dbs, sims, senders, manifest, default
// selection) from app.proj. Called after a load and after any config/generator edit, so the
// live panels reflect the edited model. Must be called while stopped (no RX threads running).
fn (mut app App) rebuild_from_proj() {
	// this replaces app.dbs wholesale, so a pending endpoint edit must land first or it is
	// silently dropped along with the databases it referred to
	app.resolve_pending_bit_edit()
	proj := app.proj
	app.mu.lock()
	app.chans = []
	// rebuild runs for ordinary config ops too (add bus/DBC, adapter change) —
	// unsaved editor state must SURVIVE it: capture dirty in-memory databases
	// by path and restore them after the reload below
	mut dbc_keep := map[string]candb.Database{}
	for i, pth in app.dbs_paths {
		if app.dbc_ed.dirty[pth] {
			dbc_keep[pth] = app.dbs[i]
		}
	}
	keep_dirty := app.dbc_ed.dirty.clone()
	app.dbs = []
	app.dbs_paths = []
	app.dbs_by_iface = map[string][]candb.Database{}
	app.dbc_ed = DbcEd{} // selection indices go stale across a rebuild
	app.dbc_ed.dirty = keep_dirty.clone()
	app.sims = []
	app.senders = []
	app.gen_bufs = []
	app.has_manifest = false
	app.eth_someip = telem.SomeipIdent{}
	app.eth_method = 0
	app.manifest = telem.Manifest{}
	app.sel_id = -1
	app.mu.unlock()
	for ch in proj.channels {
		app.chans << Chan{
			name:         ch.name
			network:      ch.network
			adapter:      ch.adapter
			address:      ch.address
			iface:        ch.iface // the stable LOGICAL key (tx_buses/senders); @bitrate is added at open
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
			mut rp := app.resolve_asset(dbpath)
			rp = os.real_path(rp) // canonical: two spellings of one file are ONE db
			// a DBC attached to several channels loads ONCE — duplicate dbs
			// entries would let the editor mutate one copy while decode reads
			// another
			prev := app.dbs_paths.index(rp)
			if prev >= 0 {
				app.dbs_by_iface[ch.iface] << app.dbs[prev]
				continue
			}
			if rp in dbc_keep {
				// this file has unsaved editor changes: the IN-MEMORY version
				// is the truth, not the disk copy
				app.dbs << dbc_keep[rp]
				app.dbs_paths << rp
				app.dbs_by_iface[ch.iface] << dbc_keep[rp]
			} else if db := candb.load_dbc_file(rp) {
				app.dbs << db
				app.dbs_paths << rp // the editor saves back to this path
				app.dbs_by_iface[ch.iface] << db // scoped to this channel (generator picker)
			} else {
				eprintln('dbc ${rp}: ${err}')
			}
		}
		if ch.manifest != '' {
			// the FIRST manifest stays the global telemetry/trace one (its
			// consumers are CAN-channel-scoped); the eth RPC shell gets its
			// OWN slot from whichever channel manifest declares it — the two
			// roles must never displace each other in a mixed project
			if m := telem.load_manifest(app.resolve_asset(ch.manifest)) {
				// the global slot serves the CAN consumers (trace/shell-frame/
				// handler labels): the first NON-eth manifest owns it, and an
				// eth manifest (classified by its SOME/IP identity — an eth
				// image without a shell endpoint is still an eth image) holds
				// it only until a CAN one shows up
				if !app.has_manifest || (app.manifest.someip.service != 0 && m.someip.service == 0) {
					app.manifest = m
					app.has_manifest = true
				}
				if m.shell_method != 0 && app.eth_method == 0 {
					app.eth_someip = m.someip
					app.eth_method = m.shell_method
				}
			} else {
				// a load/validation failure must be SEEN — silently keeping an
				// earlier manifest reads as "no eth shell" with no reason
				eprintln('manifest ${ch.manifest}: ${err}')
			}
		}
		for s in ch.senders {
			app.senders << SenderRT{
				iface:  ch.iface
				chan:   ch.name
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
		// `verify:` alone is enough: a channel that simulates nothing and only WATCHES a real
		// bench still needs its verifiers built, which is the whole point of checking the ECU
		// under test's protection.
		// A DISABLED DoIP channel still gets an entry. Its supervisor exists whatever the tick
		// (start_doip_hosts runs over the project), so enabling it live brings the entity up —
		// and draw_sim renders app.sims only, so without this the ECU is running with no way to
		// switch it off. CAN keeps the old rule: nothing runs for it while it is disabled.
		// A disabled DoIP channel is kept ONLY so the Simulation panel can show its ECU (its
		// supervisor exists whatever the tick). It must not contribute a verifier entry: an
		// empty one made `verifiers.len == 1` false, and an unlabelled MF4 import stopped
		// resolving to the single simulated bus.
		keep_for_panel := ch.is_doip() && nodes.len > 0 && !ch.enabled
		if (ch.enabled || keep_for_panel) && (nodes.len > 0 || ch.verify.len > 0) {
			// resolve_asset like the database list above: raw paths here re-based the
			// simulator's DBCs onto the launch/bundle cwd, so an external project's
			// relative DBC fed the sim nothing (codex #63 r4)
			app.sims << SimCfg{
				iface:  ch.iface
				pch:    ch
				db:     merge_dbs(ch.databases.map(app.resolve_asset(it)))
				nodes:    nodes
				verify:   ch.verify
				db_paths: ch.databases.map(app.resolve_asset(it))
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
	// Capture any CALLER-supplied project path FIRST, absolutized against the caller's
	// cwd — the re-anchoring chdir below would otherwise re-base a relative argv/env
	// path under the bundle directory and fail to open it (codex #63 r3).
	mut proj_path := ''
	mut caller_supplied := false
	if env := os.getenv_opt('BLOBLY_PROJECT') {
		proj_path = env
		caller_supplied = true
	}
	if os.args.len > 1 && os.args[1].to_lower().ends_with('.blobnet') {
		// Explorer's `.blobnet` association launches `blobly_net.exe "<file>"` — without
		// this the association opened the app but silently ignored the chosen project.
		// to_lower: the Windows association matches extensions case-insensitively.
		proj_path = os.args[1]
		caller_supplied = true
	}
	if caller_supplied {
		proj_path = os.abs_path(proj_path)
	}
	// A file-association launch keeps the CALLER's working directory, so every
	// bundle-root-relative asset (projects/, dbc/, tests/, docs/, samples/) would miss.
	// Re-anchor to the executable's directory — but only when the cwd clearly isn't a
	// bundle/repo root already, so `v run` from the checkout keeps working unchanged.
	exe_dir := os.dir(os.executable())
	if !os.exists('projects') && os.exists(os.join_path(exe_dir, 'projects')) {
		os.chdir(exe_dir) or {}
	}
	if proj_path == '' {
		proj_path = 'projects/sim-demo.blobnet' // bundle-relative: resolved AFTER the anchor
	}
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
	app.shell_buf = mkbuf('', 128)
	app.eth_target_buf = mkbuf('', 64)
	app.flash_img_buf = mkbuf('', 256)
	app.flash_base_buf = mkbuf('08020000', 16)
	app.flash_req_buf = mkbuf('7B0', 12)
	app.flash_rsp_buf = mkbuf('7B8', 12)
	app.flash_ver_buf = mkbuf('1', 12)
	app.trace_filter_buf = mkbuf('', 64)
	app.trace_filter2_buf = mkbuf('', 64)
	app.symbol_filter_buf = mkbuf('', 64)
	app.log_path_buf = mkbuf('samples/demo.log', 256)
	app.doip_host_buf = mkbuf('127.0.0.1', 64)
	app.load_project(proj_path)
	println('blobly_net: ${app.proj_name} — ${app.chans.len} channel(s), ${app.dbs.len} DBC(s), manifest=${app.has_manifest}. Press Start.')

	// Headless self-test of the Configuration editor: drive the real methods (New → add bus →
	// edit fields → add DBC → Save As) and assert the written .blobnet round-trips. Exits after.
	// The editor's widgets can't be clicked under WSLg, so this smoke covers the logic instead.
	if os.getenv('BLOBLY_SELFTEST_CONFIG') != '' {
		selftest_config(mut app)
		return
	}

	if os.getenv('BLOBLY_SELFTEST_DBC') != '' {
		app.show_dbc = true
		if !vgui.init('blobly_net — selftest', 1500, 850, true) {
			eprintln('vgui.init failed')
			return
		}
		for frame in 0 .. 10 {
			vgui.frame_begin()
			if app.dbs.len > 0 {
				app.dbc_ed.db = 0
				if frame > 2 && app.dbs[0].messages.len > 0 {
					app.dbc_ed.msg = 0
				}
				if frame > 5 && app.dbs[0].messages.len > 0 && app.dbs[0].messages[0].signals.len > 0 {
					app.dbc_ed.sig = 0
				}
			}
			draw_dbc_editor(mut app)
			vgui.frame_end()
		}
		vgui.shutdown()
		println('selftest_dbc: ok')
		return
	}

	if !vgui.init('blobly_net — ${app.proj_name} (imgui/ImPlot)', 1500, 850, true) {
		eprintln('vgui.init failed')
		return
	}
	vgui.set_window_icon(32, 32, app_icon()) // replace the default placeholder window icon
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
		if n > 0 {
			n
		} else {
			30
		}
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
		app.poll_hotkeys()

		if app.show_buses {
			draw_buses(mut app, chans)
		}
		if app.show_sim {
			draw_sim(mut app)
		}
		if app.show_symbols {
			draw_symbols(mut app)
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
		if app.show_diag {
			draw_diag(mut app)
		}
		if app.show_shell {
			draw_shell(mut app)
		}
		if app.show_dbc {
			draw_dbc_editor(mut app)
		}
		if app.show_sys {
			draw_system(mut app)
		}
		if app.show_flash {
			draw_flash(mut app)
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
			for s in [100, 125, 150, 175] {
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
	// Unsaved FILE-tab text counts as modified too. It lives in its own buffer, so without this
	// the toolbar read clean while an edit sat waiting in a closed window.
	dirtymark := if app.dirty || app.cfg_text_dirty { ' ●' } else { '' }
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
		// each bus is a collapsible group, collapsed by default (### keeps the id stable if the
		// label changes)
		// id by channel, not interface: two channels on one interface collapsed into a single
		// imgui id, so expanding one expanded the other. Same substitution as sim_key.
		if !vgui.tree_node('${sc.iface}   (${sc.nodes.len})###simbus_${sc.pch.name}|${sc.iface}') {
			continue
		}
		for node in sc.nodes {
			// sim_key, not '<iface>:<node>': the panel writes what the CAN loop and the DoIP
			// supervisor read, so all three move together or a tick lands on a key nobody
			// consults. Channel identity is in the key because two channels can share an
			// interface string and a node name.
			key := sim_key(sc.pch, node.name)
			en := app.sim_enabled[key] or { true }
			nen := vgui.checkbox('##simen_${key}', en)
			if nen != en {
				app.mu.lock()
				app.sim_enabled[key] = nen
				app.sim_gen++
				app.mu.unlock()
			}
			vgui.same_line()
			// A shorthand node (project `simulate:`, e.g. from "Simulate the rest") carries NO
			// explicit config by design — build_node derives its frames from the DBC by
			// transmitter name. Printing "0 sig / 0 resp" for it reads as "this ECU sends
			// nothing", which is wrong and alarming; say where its behaviour comes from.
			// Protection is worth its own word in the header. It is invisible on the wire until
			// the ECU rejects a frame, so "is this node protected?" must be answerable without
			// opening the project file.
			// ASCII only: fonts are loaded without expanded glyph ranges, and the fallback
			// ProggyClean is ASCII-only, so a shield or an arrow renders as a missing-glyph box.
			prot := if node.protect.len > 0 { '  [P${node.protect.len}]' } else { '' }
			diag := if node.uds != none { '  [UDS]' } else { '' }
			// Protection is orthogonal to BEHAVIOUR, in the label exactly as in from_project: a
			// protect-only node still transmits its DBC-derived frames, so calling it
			// "0 sig / 0 resp" recreates the "this ECU sends nothing" reading the line above
			// exists to avoid. The protection count is appended to whichever label applies.
			hdr := if node.signals.len == 0 && node.responses.len == 0 {
				'${node.name}  (frames derived from the DBC)${prot}${diag}###${key}'
			} else {
				'${node.name}  (${node.signals.len} sig / ${node.responses.len} resp)${prot}${diag}###${key}'
			}
			if vgui.tree_node(hdr) {
				for g in node.signals {
					vgui.text('    ${g.signal}: ${g.typ}')
				}
				for r in node.responses {
					vgui.text('    ${r.request} -> ${r.response}')
				}
				// Protection that matches nothing is applied nowhere while the count above still
				// claims it is on. Say so here, next to the claim.
				if u := node.uds {
					mut what := 'rx 0x${u.rx:X} / tx 0x${u.tx:X}'
					if u.dids.len > 0 {
						what += ', ${u.dids.len} DID(s)'
					}
					if u.dtcs.len > 0 {
						what += ', ${u.dtcs.len} DTC(s)'
					}
					vgui.text('    [UDS] ${what}')
				}
				for w in sim.validate_cfg(sc.db, node) {
					vgui.text_dim('    ! ${w}')
				}
				// Fault injection, per message. Only messages the DBC says this node sends,
				// because a fault on a frame it never transmits does nothing and reads as a
				// broken feature rather than a misconfiguration.
				for m in sc.db.messages_from(node.name) {
					cur := sim.injected_fault(sc.iface, node.name, m.name)
					lbl := match cur.kind {
						.none_ { 'normal' }
						.drop { 'DROP' }
						.bad_crc { 'BAD CRC' }
						.freeze_ctr { 'FROZEN CTR' }
						.out_of_range { 'OUT OF RANGE' }
					}
					// Only offer what can take effect on THIS message. bad_crc without a
					// configured checksum changes no bits, and out_of_range needs a signal with
					// an illegal value — offering either would show a fault the bus never sees.
					has_crc := node.protect.any(it.message == m.name && it.crc != '')
					has_ctr := node.protect.any(it.message == m.name && it.counter != '')
					mut oor_sig := ''
					mut mprot := sim.E2e{}
					for pr in node.protect {
						if pr.message == m.name {
							mprot = sim.E2e{ counter: pr.counter, crc: pr.crc, profile: pr.profile }
						}
					}
					for sg in m.signals {
						if sim.can_force_out_of_range(m, sg.name, mprot) {
							oor_sig = sg.name
							break
						}
					}
					mut kinds := ['normal', 'drop']
					mut kind_of := [sim.FaultKind.none_, .drop]
					// Independently: a counter-only entry can be frozen but has no checksum to
					// corrupt, and a crc-only entry the reverse. Gating both on the checksum
					// offered one fault that changes nothing and hid one that works.
					if has_crc {
						kinds << 'bad crc'
						kind_of << .bad_crc
					}
					if has_ctr {
						kinds << 'freeze counter'
						kind_of << .freeze_ctr
					}
					if oor_sig != '' {
						kinds << 'out of range (${oor_sig})'
						kind_of << .out_of_range
					}
					mut sel := 0
					for ki, kk in kind_of {
						if kk == cur.kind {
							sel = ki
							break
						}
					}
					vgui.text('    ${m.name}: ${lbl}')
					vgui.same_line()
					nsel := vgui.combo('##fault_${sc.iface}_${node.name}_${m.name}', kinds, sel)
					if nsel != sel && nsel < kind_of.len {
						sim.inject(sc.iface, node.name, m.name, sim.Fault{
							kind:   kind_of[nsel]
							signal: if kind_of[nsel] == .out_of_range { oor_sig } else { '' }
						})
					}
				}
				for pr in node.protect {
					mut what := []string{}
					if pr.counter != '' {
						what << 'counter ${pr.counter}'
					}
					if pr.crc != '' {
						what << '${pr.profile} -> ${pr.crc}'
					}
					if id := pr.data_id {
						what << 'id 0x${id:02X}' // shown even when 0: an explicit zero id is
						// not the same as none, and telling them apart is the whole point when
						// you are staring at a checksum mismatch
					}
					vgui.text('    [P] ${pr.message}: ${what.join(', ')}')
				}
				vgui.tree_pop()
			}
		}
		vgui.tree_pop()
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
// Separators are normalized to `/` first, so it also works for the file browser's
// backslash paths on Windows (and the stored `.blobnet` path stays portable).
fn rel_path(p string) string {
	np := p.replace('\\', '/')
	cwd := os.getwd().replace('\\', '/')
	if np.starts_with(cwd + '/') {
		return np[cwd.len + 1..]
	}
	return np
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
	} else if target == 'system' {
		'.toml'
	} else if target == 'flash' {
		'.img' // match_ext also lets .bin through for this filter
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
	} else if t == 'system' {
		app.load_system(path)
	} else if t == 'flash' {
		app.flash_img_buf = mkbuf(path, 256)
	}
}

// load_system loads a blobly_emb system.toml into the read-only System view.
// restbus_from_system configures the REST BUS for one ECU under test: every OTHER node that
// shares a bus with it becomes a simulated ECU on the matching channel. This is the single-ECU
// bench workflow — you develop one ECU, and the rest of its buses have to be alive or it faults.
// The system model already knows who sits on which bus, and system.toml node names are the DBC
// transmitter (BU_) names, so the simulator can derive each node's frames straight from the DBC.
// Writes into the PROJECT (channel.simulate) so it survives a rebuild and can be saved.
// Returns (simulated nodes, channels touched).
fn (mut app App) restbus_from_system(sut string) (int, int) {
	mut nodes := 0
	mut chans_hit := 0
	mut sut_dropped := 0    // rich `nodes:` entries removed because they configured the SUT itself
	mut chans_disabled := 0 // matching channels skipped because the project has them disabled
	// the system buses the ECU under test sits on
	mut sut_buses := []string{}
	for n in app.sys.nodes {
		if n.name == sut {
			sut_buses = n.buses.clone()
			break
		}
	}
	for sb in app.sys.buses {
		if sb.name !in sut_buses {
			continue
		}
		mut others := []string{}
		for n in app.sys.nodes {
			if n.name != sut && sb.name in n.buses {
				others << n.name
			}
		}
		if others.len == 0 {
			continue
		}
		for ci, ch in app.proj.channels {
			if ch.iface != sb.iface {
				continue
			}
			// A disabled channel gets no SimCfg from rebuild_from_proj, so writing its
			// simulate list and counting it as configured reports success for something
			// that will not run (codex #65 r4).
			if !ch.enabled {
				// Skipping is right — rebuild_from_proj makes no SimCfg for a disabled channel —
				// but skipping SILENTLY made a partial setup report success and an all-disabled
				// one claim no interface matched (codex #65 r5). Count it and say so.
				chans_disabled++
				continue
			}
			// all_nodes() merges the rich `nodes:` configs with the `simulate:` shorthand, so
			// replacing `simulate` does NOT stop a SUT that is also explicitly configured —
			// the ECU under test would be simulated against itself, two talkers on one bus.
			// Drop its config here and say so, rather than silently leaving it live.
			before := app.proj.channels[ci].nodes.len
			app.proj.channels[ci].nodes = app.proj.channels[ci].nodes.filter(it.name != sut)
			sut_dropped += before - app.proj.channels[ci].nodes.len
			app.proj.channels[ci].simulate = others.clone()
			chans_hit++
			nodes += others.len
		}
	}
	if chans_hit > 0 {
		// Generators are edited live in app.senders/gen_bufs and only reach app.proj through
		// this sync; rebuilding without it recreates them from the stale project model and
		// silently drops unsaved edits, while still marking the project dirty. Both other
		// rebuild_from_proj call sites sync first — this one did not (codex #65 r5).
		app.sync_senders_into_proj()
		app.rebuild_from_proj()
		app.dirty = true
	}
	if sut_dropped > 0 {
		app.notify('restbus: dropped ${sut_dropped} configured simulation entr(ies) for ${sut} — it is the ECU under test, not a simulated node')
	}
	if chans_disabled > 0 {
		app.notify('restbus: ${chans_disabled} matching channel(s) are DISABLED and were skipped — enable them in Configure, or the rest bus stays silent')
	}
	return nodes, chans_hit
}

fn (mut app App) load_system(path string) {
	if path.trim_space() == '' {
		app.notify('no system.toml path — type one or use Browse')
		return
	}
	if sy := sysview.load(path) {
		app.sys = sy
		app.sys_loaded = true
		app.sys_path_buf = mkbuf(path, path.len + 64)
		app.notify('system: ${sy.nodes.len} node(s), ${sy.buses.len} bus(es), ${sy.signals.len} cross-node signal(s)')
	} else {
		app.notify('system load failed: ${err}')
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
	} else if app.fb_target == 'system' {
		'Open system.toml'
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
	if app.fb_ext == '.img' && n.ends_with('.bin') {
		return true // firmware picker: wrapped .img preferred, raw .bin allowed
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

// iface_desc renders a short description for a transport-discovered interface (used for the
// vendor/virtual entries that don't come with the rich /sys hardware label).
fn iface_desc(f transport.Iface) string {
	mut d := match f.kind {
		'vcan' {
			'virtual CAN'
		}
		'udp' {
			'software bus'
		}
		'inproc' {
			'in-process simulation'
		}
		'can' {
			if f.name != '' && f.name != f.iface { f.name } else { 'CAN' }
		}
		else {
			f.kind
		}
	}

	if f.bitrate > 0 {
		d += ' · ${f.bitrate}'
	}
	return d
}

// discover_all builds the Discover list, marking entries already in the project. Two sources
// are merged and de-duplicated by (adapter,address):
//   1. Linux /sys CAN interfaces — finds interfaces that are DOWN (which `ip -json`, and thus
//      transport.list_interfaces on Linux, omits) and enriches them with the USB product /
//      bus path / link state. Empty off Linux.
//   2. transport.list_interfaces() — the platform-gated enumerator that adds Windows vendor
//      hardware (PCAN/Kvaser via their DLLs) plus the driver-free software buses (UDP/SIM).
fn (app &App) discover_all() []DiscoveredIface {
	mut out := []DiscoveredIface{}
	mut seen := map[string]bool{}
	for ci in read_can_ifaces() {
		adapter := if ci.is_vcan { 'vcan' } else { 'socketcan' }
		seen[project.compose_iface(adapter, ci.name)] = true
		out << DiscoveredIface{
			adapter: adapter
			address: ci.name
			desc:    ci.desc
			added:   app.iface_added(adapter, ci.name)
		}
	}
	for f in transport.list_interfaces() or { transport.virtual_ifaces() } {
		adapter, address := project.decompose_iface(f.iface)
		key := project.compose_iface(adapter, address)
		if key in seen {
			continue
		}
		seen[key] = true
		out << DiscoveredIface{
			adapter: adapter
			address: address
			desc:    iface_desc(f)
			added:   app.iface_added(adapter, address)
		}
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

// parse_u16_hex reads a 16-bit address ("0x"-hex or bare hex). Any malformed input — empty,
// a bare "0x", a non-hex character, or a value above 16 bits — returns `deflt` (the previous
// value) rather than silently accepting a wrong address like 0x0000.
fn parse_u16_hex(s string, deflt u16) u16 {
	mut t := s.trim_space().trim('"')
	if t.starts_with('0x') || t.starts_with('0X') {
		t = t[2..]
	}
	if t == '' {
		return deflt
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
			return deflt // non-hex character — keep the previous value
		}
		v = v * 16 + d
		if v > 0xFFFF {
			return deflt // out of 16-bit range — keep the previous value
		}
	}
	return u16(v)
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
	app.rebuild_preserving_senders()
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
	removed_iface := app.proj.channels[i].iface
	app.proj.channels.delete(i)
	// drop generator bus-overrides that pointed at the removed bus, so start() won't reopen and
	// transmit on an interface that's no longer configured (they fall back to their own channel).
	for si in 0 .. app.senders.len {
		if app.senders[si].sender.bus == removed_iface {
			app.senders[si].sender.bus = ''
		}
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

// set_adapter changes a bus's transport backend, recomposing its iface and keeping the
// can/doip protocol coherent.
fn (mut app App) set_adapter(i int, a string) {
	if i < 0 || i >= app.proj.channels.len {
		return
	}
	old_iface := app.proj.channels[i].iface
	app.proj.channels[i].adapter = a
	if a == 'doip' {
		app.proj.channels[i].typ = 'doip'
	} else if app.proj.channels[i].typ == 'doip' {
		app.proj.channels[i].typ = 'can'
	}
	app.proj.channels[i].iface = project.compose_iface(a, vgui.buf_str(app.cfg_bufs[i].address_buf))
	app.rebind_senders(old_iface, app.proj.channels[i].iface) // keep this bus's generators bound
	app.dirty = true
	app.rebuild_preserving_senders()
}

// rebuild_preserving_senders folds unsaved Generators-panel edits (gen_bufs id/data) into
// app.proj before rebuilding the runtime view — so a structural config change (add/remove
// bus/DBC, adapter/mode) doesn't discard them when rebuild_from_proj repopulates senders from
// the model. Use this instead of rebuild_from_proj for edits made while the editor is open.
fn (mut app App) rebuild_preserving_senders() {
	app.sync_senders_into_proj()
	app.rebuild_from_proj()
}

// rebind_senders repoints a channel's flattened generators from an old iface to a new one, so
// editing a bus address doesn't orphan them: sync_senders_into_proj groups senders by iface
// (and firing opens tx_buses[iface]), so a stale SenderRT.iface would drop all of a renamed
// bus's generators on the next Save/Start. Also follows explicit per-sender bus overrides.
fn (mut app App) rebind_senders(old_iface string, new_iface string) {
	if old_iface == new_iface || old_iface == '' {
		return
	}
	for si in 0 .. app.senders.len {
		if app.senders[si].iface == old_iface {
			app.senders[si].iface = new_iface
		}
		if app.senders[si].sender.bus == old_iface {
			app.senders[si].sender.bus = new_iface
		}
	}
}

fn (mut app App) set_protocol(i int, pr string) {
	app.proj.channels[i].typ = pr
	app.proj.channels[i].fd = pr == 'canfd'
	app.dirty = true
}

fn (mut app App) set_mode(i int, md string) {
	app.proj.channels[i].mode = project.mode_from(md)
	app.dirty = true
	app.rebuild_preserving_senders()
}

fn (mut app App) add_dbc(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	app.proj.channels[ci].databases << rel_path(path)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
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
	app.rebuild_preserving_senders()
}

fn (mut app App) set_manifest(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	app.proj.channels[ci].manifest = rel_path(path)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

// draw_config is the dedicated Configuration editor (File → Configure…): add/edit/remove
// buses, pick adapters, attach DBCs. Stopped-only; Save persists to the .blobnet.
fn draw_config(mut app App) {
	vgui.set_next_window(120, 90, 720, 620)
	was_open := app.show_config
	vis, op := vgui.begin_closable('Configuration', app.show_config)
	app.show_config = op
	if was_open && !op && !app.running && app.dirty {
		app.apply_edits() // closed via the [X] with unsaved edits — fold them into model + runtime
	}
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
	// Two views of one configuration: the structured bus editor, and the file itself. The file
	// tab exists because most of what a project says — simulated ECUs, generators, responses,
	// protection, per-ECU UDS, verification, senders — has no structured editor at all, so
	// without it those are only reachable by leaving the app.
	if vgui.small_button(if app.cfg_tab == 0 { '[ Buses ]' } else { '  Buses  ' }) {
		app.cfg_tab = 0
	}
	vgui.same_line()
	if vgui.small_button(if app.cfg_tab == 1 { '[ File ]' } else { '  File  ' }) {
		app.cfg_tab = 1
		app.load_cfg_text()
	}
	vgui.separator()
	if app.cfg_tab == 1 {
		app.load_cfg_text() // every frame: a no-op while typing, and correct after a switch
		app.draw_config_text()
		vgui.end()
		return
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
		if app.dirty {
			app.apply_edits() // fold unsaved edits into the model + runtime view on close
		}
	}
	if app.dirty || app.cfg_text_dirty {
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
		old_iface := app.proj.channels[i].iface
		app.proj.channels[i].address = vgui.buf_str(app.cfg_bufs[i].address_buf)
		app.proj.channels[i].iface = project.compose_iface(ch.adapter, app.proj.channels[i].address)
		app.rebind_senders(old_iface, app.proj.channels[i].iface) // keep this bus's generators bound
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

// help_docs lists the Help pages: the built-in quick start (empty path) plus real markdown docs
// loaded from disk. Paths are resolved relative to the working dir (the app chdir's to its
// bundle dir at startup, so these resolve in a distributed build too).
struct HelpDoc {
	title string
	path  string // '' = built-in quick_ref_md
}

const help_docs = [
	HelpDoc{'Quick start', ''},
	HelpDoc{'Simulation', 'docs/simulation.md'},
	HelpDoc{'Scripting', 'docs/scripting.md'},
	HelpDoc{'Project editing', 'docs/project_editing.md'},
	HelpDoc{'CAN hardware', 'docs/can_hardware.md'},
	HelpDoc{'Ethernet / DoIP', 'docs/doip.md'},
	HelpDoc{'Known issues', 'docs/known_issues.md'},
]

const quick_ref_md = '# Blobly Net

An imgui/ImPlot CAN/automotive bus tester. **Start/Stop** runs the measurement on the
enabled channels; the activity bar (far left) and the **View** menu toggle panels; **Settings**
sets the frame rate and UI scale.

## Panels

- **Buses** — channel enable and live state
- **Cfg / Configuration** — edit the project: buses in a form, or the `.blobnet` as text
- **Simulation** — in-process simulated ECUs (driver-free)
- **Symbols** — DBC message / signal browser (searchable)
- **Trace / Trace (filter)** — live frames, all or grouped, filterable, per-bus
- **Signals** — decode the selected message; add signals to Graphics
- **Graphics** — live ImPlot signal plots (multi-axis, real values)
- **Trace Chart** — telemetry handler swimlane
- **Shell** — command line on the target (over CAN; Up/Down = history)
- **Generators** — quick send + saved senders (manual / on-key / cyclic)
- **Diagnostics / DoIP** — UDS diagnostics and DoIP discovery
- **Script** — run a Lua test file

## Toolbar

- **Pause** freezes the trace, **Clear** empties it, **Record** writes `recording.log`
- **Open** loads a candump `.log` or ASAM `.mf4` into the trace

## Generators

A generator is a reusable send block. Give it a single **key** and set its trigger to
**on key** to fire it from the keyboard while running. **cyclic** auto-repeats at its period.
Use **Quick send** at the top for an ad-hoc one-shot without saving a generator.
'

// help_style + help_script are the Help page CSS/JS. Raw strings (single-quote delimited) so the
// double quotes inside are literal; kept free of single quotes so they never terminate the string.
const help_style = r'
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;line-height:1.6;color:#1b1b1b;background:#fff}
#wrap{display:flex;min-height:100vh}
nav{width:250px;flex:none;border-right:1px solid #e2e2e2;padding:1rem;height:100vh;position:sticky;top:0;overflow:auto}
nav h2{font-size:1rem;margin:.2rem 0 .8rem}
#q{width:100%;padding:.5em .6em;border:1px solid #ccc;border-radius:6px;font-size:.95em;margin-bottom:.8rem}
ul#nav{list-style:none;margin:0;padding:0}
.navitem{padding:.4em .6em;border-radius:6px;cursor:pointer;font-size:.95em}
.navitem:hover{background:#f0f0f0}
.xref{color:#0078d4;cursor:pointer;text-decoration:underline}
.navitem.active{background:#0078d4;color:#fff}
#results{margin-top:.6rem}
.result{padding:.5em .6em;border-radius:6px;cursor:pointer;font-size:.82em;border:1px solid #eee;margin-bottom:.4rem}
.result:hover{background:#f5f5f5}
.result .rp{font-weight:600;color:#0078d4;margin-bottom:.2em}
main{flex:1;max-width:900px;padding:1.5rem 2.5rem;overflow:auto}
.page.hidden{display:none}
h1,h2,h3{line-height:1.25;margin-top:1.5em}
h1{border-bottom:2px solid #0078d4;padding-bottom:.2em;margin-top:.2em}
h2{border-bottom:1px solid #ddd;padding-bottom:.2em}
code{background:#f3f3f3;padding:.1em .35em;border-radius:3px;font-size:.92em}
pre{background:#f6f8fa;padding:1em;border-radius:6px;overflow:auto}
pre code{background:none;padding:0}
a{color:#0078d4}
hr{border:0;border-top:1px solid #ddd;margin:2.5em 0}
table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:.4em .6em}
mark{background:#ffe066;color:inherit;border-radius:2px}
@media(prefers-color-scheme:dark){
body{color:#d4d4d4;background:#1e1e1e}
nav{border-color:#333}
#q{background:#2d2d2d;border-color:#444;color:#d4d4d4}
.navitem:hover{background:#2a2a2a}
.result{border-color:#333}.result:hover{background:#2a2a2a}
code{background:#2d2d2d}pre{background:#252526}
h2,hr,td,th{border-color:#3a3a3a}a{color:#4ea1ff}
mark{background:#7a5c00;color:#fff}
}
'

const help_script = r'
(function(){
var pages=[].slice.call(document.querySelectorAll(".page"));
var navitems=[].slice.call(document.querySelectorAll(".navitem"));
var results=document.getElementById("results");
var q=document.getElementById("q");
var content=document.getElementById("content");
function show(idx){
pages.forEach(function(p,i){p.classList.toggle("hidden",i!==idx);});
navitems.forEach(function(n,i){n.classList.toggle("active",i===idx);});
}
document.addEventListener("click",function(e){var x=e.target.closest?e.target.closest("[data-goto]"):null;if(!x)return;e.preventDefault();clearMarks();results.textContent="";q.value="";show(parseInt(x.getAttribute("data-goto")));content.scrollTop=0;});
navitems.forEach(function(n){n.addEventListener("click",function(){clearMarks();results.textContent="";q.value="";show(parseInt(n.getAttribute("data-page")));content.scrollTop=0;});});
function clearMarks(){var ms=[].slice.call(document.querySelectorAll("mark"));ms.forEach(function(m){var t=document.createTextNode(m.textContent);var par=m.parentNode;par.replaceChild(t,m);par.normalize();});}
function highlight(el,term){var first=null;var low=term.toLowerCase();var nodes=[];var w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);while(w.nextNode())nodes.push(w.currentNode);nodes.forEach(function(node){var txt=node.nodeValue;var lo=txt.toLowerCase();var idx=lo.indexOf(low);if(idx<0)return;var frag=document.createDocumentFragment();var pos=0;while(idx>=0){frag.appendChild(document.createTextNode(txt.slice(pos,idx)));var m=document.createElement("mark");m.textContent=txt.slice(idx,idx+term.length);frag.appendChild(m);if(!first)first=m;pos=idx+term.length;idx=lo.indexOf(low,pos);}frag.appendChild(document.createTextNode(txt.slice(pos)));node.parentNode.replaceChild(frag,node);});return first;}
function search(term){clearMarks();results.textContent="";if(!term){return;}var low=term.toLowerCase();var any=false;pages.forEach(function(p,i){var txt=p.textContent;var lo=txt.toLowerCase();var idx=lo.indexOf(low);if(idx<0)return;any=true;var c=0,k=idx;while(k>=0){c++;k=lo.indexOf(low,k+term.length);}var st=Math.max(0,idx-30);var snip=(st>0?"…":"")+txt.slice(st,idx+term.length+50).replace(/\s+/g," ").trim()+"…";var div=document.createElement("div");div.className="result";var rp=document.createElement("div");rp.className="rp";rp.textContent=navitems[i].textContent+" ("+c+")";div.appendChild(rp);div.appendChild(document.createTextNode(snip));div.addEventListener("click",function(){results.textContent="";show(i);var m=highlight(p,term);content.scrollTop=0;if(m)m.scrollIntoView({block:"center"});});results.appendChild(div);});if(!any){var d=document.createElement("div");d.className="result";d.textContent="No matches";results.appendChild(d);}}
q.addEventListener("input",function(){search(q.value.trim());});
})();
'

// help_text returns a Help doc body, reading + caching the file on first access.
fn (mut app App) help_text(path string) string {
	if path == '' {
		return quick_ref_md
	}
	if path in app.help_cache {
		return app.help_cache[path]
	}
	txt := os.read_file(path) or { 'Could not load `${path}`.\n\nIt may not ship in this build.' }
	app.help_cache[path] = txt
	return txt
}

// rewrite_help_links makes relative `*.md` links usable inside the single-file Help page.
//
// Help renders every page into ONE html file written to a cache directory, so a link like
// `scripting.md` resolves beside that cached file and opens nothing. Three shipped pages
// already carried such links before the Simulation manual added more.
//
//   - target IS a Help page  -> an in-page jump (`data-goto`), handled by the nav script
//   - target is NOT          -> the link is dropped and its text kept, because a dead link
//                               that looks live is worse than plain text
fn rewrite_help_links(html string) string {
	mut base_to_idx := map[string]int{}
	for i, d in help_docs {
		if d.path != '' {
			base_to_idx[d.path.all_after_last('/')] = i
		}
	}
	mut out := html
	for _ in 0 .. 64 { // bounded: each pass rewrites one link, and pages have few
		start := out.index('<a href="') or { break }
		qs := start + '<a href="'.len
		qe := out.index_after('"', qs) or { break }
		href := out[qs..qe]
		gt := out.index_after('>', qe) or { break }
		close := out.index_after('</a>', gt) or { break }
		text := out[gt + 1..close]
		mut repl := ''
		if href.ends_with('.md') && !href.starts_with('http') {
			if idx := base_to_idx[href.all_after_last('/')] {
				repl = '<span class="xref" data-goto="${idx}">${text}</span>'
			} else {
				repl = text // not a Help page: keep the words, drop the dead link
			}
		} else {
			// leave it alone, but mark it so the scan moves past it
			repl = '<a data-ok href="${href}"' + out[qe + 1..close] + '</a>'
		}
		out = out[..start] + repl + out[close + '</a>'.len..]
	}
	return out.replace('<a data-ok ', '<a ')
}

// help_html renders the Help docs into ONE self-contained, static HTML page: a sidebar of pages,
// full-text search across them, and each doc rendered via vlang/markdown (headings, code, tables).
// Pure client-side JS — no web server. Written once, opened as a file:// URL.
fn (mut app App) help_html() string {
	mut nav := strings.new_builder(1024)
	mut pages := strings.new_builder(65536)
	for i, d in help_docs {
		active := if i == 0 { ' active' } else { '' }
		hidden := if i == 0 { '' } else { ' hidden' }
		nav.write_string('<li class="navitem${active}" data-page="${i}">${d.title}</li>')
		body := rewrite_help_links(markdown.to_html(app.help_text(d.path)))
		pages.write_string('<div class="page${hidden}" id="page-${i}">${body}</div>')
	}
	return '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">' +
		'<meta name="viewport" content="width=device-width, initial-scale=1">' +
		'<title>Blobly Net — Help</title><style>${help_style}</style></head><body>' +
		'<div id="wrap"><nav><h2>Blobly Net Help</h2>' +
		'<input id="q" type="search" placeholder="Search all pages…" autocomplete="off">' +
		'<ul id="nav">${nav.str()}</ul><div id="results"></div></nav>' +
		'<main id="content">${pages.str()}</main></div>' +
		'<script>${help_script}</script></body></html>\n'
}

// open_help_in_browser writes the rendered Help HTML to a per-user cache file and opens it in the
// system browser (imgui is effectively one desktop app; the browser is the nicely-rendered view).
fn (mut app App) open_help_in_browser() {
	app.notify('opening Help in browser')
	dir := os.join_path(os.cache_dir(), 'blobly_net')
	os.mkdir_all(dir) or {}
	os.chmod(dir, 0o700) or {} // not a shared /tmp — avoid a symlink pre-plant
	path := os.join_path(dir, 'help.html')
	os.write_file(path, app.help_html()) or {
		app.notify('Help: could not write ${path} (${err})')
		return
	}
	ok, note := open_uri_in_browser(path)
	app.notify(if ok { note } else { 'Help written to ${path} — ${note}' })
}

// is_wsl reports whether we're under WSL, where os.open_uri finds no Linux browser.
fn is_wsl() bool {
	if os.getenv('WSL_DISTRO_NAME') != '' || os.getenv('WSL_INTEROP') != '' {
		return true
	}
	rel := os.read_file('/proc/sys/kernel/osrelease') or { return false }
	low := rel.to_lower()
	return low.contains('microsoft') || low.contains('wsl')
}

// open_uri_in_browser opens `path` in the system browser. Under WSL, os.open_uri finds no Linux
// browser, so route to the Windows browser via wslview (wslu) or explorer.exe with a wslpath UNC.
fn open_uri_in_browser(path string) (bool, string) {
	if is_wsl() {
		if exe := os.find_abs_path_of_executable('wslview') {
			mut p := os.new_process(exe)
			p.set_args([path])
			p.run()
			p.wait()
			if p.code == 0 {
				return true, 'opened Help in the Windows browser'
			}
		}
		if exe := os.find_abs_path_of_executable('explorer.exe') {
			win := os.execute('wslpath -w ' + os.quoted_path(path))
			if win.exit_code == 0 {
				mut p := os.new_process(exe)
				p.set_args([win.output.trim_space()])
				p.run()
				p.wait()
				return true, 'opening Help in the Windows browser'
			}
		}
		return false, 'open it manually (install wslu for wslview)'
	}
	os.open_uri(path) or { return false, 'open it manually (${err.msg()})' }
	return true, 'opened Help in browser'
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
	// group channels by adapter type (in-process / SocketCAN / hardware / UDP / DoIP), each a
	// collapsible group with a count — so a big mixed setup folds into a few headers, and a
	// single-type project is just one group.
	mut order := []string{}
	mut groups := map[string][]int{}
	for i, c in chans {
		k := bus_kind(c.adapter)
		if k !in groups {
			order << k
		}
		groups[k] << i
	}
	for k in order {
		idxs := groups[k]
		if !vgui.tree_node_open('${k}   (${idxs.len})###busgrp_${k}') {
			continue
		}
		for i in idxs {
			c := chans[i]
			new := vgui.checkbox('##en${i}', c.enabled)
			if new != c.enabled {
				app.mu.lock()
				app.chans[i].enabled = new
				// enabling a channel mid-run spawns its RX thread; disabling lets it exit.
				// `spawning` is the double-click guard — without one, a second click inside the
				// open window starts a second rx_loop and every frame is logged twice. It is
				// SEPARATE from `running` on purpose: running means "a monitor is reading", and
				// an inproc bus broadcasts only to subscribers already attached, so a frame sent
				// while the socket is still opening cannot echo. Claiming a watcher that early
				// marked healthy traffic as never having reached the wire.
				if new && app.running && c.monitorable() && !app.chans[i].running
					&& !app.chans[i].spawning {
					app.chans[i].spawning = true
					spawn rx_loop(app, i, app.chans[i].iface, app.run_gen)
				}
				app.mu.unlock()
			}
			vgui.same_line()
			r, g, b, label := chan_state(c)
			vgui.text_colored(r, g, b, label)
			vgui.same_line()
			vgui.text('${c.name}  ${c.iface}  [${c.mode}]  RX ${c.rx}')
			// system awareness: when a system.toml is loaded, name the ECUs that sit on
			// this bus — the channel row alone doesn't say WHO is on the wire. The system
			// bus is matched by its interface (system [bus.x].interface == the channel's).
			if app.sys_loaded {
				mut bus_name := ''
				for sb in app.sys.buses {
					if sb.iface == c.iface {
						bus_name = sb.name
						break
					}
				}
				if bus_name != '' {
					mut on_bus := []string{}
					for n in app.sys.nodes {
						if bus_name in n.buses {
							on_bus << n.name
						}
					}
					if on_bus.len > 0 {
						// own line, indented: the channel row is narrow and would clip this
						vgui.text_dim('        ${bus_name}: ${on_bus.join(', ')}')
					}
				}
			}
		}
		vgui.tree_pop()
	}
	vgui.end()
}

// bus_kind maps a channel adapter to a friendly type-group label for the Buses panel.
fn bus_kind(adapter string) string {
	return match adapter {
		'virtual' { 'Virtual (in-process)' }
		'vcan' { 'Virtual CAN (vcan)' }
		'socketcan' { 'SocketCAN' }
		'pcan' { 'PCAN (hardware)' }
		'kvaser' { 'Kvaser (hardware)' }
		'udp' { 'UDP software bus' }
		'doip' { 'DoIP (Ethernet)' }
		'' { 'Other' }
		else { adapter }
	}
}

// draw_network shows the bus topology: each channel (bus) and everything attached to it —
// the tester's own functions (Monitor / Send / Diagnostics), simulated ECUs, and generators
// grouped by the bus they actually transmit on. The simulation-setup analog.
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
	brows := app.filter_bus(rows, app.trace_bus)
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
	frows := app.filter_bus(rows.filter(app.is_fwatched(it.id, it.ext)), app.ftrace_bus)
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

// filter_bus keeps only rows on the selected bus (by configured name); '' = all. Live rows
// carry the bus name in `ch`, but rows from a loaded recording carry the log interface string
// (e.g. `vcan0`) instead of the bus name (e.g. `CAN0`), so also match the selected bus's
// iface/address — otherwise a chip would filter every imported row out.
fn (app &App) filter_bus(rows []TraceRow, bus string) []TraceRow {
	if bus == '' {
		return rows
	}
	mut aliases := [bus]
	for c in app.chans {
		if c.name == bus {
			if c.iface != '' && c.iface !in aliases {
				aliases << c.iface
			}
			if c.address != '' && c.address !in aliases {
				aliases << c.address
			}
		}
	}
	return rows.filter(it.ch in aliases)
}

fn idstr(id u32, ext bool) string {
	return if ext { '0x${id:08X}' } else { '0x${id:03X}' }
}

// trace_pass: case-insensitive substring match over id / name / ch / dir / data.
fn trace_pass(r TraceRow, filt string) bool {
	if filt == '' {
		return true
	}
	// the violation is searchable, so "!crc" in the filter box shows only bad frames — the
	// gesture someone reaches for the moment they suspect one
	// the origin is searchable, so "sim" shows only our simulated ECUs and "bus" only what the
	// device under test actually put on the wire — the two views a bench asks for
	hay := '${idstr(r.id, r.ext)} ${r.name} ${r.ch} ${r.origin}${origin_mark(r)} ${hex(r.data)} ${r.e2e}'.to_lower()
	return hay.contains(filt)
}

// loaded_dbs_for returns the CURRENT in-memory database for each of these paths — the edited
// copy where the editor has unsaved changes, skipping any path no longer loaded.
fn (app &App) loaded_dbs_for(paths []string) []candb.Database {
	mut out := []candb.Database{}
	for p in paths {
		i := app.dbs_paths.index(p)
		if i >= 0 && i < app.dbs.len {
			out << app.dbs[i]
		}
	}
	return out
}

// merge_dbs_from flattens several loaded databases into one, for callers that already hold
// Database values rather than paths.
fn merge_dbs_from(dbs []candb.Database) candb.Database {
	mut msgs := []candb.Message{}
	mut nodes := []string{}
	mut seen := map[string]bool{}
	for d in dbs {
		for m in d.messages {
			k := '${m.id}|${m.ext}'
			if k in seen {
				continue
			}
			seen[k] = true
			msgs << m
		}
		nodes << d.nodes
	}
	return candb.Database{
		messages: msgs
		nodes:    nodes
	}
}

// trace_name_cell is the name column, with any end-to-end verdict appended.
//
// Shared by the flat and GROUPED views because grouped is the default: a violation rendered
// only in the flat table is invisible unless the user happens to switch modes, which is the
// same as not reporting it.
fn trace_name_cell(r TraceRow) string {
	return if r.e2e == '' { r.name } else { '${r.name}  ${r.e2e}' }
}

fn draw_trace_all(id string, rows []TraceRow, filt string) {
	if vgui.table_begin(id, 6) {
		vgui.table_setup_col('t (ms)', 66)
		vgui.table_setup_col('ch', 52)
		vgui.table_setup_col('origin', 52)
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
			vgui.table_cell('${r.origin}${origin_mark(r)}')
			vgui.table_cell(idstr(r.id, r.ext))
			// A violation is appended to the NAME rather than given a column: it is rare, and
			// a permanently-empty column costs width on every row for the frames that are fine.
			vgui.table_cell(trace_name_cell(r))
			vgui.table_cell(if r.rtr { 'RTR' } else { hex(r.data) })
		}
		vgui.table_end()
	}
}

struct GAgg {
mut:
	origin string
	ch     string
	id     u32
	ext    bool
	count  int
	// Any frame in this group that never reached the wire. Taken across the whole group, not
	// from `last`: the newest row is the one whose echo window has had least time to close, so
	// reading the flag off it would hide every miss but the stalest.
	missed bool
	last  TraceRow // newest frame of this group in the window
	prev  TraceRow // the frame before `last` (empty data if only one seen) — for byte-delta dim
}

// gkey is the stable per-group identity used for both the grouped-view rows and the
// persistent all-time frame count (App.gcount). Keep in sync with draw_trace_grouped.
fn gkey(origin string, ch string, id u32, ext bool) string {
	// Length-prefixed for the same reason as tx_bus_key: a channel name may contain '|', and a
	// key that two different channels can produce merges their rows in the grouped view — with
	// a count that silently adds them together, which is the very thing this column exists to
	// stop. (origin is one of four fixed labels, and id/ext cannot contain a separator.)
	return '${origin}|${ch.len}:${ch}|${id}|${ext}'
}

// origin_mark renders the wire verdict for a frame we emitted: '!' once its echo window closed
// with nothing coming back. A bus that never echoes is a bus nothing reached — no ACK from any
// other node, wrong bitrate, swapped CANH/CANL, or a down link — and today that is invisible.
fn origin_mark(r TraceRow) string {
	return if r.missed { '!' } else { '' }
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
		// Grouping by ORIGIN as well as id means our simulated 0x120 and a real ECU's 0x120 are
		// two rows, not one row with a count that quietly adds them together.
		k := gkey(r.origin, r.ch, r.id, r.ext)
		mut g := agg[k] or { GAgg{r.origin, r.ch, r.id, r.ext, 0, false, r, TraceRow{}} }
		if r.missed {
			g.missed = true
		}
		if g.count > 0 {
			g.prev = g.last // slide the previous-frame window forward
		}
		g.count++
		g.last = r
		agg[k] = g
	}
	mut groups := agg.values()
	groups.sort_with_compare(fn (a &GAgg, b &GAgg) int {
		if a.id != b.id {
			return if a.id < b.id { -1 } else { 1 }
		}
		if a.origin != b.origin {
			return if a.origin < b.origin { -1 } else { 1 }
		}
		return if a.ch < b.ch {
			-1
		} else if a.ch > b.ch {
			1
		} else {
			0
		}
	})
	if vgui.table_begin('gtrace', 5) {
		vgui.table_setup_col('id / name', 210)
		vgui.table_setup_col('ch', 52)
		vgui.table_setup_col('origin', 52)
		vgui.table_setup_col('count', 60)
		vgui.table_setup_col('data', 0)
		vgui.table_freeze_top()
		vgui.table_headers()
		for g in groups {
			r := g.last
			vgui.table_row()
			vgui.table_next_col()
			// ### keys the tree id on identity only, so the live label / sort don't reset it.
			open :=
				vgui.tree_node_table('${idstr(g.id, g.ext)}  ${trace_name_cell(r)}###${gkey(g.origin,
				g.ch, g.id, g.ext)}')
			// clicking a row selects that frame (drives Signals/Graphics + "Add to filter")
			if vgui.is_item_clicked() {
				app.sel_id = int(g.id)
				app.sel_ext = g.ext
			}
			// right-click a row → context menu (plot its signals / add to filter)
			if vgui.begin_popup_context_item('rowctx##${gkey(g.origin, g.ch, g.id, g.ext)}') {
				if m := app.find_message(g.id, g.ext) {
					if vgui.menu_item('Add all signals to Graphics') {
						for s in m.active_signals(r.data) {
							app.add_watch(g.id, g.ext, s.name)
						}
						app.show_graphics = true
					}
				}
				if vgui.menu_item('Add to Trace (filter)') {
					app.add_fwatch(g.id, g.ext)
				}
				vgui.end_popup()
			}
			vgui.table_cell(g.ch)
			vgui.table_cell('${g.origin}${if g.missed { '!' } else { '' }}')
			// all-time total (survives the ring trim); fall back to the window count.
			total := gcount[gkey(g.origin, g.ch, g.id, g.ext)] or { u64(g.count) }
			vgui.table_cell('${total}')
			// data column: dim bytes that match the PREVIOUS frame of this group, normal for
			// ones that changed (conventional change highlight). Compared against the actual prior
			// frame in the trace buffer — not the last-rendered payload — so the delta is correct
			// regardless of repaint timing (a byte that flips and flips back between repaints still
			// shows against the real previous frame).
			vgui.table_next_col()
			if r.rtr {
				vgui.text('RTR')
			} else {
				prev := g.prev.data
				for i, b in r.data {
					if i > 0 {
						vgui.same_line()
					}
					tok := '${b:02X}'
					if i >= prev.len || prev[i] != b {
						vgui.text(tok) // changed → normal colour
					} else {
						vgui.text_dim(tok) // unchanged → dimmed
					}
				}
			}
			if open {
				if m := app.find_message(g.id, g.ext) {
					for s in m.active_signals(r.data) {
						lbl := s.label(r.data)
						extra := if lbl != '' { ' (${lbl})' } else { '' }
						unit := if s.unit != '' { ' ${s.unit}' } else { '' }
						vgui.table_row()
						vgui.table_next_col()
						// selectable spans the cell so the whole row is a right-click target
						vgui.selectable('    ${s.name}##sigrow${g.id}_${g.ext}_${s.name}', false)
						if vgui.begin_popup_context_item('sigctx##${g.id}_${g.ext}_${s.name}') {
							if vgui.menu_item('Add ${s.name} to Graphics') {
								app.add_watch(g.id, g.ext, s.name)
								app.show_graphics = true
							}
							vgui.end_popup()
						}
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
	// it holds still. Samples and `now` share app.t0's clock (rx stamps t_ms = ticks - t0).
	mut xmax := f64(0)
	if app.running && !app.paused {
		xmax = f64(time.ticks() - app.t0) / 1000.0
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

// ---- Send ----
// draw_quick_send is the folded-in Send: a one-shot raw id+data transmit at the top of the
// Generators panel. It fires immediately without creating a saved generator — the fast ad-hoc
// path. Fields stay editable while stopped; only firing needs a running bus.
fn draw_quick_send(mut app App) {
	vgui.separator_text('quick send')
	// target bus: validate the stored quick-send iface against the current channels; fall back to
	// the default send_iface if it was removed/renamed.
	mut target := app.send_iface
	mut cur := 0
	for k, c in app.chans {
		if c.iface == app.qs_iface {
			target = app.qs_iface
			cur = k
		} else if c.iface == target {
			cur = k
		}
	}
	if app.chans.len > 1 {
		mut names := []string{cap: app.chans.len}
		for c in app.chans {
			names << c.name
		}
		vgui.set_next_item_width(120 * app.ui_scale)
		nsel := vgui.combo('bus##qsbus', names, cur)
		if nsel != cur && nsel >= 0 && nsel < app.chans.len {
			app.qs_iface = app.chans[nsel].iface
			target = app.qs_iface
		}
		vgui.same_line()
	}
	vgui.set_next_item_width(70 * app.ui_scale)
	vgui.input_text('id (hex)', mut app.send_id_buf)
	vgui.same_line()
	vgui.set_next_item_width(200 * app.ui_scale)
	vgui.input_text('data (hex)', mut app.send_data_buf)
	vgui.same_line()
	if app.running {
		if vgui.button('Send##quicksend') {
			id := u32(('0x' + vgui.buf_str(app.send_id_buf)).u64())
			data := parse_hex_bytes(vgui.buf_str(app.send_data_buf))
			app.tx_on(target, transport.CanFrame{
				id:   id
				data: data
			})
		}
		vgui.same_line()
		vgui.text_dim('on ${app.chan_name_for(target)}')
	} else {
		vgui.text_dim('start to send')
	}
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
	// folded-in Send: fast ad-hoc raw transmit
	draw_quick_send(mut app)
	vgui.separator_text('generators')
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
		vgui.text_dim('edit freely · Send now fires once · cyclic auto-repeats · on-key fires on its key')
	} else {
		vgui.text_dim('edit freely · press Start to fire')
	}
	if app.senders.len == 0 {
		vgui.text_dim('no generators — click "+ Add generator"')
		vgui.end()
		return
	}
	// one collapsed tree node per generator; the header summarises name + trigger so the list
	// stays scannable when everything is folded (start state).
	mut remove_idx := -1
	for i, sr in app.senders {
		// keep the model in sync with the edit buffers (name/key are UI-thread-only fields);
		// do it before the header so the collapsed label reflects the latest edit.
		app.senders[i].sender.name = vgui.buf_str(app.gen_bufs[i].name_buf)
		app.senders[i].sender.key = vgui.buf_str(app.gen_bufs[i].key_buf)
		mut s := app.senders[i].sender
		cm := if s.cycle_ms > 0 { s.cycle_ms } else { 100 }
		trig := match s.trigger {
			'key' {
				if s.key != '' { 'key "${s.key}"' } else { 'key (unset)' }
			}
			'cyclic' {
				'cyclic ${cm} ms'
			}
			else {
				'manual'
			}
		}

		nm := if s.name != '' { s.name } else { '(unnamed)' }
		// ### keys the node on the index only, so editing the visible name doesn't collapse it.
		if vgui.tree_node('${nm}   ·   ${trig}###gennode${i}') {
			vgui.set_next_item_width(200 * app.ui_scale)
			if vgui.input_text('name##gn${i}', mut app.gen_bufs[i].name_buf) {
				app.dirty = true
			}
			vgui.same_line()
			vgui.set_next_item_width(36 * app.ui_scale)
			if vgui.input_text('key##gk${i}', mut app.gen_bufs[i].key_buf) {
				app.dirty = true
			}
			vgui.same_line()
			if vgui.small_button('remove##rm${i}') {
				remove_idx = i // indices shift on delete — do it after the loop
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
					// selected by NAME, not by interface: with two channels on one wire an
					// interface comparison lights BOTH buttons and cannot say which is current
					if vgui.toggle_button('${c.name}##b${i}_${ci}', c.name == sr.chan
						&& c.iface == cur, 0) {
						app.set_sender_bus(i, if c.iface == sr.iface { '' } else { c.iface },
							c.name)
					}
				}
			}
			// message picker: build the frame from a DBC message (→ per-signal values) or send a
			// raw id + data. Option 0 = raw; the rest are the messages on THIS generator's bus.
			gen_iface := app.senders[i].target()
			msg_names := app.message_names_for(gen_iface)
			mut msg_opts := ['(raw id / data)']
			msg_opts << msg_names
			mut cur_msg := 0
			if s.message != '' {
				for k, mn in msg_names {
					if mn == s.message {
						cur_msg = k + 1
						break
					}
				}
			}
			vgui.set_next_item_width(220 * app.ui_scale)
			nsel := vgui.combo('message##msg${i}', msg_opts, cur_msg)
			if nsel != cur_msg {
				app.set_sender_message(i, if nsel <= 0 { '' } else { msg_opts[nsel] })
				s = app.senders[i].sender // reflect the switch in this frame's payload block
			}
			// payload: DBC message -> per-signal values; raw -> id + data hex
			if s.message != '' {
				vgui.text('message ${s.message} · signal values:')
				cmsg := app.find_message_cdb_for(gen_iface, s.message) or { candb.Message{} }
				for j, ss in s.signals {
					mut sig := candb.Signal{}
					mut have := false
					for cs in cmsg.signals {
						if cs.name == ss.name {
							sig = cs
							have = true
							break
						}
					}
					app.signal_input(i, j, sig, have)
				}
			} else {
				vgui.set_next_item_width(70 * app.ui_scale)
				if vgui.input_text('id##id${i}', mut app.gen_bufs[i].id_buf) {
					app.dirty = true
				}
				vgui.same_line()
				vgui.set_next_item_width(260 * app.ui_scale)
				if vgui.input_text('data (hex)##dt${i}', mut app.gen_bufs[i].data_buf) {
					app.dirty = true
				}
			}
			vgui.tree_pop()
		}
	}
	if remove_idx >= 0 {
		app.remove_generator(remove_idx)
	}
	vgui.end()
}

// add_generator appends a new raw generator to the session, targeting the first channel.
// Session-only until Save writes it to the project.
fn (mut app App) add_generator() {
	iface := if app.chans.len > 0 { app.chans[0].iface } else { '' }
	cname := if app.chans.len > 0 { app.chans[0].name } else { '' }
	app.mu.lock()
	app.senders << SenderRT{
		iface:  iface
		chan:   cname
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
	if app.running && iface != '' && tx_bus_key(cname, iface) !in app.tx_buses {
		if b := app.open_tap_on(iface, org_tst, cname) {
			app.tx_buses[tx_bus_key(cname, iface)] = b
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
// load_cfg_text reads the project file into the edit buffer.
//
// Only when the buffer does not already hold this path: re-reading on every frame — or every
// tab switch — would throw away whatever the user had typed.
fn (mut app App) load_cfg_text() {
	// Cached. The File tab calls this every render, so re-reading whenever the buffer was
	// clean meant a synchronous file read and a 64 KiB allocation at frame rate. Freshness
	// comes from EXPLICIT invalidation instead — cfg_invalidate() at every path that rewrites
	// or replaces the project — which is also the only way to be right about a file changed
	// by something other than us.
	if app.cfg_loaded == app.proj_path && app.proj_path != '' {
		return
	}
	if app.proj_path == '' {
		app.cfg_text = mkbuf('', 4096)
		app.cfg_loaded = ''
		app.cfg_text_dirty = false
		app.cfg_err = 'no file yet — save the project once (File ▸ Save As), then edit it here'
		return
	}
	txt := os.read_file(app.proj_path) or {
		// Still allocate: draw_config_text renders the box regardless, and ImGui cannot be
		// handed a zero-capacity buffer.
		app.cfg_text = mkbuf('', 4096)
		// Mark it LOADED even though it failed: the tab calls this every frame, and leaving the
		// marker empty meant re-attempting the read and reallocating the buffer at frame rate
		// for as long as the file stayed missing. Reload and invalidation still retry.
		app.cfg_loaded = app.proj_path
		app.cfg_text_dirty = false
		app.cfg_chans = -1
		app.cfg_err = 'cannot read ${app.proj_path}: ${err}'
		return
	}
	// Generous headroom: ImGui writes into this buffer and cannot grow it, so the room to type
	// has to be reserved up front. The fill level is shown once it gets close.
	cap := if txt.len * 3 > 65536 { txt.len * 3 } else { 65536 }
	app.cfg_text = mkbuf(txt, cap)
	app.cfg_text_len = txt.len
	app.cfg_loaded = app.proj_path
	app.cfg_text_dirty = false
	// Validate what was just READ. Assuming a file on disk is well-formed made the status claim
	// "YAML well-formed · -1 channel(s)" for a file the very next Save would reject — the tool
	// disagreeing with itself about the bytes on screen.
	app.cfg_err = cfg_text_error(txt)
	app.cfg_chans = cfg_text_channels(txt)
}

// set_config_open is the ONE way the Configuration window is shown or hidden.
//
// Hiding it by any route that is not its own [X] means draw_config never runs again, so its
// close-time apply_edits() never fires and a half-typed bus field is resynced away from the old
// model when the window reopens. There were three such routes and the fix reached one of them,
// so they now share this.
fn (mut app App) set_config_open(open bool) {
	if open == app.show_config {
		return
	}
	if !open {
		if !app.running && app.dirty {
			app.apply_edits()
		}
		app.show_config = false
		return
	}
	app.show_config = true
	app.sync_cfg_bufs()
}

// cfg_invalidate drops the cached project text, so the File tab re-reads it next render.
// Called wherever the file or the active project changes underneath the editor.
fn (mut app App) cfg_invalidate() {
	app.cfg_loaded = ''
	app.cfg_text_dirty = false
}

// draw_config_text is the File tab: edit the project as text, validate, write it back.
fn (mut app App) draw_config_text() {
	if app.dirty {
		// The two tabs edit different things — app.proj versus the file on disk — and either
		// action below overwrites one side, so say which is at risk before offering it.
		vgui.text_colored(230, 170, 70, '● unsaved edits in the model (buses/generators) are not in this text')
		if app.cfg_text_dirty {
			// Both sides modified: writing the model would overwrite the typing, so that
			// action is withheld rather than offered and silently destructive.
			vgui.text_colored(230, 120, 120, '  …and this text has unsaved edits too — Save the text, or Revert it, before folding bus edits in')
			if vgui.small_button('Revert the text') {
				app.cfg_invalidate() // clearing the flag alone leaves the cache holding the edits
				app.load_cfg_text()
			}
		} else {
			if vgui.small_button('Save those edits into the file') {
				app.save_project()
				app.load_cfg_text() // re-read what was just written
			}
			vgui.same_line()
			// "bus edits" was too narrow: app.dirty is also set by the Generators panel, and
			// revert re-reads the whole project, so a generator edit went with it under a label
			// that did not mention it.
			if vgui.small_button('Discard ALL unsaved edits (buses + generators)') {
				app.revert_proj_from_disk()
			}
		}
		vgui.separator()
	}
	// Gated, not merely ignored on click: os.write_file('') fails, and Save As serialises the
	// MODEL, which would throw away the text the user is looking at.
	can_save := app.cfg_err == '' && app.proj_path != ''
	if can_save {
		if vgui.button('Save') {
			app.save_cfg_text()
		}
	} else {
		vgui.text_dim('[ Save ]')
	}
	vgui.same_line()
	if vgui.button('Reload') {
		// invalidate, not just un-dirty: load_cfg_text returns early while cfg_loaded still
		// matches the path, so the edited buffer would stay on screen with its marker cleared
		// and a later Save would write text the user believed was discarded
		app.cfg_invalidate()
		app.load_cfg_text()
	}
	if app.cfg_text_dirty {
		vgui.same_line()
		vgui.text_colored(230, 170, 70, '● modified')
	}
	vgui.same_line()
	vgui.text_dim(if app.proj_path == '' { '(unsaved project)' } else { app.proj_path })
	used := vgui.buf_str(app.cfg_text).len
	if used > app.cfg_text.len - 1024 {
		vgui.text_colored(230, 120, 120, 'buffer nearly full (${used}/${app.cfg_text.len}) — Save, then Reload for more room')
	}
	if app.cfg_err != '' {
		vgui.text_colored(230, 120, 120, app.cfg_err)
	} else {
		// The channel count, not just "OK": an empty file parses perfectly and yields zero
		// channels, so "OK" alone would reassure someone whose edit had emptied the project.
		// Cached — recomputing it per frame reparsed the whole document at frame rate, and a
		// typing frame parsed it twice.
		n := app.cfg_chans
		if n == 0 && app.proj.channels.len > 0 {
			vgui.text_colored(230, 170, 70, 'YAML is well-formed but yields NO channels — saving would empty this project')
		} else {
			vgui.text_dim('YAML well-formed · ${n} channel(s) — syntax only, not a config check')
		}
	}
	if vgui.text_edit('##cfgtext', mut app.cfg_text, 460) {
		// Validate as you type, so a mistake is visible where it was made rather than at Save.
		app.cfg_text_dirty = true
		t := vgui.buf_str(app.cfg_text)
		app.cfg_err = cfg_text_error(t)
		app.cfg_chans = cfg_text_channels(t)
	}
}

// cfg_text_error returns why this text would not load, or '' if it parses.
//
// What this can and cannot promise, measured rather than assumed: `parse` rejects malformed
// YAML — unterminated flow collections, tab indentation — and nothing else. A file with no
// `project:` key, an unknown key, a channel with no name, or a non-numeric bitrate all parse
// happily, defaulting or ignoring. So this is a SYNTAX check, and the UI says so instead of
// claiming the configuration is valid.
fn cfg_text_error(txt string) string {
	p := project.parse(txt) or { return '${err}' }
	if !p.is_supported() {
		return p.version_note()
	}
	return ''
}

// cfg_text_channels reports how many channels the text yields — the number that tells a reader
// whether an edit did what they meant, and the one that catches the destructive case below.
fn cfg_text_channels(txt string) int {
	p := project.parse(txt) or { return -1 }
	return p.channels.len
}

// save_cfg_text writes the edit buffer back to the project file and reloads from it.
//
// The TEXT is written, not a re-serialisation of the parsed model: the model does not carry
// comments, and this file is where a bench setup explains itself.
fn (mut app App) save_cfg_text() {
	if app.dirty {
		// The mirror of the guard in save_project: applying this text would replace a model
		// that holds unsaved bus or generator edits.
		app.cfg_err = 'unsaved bus edits would be lost — save or discard them above first'
		app.notify('not saved — resolve the unsaved bus edits first')
		return
	}
	txt := vgui.buf_str(app.cfg_text)
	if e := non_empty(cfg_text_error(txt)) {
		app.cfg_err = e
		app.notify('not saved — ${e}')
		return
	}
	// Refuse the one edit that silently destroys work: a well-formed file that parses to no
	// channels at all, over a project that had some. Almost always a truncated buffer or a
	// mangled top level, never a thing anyone means to save.
	if cfg_text_channels(txt) == 0 && app.proj.channels.len > 0 {
		app.cfg_err = 'refused: this text yields no channels, which would empty the project — use Reload to get the file back'
		app.notify('not saved — it would empty the project')
		return
	}
	path := app.proj_path
	os.write_file(path, txt) or {
		app.notify('save failed: ${err}')
		return
	}
	app.notify('saved -> ${path}')
	app.dirty = false
	app.cfg_text_dirty = false
	// rebuild_from_proj, NOT load_project: the full open path calls set_project, which clears
	// the trace rows, grouped counts, telemetry records, diagnostic and script logs and signal
	// watches. Editing one config line while stopped must not throw away a captured session —
	// the structured Buses Save does not, and neither should this.
	app.apply_parsed_text(txt)
	app.load_cfg_text()
}

// apply_parsed_text folds already-validated project text into the model and rebuilds the
// runtime view, leaving the captured session alone.
fn (mut app App) apply_parsed_text(txt string) bool {
	p := project.parse(txt) or { return false }
	if !p.is_supported() {
		return false
	}
	// Injected faults are keyed by interface/node/message; a config edit can rename or remove
	// any of those, and a fault left pointing at the old names would apply to whatever now
	// occupies them.
	sim.clear_all()
	app.mu.lock()
	app.proj = p
	app.proj_name = p.name
	app.mu.unlock()
	app.cfg_bufs = [] // re-derived from the new channel list on the next Buses render
	app.rebuild_from_proj()
	return true
}

// revert_proj_from_disk throws away unsaved STRUCTURED edits by re-reading the file, without
// the session reset that load_project performs.
fn (mut app App) revert_proj_from_disk() {
	txt := os.read_file(app.proj_path) or {
		app.notify('cannot re-read ${app.proj_path}: ${err}')
		return
	}
	// Clear the flags only if the file actually replaced the model. Clearing them regardless
	// left the edited model live and looking clean, so a later save would persist changes the
	// user had been told were discarded.
	if !app.apply_parsed_text(txt) {
		app.notify('nothing discarded — ${app.proj_path} does not parse; fix it on the File tab')
		return
	}
	app.dirty = false
	app.cfg_invalidate()
	app.load_cfg_text()
	app.notify('unsaved model edits discarded (buses + generators)')
}

// non_empty is `?string` sugar: Some(s) when s is not empty.
fn non_empty(s string) ?string {
	return if s == '' { none } else { s }
}

fn (mut app App) save_project() {
	if app.proj_path == '' {
		app.open_browser('saveas')
		return
	}
	// The model and the file text are two representations of one project, and writing either
	// over the other loses work. Only one may be modified at a time, and that is enforced HERE
	// rather than in the File tab alone — the Buses Save button and File ▸ Save reach this
	// function without passing through any of that tab's controls.
	if app.cfg_text_dirty {
		app.notify('not saved — the Configuration ▸ File tab has unsaved text; save or revert it there first')
		app.show_config = true
		app.cfg_tab = 1
		return
	}
	app.apply_edits()
	app.mu.lock()
	p := app.proj
	path := app.proj_path
	app.mu.unlock()
	p.save(path) or {
		app.notify('save failed: ${err}')
		return
	}
	app.dirty = false
	app.cfg_invalidate() // the file just changed under the File tab
	app.notify('saved -> ${path}')
}

// apply_edits folds pending editor state into app.proj so Start/Save act on exactly what the
// editor shows. While STOPPED it also rebuilds the runtime view; while RUNNING it only folds
// generator edits into the model for the file write and does NOT rebuild — rebuilding app.chans
// mid-measurement would reset the running flags / desync the live RX/gen threads and tx_buses
// (the config editor is stopped-only, so there are no live config edits to apply anyway).
fn (mut app App) apply_edits() {
	if app.running {
		app.sync_senders_into_proj() // generators may be edited live; persist them, don't rebuild
		return
	}
	app.commit_cfg() // Configuration-editor buffers -> app.proj (no-op if the editor never opened)
	app.sync_senders_into_proj() // session generators -> app.proj
	app.rebuild_from_proj() // rebuild app.chans/dbs/sims from the updated model
}

// save_as sets the path (from the browser) and saves.
fn (mut app App) save_as(path string) {
	// BEFORE the path moves. The centralised guard in save_project refuses the write, but by
	// then proj_path already names the new destination — so the next File render sees a cache
	// miss and replaces the unsaved buffer with that file's contents, or an empty error buffer
	// for a file that does not exist yet.
	if app.cfg_text_dirty {
		app.notify('not saved — the Configuration ▸ File tab has unsaved text; save or revert it there first')
		app.show_config = true
		app.cfg_tab = 1
		return
	}
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
	// A blank project inherits nothing: set_project bypasses load_project's reset, so without
	// this the System panel kept showing the PREVIOUS project's ECUs and annotated any newly
	// added channel from that stale model (codex #65 r5) — the same staleness fixed for the
	// load path in r3, in the one entry point it did not cover.
	app.sys = sysview.System{}
	app.sys_loaded = false
	app.sel_ecu = ''
	app.show_sys = false
	app.set_project(project.Project{ name: 'untitled' }, '')
	app.notify('new project — add buses in Configure…')
}

// dbs_for returns the DBCs attached to the channel transmitting on `iface` (a generator's target
// bus). Scoping the message picker/lookup here — not the global app.dbs — means a generator on
// bus B never resolves a same-named message from bus A's database.
fn (app &App) dbs_for(iface string) []candb.Database {
	return app.dbs_by_iface[iface] or { [] }
}

// message_names_for lists the DBC message names on `iface` (deduplicated, load order) — the
// picker options for a generator whose target bus is `iface`.
fn (app &App) message_names_for(iface string) []string {
	mut out := []string{}
	mut seen := map[string]bool{}
	for db in app.dbs_for(iface) {
		for m in db.messages {
			if m.name in seen {
				continue
			}
			seen[m.name] = true
			out << m.name
		}
	}
	return out
}

// set_sender_message switches generator `i` between raw (msg == '') and DBC-message mode. When a
// message is picked, its signals are seeded (values preserved by name across a re-pick) so the
// editor shows one input per signal; picking raw clears them so the id/data hex inputs return.
// The message is resolved on the generator's OWN target bus, not globally.
fn (mut app App) set_sender_message(i int, msg string) {
	if i < 0 || i >= app.senders.len {
		return
	}
	iface := app.senders[i].target()
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if msg == '' {
		app.senders[i].sender.message = ''
		app.senders[i].sender.signals = []
	} else {
		old := app.senders[i].sender.signals.clone()
		app.senders[i].sender.message = msg
		mut sigs := []project.SenderSig{}
		for db in app.dbs_for(iface) {
			mut found := false
			for m in db.messages {
				if m.name != msg {
					continue
				}
				for sig in m.signals {
					mut v := f64(0)
					for o in old {
						if o.name == sig.name {
							v = o.value
							break
						}
					}
					sigs << project.SenderSig{
						name:  sig.name
						value: v
					}
				}
				found = true
				break
			}
			if found {
				break
			}
		}
		app.senders[i].sender.signals = sigs
	}
	app.dirty = true
}

// find_message_cdb_for returns the candb.Message `name` from the DBCs on `iface` (signal
// metadata: units, value tables, integer-vs-float scaling) — scoped to the generator's bus.
fn (app &App) find_message_cdb_for(iface string, name string) ?candb.Message {
	for db in app.dbs_for(iface) {
		for m in db.messages {
			if m.name == name {
				return m
			}
		}
	}
	return none
}

// signal_is_integer is true when every representable physical value of the signal is a whole
// number (integer factor + offset) — so it should get an integer input, not a float box.
fn signal_is_integer(sig candb.Signal) bool {
	return sig.factor == math.trunc(sig.factor) && sig.offset == math.trunc(sig.offset)
}

// signal_input renders one generator signal value using its DBC type: an enum dropdown for a
// signal with a VAL_ table, an integer spinner for integer-scaled signals, else a float box.
// `sig` is the DBC metadata (valid only when `have`); without it we fall back to a float box.
fn (mut app App) signal_input(i int, j int, sig candb.Signal, have bool) {
	ss := app.senders[i].sender.signals[j]
	unit := if have && sig.unit != '' { ' [${sig.unit}]' } else { '' }
	lbl := '${ss.name}${unit}##sig${i}_${j}'
	pv := unsafe { &app.senders[i].sender.signals[j].value }
	vgui.set_next_item_width(170 * app.ui_scale)
	if have && sig.values.len > 0 {
		// enum: dropdown of "value — name" states. VAL_ keys are stored two's-complement for
		// signed signals, so map key<->physical through the signal (phys_from_raw / raw_from_phys)
		// — never a bare f64(rawkey), which would turn -1 into 1.8e19.
		mut raws := sig.values.keys()
		raws.sort()
		mut labels := []string{cap: raws.len}
		for r in raws {
			labels << '${sig.phys_from_raw(r):g} — ${sig.values[r]}'
		}
		curraw := sig.raw_from_phys(ss.value)
		mut cur := 0
		for k, r in raws {
			if r == curraw {
				cur = k
				break
			}
		}
		nsel := vgui.combo(lbl, labels, cur)
		if nsel != cur && nsel >= 0 && nsel < raws.len {
			unsafe {
				*pv = sig.phys_from_raw(raws[nsel])
			}
			app.dirty = true
		}
	} else if have && signal_is_integer(sig) {
		mut iv := int(math.round(ss.value))
		if vgui.input_int(lbl, &iv) {
			unsafe {
				*pv = f64(iv)
			}
			app.dirty = true
		}
	} else {
		if vgui.input_double(lbl, pv) {
			app.dirty = true
		}
	}
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
// `bus` is an INTERFACE (project.Sender.bus is documented as one, and '' means the sender's own
// channel); `chan_name` is the channel the user actually picked. They are different facts, and
// only the second one survives two channels sharing a wire — an interface cannot say which of
// them the generator now belongs to.
fn (mut app App) set_sender_bus(i int, bus string, chan_name string) {
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.bus = bus
		tgt := app.senders[i].target()
		if chan_name != '' {
			app.senders[i].chan = chan_name
		}
		own := app.senders[i].chan
		if app.running && tgt != '' && tx_bus_key(own, tgt) !in app.tx_buses {
			if b := app.open_tap_on(tgt, org_tst, own) {
				app.tx_buses[tx_bus_key(own, tgt)] = b
			}
		}
	}
	app.mu.unlock()
}

// fire_index sends generator `i`'s CURRENT (edited) frame once. DBC-message generators
// encode the edited signal values; raw generators use the edited id/data hex fields.
// poll_hotkeys fires any 'key'-triggered generator whose key went down this frame. Runs on the
// UI thread once per frame (fire_index reads UI-thread edit buffers). Suppressed while a text
// field is focused so typing a key into an input box doesn't also fire a generator.
fn (mut app App) poll_hotkeys() {
	if !app.running || vgui.want_text_input() {
		return
	}
	for i, sr in app.senders {
		s := sr.sender
		if s.trigger != 'key' || s.key == '' {
			continue
		}
		if vgui.key_pressed(s.key[0]) {
			app.fire_index(i)
		}
	}
}

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
		// resolve the message on the generator's own target bus (not globally)
		for db in app.dbs_for(app.senders[i].target()) {
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
	app.tx_on_chan(app.senders[i].chan, app.senders[i].target(), transport.CanFrame{
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

// diag_iface_opt is diag_iface, but says when there is no running channel at all.
fn (app &App) diag_iface_opt() ?string {
	iface := app.diag_iface()
	return if iface == '' { none } else { iface }
}

fn (app &App) diag_iface() string {
	for c in app.chans {
		if c.monitorable() && c.running {
			return c.iface
		}
	}
	return ''
}

// DiagTarget is one addressable diagnostic server: the built-in channel default, or a
// simulated ECU that configured its own addresses.
struct DiagTarget {
	// The identity the panel and worker resolve by. The LABEL is a display string and is not
	// unique: two buses configuring the same node name and UDS id pair produce identical ones,
	// so selecting the second silently reset to the first and requests went to the wrong bus.
	// Eighth instance in this change of a convenient string standing in for an identity.
	key   string
	label string
	iface string
	chan  string // the CHANNEL that owns it — an interface cannot say which, when two share one
	rx    u32 // the ECU listens here — the tester TRANSMITS to it
	tx    u32 // the ECU answers here — the tester RECEIVES from it
	ext   bool
	// How to reach it. A DoIP target has no CAN ids at all — it is addressed by the channel's
	// logical pair — so rx/tx above are meaningless for one and the panel must not open an
	// ISO-TP channel for it. Derived by the same carrier_of() the scripting side uses.
	carrier script.Carrier
}

// diag_targets lists what the Diagnostics panel can talk to.
//
// Without this the panel opened diag_tx_id/diag_rx_id unconditionally, so an ECU configured on
// any other pair was unreachable from the UI that exists to reach it — including the demo
// project's own ChassisECU.
fn (app &App) diag_targets() []DiagTarget {
	// Whatever start() actually spawned, plus the plain 0x7E0/0x7E8 entry — which on a mixed
	// bench is the PHYSICAL ECU under test, not the built-in simulated server, and was
	// addressable long before per-ECU servers existed.
	// Snapshot under the lock. doip_publish/doip_forget replace this array from a supervisor
	// thread whenever a channel or ECU is toggled, so iterating it here — during a redraw or at
	// the start of a request — can read it while it is being reallocated.
	a := unsafe { app }
	a.mu.lock()
	plan := app.diag_plan.clone()
	a.mu.unlock()
	mut out := []DiagTarget{}
	if hw := app.diag_iface_opt() {
		if !plan.any(it.key == diag_key_can(hw, diag_tx_id, diag_rx_id)) {
			out << DiagTarget{
				key:   diag_key_can(hw, diag_tx_id, diag_rx_id)
				label: 'default on ${hw}  (0x${diag_tx_id:X}/0x${diag_rx_id:X})'
				iface: hw
				rx:    diag_tx_id
				tx:    diag_rx_id
			}
		}
	}
	out << plan
	// Every enabled DoIP channel is addressable, hosted by us or not. The panel's DoIP support
	// would otherwise reach only entities this application started — while the normal
	// tester-only case, a DoIP channel pointed at a REAL ECU, has no simulated nodes, is not
	// hosted, and never reaches diag_plan at all. That is the case a bench actually uses.
	for c in app.proj.channels {
		if !c.is_doip() {
			continue
		}
		// The LIVE tick, not the load-time value. The Buses checkbox writes app.chans, so a
		// channel switched off stayed selectable and the panel could still reach the external
		// ECU — and one switched on after starting disabled never appeared at all.
		if !app.chan_enabled(c) {
			continue
		}
		if c.all_nodes().len > 0 {
			// This channel SIMULATES an ECU. If it is not in diag_plan, hosting it failed —
			// and the bind failure means someone else owns that endpoint. Offering it anyway
			// would let the panel report results from that other process, which is the exact
			// wrong-ECU failure the synchronous bind check exists to prevent.
			continue
		}
		car := script.carrier_of(c)
		// Deduplicate by LOGICAL identity, not endpoint: several tester-only channels may
		// address different ECUs through one gateway, and matching on the interface alone
		// suppressed every channel after the first — leaving the others unaddressable.
		// Identity includes the TESTER address: it is sent during routing activation and can
		// select a different role or authorisation at the external ECU, so two channels
		// addressing one ECU as different testers are two distinct things to exercise.
		if out.any(it.key == diag_key_doip(c)) {
			continue
		}
		out << DiagTarget{
			key:     diag_key_doip(c)
			label:   '${c.name}  (DoIP 0x${c.ecu_addr:04X})'
			iface:   c.iface
			carrier: car
		}
	}
	if out.len == 0 {
		out << DiagTarget{
			key:   diag_key_can(app.diag_iface(), diag_tx_id, diag_rx_id)
			label: 'default  (0x${diag_tx_id:X}/0x${diag_rx_id:X})'
			iface: app.diag_iface()
			rx:    diag_tx_id
			tx:    diag_rx_id
		}
	}
	return out
}

fn diag_worker(app &App, kind string, did u16, want_key string) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.diag_busy {
		a.mu.unlock()
		return
	}
	a.diag_busy = true
	a.mu.unlock()
	targets := a.diag_targets()
	// Resolve by the identity captured AT CLICK TIME, passed in rather than read here: the
	// combo stays enabled while a request is busy, so a worker that read the live field could
	// address whichever ECU the user selected after clicking. Falling back to another entry
	// when the chosen one has gone would do the same thing more quietly.
	key := want_key
	mut t := DiagTarget{}
	mut found := false
	for cand in targets {
		if cand.key == key || (key == '' && !found) {
			t = cand
			found = true
			if cand.key == key {
				break
			}
		}
	}
	if !found {
		a.diag_push('target "${key}" is no longer available')
		a.diag_done()
		return
	}
	iface := if t.iface != '' { t.iface } else { a.diag_iface() }
	// The transport follows the TARGET, not the panel. Opening ISO-TP for a DoIP entry would
	// try to open `doip:127.0.0.1:13400` as a CAN interface, which on Linux falls through to
	// SocketCAN and fails — the panel would report the entity unreachable while it was serving.
	mut ch := if t.carrier.doip {
		isotp.Channel(doip.open_doip(t.carrier.host, t.carrier.port, t.carrier.tester,
			t.carrier.ecu) or {
			a.diag_push('doip ${t.carrier.host}:${t.carrier.port}: ${err}')
			a.diag_done()
			return
		})
	} else {
		isotp.Channel(isotp.on_bus(a.open_tap_on(iface, org_tst, t.chan) or {
			a.diag_push('open ${iface}: ${err}')
			a.mu.lock()
			a.diag_busy = false
			a.mu.unlock()
			vgui.wake()
			return
		}, a.bitrate_iface(iface), t.rx, t.tx, t.ext) or {
			a.diag_push('open ${iface}: ${err}')
			a.mu.lock()
			a.diag_busy = false
			a.mu.unlock()
			vgui.wake()
			return
		})
	}
	// Close it when this request is done. A DoIP entity serves ONE connection at a time and
	// stays inside it until the peer disconnects, so a leaked connection from the first button
	// press blocked every later one until the server's 60-second idle timeout.
	defer {
		ch.close()
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

// trace_dump_worker performs one capture read-out: it freezes the target's ring(s) and dumps
// the selected cores, reassembling each per-core ISO-TP block on 0x7E5 (sending flow control
// on 0x7E6) and decoding the records into app.trecs for the swimlane. Mirrors diag_worker: a
// single-flight busy flag, a short-lived spawn, a blocking transfer, results under mu + wake.
fn trace_dump_worker(app &App, core_mask u16) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.trace_busy {
		a.mu.unlock()
		return
	}
	a.trace_busy = true
	a.mu.unlock()
	iface := a.trace_iface()
	if iface == '' {
		a.set_trace_status('dump: no running channel')
		a.trace_done()
		return
	}
	// the trace frame ids are config-driven on the target — read them from the loaded manifest
	// (or_defaults fills the trace_demo wire when the manifest omits the `# trace frames` block).
	f := a.manifest.frames.or_defaults()
	// the host is the ISO-TP receiver: it sends flow control on dump_fc and receives the dump
	// data on record (open before commanding, so the socket buffers the target's first frame).
	// ISO-TP addressing must match the frame width — a 29-bit trace id would otherwise be masked
	// to 11 bits by SocketCAN and the target would never answer.
	tapped := a.open_tap(iface, org_tst) or {
		a.set_trace_status('dump: open ${iface}: ${err}')
		a.trace_done()
		return
	}
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), f.dump_fc, f.record, trace_ext(f.record)) or {
		a.set_trace_status('dump: open ${iface}: ${err}')
		a.trace_done()
		return
	}
	defer {
		ch.close()
	}
	cmd_ext := trace_ext(f.cmd)
	// Freeze each selected core's capture RING (op_stop) so it can be read out — the target
	// refuses to dump a buffer that's still being written. This stops recording, NOT the
	// core: handlers keep running. Then dump (op_dump).
	a.tx_on(iface, transport.CanFrame{
		id:       f.cmd
		extended: cmd_ext
		data:     telem.encode_trace_cmd(telem.op_stop, telem.filter_all, core_mask)
	})
	a.tx_on(iface, transport.CanFrame{
		id:       f.cmd
		extended: cmd_ext
		data:     telem.encode_trace_cmd(telem.op_dump, telem.filter_all, core_mask)
	})
	// a dump streams SELF-DESCRIBING blocks: one or more per selected core (multi-block:
	// deep rings ride many ~payload-sized blocks; the header's more-flag marks continuation,
	// so end-of-stream lives in the format, not in transport heuristics).
	ncores := mask_popcount(core_mask)
	mut recs := []TRec{}
	mut got := 0
	mut last_seen := 0 // cores whose final block has arrived
	mut recv_err := ''
	// Cross-core correlation (emb REQ-TRACE-011), keyed by core: how tight the measured clock
	// offset was. A core absent here is drawn on its OWN clock — the status has to say so,
	// because an uncorrelated lane looks exactly like a correlated one.
	mut skew_bounds := map[int]u16{}
	for _ in 0 .. 256 {
		if last_seen >= ncores {
			break
		}
		// Reassembly can fail transiently (a lost/reordered frame -> the SN check errors out
		// cleanly). The target's ring stays FROZEN after a dump, so re-issuing op_dump simply
		// re-streams the same block — retry a couple of times and SURFACE the error text
		// (it names the cause: SN gap vs wrong PCI vs timeout) instead of swallowing it.
		mut block := []u8{}
		mut have := false
		for attempt in 0 .. 3 {
			block = ch.recv(1000) or {
				recv_err = err.msg()
				if attempt < 2 {
					// a stale stream (a previous timed-out dump still trickling CFs) makes the
					// next recv join mid-stream ('unexpected PCI 0x2x') — drain until the bus is
					// quiet on the record id, then re-issue the dump (the frozen ring re-streams).
					ch.drain_quiet(150)
					a.tx_on(iface, transport.CanFrame{
						id:       f.cmd
						extended: cmd_ext
						data:     telem.encode_trace_cmd(telem.op_dump, telem.filter_all, core_mask)
					})
				}
				continue
			}
			have = true
			break
		}
		if !have {
			break // no more blocks (or the transfer kept failing — recv_err says why)
		}
		got++
		// Decoding lives in the engine (telem.decode_block), not here: the epoch re-anchor and the
		// cross-core clock offset decide what a dump MEANS, so the Trace Chart and the headless
		// cmd/trace_dump must not each interpret them. It is also where those rules are tested.
		b := telem.decode_block(block)
		if !b.more {
			last_seen++ // this core's final block
		}
		if b.skew_known {
			skew_bounds[b.core] = b.skew_bound_us
		}
		for br in b.records {
			recs << TRec{
				ch:     0
				core:   b.core
				abs_us: br.abs_us
				rec:    br.rec
			}
		}
	}
	a.mu.lock()
	a.trecs = synthesize_idle(recs)
	a.rev++
	a.trace_recording = false // the dump froze the buffer; Record re-arms for a new window
	// Say plainly whether the cores share a timeline. With >1 core and no measured offset the
	// lanes are each on their own clock, and reading across them is meaningless — never let that
	// pass silently, it renders identically to a correlated dump.
	sync_note := if ncores < 2 {
		''
	} else if skew_bounds.len == 0 {
		' · ⚠ cores NOT time-correlated (each on its own clock)'
	} else {
		mut worst := u16(0)
		for _, b in skew_bounds {
			if b > worst {
				worst = b
			}
		}
		' · ${skew_bounds.len}/${ncores - 1} satellite core(s) time-corrected (±${worst} µs)'
	}
	a.trace_status = if last_seen < ncores && recv_err != '' {
		'dumped ${got} block(s), ${last_seen}/${ncores} cores complete · ${recs.len} records${sync_note} · last error: ${recv_err}'
	} else {
		'dumped ${got} block(s) from ${ncores} core(s) · ${recs.len} records${sync_note}'
	}
	a.mu.unlock()
	a.trace_done()
}

fn (mut app App) trace_done() {
	app.mu.lock()
	app.trace_busy = false
	app.mu.unlock()
	vgui.wake()
}

fn (mut app App) set_trace_status(s string) {
	app.mu.lock()
	app.trace_status = s
	app.mu.unlock()
}

// trace_rsp_status formats a TraceRsp for the Trace Chart: the reporting core, its capture state,
// and — when frozen — WHY (the overrun trigger vs an explicit stop). A cross-core propagated
// freeze reports "by trigger" on every core, since each core triggers on the shared freeze.
fn trace_rsp_status(r telem.TraceRsp) string {
	st := match r.state {
		telem.state_idle { 'idle' }
		telem.state_capturing { 'capturing' }
		telem.state_full { 'full' }
		telem.state_frozen { 'frozen' }
		else { 'state ${r.state}' }
	}

	cause := match r.cause {
		telem.freeze_trigger { ' by trigger' }
		telem.freeze_stop { ' by stop' }
		else { '' }
	}

	return 'core ${r.core}: ${st}${cause} · ${r.records_used}/${r.capacity} rec'
}

// set_trace_state updates the Record toggle + status under the mutex (shared with the worker).
fn (mut app App) set_trace_state(recording bool, s string) {
	app.mu.lock()
	app.trace_recording = recording
	app.trace_status = s
	app.mu.unlock()
}

// mask_popcount counts the cores a dump mask selects (a 0 mask means the single core 0).
fn mask_popcount(mask u16) int {
	if mask == 0 {
		return 1
	}
	mut m := mask
	mut n := 0
	for m != 0 {
		n += int(m & 1)
		m >>= 1
	}
	return n
}

// send_trace_cmd fires one TraceCmd (arm/stop/reset) on the traced channel with the manifest
// core mask — a fire-and-forget control frame (no ISO-TP), used by the Record/Stop buttons.
fn (mut app App) send_trace_cmd(opcode u8) bool {
	iface := app.trace_iface()
	if iface == '' {
		app.trace_status = 'no running channel'
		return false
	}
	f := app.manifest.frames.or_defaults() // config-driven cmd id (falls back to the default)
	return app.tx_on(iface, transport.CanFrame{
		id:       f.cmd
		extended: trace_ext(f.cmd) // 29-bit ids must go out extended, else SocketCAN masks them
		data:     telem.encode_trace_cmd(opcode, telem.filter_all, app.trace_core_mask())
	})
}

// trace_ext infers the CAN addressing width of a trace frame id: any id above the 11-bit standard
// range (0x7FF) must be sent/received as a 29-bit extended id. loom2v writes literal ids to the
// manifest without an explicit width, so we infer it here (matches how a target opens the bus).
fn trace_ext(id u32) bool {
	return id > 0x7ff
}

// trace_iface picks the channel to command the dump on: the running monitor channel that
// carries the telemetry manifest (the target being traced), so a multi-channel project sends
// to the right bus. Falls back to the first running channel when no channel has a manifest.
fn (app &App) trace_iface() string {
	for c in app.chans {
		if c.monitorable() && c.running && c.manifest != '' {
			return c.iface
		}
	}
	return app.diag_iface()
}

// trace_core_mask builds a dump mask from the manifest's distinct cores, so "Dump" reads out
// every core the target declares. A single-core target uses mask 0 (the receiving/default
// core in the core_mask contract) regardless of the core *label* the manifest gives it — a
// single-core manifest that names its core "1" must still dump, not send 0x0002 to a core-0
// target. Only a genuinely multi-core manifest sets per-core bits (bit i = core i).
fn (app &App) trace_core_mask() u16 {
	mut seen := map[int]bool{}
	for h in app.manifest.handlers {
		if h.core >= 0 && h.core < 16 {
			seen[h.core] = true
		}
	}
	if seen.len <= 1 {
		return 0 // no manifest, or a single core: the default receiving core
	}
	mut mask := u16(0)
	for core, _ in seen {
		mask |= u16(1) << u16(core)
	}
	return mask
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

// shell_worker sends one command line and collects the response. Mirrors diag/trace workers:
// a single-flight busy flag, a short-lived spawn, a blocking ISO-TP recv, results under mu +
// wake. The shell ids come from the manifest's `# shell frames` section (or loom2v defaults).
fn shell_worker(app &App, line string) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.shell_busy {
		a.mu.unlock()
		return
	}
	a.shell_busy = true
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.shell_busy = false
		a.mu.unlock()
		vgui.wake()
	}
	a.shell_append('> ' + line)
	iface := a.trace_iface()
	if iface == '' {
		a.shell_append('(no running channel)')
		return
	}
	if line.len > 8 {
		a.shell_append('(line too long — the target takes one 8-byte frame per command)')
		return
	}
	sh := a.manifest.shell.or_defaults()
	// the host is the ISO-TP receiver: flow control out on `fc`, the response in on `out`
	// (opened before the command is sent, so the socket buffers the target's first frame).
	tapped := a.open_tap(iface, org_tst) or {
		a.shell_append('(open ${iface}: ${err})')
		return
	}
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), sh.fc, sh.out, trace_ext(sh.out)) or {
		a.shell_append('(open ${iface}: ${err})')
		return
	}
	defer {
		ch.close()
	}
	if !a.tx_on(iface, transport.CanFrame{
		id:       sh.input
		extended: trace_ext(sh.input)
		data:     line.bytes()
	}) {
		a.shell_append('(send failed on ${iface})')
		return
	}
	rsp := ch.recv(1500) or {
		a.shell_append('(no response: ${err})')
		return
	}
	a.shell_append(rsp.bytestr().trim_right('\n'))
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

// flash_worker runs the whole download session off-thread (the trace-dump
// pattern): open a dedicated ISO-TP channel to the BOOT ids and drive
// flash.program. The target must already be in its boot manager — the
// panel's "enter boot" button gets it there (the app's shell `boot` command;
// no reply, the reset is the ack).
fn flash_worker(app &App, path string, base u32, req_id u32, rsp_id u32, ver u32) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.flash_busy {
		a.mu.unlock()
		return
	}
	a.flash_busy = true
	a.flash_done = 0
	a.flash_total = 0
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.flash_busy = false
		a.mu.unlock()
		vgui.wake()
	}
	iface := a.trace_iface()
	if iface == '' {
		a.flash_append('(no running channel)')
		return
	}
	image := os.read_bytes(path) or {
		a.flash_append('(read ${path}: ${err})')
		return
	}
	a.flash_append('> ${os.file_name(path)} -> ${iface} @0x${base.hex()}')
	tapped := a.open_tap(iface, org_tst) or {
		a.flash_append('(open ${iface}: ${err})')
		return
	}
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), req_id, rsp_id, trace_ext(rsp_id)) or {
		a.flash_append('(open ${iface}: ${err})')
		return
	}
	defer {
		ch.close()
	}
	mut sink := GuiFlashSink{
		app: a
	}
	// 0x29 tester seed: $BLOBLY_FLASH_SEED or the dev seed — same as cmd/flash, so
	// the panel authenticates against a secured boot instead of skipping 0x29.
	seed := flash.tester_seed(os.getenv('BLOBLY_FLASH_SEED')) or {
		a.flash_append('(BLOBLY_FLASH_SEED: ${err})')
		return
	}
	flash.program(mut ch, image, flash.Opts{ base: base, sw_version: ver, auth_seed: seed }, mut
		sink) or {
		a.flash_append('FAILED: ${err}')
		a.flash_append('(a cut transfer is safe: the boot refuses the torn image — fix and re-run)')
		return
	}
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

fn script_worker(app &App, path string) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.script_busy {
		a.dbc_readers-- // release the spawn-side reservation: we never read
		a.mu.unlock()
		return
	}
	a.script_busy = true
	a.script_log = []
	a.mu.unlock()
	// the reader slot was reserved by the SPAWNING thread (TOCTOU: this
	// worker may not schedule before an edit) — this side only releases it
	defer {
		a.mu.lock()
		a.dbc_readers--
		a.mu.unlock()
	}
	mut chans := []script.ChanInfo{}
	for ch in a.chans {
		// Disabled channels are NOT scriptable. The headless runner skips them when building
		// its channel list, so leaving them here meant the same script could reach an ECU the
		// project had explicitly switched off from the GUI, and report "unknown channel" for
		// it headlessly. For a DoIP channel that means dialing a TCP endpoint the user turned
		// off — and connecting to whatever else is listening there.
		if !ch.enabled {
			continue
		}
		// A DoIP channel we are SUPPOSED to host but could not is not scriptable either. The
		// bind failed because something else owns that endpoint, so uds.open() would dial that
		// process and a GUI script would pass against the wrong ECU — the failure the
		// synchronous bind exists to prevent, reached through the scripting side instead.
		if ch.doip && a.doip_host_failed(ch.name, ch.iface) {
			continue
		}
		mut sim_nodes := []project.NodeCfg{}
		for sc in a.sims {
			if sc.iface == ch.iface {
				sim_nodes << sc.nodes
			}
		}
		// The carrier comes from the PROJECT channel: the runtime Chan above carries a `doip`
		// flag but not the logical addresses, and a DoIP open needs both. Matched by name, the
		// same key the rest of the config editor uses.
		mut pch := project.Channel{}
		for c in a.proj.channels {
			if c.name == ch.name {
				pch = c
				break
			}
		}
		chans << script.ChanInfo{
			name:      ch.name
			iface:     a.bitrate_iface(ch.iface) // pcan/kvaser: @<bitrate> so scripts open right
			key_iface: ch.iface // faults key on the LOGICAL interface, not the opened string
			// This channel's OWN merged database. Handing every channel the first one meant a
			// real message on any other DBC was rejected as unknown, or a coincidentally named
			// message was accepted with the wrong signal metadata.
			db:        merge_dbs(ch.databases)
			nodes:     sim_nodes // so a fault that cannot take effect can be refused
			carrier:   script.carrier_of(pch)
		}
	}
	mut env := script.new_env(chans) or {
		a.script_push('env init: ${err}')
		a.script_done()
		return
	}
	// A script IS the tester. Left on the default opener it would be the one emitter the trace
	// could not account for, and its frames would come back labelled as the device under test's.
	env.opener = fn [a] (iface string, chan_name string) !transport.Bus {
		// open_tap_on, not open_tap: the script picked a CHANNEL, and two channels can share one
		// interface — resolving it back from the interface would attribute the second's traffic
		// to the first.
		return a.open_tap_on(iface, org_tst, chan_name)
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

fn draw_tchart(mut app App, trecs []TRec) {
	vis, op := vgui.begin_closable('Trace Chart', app.show_tchart)
	app.show_tchart = op
	if !vis {
		vgui.end()
		return
	}
	// Capture control: Record arms the target's ring (op_arm), Stop freezes it (op_stop),
	// Dump reads the frozen buffer out over ISO-TP into the swimlane. Snapshot the worker-
	// shared state under the mutex (trace_dump_worker writes it from its thread).
	app.mu.lock()
	busy := app.trace_busy
	recording := app.trace_recording
	status := app.trace_status
	freeze := app.trace_freeze
	app.mu.unlock()
	if busy {
		vgui.text_dim('dumping…')
	} else if app.running {
		if recording {
			if vgui.button('Stop##trace') {
				app.send_trace_cmd(telem.op_stop)
				app.set_trace_state(false, 'recording stopped (frozen)')
			}
		} else {
			if vgui.button('Record##trace') {
				if app.send_trace_cmd(telem.op_arm) {
					app.set_trace_state(true, 'recording…')
				}
			}
		}
		vgui.same_line()
		if vgui.button('Dump##trace') {
			spawn trace_dump_worker(app, app.trace_core_mask())
		}
		vgui.same_line()
		vgui.text_dim('Record arms · Stop freezes · Dump reads out (all cores)')
	} else {
		vgui.text_dim('Start a channel, then Record / Dump')
	}
	// A missing manifest does NOT mean a missing endpoint: send_trace_cmd/trace_dump_worker
	// use TraceFrames.or_defaults(), so a default-configured target answers without one. Keep
	// the controls live and say what the manifest WOULD add (names) — a hint, not a gate
	// (codex #65).
	if !app.has_manifest {
		vgui.text_dim('no trace manifest attached — using the default ids; records decode without handler/thread names')
	}
	if status != '' {
		vgui.text_dim(status)
	}
	if freeze != '' { // the target's own report: capturing / frozen-by-trigger / frozen-by-stop
		vgui.text_dim('target: ${freeze}')
	}
	labels, bars, links, span := build_swimlane(app, trecs)
	vgui.text('${trecs.len} records · ${labels.len} lanes · idle lane = derived (gap between thread runs)')
	vgui.text_dim('drag = pan · scroll = zoom · double-click = fit · A/B keys or drag markers (snap to edges; Alt = free) · hover a bar + M = measure it')
	if bars.len > 0 {
		// re-seat the A/B markers into view whenever a new dump (different span) loads.
		if app.cursor_span != f64(span) {
			app.cursor_span = f64(span)
			app.cursor_a = f64(span) * 0.25
			app.cursor_b = f64(span) * 0.75
		}
		vgui.swimlane('##swim', labels, bars, links, span, &app.cursor_a, &app.cursor_b)
		d := if app.cursor_b > app.cursor_a {
			app.cursor_b - app.cursor_a
		} else {
			app.cursor_a - app.cursor_b
		}
		vgui.text('A ${app.cursor_a:.0f} us    B ${app.cursor_b:.0f} us    Δ ${d:.0f} us (${d / 1000:.3f} ms)')
		vgui.same_line()
		if vgui.button('Reset markers') { // re-seat A/B to 1/4 and 3/4 of the view
			app.cursor_a = f64(span) * 0.25
			app.cursor_b = f64(span) * 0.75
		}
	} else {
		vgui.text_dim('press Dump to capture (handler bars + thread/idle lanes appear here)')
	}
	vgui.end()
}

// A real thread interval, for the idle complement below.
struct Span {
	s u64
	e u64
}

// synthesize_idle appends DERIVED idle bars (THREAD id 0) covering the gaps where no real thread
// ran — per core, bounded by that core's captured window. The wire carries only real events (the
// exec-hook targets emit nothing when nothing runs), so idle is the complement, computed here in
// the viewer where it can be seen and measured. Cores that already stream REAL idle records (the
// multicore host path) are left alone. Long gaps chunk at the u16 cpu_us ceiling.
fn synthesize_idle(recs []TRec) []TRec {
	mut out := recs.clone()
	mut cores := []int{}
	for tr in recs {
		if tr.core !in cores {
			cores << tr.core
		}
	}
	for core in cores {
		mut spans := []Span{}
		mut lo := u64(0)
		mut hi := u64(0)
		mut first := true
		mut has_real_idle := false
		for tr in recs {
			if tr.core != core {
				continue
			}
			s0 := tr.abs_us
			e0 := s0 + u64(tr.rec.cpu_us)
			if first || s0 < lo {
				lo = s0
			}
			if first || e0 > hi {
				hi = e0
			}
			first = false
			if tr.rec.kind() == telem.kind_thread {
				if tr.rec.id() == 0 {
					has_real_idle = true
				} else {
					spans << Span{s0, e0}
				}
			}
		}
		if first || has_real_idle || spans.len == 0 {
			continue // nothing captured, or the target already reports idle itself
		}
		spans.sort(a.s < b.s)
		// Gaps below ~20 us are context-switch/kernel/hook overhead between back-to-back slices —
		// a READY thread is usually waiting through them, so painting them "idle" lies at high
		// zoom (idle can't run while someone is ready). Only real gaps become idle bars.
		min_gap := u64(20)
		mut cur := lo
		for sp in spans {
			if sp.s > cur && sp.s - cur >= min_gap {
				out << idle_recs(core, cur, sp.s - cur)
			}
			if sp.e > cur {
				cur = sp.e
			}
		}
		if hi > cur && hi - cur >= min_gap {
			out << idle_recs(core, cur, hi - cur)
		}
	}
	return out
}

// idle_recs emits one derived idle interval as TRec(s), chunked so each fits Record's u16 cpu_us.
fn idle_recs(core int, start u64, dur u64) []TRec {
	mut out := []TRec{}
	mut s0 := start
	mut left := dur
	for left > 0 {
		chunk := if left > 0xFFFF { u64(0xFFFF) } else { left }
		out << TRec{
			ch:     0
			core:   core
			abs_us: s0
			rec:    telem.Record{
				entity_id: u16(telem.kind_thread) << 14 // THREAD id 0 = idle
				info:      telem.reason_block           // idle can't be "preempted" — no hatch
				cpu_us:    u16(chunk)
			}
		}
		s0 += chunk
		left -= chunk
	}
	return out
}

// build_swimlane turns decoded records into swimlane lanes + bars. A dumped stream mixes entity
// kinds, each an interval [start, start+cpu): FB (handler) runs, THREAD runs, and ISR runs each
// get a duration bar on their own lane; CONTROL records (block headers / epochs) are framing and
// were stripped by the dump worker. Lanes are grouped FB → threads → interrupts, by core.
// handler_core / thread_core resolve the core of a manifest id (-1 = unknown / no manifest).
fn handler_core(app &App, id u16) int {
	if h := app.manifest.lookup(id) {
		return h.core
	}
	return -1
}

// fb_label prefixes the handler name with its core (c0/c1…) so a lane shows which
// core it belongs to.
fn fb_label(app &App, id u16) string {
	c := handler_core(app, id)
	base := app.manifest.label(id)
	return if c >= 0 { 'c${c}  ${base}' } else { base }
}

// split_lane_key splits a '<core>:<id>' thread/isr lane key back into its parts.
fn split_lane_key(k string) (int, u16) {
	parts := k.split(':')
	if parts.len != 2 {
		return 0, 0
	}
	return parts[0].int(), u16(parts[1].int())
}

// thread_core_label labels a THREAD lane, prefixed with its (block) core. id 0 is idle (no
// manifest row); a real thread resolves its name from the manifest, else "thread N".
fn thread_core_label(app &App, core int, id u16) string {
	base := if id == 0 { 'idle' } else { app.manifest.thread_label(core, id) }
	if id != 0 {
		if t := app.manifest.by_tid[telem.tkey(core, id)] {
			if t.prio >= 0 {
				return 'c${core}  ${base} p${t.prio}'
			}
		}
	}
	return 'c${core}  ${base}'
}

fn build_swimlane(app &App, trecs []TRec) ([]string, []vgui.Bar, []vgui.Link, f32) {
	if trecs.len == 0 {
		return []string{}, []vgui.Bar{}, []vgui.Link{}, f32(1)
	}
	// distinct lanes, first-seen. FB handler ids are globally unique; THREAD and ISR lanes are
	// keyed by (block core, id) — via TRec.core from the block header — so each core's idle (id 0,
	// shared across cores) and per-core ISR vectors get their own lane rather than merging.
	// lanes are laid out in a STABLE order (not first-seen-in-capture, which shuffles every
	// dump): handlers by manifest id, threads by RTOS priority (p0 at the top — the hierarchy
	// preemption is read against), unknown-prio threads after, by id.
	mut hids := []u16{}
	mut sh := map[u16]bool{}
	mut tkeys := []string{} // '<core>:<id>' for THREAD (incl. idle id 0)
	mut tseen := map[string]bool{}
	mut ikeys := []string{} // '<core>:<id>' for ISR
	mut iseen := map[string]bool{}
	for tr in trecs {
		r := tr.rec
		if r.kind() == telem.kind_fb {
			if r.id() !in sh {
				sh[r.id()] = true
				hids << r.id()
			}
		} else if r.kind() == telem.kind_thread {
			k := '${tr.core}:${r.id()}'
			if k !in tseen {
				tseen[k] = true
				tkeys << k
			}
		} else if r.kind() == telem.kind_isr {
			k := '${tr.core}:${r.id()}'
			if k !in iseen {
				iseen[k] = true
				ikeys << k
			}
		}
	}
	hids.sort()
	tkeys.sort_with_compare(fn [app] (a &string, b &string) int {
		acore, aid := split_lane_key(a)
		bcore, bid := split_lane_key(b)
		ap := if t := app.manifest.by_tid[telem.tkey(acore, aid)] { t.prio } else { -1 }
		bp := if t := app.manifest.by_tid[telem.tkey(bcore, bid)] { t.prio } else { -1 }
		// known priorities first (ascending: p0 on top), then unknowns by id
		if ap >= 0 && bp >= 0 {
			if ap != bp {
				return if ap < bp { -1 } else { 1 }
			}
			return if aid < bid {
				-1
			} else {
				if aid > bid { 1 } else { 0 }
			}
		}
		if ap >= 0 {
			return -1
		}
		if bp >= 0 {
			return 1
		}
		return if aid < bid {
			-1
		} else {
			if aid > bid { 1 } else { 0 }
		}
	})
	ikeys.sort()
	// lay lanes out grouped by core: FB (handler) lanes first (by core), then a separator + thread
	// lanes (by core; real threads before idle within a core), then a separator + ISR lanes. So
	// each core's fb / thread / interrupt traces are visually grouped and split.
	mut lane_of := map[string]int{}
	mut labels := []string{}
	for core in 0 .. 16 {
		for id in hids {
			if handler_core(app, id) == core && 'h${id}' !in lane_of {
				lane_of['h${id}'] = labels.len
				labels << fb_label(app, id)
			}
		}
	}
	for id in hids { // unknown-core handlers (no manifest) last
		if 'h${id}' !in lane_of {
			lane_of['h${id}'] = labels.len
			labels << fb_label(app, id)
		}
	}
	if tkeys.len > 0 {
		labels << '──  threads  ──' // separator lane (no bars)
		for pass in 0 .. 2 { // pass 0 = real threads, pass 1 = idle (id 0) — idle at each core's foot
			for core in 0 .. 16 {
				for k in tkeys {
					kc, kid := split_lane_key(k)
					idle := kid == 0
					if kc == core && ((pass == 0 && !idle) || (pass == 1 && idle))
						&& 't${k}' !in lane_of {
						lane_of['t${k}'] = labels.len
						labels << thread_core_label(app, kc, kid)
					}
				}
			}
		}
		for k in tkeys { // cores outside 0..16 (garbage/unexpected header) — never drop a lane
			if 't${k}' !in lane_of {
				kc, kid := split_lane_key(k)
				lane_of['t${k}'] = labels.len
				labels << thread_core_label(app, kc, kid)
			}
		}
	}
	if ikeys.len > 0 {
		labels << '──  interrupts  ──' // separator lane (no bars)
		for core in 0 .. 16 {
			for k in ikeys {
				kc, kid := split_lane_key(k)
				if kc == core && 'i${k}' !in lane_of {
					lane_of['i${k}'] = labels.len
					labels << 'c${kc}  isr ${kid}'
				}
			}
		}
		for k in ikeys { // cores outside 0..16 — same catch-all as threads
			if 'i${k}' !in lane_of {
				kc, kid := split_lane_key(k)
				lane_of['i${k}'] = labels.len
				labels << 'c${kc}  isr ${kid}'
			}
		}
	}
	// time span over every interval record (abs_us folds epoch re-anchors; every kind has width).
	// Work in u64 and subtract tmin BEFORE the f32 cast: absolute µs can exceed f32's 24-bit
	// precision (~16.7 s) on a long capture, but the relative offsets are small and f32-exact.
	mut tmin := u64(0xffff_ffff_ffff_ffff)
	mut tmax := u64(0)
	for tr in trecs {
		s := tr.abs_us
		e := s + u64(tr.rec.cpu_us)
		if s < tmin {
			tmin = s
		}
		if e > tmax {
			tmax = e
		}
	}
	// TIME-BASE RECONSTRUCTION. A thread record's cpu_us is ISR-SUBTRACTED duration, but bar
	// positions are wall time — drawn as [start, start+cpu] a slice ends BEFORE reality and
	// overlaps ISR bars. Re-add the overlapping ISR durations to get the wall extent, then chop
	// the slice around the ISR spans: what remains is where the thread's code actually ran.
	// FB bars clip to these chunks (an FB record's duration IS wall — the Loom hook brackets by
	// clock), so neither a thread nor its FB can ever overlap an ISR again.
	mut isr_spans := map[int][]Span{}
	for tr in trecs {
		if tr.rec.kind() == telem.kind_isr {
			isr_spans[tr.core] << Span{tr.abs_us, tr.abs_us + u64(tr.rec.cpu_us)}
		}
	}
	for c, _ in isr_spans {
		isr_spans[c].sort(a.s < b.s)
	}
	mut tsl_key := []string{} // '<core>:<tid>' per thread slice
	mut tsl_core := []int{}
	mut tsl_id := []u16{}
	mut tsl_s := []u64{} // wall start
	mut tsl_e := []u64{} // wall END (ISR-extended)
	mut tsl_pre := []bool{} // ended by preemption
	mut tsl_chunks := [][]Span{} // run chunks: [s..e] minus ISR spans
	for tr in trecs {
		if tr.rec.kind() != telem.kind_thread || tr.rec.id() == 0 {
			continue
		}
		s0 := tr.abs_us
		mut e0 := s0 + u64(tr.rec.cpu_us)
		spans := isr_spans[tr.core] or { []Span{} }
		for isp in spans {
			if isp.s >= s0 && isp.s < e0 {
				e0 += isp.e - isp.s // an ISR inside the slice: the wall end moves right
			}
		}
		mut chunks := []Span{}
		mut cur := s0
		for isp in spans {
			if isp.e <= cur || isp.s >= e0 {
				continue
			}
			if isp.s > cur {
				chunks << Span{cur, isp.s}
			}
			if isp.e > cur {
				cur = isp.e
			}
		}
		if e0 > cur {
			chunks << Span{cur, e0}
		}
		tsl_key << '${tr.core}:${tr.rec.id()}'
		tsl_core << tr.core
		tsl_id << tr.rec.id()
		tsl_s << s0
		tsl_e << e0
		tsl_pre << (tr.rec.reason() == telem.reason_preempt)
		tsl_chunks << chunks
	}
	mut tslices := map[string][]Span{}
	for i, k in tsl_key {
		for ch in tsl_chunks[i] {
			tslices[k] << ch
		}
	}
	mut tid_of := map[string]u16{}
	for t in app.manifest.threads {
		tid_of[t.name] = t.id
	}
	if tmin > tmax { // no interval records — nothing to draw
		return labels, []vgui.Bar{}, []vgui.Link{}, f32(1)
	}
	span := if tmax > tmin { f32(tmax - tmin) } else { f32(1) }
	mut bars := []vgui.Bar{cap: trecs.len}
	for tr in trecs {
		r := tr.rec
		mut key := ''
		if r.kind() == telem.kind_fb {
			key = 'h${r.id()}'
		} else if r.kind() == telem.kind_thread {
			if r.id() != 0 {
				continue // real thread slices are drawn from the reconstructed chunks below
			}
			key = 't${tr.core}:${r.id()}'
		} else if r.kind() == telem.kind_isr {
			key = 'i${tr.core}:${r.id()}'
		} else {
			continue // CONTROL framing — no bar
		}
		li := lane_of[key]
		// colour by (block) core so cores are visually distinct.
		c := lane_palette[tr.core % lane_palette.len]
		// FB warn = overran/saturated (a deadline concept — belongs to the handler). The preempt
		// hatch is THREAD-ONLY: preemption happens to threads, never to functions — the FB lane
		// shows execution chunks and the thread lane below carries the scheduling story.
		warn := if r.kind() == telem.kind_fb
			&& (r.flags() & (telem.flag_overran | telem.flag_saturated)) != 0 {
			1
		} else {
			0
		}
		preempted := if r.kind() == telem.kind_thread && r.reason() == telem.reason_preempt {
			1
		} else {
			0
		}
		if r.kind() == telem.kind_fb {
			s0 := tr.abs_us
			e0 := s0 + u64(r.cpu_us)
			mut hrow_thread := ''
			if h := app.manifest.by_id[r.id()] {
				hrow_thread = h.thread
			}
			tid := tid_of[hrow_thread] or { u16(0) }
			if tid != 0 {
				spans := tslices['${tr.core}:${tid}'] or { []Span{} }
				mut chunks := []Span{}
				for sp in spans {
					cs := if sp.s > s0 { sp.s } else { s0 }
					ce := if sp.e < e0 { sp.e } else { e0 }
					if ce > cs {
						chunks << Span{cs, ce}
					}
				}
				if chunks.len > 0 {
					for ck in chunks {
						bars << vgui.Bar{
							t0:        f32(ck.s - tmin)
							dur:       f32(ck.e - ck.s)
							lane:      li
							color:     vgui.rgba(c[0], c[1], c[2], 235)
							warn:      warn
							preempted: 0 // functions don't get preempted — threads do (see the thread lane)
						}
					}
					continue
				}
			}
		}
		bars << vgui.Bar{
			t0:        f32(tr.abs_us - tmin) // relative µs (f32-exact even for long captures)
			dur:       f32(r.cpu_us)
			lane:      li
			color:     vgui.rgba(c[0], c[1], c[2], 235)
			warn:      warn
			preempted: preempted
		}
	}
	// thread execution chunks (ISR-chopped, wall-consistent), the torn edge on the LAST chunk of
	// a preempted slice, and a thin dim READY bar from the cut to the thread's next slice — the
	// whole preempted wait is visible, not just the cut instant.
	for i, k in tsl_key {
		li := lane_of['t${k}']
		c := lane_palette[tsl_core[i] % lane_palette.len]
		nch := tsl_chunks[i].len
		for j, ch in tsl_chunks[i] {
			bars << vgui.Bar{
				t0:        f32(ch.s - tmin)
				dur:       f32(ch.e - ch.s)
				lane:      li
				color:     vgui.rgba(c[0], c[1], c[2], 235)
				preempted: if tsl_pre[i] && j == nch - 1 { 1 } else { 0 }
			}
		}
		if tsl_pre[i] {
			// ready-but-waiting: until this thread's next slice starts
			mut nxt := u64(0)
			for j2, k2 in tsl_key {
				if k2 == k && tsl_s[j2] > tsl_e[i] && (nxt == 0 || tsl_s[j2] < nxt) {
					nxt = tsl_s[j2]
				}
			}
			if nxt > tsl_e[i] {
				bars << vgui.Bar{
					t0:    f32(tsl_e[i] - tmin)
					dur:   f32(nxt - tsl_e[i])
					lane:  li
					color: vgui.rgba(c[0], c[1], c[2], 90)
					style: 1
				}
			}
		}
	}
	// preemption cut-links: victim -> the thread whose slice starts at the (wall) cut.
	mut links := []vgui.Link{}
	for i, k in tsl_key {
		if !tsl_pre[i] {
			continue
		}
		cut := tsl_e[i]
		mut best_dt := u64(200)
		mut best_key := ''
		for j2, k2 in tsl_key {
			if k2 == k || tsl_core[j2] != tsl_core[i] {
				continue
			}
			dt := if tsl_s[j2] >= cut { tsl_s[j2] - cut } else { cut - tsl_s[j2] }
			if dt < best_dt {
				best_dt = dt
				best_key = k2
			}
		}
		if best_key != '' {
			links << vgui.Link{
				x:         f32(cut - tmin)
				lane_from: lane_of['t${k}']
				lane_to:   lane_of['t${best_key}']
			}
		}
	}
	return labels, bars, links, span
}

// ---- DBC Editor (docs/dbc_editor.md P1) -------------------------------------
// Edits the IN-MEMORY app.dbs — the same databases the Trace panel decodes
// against, so an edit re-decodes live traffic instantly. Save renders the
// canonical form (candb.to_dbc, fixpoint-tested) back to the loaded path;
// canonical order keeps the file git-diff-reviewable. All model mutations
// take app.mu briefly: decode runs on worker threads.
// NOTE: dbs_by_iface holds value copies (the generator picker) — it refreshes
// on save/reload, not per keystroke; the Trace union (app.dbs) is live.

struct DbcEd {
mut:
	db             int = -1 // dbs index
	msg            int = -1
	sig            int = -1
	dirty          map[string]bool // unsaved edits keyed by dbc PATH (survives rebuilds/index shifts)
	loaded_key     string          // which db:msg:sig the string buffers hold
	mname_buf      []u8
	sender_buf     []u8
	sname_buf      []u8
	unit_buf       []u8
	desc_buf       []u8
	msg_filter_buf []u8
	sig_filter_buf []u8
	val_key_buf    []u8
	val_name_buf   []u8
	node_buf       []u8
	view_tree      bool = true // toggle between Tree view and Table view
	left_w         f32  // draggable width (px) of the messages&signals pane; 0 = use the default
	// An in-progress bit-endpoint edit. An input field commits on EVERY keystroke, so a handler
	// that derives the width from the opposite endpoint would measure each keystroke against an
	// anchor the previous one already moved — typing a higher start collapsed the span to one
	// bit (#68). The edit is therefore held here and applied once, on deactivation, against the
	// anchor captured when it began.
	bit_edit_key    string // '<field>:<db>:<msg>:<sig>' while that field is being edited
	bit_edit_val    int    // the in-progress value (the field shows this, not the model)
	bit_edit_anchor int    // the opposite endpoint, snapshotted when the edit began
	bit_edit_db     int = -1 // where to apply it, kept apart from the key so resolve need not parse
	bit_edit_msg    int = -1
	bit_edit_sig    int = -1
	bit_edit_name   string // the signal's NAME at edit time — an index can be re-used after a
	// delete, and applying an edit to whatever now sits at that index would corrupt it
	bit_edit_msg_name string // and the MESSAGE's name: deleting a message shifts the next one
	// into the stored index, where a same-named signal (Counter, Status…) would pass a
	// name-only check and take the edit meant for a different message entirely
}

// resolve_pending_bit_edit applies a bit-endpoint edit still held in the editor's buffer.
//
// WHY A CHOKE POINT: deferring the commit to deactivation (so a per-keystroke commit cannot
// measure each digit against an anchor the previous one moved) opens a window where the FIELD
// holds the value and the model does not. Every action that reads or replaces app.dbs during
// that window would otherwise act on stale data — and the toolbar is drawn BEFORE the editor,
// so the very click that ends an edit is processed first: Start ran workers against the old
// schema, and Save serialised the old endpoint and only then committed, leaving the file dirty.
// Guarding each consumer separately is how that turned into a series of one-off patches; this
// is the single place the window is closed instead.
//
// Safe to call at any time: with no edit pending it does nothing.
fn (mut app App) resolve_pending_bit_edit() {
	if app.dbc_ed.bit_edit_key == '' {
		return
	}
	di := app.dbc_ed.bit_edit_db
	mi := app.dbc_ed.bit_edit_msg
	si := app.dbc_ed.bit_edit_sig
	is_start := app.dbc_ed.bit_edit_key.starts_with('start:')
	anchor := app.dbc_ed.bit_edit_anchor
	val := app.dbc_ed.bit_edit_val
	name := app.dbc_ed.bit_edit_name
	msg_name := app.dbc_ed.bit_edit_msg_name
	key := app.dbc_ed.bit_edit_key
	app.dbc_ed.bit_edit_key = '' // clear FIRST: every path below is now a no-op or an apply

	// Has the user moved on? The key names the signal the edit began on; if that is no longer
	// the selection, the edit was abandoned by clicking away and must not be committed.
	// This check belongs HERE and not at the top of the editor, because the toolbar is drawn
	// before the editor (main.v ~1322 vs ~1368): pressing Start after selecting a different
	// signal reached the resolver first, and the stored names/indices still matched the
	// original signal — which exists and is unchanged — so an abandoned edit was applied and
	// the DBC marked dirty, blocking the run. Every caller funnels through here, so one check
	// covers Start, Save, rebuild and deactivation alike.
	if !key.ends_with(':${app.dbc_ed.db}:${app.dbc_ed.msg}:${app.dbc_ed.sig}') {
		return
	}

	// `warn` is collected under the lock and emitted after it. notify() takes app.mu, which is
	// not recursive, so notifying from in here deadlocks the app on the value-table path —
	// reachable from deactivation, Save, Start and rebuild alike.
	mut warn := '' // refuses the edit outright
	mut note := '' // the edit is applied, but not exactly as typed
	mut dirty := -1
	app.mu.lock()
	ok := di >= 0 && di < app.dbs.len && mi >= 0 && mi < app.dbs[di].messages.len
		&& si >= 0 && si < app.dbs[di].messages[mi].signals.len
	if ok && app.dbs[di].messages[mi].name == msg_name
		&& app.dbs[di].messages[mi].signals[si].name == name {
		// Both names must match. An index alone is not identity: deleting a message shifts the
		// next into its slot, and a same-named signal there would otherwise take this edit.
		sg := app.dbs[di].messages[mi].signals[si]
		be := sg.byte_order == .big_endian
		mut ns := sg.start_bit
		mut nl := sg.length
		if is_start {
			ns = if val < 0 { 0 } else { val }
			if !be && ns > anchor {
				ns = anchor // start cannot pass stop: the span may not invert
			}
			if !be {
				// A signal is at most 64 bits, and editing the START must hold the STOP — that
				// is the whole contract of the two fields. Capping the LENGTH here would keep
				// the typed start and drag the stop down with it (100..107, start := 0, gives
				// 0..63: the stop silently moved from 107 to 63 and the signal decodes
				// completely different bits). Clamp the start instead, so the anchor survives
				// and the span is the widest legal one that still ends where it did.
				if anchor - ns + 1 > 64 {
					ns = anchor - 63
					note = 'start clamped to ${ns}: a signal is at most 64 bits and the stop bit ${anchor} is held'
				}
				nl = anchor - ns + 1
			}
		} else {
			nl = if be { val } else { val - anchor + 1 }
		}
		if nl < 1 {
			nl = 1
		}
		if nl > 64 {
			nl = 64
		}
		// the value-table guard both fields enforce: a narrowing that cannot hold the existing
		// VAL_ keys is refused, or the writer masks them on save and remaps or collides them
		nmask := if nl >= 64 { ~u64(0) } else { (u64(1) << nl) - 1 }
		mut clash := false
		for k, _ in sg.values {
			if k & ~nmask != 0 {
				clash = true
			}
		}
		if clash {
			warn = '${sg.name}: ${nl} bit(s) cannot hold the existing value-table keys — edit discarded'
		} else {
			app.dbs[di].messages[mi].signals[si].start_bit = ns
			app.dbs[di].messages[mi].signals[si].length = nl
			dirty = di
		}
	}
	app.mu.unlock()
	if dirty >= 0 {
		app.mark_dirty(dirty)
	}
	if warn != '' {
		app.notify(warn)
	}
	if note != '' {
		app.notify(note)
	}
}

// cancel_pending_bit_edit drops an in-progress endpoint edit without applying it. Used where
// the database it referred to is about to be replaced by something the user did NOT edit —
// Revert being the case that matters, since resolving there would write the pending value
// onto the freshly reloaded file.
fn (mut app App) cancel_pending_bit_edit() {
	app.dbc_ed.bit_edit_key = ''
}

// dbc_ed_color: a deterministic per-signal palette for the bit grid.
fn dbc_ed_color(i int) (int, int, int) {
	return match i % 8 {
		0 { 86, 156, 214 }
		1 { 220, 170, 80 }
		2 { 120, 190, 120 }
		3 { 200, 120, 190 }
		4 { 100, 200, 200 }
		5 { 230, 130, 110 }
		6 { 150, 150, 220 }
		else { 180, 200, 100 }
	}
}

// dbc_ident_ok: message/signal/sender names are UNQUOTED DBC tokens — a space
// or punctuation would emit a record our own parser rejects.
fn dbc_ident_ok(sv string) bool {
	if sv == '' {
		return false
	}
	for i, c in sv {
		alpha := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
		if i == 0 && !alpha {
			return false
		}
		if !(alpha || (c >= `0` && c <= `9`)) {
			return false
		}
	}
	return true
}

// dbc_signal_bits lists the global LSB-0 bit positions a signal occupies —
// the same walk candb.raw_value takes (Intel ascending, Motorola sawtooth).
fn dbc_signal_bits(s candb.Signal) []int {
	mut out := []int{cap: s.length}
	if s.byte_order == .little_endian {
		for i in 0 .. s.length {
			out << s.start_bit + i
		}
	} else {
		mut pos := s.start_bit
		for _ in 0 .. s.length {
			out << pos
			if pos % 8 == 0 {
				pos = pos + 15 // drop to the next byte's bit 7
			} else {
				pos--
			}
		}
	}
	return out
}

// dbc_ed_load_bufs refreshes the string edit buffers when the selection moves.
fn (mut app App) dbc_ed_load_bufs() {
	key := '${app.dbc_ed.db}:${app.dbc_ed.msg}:${app.dbc_ed.sig}'
	if app.dbc_ed.msg_filter_buf.len == 0 {
		app.dbc_ed.msg_filter_buf = mkbuf('', 64)
	}
	if app.dbc_ed.sig_filter_buf.len == 0 {
		app.dbc_ed.sig_filter_buf = mkbuf('', 64)
	}
	if app.dbc_ed.val_key_buf.len == 0 {
		app.dbc_ed.val_key_buf = mkbuf('', 24)
	}
	if app.dbc_ed.val_name_buf.len == 0 {
		app.dbc_ed.val_name_buf = mkbuf('', 96)
	}
	if app.dbc_ed.node_buf.len == 0 {
		app.dbc_ed.node_buf = mkbuf('', 48)
	}
	if app.dbc_ed.loaded_key == key {
		return
	}
	app.dbc_ed.loaded_key = key
	di, mi, si := app.dbc_ed.db, app.dbc_ed.msg, app.dbc_ed.sig
	if di < 0 || di >= app.dbs.len || mi < 0 || mi >= app.dbs[di].messages.len {
		return
	}
	m := app.dbs[di].messages[mi]
	// buffers sized past the current content: mkbuf's cap includes the NUL, so
	// a fixed cap would silently truncate long fields on first edit
	app.dbc_ed.mname_buf = mkbuf(m.name, m.name.len + 96)
	app.dbc_ed.sender_buf = mkbuf(m.sender, m.sender.len + 96)
	if si >= 0 && si < m.signals.len {
		sg := m.signals[si]
		app.dbc_ed.sname_buf = mkbuf(sg.name, sg.name.len + 96)
		app.dbc_ed.unit_buf = mkbuf(sg.unit, sg.unit.len + 64)
		app.dbc_ed.desc_buf = mkbuf(sg.desc, sg.desc.len + 256)
	}
}

// dbc_refresh_if_all_clean re-reads sims/dbs_by_iface/generator caches from
// disk once NO database holds unsaved edits (the rebuild re-reads every
// file). Preserves the editor's selected database across the index shuffle.
fn (mut app App) dbc_refresh_if_all_clean() {
	for _, d in app.dbc_ed.dirty {
		if d {
			app.notify('sim/generator databases refresh after ALL DBCs are saved')
			return
		}
	}
	sel_path := if app.dbc_ed.db >= 0 && app.dbc_ed.db < app.dbs_paths.len {
		app.dbs_paths[app.dbc_ed.db]
	} else {
		''
	}
	app.rebuild_preserving_senders()
	if sel_path != '' {
		app.dbc_ed.db = app.dbs_paths.index(sel_path)
	}
}

// dbc_refresh_trace_names re-resolves the cached name on captured trace rows
// after a message rename / id / kind edit — they hold the name captured at
// arrival and would otherwise display the stale identity.
fn (mut app App) dbc_refresh_trace_names() {
	app.mu.lock()
	for i, r in app.trace {
		nn := app.lookup_name(r.id, r.ext)
		if nn != r.name {
			app.trace[i] = TraceRow{
				...r
				name: nn
			}
		}
	}
	app.mu.unlock()
}

fn (app &App) db_path(di int) string {
	if di >= 0 && di < app.dbs_paths.len {
		return app.dbs_paths[di]
	}
	if di >= 0 && di < app.dbs.len {
		return 'dbc_${di}'
	}
	return ''
}

fn (mut app App) mark_dirty(di int) {
	pth := app.db_path(di)
	if pth != '' {
		app.dbc_ed.dirty[pth] = true
	}
}

fn draw_dbc_editor(mut app App) {
	// Cancel an edit the user walked away from — before ANY early return below, so selecting
	// the message, reverting the database or deleting the signal cannot leave it pending.
	//
	// This is NOT redundant with the identical-looking check in resolve_pending_bit_edit(),
	// and removing it as a duplicate was wrong. They answer different questions:
	//   here      — every frame: has the selection moved? then DROP the state, so reselecting
	//               the original signal cannot resurrect its stale value in the field.
	//   resolver  — on commit: does the key still name the selection? then REFUSE to apply,
	//               which is what catches Start, since the toolbar draws before this panel.
	// Without this one, edit A → select B → reselect A brought the abandoned value back and
	// let it be committed. Without the other, Start committed it outright. Selection is
	// assigned in a dozen places, so detecting the change per frame beats asking every
	// assignment site to remember.
	if app.dbc_ed.bit_edit_key != ''
		&& !app.dbc_ed.bit_edit_key.ends_with(':${app.dbc_ed.db}:${app.dbc_ed.msg}:${app.dbc_ed.sig}') {
		app.dbc_ed.bit_edit_key = ''
	}
	vis, op := vgui.begin_closable('DBC Editor', app.show_dbc)
	app.show_dbc = op
	if !vis {
		vgui.end()
		return
	}
	if app.dbs.len == 0 {
		vgui.text_dim('no DBCs loaded — attach one to a channel (Config panel)')
		vgui.end()
		return
	}
	app.dbc_ed_load_bufs()
	// READ-ONLY while a measurement runs: rx/sim/generator workers iterate
	// app.dbs lock-free, and the save path rebuilds runtime state — both are
	// only safe stopped. (Editing a stopped capture still re-decodes it live:
	// the trace decodes signal values at draw time.)
	app.mu.lock()
	live_readers := app.dbc_readers
	app.mu.unlock()
	ro := app.running || live_readers > 0
	if ro {
		vgui.text_colored(230, 170, 70,
			'read-only while measuring — Stop to edit (workers drain briefly after Stop)')
	}
	// a project swap replaces dbs_paths: dirty entries for paths no longer
	// attached are unreachable ghosts — drop them (the swap discarded those
	// databases; keeping the flags would wedge Start forever)
	for pth, _ in app.dbc_ed.dirty.clone() {
		if app.dbs_paths.index(pth) < 0 {
			app.dbc_ed.dirty.delete(pth)
			app.notify('unsaved DBC edits for detached ${os.file_name(pth)} were discarded')
		}
	}
	sc := app.ui_scale

	// ---- TOP CONTROL BAR: Database selector, Save / Revert, ECU Nodes ----
	mut names := []string{cap: app.dbs.len}
	for i, db in app.dbs {
		pth := app.db_path(i)
		mark := if pth != '' && app.dbc_ed.dirty[pth] { '` ' } else { '' }
		disp := if i < app.dbs_paths.len { '${os.file_name(os.dir(pth))}/${os.file_name(pth)}' } else { 'DBC #${i}' }
		names << '${mark}${disp} (${db.messages.len} msgs) ##${i}'
	}
	if app.dbc_ed.db < 0 && app.dbs.len > 0 {
		app.dbc_ed.db = 0
	}
	vgui.set_next_item_width(280 * sc)
	ndb := vgui.combo('database', names, app.dbc_ed.db)
	if ndb != app.dbc_ed.db {
		app.dbc_ed.db = ndb
		app.dbc_ed.msg = -1
		app.dbc_ed.sig = -1
	}
	di := app.dbc_ed.db
	if di < 0 || di >= app.dbs.len {
		vgui.end()
		return
	}
	dbc_path := app.db_path(di)

	// save / revert controls
	vgui.same_line()
	if !ro && dbc_path != '' && app.dbc_ed.dirty[dbc_path] {
		vgui.text_colored(230, 170, 70, '` modified')
		vgui.same_line()
	}
	if !ro && dbc_path != '' && vgui.small_button('Save') {
		// resolve first: this button is processed before the inspector, so without it the old
		// endpoint is serialised and the edit commits afterwards, leaving the file dirty again
		app.resolve_pending_bit_edit()
		app.mu.lock()
		for m in app.dbs[di].messages {
			if m.sender != '' && m.sender !in app.dbs[di].nodes {
				app.dbs[di].nodes << m.sender
			}
		}
		text := app.dbs[di].to_dbc()
		app.mu.unlock()
		tmp := dbc_path + '.tmp~'
		mut save_ok := true
		os.write_file(tmp, text) or {
			app.notify('dbc save failed (edits kept in memory): ${err}')
			save_ok = false
		}
		if save_ok {
			os.mv(tmp, dbc_path) or {
				os.rm(tmp) or {}
				app.notify('dbc save failed (edits kept in memory): ${err}')
				save_ok = false
			}
		}
		if save_ok {
			app.dbc_ed.dirty.delete(dbc_path)
			app.dbc_ed.loaded_key = ''
			app.notify('saved ${dbc_path}')
			app.dbc_refresh_trace_names()
			app.dbc_refresh_if_all_clean()
		}
	}
	vgui.same_line()
	if !ro && dbc_path != '' && vgui.small_button('Revert') {
		if db := candb.load_dbc_file(dbc_path) {
			// Cancel only on SUCCESS. Revert reloads the file and then refreshes, which reaches
			// the resolver before the next frame can cancel on selection mismatch, so the
			// pending value would land on the database the user just discarded. But if the
			// file has been deleted, made unreadable or become unparsable, the revert does not
			// happen at all — the database and its other in-memory edits stay — and dropping
			// the endpoint edit there would lose typing for an operation that failed.
			app.cancel_pending_bit_edit()
			app.mu.lock()
			app.dbs[di] = db
			app.mu.unlock()
			app.dbc_ed.dirty.delete(dbc_path)
			app.dbc_ed.msg = -1
			app.dbc_ed.sig = -1
			app.dbc_ed.loaded_key = ''
			app.notify('reverted ${dbc_path}')
			app.dbc_refresh_trace_names()
			mut kept := []Watch{cap: app.watch.len}
			for w in app.watch {
				if m := app.find_message(w.id, w.ext) {
					mut have := false
					for sg in m.signals {
						if sg.name == w.sig {
							have = true
						}
					}
					if have {
						kept << w
					}
				}
			}
			if kept.len != app.watch.len {
				app.notify('${app.watch.len - kept.len} plotted signal(s) removed: not in the reverted DBC')
			}
			app.watch = kept
			app.dbc_refresh_if_all_clean()
		} else {
			app.notify('dbc revert failed: ${err}')
		}
	}

	// ECU Nodes (BU_) inline section
	vgui.same_line()
	if vgui.tree_node('ECU Nodes (BU_) [${app.dbs[di].nodes.len}]##bunodes') {
		app.dbc_ed_load_bufs()
		if app.dbs[di].nodes.len > 0 {
			for ni, nname in app.dbs[di].nodes {
				vgui.text_colored(120, 190, 120, nname)
				vgui.same_line()
				if !ro && vgui.small_button('-##delnode_${ni}') {
					app.mu.lock()
					app.dbs[di].nodes.delete(ni)
					app.mu.unlock()
					app.mark_dirty(di)
				}
				vgui.same_line()
			}
		} else {
			vgui.text_dim('no ECU nodes declared')
			vgui.same_line()
		}
		if !ro {
			vgui.set_next_item_width(120 * sc)
			vgui.input_text('node name##newnode', mut app.dbc_ed.node_buf)
			vgui.same_line()
			if vgui.small_button('+ ECU Node') {
				nname := vgui.buf_str(app.dbc_ed.node_buf).trim_space()
				if dbc_ident_ok(nname) && nname !in app.dbs[di].nodes {
					app.mu.lock()
					app.dbs[di].nodes << nname
					app.mu.unlock()
					app.mark_dirty(di)
					app.dbc_ed.node_buf = mkbuf('', 48)
				} else {
					app.notify('invalid or duplicate ECU node name')
				}
			}
		}
		vgui.tree_pop()
	}

	vgui.separator()

	// ---- MAIN SPLIT PANES: Left (Navigation) vs Right (Inspector & Layout) ----
	// draggable divider (splitter_v below); width persists in dbc_ed.left_w
	if app.dbc_ed.left_w <= 0 {
		app.dbc_ed.left_w = 340 * sc
	}
	left_w := app.dbc_ed.left_w
	vgui.child_wh('##dbced_left_pane', left_w, 0)

	// --- LEFT PANE: Messages & Signals Browser ---
	vgui.separator_text('messages & signals')
	vgui.set_next_item_width(150 * sc)
	vgui.input_text('filter##mf', mut app.dbc_ed.msg_filter_buf)
	vgui.same_line()
	app.dbc_ed.view_tree = vgui.checkbox('Tree##tv', app.dbc_ed.view_tree)
	mfilter := vgui.buf_str(app.dbc_ed.msg_filter_buf).to_lower()

	// Messages tree/list child
	vgui.child_begin('##dbcmsgbox', 220 * sc)
	if app.dbc_ed.view_tree {
		for i, m in app.dbs[di].messages {
			idtxt := if m.ext { '0x${m.id.hex()}x' } else { '0x${m.id.hex()}' }
			if mfilter != '' {
				name_match := m.name.to_lower().contains(mfilter)
				id_match := idtxt.to_lower().contains(mfilter) || '${m.id}'.contains(mfilter)
				sender_match := m.sender.to_lower().contains(mfilter)
				if !name_match && !id_match && !sender_match {
					continue
				}
			}
			sender_tag := if m.sender != '' { ' [${m.sender}]' } else { '' }
			is_msg_open := vgui.tree_node('${idtxt} ${m.name}${sender_tag} (${m.signals.len})###treem_${i}')
			if vgui.is_item_clicked() {
				if app.dbc_ed.msg != i {
					app.dbc_refresh_trace_names()
				}
				app.dbc_ed.msg = i
				app.dbc_ed.sig = -1
			}
			if is_msg_open {
				for si, sg in m.signals {
					cr, cg, cb := dbc_ed_color(si)
					vgui.text_colored(u8(cr), u8(cg), u8(cb), ' #')
					vgui.same_line()
					or_tag := if sg.byte_order == .little_endian { 'LE' } else { 'BE' }
					sgn := if sg.is_signed { 'i' } else { 'u' }
					end_b := sg.start_bit + sg.length - 1
					if vgui.selectable('${sg.name} [b${sg.start_bit}..${end_b}] @${or_tag} ${sgn}${sg.length}##tsig_${i}_${si}',
						app.dbc_ed.msg == i && app.dbc_ed.sig == si)
					{
						app.dbc_ed.msg = i
						app.dbc_ed.sig = si
					}
				}
				vgui.tree_pop()
			}
		}
	} else {
		for i, m in app.dbs[di].messages {
			idtxt := if m.ext { '0x${m.id.hex()}x' } else { '0x${m.id.hex()}' }
			if mfilter != '' {
				name_match := m.name.to_lower().contains(mfilter)
				id_match := idtxt.to_lower().contains(mfilter) || '${m.id}'.contains(mfilter)
				sender_match := m.sender.to_lower().contains(mfilter)
				if !name_match && !id_match && !sender_match {
					continue
				}
			}
			if vgui.selectable('${idtxt} ${m.name} (dlc ${m.dlc})##dm${i}', app.dbc_ed.msg == i) {
				if app.dbc_ed.msg != i {
					app.dbc_refresh_trace_names()
				}
				app.dbc_ed.msg = i
				app.dbc_ed.sig = -1
			}
		}
	}
	vgui.child_end()

	// Message Action Buttons
	if !ro && vgui.small_button('+ message') {
		app.mu.lock()
		mut nid := u32(0x100)
		mut id_free := false
		for {
			mut taken := false
			for m in app.dbs[di].messages {
				if !m.ext && m.id == nid {
					taken = true
				}
			}
			if !taken {
				id_free = true
				break
			}
			if nid >= 0x7FF {
				break
			}
			nid++
		}
		if !id_free {
			app.mu.unlock()
			app.notify('no free standard id in 0x100..0x7FF — delete a message or use extended ids')
			vgui.child_end()
			vgui.end()
			return
		}
		mut mname := 'NewMessage'
		mut mn := 1
		for {
			mut taken := false
			for odb in app.dbs {
				for m in odb.messages {
					if m.name == mname {
						taken = true
					}
				}
			}
			if !taken {
				break
			}
			mn++
			mname = 'NewMessage${mn}'
		}
		app.dbs[di].messages << candb.Message{
			name: mname
			id:   nid
			dlc:  8
		}
		app.mu.unlock()
		app.dbc_ed.msg = app.dbs[di].messages.len - 1
		app.dbc_ed.sig = -1
		app.mark_dirty(di)
		app.dbc_ed.loaded_key = ''
	}
	mi := app.dbc_ed.msg
	if mi >= 0 && mi < app.dbs[di].messages.len {
		vgui.same_line()
		if !ro && vgui.small_button('- delete message') {
			app.mu.lock()
			app.dbs[di].messages.delete(mi)
			app.mu.unlock()
			app.dbc_ed.msg = -1
			app.dbc_ed.sig = -1
			app.mark_dirty(di)
			app.dbc_ed.loaded_key = ''
			app.dbc_refresh_trace_names()
			vgui.child_end()
			vgui.end()
			return
		}

		// Signals List for Selected Message
		vgui.separator_text('signals (${app.dbs[di].messages[mi].signals.len})')
		vgui.set_next_item_width(180 * sc)
		vgui.input_text('filter signals##sf', mut app.dbc_ed.sig_filter_buf)
		sfilter := vgui.buf_str(app.dbc_ed.sig_filter_buf).to_lower()

		vgui.child_begin('##dbcsigbox', 180 * sc)
		if vgui.table_begin('##dbcsigtable', 4) {
			vgui.table_setup_col('#', 18 * sc)
			vgui.table_setup_col('name', 130 * sc)
			vgui.table_setup_col('start|len', 65 * sc)
			vgui.table_setup_col('fmt', 45 * sc)
			vgui.table_headers()
			for i, sg in app.dbs[di].messages[mi].signals {
				if sfilter != '' {
					name_match := sg.name.to_lower().contains(sfilter)
					unit_match := sg.unit.to_lower().contains(sfilter)
					desc_match := sg.desc.to_lower().contains(sfilter)
					if !name_match && !unit_match && !desc_match {
						continue
					}
				}
				or_tag := if sg.byte_order == .little_endian { 'LE' } else { 'BE' }
				sgn := if sg.is_signed { 'i' } else { 'u' }
				cr, cg, cb := dbc_ed_color(i)
				vgui.table_row()
				vgui.table_next_col()
				vgui.text_colored(u8(cr), u8(cg), u8(cb), '#')
				vgui.table_next_col()
				if vgui.selectable('${sg.name}##ds${i}', app.dbc_ed.sig == i) {
					app.dbc_ed.sig = i
				}
				vgui.table_cell('${sg.start_bit}|${sg.length}')
				vgui.table_cell('@${or_tag}${sgn}')
			}
			vgui.table_end()
		}
		vgui.child_end()

		if !ro && vgui.small_button('+ signal') {
			app.mu.lock()
			mut top := 0
			for sg in app.dbs[di].messages[mi].signals {
				for g in dbc_signal_bits(sg) {
					if g + 1 > top {
						top = g + 1
					}
				}
			}
			mut nn := 1
			mut nname := 'NewSignal'
			for {
				mut taken := false
				for sg in app.dbs[di].messages[mi].signals {
					if sg.name == nname {
						taken = true
					}
				}
				if !taken {
					break
				}
				nn++
				nname = 'NewSignal${nn}'
			}
			app.dbs[di].messages[mi].signals << candb.Signal{
				name:      nname
				start_bit: top
				length:    8
			}
			app.mu.unlock()
			app.dbc_ed.sig = app.dbs[di].messages[mi].signals.len - 1
			app.mark_dirty(di)
			app.dbc_ed.loaded_key = ''
		}
		si_left := app.dbc_ed.sig
		if si_left >= 0 && si_left < app.dbs[di].messages[mi].signals.len {
			vgui.same_line()
			if !ro && vgui.small_button('- delete signal') {
				if app.dbs[di].messages[mi].signals[si_left].is_multiplexor {
					mut deps := 0
					for oi, osg in app.dbs[di].messages[mi].signals {
						if oi != si_left && osg.is_multiplexed {
							deps++
						}
					}
					if deps > 0 {
						app.notify('cannot delete the multiplexor switch: ${deps} multiplexed signal(s) depend on it')
						vgui.child_end()
						vgui.end()
						return
					}
				}
				app.mu.lock()
				app.dbs[di].messages[mi].signals.delete(si_left)
				app.mu.unlock()
				app.dbc_ed.sig = -1
				app.mark_dirty(di)
				app.dbc_ed.loaded_key = ''
				vgui.child_end()
				vgui.end()
				return
			}
		}
	}
	vgui.child_end() // end left pane

	// draggable divider: grow/shrink the left (messages & signals) pane vs the right (inspector)
	vgui.same_line()
	// Clamp the persisted width against what the panel has NOW: left_w survives docking and
	// resizing, so a divider dragged wide in a large window could otherwise consume a narrower
	// one entirely and leave the inspector unreachable (#68). The right pane keeps 200*sc.
	// content_avail_w() is called AFTER the left child and same_line(), so it reports only the
	// space to the RIGHT of the left pane. Treating that as the panel total made max_left shrink
	// as the user widened the pane, dragging the divider back on the next frame (#69). The panel
	// total is the left pane plus what remains beside it.
	avail := vgui.content_avail_w()
	total_w := app.dbc_ed.left_w + avail
	mut max_left := 760 * sc
	if total_w > 0 && total_w - 200 * sc < max_left {
		max_left = total_w - 200 * sc
	}
	if max_left < 200 * sc {
		max_left = 200 * sc
	}
	if app.dbc_ed.left_w > max_left {
		app.dbc_ed.left_w = max_left
	}
	app.dbc_ed.left_w = vgui.splitter_v('##dbced_split', app.dbc_ed.left_w, 200 * sc, max_left)
	vgui.same_line()

	// --- RIGHT PANE: Message Properties, Bit Layout Grid, Signal Inspector ---
	vgui.child_wh('##dbced_right_pane', 0, 0)

	if mi < 0 || mi >= app.dbs[di].messages.len {
		vgui.text_dim('select a message on the left to edit properties & bit layout')
		vgui.child_end()
		vgui.end()
		return
	}

	msg := app.dbs[di].messages[mi]

	// 1. Message Properties Form
	id_hex_str := if msg.ext { '0x${msg.id.hex()}x' } else { '0x${msg.id.hex()}' }
	vgui.separator_text('Message Properties: ${msg.name} (${id_hex_str})')
	app.dbc_ed_load_bufs()

	vgui.set_next_item_width(160 * sc)
	if !ro && vgui.input_text('name##dbcm', mut app.dbc_ed.mname_buf) {
		nv := vgui.buf_str(app.dbc_ed.mname_buf)
		mut mname_taken := false
		for odi, odb in app.dbs {
			for oi, om in odb.messages {
				if !(odi == di && oi == mi) && om.name == nv {
					mname_taken = true
				}
			}
		}
		if dbc_ident_ok(nv) && !mname_taken {
			app.mu.lock()
			app.dbs[di].messages[mi].name = nv
			app.mu.unlock()
			app.mark_dirty(di)
		}
	}
	if !dbc_ident_ok(vgui.buf_str(app.dbc_ed.mname_buf)) {
		vgui.same_line()
		vgui.text_colored(205, 60, 60, 'invalid name')
	}

	vgui.same_line()
	mut idv := int(msg.id)
	vgui.set_next_item_width(100 * sc)
	if !ro && vgui.input_int('id (dec)', &idv) {
		id_max := if msg.ext { 0x1FFF_FFFF } else { 0x7FF }
		cl := if idv < 0 {
			0
		} else if idv > id_max {
			id_max
		} else {
			idv
		}
		mut id_taken := false
		for oi, om in app.dbs[di].messages {
			if oi != mi && om.id == u32(cl) && om.ext == msg.ext {
				id_taken = true
			}
		}
		if !id_taken {
			old_id := msg.id
			wext0 := msg.ext
			app.mu.lock()
			app.dbs[di].messages[mi].id = u32(cl)
			app.mu.unlock()
			mut id_shadowed := false
			for odi in 0 .. di {
				for om in app.dbs[odi].messages {
					if om.id == old_id && om.ext == wext0 {
						id_shadowed = true
					}
				}
			}
			for wi, w in app.watch {
				if id_shadowed {
					break
				}
				if w.id == old_id && w.ext == wext0 {
					app.watch[wi] = Watch{
						id:  u32(cl)
						ext: w.ext
						sig: w.sig
					}
				}
			}
			app.mark_dirty(di)
		} else {
			app.notify('id 0x${u32(cl).hex()} already used by another frame — not applied')
		}
	}
	vgui.same_line()
	vgui.text_dim('= 0x${msg.id.hex()}')

	vgui.same_line()
	next := vgui.checkbox('ext##dbcm', msg.ext)
	if !ro && next != msg.ext {
		mut nid := msg.id
		if !next && nid > 0x7FF {
			nid = 0x7FF
		}
		mut clash := false
		for oi, om in app.dbs[di].messages {
			if oi != mi && om.id == nid && om.ext == next {
				clash = true
			}
		}
		if clash {
			app.notify('cannot flip ext: 0x${nid.hex()} already exists as that frame kind')
		} else {
			old_id2 := msg.id
			old_ext2 := msg.ext
			app.mu.lock()
			app.dbs[di].messages[mi].ext = next
			app.dbs[di].messages[mi].id = nid
			app.mu.unlock()
			mut kind_shadowed := false
			for odi in 0 .. di {
				for om in app.dbs[odi].messages {
					if om.id == old_id2 && om.ext == old_ext2 {
						kind_shadowed = true
					}
				}
			}
			for wi, w in app.watch {
				if kind_shadowed {
					break
				}
				if w.id == old_id2 && w.ext == old_ext2 {
					app.watch[wi] = Watch{
						id:  nid
						ext: next
						sig: w.sig
					}
				}
			}
			app.mark_dirty(di)
		}
	}

	// second row: framing (dlc / cycle / sender) — keeps the identity row (name / id / ext)
	// from running off the right edge.
	mut dlcv := msg.dlc
	vgui.set_next_item_width(70 * sc)
	if !ro && vgui.input_int('dlc', &dlcv) {
		app.mu.lock()
		app.dbs[di].messages[mi].dlc = if dlcv < 0 { 0 } else if dlcv > 64 { 64 } else { dlcv }
		app.mu.unlock()
		app.mark_dirty(di)
	}

	vgui.same_line()
	mut cycv := msg.cycle_ms
	vgui.set_next_item_width(70 * sc)
	if !ro && vgui.input_int('cycle ms', &cycv) {
		app.mu.lock()
		app.dbs[di].messages[mi].cycle_ms = if cycv < 0 { 0 } else { cycv }
		app.mu.unlock()
		app.mark_dirty(di)
	}

	// sender = the transmitting ECU. PICK it from the declared ECU nodes (BU_) — you can't invent
	// an arbitrary sender. Add/remove nodes under "ECU Nodes (BU_)" at the top; "(none)" = no
	// sender. A loaded frame naming a not-yet-declared node still shows it (Save adds it to BU_).
	vgui.same_line()
	mut sender_opts := ['(none)']
	sender_opts << app.dbs[di].nodes
	if msg.sender != '' && msg.sender !in app.dbs[di].nodes {
		sender_opts << msg.sender
	}
	cur_sel := if msg.sender == '' { 0 } else { sender_opts.index(msg.sender) }
	vgui.set_next_item_width(130 * sc)
	nsel := vgui.combo('sender', sender_opts, cur_sel)
	if !ro && nsel != cur_sel && nsel >= 0 && nsel < sender_opts.len {
		new_snd := if nsel == 0 { '' } else { sender_opts[nsel] }
		app.mu.lock()
		app.dbs[di].messages[mi].sender = new_snd
		app.mu.unlock()
		app.mark_dirty(di)
	}

	// 2. Bit Layout Matrix Grid
	vgui.separator_text('Bit Layout Matrix')
	if msg.dlc < 0 || msg.dlc > 64 {
		vgui.text_colored(205, 60, 60, 'dlc ${msg.dlc} out of range — fix it above to see the layout')
	} else {
		nbits := msg.dlc * 8
		mut owner_cnts := [512]int{}
		mut owners := [512][4]int{}
		for six, sg in msg.signals {
			for g in dbc_signal_bits(sg) {
				if g >= 0 && g < nbits && g < 512 {
					if owner_cnts[g] < 4 {
						owners[g][owner_cnts[g]] = six
						owner_cnts[g]++
					}
				}
			}
		}
		mut conflict := [512]bool{}
		for g in 0 .. nbits {
			cnt := owner_cnts[g]
			for x in 0 .. cnt {
				for y in x + 1 .. cnt {
					a := msg.signals[owners[g][x]]
					bsig := msg.signals[owners[g][y]]
					coexist := !(a.is_multiplexed && bsig.is_multiplexed
						&& a.multiplexor_value != bsig.multiplexor_value)
					if coexist {
						conflict[g] = true
					}
				}
			}
		}
		cell := 21 * sc
		// scrollable: a large dlc (up to 64 bytes) shouldn't stretch the whole panel — show
		// ~10 byte rows and scroll for the rest.
		vis_rows := if msg.dlc < 10 { msg.dlc } else { 10 }
		vgui.child_begin('##bitmatrix', f32(vis_rows) * (cell + 4 * sc) + 6 * sc)
		for byte_i in 0 .. msg.dlc {
			vgui.text_dim('B${byte_i}')
			for bit_i := 7; bit_i >= 0; bit_i-- {
				vgui.same_line()
				g := byte_i * 8 + bit_i
				cnt := owner_cnts[g]
				mut r, mut gg, mut b := 58, 58, 62
				mut lbl := ' '
				if cnt == 1 {
					sidx := owners[g][0]
					r, gg, b = dbc_ed_color(sidx)
					if sidx == app.dbc_ed.sig {
						r, gg, b = r + 40, gg + 40, b + 40
					}
					sg := msg.signals[sidx]
					if sg.is_multiplexor {
						lbl = 'M'
					} else if sg.is_multiplexed {
						lbl = 'm'
					} else {
						lbl = '${sidx % 10}'
					}
				} else if cnt > 1 {
					if conflict[g] {
						r, gg, b = 205, 60, 60
						lbl = '!'
					} else {
						r, gg, b = dbc_ed_color(owners[g][0])
						r, gg, b = r / 2 + 20, gg / 2 + 20, b / 2 + 20
						lbl = 'm'
					}
				}
				if vgui.button_big('${lbl}##g${g}', r, gg, b, cell, cell) {
					if cnt > 0 {
						app.dbc_ed.sig = owners[g][0]
					}
				}
				if cnt > 0 {
					mut tt := 'bit ${g} (Byte ${byte_i}, bit ${bit_i})'
					for o_idx in 0 .. cnt {
						o := owners[g][o_idx]
						sg := msg.signals[o]
						mux_info := if sg.is_multiplexor {
							' [Mux Switch]'
						} else if sg.is_multiplexed {
							' [Mux ${sg.multiplexor_value}]'
						} else {
							''
						}
						tt += '\n${sg.name}${mux_info}'
					}
					vgui.set_item_tooltip(tt)
				}
			}
		}
		vgui.child_end()
		mut over := 0
		for g in 0 .. nbits {
			if conflict[g] {
				over++
			}
		}
		if over > 0 {
			vgui.text_colored(205, 60, 60, '${over} bit(s) claimed by more than one signal')
		}
		for sg in msg.signals {
			for g in dbc_signal_bits(sg) {
				if g >= nbits || g < 0 {
					vgui.text_colored(205, 60, 60, '${sg.name} exceeds the ${msg.dlc}-byte frame')
					break
				}
			}
		}
	}

	// 3. Signal Inspector Form (for selected signal)
	si := app.dbc_ed.sig
	if si < 0 || si >= msg.signals.len {
		vgui.separator_text('Signal Inspector')
		vgui.text_dim('select a signal in the left tree/table or layout grid to inspect properties')
		vgui.child_end()
		vgui.end()
		return
	}

	sg := msg.signals[si]
	cr, cg, cb := dbc_ed_color(si)
	vgui.separator_text('Signal Inspector: #${si + 1} ')
	vgui.same_line()
	vgui.text_colored(u8(cr), u8(cg), u8(cb), sg.name)

	app.dbc_ed_load_bufs()
	vgui.set_next_item_width(160 * sc)
	if !ro && vgui.input_text('name##dbcs', mut app.dbc_ed.sname_buf) {
		nv := vgui.buf_str(app.dbc_ed.sname_buf)
		mut name_taken := false
		for oi, osg in msg.signals {
			if oi != si && osg.name == nv {
				name_taken = true
			}
		}
		if dbc_ident_ok(nv) && !name_taken {
			old_sig := msg.signals[si].name
			app.mu.lock()
			app.dbs[di].messages[mi].signals[si].name = nv
			app.mu.unlock()
			app.mark_dirty(di)
			wid := msg.id
			wext := msg.ext
			mut shadowed := false
			for odi in 0 .. di {
				for om in app.dbs[odi].messages {
					if om.id == wid && om.ext == wext {
						shadowed = true
					}
				}
			}
			for wi, w in app.watch {
				if shadowed {
					break
				}
				if w.id == wid && w.ext == wext && w.sig == old_sig {
					app.watch[wi] = Watch{
						id:  w.id
						ext: w.ext
						sig: nv
					}
				}
			}
		}
	}
	if !dbc_ident_ok(vgui.buf_str(app.dbc_ed.sname_buf)) {
		vgui.same_line()
		vgui.text_colored(205, 60, 60, 'invalid name')
	}

	// A signal's bit span is defined by its two endpoints: start bit + stop bit (the width is
	// derived, stop - start + 1). No separate "len" field and no +/- steppers — you set where
	// the bits begin and end. (Little-endian contiguous span; big-endian keeps DBC semantics.)
	lnv := sg.length
	stop_bit := sg.start_bit + lnv - 1
	sb_key := 'start:${di}:${mi}:${si}'
	// While this field is being edited the FIELD owns the value, not the model — otherwise the
	// next frame resets it to the unchanged model and the edit snaps back mid-typing.
	mut sbv := if app.dbc_ed.bit_edit_key == sb_key { app.dbc_ed.bit_edit_val } else { sg.start_bit }

	vgui.same_line()
	vgui.set_next_item_width(65 * sc)
	if !ro && vgui.input_int('start bit', &sbv) {
		if app.dbc_ed.bit_edit_key != sb_key {
			// the edit begins here: snapshot the endpoint we will hold it against, so later
			// keystrokes are measured against where the span was BEFORE typing started (#68)
			app.dbc_ed.bit_edit_key = sb_key
			app.dbc_ed.bit_edit_anchor = stop_bit
			app.dbc_ed.bit_edit_db = di
			app.dbc_ed.bit_edit_msg = mi
			app.dbc_ed.bit_edit_sig = si
			app.dbc_ed.bit_edit_name = sg.name
			app.dbc_ed.bit_edit_msg_name = app.dbs[di].messages[mi].name
		}
		app.dbc_ed.bit_edit_val = sbv
	}
	// The edit finished. Applying it lives in resolve_pending_bit_edit() and ONLY there — the
	// same call Start, Save and rebuild make — so the deactivation path and the choke point
	// cannot drift into disagreeing about clamping or value-table validation.
	if !ro && app.dbc_ed.bit_edit_key == sb_key && vgui.is_item_deactivated_after_edit() {
		app.resolve_pending_bit_edit()
	}
	vgui.same_line()
	vgui.set_next_item_width(65 * sc)
	// Intel: the span is contiguous, so a stop-bit endpoint derives the width. Motorola
	// (big-endian) bits descend within a byte and jump +15 across bytes (a sawtooth), so
	// stop - start + 1 is NOT the width — editing an endpoint there would silently corrupt
	// it (codex #65). Edit the length directly for big-endian.
	be := sg.byte_order == .big_endian
	w_key := 'width:${di}:${mi}:${si}'
	mut widthv := if app.dbc_ed.bit_edit_key == w_key {
		app.dbc_ed.bit_edit_val
	} else if be {
		lnv
	} else {
		stop_bit
	}
	if !ro && vgui.input_int(if be { 'length' } else { 'stop bit' }, &widthv) {
		if app.dbc_ed.bit_edit_key != w_key {
			// same reasoning as the start field: hold the START endpoint as it was when typing
			// began, so intermediate keystrokes are not measured against a moving anchor (#68)
			app.dbc_ed.bit_edit_key = w_key
			app.dbc_ed.bit_edit_anchor = sg.start_bit
			app.dbc_ed.bit_edit_db = di
			app.dbc_ed.bit_edit_msg = mi
			app.dbc_ed.bit_edit_sig = si
			app.dbc_ed.bit_edit_name = sg.name
			app.dbc_ed.bit_edit_msg_name = app.dbs[di].messages[mi].name
		}
		app.dbc_ed.bit_edit_val = widthv
	}
	if !ro && app.dbc_ed.bit_edit_key == w_key && vgui.is_item_deactivated_after_edit() {
		app.resolve_pending_bit_edit()
	}
	vgui.same_line()
	vgui.text_dim('(${lnv} bit${if lnv == 1 { '' } else { 's' }})')
	vgui.same_line()
	// the contiguous start..stop range only describes an Intel span; a Motorola signal
	// walks the sawtooth, so show its start + width instead of a misleading range
	vgui.text_dim(if be {
		'(Motorola: start ${sbv}, ${lnv} bits)'
	} else {
		'(range: bit ${sbv} .. ${sbv + lnv - 1})'
	})

	cur_o := if sg.byte_order == .little_endian { 0 } else { 1 }
	vgui.set_next_item_width(120 * sc)
	no := vgui.combo('order', ['Intel (LE)', 'Motorola (BE)'], cur_o)
	if !ro && no != cur_o {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].byte_order = if no == 0 {
			candb.ByteOrder.little_endian
		} else {
			candb.ByteOrder.big_endian
		}
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	nsg := vgui.checkbox('signed', sg.is_signed)
	if !ro && nsg != sg.is_signed {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].is_signed = nsg
		app.mu.unlock()
		app.mark_dirty(di)
	}

	mut fv := sg.factor
	vgui.same_line()
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('factor', &fv) {
		if fv != 0 {
			app.mu.lock()
			app.dbs[di].messages[mi].signals[si].factor = fv
			app.mu.unlock()
			app.mark_dirty(di)
		}
	}
	vgui.same_line()
	mut ov := sg.offset
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('offset', &ov) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].offset = ov
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	mut mnv := sg.minimum
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('min', &mnv) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].minimum = mnv
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	mut mxv := sg.maximum
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('max', &mxv) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].maximum = mxv
		app.mu.unlock()
		app.mark_dirty(di)
	}

	vgui.set_next_item_width(80 * sc)
	if !ro && vgui.input_text('unit', mut app.dbc_ed.unit_buf) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].unit = vgui.buf_str(app.dbc_ed.unit_buf)
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	vgui.set_next_item_width(280 * sc)
	if !ro && vgui.input_text('desc', mut app.dbc_ed.desc_buf) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].desc = vgui.buf_str(app.dbc_ed.desc_buf)
		app.mu.unlock()
		app.mark_dirty(di)
	}

	// Multiplexing
	vgui.separator_text('multiplexing')
	mut is_mux := sg.is_multiplexor
	new_is_mux := vgui.checkbox('Multiplexor Switch (M)##muxm', is_mux)
	if !ro && new_is_mux != is_mux {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].is_multiplexor = new_is_mux
		if new_is_mux {
			app.dbs[di].messages[mi].signals[si].is_multiplexed = false
		}
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	mut is_sub := sg.is_multiplexed
	new_is_sub := vgui.checkbox('Multiplexed Signal (m<N>)##muxsub', is_sub)
	if !ro && new_is_sub != is_sub {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].is_multiplexed = new_is_sub
		if new_is_sub {
			app.dbs[di].messages[mi].signals[si].is_multiplexor = false
		}
		app.mu.unlock()
		app.mark_dirty(di)
	}
	if app.dbs[di].messages[mi].signals[si].is_multiplexed {
		vgui.same_line()
		mut mval := sg.multiplexor_value
		vgui.set_next_item_width(80 * sc)
		if !ro && vgui.input_int('Mux Value (N)##muxval', &mval) {
			app.mu.lock()
			app.dbs[di].messages[mi].signals[si].multiplexor_value = if mval < 0 { 0 } else { mval }
			app.mu.unlock()
			app.mark_dirty(di)
		}
	}

	// Value Table (VAL_)
	vgui.separator_text('value table (VAL_)')
	sg_vals := sg.values.clone()
	if sg_vals.len > 0 {
		vgui.child_begin('##valtablebox', 90 * sc)
		if vgui.table_begin('##valtable', 3) {
			vgui.table_setup_col('raw value', 90 * sc)
			vgui.table_setup_col('label / state', 180 * sc)
			vgui.table_setup_col('action', 50 * sc)
			vgui.table_headers()
			mut keys := sg_vals.keys()
			keys.sort()
			for k in keys {
				vgui.table_row()
				vgui.table_cell('${k} (0x${k:X})')
				vgui.table_cell(sg_vals[k])
				vgui.table_next_col()
				if !ro && vgui.small_button('-##delval_${k}') {
					app.mu.lock()
					app.dbs[di].messages[mi].signals[si].values.delete(k)
					app.mu.unlock()
					app.mark_dirty(di)
				}
			}
			vgui.table_end()
		}
		vgui.child_end()
	} else {
		vgui.text_dim('no value table mappings defined for this signal')
	}
	if !ro {
		vgui.set_next_item_width(90 * sc)
		vgui.input_text('raw key##vkey', mut app.dbc_ed.val_key_buf)
		vgui.same_line()
		vgui.set_next_item_width(180 * sc)
		vgui.input_text('state label##vlbl', mut app.dbc_ed.val_name_buf)
		vgui.same_line()
		if vgui.small_button('+ value') {
			kstr := vgui.buf_str(app.dbc_ed.val_key_buf).trim_space()
			lblstr := vgui.buf_str(app.dbc_ed.val_name_buf).trim_space()
			if kstr != '' && lblstr != '' {
				parsed_k := kstr.u64()
				app.mu.lock()
				app.dbs[di].messages[mi].signals[si].values[parsed_k] = lblstr
				app.mu.unlock()
				app.mark_dirty(di)
				app.dbc_ed.val_key_buf = mkbuf('', 24)
				app.dbc_ed.val_name_buf = mkbuf('', 96)
			} else {
				app.notify('enter both a raw value and state label')
			}
		}
	}

	vgui.child_end() // end right pane

	vgui.end()
}

// ---- System viewer (docs/dbc_editor.md roadmap: viewer, NOT an editor) -----
// Renders a blobly_emb system.toml — the things text is bad at seeing: the
// per-bus communication matrix (P producer / C consumer / W undeclared
// writer), node identities, and the id allocation with collisions. Read-only
// by design: system/ecu TOML is hand-written and comment-rich, and its
// validation brain (ecucheck/syscheck) lives in blobly_emb.

fn draw_system(mut app App) {
	vis, op := vgui.begin_closable('System', app.show_sys)
	app.show_sys = op
	if !vis {
		vgui.end()
		return
	}
	sc := app.ui_scale
	if app.sys_path_buf.len == 0 {
		// smart default: the project's own dir usually holds the system.toml (a .blobnet lives
		// next to it), so Load works out of the box instead of starting on an empty box.
		mut def := ''
		if app.proj_path != '' {
			cand := os.join_path(os.dir(app.proj_path), 'system.toml')
			if os.is_file(cand) {
				def = cand
			}
		}
		app.sys_path_buf = mkbuf(def, 512)
	}
	vgui.set_next_item_width(340 * sc)
	vgui.input_text('system.toml', mut app.sys_path_buf)
	vgui.same_line()
	if vgui.small_button('Browse…##sys') {
		app.open_browser('system')
	}
	vgui.same_line()
	if vgui.small_button('Load##sys') {
		app.load_system(vgui.buf_str(app.sys_path_buf))
	}
	if !app.sys_loaded {
		vgui.text_dim('pick a blobly_emb system.toml — Browse…, or type a path (e.g. examples/system_full/system.toml)')
		vgui.end()
		return
	}

	// nodes + identities
	// load-time problems (unreadable DBCs etc.) must stay visible
	for e in app.sys.errs {
		vgui.text_colored(205, 60, 60, e)
	}
	vgui.text_dim('showing: ${app.sys.path}')
	// Nodes as a compact master-detail: a small selectable list (left) + the selected
	// ECU's detail (right). Replaces the wide 6-column table that dominated the panel.
	// default/reset the selection: re-default whenever the selected node is absent — after
	// loading a different system the old name would linger and leave the detail pane blank.
	mut sel_valid := false
	for n in app.sys.nodes {
		if n.name == app.sel_ecu {
			sel_valid = true
			break
		}
	}
	if !sel_valid {
		app.sel_ecu = if app.sys.nodes.len > 0 { app.sys.nodes[0].name } else { '' }
	}
	vgui.separator_text('nodes')
	// BOTH panes get the SAME fixed height: a child_fill detail pane would eat all remaining
	// vertical space, and ImGui advances the parent past the taller same-line child — pushing
	// the 'buses & id allocation' tree below the visible region (codex #65).
	ecu_h := 160 * sc
	vgui.child_wh('##ecu_list', 130 * sc, ecu_h)
	for n in app.sys.nodes {
		lbl := if n.ecu_err != '' { '${n.name}  (!)' } else { n.name }
		if vgui.selectable('${lbl}##ecusel_${n.name}', n.name == app.sel_ecu) {
			app.sel_ecu = n.name
		}
	}
	vgui.child_end()
	vgui.same_line()
	vgui.child_wh('##ecu_detail', 0, ecu_h) // w=0 = remaining width, same height as the list
	if app.sel_ecu == '' {
		vgui.text_dim('select an ECU on the left')
	} else {
		mut si := -1
		for j, n in app.sys.nodes {
			if n.name == app.sel_ecu {
				si = j
				break
			}
		}
		if si >= 0 {
			en := app.sys.nodes[si]
			vgui.text(en.name)
			if en.ecu_err != '' {
				vgui.text_colored(205, 60, 60, 'UNREADABLE: ${en.ecu_err}')
			}
			vgui.text_dim('ecu   ${en.ecu}')
			vgui.text_dim('buses ${en.buses.join(', ')}    NM ${if en.nm != 0 {
				'0x' + en.nm.hex()
			} else {
				'-'
			}}    ${if en.trace != 0 { 'trace' } else { 'no-trace' }}')
			if en.diag_req != 0 {
				vgui.text_dim('diag  0x${en.diag_req.hex()} / 0x${en.diag_rsp.hex()}')
			}
			// the single-ECU bench action: make everything else on this ECU's buses come alive.
			// It runs rebuild_from_proj(), which clears app.chans/dbs/sims while rx, sim and
			// generator workers iterate them lock-free — safe only when stopped AND drained.
			// stop() clears app.running BEFORE those workers exit, so !running alone leaves a
			// window where the rebuild frees what a live worker is reading (codex #65 r4). Use
			// the same gate the DBC editor uses.
			app.mu.lock()
			rb_readers := app.dbc_readers
			app.mu.unlock()
			if app.running || rb_readers > 0 {
				vgui.text_dim('Simulate the rest — stop to configure (workers drain briefly after Stop)')
			} else if vgui.small_button('Simulate the rest##restbus') {
				n, c := app.restbus_from_system(en.name)
				if c > 0 {
					app.notify('restbus for ${en.name}: simulating ${n} node(s) on ${c} channel(s) — enable/disable them in the Simulation panel')
				} else {
					app.notify('restbus: no channel matches ${en.name}\'s buses (check the project\'s interfaces)')
				}
			}
			vgui.same_line()
			vgui.text_dim('← treat as ECU under test; simulate the other nodes on its buses')
			vgui.separator_text('produces (${en.writes.len})')
			for s in en.writes {
				vgui.text('  ${s}')
			}
			vgui.separator_text('consumes (${en.reads.len})')
			for s in en.reads {
				vgui.text('  ${s}')
			}
		}
	}
	vgui.child_end()

	// buses matrix + id allocation: useful but long, so fold it (closed by default) —
	// keeps the panel focused on the nodes/ECU detail above.
	if vgui.tree_node('buses & id allocation###sysbusid') {
	for b in app.sys.buses {
		vgui.separator_text('bus ${b.name} (${b.iface}${if b.fd { ', FD' } else { '' }}${if b.bitrate > 0 {
			', ${b.bitrate / 1000} kbit'
		} else {
			''
		}})')

		// the communication matrix: signals x nodes, node columns chunked
		// well under Dear ImGui's hard 64-column table limit
		chunk := 32
		mut n0 := 0
		// a nodeless (partially authored) system still shows its signals:
		// the first pass always renders (with zero node columns), and the
		// explicit break below ends the zero-node case
		for {
			n1 := if n0 + chunk < app.sys.nodes.len { n0 + chunk } else { app.sys.nodes.len }
			if vgui.table_begin('##sysmx_${b.name}_${n0}', 3 + (n1 - n0)) {
				vgui.table_setup_col('signal', 140 * sc)
				vgui.table_setup_col('frame', 130 * sc)
				vgui.table_setup_col('cycle', 50 * sc)
				for ni in n0 .. n1 {
					vgui.table_setup_col(app.sys.nodes[ni].name, 70 * sc)
				}
				vgui.table_headers()
				for sg in app.sys.signals {
					if sg.bus != b.name {
						continue
					}
					vgui.table_row()
					vgui.table_cell(sg.name)
					vgui.table_cell(sg.frame)
					vgui.table_cell(if sg.cycle_ms > 0 { '${sg.cycle_ms}ms' } else { '-' })
					for ni in n0 .. n1 {
						cell := app.sys.matrix_cell(sg, app.sys.nodes[ni])
						vgui.table_next_col()
						if cell == 'W' {
							vgui.text_colored(205, 60, 60, 'W?') // undeclared writer
						} else if cell == 'P' {
							vgui.text_colored(120, 190, 120, 'P')
						} else if cell == 'C' {
							vgui.text_colored(86, 156, 214, 'C')
						} else {
							vgui.text_dim('')
						}
					}
				}
				vgui.table_end()
			}
			if n1 >= app.sys.nodes.len {
				break
			}
			n0 = n1
		}

		// id allocation with collisions (kind-aware: an ext twin of a
		// colliding std id is not itself flagged)
		ncols := app.sys.collision_count(b.name)
		if ncols > 0 {
			vgui.text_colored(205, 60, 60, '${ncols} id collision(s) on ${b.name}')
		}
		if vgui.table_begin('##sysid_${b.name}', 3) {
			vgui.table_setup_col('id', 90 * sc)
			vgui.table_setup_col('kind', 80 * sc)
			vgui.table_setup_col('owner', 160 * sc)
			vgui.table_headers()
			for a in app.sys.id_allocation(b.name) {
				vgui.table_row()
				idtxt := if a.ext { '0x${a.id.hex()}x' } else { '0x${a.id.hex()}' }
				if app.sys.is_collision(b.name, a.id, a.ext) {
					vgui.table_next_col()
					vgui.text_colored(205, 60, 60, '${idtxt} !')
				} else {
					vgui.table_cell(idtxt)
				}
				vgui.table_cell(a.kind)
				vgui.table_cell(a.owner)
			}
			vgui.table_end()
		}
	}
	vgui.tree_pop()
	}
	vgui.end()
}

// shell_worker_eth sends one command line as a SOME/IP REQUEST and renders
// the correlated response — the client half of the emb P3 RPC design
// (modules/someip RpcClient: one in flight, deadline, drain). The local
// socket binds the manifest peer\'s PORT: the board\'s static source filter
// accepts only its configured peer endpoint, and the WSL->LAN NAT path
// preserves a bound source port (the emb#158 bench recipe). Single-flight
// via the same shell_busy latch as the CAN worker.
fn shell_worker_eth(app &App, line string, target string, sip telem.SomeipIdent, method u16) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.shell_busy {
		a.mu.unlock()
		return
	}
	a.shell_busy = true
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.shell_busy = false
		a.mu.unlock()
		vgui.wake()
	}
	a.shell_append('> ' + line)
	if target == '' {
		a.shell_append('(enter the board ip first)')
		return
	}
	peer_port := sip.peer.all_after_last(':').int()
	bind_port := if peer_port > 0 { peer_port } else { 30491 }
	mut sock := vnet.listen_udp(':${bind_port}') or {
		a.shell_append('(bind :${bind_port}: ${err} — the board only answers its configured peer endpoint)')
		return
	}
	defer {
		sock.close() or {}
	}
	sock.set_read_timeout(100 * time.millisecond)
	addrs := vnet.resolve_addrs('${target}:${sip.port}', .ip, .udp) or {
		a.shell_append('(resolve ${target}: ${err})')
		return
	}
	a.mu.lock()
	last_session := a.eth_shell_session
	a.mu.unlock()
	mut cli := someip.RpcClient{
		service:    sip.service
		method:     method
		iface:      sip.version
		client_id:  0x0E01
		timeout_us: 1_500_000
		session:    last_session
	}
	sw := time.new_stopwatch()
	req := cli.send(line.bytes(), 0) or {
		a.shell_append('(client busy)')
		return
	}
	a.mu.lock()
	a.eth_shell_session = cli.session // burn it NOW: even a timeout never reuses it
	a.mu.unlock()
	sock.write_to(addrs[0], req) or {
		a.shell_append('(send: ${err})')
		return
	}
	mut buf := []u8{len: 65536} // one FULL UDP datagram: a truncated read would
	// fail the header-length check and read as a timeout, not as truncation
	want_src := addrs[0].str()
	for cli.state == .waiting {
		n, raddr := sock.read(mut buf) or {
			cli.poll(u64(sw.elapsed().microseconds()))
			continue
		}
		// only the dialed board may answer — on a shared bench another node
		// could otherwise forge matching correlation fields
		if raddr.str() == want_src {
			cli.on_datagram(buf[..n])
		}
		cli.poll(u64(sw.elapsed().microseconds()))
	}
	if cli.state == .done {
		a.shell_append(cli.result.payload.bytestr())
		return
	}
	if cli.result.timed_out {
		a.shell_append('(no response — board off, wrong ip, or the peer port is not ours after NAT)')
	} else {
		match cli.result.rc {
			0x03 { a.shell_append('(error: unknown method on the target)') }
			0x20 { a.shell_append("(denied — this build's mutate gate is closed)") }
			else { a.shell_append('(error rc 0x${cli.result.rc.hex()})') }
		}
	}
}
