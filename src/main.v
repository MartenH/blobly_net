// Blobly Net — main application window.
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
import sync
import sokol.sapp
import transport
import candb
import canlog
import mf4
import project
import sim
import player
import isotp
import doip
import uds
import script

const max_trace = 1000 // ring-buffer cap on retained frames (all are scrollable)

// Embedded Help docs — rendered in-app via gui.markdown, so the exe is self-contained
// (no loose files, no browser). Paths are relative to this source file (src/).
const help_quickstart = $embed_file('../docs/help/quickstart.md').to_string()
const help_examples = $embed_file('../docs/help/examples.md').to_string()
const default_fps = 5  // trace repaint rate; user-tunable (3/5/10) from the toolbar
const fps_options = ['3 fps', '5 fps', '10 fps']

// Scroll ids for the side panels — non-zero + unique per window (gui enables a
// column's scrollbar when id_scroll > 0). Kept clear of the checkbox id_focus
// ranges (200+ buses, 300+ sim nodes, 400+ Graphics legend, 500+ watch chips).
const id_scroll_buses = u32(7100)
const id_scroll_sim = u32(7200)
const id_scroll_plot = u32(7300)
const id_scroll_diag = u32(7400)
const id_scroll_gen = u32(7800) // Generators (interactive senders) panel
const id_scroll_plot_outer = u32(7500) // Graphics root: clamps the panel measurement
const id_scroll_symbols = u32(7600)    // Symbol Browser tree
const id_scroll_busconfig = u32(7700)  // Bus Config candidate list
const id_scroll_log = u32(7900)        // Log panel (scrolling event log)
const id_scroll_script = u32(8000)     // Script panel (Lua test output)
const id_scroll_doip = u32(8100)       // DoIP discovery panel (entity list)

// UDS request/response CAN ids (classic OBD physical addressing): the tester
// transmits on 0x7E0, the ECU answers on 0x7E8. The simulated ECU's UDS
// server listens accordingly.
const diag_tx_id = u32(0x7E0)
const diag_rx_id = u32(0x7E8)

// ---- Look & feel: the few knobs that restyle the whole app ----
// Font family for ALL UI text. '' keeps gui's bundled default; set e.g.
// 'Cascadia Mono' and it flows through gui's font_variants() to every derived
// style (normal/bold/italic) — one knob for the whole app's typeface.
const ui_font_family = ''
// The type scale (px). These ARE the font sizes — every widget references one of
// them via the theme (trace = small, panels = medium, app title = x_large), so
// bumping these restyles the whole UI. Tuned tight for a dense layout.
const ui_size_tiny = f32(8)
const ui_size_x_small = f32(9)
const ui_size_small = f32(10)
const ui_size_medium = f32(11)
const ui_size_large = f32(13)
const ui_size_x_large = f32(16)
// Trace-grid density (the Directory-Opus-dense rows). Pixel heights gui needs
// explicitly; keep ~4px of leading over ui_size_small so descenders don't clip.
const trace_row_height = f32(14)
const trace_header_height = f32(16)

// UI scale factor — the DPI workaround. sokol can't query the system DPI under
// WSLg/X11 (LINUX_X11_QUERY_SYSTEM_DPI_FAILED → it assumes 96 dpi → gg.scale stays
// 1.0), so on a HiDPI monitor the whole UI renders 1:1 device-pixel and looks tiny.
// There's no real DPI to read back, so we expose a manual multiplier instead: it
// scales every font size, padding/spacing and the explicit grid row heights at
// theme-build time, so the UI grows uniformly (text via vglyph just renders bigger
// glyphs). A process global because the dense-grid helpers (make_theme,
// trace_text_style via the theme, the activity-bar icons) are free functions with
// no App handle; globals are already enabled (-enable-globals, for the in-proc bus).
// Set BLOBLY_UI_SCALE=1.5 at startup, or pick it live from the toolbar control.
__global (
	g_ui_scale = f32(1.0)
)

const ui_scale_min = f32(0.75)
const ui_scale_max = f32(3.0)
// Toolbar choices (label → factor); 100% is the no-scale baseline.
const ui_scale_options = ['100%', '125%', '150%', '175%', '200%', '250%', '300%']

fn clamp_scale(s f32) f32 {
	return if s < ui_scale_min {
		ui_scale_min
	} else if s > ui_scale_max {
		ui_scale_max
	} else {
		s
	}
}

// sc scales a hand-set pixel dimension (widget width/height/min/max) by the UI
// scale. Theme-derived sizes already scale in make_theme; these literals don't, so
// wrap them so fixed boxes (inputs, the activity bar) grow with the font.
@[inline]
fn sc(v f32) f32 {
	return v * g_ui_scale
}

// scpad scales an explicit Padding the same way (theme paddings already scale).
fn scpad(top f32, right f32, bottom f32, left f32) gui.Padding {
	return gui.Padding{top * g_ui_scale, right * g_ui_scale, bottom * g_ui_scale, left * g_ui_scale}
}

// ui_scale_label renders the current scale as the nearest toolbar percentage label.
fn ui_scale_label() string {
	return '${int(g_ui_scale * 100 + 0.5)}%'
}
// Crop the chronological-trace Data cell after this many bytes (CAN-FD payloads
// reach 64 bytes and would otherwise overflow the column); the rest is summarised.
const trace_data_max_bytes = 16
const plot_max_points = 1200 // drawn points per signal cap (tessellation cost ∝ this)
const plot_history = 6000     // per-message frames retained for the plot (deep history)
const plot_win_options = ['5 s', '10 s', '30 s', '60 s'] // Graphics time window

// ---- Color palettes: one struct, fed into make_theme() ----
// Every gui color knob in one place (parallel to the ui_size_* scale). Swap the
// whole look by swapping a Palette; the dark/light toggle picks between two.
struct Palette {
	name       string
	dark       bool // drives titlebar_dark + the gui base preset
	background gui.Color // window chrome (menus/toolbars/panel headers)
	panel      gui.Color // panel backgrounds
	interior   gui.Color // list/input interior (the data area)
	hover      gui.Color
	focus      gui.Color
	active     gui.Color
	border     gui.Color // panel / menu / input frames (Opus "Frame")
	gridline   gui.Color // data-grid lines (Opus listview gridlines; darker than border)
	select     gui.Color // selection bar (text colour is preserved, not whitened)
	accent     gui.Color // focus / selection-frame accent
	text       gui.Color
}

// Directory-Opus light theme, matched to the user's actual DOpus settings:
// pure-white backgrounds (255/255/255) and 109/109/109 lines. The blue accents
// come from the theme file (Themes/foo.dlt → theme.xml): selection #0078d4
// (rendered pale via blending=yes over white) and hover #8bc9f8. No green — the
// sage seen in DOpus is the Windows window tint (syscols), not an Opus value.
const palette_opus = Palette{
	name:       'opus-light'
	dark:       false
	background: gui.rgb(242, 242, 242) // chrome / menus / toolbars (DOpus Menus bg)
	panel:      gui.rgb(255, 255, 255) // panels hold list/tree/form content → white
	interior:   gui.rgb(255, 255, 255) // inputs + data-grid background (DOpus listview)
	hover:      gui.rgb(214, 236, 252) // #8bc9f8 blended light
	focus:      gui.rgb(199, 222, 244) // #0078d4 ~22% over white
	active:     gui.rgb(180, 211, 240) // #0078d4 stronger
	border:     gui.rgb(204, 204, 204) // panel/menu/input frames (DOpus Frame)
	gridline:   gui.rgb(224, 224, 224) // data-grid lines — subtle, not a heavy black grid
	select:     gui.rgb(199, 222, 244) // #0078d4 selection, blended over white
	accent:     gui.rgb(0, 120, 212)   // #0078d4 — focus/selection frame (crisp blue)
	text:       gui.rgb(20, 20, 20)
}

// The previous neutral-grey dark look, preserved (gui's dark_bordered palette).
const palette_dark = Palette{
	name:       'dark'
	dark:       true
	background: gui.rgb(48, 48, 48)
	panel:      gui.rgb(64, 64, 64)
	interior:   gui.rgb(74, 74, 74)
	hover:      gui.rgb(84, 84, 84)
	focus:      gui.rgb(94, 94, 94)
	active:     gui.rgb(104, 104, 104)
	border:     gui.rgb(100, 100, 100)
	gridline:   gui.rgb(82, 82, 82) // subtle lines on the dark interior
	select:     gui.rgb(65, 105, 225)
	accent:     gui.rgb(90, 140, 240)
	text:       gui.rgb(225, 225, 225)
}

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
	ch   string // channel/interface the frame was seen on (CAN1, can, …)
	dir  string
	id   u32
	ext  bool
	dlc  int
	data []u8
	name string
	changed u8 // per-byte changed-vs-previous-instance bitmask; 0 = exact repeat
}

struct MsgAgg {
mut:
	id      u32
	ext     bool
	ch      string
	dir     string
	last    []u8
	count   int
	last_ms f64
	name    string
	repeat  bool // latest frame was byte-identical to the prior one for this ID
}

// BusCandidate is one discovered interface shown in the Bus Config panel: a real
// can/vcan netdev or a virtual software bus, with its live link state so you can see
// what's actually connected before adding it as a project channel.
struct BusCandidate {
	name    string
	iface   string
	kind    string // can | vcan | udp | inproc
	bitrate int
	virtual bool
	in_proj bool   // already a channel in the project
	state   string // 'connected' | 'no carrier' | 'down' | '' (virtual)
	hw      string // hardware id for a real USB CAN netdev, e.g. "Kvaser Leaf Light v2 [3-3:1.0]"
}

// PlotSample is one retained frame of a message for the Graphics strip chart —
// kept in a per-message history (App.plot_hist) that is much deeper than the
// 1000-frame display trace, so the plot can fill a long time window.
struct PlotSample {
	t_s  f32
	data []u8
}

// PlotPin is a signal pinned to the Graphics plot from a specific frame, so the
// plot can show signals from MULTIPLE messages at once (not just the selected
// one). Identified by (id, signal name); ext distinguishes 29-bit ids.
struct PlotPin {
	id     u32
	ext    bool
	signal string
}

// ChannelRT is the live runtime state of one configured channel (bus).
struct ChannelRT {
mut:
	bus      ?transport.Bus    // backend (SocketCAN or udp software bus); none until opened
	doip_srv ?&doip.DoipServer // DoIP entity (type: doip channels); none until listening
	running  bool
	err      bool // open failed / bus error
	rx_count int
	tx_count int
	note     string
}

// StatusLevel tags a Log-panel entry for colouring.
enum StatusLevel {
	info
	ok
	warn
	error
}

// StatusMsg is one entry in the scrolling Log panel.
struct StatusMsg {
	tstamp string // HH:MM:SS
	level  StatusLevel
	text   string
}

@[heap]
struct App {
mut:
	dock_root      &gui.DockNode = unsafe { nil }
	proj           project.Project // bus setup (loaded from a .yml; built-in default fallback)
	proj_source    string
	rt             []ChannelRT // runtime per proj.channels (parallel index)
	running        bool        // measurement started?
	db             candb.Database // merged catalog across all channels' DBCs (decode/lookup)
	dbs            []candb.Database // per-channel catalog (parallel to proj.channels); drives node list + sim
	db_source      string
	status         string
	logs           []StatusMsg // scrolling event log (Log panel); newest appended
	t0             i64
	trace     []TraceRow
	// Grouped trace: keyed by (id, bus, dir) — see trace_group_key — so the same ID
	// on different buses or RX vs TX are SEPARATE rows. order keeps first-seen order.
	grouped   map[string]MsgAgg
	order     []string
	seq       int
	rx_count  int
	tx_count  int
	paused    bool
	mode      string = 'grouped' // main Trace view: 'grouped' | 'all'
	mode2     string = 'grouped' // Trace (filter) view, independent toggle
	help_page string = 'quickstart' // Help panel page: 'quickstart' | 'examples' | 'about'
	dark      bool // current theme: false = Opus sage-light (default), true = dark
	recents   []string // recently opened project file paths (most-recent first; persisted)
	expanded  map[string]bool // grouped-trace group-keys expanded in the main Trace (which 0)
	expanded2 map[string]bool // …and independently in Trace (filter) (which 1)
	plot_hist map[u64][]PlotSample // deep per-message history for the Graphics plot, keyed by hist_key(id, ext)
	// Persistent, REUSED decode buffers for the Graphics panel — refilled in place
	// (not reallocated) each render, and only when the data actually changed
	// (plot_sig). Allocating these fresh every frame was the Graphics stutter.
	plot_sig    string  // signature of what's currently in the buffers below
	plot_series [][]f32 // per-plotted-signal decoded values over the window
	plot_times  [][]f32 // per-plotted-signal sample timeline (cross-frame = different cadences)
	plot_cur    []f64   // latest value per plotted signal (legend)
	// Expand-only running y-range per '<id>:<signal>' so a scrolling waveform keeps a
	// STABLE vertical scale (it only widens for new extremes, never shrinks as samples
	// leave the window). Without this, the per-window auto-scale made signals "breathe"
	// / stretch independently. Reset when the plot history is cleared.
	plot_range map[string][2]f32
	// Reused tessellation scratch (pixel positions + polyline points), refilled per
	// series during draw — accessed via the app pointer captured into the draw closure.
	plot_xs  []f32
	plot_ys  []f32
	plot_pts []f32
	sel_id      i64 = -1 // message ID the Signals panel inspects (trace selection)
	selection gui.GridSelection
	send_id   string = '101'
	send_data string = 'AABBCC'
	// Recording: when on, record() also appends every frame to record_entries; the
	// toolbar ⏺ button toggles it and writes a candump .log on stop.
	recording      bool
	record_entries []canlog.LogEntry
	log_path  string // candump .log to open from the toolbar
	fps       int = default_fps // trace repaint rate (toolbar dropdown)
	// RX/TX inbox: the bus threads append frames here (bounded — drop oldest on
	// overflow) and queue AT MOST ONE drain command (drain_queued) to record them on
	// the UI thread. This caps memory regardless of whether the UI is draining — the
	// old per-flush queue_command(frames) piled up unboundedly when not rendering.
	inbox        []InboxItem
	inbox_mu     sync.Mutex
	drain_queued bool
	senders   []SenderRT // interactive generators flattened across channels (Generators panel + hotkeys)
	sim_nodes []SimNode // simulated ECUs available per channel (Simulation panel)
	sim_expanded map[int]bool // Simulation tree: channel idx -> expanded (default collapsed)
	// Generator editor: which node's signals are shown ('ch:node'), and which single
	// signal's inline editor is open ('ch:node:signal'; '' = none, one at a time).
	sim_sig_expanded map[string]bool
	sim_sig_edit     string
	// Generators panel: which sender's inline editor is open (key '<ch_idx>:<sidx>').
	gen_edit map[string]bool
	trace_filter string // case-insensitive substring filter on ID/name/ch/data
	// The second, independent trace panel ("Trace (filter)"): same data, its
	// own filter + selection — keep the full trace and a curated slice open
	// side by side (conventional). It starts EMPTY: rows appear only for IDs
	// added to the watch set (the ＋ button adds the Trace-selected message;
	// each watched ID is a chip with ✕ to remove) or matching a typed filter.
	trace_filter2 string
	selection2    gui.GridSelection
	watch         map[u32]bool
	// Grouped-trace expand is now double-click (single click just selects, so it
	// can drive multi-select + "add to filter"); track the last click to detect it.
	last_click_id string
	last_click_ms i64
	// Symbol Browser: search string + which message rows are expanded.
	symbol_filter   string
	symbol_expanded map[u32]bool
	// Bus Config panel: discovered candidate interfaces, which are ticked to add,
	// and the (editable) name to give each — so you can label can0 'vehicle-can'
	// etc. and that name is what lands in the project / Buses / trace Ch column.
	bus_candidates []BusCandidate
	bus_ticked     map[string]bool
	bus_names      map[string]string // iface -> chosen channel name
	send_ch        string            // Send target bus (channel name); '' = first running
	// Graphics panel: signals UNchecked in the legend (key '<id>:<signal>') —
	// default empty = plot everything, so new selections start fully visible.
	plot_off map[string]bool
	// Graphics: the explicit watch list — the plot shows EXACTLY these signals
	// (added via ＋ Plot in the Signals panel), accumulated across any number of
	// frames, independent of the Trace selection. plot_shared scales all plotted
	// signals to one labelled Y-axis; false = per-signal fit.
	plot_watch  []PlotPin
	plot_shared bool = true
	// Diagnostics panel: response log (newest first) + the typed DID for the
	// free-form RDBI read.
	diag_log []string
	diag_did string = 'F190'
	// Diagnostics target override: when set (via the DoIP panel), requests go here
	// instead of the first running channel. Cleared on Stop / project load.
	diag_sel      ?DiagTarget
	diag_sel_name string
	// DoIP discovery panel: the last scan's discovered entities + the manual
	// host[:port] to probe in addition to the running DoIP channels. doip_scan_gen
	// is bumped on each scan / Stop / project load so a late worker callback from a
	// superseded scan is ignored instead of repopulating cleared/stale results.
	doip_entities  []DiscoveredEntity
	doip_scan_host string
	doip_scan_gen  int
	// Script panel: the Lua script to run, its output log (chronological), and a
	// busy flag while a run is in flight on a worker thread.
	script_path    string = 'tests/diag_basic.lua'
	script_log     []string
	script_running bool
	// Strip-chart time window (seconds): the plot shows [latest - win, latest]
	// and slides as frames arrive, instead of compressing all history.
	plot_win int = 10
	// Graphics hover cursor: fraction [0,1] across the canvas width of the last
	// mouse-over position; -1 = not hovering. Drives the crosshair + value readout.
	plot_hover_frac f32 = -1
	// Graphics line style: true = step / sample-and-hold (conventional for discrete
	// signals), false = linear interpolation between samples.
	plot_step bool = true
}

// trace_match reports whether any of the given fields contains the (lowercased)
// filter — empty filter matches everything. Used to filter trace rows.
fn trace_match(filter string, fields ...string) bool {
	if filter.len == 0 {
		return true
	}
	f := filter.to_lower()
	for fld in fields {
		if fld.to_lower().contains(f) {
			return true
		}
	}
	return false
}

// trace_pass is the row predicate per trace panel. The main Trace (which 0)
// shows everything its filter matches (empty filter = everything). The
// "Trace (filter)" panel (which 1) is opt-in: a row shows only if its ID is in
// the watch set or a NON-empty filter matches — so it starts empty.
fn trace_pass(app &App, which int, filter string, id u32, fields ...string) bool {
	if which == 0 {
		return trace_match(filter, ...fields)
	}
	if app.watch[id] {
		return true
	}
	return filter.len > 0 && trace_match(filter, ...fields)
}

// SenderRT is one interactive generator (project.Sender) bound to the channel it
// belongs to. Flattened across all channels in App.senders so the Generators
// panel and the global hotkey handler can fire any of them by index.
struct SenderRT {
mut:
	ch_idx int             // index into proj.channels
	sidx   int             // index into proj.channels[ch_idx].senders (maps edits back)
	cfg    project.Sender
}

// SimNode is one simulated ECU offered in the Simulation panel: a configured ECU
// on a channel, with a checkbox to connect it to the bus (= have the tester
// simulate it). `cfg` carries its per-signal generators + response rules.
struct SimNode {
mut:
	ch_idx  int
	node    string
	enabled bool
	cfg     project.NodeCfg
}

// build_sim_nodes lists, per channel, the ECU nodes the DBC declares (BU_) — the
// node list is the database's, not the project's. The project then (a) enables a
// node by naming it in `nodes:`/`simulate:` and (b) optionally configures its
// behaviour there; un-named DBC nodes still appear (so you can connect them from
// the panel) but start disconnected and use default behaviour.
fn (mut app App) build_sim_nodes() {
	app.sim_nodes = []SimNode{}
	for i, ch in app.proj.channels {
		if ch.databases.len == 0 {
			continue
		}
		cfgs := ch.all_nodes()
		ch_db := if i < app.dbs.len { app.dbs[i] } else { candb.Database{} }
		for node in ch_db.nodes {
			mut cfg := project.NodeCfg{
				name: node
			}
			mut enabled := false
			for c in cfgs {
				if c.name == node {
					cfg = c
					enabled = true
					break
				}
			}
			app.sim_nodes << SimNode{
				ch_idx:  i
				node:    node
				enabled: enabled
				cfg:     cfg
			}
		}
	}
	app.build_senders()
}

// build_senders flattens every channel's interactive generators (`senders:`) into
// App.senders, tagging each with its channel index. Rebuilt with build_sim_nodes
// whenever the project changes, so the Generators panel + hotkeys stay in sync.
fn (mut app App) build_senders() {
	app.senders = []SenderRT{}
	for i, ch in app.proj.channels {
		for si, s in ch.senders {
			app.senders << SenderRT{
				ch_idx: i
				sidx:   si
				cfg:    s
			}
		}
	}
}

// build_sender_frame resolves a Sender into a CAN frame. With a `message` that
// the DBC knows, it takes the id/ext/dlc from the message and encodes each signal
// value onto a zero (or the explicit `data`) payload. Otherwise it uses the
// explicit id + raw data verbatim.
fn (app &App) build_sender_frame(s project.Sender) transport.CanFrame {
	if s.message != '' {
		for m in app.db.messages {
			if m.name != s.message {
				continue
			}
			mut data := if s.data.len > 0 {
				s.data.clone()
			} else {
				dlc := if m.dlc > 0 { m.dlc } else { 8 }
				[]u8{len: dlc}
			}
			for sg in s.signals {
				for sig in m.signals {
					if sig.name == sg.name {
						sig.encode(mut data, sg.value)
						break
					}
				}
			}
			return transport.CanFrame{
				id:       m.id
				extended: m.ext
				data:     data
			}
		}
	}
	// No DBC message — explicit id/data (default to an 8-byte zero payload).
	data := if s.data.len > 0 { s.data.clone() } else { []u8{len: 8} }
	return transport.CanFrame{
		id:       s.id
		extended: s.ext || s.id > 0x7ff
		data:     data
	}
}

// fire_sender transmits sender `si`'s frame from the UI thread. It prefers the
// sender's own channel when running, else the first running channel (so a sender
// on an off bus still fires somewhere); records the frame as a TX trace row.
fn fire_sender(si int, mut w gui.Window) {
	mut app := w.state[App]()
	if si < 0 || si >= app.senders.len {
		return
	}
	sr := app.senders[si]
	mut idx := -1
	if sr.ch_idx < app.rt.len && app.rt[sr.ch_idx].running && app.rt[sr.ch_idx].bus != none {
		idx = sr.ch_idx
	} else {
		for i in 0 .. app.rt.len {
			if app.rt[i].running && app.rt[i].bus != none {
				idx = i
				break
			}
		}
	}
	if idx < 0 {
		app.notify(.warn, 'not running — press ▶ Start to send "${sr.cfg.name}"')
		return
	}
	frame := app.build_sender_frame(sr.cfg)
	mut bus := app.rt[idx].bus or { return }
	bus.send(frame) or {
		app.notify(.error, 'send failed: ${err}')
		return
	}
	app.rt[idx].tx_count++
	chname := if idx < app.proj.channels.len { app.proj.channels[idx].name } else { 'CAN${idx + 1}' }
	app.push('TX', frame, chname)
	app.notify(.info, 'sent "${sr.cfg.name}"')
}

// handle_hotkey fires the first sender whose `key` matches the typed character,
// unless a text input is focused (so typing in a field never triggers sends).
// Returns true if a sender fired (the event was consumed).
fn handle_hotkey(char_code u32, mut w gui.Window) bool {
	if w.id_focus() != 0 {
		return false // a focusable widget (input/select) has focus — don't hijack typing
	}
	app := w.state[App]()
	for si, sr in app.senders {
		if sr.cfg.key.len == 0 {
			continue
		}
		if u32(sr.cfg.key[0]) == char_code {
			fire_sender(si, mut w)
			w.update_window()
			return true
		}
	}
	return false
}

// --- Generators panel editing -------------------------------------------------
// Setters mutate the project model (proj.channels[ci].senders[si]) in place — the
// single source of truth that Save writes — then rebuild the flattened App.senders
// so the buttons/hotkeys/cyclic loop pick up the change immediately.

// sender_ok bounds-checks a (channel, sender) index pair against the project.
fn (app &App) sender_ok(ci int, si int) bool {
	return ci >= 0 && ci < app.proj.channels.len && si >= 0
		&& si < app.proj.channels[ci].senders.len
}

fn set_sender_name(ci int, si int, name string, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	app.proj.channels[ci].senders[si].name = name
	app.build_senders()
}

fn set_sender_key(ci int, si int, key string, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	// A single character only; ignore the rest so one keypress maps to one sender.
	app.proj.channels[ci].senders[si].key = if key.len > 0 { key[..1] } else { '' }
	app.build_senders()
}

fn set_sender_trigger(ci int, si int, trig string, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	app.proj.channels[ci].senders[si].trigger = trig
	app.build_senders()
}

fn set_sender_cycle(ci int, si int, ms int, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	app.proj.channels[ci].senders[si].cycle_ms = ms
	app.build_senders()
}

// set_sender_message points the sender at a DBC message (clearing the raw id/data
// path); msg == '' / the raw sentinel switches it back to explicit id/data.
fn set_sender_message(ci int, si int, msg string, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	if msg == '' || msg == raw_msg_opt {
		app.proj.channels[ci].senders[si].message = ''
	} else {
		app.proj.channels[ci].senders[si].message = msg
	}
	app.build_senders()
}

// set_sender_signal sets (or adds) a signal value on a message-based sender.
fn set_sender_signal(ci int, si int, signame string, value f64, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	mut found := false
	for k in 0 .. app.proj.channels[ci].senders[si].signals.len {
		if app.proj.channels[ci].senders[si].signals[k].name == signame {
			app.proj.channels[ci].senders[si].signals[k].value = value
			found = true
			break
		}
	}
	if !found {
		app.proj.channels[ci].senders[si].signals << project.SenderSig{
			name:  signame
			value: value
		}
	}
	app.build_senders()
}

fn set_sender_id(ci int, si int, id u32, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	app.proj.channels[ci].senders[si].id = id
	app.proj.channels[ci].senders[si].ext = id > 0x7ff
	app.build_senders()
}

fn set_sender_data(ci int, si int, hexstr string, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	app.proj.channels[ci].senders[si].data = hex_to_bytes(hexstr)
	app.build_senders()
}

// add_sender appends a blank manual sender to a channel and opens its editor.
fn add_sender(ci int, mut w gui.Window) {
	mut app := w.state[App]()
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.proj.channels[ci].senders << project.Sender{
		name:    'New sender'
		trigger: 'manual'
	}
	new_si := app.proj.channels[ci].senders.len - 1
	app.build_senders()
	app.gen_edit['${ci}:${new_si}'] = true // open it for editing right away
	w.update_window()
}

fn remove_sender(ci int, si int, mut w gui.Window) {
	mut app := w.state[App]()
	if !app.sender_ok(ci, si) {
		return
	}
	app.proj.channels[ci].senders.delete(si)
	app.gen_edit.delete('${ci}:${si}')
	app.build_senders()
	w.update_window()
}

// sim_warnings validates every channel's simulated ECUs against its DBC and returns
// human-readable issues (node not a DBC BU_ / generator signal not in the node's
// messages) — the silent-typo guard surfaced at the top of the Simulation panel.
fn sim_warnings(app &App) []string {
	mut out := []string{}
	for i, ch in app.proj.channels {
		if ch.databases.len == 0 {
			continue
		}
		db := app.dbs[i] or { continue }
		for node in ch.all_nodes() {
			signames := node.signals.map(it.signal)
			for warn in sim.validate_node(db, node.name, signames) {
				out << '${ch.name}: ${warn}'
			}
		}
	}
	return out
}

// scaffold_sim_node fills (or replaces) a node's config with default generators
// derived from the channel's DBC, then rebuilds the sim. In-memory; persist on Save.
fn scaffold_sim_node(ch_idx int, node string, mut w gui.Window) {
	mut app := w.state[App]()
	if ch_idx < 0 || ch_idx >= app.proj.channels.len {
		return
	}
	db := app.dbs[ch_idx] or { return }
	cfg := scaffold_node(db, node)
	mut found := false
	for k in 0 .. app.proj.channels[ch_idx].nodes.len {
		if app.proj.channels[ch_idx].nodes[k].name == node {
			app.proj.channels[ch_idx].nodes[k] = cfg
			found = true
			break
		}
	}
	if !found {
		app.proj.channels[ch_idx].nodes << cfg
	}
	app.build_sim_nodes()
	app.notify(.info, 'scaffolded ${cfg.signals.len} signal(s) for ${node} — tweak/Save (session-only until Save)')
	w.update_window()
}

// build_node turns a project node config into a simulation ECU: when it carries
// signal/response config, build from that; otherwise use the built-in default
// behaviour (the hand-tuned SUT for 'SUT', generic DBC-derived otherwise).
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

// scaffold_signal picks a sensible default generator for a DBC signal so a
// scaffolded node transmits realistic, in-range data with zero hand-tuning (and no
// possible typo — it's derived from the DBC): a 1-bit signal toggles, an enum cycles
// its value table, anything else sines across its physical range (the DBC [min|max],
// or, when unspecified, the range derived from the bit width + factor/offset).
fn scaffold_signal(s candb.Signal) project.GenCfg {
	if s.length == 1 {
		return project.GenCfg{
			signal: s.name
			typ:    'stepmod'
			period: 2
			count:  2
			base:   0
		} // toggle 0/1
	}
	if s.values.len > 0 {
		mut base := f64(1e30)
		for k, _ in s.values {
			if f64(k) < base {
				base = f64(k)
			}
		}
		if base > 1e29 {
			base = 0
		}
		return project.GenCfg{
			signal: s.name
			typ:    'stepmod'
			period: 2
			count:  f64(s.values.len)
			base:   base
		} // cycle the enum
	}
	mut lo := s.minimum
	mut hi := s.maximum
	if !(hi > lo) {
		// No DBC range — derive the physical range from the bit width + factor/offset.
		if s.is_signed && s.length >= 2 {
			half := f64(u64(1) << (s.length - 1))
			lo = -half * s.factor + s.offset
			hi = (half - 1) * s.factor + s.offset
		} else {
			rawmax := if s.length >= 63 {
				f64(u64(-1))
			} else {
				f64((u64(1) << u64(s.length)) - 1)
			}
			lo = s.offset
			hi = rawmax * s.factor + s.offset
		}
	}
	return project.GenCfg{
		signal:    s.name
		typ:       'sine'
		offset:    (lo + hi) / 2
		amplitude: (hi - lo) / 2
		freq:      0.5
	}
}

// scaffold_node builds a NodeCfg whose signals all have default generators — every
// signal the node transmits (its DBC messages), deduped, mux switch left alone.
fn scaffold_node(db candb.Database, node string) project.NodeCfg {
	mut sigs := []project.GenCfg{}
	mut seen := map[string]bool{}
	for m in db.messages_from(node) {
		for s in m.signals {
			if s.is_multiplexor || s.name in seen {
				continue
			}
			seen[s.name] = true
			sigs << scaffold_signal(s)
		}
	}
	return project.NodeCfg{
		name:    node
		signals: sigs
	}
}

// --- Generator editor helpers (GUI authoring of per-signal generators) ---

// gnum formats a number compactly (no trailing .0 when integral).
fn gnum(v f64) string {
	return if v == f64(int(v)) { '${int(v)}' } else { '${v:.2f}' }
}

// node_gens returns a node's configured generators (its project NodeCfg.signals), or
// [] if the node isn't configured yet (Scaffold first to get editable generators).
fn node_gens(app &App, ch_idx int, node string) []project.GenCfg {
	if ch_idx < 0 || ch_idx >= app.proj.channels.len {
		return []project.GenCfg{}
	}
	for n in app.proj.channels[ch_idx].nodes {
		if n.name == node {
			return n.signals
		}
	}
	return []project.GenCfg{}
}

// gen_summary is the one-line description shown for a signal's generator.
fn gen_summary(g project.GenCfg) string {
	return match g.typ {
		'const' { 'const ${gnum(g.value)}' }
		'sine' { 'sine ${gnum(g.offset)}±${gnum(g.amplitude)} @${gnum(g.freq)}' }
		'sawtooth' { 'sawtooth ${gnum(g.min)}..${gnum(g.max)} /${gnum(g.period)}s' }
		'counter' { 'counter ${gnum(g.start)}+${gnum(g.step)} %${gnum(g.modulo)}' }
		'stepmod' { 'stepmod ${gnum(g.base)} ×${gnum(g.count)} /${gnum(g.period)}s' }
		else { g.typ }
	}
}

// gen_fields lists the editable parameters relevant to a generator type.
fn gen_fields(typ string) []string {
	return match typ {
		'const' { ['value'] }
		'sine' { ['offset', 'amplitude', 'freq', 'phase'] }
		'sawtooth' { ['min', 'max', 'period'] }
		'counter' { ['start', 'step', 'modulo'] }
		'stepmod' { ['period', 'count', 'base'] }
		else { []string{} }
	}
}

// gen_field_val reads one named parameter from a generator.
fn gen_field_val(g project.GenCfg, f string) f64 {
	return match f {
		'value' { g.value }
		'offset' { g.offset }
		'amplitude' { g.amplitude }
		'freq' { g.freq }
		'phase' { g.phase }
		'min' { g.min }
		'max' { g.max }
		'period' { g.period }
		'start' { g.start }
		'step' { g.step }
		'modulo' { g.modulo }
		'count' { g.count }
		'base' { g.base }
		else { f64(0) }
	}
}

// set_gen_type / set_gen_field mutate a signal's generator in the project (in-memory;
// persists on Save, applies to the sim on the next ▶ Start). They don't rebuild the
// running engine (that would reset the per-node enable toggles), and the displayed
// summary reads back from the config so the edit shows immediately.
fn set_gen_type(ch_idx int, node string, sig string, typ string, mut w gui.Window) {
	mut app := w.state[App]()
	if ch_idx < 0 || ch_idx >= app.proj.channels.len {
		return
	}
	for ni in 0 .. app.proj.channels[ch_idx].nodes.len {
		if app.proj.channels[ch_idx].nodes[ni].name != node {
			continue
		}
		for si in 0 .. app.proj.channels[ch_idx].nodes[ni].signals.len {
			if app.proj.channels[ch_idx].nodes[ni].signals[si].signal == sig {
				app.proj.channels[ch_idx].nodes[ni].signals[si].typ = typ
				w.update_window()
				return
			}
		}
	}
}

fn set_gen_field(ch_idx int, node string, sig string, field string, val f64, mut w gui.Window) {
	mut app := w.state[App]()
	if ch_idx < 0 || ch_idx >= app.proj.channels.len {
		return
	}
	for ni in 0 .. app.proj.channels[ch_idx].nodes.len {
		if app.proj.channels[ch_idx].nodes[ni].name != node {
			continue
		}
		for si in 0 .. app.proj.channels[ch_idx].nodes[ni].signals.len {
			if app.proj.channels[ch_idx].nodes[ni].signals[si].signal != sig {
				continue
			}
			match field {
				'value' { app.proj.channels[ch_idx].nodes[ni].signals[si].value = val }
				'offset' { app.proj.channels[ch_idx].nodes[ni].signals[si].offset = val }
				'amplitude' { app.proj.channels[ch_idx].nodes[ni].signals[si].amplitude = val }
				'freq' { app.proj.channels[ch_idx].nodes[ni].signals[si].freq = val }
				'phase' { app.proj.channels[ch_idx].nodes[ni].signals[si].phase = val }
				'min' { app.proj.channels[ch_idx].nodes[ni].signals[si].min = val }
				'max' { app.proj.channels[ch_idx].nodes[ni].signals[si].max = val }
				'period' { app.proj.channels[ch_idx].nodes[ni].signals[si].period = val }
				'start' { app.proj.channels[ch_idx].nodes[ni].signals[si].start = val }
				'step' { app.proj.channels[ch_idx].nodes[ni].signals[si].step = val }
				'modulo' { app.proj.channels[ch_idx].nodes[ni].signals[si].modulo = val }
				'count' { app.proj.channels[ch_idx].nodes[ni].signals[si].count = val }
				'base' { app.proj.channels[ch_idx].nodes[ni].signals[si].base = val }
				else {}
			}
			return
		}
	}
}

// gen_of maps a project generator spec to a sim.Gen.
fn gen_of(g project.GenCfg) sim.Gen {
	return match g.typ {
		'sine' { sim.gen_sine(g.offset, g.amplitude, g.freq, g.phase) }
		'sawtooth' { sim.gen_sawtooth(g.min, g.max, g.period) }
		'counter' { sim.gen_counter(g.start, g.step, g.modulo) }
		'stepmod' { sim.gen_stepmod(g.period, g.count, g.base) }
		else { sim.gen_const(g.value) }
	}
}

// sim_signature is the set of currently-enabled simulated nodes on a channel,
// used by sim_loop to detect live connect/disconnect and rebuild its engine.
fn sim_signature(app &App, ch_idx int) string {
	mut on := []string{}
	for sn in app.sim_nodes {
		if sn.ch_idx == ch_idx && sn.enabled {
			on << sn.node
		}
	}
	return on.join(',')
}

// is_wsl reports whether we're running under WSL — where the XDG Desktop Portal's
// file-dialog Response never arrives and hangs the UI thread, so we prefer gui's
// zenity backend (see the GUI_NO_PORTAL default in main).
fn is_wsl() bool {
	if os.getenv('WSL_DISTRO_NAME') != '' || os.getenv('WSL_INTEROP') != '' {
		return true
	}
	rel := os.read_file('/proc/sys/kernel/osrelease') or { return false }
	low := rel.to_lower()
	return low.contains('microsoft') || low.contains('wsl')
}

fn main() {
	// DPI workaround (see g_ui_scale): read the startup UI scale BEFORE building the
	// window/theme so the initial window size and all theme sizes use it. Accepts a
	// factor (1.5) or a percentage (150%).
	if v := os.getenv_opt('BLOBLY_UI_SCALE') {
		raw := v.trim_space()
		if raw.ends_with('%') {
			g_ui_scale = clamp_scale(raw.trim_right('%').f32() / 100)
		} else {
			g_ui_scale = clamp_scale(raw.f32())
		}
	}
	// On WSL, default to gui's zenity/kdialog file dialogs instead of the XDG
	// Desktop Portal: gui's portal path (nativebridge/portal_linux.c) does a
	// synchronous D-Bus wait for the FileChooser Response that never arrives under
	// WSLg, wedging the UI thread (the file requester opens, then the app hangs
	// after OK). Real desktops keep the working portal. An explicit GUI_NO_PORTAL
	// (0 or 1) always wins. See docs/known_issues.md + docs/v_patches/gui-no-portal-fallback.
	if os.getenv('GUI_NO_PORTAL') == '' && is_wsl() {
		os.setenv('GUI_NO_PORTAL', '1', true)
	}
	mut window := gui.window(
		title:        'Blobly Net — CAN'
		state:        &App{}
		width:        int(1500 * g_ui_scale)
		height:       int(920 * g_ui_scale)
		sample_count: 4 // MSAA — antialias the Graphics polylines (needs gui patch)
		// Global hotkeys for interactive generators: a `char` event with no input
		// focused fires the matching sender (conventional tooling "key on"). gui's per-widget
		// handlers still run; we only act on otherwise-unconsumed typing.
		on_event:     fn (e &gui.Event, mut w gui.Window) {
			if e.typ == .char {
				handle_hotkey(e.char_code, mut w)
			}
		}
		on_init:      fn (mut w gui.Window) {
			mut app := w.state[App]()
			app.t0 = time.ticks()
			app.dock_root = default_layout()
			// Load the project (bus setup). Precedence: CLI arg (first positional
			// path, e.g. `blobly_net projects/foo.yml`) > BLOBLY_PROJECT env >
			// most-recently-opened project > projects/demo.yml > a built-in
			// single-vcan0 default so the app always runs.
			app.recents = load_recents()
			proj_path := cli_project_arg() or {
				os.getenv_opt('BLOBLY_PROJECT') or {
					if app.recents.len > 0 { app.recents[0] } else { 'projects/demo.yml' }
				}
			}
			if p := project.load(proj_path) {
				app.proj = p
				app.proj_source = proj_path
				app.remember_project(proj_path)
			} else {
				app.proj = project.default_project()
				app.proj_source = 'built-in default (${err})'
			}
			app.rt = []ChannelRT{len: app.proj.channels.len}
			app.load_databases()
			app.build_sim_nodes()
			set_window_title(app.proj.name)
			app.log_path = os.getenv_opt('BLOBLY_LOG') or { '' }
			vnote := app.proj.version_note()
			app.notify(if vnote != '' { .warn } else { .info }, if vnote != '' {
				'⚠ ${vnote}'
			} else {
				'stopped — press ▶ Start (${app.proj.channels.len} channel(s))'
			})
			w.update_view(main_view)
			// Intercept markdown link clicks (Help panel): keep internal/relative
			// links in-app instead of letting gui spawn the OS browser. Only real
			// http(s) URLs fall through to the browser. See help_link_handler.
			w.set_link_handler(help_link_handler)
			// BLOBLY_AUTOSTART=1 begins measurement immediately on launch —
			// handy for the screenshot loop (xdotool clicking is unreliable under
			// WSLg), harmless otherwise.
			if os.getenv('BLOBLY_AUTOSTART') != '' {
				start_measurement(mut w)
			}
			// BLOBLY_RUN_MS=N exits the process after N ms — for clean profiler
			// (heaptrack/valgrind) finalization. Dev-only.
			if ms := os.getenv_opt('BLOBLY_RUN_MS') {
				spawn fn (n int) {
					time.sleep(n * time.millisecond)
					exit(0)
				}(ms.int())
			}
			// BLOBLY_MEMLOG=1 logs RSS + the V GC heap every 3s; BLOBLY_GCFORCE=1
			// also forces a collection each tick — to tell a V-heap leak (both grow)
			// from a C-side one (RSS grows, gcheap flat). Dev-only.
			if os.getenv('BLOBLY_MEMLOG') != '' {
				spawn fn () {
					force := os.getenv('BLOBLY_GCFORCE') != ''
					for {
						time.sleep(3 * time.second)
						if force {
							gc_collect()
						}
						mut rss := 0
						if s := os.read_file('/proc/self/status') {
							for line in s.split_into_lines() {
								if line.starts_with('VmRSS:') {
									rss = line.fields()[1].int()
									break
								}
							}
						}
						eprintln('[mem] RSS=${rss} kB  gcheap=${gc_memory_use() / 1024} kB')
					}
				}()
			}
		}
	)
	window.set_theme(make_theme(palette_opus))
	window.run()
}

// make_theme builds the app theme from a Palette (colours) + the ui_size_* scale
// (fonts) + tightened padding/spacing for a dense, Directory-Opus-like layout.
// One function, one palette in — the single source of truth for look & feel.
fn make_theme(p Palette) gui.Theme {
	base := if p.dark { gui.theme_dark_bordered } else { gui.theme_light_bordered }
	// Base text style: drives the app-wide font + text colour. family flows to
	// every derived style via gui's font_variants(); fall back to the base family
	// (gui's bundled default) when ui_font_family is ''.
	family := if ui_font_family != '' { ui_font_family } else { base.cfg.text_style.family }
	// One DPI knob: scale every font size + padding/spacing/radius uniformly.
	s := g_ui_scale
	pad := fn (top f32, right f32, bottom f32, left f32, s f32) gui.Padding {
		return gui.Padding{top * s, right * s, bottom * s, left * s}
	}
	text_style := gui.TextStyle{
		...base.cfg.text_style
		family: family
		size:   ui_size_medium * s
		color:  p.text
	}
	cfg := gui.ThemeCfg{
		...base.cfg
		name:               p.name
		color_background:   p.background
		color_panel:        p.panel
		color_interior:     p.interior
		color_hover:        p.hover
		color_focus:        p.focus
		color_active:       p.active
		color_border:       p.border
		color_border_focus: p.accent
		color_select:       p.select
		titlebar_dark:      p.dark
		size_text_tiny:    ui_size_tiny * s
		size_text_x_small: ui_size_x_small * s
		size_text_small:   ui_size_small * s
		size_text_medium:  ui_size_medium * s
		size_text_large:   ui_size_large * s
		size_text_x_large: ui_size_x_large * s
		text_style:        text_style
		padding:        pad(3, 6, 3, 6, s)
		padding_small:  pad(2, 4, 2, 4, s)
		padding_medium: pad(3, 6, 3, 6, s)
		padding_large:  pad(5, 10, 5, 10, s)
		spacing_small:  2 * s
		spacing_medium: 5 * s
		spacing_large:  8 * s
		radius:         3 * s
		radius_small:   2 * s
		radius_medium:  3 * s
		radius_large:   4 * s
	}
	mut t := gui.theme_maker(&cfg)
	// Slim the toolbar buttons and grid cells/headers — their padding isn't
	// driven by ThemeCfg (it uses fixed consts), so override the widget styles.
	t = t.with_button_style(gui.ButtonStyle{
		...t.button_style
		padding: pad(1, 7, 1, 7, s)
	})
	t = t.with_data_grid_style(gui.DataGridStyle{
		...t.data_grid_style
		padding_cell:   pad(0, 4, 0, 4, s)
		padding_header: pad(0, 4, 0, 4, s)
		color_border:   p.gridline   // listview gridlines (darker than panel frames)
		color_header:   p.background // grey header strip, distinct from white rows
	})
	return t
}

// Buses (narrow left) | Trace (centre) | Signals / Send / Statistics stacked
// (right) — each its own panel. They can still be tabbed/dragged by the user.
fn default_layout() &gui.DockNode {
	// A focused default — Trace + Buses + Simulation + Signals + Graphics, with a Log
	// strip across the bottom. Send, Diagnostics, Script, Statistics and Symbol Browser
	// start hidden; toggle them from the left activity bar (or the View menu). Right
	// column: Signals over Graphics.
	right := gui.dock_split('r1', .vertical, 0.42, gui.dock_panel_group('g_sig', ['signals'],
		'signals'), gui.dock_panel_group('g_plot', ['plot'], 'plot'))
	// Trace over the independently-filtered trace (conventional second trace window).
	traces := gui.dock_split('t1', .vertical, 0.55, gui.dock_panel_group('g_trace', ['trace'],
		'trace'), gui.dock_panel_group('g_ftrace', ['ftrace'], 'ftrace'))
	mid := gui.dock_split('mid', .horizontal, 0.66, traces, right)
	// Left column: Buses (top) over Simulation (bottom).
	left := gui.dock_split('l1', .vertical, 0.45, gui.dock_panel_group('g_buses', ['buses'],
		'buses'), gui.dock_panel_group('g_sim', ['simulation'], 'simulation'))
	main_area := gui.dock_split('main', .horizontal, 0.18, left, mid)
	// Log strip across the bottom, visible at startup (full window width).
	return gui.dock_split('root', .vertical, 0.82, main_area, gui.dock_panel_group('g_log',
		['log'], 'log'))
}

// load_databases loads each channel's DBC into a per-channel catalog (app.dbs,
// parallel to proj.channels) — so every bus simulates/decodes its OWN messages —
// and builds a merged catalog (app.db) for id-based decode lookups across buses.
// With no DBC attached, the merged catalog is left EMPTY (raw frames only — no
// phantom messages in Send), rather than falling back to a built-in sample catalog.
// notify updates the toolbar status line AND appends a timestamped entry to the
// scrolling Log panel (bounded). `level` colours the Log entry. Use this instead
// of assigning `app.status` directly so events are kept in the Log.
fn (mut app App) notify(level StatusLevel, msg string) {
	app.status = msg
	t := time.now()
	app.logs << StatusMsg{
		tstamp: '${t.hour:02}:${t.minute:02}:${t.second:02}'
		level:  level
		text:   msg
	}
	if app.logs.len > 300 {
		app.logs = app.logs[app.logs.len - 200..].clone()
	}
}

fn (mut app App) load_databases() {
	app.dbs = []candb.Database{len: app.proj.channels.len}
	mut sources := []string{}
	for i, ch in app.proj.channels {
		// Merge every DBC attached to this channel into one per-channel catalog
		// (first DBC to define an id wins on collision; nodes deduped).
		mut chan_msgs := []candb.Message{}
		mut chan_nodes := []string{}
		mut chan_seen := map[u32]bool{}
		for path in ch.databases {
			db := candb.load_dbc_file(path) or { continue }
			sources << path
			for m in db.messages {
				if m.id !in chan_seen {
					chan_seen[m.id] = true
					chan_msgs << m
				}
			}
			for n in db.nodes {
				if n !in chan_nodes {
					chan_nodes << n
				}
			}
		}
		app.dbs[i] = candb.Database{
			messages: chan_msgs
			nodes:    chan_nodes
		}
	}
	// Merge for decode: first DBC to define an id wins (cross-bus id collisions
	// are rare; the chronological view's Ch column still disambiguates them).
	mut msgs := []candb.Message{}
	mut seen := map[u32]bool{}
	for db in app.dbs {
		for m in db.messages {
			if m.id !in seen {
				seen[m.id] = true
				msgs << m
			}
		}
	}
	if msgs.len == 0 {
		// No DBC attached to any channel — leave the catalog EMPTY. Trace shows raw
		// frames and Send offers raw-only (no phantom DBC messages). Previously this
		// fell back to sampledb, which looked like a stale database after New Project.
		app.db = candb.Database{}
		app.db_source = 'no database'
		return
	}
	app.db = candb.Database{
		messages: msgs
	}
	app.db_source = if sources.len == 1 {
		sources[0]
	} else {
		'${sources.len} DBCs merged (${msgs.len} msgs)'
	}
}

// start_measurement attaches every enabled channel per its mode (the conventional
// measurement lifecycle): monitor → opens the bus + RX thread (+ sim engine if
// the channel hosts simulated nodes); replay → opens the bus + a player thread
// that transmits the configured recording at its recorded cadence.
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
		// `mode: off` means "configured but not attached" for every channel type
		// (CAN or DoIP) — checked here so the DoIP special case below honours it too.
		if ch.mode == .off {
			app.rt[i].note = 'off'
			continue
		}
		// DoIP channels are diagnostics-over-Ethernet endpoints, not CAN buses:
		// there are no frames to monitor, so we don't open a transport.Bus or an
		// RX thread. If the channel hosts a simulated ECU, spawn the DoIP server
		// (driver-free, real localhost TCP/UDP); the Diagnostics panel then talks
		// to it (or to a real/external entity) as a DoIP client.
		if ch.is_doip() {
			host, port := ch.doip_endpoint()
			hosts_ecu := ch.all_nodes().len > 0
			app.rt[i].running = true
			app.rt[i].note = if hosts_ecu {
				'DoIP entity @${host}:${port}'
			} else {
				'DoIP client → ${host}:${port}'
			}
			opened++
			if hosts_ecu {
				spawn fn [i] (mut w gui.Window) {
					doip_server_loop(i, mut w)
				}(mut w)
			}
			continue
		}
		match ch.mode {
			.off {
				app.rt[i].note = 'off'
			}
			.monitor {
				if bus := transport.open(ch.iface) {
					app.rt[i].bus = bus
					app.rt[i].running = true
					can_sim := app.sim_nodes.any(it.ch_idx == i)
					app.rt[i].note = if can_sim { 'monitoring + simulation' } else { 'monitoring' }
					opened++
					spawn fn [i] (mut w gui.Window) {
						rx_loop(i, mut w)
					}(mut w)
					// If the network can host simulated ECUs, spawn the sim engine on its own
					// bus instance attached to the same interface (so the monitor's RX thread
					// hears the simulated traffic via the normal path). It simulates whichever
					// nodes are checked in the Simulation panel, live.
					if can_sim {
						spawn fn [i] (mut w gui.Window) {
							sim_loop(i, mut w)
						}(mut w)
						// The simulated ECU also answers UDS (0x7E0 -> 0x7E8) over
						// software ISO-TP on the same bus — diagnostics with no
						// Python and no kernel CAN_ISOTP.
						spawn fn [i] (mut w gui.Window) {
							diag_server_loop(i, mut w)
						}(mut w)
					}
				} else {
					app.rt[i].err = true
					app.rt[i].note = 'open failed: ${err}'
				}
			}
			.replay {
				rcfg := ch.replay or {
					app.rt[i].err = true
					app.rt[i].note = 'replay: no source configured'
					continue
				}
				if bus := transport.open(ch.iface) {
					app.rt[i].bus = bus
					app.rt[i].running = true
					app.rt[i].note = 'replay: ${os.base(rcfg.source)}'
					opened++
					spawn fn [i] (mut w gui.Window) {
						replay_loop(i, mut w)
					}(mut w)
				} else {
					app.rt[i].err = true
					app.rt[i].note = 'open failed: ${err}'
				}
			}
		}
	}
	app.running = true
	app.notify(.info, 'running — ${opened} channel(s) attached')
	// One thread drives all cyclic interactive generators (trigger: cyclic).
	if app.senders.any(it.cfg.trigger == 'cyclic' && it.cfg.cycle_ms > 0) {
		spawn fn (mut w gui.Window) {
			gen_loop(mut w)
		}(mut w)
	}
	// Drive the toolbar stutter-spinner (~30 fps) while running. This forces a
	// steady repaint cadence so GUI render hitches show up as a jerk in the spin.
	spawn fn (mut w gui.Window) {
		spin_loop(mut w)
	}(mut w)
}

// spin_loop requests a repaint ~30×/s while a measurement runs, animating the
// toolbar spinner and surfacing GUI render stutters. Exits when running stops.
fn spin_loop(mut w gui.Window) {
	for {
		app := w.state[App]()
		if !app.running {
			break
		}
		w.queue_command(fn (mut w gui.Window) {
			w.update_window()
		})
		time.sleep(33 * time.millisecond)
	}
}

// gen_loop transmits the cyclic interactive generators (trigger: cyclic) at their
// configured periods while the measurement runs. Sends on each sender's own
// channel bus (a dedicated bus instance per interface, like sim_loop) and records
// the frames as TX via the bounded inbox. Manual/key senders fire on the UI
// thread instead (see fire_sender); only cyclic ones need this clock.
fn gen_loop(mut w gui.Window) {
	mut app := w.state[App]()
	// A dedicated bus per interface used by a cyclic sender (opened lazily; closed
	// on exit) — avoids sharing the monitor's bus handle across threads.
	mut buses := map[string]transport.Bus{}
	mut next := map[int]f64{} // sender index -> next-due ms
	t0 := time.ticks()
	for app.running {
		now := f64(time.ticks() - t0)
		mut sent_any := false
		for si, sr in app.senders {
			if sr.cfg.trigger != 'cyclic' || sr.cfg.cycle_ms <= 0 {
				continue
			}
			if sr.ch_idx >= app.rt.len || !app.rt[sr.ch_idx].running {
				continue
			}
			if now < (next[si] or { 0.0 }) {
				continue
			}
			iface := app.proj.channels[sr.ch_idx].iface
			if iface !in buses {
				buses[iface] = transport.open(iface) or { continue }
			}
			mut bus := buses[iface] or { continue }
			frame := app.build_sender_frame(sr.cfg)
			bus.send(frame) or {}
			app.inbox_push(InboxItem{
				idx:   sr.ch_idx
				dir:   'TX'
				frame: frame
			})
			next[si] = now + f64(sr.cfg.cycle_ms)
			sent_any = true
		}
		if sent_any {
			app.request_drain(mut w)
		}
		time.sleep(2 * time.millisecond)
	}
	for _, mut b in buses {
		b.close()
	}
}

// reset_diag_discovery clears discovered DoIP entities + any selected diagnostics
// target, and bumps the scan generation so an in-flight discovery worker's late
// callback is discarded. Called whenever the project/measurement changes (Stop /
// New / Open) so stale entities can't be shown or selected.
fn (mut app App) reset_diag_discovery() {
	app.doip_entities = []
	app.doip_scan_gen++
	app.diag_sel = none
	app.diag_sel_name = ''
}

// reset_plot clears the Graphics watch list + its derived decode/scale state. Called
// on project change (Open/New) and the Graphics/Trace Clear buttons, so pins from a
// previous project (referencing frames that may not exist or mean something else in
// the new one) and stale expand-only Y-ranges don't leak across. Does NOT touch
// plot_hist — callers that also wipe history (project load, Trace Clear) do that.
fn (mut app App) reset_plot() {
	app.plot_watch = []
	app.plot_range = map[string][2]f32{}
	app.plot_off = map[string]bool{}
	app.plot_sig = ''
	app.plot_series = [][]f32{}
	app.plot_times = [][]f32{}
	app.plot_cur = []f64{}
}

// stop_measurement signals every running channel's RX thread to exit; each
// thread closes its own bus on the way out (avoids closing under a blocked recv).
// For DoIP channels we ALSO close the server here so its bound TCP/UDP sockets are
// released immediately (a flag flip alone can't interrupt a blocked accept/read):
// the serve loop then exits on the next iteration and its defer close()s again
// harmlessly.
fn stop_measurement(mut w gui.Window) {
	mut app := w.state[App]()
	for i in 0 .. app.rt.len {
		if app.rt[i].running {
			app.rt[i].running = false
			app.rt[i].note = 'stopped'
		}
		if mut srv := app.rt[i].doip_srv {
			srv.close()
			app.rt[i].doip_srv = none
		}
	}
	app.running = false
	app.reset_diag_discovery() // discovered entities / target are stale once stopped
	app.notify(.info, 'stopped')
}

// sim_loop runs the simulated ECUs for channel `idx` on a dedicated in-process
// bus instance attached to the same interface as the monitor, so its emitted
// frames reach the monitor's RX thread via the normal bus path (no special
// wiring — exactly like a real ECU on the wire). Transmits due cyclic frames and
// answers requests until the channel stops. GUI-free engine; this thread only
// touches the bus + its own engine.
fn sim_loop(idx int, mut w gui.Window) {
	app := w.state[App]()
	ch := app.proj.channels[idx]
	ch_db := if idx < app.dbs.len { app.dbs[idx] } else { candb.Database{} }
	mut bus := transport.open(ch.iface) or { return }
	mut engine := sim.Engine{}
	mut sig := '\x00' // force an initial build (differs from any real signature)
	t0 := time.ticks()
	for app.rt[idx].running {
		// Live connect/disconnect: when the set of enabled nodes (Simulation panel
		// checkboxes) changes, rebuild the engine to match.
		cur := sim_signature(app, idx)
		if cur != sig {
			sig = cur
			engine = sim.Engine{}
			for sn in app.sim_nodes {
				if sn.ch_idx == idx && sn.enabled {
					engine.ecus << build_node(ch_db, sn.cfg)
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

// replay_loop transmits channel `idx`'s configured recording onto its bus at
// the recorded cadence × speed (modules/player drives the timing; this thread
// only supplies the wall clock and the bus). Sent frames are recorded as TX in
// batches with the same bounded-repaint scheme as rx_loop. Monitoring the same
// interface on another channel shows the replay via the normal RX path —
// exactly like traffic from a real node on the wire.
fn replay_loop(idx int, mut w gui.Window) {
	mut app := w.state[App]()
	ch := app.proj.channels[idx]
	rcfg := ch.replay or { return } // start_measurement guarantees it
	mut bus := app.rt[idx].bus or { return }
	// Load in this thread so Start stays snappy (a big MF4 takes a moment).
	entries := load_entries(rcfg.source) or {
		msg := 'replay: ${err}'
		w.queue_command(fn [idx, msg] (mut w gui.Window) {
			mut a := w.state[App]()
			a.rt[idx].err = true
			a.rt[idx].note = msg
			a.rt[idx].running = false
			w.update_window()
		})
		bus.close()
		return
	}
	mut pl := player.new_player(entries, rcfg.speed, rcfg.repeat)
	t0 := time.ticks()
	pl.play(0)
	mut last_flush := time.ticks()
	for app.rt[idx].running {
		now := f64(time.ticks() - t0)
		for e in pl.due(now) {
			bus.send(e.frame) or {}
			app.inbox_push(InboxItem{ idx: idx, dir: 'TX', frame: e.frame })
		}
		fin := pl.finished()
		nticks := time.ticks()
		if fin || nticks - last_flush >= flush_ms_for(app.fps) {
			last_flush = nticks
			note := if fin {
				'replay finished (${pl.len()} frames)'
			} else if rcfg.repeat {
				'replay loop ${pl.passes() + 1} — ${int(pl.progress(now) * 100)}%'
			} else {
				'replay ${int(pl.progress(now) * 100)}% (${pl.sent()}/${pl.len()})'
			}
			app.request_drain(mut w) // TX frames recorded via the bounded inbox
			w.queue_command(fn [idx, note, fin] (mut w gui.Window) {
				mut a := w.state[App]()
				a.rt[idx].note = note
				if fin {
					a.rt[idx].running = false
				}
				w.update_window()
			})
			if fin {
				break
			}
		}
		time.sleep(time.millisecond)
	}
	bus.close()
}

// diag_server_loop runs the native UDS server for channel `idx`'s simulated
// ECU: software ISO-TP on its own bus instance, answering tester requests on
// the standard physical pair (rx 0x7E0 / tx 0x7E8) until the channel stops.
fn diag_server_loop(idx int, mut w gui.Window) {
	app := w.state[App]()
	iface := app.proj.channels[idx].iface
	mut ch := isotp.open_software(iface, diag_rx_id, diag_tx_id, false) or { return }
	mut srv := uds.default_server()
	for app.rt[idx].running {
		req := ch.recv(50) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}

// doip_server_loop runs a native DoIP entity (simulated ECU) for channel `idx`:
// it wraps the same uds.Server the CAN path uses, but over real localhost
// TCP/UDP (ISO 13400) instead of software ISO-TP — driver-free, no CAN bus. The
// Diagnostics panel connects to it as a DoIP client. Serves TCP diagnostics and
// UDP vehicle discovery, polling the channel's running flag to exit.
fn doip_server_loop(idx int, mut w gui.Window) {
	app := w.state[App]()
	ch := app.proj.channels[idx]
	host, port := ch.doip_endpoint()
	mut us := uds.default_server()
	// Make UDS RDBI of the VIN (DID 0xF190) match this entity's announced VIN, so a
	// selected entity reads back its own identity instead of the default SUT VIN.
	if ch.vin != '' {
		us.dids[0xF190] = ch.vin.bytes()
	}
	handler := fn [mut us] (req []u8) []u8 {
		return us.handle(req)
	}
	mut srv := doip.new_server(doip.server_cfg(ch.ecu_addr, ch.vin, ch.eid), handler)
	srv.listen(host, port) or {
		srv.close() // release any partially-opened socket (listen() is atomic, but be safe)
		// On the worker thread — bounce the failure status onto the UI thread (the
		// app's cross-thread convention) instead of mutating App + repainting here.
		emsg := err.msg()
		w.queue_command(fn [idx, emsg] (mut w gui.Window) {
			mut a := w.state[App]()
			a.rt[idx].err = true
			a.rt[idx].running = false
			a.rt[idx].note = 'DoIP listen failed: ${emsg}'
			// If this failure leaves no channel attached, drop back out of the
			// global Running state so Start works again (otherwise a single-channel
			// DoIP project is stuck "running" with no live target).
			if !a.rt.any(it.running) {
				a.running = false
				a.notify(.warn, 'stopped — no channels attached (DoIP bind failed)')
			}
			w.update_window()
		})
		return
	}
	// Publish the server handle so Stop can close the sockets promptly (releasing
	// the bound port for an immediate restart and unblocking a pending accept).
	w.queue_command(fn [idx, srv] (mut w gui.Window) {
		mut a := w.state[App]()
		a.rt[idx].doip_srv = srv
	})
	defer {
		srv.close()
	}
	// UDP vehicle discovery runs on its OWN thread so it stays orthogonal to TCP:
	// otherwise a connected/idle tester holds accept_and_serve in serve_connection
	// and discovery would go unanswered until that session ends. Both threads exit
	// on the running flag (and on srv.close() erroring their socket op).
	spawn fn [idx, srv] (mut w gui.Window) {
		app := w.state[App]()
		for app.rt[idx].running {
			srv.serve_udp_once(50) or {}
		}
	}(mut w)
	for app.rt[idx].running {
		// TCP diagnostics. Short accept timeout keeps the loop responsive to Stop;
		// Stop also closes the server (interrupting a blocked per-connection read).
		srv.accept_and_serve(50) or {}
	}
}

// diag_post appends one line to the Diagnostics log (UI thread, newest first).
fn diag_post(line string, mut w gui.Window) {
	w.queue_command(fn [line] (mut w gui.Window) {
		mut a := w.state[App]()
		a.diag_log.insert(0, line)
		if a.diag_log.len > 50 {
			a.diag_log = a.diag_log[..50].clone()
		}
		w.update_window()
	})
}

// DiagTarget describes where a UDS request should go: a CAN channel (software
// ISO-TP, tester 0x7E0 / ECU 0x7E8) or a DoIP entity (TCP, logical addresses).
// Both resolve to an isotp.Channel that uds.Client rides unchanged.
struct DiagTarget {
	is_doip     bool
	iface       string // CAN: the bus interface
	host        string // DoIP: host
	port        int    // DoIP: port
	tester_addr u16    // DoIP: our (tester) logical address
	ecu_addr    u16    // DoIP: ECU logical address
}

// DiscoveredEntity is one DoIP entity found by a discovery scan (its UDP vehicle
// announcement). ch_idx is the project channel it came from, or -1 for a manually
// probed host.
struct DiscoveredEntity {
	host    string
	port    int
	vin     string
	logical u16
	eid     []u8
	ch_idx  int = -1
}

// open_diag_channel opens the right isotp.Channel for a DiagTarget. DoipClient
// implements isotp.Channel, so UDS-over-Ethernet needs no client changes.
fn open_diag_channel(t DiagTarget) !isotp.Channel {
	if t.is_doip {
		return doip.open_doip(t.host, t.port, t.tester_addr, t.ecu_addr)!
	}
	return isotp.open_software(t.iface, diag_tx_id, diag_rx_id, false)!
}

// diag_request sends one UDS request from a worker thread: opens a diagnostics
// channel on the first running channel (software ISO-TP for CAN, or a DoIP TCP
// connection for a DoIP channel), runs the request, posts the outcome. For CAN
// the ISO-TP frames travel the real bus, so the Trace shows them too.
// diag_target_for builds a DiagTarget for a channel (DoIP vs CAN software ISO-TP).
fn diag_target_for(ch project.Channel) DiagTarget {
	if ch.is_doip() {
		host, port := ch.doip_endpoint()
		return DiagTarget{
			is_doip:     true
			host:        host
			port:        port
			tester_addr: ch.tester_addr
			ecu_addr:    ch.ecu_addr
		}
	}
	return DiagTarget{
		iface: ch.iface
	}
}

// resolve_diag_target returns where UDS requests should go: an explicit selection
// from the DoIP panel (app.diag_sel) wins; otherwise the first running channel.
fn resolve_diag_target(app &App) ?DiagTarget {
	if sel := app.diag_sel {
		return sel
	}
	for i, ch in app.proj.channels {
		if app.rt[i].running {
			return diag_target_for(ch)
		}
	}
	return none
}

fn diag_request(req []u8, label string, mut w gui.Window) {
	app := w.state[App]()
	target := resolve_diag_target(app) or {
		diag_post('${label}: no target — press ▶ Start (or pick an entity in DoIP)', mut w)
		return
	}
	spawn fn [req, label, target] (mut w gui.Window) {
		mut ch := open_diag_channel(target) or {
			diag_post('${label}: open failed: ${err}', mut w)
			return
		}
		defer {
			ch.close()
		}
		mut client := uds.new_client(ch)
		resp := client.raw(req) or {
			diag_post('${label}: ${err.msg()}', mut w)
			return
		}
		diag_post('${label}: ${diag_render(resp)}', mut w)
	}(mut w)
}

// diag_render shows a positive response as hex, plus ASCII when the payload
// is printable text (VIN, serial number…).
fn diag_render(resp []u8) string {
	h := hex(resp)
	// RDBI: try the data record (after SID + DID echo) as text.
	if resp.len > 3 && resp[0] == 0x62 {
		data := resp[3..]
		mut printable := data.len > 0
		for b in data {
			if b < 0x20 || b > 0x7E {
				printable = false
				break
			}
		}
		if printable {
			return '${h}  ("${data.bytestr()}")'
		}
	}
	return h
}

// InboxItem is one received/sent frame queued for the UI thread to record.
struct InboxItem {
	idx   int
	dir   string
	frame transport.CanFrame
}

const rx_inbox_cap = 8192 // buffered frames before the inbox drops oldest

// rx_loop reads frames and buffers them in App.inbox (bounded), waking the UI to
// record them at a bounded rate via request_drain. Each w.queue_command wakes sokol
// and forces a full GL frame (~tens of ms under WSLg's GL translation), so one wake
// per frame pegs the CPU on a busy bus — and undrained commands carrying frame
// clones used to pile up unboundedly when the window wasn't rendering (the leak).
// Now the frames live in a capped buffer and at most one drain is ever pending.
fn rx_loop(idx int, mut w gui.Window) {
	mut app := w.state[App]()
	mut bus := app.rt[idx].bus or { return }
	mut last_flush := time.ticks()
	for app.rt[idx].running {
		flush_ms := flush_ms_for(app.fps) // live: reflects the toolbar dropdown
		if frame := bus.recv(int(flush_ms)) {
			app.inbox_push(InboxItem{ idx: idx, dir: 'RX', frame: frame })
		}
		now := time.ticks()
		if now - last_flush >= flush_ms {
			last_flush = now
			app.request_drain(mut w) // queues AT MOST ONE drain (fps-bounded repaint)
		}
	}
	bus.close()
}

// inbox_push appends one frame to the shared inbox, dropping the oldest on overflow
// (amortised) — so it can never grow unbounded if the UI thread isn't draining.
fn (mut app App) inbox_push(it InboxItem) {
	app.inbox_mu.lock()
	app.inbox << it
	if app.inbox.len > rx_inbox_cap + rx_inbox_cap / 4 {
		app.inbox = app.inbox[app.inbox.len - rx_inbox_cap..].clone()
	}
	app.inbox_mu.unlock()
}

// request_drain queues a drain_inbox command only if one isn't already pending, so
// undrained commands never pile up (the old per-flush queue_command(frames) leak).
fn (mut app App) request_drain(mut w gui.Window) {
	app.inbox_mu.lock()
	need := app.inbox.len > 0 && !app.drain_queued
	if need {
		app.drain_queued = true
	}
	app.inbox_mu.unlock()
	if need {
		w.queue_command(drain_inbox)
	}
}

// drain_inbox (UI thread) records everything buffered since the last drain.
fn drain_inbox(mut w gui.Window) {
	mut a := w.state[App]()
	a.inbox_mu.lock()
	items := a.inbox.clone()
	a.inbox.clear()
	a.drain_queued = false
	a.inbox_mu.unlock()
	if a.paused {
		return // frames were already dropped from the bounded inbox
	}
	for it in items {
		ch := if it.idx < a.proj.channels.len { a.proj.channels[it.idx].name } else { 'CAN${it.idx + 1}' }
		if it.idx < a.rt.len {
			if it.dir == 'RX' {
				a.rt[it.idx].rx_count++
			} else {
				a.rt[it.idx].tx_count++
			}
		}
		a.push(it.dir, it.frame, ch)
	}
	w.update_window()
}

// push records a live frame, stamping it with the current wall-clock offset.
fn (mut app App) push(dir string, f transport.CanFrame, ch string) {
	app.record(dir, f, f64(time.ticks() - app.t0), ch)
}

// record appends a frame to the trace + grouped aggregate at an explicit time
// (ms). Live capture passes "now"; log replay passes the recorded timestamp.
// trace_group_key is the grouped-trace bucket: same ID on a different bus, or RX vs
// TX, are distinct groups. id is first so the message id parses back out (all_before '|').
fn trace_group_key(id u32, ch string, dir string) string {
	return '${id}|${ch}|${dir}'
}

// latest_for returns the most-recent aggregate for a message id across ALL groups
// (any bus/dir) — used by the Signals panel + Symbol Browser, which decode by id and
// don't care which bus/dir it came from. Empty MsgAgg if the id hasn't been seen.
fn (app &App) latest_for(id u32) MsgAgg {
	mut best := MsgAgg{}
	mut found := false
	for _, agg in app.grouped {
		if agg.id == id && (!found || agg.last_ms > best.last_ms) {
			best = agg
			found = true
		}
	}
	return best
}

fn (mut app App) record(dir string, f transport.CanFrame, t_ms f64, ch string) {
	app.seq++
	if dir == 'RX' {
		app.rx_count++
	} else {
		app.tx_count++
	}
	if app.recording {
		app.record_entries << canlog.LogEntry{
			t_s:   t_ms / 1000.0
			iface: ch
			frame: f
		}
	}
	name := if m := app.db.lookup_frame(f.id, f.extended) { m.name } else { '' }
	gkey := trace_group_key(f.id, ch, dir)
	prev := app.grouped[gkey] or { MsgAgg{} }
	first := prev.last.len == 0
	// Per-byte change vs the previous instance of this ID (bit i set = byte i
	// differs, or is new this frame). The chronological view colours a frame's
	// bytes by this; 0 means an exact repeat (shown greyed).
	mut changed := u8(0)
	for i in 0 .. 8 {
		if i < f.data.len && (first || i >= prev.last.len || f.data[i] != prev.last[i]) {
			changed |= u8(1) << i
		}
	}
	app.trace << TraceRow{
		seq:     app.seq
		t_ms:    t_ms
		ch:      ch
		dir:     dir
		id:      f.id
		ext:     f.extended
		dlc:     f.data.len
		data:    f.data.clone()
		name:    name
		changed: changed
	}
	// Trim in bulk, not per-frame: delete(0) shifts the whole array every frame
	// (O(n)) and dominates CPU on a busy bus. Let it overrun by 1/4, then slice
	// back to the cap — amortised O(1) per frame.
	if app.trace.len > max_trace + max_trace / 4 {
		app.trace = app.trace[app.trace.len - max_trace..].clone()
	}
	if gkey !in app.grouped {
		app.order << gkey
	}
	// Deep per-message plot history (independent of the 1000-frame display cap),
	// so the Graphics strip chart can fill a long window. Amortised trim like trace.
	mut hist := app.plot_hist[hist_key(f.id, f.extended)] or { []PlotSample{} }
	hist << PlotSample{
		t_s:  f32(t_ms / 1000.0)
		data: f.data.clone()
	}
	if hist.len > plot_history + plot_history / 4 {
		hist = hist[hist.len - plot_history..].clone()
	}
	app.plot_hist[hist_key(f.id, f.extended)] = hist
	app.grouped[gkey] = MsgAgg{
		id:      f.id
		ext:     f.extended
		ch:      ch
		dir:     dir
		last:    f.data.clone()
		count:   prev.count + 1
		last_ms: t_ms
		name:    name
		repeat:  !first && changed == 0 // unchanged vs the prior frame for this ID
	}
}

// spinner_view is a small toolbar spinner that rotates while a measurement runs.
// It's time-based (angle from the wall clock) and driven at ~30 fps by spin_loop,
// so a smooth spin means a healthy render loop and any jerk/jump is a GUI frame
// stutter. Frozen (faint ring) when stopped, so it costs nothing idle.
fn spinner_view(app &App) gui.View {
	sz := sc(18)
	r := sz / 2
	running := app.running
	// ~1 revolution/sec while running (phase in radians, 2π = 6.2831855).
	phase := if running { f32(f64(time.ticks() % 1000) / 1000.0) * 6.2831855 } else { f32(0) }
	col := if running { gui.rgb(0x2f, 0x86, 0xff) } else { gui.Color{150, 150, 155, 120} }
	return gui.draw_canvas(
		id:      'stutter_spin'
		version: if running { u64(time.ticks() / 16) } else { u64(0) } // re-tessellate each frame while spinning
		width:   sz
		height:  sz
		padding: gui.padding_none
		on_draw: fn [r, phase, col, running] (mut dc gui.DrawContext) {
			dc.circle(r, r, r - 2, gui.Color{120, 120, 128, 80}, 1.5) // faint track ring
			if running {
				dc.arc(r, r, r - 2, r - 2, phase, f32(4.712389), col, 2.5) // a 270° arc
			}
		}
	)
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
			// VS Code-style: the activity bar runs the full left edge (under the menu),
			// with the toolbar + dock stacked to its right.
			gui.row(
				sizing:  gui.fill_fill
				spacing: 4
				padding: gui.padding_none
				content: [
					activity_bar(app),
					gui.column(
						sizing:  gui.fill_fill
						spacing: 8
						padding: gui.padding_none
						content: [
							toolbar(mut window),
							gui.dock_layout(
				id:               'dock'
				root:             app.dock_root
				panels:           [
					gui.DockPanelDef{ id: 'trace', label: 'Trace', content: [trace_panel(mut window)] },
				gui.DockPanelDef{ id: 'ftrace', label: 'Trace (filter)', content: [filtered_trace_panel(mut window)] },
					gui.DockPanelDef{ id: 'buses', label: 'Buses', content: [buses_panel(app)] },
						gui.DockPanelDef{ id: 'simulation', label: 'Simulation', content: [simulation_panel(mut window)] },
					gui.DockPanelDef{ id: 'signals', label: 'Signals', content: [signals_panel(app)] },
					gui.DockPanelDef{ id: 'plot', label: 'Graphics', content: [plot_panel(mut window)] },
					gui.DockPanelDef{ id: 'send', label: 'Send', content: [send_panel(mut window)] },
				gui.DockPanelDef{ id: 'generators', label: 'Generators', content: [generators_panel(mut window)] },
				gui.DockPanelDef{ id: 'diag', label: 'Diagnostics', content: [diag_panel(mut window)] },
				gui.DockPanelDef{ id: 'doip', label: 'DoIP', content: [doip_panel(mut window)] },
				gui.DockPanelDef{ id: 'script', label: 'Script', content: [script_panel(mut window)] },
					gui.DockPanelDef{ id: 'stats', label: 'Statistics', content: [stats_panel(app)] },
						gui.DockPanelDef{ id: 'log', label: 'Log', content: [log_panel(mut window)] },
						gui.DockPanelDef{ id: 'symbols', label: 'Symbol Browser', content: [symbol_browser_panel(app)] },
						gui.DockPanelDef{ id: 'busconfig', label: 'Bus Config', content: [bus_config_panel(app)] },
					gui.DockPanelDef{ id: 'help', label: 'Help', content: [help_panel(mut window)] },
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
					),
				]
			),
		]
	)
}

// menu_bar is the top menubar. File covers projects + recordings + exit; the
// other menus are scaffolded for later (Phase 9). Project/Recording opens reuse
// the native picker (zenity on Linux) with the typed-path/log box as fallback.
fn menu_bar(mut window gui.Window) gui.View {
	app := window.state[App]()
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
							// Empty canvas — build it up in Bus Config (＋ Sim net / ＋ vcan
							// / Discover), attach DBCs in Buses, scaffold in Simulation, Save.
							a.proj = project.Project{
								name:    'untitled'
								version: project.schema_version
							}
							a.proj_source = 'new' // not a file yet → Save acts as Save As
							a.rt = []ChannelRT{}
							a.reset_diag_discovery()
							a.reset_plot()
							a.plot_hist = map[u64][]PlotSample{}
							a.load_databases()
							a.build_sim_nodes()
							set_window_title(a.proj.name)
							a.notify(.info, 'new project — add a network in Bus Config (＋ Sim net / ＋ vcan / Discover)')
							open_bus_config(mut w)
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
						id:   'file.examples'
						text: 'Open Example'
						submenu: [
							gui.MenuItemCfg{
								id:     'ex.sim'
								text:   'Simulation (2 networks, multi-ECU)'
								action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
									open_project('projects/sim-demo.yml', mut w)
								}
							},
							gui.MenuItemCfg{
								id:     'ex.replay'
								text:   'Replay (recorded log)'
								action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
									open_project('projects/replay-demo.yml', mut w)
								}
							},
							gui.MenuItemCfg{
								id:     'ex.udp'
								text:   'UDP software bus'
								action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
									open_project('projects/demo-udp.yml', mut w)
								}
							},
							gui.MenuItemCfg{
								id:     'ex.hw'
								text:   'Hardware (Kvaser + PCAN, same bus)'
								action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
									open_project('projects/hw-crossvendor.yml', mut w)
								}
							},
						]
					},
					gui.MenuItemCfg{
						id:     'file.adddbc'
						text:   'Add DBC(s)…'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							add_dbcs_menu(mut w)
						}
					},
					gui.MenuItemCfg{
						id:     'file.save'
						text:   'Save Project'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							do_save_project(mut w)
						}
					},
					gui.MenuItemCfg{
						id:     'file.saveas'
						text:   'Save Project As…'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							save_project_as(mut w)
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
						submenu: recent_submenu(app.recents)
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
			gui.MenuItemCfg{
				id:      'view'
				text:    'View'
				submenu: view_submenu(app)
			},
			gui.MenuItemCfg{
				id:   'help'
				text: 'Help'
				submenu: [
					gui.MenuItemCfg{
						id:     'help.quick'
						text:   'Quick Start'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							open_help('quickstart', mut w)
						}
					},
					gui.MenuItemCfg{
						id:     'help.examples'
						text:   'Examples'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							open_help('examples', mut w)
						}
					},
					gui.MenuItemCfg{
						id:     'help.about'
						text:   'About'
						action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
							open_help('about', mut w)
						}
					},
				]
			},
		]
	)
}

// view_panels lists every dock panel (id, label) for the View menu — its order
// is also the menu order. Must stay in sync with the dock_layout panels list.
const view_panels = [
	['trace', 'Trace'],
	['ftrace', 'Trace (filter)'],
	['buses', 'Buses'],
	['busconfig', 'Bus Config'],
	['simulation', 'Simulation'],
	['symbols', 'Symbol Browser'],
	['signals', 'Signals'],
	['plot', 'Graphics'],
	['send', 'Send'],
	['generators', 'Generators'],
	['diag', 'Diagnostics'],
	['doip', 'DoIP Discovery'],
	['script', 'Script'],
	['stats', 'Statistics'],
	['log', 'Log'],
	['help', 'Help'],
]

// dock_has_panel reports whether a panel id is currently placed somewhere in the
// dock tree (i.e. open). Used to tick the View menu and toggle show/hide.
fn dock_has_panel(root &gui.DockNode, pid string) bool {
	if _ := gui.dock_tree_find_group_by_panel(root, pid) {
		return true
	}
	return false
}

// ---- Help panel: in-app docs rendered from embedded markdown (self-contained exe) ----

// about_text builds the About page (version + links) at runtime.
fn about_text() string {
	return '# Blobly Net\n\n' +
		'A **conventional** automotive bus tester written in V (vlang). Virtual-first — it ' +
		'runs driver-free with a built-in simulation; real CAN hardware (Kvaser/PCAN) drops ' +
		'in behind the same bus abstraction.\n\n' +
		'Live trace + DBC decode · signal plots · Send / Generators · UDS diagnostics · ' +
		'MF4 / candump log replay · embedded **Lua** scripting.\n\n' +
		'- Repo: https://github.com/MartenH/blobly_net\n' +
		'- Issues: https://github.com/MartenH/blobly_net/issues\n' +
		'- Docs: the `docs/` folder — scripting.md, can_hardware.md, windows_build.md\n\n' +
		'Built with vlang/gui + vglyph.'
}

fn help_doc(page string) string {
	return match page {
		'examples' { help_examples }
		'about' { about_text() }
		else { help_quickstart }
	}
}

fn help_tab(page string, label string, current string) gui.View {
	on := page == current
	return gui.button(
		id_focus:     0
		h_align:      .center
		min_width:    sc(96)
		max_width:    sc(140)
		padding:      scpad(4, 10, 4, 10)
		color:        gui.Color{0, 0, 0, 0}
		color_border: gui.Color{0, 0, 0, 0}
		content:      [
			gui.text(text: label, text_style: if on { gui.theme().b3 } else { gui.theme().n3 }),
		]
		on_click:     fn [page] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
			mut a := w.state[App]()
			a.help_page = page
			w.update_window()
		}
	)
}

// help_panel renders the in-app documentation (embedded markdown) with page tabs.
// Driver-free, no internet — the docs ship inside the binary via $embed_file.
fn help_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	page := app.help_page
	return gui.column(
		sizing:  gui.fill_fill
		spacing: sc(6)
		padding: scpad(6, 8, 6, 8)
		content: [
			gui.row(
				spacing: sc(6)
				content: [
					help_tab('quickstart', 'Quick Start', page),
					help_tab('examples', 'Examples', page),
					help_tab('about', 'About', page),
				]
			),
			gui.column(
				id_scroll: 7400
				sizing:    gui.fill_fill
				content:   [
					window.markdown(id: 'help_md', source: help_doc(page)),
				]
			),
		]
	)
}

// help_link_handler intercepts markdown link clicks so the in-app Help never
// surprise-launches the OS browser. Real http(s):// URLs fall through (we leave
// `is_handled` unset, so gui opens them in the browser as expected); everything
// else (relative paths, bare doc names) is handled in-app: if it names a Help
// page we switch to it, otherwise we swallow it. (`#anchor` links are scrolled
// in-app by gui before the handler is even called.)
fn help_link_handler(url string, mut e gui.Event, mut w gui.Window) {
	if url.starts_with('http://') || url.starts_with('https://') {
		return // leave unhandled → gui opens a real external link in the browser
	}
	// internal/relative link: never spawn a browser. Map e.g. "examples",
	// "docs/examples.md", "examples.md" → the help page id.
	page := url.all_after_last('/').all_before('.').to_lower()
	if page in ['quickstart', 'examples', 'about'] {
		mut app := w.state[App]()
		app.help_page = page
		if !dock_has_panel(app.dock_root, 'help') {
			app.dock_root = gui.dock_tree_wrap_root(app.dock_root, 'help', .right)
		}
		w.update_window()
	}
	e.is_handled = true // swallow: internal/relative links do not reach the browser
}

// open_help shows the Help panel and switches to `page`.
fn open_help(page string, mut w gui.Window) {
	mut app := w.state[App]()
	app.help_page = page
	if !dock_has_panel(app.dock_root, 'help') {
		app.dock_root = gui.dock_tree_wrap_root(app.dock_root, 'help', .right)
	}
	w.update_window()
}

// toggle_panel shows/hides a dock panel by id (the activity bar + View menu both use it).
fn toggle_panel(pid string, mut w gui.Window) {
	mut app := w.state[App]()
	if dock_has_panel(app.dock_root, pid) {
		app.dock_root = gui.dock_tree_remove_panel(app.dock_root, pid)
	} else {
		app.dock_root = gui.dock_tree_wrap_root(app.dock_root, pid, .right)
	}
	w.update_window()
}

// activity_bar is the VS Code-style vertical icon strip on the far left: one toggle
// per dock panel (highlighted when open), each with a tooltip naming it.
fn activity_bar(app &App) gui.View {
	// Monochrome glyphs (NOT colour emoji) — they render in the text colour, so they
	// follow the theme and look identical across WSLg/Windows, like VS Code's icons.
	icons := {
		'trace':      '☰'
		'ftrace':     '▽'
		'buses':      '⊞'
		'busconfig':  '⊙'
		'simulation': '▷'
		'symbols':    '⌗'
		'signals':    '∿'
		'plot':       '▦'
		'send':       '➤'
		'generators': '⎍'
		'diag':       '✚'
		'doip':       '⊕'
		'script':     'ƒ'
		'stats':      'Σ'
		'log':        '▤'
		'help':       '?'
	}
	// Active = bright (theme text colour), inactive = dim — flat buttons, no boxes.
	icon_on := gui.TextStyle{
		...gui.theme().b2
		size: 19 * g_ui_scale
	}
	dim := if app.dark { gui.Color{150, 155, 165, 255} } else { gui.Color{150, 150, 155, 255} }
	icon_off := gui.TextStyle{
		...gui.theme().b2
		size:  19 * g_ui_scale
		color: dim
	}
	transparent := gui.Color{0, 0, 0, 0}
	hl := if app.dark { gui.Color{58, 66, 84, 255} } else { gui.Color{210, 224, 245, 255} }
	hover := if app.dark { gui.Color{46, 52, 66, 255} } else { gui.Color{228, 232, 240, 255} }
	mut items := []gui.View{}
	for p in view_panels {
		pid := p[0]
		label := p[1]
		shown := dock_has_panel(app.dock_root, pid)
		icon := icons[pid] or { '•' }
		items << gui.button(
			id_focus:     0
			min_width:    sc(40)
			max_width:    sc(40)
			h_align:      .center
			padding:      scpad(5, 8, 5, 8)
			color:        if shown { hl } else { transparent }
			color_border: transparent
			color_hover:  hover
			tooltip:      &gui.TooltipCfg{
				id:      'act_${pid}'
				content: [gui.text(text: '${if shown { 'Hide' } else { 'Show' }} ${label}')]
			}
			content:      [gui.text(text: icon, text_style: if shown { icon_on } else { icon_off })]
			on_click:     fn [pid] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				toggle_panel(pid, mut w)
			}
		)
	}
	return gui.column(
		sizing:  gui.fit_fill
		spacing: sc(4)
		padding: scpad(4, 5, 4, 5)
		content: items
	)
}

// view_submenu builds the View menu: one toggle per dock panel. A ✓ marks open
// panels; selecting one hides it (if open) or re-adds it at the right edge.
fn view_submenu(app &App) []gui.MenuItemCfg {
	mut items := []gui.MenuItemCfg{}
	for p in view_panels {
		pid := p[0]
		open := dock_has_panel(app.dock_root, pid)
		mark := if open { '✓ ' } else { '    ' }
		items << gui.MenuItemCfg{
			id:     'view.${pid}'
			text:   '${mark}${p[1]}'
			action: fn [pid] (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				if dock_has_panel(a.dock_root, pid) {
					a.dock_root = gui.dock_tree_remove_panel(a.dock_root, pid)
				} else {
					a.dock_root = gui.dock_tree_wrap_root(a.dock_root, pid, .right)
				}
			}
		}
	}
	return items
}

// cli_project_arg returns the first positional CLI argument that looks like a
// project file (a path ending in .yml/.yaml, or any existing file), so
// `blobly_net projects/ecu-vcm.yml` loads that project. Flags (leading '-') are
// skipped so sokol/gg options don't get mistaken for a path.
fn cli_project_arg() ?string {
	for a in os.args[1..] {
		if a.starts_with('-') {
			continue
		}
		if a.ends_with('.yml') || a.ends_with('.yaml') || os.is_file(a) {
			return a
		}
	}
	return none
}

// open_project loads a project file, rebuilds the runtime, and reloads DBCs.
fn open_project(path string, mut w gui.Window) {
	mut app := w.state[App]()
	if app.running {
		stop_measurement(mut w)
	}
	p := project.load(path) or {
		app.notify(.error, 'open project failed: ${err}')
		return
	}
	app.proj = p
	app.proj_source = path
	app.remember_project(path)
	app.rt = []ChannelRT{len: p.channels.len}
	app.reset_diag_discovery()
	app.reset_plot()
	app.plot_hist = map[u64][]PlotSample{} // old project's history is meaningless now
	app.load_databases()
	app.build_sim_nodes()
	set_window_title(p.name)
	note := p.version_note()
	app.notify(if note != '' { .warn } else { .info }, if note != '' {
		'loaded ${p.name} — ⚠ ${note}'
	} else {
		'loaded ${p.name} (${p.channels.len} ch) — press ▶ Start'
	})
	w.update_window()
}

// can_hw_id identifies the physical hardware behind a real CAN netdev by reading
// sysfs: the USB product + USB busid, e.g. "PCAN-USB Pro FD [1-2]". The busid GROUPS
// the channels of a multi-channel adapter (both PCAN channels share one busid; the
// canN name distinguishes them) and separates distinct adapters. Falls back to the
// driver (kvaser_usb→Kvaser, peak_usb→PEAK). '' for vcan / non-USB (no device dir).
fn can_hw_id(iface string) string {
	dev := '/sys/class/net/${iface}/device'
	if !os.exists(dev) {
		return ''
	}
	usbdir := os.dir(os.real_path(dev)) // …/1-2 (the USB device — has product, is the busid)
	busid := os.base(usbdir)
	product := (os.read_file('${usbdir}/product') or { '' }).trim_space()
	if product != '' {
		return '${product} [${busid}]'
	}
	drv := os.base(os.real_path('${dev}/driver'))
	vendor := match drv {
		'kvaser_usb' { 'Kvaser' }
		'peak_usb' { 'PEAK' }
		else { drv }
	}
	return '${vendor} [${busid}]'
}

// discover_to_candidates scans interfaces (transport.list_interfaces: real can/vcan
// netdevs with bitrate + virtual udp/inproc buses), enriches each with its live link
// state (from `ip -brief link show type can`: connected / no carrier / down), and
// fills the Bus Config candidate list. Real, not-yet-added interfaces are pre-ticked.
fn discover_to_candidates(mut w gui.Window) {
	mut app := w.state[App]()
	ifaces := transport.list_interfaces() or {
		app.notify(.error, 'discover failed: ${err}')
		return
	}
	mut linkstate := map[string]string{}
	lr := os.execute('ip -brief link show type can')
	if lr.exit_code == 0 {
		for line in lr.output.split_into_lines() {
			parts := line.fields()
			if parts.len >= 2 {
				linkstate[parts[0]] = if parts[1] != 'UP' {
					'down'
				} else if line.contains('LOWER_UP') {
					'connected'
				} else {
					'no carrier'
				}
			}
		}
	}
	mut have := map[string]bool{}
	for ch in app.proj.channels {
		have[ch.iface] = true
	}
	mut cands := []BusCandidate{}
	for f in ifaces {
		cands << BusCandidate{
			name:    f.name
			iface:   f.iface
			kind:    f.kind
			bitrate: f.bitrate
			virtual: f.virtual
			in_proj: f.iface in have
			state:   linkstate[f.iface] or { '' }
			hw:      if f.kind == 'can' { can_hw_id(f.iface) } else { '' }
		}
	}
	app.bus_candidates = cands
	for c in cands {
		if c.iface !in app.bus_names {
			app.bus_names[c.iface] = c.name // default; user can rename before Add
		}
		if !c.virtual && !c.in_proj {
			app.bus_ticked[c.iface] = true
		}
	}
	app.notify(.info, 'discovered ${cands.len} interface(s) — name + tick the ones to add, then ＋ Add')
}

// add_ticked_channels appends the ticked, not-already-present candidates as monitor
// channels and rebuilds the runtime (stops measurement first). In-memory only — the
// Buses panel updates live; persist with File ▸ Save.
fn add_ticked_channels(mut w gui.Window) {
	mut app := w.state[App]()
	if app.running {
		stop_measurement(mut w)
	}
	mut have := map[string]bool{}
	for ch in app.proj.channels {
		have[ch.iface] = true
	}
	mut added := 0
	for c in app.bus_candidates {
		if !(app.bus_ticked[c.iface] or { false }) || c.iface in have {
			continue
		}
		chname := app.bus_names[c.iface] or { c.name }
		app.proj.channels << project.Channel{
			name:    if chname.trim_space() != '' { chname.trim_space() } else { c.name }
			typ:     'can'
			iface:   c.iface
			bitrate: if c.bitrate > 0 { c.bitrate } else { 500000 }
			mode:    .monitor
			enabled: true
		}
		have[c.iface] = true
		added++
	}
	app.rt = []ChannelRT{len: app.proj.channels.len}
	app.load_databases()
	app.build_sim_nodes()
	app.notify(.info, 'added ${added} channel(s) — review in Buses, then File ▸ Save')
	w.update_window()
}

// create_vcan adds + brings up the next free virtual CAN netdev (vcan0, vcan1, …)
// via `sudo -n ip link` (scoped passwordless sudo is configured for `ip`), then
// re-scans so it appears as a candidate. Driver-free extra buses with no hardware.
fn create_vcan(mut w gui.Window) {
	mut app := w.state[App]()
	mut n := 0
	for n < 64 && os.exists('/sys/class/net/vcan${n}') {
		n++
	}
	iface := 'vcan${n}'
	add := os.execute('sudo -n ip link add dev ${iface} type vcan')
	if add.exit_code != 0 {
		app.notify(.error, 'create ${iface} failed — need passwordless sudo for ip (scripts/setup_sudoers.sh): ${add.output.trim_space()}')
		return
	}
	os.execute('sudo -n ip link set up ${iface}')
	discover_to_candidates(mut w)
	app.notify(.info, 'created ${iface} — tick it + ＋ Add to use it')
	w.update_window()
}

// add_sim_network offers a NEW in-process simulated network as a candidate (a unique
// inproc:SIM<N> bus, editable name, pre-ticked) — the simulated-network twin of ＋ vcan.
// Unlike vcan, an inproc bus is not a system object (no ip link); it exists as soon as
// a channel opens it, so this just mints a uniquely-named one to rename + Add.
fn add_sim_network(mut w gui.Window) {
	mut app := w.state[App]()
	mut used := map[string]bool{}
	for ch in app.proj.channels {
		used[ch.iface] = true
	}
	for c in app.bus_candidates {
		used[c.iface] = true
	}
	mut n := 1
	for {
		if 'inproc:SIM${n}' !in used {
			break
		}
		n++
	}
	iface := 'inproc:SIM${n}'
	app.bus_candidates << BusCandidate{
		name:    'SIM${n}'
		iface:   iface
		kind:    'inproc'
		virtual: true
	}
	app.bus_names[iface] = 'SIM${n}'
	app.bus_ticked[iface] = true
	app.notify(.info, 'new simulated network ${iface} — rename it, then ＋ Add ticked')
	w.update_window()
}

// open_bus_config ensures the Bus Config panel is docked, then scans (the Buses
// '🔍 Discover' button). gui has no custom-content modal, so it's a dock panel
// (float it by dragging its tab if you want a window).
fn open_bus_config(mut w gui.Window) {
	mut app := w.state[App]()
	if !dock_has_panel(app.dock_root, 'busconfig') {
		app.dock_root = gui.dock_tree_wrap_root(app.dock_root, 'busconfig', .right)
	}
	discover_to_candidates(mut w)
	w.update_window()
}

// save_project_to writes the in-memory project to `path` (the inverse of load —
// project.to_yaml emits the `simulation:` schema) and adopts it as the source.
fn save_project_to(path string, mut w gui.Window) {
	mut app := w.state[App]()
	app.proj.save(path) or {
		app.notify(.error, 'save failed: ${err}')
		return
	}
	app.proj_source = path
	app.remember_project(path)
	set_window_title(app.proj.name)
	app.notify(.info, 'saved ${app.proj.name} → ${path}')
	w.update_window()
}

// save_project_as prompts for a path (native save dialog) then writes.
fn save_project_as(mut w gui.Window) {
	app := w.state[App]()
	dn := if app.proj_source.ends_with('.yml') || app.proj_source.ends_with('.yaml') {
		os.base(app.proj_source)
	} else {
		'project.yml'
	}
	w.native_save_dialog(
		title:             'Save Project As'
		default_name:      dn
		default_extension: 'yml'
		filters:           [gui.NativeFileFilter{
			name:       'Projects'
			extensions: ['yml', 'yaml']
		}]
		on_done:           fn (r gui.NativeDialogResult, mut w gui.Window) {
			if r.status == .ok && r.paths.len > 0 {
				save_project_to(r.path_strings()[0], mut w)
			}
		}
	)
}

// do_save_project saves to the current file if there is one, else asks where (the
// project was the built-in default / never saved).
fn do_save_project(mut w gui.Window) {
	app := w.state[App]()
	src := app.proj_source
	if src.ends_with('.yml') || src.ends_with('.yaml') {
		save_project_to(src, mut w)
	} else {
		save_project_as(mut w)
	}
}

// set_window_title updates the OS titlebar to show the open project (sapp is valid
// inside on_init / once running). In-app the Buses panel header + Stats also show it.
fn set_window_title(project_name string) {
	title := 'Blobly Net — ${project_name}'
	C.sapp_set_window_title(&char(title.str))
}

// add_dbcs_menu (File ▸ Add DBC(s)…) multi-selects .dbc files and attaches each to the
// channel whose name its file name matches (CAN01-postfix.dbc → channel "CAN01"); a DBC
// with no matching bus auto-creates one from its name (so it works on an empty project
// too). Use the Buses panel ＋ DBC to target one specific bus.
fn add_dbcs_menu(mut w gui.Window) {
	w.native_open_dialog(
		title:          'Add DBC(s) — auto-routed to matching channels'
		allow_multiple: true
		filters:        [gui.NativeFileFilter{
			name:       'DBC databases'
			extensions: ['dbc']
		}]
		on_done: fn (r gui.NativeDialogResult, mut w gui.Window) {
			if r.status == .ok && r.paths.len > 0 {
				attach_dbcs_routed(r.path_strings(), mut w)
			}
		}
	)
}

// bus_key extracts a normalized (letters, has-number, number) bus token from the start
// of a name: "CAN01" → ('can', true, 1), "CAN1" → ('can', true, 1), "IPC04-postfix" →
// ('ipc', true, 4), "Powertrain" → ('powertrain', false, 0). Comparing the number as an
// int makes zero-padding irrelevant, so a "CAN01-…" DBC matches a "CAN1" channel.
fn bus_key(s string) (string, bool, int) {
	mut i := 0
	mut alpha := ''
	for i < s.len {
		c := s[i]
		if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) {
			alpha += c.ascii_str()
			i++
		} else {
			break
		}
	}
	mut numstr := ''
	for i < s.len && s[i] >= `0` && s[i] <= `9` {
		numstr += s[i].ascii_str()
		i++
	}
	return alpha.to_lower(), numstr.len > 0, if numstr.len > 0 { numstr.int() } else { 0 }
}

// channel_for_dbc returns the index of the channel whose bus token matches the DBC file
// name's (e.g. CAN01-postfix.dbc → channel "CAN1" or "CAN01"; IPC04-*.dbc → "IPC04").
// Matching is on (letters, number) so zero-padding and case don't matter. none = no match.
fn (app &App) channel_for_dbc(path string) ?int {
	stem := os.base(path).all_before_last('.')
	sa, sh, sn := bus_key(stem)
	if sa == '' {
		return none
	}
	for i, ch in app.proj.channels {
		ca, chh, cn := bus_key(ch.name)
		if ca == sa && chh == sh && cn == sn {
			return i
		}
	}
	return none
}

// dbc_bus_name derives a channel name from a DBC file name: the leading
// alphanumeric run of the stem (CAN01-postfix.dbc → "CAN01"; Powertrain.dbc →
// "Powertrain"). Used to name an auto-created bus.
fn dbc_bus_name(path string) string {
	stem := os.base(path).all_before_last('.')
	mut i := 0
	for i < stem.len {
		c := stem[i]
		if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) {
			i++
		} else {
			break
		}
	}
	name := stem[..i]
	return if name == '' { stem } else { name }
}

// attach_dbcs_routed attaches each picked DBC to the channel whose name matches the
// file name (channel_for_dbc). A DBC with NO matching channel gets a new inproc bus
// created from its name — so Add DBC(s)… works on an empty project, and an unmatched
// DBC becomes its own bus instead of landing on an arbitrary one. Channels created
// earlier in the same call are matchable by later DBCs (so CAN01-a.dbc + CAN01-b.dbc
// share one bus). One reload for the lot; in-memory only, persists on File ▸ Save.
fn attach_dbcs_routed(paths []string, mut w gui.Window) {
	mut app := w.state[App]()
	if paths.len == 0 {
		return
	}
	mut routed := 0
	mut created := 0
	for p in paths {
		if idx := app.channel_for_dbc(p) {
			app.proj.channels[idx].databases << p
			routed++
			continue
		}
		name := dbc_bus_name(p)
		app.proj.channels << project.Channel{
			name:      name
			typ:       'can'
			iface:     'inproc:${name}'
			mode:      .monitor
			enabled:   true
			databases: [p]
		}
		created++
	}
	// Grow the parallel runtime array for any new channels (preserve existing).
	for app.rt.len < app.proj.channels.len {
		app.rt << ChannelRT{}
	}
	app.load_databases()
	app.build_sim_nodes()
	app.notify(.info, if created > 0 {
		'added ${paths.len} DBC(s): ${routed} matched, ${created} new bus(es) created (Save to persist)'
	} else {
		'added ${paths.len} DBC(s): ${routed} routed by name to existing buses (Save to persist)'
	})
	w.update_window()
}

// pick_dbc opens a native file picker (multi-select) and attaches the chosen .dbc
// file(s) to channel ch_idx.
fn pick_dbc(ch_idx int, mut w gui.Window) {
	w.native_open_dialog(
		title:          'Attach DBC(s) to channel'
		allow_multiple: true
		filters:        [gui.NativeFileFilter{
			name:       'DBC databases'
			extensions: ['dbc']
		}]
		on_done: fn [ch_idx] (r gui.NativeDialogResult, mut w gui.Window) {
			if r.status == .ok && r.paths.len > 0 {
				attach_dbcs(ch_idx, r.path_strings(), mut w)
			}
		}
	)
}

// attach_dbcs adds one or more DBC paths to a channel and reloads — so decode AND the
// Simulation panel's node list (build_sim_nodes skips channels with no DBC) come alive.
// In-memory only; persists on File ▸ Save.
fn attach_dbcs(ch_idx int, paths []string, mut w gui.Window) {
	mut app := w.state[App]()
	if ch_idx < 0 || ch_idx >= app.proj.channels.len || paths.len == 0 {
		return
	}
	for p in paths {
		app.proj.channels[ch_idx].databases << p
	}
	app.load_databases()
	app.build_sim_nodes()
	names := paths.map(os.base(it)).join(', ')
	app.notify(.info, 'attached ${names} to ${app.proj.channels[ch_idx].name} (session-only until Save)')
	w.update_window()
}

// remove_channel deletes a bus from the project (stops measurement first, then
// rebuilds the runtime). In-memory; persists on Save.
fn remove_channel(ch_idx int, mut w gui.Window) {
	mut app := w.state[App]()
	if app.running {
		stop_measurement(mut w)
	}
	if ch_idx < 0 || ch_idx >= app.proj.channels.len {
		return
	}
	name := app.proj.channels[ch_idx].name
	app.proj.channels.delete(ch_idx)
	app.rt = []ChannelRT{len: app.proj.channels.len}
	app.load_databases()
	app.build_sim_nodes()
	app.notify(.info, 'removed ${name} — Save to persist')
	w.update_window()
}

// clear_dbc removes all DBCs from a channel and reloads.
fn clear_dbc(ch_idx int, mut w gui.Window) {
	mut app := w.state[App]()
	if ch_idx < 0 || ch_idx >= app.proj.channels.len {
		return
	}
	app.proj.channels[ch_idx].databases = []string{}
	app.load_databases()
	app.build_sim_nodes()
	app.notify(.info, 'cleared DBCs on ${app.proj.channels[ch_idx].name}')
	w.update_window()
}

// usbipd_exe finds the Windows usbipd-win binary (WSL can run it via interop).
fn usbipd_exe() ?string {
	p := '/mnt/c/Program Files/usbipd-win/usbipd.exe'
	return if os.exists(p) { p } else { none }
}

// usb_attach_can attaches every BOUND-but-not-attached CAN adapter (Kvaser 0bfd /
// PEAK 0c72) into WSL via usbipd, so its can0/… netdev appears for Discover. The
// one-time `usbipd bind` still needs an elevated Windows shell; attach does not.
fn usb_attach_can(mut w gui.Window) {
	mut app := w.state[App]()
	usbipd := usbipd_exe() or {
		app.notify(.error, 'usbipd.exe not found — install usbipd-win on Windows')
		return
	}
	res := os.execute('"${usbipd}" list')
	if res.exit_code != 0 {
		app.notify(.error, 'usbipd list failed (is usbipd-win installed?)')
		return
	}
	mut attached := 0
	mut seen := 0
	for line in res.output.split_into_lines() {
		low := line.to_lower()
		is_can := low.contains('0bfd:') || low.contains('0c72:') || low.contains('kvaser')
			|| low.contains('peak')
		if !is_can {
			continue
		}
		seen++
		if low.contains('attached') {
			continue
		}
		busid := line.trim_space().all_before(' ')
		if busid.len == 0 {
			continue
		}
		if os.execute('"${usbipd}" attach --wsl --busid ${busid}').exit_code == 0 {
			attached++
		}
	}
	app.notify(if attached > 0 || seen > 0 { .info } else { .warn }, if attached > 0 {
		'attached ${attached} CAN adapter(s) — press 🔍 Discover'
	} else if seen > 0 {
		'CAN adapter(s) already attached — press 🔍 Discover'
	} else {
		'no CAN adapters found (run `usbipd bind` elevated on Windows first)'
	})
	w.update_window()
}

const max_recents = 8

// recents_path is the per-user file that stores recently opened projects,
// one path per line, in the OS config dir (%APPDATA%\blobly_net on Windows,
// ~/.config/blobly_net on Linux). It is user state, not part of the repo.
fn recents_path() string {
	cfg := os.config_dir() or { return '' }
	return os.join_path(cfg, 'blobly_net', 'recent_projects.txt')
}

// load_recents reads the recents file, dropping blanks, duplicates, and paths
// that no longer exist on disk.
fn load_recents() []string {
	p := recents_path()
	if p == '' || !os.exists(p) {
		return []string{}
	}
	content := os.read_file(p) or { return []string{} }
	mut out := []string{}
	for line in content.split_into_lines() {
		s := line.trim_space()
		if s != '' && os.exists(s) && s !in out {
			out << s
		}
	}
	return out
}

fn save_recents(recents []string) {
	p := recents_path()
	if p == '' {
		return
	}
	dir := os.dir(p)
	if !os.exists(dir) {
		os.mkdir_all(dir) or { return }
	}
	os.write_file(p, recents.join('\n')) or {}
}

// remember_project moves path to the front of the recents list (absolute,
// deduped, capped at max_recents) and persists it.
fn (mut app App) remember_project(path string) {
	abs := os.abs_path(path)
	mut r := [abs]
	for x in app.recents {
		if x != abs && r.len < max_recents {
			r << x
		}
	}
	app.recents = r
	save_recents(r)
}

// recent_submenu builds the File ▸ Open Recent items from the recents list.
fn recent_submenu(recents []string) []gui.MenuItemCfg {
	if recents.len == 0 {
		return [
			gui.MenuItemCfg{
				id:     'file.recent.none'
				text:   '(none yet)'
				action: fn (_ &gui.MenuItemCfg, mut _ gui.Event, mut _ gui.Window) {}
			},
		]
	}
	mut items := []gui.MenuItemCfg{}
	for i, path in recents {
		p := path // capture per-item for the closure
		items << gui.MenuItemCfg{
			id:     'file.recent.${i}'
			text:   recent_label(p)
			action: fn [p] (_ &gui.MenuItemCfg, mut _ gui.Event, mut w gui.Window) {
				open_project(p, mut w)
			}
		}
	}
	return items
}

// recent_label shows the file name plus its parent dir for disambiguation,
// e.g. .../projects/demo-udp.yml -> "demo-udp.yml — projects".
fn recent_label(path string) string {
	base := os.base(path)
	parent := os.base(os.dir(path))
	return if parent == '' || parent == '.' { base } else { '${base} — ${parent}' }
}

fn toolbar(mut window gui.Window) gui.View {
	app := window.state[App]()
	dot := if app.running { '🟢' } else { '🔴' } // red ring when stopped
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
			gui.text(text: '${dot} ${app.status}', text_style: gui.theme().n4),
			spinner_view(app),
			gui.text(text: 'RX ${app.rx_count}  TX ${app.tx_count}', text_style: gui.theme().n4),
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
					a.grouped = map[string]MsgAgg{}
					a.order = []string{}
					a.expanded = map[string]bool{}
					a.expanded2 = map[string]bool{}
					a.plot_hist = map[u64][]PlotSample{}
					a.reset_plot() // also drop the graph watch list (was left dangling over cleared history)
					a.sel_id = -1
				}
			),
			gui.button(
				id_focus: 105
				content:  [gui.text(text: if app.recording { '⏹ Recording (${app.record_entries.len})' } else { '⏺ Record' })]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					toggle_record(mut w)
				}
			),
			gui.button(
				id_focus: 106
				content:  [gui.text(text: if app.dark { '☀ Light' } else { '🌙 Dark' })]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.dark = !a.dark
					// set_theme also re-applies titlebar_dark; safe here since the
					// app is running (sapp is valid), unlike the startup call.
					w.set_theme(make_theme(if a.dark { palette_dark } else { palette_opus }))
				}
			),
			gui.text(text: 'scale', text_style: gui.theme().n4),
			window.select(
				id:        'uiscale'
				id_focus:  107
				select:    [ui_scale_label()]
				options:   ui_scale_options
				min_width: sc(76)
				max_width: sc(92)
				on_select: fn (sel []string, mut _ gui.Event, mut w gui.Window) {
					if sel.len == 0 {
						return
					}
					// DPI workaround: re-scale the whole UI live by rebuilding the
					// theme (same path as the dark/light toggle — sapp is valid here).
					old := g_ui_scale
					g_ui_scale = clamp_scale(sel[0].trim_right('%').f32() / 100)
					a := w.state[App]()
					w.set_theme(make_theme(if a.dark { palette_dark } else { palette_opus }))
					// Grow/shrink the window by the same ratio so content density
					// stays constant (startup already sizes the window × scale). The
					// ratio (not scale×base) respects any manual user resize.
					if old > 0 && g_ui_scale != old {
						cw, ch := w.window_size()
						ratio := g_ui_scale / old
						w.resize(int(f32(cw) * ratio), int(f32(ch) * ratio))
					}
				}
			),
			gui.text(text: 'screen', text_style: gui.theme().n4),
			window.select(
				id:        'fps'
				id_focus:  105
				select:    ['${app.fps} fps']
				options:   fps_options
				min_width: sc(76)
				max_width: sc(92)
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
				width:           sc(220)
				height:          sc(26)
				padding:         scpad(4, 8, 4, 8)
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
										a.notify(.warn, 'no file picker (install zenity) — type a log path + Enter')
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

// trace_panel is the main Trace; filtered_trace_panel is the second,
// independently-filtered view of the same data ("Trace (filter)" tab). Both
// render through trace_view, parameterized by `which` (0 = main, 1 = filtered):
// own filter string, own selection, own grid/focus ids — shared trace buffer,
// expand state and Signals-panel follow.
fn trace_panel(mut window gui.Window) gui.View {
	return trace_view(mut window, 0)
}

fn filtered_trace_panel(mut window gui.Window) gui.View {
	return trace_view(mut window, 1)
}

fn trace_view(mut window gui.Window, which int) gui.View {
	app := window.state[App]()
	grouped := if which == 0 { app.mode == 'grouped' } else { app.mode2 == 'grouped' }
	filter := if which == 0 { app.trace_filter } else { app.trace_filter2 }
	sel := if which == 0 { app.selection } else { app.selection2 }
	gid := if which == 0 { 'trace' } else { 'ftrace' }

	mut rows := []gui.GridRow{}
	if grouped {
		for gkey in app.order {
			a := app.grouped[gkey] or { continue }
			if !trace_pass(app, which, filter, a.id, hexid(a.id, a.ext), a.name, a.ch) {
				continue
			}
			expanded := if which == 0 { gkey in app.expanded } else { gkey in app.expanded2 }
			chevron := if expanded { '▼' } else { '▶' }
			rows << gui.GridRow{
				id:    gkey
				cells: {
					'time':  '${a.last_ms / 1000.0:.6f}'
					'ch':    a.ch
					'id':    '${chevron} ${hexid(a.id, a.ext)}'
					'name':  a.name
					'dlc':   '${a.last.len}'
					'dir':   a.dir
					'data':  hex_crop(a.last, trace_data_max_bytes)
					'count': '${a.count}'
				}
			}
			if expanded {
				if m := app.db.lookup_frame(a.id, a.ext) {
					for s in m.active_signals(a.last) {
						raw := s.raw_value(a.last)
						label := s.label(a.last)
						value := if label != '' {
							'${s.physical(a.last):.2f} ${s.unit} (${label})'
						} else {
							'${s.physical(a.last):.2f} ${s.unit}'
						}
						rows << gui.GridRow{
							id:    's:${gkey}:${s.name}'
							cells: {
								'id':   '       ${s.name}'
								'name': value
								'dlc':  '0x${raw:X}'
							}
						}
					}
				}
			}
		}
		grouped_grid := window.data_grid(
			id:                  '${gid}_grouped'
			sizing:              gui.fill_fill
			scrollbar:           .visible
			row_height:          trace_row_height * g_ui_scale
			header_height:       trace_header_height * g_ui_scale
			text_style:          trace_text_style()
			text_style_header:   trace_text_style()
			columns:             [
				tcol('time', 'Time(s)', 80, .end),
				tcol('ch', 'Ch', 44, .start),
				tcol('count', 'Count', 56, .end),
				tcol('id', 'ID', 110, .start),
				tcol('name', 'Name', 130, .start),
				tcol('dlc', 'DLC', 44, .end),
				tcol('dir', 'Dir', 44, .start),
				tcol('data', 'Data', 320, .start),
			]
			rows:                rows
			selection:           sel
			multi_select:        true
			range_select:        true
			on_selection_change: fn [which] (selection gui.GridSelection, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				if which == 0 {
					a.selection = selection
				} else {
					a.selection2 = selection
				}
				rid := selection.active_row_id // the group key 'id|ch|dir'
				if rid.len > 0 && !rid.starts_with('s:') {
					a.sel_id = i64(rid.all_before('|').u32()) // message id from the group key
					// Single click = select (for multi-select + add-to-filter);
					// a second click on the same row within 400 ms = expand toggle.
					// Expand state is keyed by the GROUP key so each bus/dir row toggles
					// independently.
					now := time.ticks()
					if rid == a.last_click_id && now - a.last_click_ms < 400 {
						if which == 0 {
							if rid in a.expanded {
								a.expanded.delete(rid)
							} else {
								a.expanded[rid] = true
							}
						} else {
							if rid in a.expanded2 {
								a.expanded2.delete(rid)
							} else {
								a.expanded2[rid] = true
							}
						}
						a.last_click_id = '' // consume, so a 3rd click isn't a double
					} else {
						a.last_click_id = rid
						a.last_click_ms = now
					}
				}
			}
			on_cell_format:      trace_cell_format
		)
		return gui.column(
			sizing:  gui.fill_fill
			spacing: 2
			padding: gui.padding_none
			content: [trace_filter_row(app, which), grouped_grid]
		)
	}
	// Newest first: the latest frame sits at the top, so a live trace "follows"
	// without any scroll math; scroll down to review the retained history.
	for i := app.trace.len - 1; i >= 0; i-- {
		r := app.trace[i]
		if !trace_pass(app, which, filter, r.id, hexid(r.id, r.ext), r.name, r.ch, hex(r.data)) {
			continue
		}
		rows << gui.GridRow{
			id:    '${r.seq}:${r.id}' // seq keeps it unique; id lets selection drive Signals
			cells: {
				'time': '${r.t_ms / 1000.0:.6f}'
				'ch':   r.ch
				'id':   hexid(r.id, r.ext)
				'name': r.name
				'dlc':  '${r.dlc}'
				'dir':  r.dir
				'data': hex_crop(r.data, trace_data_max_bytes)
			}
		}
	}
	all_grid := window.data_grid(
		id:             '${gid}_all'
		sizing:         gui.fill_fill
		scrollbar:      .visible
		row_height:     trace_row_height * g_ui_scale
		header_height:  trace_header_height * g_ui_scale
		text_style:     trace_text_style()
		text_style_header: trace_text_style()
		columns:        [
			tcol('time', 'Time(s)', 80, .end),
			tcol('ch', 'Ch', 44, .start),
			tcol('id', 'ID', 110, .start),
			tcol('name', 'Name', 130, .start),
			tcol('dlc', 'DLC', 44, .end),
			tcol('dir', 'Dir', 44, .start),
			tcol('data', 'Data', 320, .start),
		]
		rows:                rows
		selection:           sel
		multi_select:        true
		range_select:        true
		on_selection_change: fn [which] (selection gui.GridSelection, mut _ gui.Event, mut w gui.Window) {
			mut a := w.state[App]()
			if which == 0 {
				a.selection = selection
			} else {
				a.selection2 = selection
			}
			parts := selection.active_row_id.split(':')
			if parts.len == 2 {
				a.sel_id = i64(parts[1].u32()) // Signals follows the clicked frame's ID
			}
		}
		on_cell_format:      trace_cell_format
	)
	return gui.column(
		sizing:  gui.fill_fill
		spacing: 2
		padding: gui.padding_none
		content: [trace_filter_row(app, which), all_grid]
	)
}

// selected_msg_ids returns the unique message IDs in a grid selection. Grouped
// rows are '<id>', chronological rows '<seq>:<id>'; signal sub-rows ('s:…') are
// skipped. Falls back to the active row when nothing is multi-selected.
fn selected_msg_ids(sel gui.GridSelection) []u32 {
	mut out := []u32{}
	mut rids := []string{}
	for rid, on in sel.selected_row_ids {
		if on {
			rids << rid
		}
	}
	if rids.len == 0 && sel.active_row_id.len > 0 {
		rids << sel.active_row_id
	}
	for rid in rids {
		if rid.starts_with('s:') {
			continue
		}
		// grouped row = 'id|ch|dir', chronological = 'seq:id', signal sub = 's:…' (skipped)
		idstr := if rid.contains('|') {
			rid.all_before('|')
		} else if rid.contains(':') {
			rid.all_after_last(':')
		} else {
			rid
		}
		if idstr.len == 0 {
			continue
		}
		mid := idstr.u32()
		if mid !in out {
			out << mid
		}
	}
	return out
}

// trace_filter_row is the filter input above a trace grid: a case-insensitive
// substring matched against each row's ID / name / channel / data. Each trace
// panel (`which`) edits its own filter string and gets its own focus ids.
fn trace_filter_row(app &App, which int) gui.View {
	filter := if which == 0 { app.trace_filter } else { app.trace_filter2 }
	mode := if which == 0 { app.mode } else { app.mode2 }
	mut content := [
		gui.View(gui.button(
			id_focus:  u32(36 + which) // per-panel grouped/all toggle
			max_width: sc(92)
			content:   [gui.text(text: 'View: ${mode}')]
			padding:   scpad(2, 6, 2, 6)
			on_click:  fn [which] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				if which == 0 {
					a.mode = if a.mode == 'grouped' { 'all' } else { 'grouped' }
				} else {
					a.mode2 = if a.mode2 == 'grouped' { 'all' } else { 'grouped' }
				}
			}
		)),
		gui.text(text: 'Filter', text_style: gui.theme().n4),
		gui.input(
			id_focus:        u32(30 + which * 2)
			text:            filter
			width:           sc(260)
			height:          sc(22)
			padding:         scpad(2, 6, 2, 6)
			sizing:          gui.fixed_fixed
			placeholder:     if which == 0 {
				'id / name / ch / data — e.g. 0x100, Wheel, CAN2, FF'
			} else {
				'select a message in Trace, press ＋ (or type a filter)'
			}
			on_text_changed: fn [which] (_ &gui.Layout, s string, mut w gui.Window) {
				mut a := w.state[App]()
				if which == 0 {
					a.trace_filter = s
				} else {
					a.trace_filter2 = s
				}
			}
		),
	]
	if filter.len > 0 {
		content << gui.button(
			id_focus:  u32(31 + which * 2)
			max_width: sc(30)
			content:   [gui.text(text: '✕', text_style: trace_text_style())]
			padding:   scpad(2, 6, 2, 6)
			on_click:  fn [which] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				if which == 0 {
					a.trace_filter = ''
				} else {
					a.trace_filter2 = ''
				}
			}
		)
	}
	if which == 0 {
		// ＋ Add to filter: push every message ID selected in the Trace (ctrl/shift-
		// click for several) into the watch set, so they appear in Trace (filter).
		mids := selected_msg_ids(app.selection)
		if mids.len > 0 {
			content << gui.button(
				id_focus:  34
				max_width: sc(96)
				content:   [gui.text(text: '＋ filter (${mids.len})', text_style: trace_text_style())]
				padding:   scpad(2, 6, 2, 6)
				on_click:  fn [mids] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					for mid in mids {
						a.watch[mid] = true
					}
				}
			)
		}
	}
	if which == 1 {
		// − filter: remove every selected message from the watch list (mirror of the
		// Trace's ＋). Operates on this panel's own selection.
		rmids := selected_msg_ids(app.selection2).filter(app.watch[it])
		if rmids.len > 0 {
			content << gui.button(
				id_focus:  35
				max_width: sc(100)
				content:   [gui.text(text: '− filter (${rmids.len})', text_style: trace_text_style())]
				padding:   scpad(2, 6, 2, 6)
				on_click:  fn [rmids] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					for mid in rmids {
						a.watch.delete(mid)
					}
				}
			)
		}
		// Watch-list chips: each watched ID (added from the Trace's ＋) is a chip —
		// click its ✕ to drop it again.
		mut ids := app.watch.keys()
		ids.sort()
		for k, wid in ids {
			content << gui.button(
				id_focus:  u32(500 + k) // 500+ = watch chips (see id ranges note)
				max_width: sc(72)
				content:   [
					gui.text(
						text:       '${hexid(wid, wid > 0x7ff)} ✕'
						text_style: trace_text_style()
					),
				]
				padding:   scpad(2, 6, 2, 6)
				on_click:  fn [wid] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.watch.delete(wid)
				}
			)
		}
	}
	return gui.row(
		v_align: .middle
		spacing: 6
		padding: scpad(2, 4, 4, 4)
		content: content
	)
}

// hist_key keys plot_hist by frame id AND format, so a standard and an extended
// frame that share a numeric id keep separate sample histories (else their payloads
// mix and a signal decodes the wrong frame's bytes).
fn hist_key(id u32, ext bool) u64 {
	return if ext { u64(id) | (u64(1) << 32) } else { u64(id) }
}

// pin_key is the canonical Graphics key (watch dedup / plot_off / plot_range) for a
// signal. It includes the frame format (ext) so a standard and an extended frame
// that share a numeric id AND signal name don't collide into one plot entry.
fn pin_key(id u32, ext bool, signal string) string {
	return '${id}:${if ext { 'x' } else { 's' }}:${signal}'
}

// is_pinned reports whether (id, ext, signal) is pinned to the Graphics plot.
fn (app &App) is_pinned(id u32, ext bool, signal string) bool {
	return app.plot_watch.any(it.id == id && it.ext == ext && it.signal == signal)
}

// toggle_pin adds/removes a signal to/from the Graphics plot's cross-frame watch
// list (so signals from several messages can be plotted together). On removal it
// also drops the signal's stale expand-only Y-range so a later re-add auto-fits.
fn (mut app App) toggle_pin(id u32, ext bool, signal string) {
	defer {
		app.plot_sig = '' // force the decode block to re-run (set changed; re-fills ranges)
	}
	for i, p in app.plot_watch {
		if p.id == id && p.ext == ext && p.signal == signal {
			app.plot_watch.delete(i)
			k := pin_key(id, ext, signal)
			app.plot_range.delete(k) // stale expand-only Y-range
			app.plot_off.delete(k) // stale hide-state (else a re-add looks pinned but stays hidden)
			return
		}
	}
	app.plot_watch << PlotPin{
		id:     id
		ext:    ext
		signal: signal
	}
}

// add_pins adds every named signal of a frame to the graph (skipping any already on).
fn (mut app App) add_pins(id u32, ext bool, names []string) {
	defer {
		app.plot_sig = ''
	}
	for n in names {
		if !app.is_pinned(id, ext, n) {
			app.plot_watch << PlotPin{
				id:     id
				ext:    ext
				signal: n
			}
		}
	}
}

// drop_frame_pins removes all of a frame's signals from the graph (+ their Y-ranges).
fn (mut app App) drop_frame_pins(id u32, ext bool) {
	for p in app.plot_watch {
		if p.id == id && p.ext == ext {
			k := pin_key(id, ext, p.signal)
			app.plot_range.delete(k)
			app.plot_off.delete(k)
		}
	}
	app.plot_watch = app.plot_watch.filter(it.id != id || it.ext != ext)
	app.plot_sig = '' // force re-decode (set changed; re-fills ranges for remaining pins)
}

// signals_panel decodes the message currently selected in the Trace (any ID),
// live. Click a row in either trace view to inspect its signals here. Each signal
// has a pin (＋/📌) that adds it to the Graphics plot — so you can build a plot
// from signals across multiple frames, not just the selected one.
fn signals_panel(app &App) gui.View {
	mut lines := []gui.View{}
	if app.sel_id < 0 {
		lines << gui.text(text: 'Signals', text_style: gui.theme().b3)
		lines << gui.text(text: '(click a message in the Trace)', text_style: gui.theme().n4)
		return gui.column(sizing: gui.fill_fill, padding: gui.padding_medium, spacing: 5, content: lines)
	}
	id := u32(app.sel_id)
	agg := app.latest_for(id) // latest across any bus/dir
	msg := app.db.lookup_frame(id, agg.ext) or {
		lines << gui.text(text: 'Signals — ${hexid(id, agg.ext)}', text_style: gui.theme().b3)
		lines << gui.text(text: '(no DBC message for this ID)', text_style: gui.theme().n4)
		return gui.column(sizing: gui.fill_fill, padding: gui.padding_medium, spacing: 5, content: lines)
	}
	data := agg.last
	ext := agg.ext
	add_color := gui.Color{44, 160, 44, 255}  // green = add to graph
	drop_color := gui.Color{200, 70, 70, 255}  // red = remove from graph
	// Header: title + a "＋ Plot all" / "✕ Drop all" toggle for the whole frame.
	active := if data.len > 0 { msg.active_signals(data) } else { []candb.Signal{} }
	mut names := []string{}
	for s in active {
		names << s.name
	}
	all_on := names.len > 0 && names.all(app.is_pinned(id, ext, it))
	mut head := [gui.View(gui.text(text: 'Signals — ${hexid(id, ext)} ${msg.name}',
		text_style: gui.theme().b3))]
	if names.len > 0 {
		head << gui.row(
			padding:  scpad(1, 6, 1, 6)
			on_click: fn [id, ext, names, all_on] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				if all_on {
					a.drop_frame_pins(id, ext)
				} else {
					a.add_pins(id, ext, names)
				}
			}
			content:  [gui.text(text: if all_on { '✕ Drop all' } else { '＋ Plot all' },
				text_style: gui.TextStyle{
				...gui.theme().n4
				color: if all_on { drop_color } else { add_color }
			})]
		)
	}
	lines << gui.row(v_align: .middle, spacing: 8, padding: gui.padding_none, content: head)
	if data.len > 0 {
		for s in active {
			label := s.label(data)
			suffix := if label != '' { ' (${label})' } else { '' }
			pinned := app.is_pinned(id, ext, s.name)
			signame := s.name
			// Whole row is the add/remove button (a nested clickable child breaks the
			// row layout). Leading coloured "＋ Plot" / "✕ Drop" reads as an action.
			lines << gui.row(
				v_align:  .middle
				spacing:  6
				padding:  scpad(1, 2, 1, 2)
				on_click: fn [id, ext, signame] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.toggle_pin(id, ext, signame)
				}
				content:  [
					gui.text(text: if pinned { '✕ Drop' } else { '＋ Plot' }, text_style: gui.TextStyle{
						...gui.theme().n4
						color: if pinned { drop_color } else { add_color }
					}),
					gui.text(text: '${s.name}: ${s.physical(data):.1f} ${s.unit}${suffix}',
						text_style: gui.theme().n4),
				]
			)
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

// plot_colors is the per-signal line palette for the Graphics panel. Saturated
// mid-tones (matplotlib tab10-ish) so the lines read on BOTH the white opus-light
// canvas and the dark canvas — the old palette washed out on white.
const plot_colors = [
	gui.Color{31, 119, 180, 255},  // blue
	gui.Color{214, 39, 40, 255},   // red
	gui.Color{44, 160, 44, 255},   // green
	gui.Color{148, 103, 189, 255}, // purple
	gui.Color{255, 127, 14, 255},  // orange
	gui.Color{23, 158, 175, 255},  // teal
	gui.Color{140, 86, 75, 255},   // brown
]

// fmt_axis formats a Y-axis tick value with precision suited to the value span.
fn fmt_axis(v f32, span f32) string {
	if span >= 100 {
		return '${v:.0f}'
	}
	if span >= 1 {
		return '${v:.1f}'
	}
	return '${v:.3f}'
}

// PlottedSig is one signal on the Graphics plot, with the message it came from (so
// history/timeline come from the right message) and its canonical key.
struct PlottedSig {
	id  u32
	ext bool
	sig candb.Signal
	key string
}

// plot_panel graphs the selected message's signals over the trace history — a
// conventional Graphics strip chart. The x-axis is a **fixed time window**
// ([latest − window, latest], selectable 5/10/30/60 s) that slides as frames
// arrive — older samples scroll off the left edge instead of compressing the
// plot. Samples are positioned by recorded time; labels below the canvas mark
// the window. The legend is a per-signal **checkbox**: untick a signal to drop
// it from the plot (App.plot_off). Click a message in the Trace to select the PDU.
// FNV-1a 64-bit fold — mixes a few small ints into one key with no arbitrary
// multipliers (these two are the standard FNV-1a offset basis + prime).
const fnv64_offset = u64(14695981039346656037)
const fnv64_prime = u64(1099511628211)

fn fnv64(h u64, v u64) u64 {
	return (h ^ v) * fnv64_prime
}

// plot_version is the draw_canvas cache key: it changes iff something the plot
// geometry depends on changes — THIS message's sample count (not total bus traffic),
// the shown-signal count, step vs linear, the zoom window, the hover cursor, or the
// canvas size — so the canvas re-tessellates exactly when needed and no more.
fn plot_version(samples int, shown int, step bool, win int, hover_frac f32, cw f32, ph f32, tbucket u64) u64 {
	mut h := fnv64_offset
	h = fnv64(h, u64(samples))
	h = fnv64(h, u64(shown))
	h = fnv64(h, if step { u64(1) } else { u64(0) })
	h = fnv64(h, u64(win))
	h = fnv64(h, u64(int((hover_frac + 1) * 10000))) // quantize the hover fraction
	h = fnv64(h, u64(int(cw)))
	h = fnv64(h, u64(int(ph)))
	h = fnv64(h, tbucket) // wall-clock bucket while live: re-tessellate per frame so the strip chart slides smoothly between samples (0 = stopped, cached)
	return h
}

fn plot_panel(mut window gui.Window) gui.View {
	mut app := window.state[App]()
	// The plot is an independent watch list: show the empty-state when nothing is
	// pinned (NOT when the Trace selection is cleared — that's what made a populated
	// graph vanish on Trace Clear, which sets sel_id = -1). Keeping the `plot_root`
	// id here means the node exists in the tree from frame 0, so the measure block's
	// find_layout_by_id('plot_root') below never runs before the node exists.
	if app.plot_watch.len == 0 {
		return gui.column(
			id:      'plot_root'
			sizing:  gui.fill_fill
			padding: gui.padding_medium
			spacing: 5
			content: [
				gui.text(text: 'Graphics', text_style: gui.theme().b3),
				gui.text(text: 'Empty — add signals with ＋ Plot in the Signals panel (click a Trace row to pick a frame).',
					text_style: gui.theme().n4),
			]
		)
	}
	// Measure THIS panel from the previous frame's layout tree so the canvas fills
	// it exactly — draw_canvas needs explicit px. One-frame lag is imperceptible.
	mut avail_w := f32(360)
	mut avail_h := f32(220)
	if root := window.find_layout_by_id('plot_root') {
		if root.shape.width > 1 {
			avail_w = root.shape.width - 2 * gui.pad_medium
			avail_h = root.shape.height - 2 * gui.pad_medium
		}
	}
	legend_w := f32(168)
	header_h := f32(34)
	labels_h := f32(18)
	yaxis_w := f32(58)
	cw := clampf(avail_w - legend_w - yaxis_w - 18, 140, 6000)
	ph := clampf(avail_h - header_h - labels_h - 8, 90, avail_h - 44)

	// The plot is an explicit WATCH LIST: it shows exactly the signals you've added
	// (＋ Plot in the Signals panel), accumulated across as many frames as you like,
	// and stays put as you click around the Trace. Each carries its own message id so
	// history + timeline come from the right message.
	mut plotted := []PlottedSig{}
	mut seen := map[string]bool{}
	for p in app.plot_watch {
		k := pin_key(p.id, p.ext, p.signal)
		if k in seen {
			continue
		}
		pm := app.db.lookup_frame(p.id, p.ext) or { continue }
		for s in pm.signals {
			if s.name == p.signal {
				plotted << PlottedSig{
					id:  p.id
					ext: p.ext
					sig: s
					key: k
				}
				seen[k] = true
				break
			}
		}
	}
	if plotted.len == 0 {
		return gui.column(
			id:      'plot_root'
			sizing:  gui.fill_fill
			padding: gui.padding_medium
			spacing: 5
			content: [
				gui.text(text: 'Graphics', text_style: gui.theme().b3),
				gui.text(text: 'Empty — add signals with ＋ Plot in the Signals panel (click a Trace row to pick a frame).',
					text_style: gui.theme().n4),
			]
		)
	}

	win := f32(if app.plot_win > 0 { app.plot_win } else { 10 })
	// Right edge of the strip chart = latest recorded time across ALL plotted frames;
	// while LIVE, track wall-clock NOW so the chart slides smoothly between samples.
	mut last_t := f32(0)
	for pl in plotted {
		h := app.plot_hist[hist_key(pl.id, pl.ext)] or { []PlotSample{} }
		if h.len > 0 && h.last().t_s > last_t {
			last_t = h.last().t_s
		}
	}
	t_end := if app.running && !app.paused {
		now_s := f32(f64(time.ticks() - app.t0) / 1000.0)
		if now_s > last_t { now_s } else { last_t }
	} else {
		last_t
	}
	wstart := if t_end > win { t_end - win } else { f32(0) }

	// Decode each plotted signal's in-window samples from ITS message history into
	// reused buffers; recompute only when the set / any history length / zoom / the
	// sliding window changes. The `int(wstart*4)` term (250 ms buckets) makes a sparse
	// signal's series re-trim as old samples age out of the window even when no new
	// frame has arrived (h.len unchanged). Cross-frame signals keep their own
	// timelines, so times is per-series.
	mut sig := '${app.plot_win}:${int(wstart * 4)}|'
	for pl in plotted {
		h := app.plot_hist[hist_key(pl.id, pl.ext)] or { []PlotSample{} }
		sig += '${pl.key}:${h.len}:${app.plot_off[pl.key]};'
	}
	// Hash of `sig` folded into the canvas version below, so the plot re-tessellates
	// whenever the watch set / data / window changes — even when STOPPED (where the
	// 30 Hz bucket is 0) and two different watch lists happen to share `total`/`shown.len`.
	mut sighash := fnv64_offset
	for b in sig {
		sighash = fnv64(sighash, u64(b))
	}
	if sig != app.plot_sig {
		app.plot_sig = sig
		if app.plot_series.len != plotted.len {
			app.plot_series = [][]f32{len: plotted.len, init: []f32{}}
			app.plot_times = [][]f32{len: plotted.len, init: []f32{}}
			app.plot_cur = []f64{len: plotted.len}
		}
		for j, pl in plotted {
			h := app.plot_hist[hist_key(pl.id, pl.ext)] or { []PlotSample{} }
			mut st := h.len
			for st > 0 && h[st - 1].t_s >= wstart {
				st--
			}
			if h.len - st > plot_max_points {
				st = h.len - plot_max_points
			}
			mut vals := app.plot_series[j]
			mut ts := app.plot_times[j]
			vals.clear()
			ts.clear()
			// Widen (never shrink) this signal's running y-range for a stable scale.
			mut lo := f32(0)
			mut hi := f32(0)
			mut have := false
			if r := app.plot_range[pl.key] {
				lo, hi, have = r[0], r[1], true
			}
			for i := st; i < h.len; i++ {
				v := f32(pl.sig.physical(h[i].data))
				vals << v
				ts << h[i].t_s
				if !have {
					lo, hi, have = v, v, true
				} else {
					if v < lo {
						lo = v
					}
					if v > hi {
						hi = v
					}
				}
			}
			if have {
				app.plot_range[pl.key] = [lo, hi]!
			}
			app.plot_series[j] = vals
			app.plot_times[j] = ts
			app.plot_cur[j] = if vals.len > 0 { f64(vals.last()) } else { f64(0) }
		}
	}
	series := app.plot_series
	stimes := app.plot_times
	cur := app.plot_cur

	// Visible (legend-checked) signals → parallel draw arrays (own timeline each).
	mut shown := [][]f32{}
	mut shown_times := [][]f32{}
	mut shown_colors := []gui.Color{}
	mut shown_min := []f32{}
	mut shown_max := []f32{}
	mut common_unit := ''
	mut unit_set := false
	for j, pl in plotted {
		if !app.plot_off[pl.key] {
			shown << series[j]
			shown_times << stimes[j]
			shown_colors << plot_colors[j % plot_colors.len]
			r := app.plot_range[pl.key] or { [f32(0), f32(1)]! }
			shown_min << r[0]
			shown_max << r[1]
			if !unit_set {
				common_unit = pl.sig.unit
				unit_set = true
			} else if pl.sig.unit != common_unit {
				common_unit = '' // mixed units → no unit on the shared axis
			}
		}
	}
	// Shared Y-range across all visible signals (the labelled axis). In shared mode
	// every series is drawn against [srlo, srhi]; in fit-each mode each keeps its own.
	shared_y := app.plot_shared
	mut srlo := f32(0)
	mut srhi := f32(1)
	if shown_min.len > 0 {
		srlo, srhi = shown_min[0], shown_max[0]
		for i in 1 .. shown_min.len {
			if shown_min[i] < srlo {
				srlo = shown_min[i]
			}
			if shown_max[i] > srhi {
				srhi = shown_max[i]
			}
		}
	}
	if srhi <= srlo {
		srhi = srlo + 1
	}
	mut draw_min := shown_min.clone()
	mut draw_max := shown_max.clone()
	if shared_y {
		for i in 0 .. draw_min.len {
			draw_min[i] = srlo
			draw_max[i] = srhi
		}
	}

	plot_bg := if app.dark { gui.Color{24, 24, 30, 255} } else { gui.rgb(255, 255, 255) }
	plot_grid := if app.dark { gui.Color{55, 55, 70, 255} } else { gui.rgb(214, 214, 214) }
	// Hover cursor: map the stored fraction to a sample index + time for the
	// crosshair (on-canvas) and the value readout (left signal list).
	hf := app.plot_hover_frac
	hover_time := if hf >= 0 { wstart + hf * win } else { f32(-1) }

	// Title: how many signals are on the watch list, and from how many frames.
	mut frames := map[u64]bool{}
	for pl in plotted {
		frames[hist_key(pl.id, pl.ext)] = true
	}
	plot_title := 'Graphics — ${plotted.len} signal${if plotted.len == 1 { '' } else { 's' }} / ${frames.len} frame${if frames.len == 1 { '' } else { 's' }}'
	// --- Header: title + zoom toolbar ('−' widens the time window, '+' narrows it). ---
	header := gui.row(
		v_align: .middle
		spacing: 6
		padding: gui.padding_none
		content: [
			gui.text(text: plot_title, text_style: gui.theme().n4),
			gui.button(
				id_focus:  109
				max_width: sc(34)
				content:   [gui.text(text: '−')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					zoom_window(mut w, 1)
				}
			),
			window.select(
				id:        'plotwin'
				id_focus:  108
				select:    ['${app.plot_win} s']
				options:   plot_win_options
				min_width: sc(58)
				max_width: sc(70)
				on_select: fn (sel []string, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					if sel.len > 0 {
						a.plot_win = sel[0].all_before(' ').int()
					}
				}
			),
			gui.button(
				id_focus:  110
				max_width: sc(34)
				content:   [gui.text(text: '+')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					zoom_window(mut w, -1)
				}
			),
			gui.button(
				id_focus:  111
				max_width: sc(72)
				content:   [gui.text(text: if app.plot_step { '⎍ Step' } else { '╱ Linear' })]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.plot_step = !a.plot_step
				}
			),
			gui.button(
				id_focus:  112
				max_width: sc(90)
				content:   [gui.text(text: if app.plot_shared { '⊞ Shared' } else { '⊟ Fit each' })]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.plot_shared = !a.plot_shared
				}
			),
			gui.button(
				id_focus:  113
				max_width: sc(70)
				content:   [gui.text(text: 'Clear')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.reset_plot() // empty the graph + drop stale Y-ranges (keeps trace history)
				}
			),
		]
	)

	mut total := 0
	for s in shown {
		total += s.len
	}
	step := app.plot_step
	// --- Canvas (full panel width) + timeline labels directly under it. ---
	canvas := gui.draw_canvas(
		id:       'sigplot'
		// Re-tessellate when the geometry changes (see plot_version) — keyed off THIS
		// message's sample count + canvas/zoom/hover. While LIVE we also fold in a
		// ~30 Hz wall-clock bucket so the strip chart slides smoothly between samples
		// (the window's right edge tracks real time, not the last sample); when stopped
		// the bucket is 0, so a static/loaded plot stays cached.
		version:  plot_version(total, shown.len, step, app.plot_win, hf, cw, ph, if app.running
			&& !app.paused {
			u64(time.ticks() / 33)
		} else {
			u64(0)
		}) + sighash + if shared_y { u64(7) } else { u64(0) }
		width:    cw
		height:   ph
		color:    plot_bg
		radius:   4
		padding:  scpad(6, 6, 6, 6)
		on_draw:  fn [mut app, shown, shown_colors, draw_min, draw_max, shown_times, wstart, win, plot_grid, hf, step] (mut dc gui.DrawContext) {
			draw_signals(mut dc, mut app, shown, shown_colors, draw_min, draw_max, shown_times,
				wstart, win, plot_grid, hf, step)
		}
		on_hover: fn (mut layout gui.Layout, mut e gui.Event, mut w gui.Window) {
			mut a := w.state[App]()
			cwid := layout.shape.width - layout.shape.padding.left - layout.shape.padding.right
			if cwid <= 0 {
				return
			}
			rel := e.mouse_x - layout.shape.x - layout.shape.padding.left
			a.plot_hover_frac = clampf(rel / cwid, 0, 1)
		}
	)
	// Y-axis labels (left of the canvas), aligned to the gridlines top→bottom. Shared
	// mode → real values srhi..srlo (+ common unit); fit-each → normalised 100%..0%
	// (a reminder that each curve is auto-fit to its own range).
	span := srhi - srlo
	mut ylabels := []gui.View{}
	for k in 0 .. 5 {
		txt := if shared_y {
			v := srhi - span * f32(k) / 4
			fmt_axis(v, span) + if common_unit != '' { ' ${common_unit}' } else { '' }
		} else {
			'${100 - 25 * k}%'
		}
		ylabels << gui.text(text: txt, text_style: trace_text_style())
		if k < 4 {
			ylabels << gui.row(sizing: gui.fit_fill, padding: gui.padding_none) // vertical spacer
		}
	}
	yaxis := gui.column(
		width:   yaxis_w
		height:  ph
		sizing:  gui.fixed_fixed
		h_align: .right
		padding: gui.padding_none
		content: ylabels
	)
	mut tlabels := []gui.View{}
	for k in 0 .. 5 {
		tlabels << gui.text(text: '${wstart + win * f32(k) / 4:.1f}s', text_style: trace_text_style())
		if k < 4 {
			tlabels << gui.row(sizing: gui.fill_fit, padding: gui.padding_none) // spacer
		}
	}
	// RIGHT side: [Y-axis | canvas] on top, timeline labels under the canvas (offset
	// past the Y-axis column so they line up with the plot, not the labels).
	right := gui.column(
		sizing:  gui.fill_fill
		spacing: 2
		padding: gui.padding_none
		content: [
			gui.row(sizing: gui.fit_fit, spacing: 2, padding: gui.padding_none, content: [yaxis, canvas]),
			gui.row(sizing: gui.fit_fit, padding: gui.padding_none, content: [
				gui.row(width: yaxis_w + 2, sizing: gui.fixed_fit, padding: gui.padding_none),
				gui.row(width: cw, sizing: gui.fixed_fit, padding: gui.padding_none, content: tlabels),
			]),
		]
	)

	// LEFT side: the signal list (fixed width, scrolls if long) — each signal a
	// colour-coded checkbox showing its live/cursor value; cursor time on top.
	mut legend := []gui.View{}
	if hf >= 0 {
		legend << gui.text(text: '⌖ @ ${hover_time:.2f}s', text_style: gui.theme().n4)
	}
	// One clickable row per plotted signal: [☑/☐] [colour-coded name] [value]. The
	// whole row toggles show/hide (single on_click, so names render reliably — a
	// nested clickable glyph broke the row layout). Pinned (cross-frame) signals are
	// prefixed with their frame id; unpin them from the Signals panel (✕ there).
	for j, pl in plotted {
		key := pl.key
		c := plot_colors[j % plot_colors.len]
		on := !app.plot_off[key]
		// Value at the hover cursor (nearest sample in THIS series' own timeline), else latest.
		mut val := cur[j]
		if hf >= 0 && stimes[j].len > 0 {
			mut bestd := f32(1e30)
			mut bi := -1
			for i, t in stimes[j] {
				d := if t > hover_time { t - hover_time } else { hover_time - t }
				if d < bestd {
					bestd = d
					bi = i
				}
			}
			if bi >= 0 && bi < series[j].len {
				val = f64(series[j][bi])
			}
		}
		name_txt := '0x${pl.id:X} ${pl.sig.name}' // watch list spans frames → always show the source
		legend << gui.row(
			v_align:  .middle
			spacing:  4
			padding:  scpad(1, 2, 1, 2)
			on_click: fn [key] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				if key in a.plot_off {
					a.plot_off.delete(key)
				} else {
					a.plot_off[key] = true
				}
			}
			content:  [
				gui.text(text: if on { '☑' } else { '☐' }, text_style: trace_text_style()),
				gui.text(text: name_txt, text_style: gui.TextStyle{
					...trace_text_style()
					color: if on { c } else { gui.Color{150, 150, 150, 255} }
				}),
				gui.text(text: '${val:.1f}', text_style: trace_text_style()),
			]
		)
	}
	left := gui.column(
		width:           legend_w
		sizing:          gui.fixed_fill
		spacing:         2
		padding:         gui.padding_none
		id_scroll:       id_scroll_plot
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         legend
	)

	return gui.column(
		id:              'plot_root'
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         4
		// Vertical scroll clamps plot_root's measured size to the panel viewport —
		// without it, measuring plot_root (which contains the fixed-size canvas)
		// feeds the canvas size back into avail_h and the panel grows without bound.
		id_scroll:       id_scroll_plot_outer
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         [
			header,
			gui.row(sizing: gui.fill_fill, spacing: 8, padding: gui.padding_none, content: [left, right]),
		]
	)
}

// zoom_window steps the Graphics time window through 5/10/30/60 s. dir +1 widens
// (zoom out), -1 narrows (zoom in).
fn zoom_window(mut w gui.Window, dir int) {
	mut a := w.state[App]()
	wins := [5, 10, 30, 60]
	mut idx := wins.index(a.plot_win)
	if idx < 0 {
		idx = 1
	}
	idx += dir
	if idx < 0 {
		idx = 0
	}
	if idx >= wins.len {
		idx = wins.len - 1
	}
	a.plot_win = wins[idx]
}

// draw_signals paints the plot grid (4 horizontal bands + 4 vertical time
// divisions matching the labels below the canvas) and each visible series.
fn draw_signals(mut dc gui.DrawContext, mut app App, series [][]f32, colors []gui.Color,
	mins []f32, maxs []f32, times [][]f32, wstart f32, win f32, grid gui.Color, hover f32, step bool) {
	cw := dc.width
	ch := dc.height
	for i in 0 .. 5 {
		y := ch * f32(i) / 4
		dc.line(0, y, cw, y, grid, 1)
		x := cw * f32(i) / 4
		dc.line(x, 0, x, ch, grid, 1)
	}
	// Vertical hover crosshair (neutral grey reads on both white and dark).
	if hover >= 0 {
		hx := cw * hover
		dc.line(hx, 0, hx, ch, gui.Color{130, 130, 140, 255}, 1)
	}
	for j, s in series {
		draw_one_series(mut dc, mut app, s, mins[j], maxs[j], times[j], wstart, win, colors[j % colors.len],
			hover, step)
	}
}

// draw_one_series plots a single signal on the FIXED strip-chart window
// (x = recorded time mapped over [wstart, wstart+win]), auto-scaled to its own
// min/max so all signals are visible regardless of their physical range.
// draw_one_series tessellates+draws one signal, reusing app's scratch buffers
// (app.plot_xs/ys/pts) instead of allocating fresh arrays each re-tessellation. The
// draw path is single-threaded and each series is filled then drawn before the next,
// so sharing the scratch is safe; steady state allocates nothing once capacity settles.
fn draw_one_series(mut dc gui.DrawContext, mut app App, series []f32, mn f32, mx f32, times []f32, wstart f32,
	win f32, color gui.Color, hover f32, step bool) {
	if series.len < 2 || times.len != series.len {
		return
	}
	cw := dc.width
	ch := dc.height
	span := if mx > mn { mx - mn } else { f32(1) }
	tspan := if win > 0 { win } else { f32(1) }
	// Pre-compute each sample's pixel position once, into app's reused scratch
	// (cleared, not reallocated) — no aliasing copy, mutated through the app pointer.
	app.plot_xs.clear()
	app.plot_ys.clear()
	for i, v in series {
		app.plot_xs << cw * (times[i] - wstart) / tspan
		app.plot_ys << ch - ch * (v - mn) / span * 0.92 - ch * 0.04 // 4% top/bottom margin
	}
	// Decimate to ~1 point per horizontal pixel. More points than the canvas is wide
	// can't be resolved AND explode tessellation — a wide zoom window pulling 1000+
	// samples per signal × N signals overflowed gui's render buffer, blanking the
	// WHOLE window (no panic — a silent GPU-buffer overflow). Stride keeps the count
	// bounded regardless of zoom/history; butt/bevel joins also cut triangles vs round.
	mut budget := int(cw)
	if budget < 2 {
		budget = 2
	}
	stride := if series.len > budget { series.len / budget } else { 1 }
	// Step (sample-and-hold): hold the value horizontally to the next sample, then jump
	// vertically — the conventional tooling look. Linear: straight segments. Held value = previous
	// EMITTED sample (so it works under decimation too).
	app.plot_pts.clear()
	mut prev := -1
	mut k := 0
	for {
		if step && prev >= 0 {
			app.plot_pts << app.plot_xs[k]
			app.plot_pts << app.plot_ys[prev]
		}
		app.plot_pts << app.plot_xs[k]
		app.plot_pts << app.plot_ys[k]
		prev = k
		if k >= series.len - 1 {
			break
		}
		k += stride
		if k > series.len - 1 {
			k = series.len - 1 // always include the most recent sample
		}
	}
	dc.polyline(app.plot_pts, color, 1.5, .butt, .bevel)
	// Marker dot where the hover crosshair crosses this series (nearest sample).
	if hover >= 0 {
		ht := wstart + hover * win
		mut idx := 0
		mut bestd := f32(1e30)
		for i, t in times {
			d := if t > ht { t - ht } else { ht - t }
			if d < bestd {
				bestd = d
				idx = i
			}
		}
		dc.filled_circle(app.plot_xs[idx], app.plot_ys[idx], 3, color)
	}
}

fn clampf(v f32, lo f32, hi f32) f32 {
	return if v < lo { lo } else if v > hi { hi } else { v }
}

// symbol_browser_panel browses the loaded DBC (conventional Symbol Browser): a
// searchable, collapsible tree of messages → signals. Each signal shows its live
// decoded value (from the latest received frame) and DBC range; a green/grey dot
// marks whether the message is currently on the bus. Clicking a message header
// selects it (Signals/Graphics follow) and toggles its signal list.
fn symbol_browser_panel(app &App) gui.View {
	mut rows := [gui.View(gui.text(text: 'Symbol Browser', text_style: gui.theme().b3))]
	rows << gui.row(
		v_align: .middle
		spacing: 6
		padding: scpad(2, 0, 4, 0)
		content: [
			gui.text(text: 'Find', text_style: gui.theme().n4),
			gui.input(
				id_focus:        60
				text:            app.symbol_filter
				width:           sc(200)
				height:          sc(22)
				padding:         scpad(2, 6, 2, 6)
				sizing:          gui.fixed_fixed
				placeholder:     'message / signal name or id'
				on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
					mut a := w.state[App]()
					a.symbol_filter = s
				}
			),
		]
	)
	if app.db.messages.len == 0 {
		rows << gui.text(text: '(no database loaded)', text_style: gui.theme().n4)
		return gui.column(sizing: gui.fill_fill, padding: gui.padding_medium, spacing: 4, content: rows)
	}
	// Iterate messages by sorted id WITHOUT sorting the Message structs: V's stable
	// sort can fault ('invalid memory access') moving structs that contain maps
	// (Signal.values). Sort the u32 ids (a plain int sort is safe) via an id→index
	// map and index back into the unsorted catalog.
	mut idx := map[u32]int{}
	for i, msg in app.db.messages {
		idx[msg.id] = i
	}
	mut ids := idx.keys()
	ids.sort()
	filt := app.symbol_filter.to_lower()
	for id in ids {
		m := app.db.messages[idx[id]]
		if filt != '' {
			mut hit := m.name.to_lower().contains(filt) || hexid(m.id, m.ext).to_lower().contains(filt)
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
		}
		expanded := app.symbol_expanded[m.id]
		data := app.latest_for(m.id).last
		live := data.len > 0
		mid := m.id
		ext := m.ext
		rows << gui.row(
			v_align:  .middle
			spacing:  4
			padding:  scpad(1, 2, 1, 2)
			on_click: fn [mid] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				a.sel_id = i64(mid)
				if mid in a.symbol_expanded {
					a.symbol_expanded.delete(mid)
				} else {
					a.symbol_expanded[mid] = true
				}
			}
			content:  [
				gui.text(text: if expanded { '▼' } else { '▶' }, text_style: trace_text_style()),
				gui.text(text: '●', text_style: gui.TextStyle{
					...trace_text_style()
					color: if live { gui.Color{120, 200, 120, 255} } else { gui.Color{180, 180, 180, 255} }
				}),
				gui.text(text: hexid(mid, ext), text_style: trace_text_style()),
				gui.text(text: m.name, text_style: gui.theme().b4),
				gui.text(text: '(${m.signals.len})', text_style: gui.theme().n4),
			]
		)
		if expanded {
			for s in m.signals {
				val := if data.len > 0 {
					lbl := s.label(data)
					if lbl != '' {
						'${s.physical(data):.2f} ${s.unit} (${lbl})'
					} else {
						'${s.physical(data):.2f} ${s.unit}'
					}
				} else {
					'— ${s.unit}'
				}
				rng := if s.minimum != 0 || s.maximum != 0 {
					'[${s.minimum:.0f}..${s.maximum:.0f}]'
				} else {
					''
				}
				rows << gui.row(
					v_align: .middle
					spacing: 6
					padding: scpad(0, 0, 0, 22)
					content: [
						gui.text(text: s.name, text_style: trace_text_style()),
						gui.text(text: val, text_style: gui.theme().n4),
						gui.text(text: rng, text_style: gui.theme().n4),
					]
				)
			}
		}
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         2
		id_scroll:       id_scroll_symbols
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
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
			gui.text(text: 'Trace groups (id/bus/dir): ${app.order.len}', text_style: gui.theme().n4),
			gui.text(text: 'Channels: ${app.proj.channels.len}', text_style: gui.theme().n4),
			gui.text(text: 'Database: ${app.db.messages.len} msgs', text_style: gui.theme().n4),
			gui.text(text: 'DB source: ${app.db_source}', text_style: gui.theme().n4),
			gui.text(text: 'Project: ${app.proj.name} (${app.proj_source})', text_style: gui.theme().n4),
		]
	)
}

// log_panel renders the scrolling event log (App.logs) newest-first, each line
// timestamped and coloured by level (info/ok/warn/error). The toolbar status line
// shows only the latest; this keeps the history. Clear empties it.
fn log_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	mut rows := []gui.View{}
	rows << gui.row(
		v_align: .middle
		spacing: 6
		content: [
			gui.text(text: 'Log (${app.logs.len})', text_style: gui.theme().b3),
			gui.button(
				id_focus:  0
				max_width: sc(56)
				content:   [gui.text(text: 'Clear')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.logs = []StatusMsg{}
				}
			),
		]
	)
	if app.logs.len == 0 {
		rows << gui.text(text: '(no messages yet)', text_style: gui.theme().n4)
	}
	for i := app.logs.len - 1; i >= 0; i-- {
		m := app.logs[i]
		col := match m.level {
			.error { gui.Color{200, 60, 60, 255} }
			.warn { gui.Color{170, 120, 0, 255} }
			.ok { gui.Color{50, 140, 60, 255} }
			.info { gui.theme().n4.color }
		}
		rows << gui.text(
			text:       '${m.tstamp}  ${m.text}'
			text_style: gui.TextStyle{
				...gui.theme().n4
				color: col
			}
		)
	}
	return gui.column(
		sizing:      gui.fill_fill
		padding:     gui.padding_medium
		spacing:     3
		id_scroll:   id_scroll_log
		scroll_mode: .vertical_only
		content:     rows
	)
}

// buses_panel lists the project's channels (buses): a click-to-toggle enable
// box, a state-colour dot, the name/interface, and live RX/TX counts. It's the
// front-end of Start/Stop — enable a channel, then Start attaches it.
// bus_config_panel is the conventional "Network Hardware Configuration": Discover
// fills a candidate list (real can/vcan + virtual buses, each with live link state),
// you tick the ones you want, then ＋ Add appends them as project channels. In-memory
// — review in Buses, persist with File ▸ Save. (A dock panel, not a modal — gui has
// no custom-content modal; drag its tab out to float it.)
fn bus_config_panel(app &App) gui.View {
	mut rows := [gui.View(gui.text(text: 'Bus / Channel Configuration', text_style: gui.theme().b3))]
	// Row 1: discovery / attach.
	rows << gui.row(
		v_align: .middle
		spacing: 6
		padding: scpad(0, 0, 2, 0)
		content: [
			gui.button(
				id_focus:  0
				max_width: sc(92)
				content:   [gui.text(text: '🔍 Discover')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					discover_to_candidates(mut w)
				}
			),
			// USB CAN attach with an explanatory hover.
			gui.row(
				v_align: .middle
				padding: gui.padding_none
				tooltip: &gui.TooltipCfg{
					id:      'usbcan_tip'
					content: [
						gui.text(text: 'Attach USB CAN adapters (Kvaser/PEAK) into WSL\nvia usbipd, so they appear as can0/… for Discover.\n(One-time `usbipd bind` still needs an elevated\nWindows shell.)'),
					]
				}
				content: [
					gui.button(
						id_focus:  0
						max_width: sc(80)
						content:   [gui.text(text: '⚲ USB CAN')]
						on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							usb_attach_can(mut w)
						}
					),
				]
			),
		]
	)
	// Row 2: add a network / add the ticked candidates.
	rows << gui.row(
		v_align: .middle
		spacing: 6
		padding: scpad(0, 0, 4, 0)
		content: [
			gui.button(
				id_focus:  0
				max_width: sc(84)
				content:   [gui.text(text: '＋ vcan')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					create_vcan(mut w)
				}
			),
			gui.button(
				id_focus:  0
				max_width: sc(92)
				content:   [gui.text(text: '＋ Sim net')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					add_sim_network(mut w)
				}
			),
			gui.button(
				id_focus:  0
				max_width: sc(110)
				content:   [gui.text(text: '＋ Add ticked')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					add_ticked_channels(mut w)
				}
			),
		]
	)
	if app.bus_candidates.len == 0 {
		rows << gui.text(text: '(press Discover to scan interfaces)', text_style: gui.theme().n4)
	}
	for idx, c in app.bus_candidates {
		iface := c.iface
		kindlbl := match c.kind {
			'can' { 'hardware CAN' }
			'vcan' { 'virtual CAN' }
			'udp' { 'software bus' }
			'inproc' { 'simulation' }
			else { c.kind }
		}
		// Lead with the real hardware model when we have it (Kvaser/PCAN…) so you can
		// tell which physical adapter each canN is; else the generic kind.
		mut info := if c.hw != '' { c.hw } else { kindlbl }
		if c.bitrate > 0 {
			info += ' · ${c.bitrate}'
		}
		if c.state != '' {
			info += ' · ${c.state}'
		}
		if c.in_proj {
			info += ' · (already added)'
		}
		ticked := app.bus_ticked[iface] or { false }
		statecolor := match c.state {
			'connected' { gui.Color{120, 200, 120, 255} }
			'no carrier' { gui.Color{210, 180, 90, 255} }
			'down' { gui.Color{170, 170, 170, 255} }
			else { gui.Color{150, 150, 200, 255} }
		}
		cname := app.bus_names[iface] or { c.name }
		rows << gui.row(
			v_align: .middle
			spacing: 5
			padding: scpad(1, 2, 1, 2)
			content: [
				// tick on its OWN clickable so editing the name doesn't toggle it
				gui.row(
					v_align:  .middle
					padding:  scpad(0, 3, 0, 1)
					on_click: fn [iface] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
						mut a := w.state[App]()
						a.bus_ticked[iface] = !(a.bus_ticked[iface] or { false })
					}
					content:  [
						gui.text(text: if ticked { '☑' } else { '☐' }, text_style: trace_text_style()),
					]
				),
				gui.text(text: '●', text_style: gui.TextStyle{
					...trace_text_style()
					color: statecolor
				}),
				// editable channel name — what lands in the project (e.g. 'vehicle-can')
				gui.input(
					id_focus:        u32(130 + idx)
					text:            cname
					width:           sc(120)
					height:          sc(22)
					padding:         scpad(2, 6, 2, 6)
					sizing:          gui.fixed_fixed
					on_text_changed: fn [iface] (_ &gui.Layout, s string, mut w gui.Window) {
						mut a := w.state[App]()
						a.bus_names[iface] = s
					}
				),
				gui.text(text: iface, text_style: trace_text_style()),
				gui.text(text: info, text_style: gui.theme().n4),
			]
		)
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         3
		id_scroll:       id_scroll_busconfig
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
	)
}

fn buses_panel(app &App) gui.View {
	mut rows := []gui.View{}
	rows << gui.text(text: 'Buses', text_style: gui.theme().b3)
	// Which project is open (also in the titlebar + Stats).
	rows << gui.text(text: 'Project: ${app.proj.name}', text_style: gui.theme().n4)
	// Discover opens the Bus Config panel and scans. (USB CAN attach moved there.)
	rows << gui.row(
		v_align: .middle
		spacing: 5
		padding: scpad(0, 0, 4, 0)
		content: [
			gui.button(
				id_focus:  0
				max_width: sc(92)
				content:   [gui.text(text: '🔍 Discover')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					open_bus_config(mut w)
				}
			),
		]
	)
	for i, ch in app.proj.channels {
		rt := app.rt[i] or { ChannelRT{} }
		dot_style := gui.TextStyle{
			...trace_text_style()
			color: channel_color(ch, rt, app.running)
		}
		en := ch.enabled
		rows << gui.row(
			v_align: .middle
			spacing: 6
			padding: gui.padding_none
			content: [
				gui.text(text: '●', text_style: dot_style),
				// Enable toggle as a button (an on_click gui.row stretches and pushes
				// the rest right — see docs/known_issues.md). id_focus:0 → no stuck blue.
				gui.button(
					id_focus:  0
					max_width: sc(26)
					content:   [gui.text(text: if en { '☑' } else { '☐' })]
					on_click:  fn [i] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
						mut a := w.state[App]()
						a.proj.channels[i].enabled = !a.proj.channels[i].enabled
					}
				),
				gui.text(text: '${ch.name}  ${ch.iface}', text_style: trace_text_style()),
				// Remove this channel from the project.
				gui.button(
					id_focus:  0
					max_width: sc(30)
					content:   [gui.text(text: '✕')]
					on_click:  fn [i] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
						remove_channel(i, mut w)
					}
				),
			]
		)
		// DBC(s) on this channel + attach/clear. Attaching one lights up decode AND
		// the Simulation panel's node list for this bus.
		dbnames := if ch.databases.len > 0 {
			ch.databases.map(os.base(it)).join(', ')
		} else {
			'—'
		}
		mut dbrow := [
			gui.View(gui.button(
				id_focus:  0
				max_width: sc(58)
				content:   [gui.text(text: '＋ DBC')]
				on_click:  fn [i] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					pick_dbc(i, mut w)
				}
			)),
			gui.text(text: 'DBC: ${dbnames}', text_style: gui.theme().n4),
		]
		if ch.databases.len > 0 {
			dbrow << gui.button(
				id_focus:  0
				max_width: sc(30)
				content:   [gui.text(text: '✕')]
				on_click:  fn [i] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					clear_dbc(i, mut w)
				}
			)
		}
		rows << gui.row(
			v_align: .middle
			spacing: 5
			padding: scpad(0, 0, 2, 18) // indent under the channel
			content: dbrow
		)
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         2
		id_scroll:       id_scroll_buses
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
	)
}

// simulation_panel is the connect-the-simulation tree: each network with a DBC
// lists its ECU nodes, each with a checkbox to "connect" it to the bus (= have
// the tester simulate that ECU). Toggling is live while a measurement runs.
fn simulation_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	mut rows := []gui.View{}
	rows << gui.text(text: 'Simulation', text_style: gui.theme().b3)
	// Validation: flag config that doesn't match the DBC (silent-typo guard).
	warns := sim_warnings(app)
	if warns.len > 0 {
		warn_style := gui.TextStyle{
			...trace_text_style()
			color: gui.Color{200, 90, 70, 255}
		}
		rows << gui.text(text: '⚠ ${warns.len} issue(s):', text_style: warn_style)
		for warn in warns {
			rows << gui.text(text: '   ${warn}', text_style: warn_style)
		}
	}
	if app.sim_nodes.len == 0 {
		rows << gui.text(text: '(no DBC nodes to simulate)', text_style: gui.theme().n4)
		return gui.column(sizing: gui.fill_fill, padding: gui.padding_medium, spacing: 2, content: rows)
	}
	for i, ch in app.proj.channels {
		if !app.sim_nodes.any(it.ch_idx == i) {
			continue
		}
		rt := app.rt[i] or { ChannelRT{} }
		expanded := app.sim_expanded[i]
		// Per-bus summary: how many of its nodes are enabled / running.
		mut total := 0
		mut enabled := 0
		mut any_running := false
		for sn in app.sim_nodes {
			if sn.ch_idx != i {
				continue
			}
			total++
			if sn.enabled {
				enabled++
				if rt.running {
					any_running = true
				}
			}
		}
		bus_dot := gui.TextStyle{
			...trace_text_style()
			color: if any_running {
				gui.Color{120, 200, 120, 255} // simulating now
			} else if enabled > 0 {
				gui.Color{210, 180, 90, 255} // enabled, will run on Start
			} else {
				gui.Color{170, 170, 170, 255} // nothing connected
			}
		}
		// Clickable bus header: disclosure triangle + dot + name + count.
		rows << gui.row(
			v_align:  .middle
			spacing:  5
			padding:  scpad(2, 0, 2, 0)
			on_click: fn [i] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				a.sim_expanded[i] = !a.sim_expanded[i]
			}
			content:  [
				gui.text(text: if expanded { '▾' } else { '▸' }, text_style: trace_text_style()),
				gui.text(text: '●', text_style: bus_dot),
				gui.text(text: '${ch.name}', text_style: gui.theme().b4),
				gui.text(text: '${enabled}/${total}', text_style: gui.TextStyle{
					...trace_text_style()
					color: gui.Color{150, 150, 150, 255}
				}),
			]
		)
		if !expanded {
			continue
		}
		for j, sn in app.sim_nodes {
			if sn.ch_idx != i {
				continue
			}
			on := sn.enabled && rt.running
			dot_style := gui.TextStyle{
				...trace_text_style()
				color: if on {
					gui.Color{120, 200, 120, 255} // simulating now
				} else if sn.enabled {
					gui.Color{210, 180, 90, 255} // enabled, will run on Start
				} else {
					gui.Color{170, 170, 170, 255} // not connected
				}
			}
			ndix := i
			nname := sn.node
			en := sn.enabled
			nkey := '${i}:${sn.node}'
			nexp := app.sim_sig_expanded[nkey]
			rows << gui.row(
				v_align: .middle
				spacing: 6
				padding: scpad(1, 0, 1, 24) // indent under the network
				content: [
					gui.text(text: '●', text_style: dot_style),
					// gui.button (not an on_click gui.row) for the clickable bits — a
					// clickable row STRETCHES and shoves the next siblings to the far
					// right (docs/known_issues.md); a button sizes to content. id_focus:0
					// so it doesn't stay highlighted after a click (is_focus(0) == false).
					gui.button(
						id_focus:  0
						max_width: sc(26)
						content:   [gui.text(text: if en { '☑' } else { '☐' })]
						on_click:  fn [j] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							a.sim_nodes[j].enabled = !a.sim_nodes[j].enabled
						}
					),
					// Name + expand chevron (click to show/edit this node's generators).
					gui.button(
						id_focus:  0
						min_width: sc(150)
						max_width: sc(150)
						h_align:   .left
						content:   [gui.text(text: '${if nexp { '▾' } else { '▸' }} ${sn.node}')]
						on_click:  fn [nkey] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							a.sim_sig_expanded[nkey] = !a.sim_sig_expanded[nkey]
						}
					),
					gui.button(
						id_focus:  0
						max_width: sc(84)
						h_align:      .center
						content:   [gui.text(text: '⚙ Scaffold')]
						on_click:  fn [ndix, nname] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							scaffold_sim_node(ndix, nname, mut w)
						}
					),
				]
			)
			// Expanded: per-signal generator summaries; click one to edit it inline.
			if nexp {
				gens := node_gens(app, i, sn.node)
				if gens.len == 0 {
					rows << gui.text(text: '   (⚙ Scaffold to add editable generators)',
						text_style: gui.theme().n4)
				}
				for gi, g in gens {
					sigkey := '${i}:${sn.node}:${g.signal}'
					editing := app.sim_sig_edit == sigkey
					rows << gui.row(
						v_align:  .middle
						spacing:  4
						padding:  scpad(0, 0, 0, 52)
						on_click: fn [sigkey] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							a.sim_sig_edit = if a.sim_sig_edit == sigkey { '' } else { sigkey }
						}
						content:  [
							gui.text(text: if editing { '▾' } else { '▸' }, text_style: trace_text_style()),
							gui.text(text: g.signal, text_style: gui.theme().b4, min_width: sc(104)),
							gui.text(text: gen_summary(g), text_style: gui.theme().n4),
						]
					)
					if editing {
						ci := i
						nn := sn.node
						sg := g.signal
						mut ed := [
							gui.View(gui.text(text: 'type', text_style: gui.theme().n4)),
							window.select(
								id:        'gentype_${sigkey}'
								id_focus:  1000
								select:    [g.typ]
								options:   ['const', 'sine', 'sawtooth', 'counter', 'stepmod']
								min_width: sc(90)
								max_width: sc(110)
								on_select: fn [ci, nn, sg] (sel []string, mut _ gui.Event, mut w gui.Window) {
									if sel.len > 0 {
										set_gen_type(ci, nn, sg, sel[0], mut w)
									}
								}
							),
						]
						for fx, f in gen_fields(g.typ) {
							fname := f
							ed << gui.text(text: f, text_style: gui.theme().n4)
							ed << gui.input(
								id_focus:        u32(1001 + fx)
								text:            gnum(gen_field_val(g, f))
								width:           sc(54)
								height:          sc(22)
								sizing:          gui.fixed_fixed
								padding:         scpad(2, 5, 2, 5)
								on_text_changed: fn [ci, nn, sg, fname] (_ &gui.Layout, s string, mut w gui.Window) {
									set_gen_field(ci, nn, sg, fname, s.f64(), mut w)
								}
							)
						}
						rows << gui.row(
							v_align: .middle
							spacing: 4
							padding: scpad(0, 0, 2, 70)
							content: ed
						)
					}
				}
			}
		}
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         2
		id_scroll:       id_scroll_sim
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
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

fn send_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	// Pick a message straight from the loaded database: selecting one fills the id
	// (hex) and a DLC-length zero payload, ready to tweak + Send.
	mut msg_opts := ['(database message…)']
	for m in app.db.messages {
		msg_opts << '0x${m.id:X} ${m.name}'
	}
	// Target bus: '(first running)' or a specific channel by name.
	mut bus_opts := ['(first running)']
	for ch in app.proj.channels {
		bus_opts << ch.name
	}
	cur_bus := if app.send_ch != '' { app.send_ch } else { '(first running)' }
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
					gui.text(text: 'bus', text_style: gui.theme().n4),
					window.select(
						id:        'sendbus'
						id_focus:  14
						select:    [cur_bus]
						options:   bus_opts
						min_width: sc(110)
						max_width: sc(160)
						on_select: fn (sel []string, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							if sel.len > 0 {
								a.send_ch = if sel[0] == '(first running)' { '' } else { sel[0] }
							}
						}
					),
				]
			),
			gui.row(
				v_align: .middle
				sizing:  gui.fill_fit
				spacing: 6
				content: [
					gui.text(text: 'msg', text_style: gui.theme().n4),
					window.select(
						id:        'sendmsg'
						id_focus:  13
						select:    ['(database message…)']
						options:   msg_opts
						min_width: sc(150)
						max_width: sc(230)
						on_select: fn (sel []string, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							if sel.len > 0 && sel[0].starts_with('0x') {
								idhex := sel[0].all_before(' ').all_after('0x')
								a.send_id = idhex
								id := parse_hex_u32(idhex)
								if m := a.db.lookup_frame(id, id > 0x7ff) {
									dlc := if m.dlc > 0 { m.dlc } else { 8 }
									mut bytes := []string{}
									for _ in 0 .. dlc {
										bytes << '00'
									}
									a.send_data = bytes.join(' ')
								}
							}
						}
					),
				]
			),
			gui.row(
				v_align: .middle
				sizing:  gui.fill_fit
				spacing: 6
				content: [
					gui.text(text: 'id', text_style: gui.theme().n4),
					gui.input(
						id_focus:        10
						text:            app.send_id
						width:           sc(90)
						height:          sc(26)
						padding:         scpad(4, 8, 4, 8)
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
						width:           sc(150)
						height:          sc(26)
						padding:         scpad(4, 8, 4, 8)
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
			// A real themed gui.button (matches the toolbar buttons + follows the
			// dark/light theme), fixed to a compact width via min/max_width so it
			// doesn't stretch the whole column.
			gui.button(
				id_focus:  12
				min_width: sc(90)
				max_width: sc(90)
				h_align:      .center
				content:   [gui.text(text: 'Send')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					do_send(mut w)
					w.set_id_focus(0) // don't leave the button stuck in the focused/pressed look
				}
			),
		]
	)
}

// diag_panel is the UDS tester (Phase 6 GUI): one-click services against the
// simulated ECU's UDS server (or any ECU listening on 0x7E0) over software
// ISO-TP, with a newest-first response log. Works driver-free on the in-proc
// bus — press ▶ Start on a channel with simulated nodes first.
// known_dids: common UDS Read-Data-By-Identifier records, offered as a pick-list
// in the Diagnostics panel (DBCs don't define DIDs, so this is a curated list;
// DID↔DBC-signal mapping is a future step).
const known_dids = [
	['F190', 'VIN'],
	['F18C', 'ECU Serial'],
	['F195', 'SW Version'],
	['F187', 'Spare Part No'],
	['F18A', 'Supplier Id'],
	['F197', 'System Name'],
]

// merge_did_opts builds the Diagnostics DID dropdown options ('F190 VIN', …).
fn merge_did_opts() []string {
	mut o := ['pick…']
	for d in known_dids {
		o << '${d[0]} ${d[1]}'
	}
	return o
}

// raw_msg_opt is the message-select option for a raw (no-DBC) sender.
const raw_msg_opt = '(raw id/data)'

// sender_flat returns the index of (ci, si) in the flattened App.senders list, or
// -1. fire_sender works off that flat index.
fn sender_flat(app &App, ci int, si int) int {
	for k, sr in app.senders {
		if sr.ch_idx == ci && sr.sidx == si {
			return k
		}
	}
	return -1
}

// generators_panel is the interactive-generator surface (conventional tooling IG-style): senders
// grouped by channel, each a clickable button that transmits its frame plus an
// inline editor (name/key/trigger/cycle + DBC message & signal values, or a raw
// id/data). Add/remove senders here; Save writes them back to the project `.yml`.
// Hotkeys work app-wide (see handle_hotkey) whether or not this panel is open.
fn generators_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	mut rows := []gui.View{}
	// Header: title + Save (persists the edited senders to the project file).
	rows << gui.row(
		v_align: .middle
		sizing:  gui.fill_fit
		spacing: 8
		content: [
			gui.text(text: 'Interactive generators', text_style: gui.theme().b3),
			gui.button(
				id_focus:  0
				max_width: sc(70)
				h_align:      .center
				content:   [gui.text(text: 'Save')]
				on_click:  fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					do_save_project(mut w)
				}
			),
		]
	)
	rows << gui.text(
		text:       'click ▸ or press its key to transmit (▶ Start first); … edits, × removes'
		text_style: trace_text_style()
	)
	mut focus := u32(2000) // unique id_focus base per editable widget (stride below)
	for ci, ch in app.proj.channels {
		// Channel header + Add button.
		rows << gui.row(
			v_align: .middle
			sizing:  gui.fill_fit
			spacing: 6
			padding: scpad(6, 0, 1, 0)
			content: [
				gui.text(text: ch.name, text_style: gui.theme().b4),
				gui.button(
					id_focus:  0
					max_width: sc(60)
					h_align:      .center
					content:   [gui.text(text: '＋ Add')]
					on_click:  fn [ci] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
						add_sender(ci, mut w)
					}
				),
			]
		)
		for si, s in ch.senders {
			ekey := '${ci}:${si}'
			editing := app.gen_edit[ekey]
			flat := sender_flat(app, ci, si)
			frame := app.build_sender_frame(s)
			mut tags := ['0x${frame.id:X}']
			if s.trigger == 'cyclic' && s.cycle_ms > 0 {
				tags << 'every ${s.cycle_ms}ms'
			} else {
				tags << s.trigger
			}
			key_label := if s.key != '' { '  [${s.key}]' } else { '' }
			// Row: fire button · edit toggle · remove.
			rows << gui.row(
				v_align: .middle
				spacing: 4
				padding: scpad(0, 0, 0, 8)
				content: [
					gui.button(
						id_focus:  0
						min_width: sc(180)
						max_width: sc(230)
						h_align:   .left
						content:   [gui.text(text: '▸ ${s.name}${key_label}')]
						on_click:  fn [flat] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							fire_sender(flat, mut w)
							w.set_id_focus(0)
						}
					),
					gui.button(
						id_focus:  0
						max_width: sc(30)
						h_align:      .center
						content:   [gui.text(text: if editing { '▾' } else { '…' })]
						on_click:  fn [ekey] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							a.gen_edit[ekey] = !a.gen_edit[ekey]
						}
					),
					gui.button(
						id_focus:  0
						max_width: sc(30)
						h_align:      .center
						content:   [gui.text(text: '×')]
						on_click:  fn [ci, si] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							remove_sender(ci, si, mut w)
						}
					),
				]
			)
			rows << gui.text(text: '    ${tags.join(' · ')}', text_style: trace_text_style())
			if editing {
				rows << sender_editor(app, mut window, ci, si, s, focus)
			}
			focus += 40 // reserve a unique id_focus block per sender (editor uses focus..+~30)
		}
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         3
		id_scroll:       id_scroll_gen
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
	)
}

// sender_editor renders the inline editor for one sender: name, key, trigger,
// cycle_ms (cyclic only), the DBC message (or raw), and the per-signal values
// (message-based) or the id + hex data (raw). `focus` is the unique id_focus base.
fn sender_editor(app &App, mut window gui.Window, ci int, si int, s project.Sender, focus u32) gui.View {
	mut ed := []gui.View{}
	lbl := gui.theme().n4
	// name + key.
	ed << gui.row(
		v_align: .middle
		spacing: 4
		content: [
			gui.text(text: 'name', text_style: lbl),
			gui.input(
				id_focus:        focus + 0
				text:            s.name
				width:           sc(150)
				height:          sc(22)
				sizing:          gui.fixed_fixed
				padding:         scpad(2, 5, 2, 5)
				on_text_changed: fn [ci, si] (_ &gui.Layout, v string, mut w gui.Window) {
					set_sender_name(ci, si, v, mut w)
				}
			),
			gui.text(text: 'key', text_style: lbl),
			gui.input(
				id_focus:        focus + 1
				text:            s.key
				width:           sc(34)
				height:          sc(22)
				sizing:          gui.fixed_fixed
				padding:         scpad(2, 5, 2, 5)
				on_text_changed: fn [ci, si] (_ &gui.Layout, v string, mut w gui.Window) {
					set_sender_key(ci, si, v, mut w)
				}
			),
		]
	)
	// trigger + cycle_ms.
	mut trig_row := [
		gui.View(gui.text(text: 'trigger', text_style: lbl)),
		window.select(
			id:        'gentrig_${ci}_${si}'
			id_focus:  focus + 2
			select:    [s.trigger]
			options:   ['manual', 'key', 'cyclic']
			min_width: sc(84)
			max_width: sc(100)
			on_select: fn [ci, si] (sel []string, mut _ gui.Event, mut w gui.Window) {
				if sel.len > 0 {
					set_sender_trigger(ci, si, sel[0], mut w)
				}
			}
		),
	]
	if s.trigger == 'cyclic' {
		trig_row << gui.text(text: 'ms', text_style: lbl)
		trig_row << gui.input(
			id_focus:        focus + 3
			text:            '${s.cycle_ms}'
			width:           sc(54)
			height:          sc(22)
			sizing:          gui.fixed_fixed
			padding:         scpad(2, 5, 2, 5)
			on_text_changed: fn [ci, si] (_ &gui.Layout, v string, mut w gui.Window) {
				set_sender_cycle(ci, si, v.int(), mut w)
			}
		)
	}
	ed << gui.row(v_align: .middle, spacing: 4, content: trig_row)
	// message select: raw or any DBC message.
	mut msg_opts := [raw_msg_opt]
	for m in app.db.messages {
		msg_opts << m.name
	}
	cur_msg := if s.message != '' { s.message } else { raw_msg_opt }
	ed << gui.row(
		v_align: .middle
		spacing: 4
		content: [
			gui.text(text: 'msg', text_style: lbl),
			window.select(
				id:        'genmsg_${ci}_${si}'
				id_focus:  focus + 4
				select:    [cur_msg]
				options:   msg_opts
				min_width: sc(130)
				max_width: sc(180)
				on_select: fn [ci, si] (sel []string, mut _ gui.Event, mut w gui.Window) {
					if sel.len > 0 {
						set_sender_message(ci, si, sel[0], mut w)
					}
				}
			),
		]
	)
	// Per-signal value inputs (message-based) OR id + data (raw).
	if s.message != '' && app.db.messages.any(it.name == s.message) {
		msg := app.db.messages.filter(it.name == s.message)[0]
		mut fx := u32(6)
		for sig in msg.signals {
			cur := sender_sig_value(s, sig.name)
			signame := sig.name
			unit := if sig.unit != '' { ' ${sig.unit}' } else { '' }
			ed << gui.row(
				v_align: .middle
				spacing: 4
				padding: scpad(0, 0, 0, 8)
				content: [
					gui.text(text: signame, text_style: gui.theme().b4, min_width: sc(100)),
					gui.input(
						id_focus:        focus + fx
						text:            gnum(cur)
						width:           sc(70)
						height:          sc(22)
						sizing:          gui.fixed_fixed
						padding:         scpad(2, 5, 2, 5)
						on_text_changed: fn [ci, si, signame] (_ &gui.Layout, v string, mut w gui.Window) {
							set_sender_signal(ci, si, signame, v.f64(), mut w)
						}
					),
					gui.text(text: unit, text_style: lbl),
				]
			)
			fx++
		}
	} else {
		ed << gui.row(
			v_align: .middle
			spacing: 4
			content: [
				gui.text(text: 'id', text_style: lbl),
				gui.input(
					id_focus:        focus + 6
					text:            '${s.id:X}'
					width:           sc(70)
					height:          sc(22)
					sizing:          gui.fixed_fixed
					padding:         scpad(2, 5, 2, 5)
					placeholder:     'hex'
					on_text_changed: fn [ci, si] (_ &gui.Layout, v string, mut w gui.Window) {
						set_sender_id(ci, si, parse_hex_u32(v), mut w)
					}
				),
				gui.text(text: 'data', text_style: lbl),
				gui.input(
					id_focus:        focus + 7
					text:            hex(s.data)
					width:           sc(150)
					height:          sc(22)
					sizing:          gui.fixed_fixed
					padding:         scpad(2, 5, 2, 5)
					placeholder:     'hex bytes'
					on_text_changed: fn [ci, si] (_ &gui.Layout, v string, mut w gui.Window) {
						set_sender_data(ci, si, v, mut w)
					}
				),
			]
		)
	}
	return gui.column(
		sizing:  gui.fill_fit
		spacing: 3
		padding: scpad(2, 4, 4, 16)
		content: ed
	)
}

// sender_sig_value returns the configured value for a sender's signal, or 0.
fn sender_sig_value(s project.Sender, name string) f64 {
	for sg in s.signals {
		if sg.name == name {
			return sg.value
		}
	}
	return 0.0
}

// port_or_none parses a strict TCP/UDP port (all-digits, 1..65535), else none —
// so a non-numeric / out-of-range suffix isn't silently treated as a port.
fn port_or_none(s string) ?int {
	t := s.trim_space()
	if t == '' {
		return none
	}
	for c in t {
		if c < `0` || c > `9` {
			return none
		}
	}
	p := t.int()
	if p < 1 || p > 65535 {
		return none
	}
	return p
}

// split_host_port parses "host", "host:port", or "[ipv6]:port" into (host, port),
// defaulting the port to 13400. A malformed suffix (bad/out-of-range port) is kept
// whole as the host so it fails visibly on connect — matching the project endpoint
// parser — rather than silently truncating the host and probing a different ECU.
fn split_host_port(s string) (string, int) {
	t := s.trim_space()
	if t.starts_with('[') {
		if end := t.index(']') {
			host := t[1..end]
			after := t[end + 1..]
			if after == '' {
				return host, 13400
			}
			if after.starts_with(':') {
				if p := port_or_none(after[1..]) {
					return host, p
				}
			}
			return t, 13400 // malformed suffix → keep whole, fail visibly
		}
		return t, 13400
	}
	if t.count(':') == 1 {
		i := t.index(':') or { -1 }
		if p := port_or_none(t[i + 1..]) {
			return t[..i], p
		}
		return t, 13400 // bad port → keep whole, fail visibly
	}
	return t, 13400
}

// doip_discover scans for DoIP entities — every running DoIP channel's endpoint
// plus an optional manually-typed host[:port] — by sending UDP vehicle-id requests
// on a worker thread, then posts the announcements to the panel. (Unicast probes,
// which work on the loopback "subnet" and against a known gateway IP.)
fn doip_discover(mut w gui.Window) {
	mut app := w.state[App]()
	// Bump the scan generation (UI thread) and capture it; the worker's result is
	// only applied if this is still the current scan (not superseded by another
	// scan / Stop / project load).
	app.doip_scan_gen++
	gen := app.doip_scan_gen
	mut probes := []DiscoveredEntity{}
	for i, ch in app.proj.channels {
		if ch.is_doip() && app.rt[i].running {
			host, port := ch.doip_endpoint()
			probes << DiscoveredEntity{
				host:   host
				port:   port
				ch_idx: i
			}
		}
	}
	manual := app.doip_scan_host.trim_space()
	spawn fn [probes, manual, gen] (mut w gui.Window) {
		mut targets := probes.clone()
		if manual != '' {
			h, p := split_host_port(manual)
			targets << DiscoveredEntity{
				host:   h
				port:   p
				ch_idx: -1
			}
		}
		mut found := []DiscoveredEntity{}
		for t in targets {
			info := doip.discover(t.host, t.port, 800) or { continue }
			found << DiscoveredEntity{
				host:    t.host
				port:    t.port
				vin:     info.vin
				logical: info.logical_address
				eid:     info.eid
				ch_idx:  t.ch_idx
			}
		}
		w.queue_command(fn [found, gen] (mut w gui.Window) {
			mut a := w.state[App]()
			// Drop results from a superseded scan (Stop / load / newer scan bumped gen).
			if gen != a.doip_scan_gen {
				return
			}
			a.doip_entities = found
			a.notify(.info, 'DoIP discover: ${found.len} entit${if found.len == 1 { 'y' } else { 'ies' }} found')
			w.update_window()
		})
	}(mut w)
}

// use_doip_entity points the Diagnostics panel at a discovered entity: its
// announced logical address becomes the ECU target (tester address from the
// matching channel, or the DoIP default for a manually-probed host).
fn use_doip_entity(e DiscoveredEntity, mut w gui.Window) {
	mut a := w.state[App]()
	tester := if e.ch_idx >= 0 && e.ch_idx < a.proj.channels.len {
		a.proj.channels[e.ch_idx].tester_addr
	} else {
		u16(0x0E80)
	}
	a.diag_sel = DiagTarget{
		is_doip:     true
		host:        e.host
		port:        e.port
		tester_addr: tester
		ecu_addr:    e.logical
	}
	a.diag_sel_name = e.vin
	a.notify(.info, 'diagnostics target → ${e.vin} @${e.host}:${e.port}')
	w.update_window()
}

// doip_panel is the DoIP discovery surface: scan for entities (vehicle-id UDP),
// list them with VIN / logical address / endpoint, and pick one as the active
// Diagnostics target. Driver-free; works against the simulated network or real HW.
fn doip_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	mut rows := []gui.View{}
	rows << gui.text(text: 'DoIP Discovery', text_style: gui.theme().b3)
	rows << gui.row(
		v_align: .middle
		spacing:  4
		padding:  gui.padding_none
		content:  [
			diag_button(700, 'Discover', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				doip_discover(mut w)
			}),
			gui.input(
				id_focus:        701
				text:            app.doip_scan_host
				width:           sc(160)
				height:          sc(22)
				sizing:          gui.fixed_fixed
				padding:         scpad(2, 6, 2, 6)
				placeholder:     'host[:port] (optional)'
				on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
					mut a := w.state[App]()
					a.doip_scan_host = s
				}
			),
		]
	)
	// Active diagnostics target + an Auto button to drop an explicit selection.
	mut tgt := [gui.View(gui.text(text: 'Target: ${diag_target_label(app)}', text_style: trace_text_style()))]
	if app.diag_sel != none {
		tgt << diag_button(702, 'Auto', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
			mut a := w.state[App]()
			a.diag_sel = none
			a.diag_sel_name = ''
			w.update_window()
		})
	}
	rows << gui.row(v_align: .middle, spacing: 6, padding: gui.padding_none, content: tgt)
	if app.doip_entities.len == 0 {
		rows << gui.text(text: '(press Discover to scan running DoIP entities)', text_style: gui.theme().n4)
	}
	for ei, e in app.doip_entities {
		label := '${e.vin}  0x${e.logical:04X}  ${e.host}:${e.port}'
		rows << gui.row(
			v_align: .middle
			spacing:  6
			padding:  gui.padding_none
			content:  [
				diag_button(u32(710 + ei), 'Use', fn [e] (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					use_doip_entity(e, mut w)
				}),
				gui.text(text: label, text_style: trace_text_style()),
			]
		)
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         4
		id_scroll:       id_scroll_doip
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
	)
}

fn diag_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	mut rows := []gui.View{}
	rows << gui.text(text: 'Diagnostics (UDS)', text_style: gui.theme().b3)
	rows << gui.text(
		text:       diag_target_label(app)
		text_style: trace_text_style()
	)
	rows << gui.row(
		spacing: 4
		padding: gui.padding_none
		content: [
			diag_button(600, 'Session', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				diag_request([u8(0x10), 0x03], 'Session(ext)', mut w)
			}),
			diag_button(601, 'Read VIN', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				diag_request([u8(0x22), 0xF1, 0x90], 'VIN(F190)', mut w)
			}),
			diag_button(602, 'Serial', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				diag_request([u8(0x22), 0xF1, 0x8C], 'Serial(F18C)', mut w)
			}),
		]
	)
	rows << gui.row(
		spacing: 4
		padding: gui.padding_none
		content: [
			diag_button(603, 'SW ver', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				diag_request([u8(0x22), 0xF1, 0x95], 'SWver(F195)', mut w)
			}),
			diag_button(604, 'Tester present', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				diag_request([u8(0x3E), 0x00], 'TesterPresent', mut w)
			}),
		]
	)
	// Free-form RDBI: type a 16-bit DID in hex and read it.
	rows << gui.row(
		v_align: .middle
		spacing: 4
		padding: gui.padding_none
		content: [
			gui.text(text: 'DID', text_style: gui.theme().n4),
			window.select(
				id:        'diagdid'
				id_focus:  612
				select:    ['pick…']
				options:   merge_did_opts()
				min_width: sc(120)
				max_width: sc(150)
				on_select: fn (sel []string, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					if sel.len > 0 && sel[0].len >= 4 && sel[0] != 'pick…' {
						a.diag_did = sel[0].all_before(' ')
					}
				}
			),
			gui.input(
				id_focus:        610
				text:            app.diag_did
				width:           sc(60)
				height:          sc(22)
				padding:         scpad(2, 6, 2, 6)
				sizing:          gui.fixed_fixed
				on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
					mut a := w.state[App]()
					a.diag_did = s
				}
			),
			diag_button(611, 'Read DID', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				a := w.state[App]()
				did := parse_hex_u32(a.diag_did)
				diag_request([u8(0x22), u8(did >> 8), u8(did)], 'RDBI(${a.diag_did})', mut w)
			}),
		]
	)
	for line in app.diag_log {
		rows << gui.text(text: line, text_style: trace_text_style())
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         4
		id_scroll:       id_scroll_diag
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
	)
}

// diag_target_label describes where Diagnostics requests will go, based on the
// first running channel (DoIP entity vs CAN software ISO-TP), so the panel header
// reflects the active carrier.
fn diag_label_for(t DiagTarget) string {
	if t.is_doip {
		return 'tester 0x${t.tester_addr:04X} → ECU 0x${t.ecu_addr:04X}, DoIP @${t.host}:${t.port}'
	}
	return 'tester 0x7E0 → ECU 0x7E8, software ISO-TP'
}

fn diag_target_label(app &App) string {
	if sel := app.diag_sel {
		name := if app.diag_sel_name != '' { '${app.diag_sel_name}: ' } else { '' }
		return '${name}${diag_label_for(sel)}'
	}
	for i, ch in app.proj.channels {
		if app.rt[i].running {
			return diag_label_for(diag_target_for(ch))
		}
	}
	return 'tester 0x7E0 → ECU 0x7E8, software ISO-TP (press ▶ Start)'
}

// diag_button is a small clickable labelled button for the Diagnostics panel
// (left-aligned text — gui.button centered labels render blank, see known_issues).
fn diag_button(focus u32, label string, on_click fn (&gui.Layout, mut gui.Event, mut gui.Window)) gui.View {
	// Snug width capped to the label so the button doesn't stretch its column.
	w := f32(14 + label.len * 6)
	return gui.button(
		id_focus:  focus
		min_width: w
		max_width: w
		h_align:      .center
		content:   [gui.text(text: label, text_style: trace_text_style())]
		padding:   scpad(3, 8, 3, 8)
		on_click:  on_click
	)
}

// script_panel is the Lua scripting console (Phase 10 scripting, Tier 4): pick a
// .lua test script and run it against the LIVE measurement — the script reaches
// the same running buses, simulated ECUs and UDS server the GUI does, so the
// conventional test cases (test()/check/uds:/bus.) run with no GUI knowledge.
// Output (per-test ok/FAIL + log lines + a pass/fail summary) streams into the
// panel. Same scripts run headless via cmd/script (scripts/runtests.sh).
fn script_panel(mut window gui.Window) gui.View {
	app := window.state[App]()
	mut rows := []gui.View{}
	rows << gui.text(text: 'Script (Lua)', text_style: gui.theme().b3)
	rows << gui.text(
		text:       'runs against the live measurement — press ▶ Start first'
		text_style: trace_text_style()
	)
	// Script path + Run.
	rows << gui.row(
		v_align: .middle
		spacing: 4
		padding: gui.padding_none
		content: [
			gui.text(text: 'File', text_style: gui.theme().n4),
			gui.input(
				id_focus:        620
				text:            app.script_path
				width:           sc(260)
				height:          sc(22)
				padding:         scpad(2, 6, 2, 6)
				sizing:          gui.fixed_fixed
				on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
					mut a := w.state[App]()
					a.script_path = s
				}
			),
			diag_button(621, if app.script_running { 'Running…' } else { '▶ Run' },
				fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				a := w.state[App]()
				if !a.script_running {
					run_script(a.script_path, mut w)
				}
			}),
		]
	)
	// One-click sample scripts.
	rows << gui.row(
		spacing: 4
		padding: gui.padding_none
		content: [
			diag_button(622, 'diag_basic.lua', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				a.script_path = 'tests/diag_basic.lua'
				run_script(a.script_path, mut w)
			}),
			diag_button(623, 'bus_signals.lua', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				a.script_path = 'tests/bus_signals.lua'
				run_script(a.script_path, mut w)
			}),
			diag_button(624, 'Clear', fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				a.script_log = []
			}),
		]
	)
	for line in app.script_log {
		rows << gui.text(text: line, text_style: trace_text_style())
	}
	return gui.column(
		sizing:          gui.fill_fill
		padding:         gui.padding_medium
		spacing:         4
		id_scroll:       id_scroll_script
		scroll_mode:     .vertical_only
		scrollbar_cfg_y: &gui.ScrollbarCfg{
			overflow: .visible
		}
		content:         rows
	)
}

// run_script launches a Lua script on a worker thread against the currently
// running channels (their buses/DBCs/sims). Output is buffered by the Env and
// dumped into the Script panel in one queue_command when the run finishes —
// avoiding the closure-capturing-`w` problem of streaming each line live.
fn run_script(path string, mut w gui.Window) {
	mut app := w.state[App]()
	mut chans := []script.ChanInfo{}
	for i, ch in app.proj.channels {
		if app.rt[i].running {
			db := app.dbs[i] or { candb.Database{} }
			chans << script.ChanInfo{
				name:  ch.name
				iface: ch.iface
				db:    db
			}
		}
	}
	if chans.len == 0 {
		script_post(['no running channel — press ▶ Start first'], mut w)
		return
	}
	app.script_running = true
	app.script_log << '── run ${path} ──'
	spawn fn [path, chans] (mut w gui.Window) {
		mut env := script.new_env(chans) or {
			script_post(['script init failed: ${err}'], mut w)
			return
		}
		env.on_output = fn (s string) {} // buffer only; we dump env.log_lines after
		mut errline := ''
		env.run_file(path) or { errline = 'ERROR: ${err}' }
		mut lines := env.log_lines.clone()
		if errline != '' {
			lines << errline
		}
		lines << '— ${env.passed()} passed, ${env.failed()} failed —'
		env.close()
		script_post(lines, mut w)
	}(mut w)
}

// script_post appends lines to the Script panel log (bounded) and clears the
// busy flag, on the UI thread.
fn script_post(lines []string, mut w gui.Window) {
	w.queue_command(fn [lines] (mut w gui.Window) {
		mut a := w.state[App]()
		for ln in lines {
			a.script_log << ln
		}
		if a.script_log.len > 500 {
			a.script_log = a.script_log[a.script_log.len - 400..].clone()
		}
		a.script_running = false
		w.update_window()
	})
}

fn do_send(mut w gui.Window) {
	mut app := w.state[App]()
	// Transmit on the SELECTED bus (App.send_ch, a channel name) if its bus is open,
	// else the first running channel.
	mut idx := -1
	for i in 0 .. app.rt.len {
		if !(app.rt[i].running && app.rt[i].bus != none) {
			continue
		}
		chname := if i < app.proj.channels.len { app.proj.channels[i].name } else { '' }
		if app.send_ch == '' || app.send_ch == chname {
			idx = i
			break
		}
	}
	if idx < 0 {
		app.notify(.warn, if app.send_ch != '' {
			'bus "${app.send_ch}" is not running — press ▶ Start'
		} else {
			'not running — press ▶ Start to send'
		})
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
		app.notify(.error, 'send failed: ${err}')
		return
	}
	app.rt[idx].tx_count++
	ch := if idx < app.proj.channels.len { app.proj.channels[idx].name } else { 'CAN${idx + 1}' }
	app.push('TX', frame, ch)
}

// toggle_record starts/stops capturing every frame. On stop it writes the
// captured stream to a timestamped candump `.log` (canlog format) in the cwd and
// reports the path. Recording is uncapped (unlike the 1000-frame display trace).
fn toggle_record(mut w gui.Window) {
	mut app := w.state[App]()
	if app.recording {
		app.recording = false
		entries := app.record_entries
		if entries.len == 0 {
			app.notify(.warn, 'recording stopped — no frames captured')
			return
		}
		t := time.now()
		path := 'blobly_net-${t.year}${t.month:02}${t.day:02}-${t.hour:02}${t.minute:02}${t.second:02}.log'
		mut lines := []string{}
		for e in entries {
			lines << canlog.format_line(e)
		}
		os.write_file(path, lines.join('\n') + '\n') or {
			app.notify(.error, 'record save failed: ${err}')
			return
		}
		app.notify(.info, 'recorded ${entries.len} frames → ${path}')
	} else {
		app.record_entries = []canlog.LogEntry{}
		app.recording = true
		app.notify(.info, 'recording…')
	}
}

// load_log opens a candump `.log` (or an MF4 recording, parsed natively) and
// shows it as a static capture: live RX is paused and the trace is reset so the
// recording stands alone, with each frame stamped by its recorded timestamp. The
// grouped view keeps every unique ID + count; the chronological view shows the
// tail (max_trace cap).
fn load_log(path string, mut w gui.Window) {
	mut app := w.state[App]()
	p := path.trim_space()
	if p.len == 0 {
		app.notify(.warn, 'no file picker here — type a log/mf4 path and press Enter')
		return
	}
	entries := load_entries(p) or {
		app.notify(.error, 'open failed: ${err}')
		return
	}
	app.paused = true
	app.log_path = p
	app.trace = []TraceRow{}
	app.grouped = map[string]MsgAgg{}
	app.order = []string{}
	app.expanded = map[string]bool{}
	app.expanded2 = map[string]bool{}
	app.plot_hist = map[u64][]PlotSample{}
	app.reset_plot() // drop the graph watch list + decode cache (else a new recording with
	// the same pinned IDs / sample counts reuses the previous capture's decoded series)
	app.sel_id = -1
	app.rx_count = 0
	app.tx_count = 0
	app.seq = 0
	// candump stamps absolute epoch seconds; show times relative to the first
	// frame so the Time(ms) column reads 0, 100, 200… not a huge epoch value.
	t0_log := if entries.len > 0 { entries[0].t_s } else { 0.0 }
	for e in entries {
		app.record('RX', e.frame, (e.t_s - t0_log) * 1000.0, e.iface)
	}
	app.notify(.info, 'loaded ${entries.len} frames from ${os.base(p)} (paused — Resume for live)')
	w.update_window()
}

// load_entries reads a recording into the common []canlog.LogEntry stream:
// ASAM MF4 natively via modules/mf4 (DZ-compressed + VLSD CAN-FD, no Python),
// anything else as a candump `.log` via canlog. Shared by the toolbar Open
// Log action (direct-to-trace) and replay channels (onto the bus).
fn load_entries(path string) ![]canlog.LogEntry {
	if path.to_lower().ends_with('.mf4') {
		return mf4.load_file(path)
	}
	return canlog.load_file(path)
}

fn trace_cell_format(row gui.GridRow, _ int, col gui.GridColumnCfg, value string, mut w gui.Window) gui.GridCellFormat {
	if col.id == 'dir' && value == 'TX' {
		return gui.GridCellFormat{
			has_text_color: true
			text_color:     gui.Color{210, 140, 30, 255} // TX: amber (readable on white)
		}
	}
	// conventional "repeat" greying on the Data cell: a frame whose payload is
	// byte-identical to the previous instance of its ID is dimmed to grey;
	// changing frames keep the normal text colour. (Grouped rows id as the group
	// key 'id|ch|dir'; chronological rows as 'seq:id'.)
	if col.id == 'data' && value.len > 0 {
		mut a := w.state[App]()
		mut is_repeat := false
		if row.id.contains('|') {
			agg := a.grouped[row.id] or { return gui.GridCellFormat{} }
			is_repeat = agg.repeat
		} else if row.id.contains(':') {
			seq := row.id.all_before(':').int()
			if a.trace.len > 0 {
				ix := seq - a.trace[0].seq
				if ix >= 0 && ix < a.trace.len {
					is_repeat = a.trace[ix].changed == 0
				}
			}
		}
		if is_repeat {
			return gui.GridCellFormat{
				has_text_color: true
				text_color:     if a.dark {
					gui.Color{120, 120, 120, 255}
				} else {
					gui.Color{160, 160, 160, 255}
				}
			}
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
		max_width: sc(4000)
	}
}

// trace_text_style is a compact font for the dense trace grid.
// trace_text_style is the dense trace font. n4 already == size_text_small, so it
// tracks the ui_size_small knob automatically — no literal size override.
fn trace_text_style() gui.TextStyle {
	return gui.theme().n4
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

// hex_crop renders payload bytes, truncating after max_bytes with a "+N" tail so
// long CAN-FD frames stay inside the Data column instead of overflowing it.
fn hex_crop(data []u8, max_bytes int) string {
	if data.len <= max_bytes {
		return hex(data)
	}
	return hex(data[..max_bytes]) + ' …+${data.len - max_bytes}'
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
