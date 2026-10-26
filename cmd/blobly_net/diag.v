module main

import os
import blobly.transport
import blobly.telem
import blobly.script
import hostrule
import vgui

// ---- Diagnostics (UDS over software ISO-TP, on a worker thread) ----
// (its log: diag_log.v)

// diag_iface_opt is diag_iface, but says when there is no running channel at all.
fn (app &App) diag_iface_opt() ?string {
	iface := app.diag_iface()
	return if iface == '' { none } else { iface }
}

// diag_default_iface is the wire the default 0x7E0/0x7E8 target is on: the first running
// monitored channel in a run, and stopped the first one a run would read (monitorable) — the
// same row whenever its reader opens, so the target keeps its key across Start and Stop.
fn (app &App) diag_default_iface() ?string {
	if app.running {
		return app.diag_iface_opt()
	}
	// stopped: the wire the run's default was on (diag_note_default), while a row still offers
	// it — a first row whose reader failed to open is not where the default was
	if app.diag_default_last != '' && app.chans.any(it.monitorable() && it.iface == app.diag_default_last) {
		return app.diag_default_last
	}
	for c in app.chans {
		if c.monitorable() {
			return c.iface
		}
	}
	return none
}

// diag_note_default records, from the GUI thread during a run, the wire the default target is on,
// for diag_default_iface to keep once stopped.
fn (mut app App) diag_note_default() {
	if app.running {
		if hw := app.diag_iface_opt() {
			app.diag_default_last = hw
		}
	}
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
	label string // the whole name — '<who> · <carrier> <where>  (<address>)' — for the strip and the log
	group string // the selector's heading: '<carrier> · <where>'
	item  string // the selector's line under that heading: '<who>  <address>'
	who   string // the ECU, as `named` was told it
	iface string
	chan  string // the CHANNEL that owns it — an interface cannot say which, when two share one
	rx    u32    // the ECU listens here — the tester TRANSMITS to it
	tx    u32    // the ECU answers here — the tester RECEIVES from it
	ext   bool
	note  string // said under the target selector when it is selected ('' = nothing to say)
	// How to reach it. A DoIP target has no CAN ids at all — it is addressed by the channel's
	// logical pair — so rx/tx above are meaningless for one and the panel must not open an
	// ISO-TP channel for it. Derived by the same carrier_of() the scripting side uses.
	carrier script.Carrier
}

// named gives `t` its three names from what it is: `who` the ECU, `where` the channel (a CAN
// target's with its interface — chan_where) or the DoIP endpoint, the carrier from `t.carrier`, so
// every entry says CAN or DoIP the same way and two targets differ in the words that differ.
fn (t DiagTarget) named(who string, where string) DiagTarget {
	kind := if t.carrier.doip { 'DoIP' } else { 'CAN' }
	addr := if t.carrier.doip {
		'0x${t.carrier.ecu:04X}'
	} else {
		'0x${t.rx:X}→0x${t.tx:X}'
	}
	return DiagTarget{
		...t
		label: '${who} · ${kind} ${where}  (${addr})'
		group: '${kind} · ${where}'
		item:  '${who}  ${addr}'
		who:   who
	}
}

// chan_where is a target's channel as the selector shows it: its name and where it leads (a CAN
// interface, a DoIP endpoint), or that alone where there is no name to add.
fn chan_where(chan string, at string) string {
	return if chan == '' || chan == at { at } else { '${chan} (${at})' }
}

// grouped orders `ts` so each selector heading's targets are together, the headings in the order
// they first appear (a stable regroup: within a heading, the order is the list's).
fn grouped(ts []DiagTarget) []DiagTarget {
	mut heads := []string{}
	for t in ts {
		if t.group !in heads {
			heads << t.group
		}
	}
	mut out := []DiagTarget{cap: ts.len}
	for h in heads {
		out << ts.filter(it.group == h)
	}
	return out
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
	sys_targets := app.diag_sys_targets.clone()
	// the default pair's label says so when a loaded system describes nobody there
	nobody := if app.diag_sys_default_unknown { ' (no ECU described)' } else { '' }
	note := if app.diag_sys_default_unknown {
		'the loaded system describes no ECU on 0x${diag_tx_id:X}/0x${diag_rx_id:X}: a timeout here is expected'
	} else {
		''
	}
	a.mu.unlock()
	mut out := []DiagTarget{}
	// the default target's wire: the running one in a run, the one that will be read once
	// stopped — one key either way, so the selection and what was read under it survive a Stop
	mut dflt := []DiagTarget{}
	if hw := app.diag_default_iface() {
		// named by the channel the wire is, so it heads the selector with the system's targets on it
		mut hw_name := ''
		a.mu.lock()
		for c in app.chans {
			if c.monitorable() && c.iface == hw {
				hw_name = c.name
				break
			}
		}
		a.mu.unlock()
		if !plan.any(it.key == diag_key_can(hw, diag_tx_id, diag_rx_id)) {
			dflt << DiagTarget{
				key:   diag_key_can(hw, diag_tx_id, diag_rx_id)
				note:  note
				iface: hw
				rx:    diag_tx_id
				tx:    diag_rx_id
			}.named('default${nobody}', chan_where(hw_name, hw))
		}
	}
	// first — and so selected first — unless the loaded system says nobody answers there
	if nobody == '' {
		out << dflt
	}
	out << plan
	// the system's nodes on the running channels named after their buses (diag_dtc.v): a bench
	// project addresses real ECUs it simulates nothing for, which no other entry reaches
	for t in sys_targets {
		if !t.carrier.doip && !out.any(it.key == t.key) {
			out << t
		}
	}
	if nobody != '' {
		out << dflt
	}
	// Every enabled DoIP channel is addressable, hosted by us or not. The panel's DoIP support
	// would otherwise reach only entities this application started — while the normal
	// tester-only case, a DoIP channel pointed at a REAL ECU, has no simulated nodes, is not
	// hosted, and never reaches diag_plan at all. That is the case a bench actually uses.
	a.mu.lock()
	rows := app.host_rows_locked()
	a.mu.unlock()
	for pi, c in app.proj.channels {
		if !c.is_doip() {
			continue
		}
		// The LIVE tick, not the load-time value. The Buses checkbox writes app.chans, so a
		// channel switched off stayed selectable and the panel could still reach the external
		// ECU — and one switched on after starting disabled never appeared at all.
		if !hostrule.enabled(rows, pi, c.enabled) { // unstarted: the project's own value
			continue
		}
		if c.hosts_doip_entity() {
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
		// the ECU by the name the system gives the entity at that endpoint, else the channel's
		described := sys_targets.filter(it.carrier.doip && same_entity(it.carrier, car))
		who := if d := described[0] { d.who } else { 'ECU' }
		out << DiagTarget{
			key:     diag_key_doip(c)
			iface:   c.iface
			chan:    c.name // what sysview.node_for settles a shared logical address by
			carrier: car
		}.named(who, chan_where(c.name, '${car.host}:${car.port}'))
	}
	// the system's DoIP entities (diag_dtc.v), where no project channel reaches one: a project
	// need not carry a DoIP channel for an ECU its system.toml says is on the network. One that
	// does decides — ticked off, or hosting an entity whose bind failed, it is skipped above on
	// purpose, and the system's entry must not reach the entity in its place.
	for t in sys_targets {
		if t.carrier.doip && !app.proj.channels.any(it.is_doip()
			&& same_entity(script.carrier_of(it), t.carrier)) && !out.any(it.key == t.key) {
			out << t
		}
	}
	if out.len == 0 {
		out << DiagTarget{
			key:   diag_key_can(app.diag_iface(), diag_tx_id, diag_rx_id)
			note:  note
			iface: app.diag_iface()
			rx:    diag_tx_id
			tx:    diag_rx_id
		}.named('default${nobody}', if app.diag_iface() != '' { app.diag_iface() } else { 'no channel' })
	}
	return grouped(out)
}

// same_entity: two DoIP carriers reach one entity — one endpoint, one logical address. The
// tester address is not part of it: a channel the project configures to that entity is the one
// to use, whatever tester it names. Hosts compare as written: a channel naming the entity by a
// hostname is not matched to the system's address, since resolving it here would be a lookup per
// frame on the GUI thread.
fn same_entity(a script.Carrier, b script.Carrier) bool {
	return a.host.to_lower() == b.host.to_lower() && a.port == b.port && a.ecu == b.ecu
}

fn (mut app App) diag_done() {
	app.mu.lock()
	app.diag_busy = false
	app.mu.unlock()
	vgui.wake()
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
		telem.freeze_full { ' by fill' } // a oneshot that completed on its own (emb#271)
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
	// IS THIS WIRE BEING READ, not "does this row hold the reader". Under one reader per wire a
	// manifest attached to a non-owner alias left that row with running == false, so its
	// manifest was ignored and another destination's channel answered for it — trace commands
	// going to the wrong bus in a multi-bus project.
	//
	// UNDER THE LOCK, taken here. None of the callers (trace_dump_worker, the shell, the flash
	// worker, the panel) hold app.mu, so the scan must take it itself.
	mut a := unsafe { app }
	a.mu.lock()
	i := a.trace_chan_locked(true)
	found := if i >= 0 { a.chans[i].iface } else { '' }
	a.mu.unlock()
	return found
}

// trace_chan_locked picks the row trace commands go out on: the one carrying the manifest the
// trace ids came from, else any row with a manifest, else the first running row. `read` asks
// that the wire be read now (a run); false answers the same question for a stopped project.
// -1 = none. Caller holds app.mu.
fn (app &App) trace_chan_locked(read bool) int {
	for want_ref in [true, false] {
		for i, c in app.chans {
			if !c.monitorable() || c.manifest == '' || (want_ref && c.manifest != app.manifest_ref) {
				continue
			}
			if !read || app.dest_is_read_locked(c.iface) {
				return i
			}
		}
	}
	for i, c in app.chans {
		if c.monitorable() && (c.running || !read) {
			return i
		}
	}
	return -1
}

// trace_target_text names what Record / Stop / Dump address: the node and cores the manifest
// describes, then the channel the commands go out on and the command id.
fn (app &App) trace_target_text() (string, string) {
	mut a := unsafe { app }
	a.mu.lock()
	i := a.trace_chan_locked(a.running)
	chan := if i >= 0 { '${a.chans[i].name} (${a.chans[i].iface})' } else { '' }
	carries := i >= 0 && a.chans[i].manifest == a.manifest_ref
	a.mu.unlock()
	if chan == '' {
		return 'target: none', 'no channel to send the trace commands on'
	}
	node := if !app.has_manifest {
		'whichever node answers the default ids'
	} else if !carries {
		// a fallback route: the loaded manifest describes a node on another channel
		'unknown — this channel does not carry the loaded manifest'
	} else if app.manifest.node != '' {
		app.manifest.node
	} else {
		manifest_owner(app.resolve_asset(app.manifest_ref))
	}
	// the cores Dump addresses: the bits of the mask it sends (0 = the one default core)
	mask := app.trace_core_mask()
	mut cores := []string{}
	for b in 0 .. 16 {
		if mask & (u16(1) << u16(b)) != 0 {
			cores << b.str()
		}
	}
	core_txt := if cores.len > 0 { ', cores ${cores.join(' + ')}' } else { '' }
	cmd := app.manifest.frames.or_defaults().cmd
	return 'target: ${node}${core_txt}', 'on ${chan} · cmd 0x${cmd:03X}'
}

// manifest_owner names a manifest by the folder it was generated for: `<node>/gen/x.csv` ->
// `<node>`, else the folder holding it, else the file name.
fn manifest_owner(ref string) string {
	dir := os.dir(ref)
	owner := if os.file_name(dir) == 'gen' { os.file_name(os.dir(dir)) } else { os.file_name(dir) }
	return if owner in ['', '.'] { os.file_name(ref) } else { owner }
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

