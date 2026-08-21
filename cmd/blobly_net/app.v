module main

import os
import sync
import project
import transport
import wiretap
import candb
import sysview
import telem
import sim
import canlog
import doip
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

// No recording entry was written for this emission (see note_emit's second return value).
const rec_none = u64(0xFFFF_FFFF_FFFF_FFFF)

const org_tx = wiretap.tx
const org_tx_sim = wiretap.tx_sim
const org_rep = wiretap.rep
const org_rx = wiretap.rx

struct App {
mut:
	mu    sync.Mutex
	chans []Chan
	trace []TraceRow
	// Emissions still waiting for their echo, and the bookkeeping that lets one confirm its own
	// row: `trace_seq` is the next row's identity, `trace_base` the identity of trace[0].
	taps wiretap.Ring
	// Per RECORDING, for this run: whether a worker is alive, and whether it already ran to
	// completion. One marker cannot carry both — deleting it on exit made a finished group look
	// like one that needs starting, so enabling any unrelated channel restarted it; keeping it
	// made a group that had stopped unrestartable. Guarded by app.mu like the rest of App.
	replay_state map[string]ReplayState
	replay_token u64 // monotonic; identifies which worker owns a replay_state entry
	// Which recording is driving which destination, so two never reach one wire.
	// Destination -> the recording whose worker currently OWNS that wire. Keyed by
	// transport.destination_key(), not by the interface string: two spellings of one device are
	// one destination, and a table keyed by the spelling would hand the same wire to two
	// workers. It holds the entry until the worker's ownership-checked cleanup runs, so a
	// destination stays reserved while a stopping worker is still draining its last batch.
	replay_owner map[string]ReplayOwner
	// In-process consumers (simulated ECUs, diagnostic responders) per interface: how many were
	// spawned, and how many have actually attached to the bus. Counted on the spawn line itself
	// rather than by a second walk over the configuration -- the branches that decide what gets
	// spawned are intricate, and a separate count of them would be a second opinion to keep in
	// step.
	consumers_want  map[string]int
	consumers_ready map[string]int
	// …and the ones that could NOT attach, counted apart. Folding a failure into `ready` let the
	// gate open on it: the recording then transmitted its opening stimuli with the simulated ECU
	// absent, which is an incomplete experiment that looks like a normal start.
	consumers_failed map[string]int
	trace_seq        u64
	trace_base       u64
	// trace_seq as of the last reset OR Start — the base a pushed row's displayed idx is frozen
	// against (see TraceRow.idx). trace_seq itself deliberately survives resets (an in-flight
	// echo must stay unresolvable, never confirm a new run's row); this base is what makes idx
	// read as "frame number of this measurement" anyway, and Start resets it too, so a live run
	// after a trimmed import starts at 0 instead of the file's frame count. Distinct from
	// trace_base, which additionally advances on every ring trim.
	trace_run_base u64
	ghost_seq      u64                    // identities for emissions made while paused (see ghost_base)
	tx_mutexes     map[string]&sync.Mutex // per-interface send order (see TapBus.tx_mu)
	// Stable identity for recording entries, exactly like trace_seq/trace_base for rows: the
	// buffer is trimmed by re-slicing, so a plain index does not survive.
	rec_seq u64
	rec_ids []u64 // one per app.rec entry, so an entry is found by IDENTITY not by offset
	// Guards tx_mutexes ALONE, deliberately not app.mu: open_tap is called with app.mu held
	// (set_sender_bus retargets a generator mid-run under the lock), and app.mu is not
	// reentrant — taking it again inside the tap constructor deadlocked the GUI thread.
	tx_map_mu sync.Mutex
	gcount    map[string]u64 // persistent per-group frame totals (survive the ring trim)
	// One control block per RUNNING replay group (key = the group's spawn token, the same
	// identity ReplayState uses). The worker registers it at spawn and removes it on exit;
	// the Replay panel reads status and writes commands through it, all under app.mu — the
	// worker's Player itself never leaves the worker's stack.
	replay_ctls map[u64]&ReplayCtl
	// The seek slider's in-drag values, latched per group: ImGui does not write the backing
	// variable on the release frame, so a per-frame local re-seeded from the live position
	// committed "seek to where you already are" on every release.
	replay_seek map[u64]f32
	// Scan results for the Configure replay row, keyed by channel index — index-bound display
	// state, dropped by drop_index_bound_ui() at every event that shifts indices. Under mu: the
	// scan worker fills an entry from its thread.
	replay_scans map[int]&ReplayScan
	// The stopped Replay panel's precomputed grouping (see replay_view_groups): rebuilt when
	// replay_view_gen moves past replay_view_built. gen starts at 0 and rebuild_from_proj
	// bumps it, so the load in main() already leaves built(0) != gen(>=1) — the first frame
	// builds.
	replay_view_gen   u64
	replay_view_built u64
	replay_view       []ReplayGroupView
	trecs             []TRec
	rx                u64 // total across channels
	rev               u64
	running           bool
	dbs               []candb.Database // all loaded DBCs (union; trace/symbol decode)
	dbs_paths         []string         // resolved file path per dbs entry (editor save target)
	dbc_readers       int              // live workers reading app.dbs lock-free (rx loops);
	// the editor stays read-only until 0 — app.running clears BEFORE workers exit
	dbs_by_iface map[string][]candb.Database // per-channel DBCs (generator message picker scope)
	manifest     telem.Manifest
	has_manifest bool
	// Monotonic ns anchor for every row/record timestamp. Was `t0 i64` in ms via time.ticks(),
	// which quantised t_ms to whole milliseconds — a 1 kHz bus showed every frame at the same
	// stamp as its neighbour, and an FPS column computed from those stamps divides by zero.
	// t_ms stays f64 MILLISECONDS everywhere (charts, echo windows, telemetry all consume it);
	// only the clock behind it gained the missing decimals.
	t0_ns     u64
	wake_ms   i64
	last_wake i64
	proj_path string
	proj_name string
	dark      bool = true // theme
	ui_scale  f32  = 1.0
	paused    bool
	recording bool
	rec       []canlog.LogEntry // captured while recording; written on stop
	// What WE put on the wire, split the way the trace splits it: the tester's own sends and
	// the simulation's are different facts, and one merged number re-collapses them in the one
	// place a user looks first. Counted at the tap (note_emit), so every emitter counts —
	// including the ones that never call tx_on. REP is not counted: nothing was transmitted.
	tx_count     u64
	tx_sim_count u64
	// Bumped whenever the counters are zeroed. An emission carries the epoch it was counted in,
	// so a send that fails AFTER a Clear cannot take its refund out of the new session's total
	// (the counters are aggregates — they cannot tell whose count they are giving back).
	tx_epoch  u64
	logs      []string           // Log panel (status/events, newest last)
	doip_ents []doip.VehicleInfo // DoIP Discovery results
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
	show_diag     bool
	show_gen      bool
	show_script   bool
	show_doip     bool
	show_network  bool
	show_stats    bool
	show_log      bool = true
	show_replay   bool
	help_cache    map[string]string = map[string]string{} // markdown file -> contents (read once)
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
	trace_filter_buf  []u8   // Trace substring filter
	trace_grouped2    bool   // second Trace (filter) panel: own view mode
	trace_filter2_buf []u8   // second Trace (filter) panel: own filter
	symbol_filter_buf []u8   // Symbol Browser search
	rec_path          string // FULL path Record writes on stop; chosen at start so the UI can show it
	// The recording the trace is SHOWING ('' = live). Importing one also PAUSES the capture:
	// the label alone let live frames keep pouring into the same ring, trimming the file's rows
	// away within seconds on a busy bus while the chip still named the file, and summing file
	// and live counts into one gcount total. Cleared by reset_trace_locked and by Start.
	viewing_rec   string
	doip_host_buf []u8 // DoIP manual discover host[:port]
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
	fb_open     bool   // browser window shown
	fb_save     bool   // true = save mode (filename input), false = open mode
	fb_dir      string // current directory
	fb_name_buf []u8   // filename (save mode)
	// ACCEPTED extensions, plural — the caption the browser shows and the match it applies both
	// derive from this one list, so a picker can no longer advertise '(*.log)' while listing
	// .mf4, which is what the single-string version with per-case aliases did. Empty = any.
	fb_ext    []string
	fb_target string // action on OK: 'open' | 'saveas' | 'dbc:<ci>' | 'manifest:<ci>' |
	// 'system' | 'flash' | 'recording' — keep this list in step with the four dispatch
	// sites in panel_config.v (open_browser, browser_confirm, the title, match_ext)
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
	shell_buf         []u8   // the input line (persistent; edited in place by console_input)
	eth_target_buf    []u8   // the eth shell's board ip (session-only; manifest carries the port)
	eth_shell_session u16    // persists across commands: a fresh client restarting at session 1
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
	iface string // the bus this generator fires on (a channel iface); rebound if the iface changes
	chan  string // the CHANNEL that owns it — two channels can share one iface, and only the
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
	pch   project.Channel
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

// load_project (re)loads a project into the app: stops any measurement, clears the
// project-derived state, and rebuilds channels / DBCs / sims / senders. Keeps the input
// buffers + panel layout. Used at startup and by File > Open Example / Reload.
// load_project loads a project file: stop, reset the session buffers, parse into
// app.proj, then derive the runtime view (rebuild_from_proj). On a parse error the current
// project is left untouched.
fn (mut app App) load_project(path string) {
	app.stop()
	app.drop_index_bound_ui() // pending pickers and Scan results index the OLD channel set
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
	// A capture belongs to the project it was recorded IN. Neither stop() nor the reset below
	// touches `recording`, so a Record left running across File > Open/New kept appending the
	// NEXT project's traffic to the old capture and saved the mixture beside the old project —
	// where the new project's picker never looks (codex #128 r4). Stop Rec here writes the
	// frames to the path the capture reserved; a failed write keeps them, same as any Stop.
	if app.recording {
		app.toggle_record()
	}
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
	// A new project starts at zero on every counter. rx was reset here; the transmit counts were
	// not, so an empty session opened after a simulated one showed the previous project's total.
	app.tx_count = 0
	app.tx_sim_count = 0
	app.tx_epoch++
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
	app.replay_view_gen++ // the grouping the stopped Replay panel caches is derived from what
	// this function rebuilds
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
			name:           ch.name
			network:        ch.network
			adapter:        ch.adapter
			address:        ch.address
			iface:          ch.iface // the stable LOGICAL key (tx_buses/senders); @bitrate is added at open
			mode:           ch.mode.str()
			typ:            ch.typ
			bitrate:        ch.bitrate
			data_bitrate:   ch.data_bitrate
			listen_only:    ch.listen_only
			databases:      ch.databases.clone()
			manifest:       ch.manifest
			doip:           ch.is_doip()
			enabled:        ch.enabled
			replay_src:     if r := ch.replay { app.resolve_asset(r.source) } else { '' }
			replay_bus:     if r := ch.replay { r.bus } else { '' }
			replay_exclude: if r := ch.replay { r.exclude.clone() } else { []string{} }
			replay_speed:   if r := ch.replay { r.speed } else { 1.0 }
			replay_loop:    if r := ch.replay { r.repeat } else { false }
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
			// A persisted `bus:` override points at another INTERFACE, and the generator then
			// transmits there — so its rows belong to that bus's channel, not to the one the
			// sender is nested under. Resolved only when that interface has exactly one channel;
			// with several sharing it there is nothing in the file to say which (see #97).
			mut owner := ch.name
			if s.bus != '' && s.bus != ch.iface {
				mut hits := []string{}
				for c2 in app.proj.channels {
					if c2.iface == s.bus {
						hits << c2.name
					}
				}
				owner = if hits.len == 1 {
					hits[0]
				} else {
					// 0 or several channels on that wire: `ch.name` belongs to a DIFFERENT bus,
					// so it would be a worse answer than none. Empty means "derive at emit from
					// the interface", which is what the tap did before this ownership existed.
					''
				}
			}
			app.senders << SenderRT{
				iface:  ch.iface
				chan:   owner
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
				iface:    ch.iface
				pch:      ch
				db:       merge_dbs(ch.databases.map(app.resolve_asset(it)))
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
