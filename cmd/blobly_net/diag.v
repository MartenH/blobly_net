module main

import transport
import telem
import script
import vgui

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
	rx    u32    // the ECU listens here — the tester TRANSMITS to it
	tx    u32    // the ECU answers here — the tester RECEIVES from it
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
	// UNDER THE LOCK, taken here. The previous version of this comment asserted that callers
	// held app.mu; they do not — trace_dump_worker, the shell and the flash worker all release
	// it before calling, and the panel never takes it. So the scan below ran unlocked against
	// rows an rx_loop was publishing or a toggle was rewriting. None of the callers hold it,
	// which is what makes taking it here safe as well as necessary.
	mut a := unsafe { app }
	a.mu.lock()
	mut found := ''
	for c in a.chans {
		if c.monitorable() && c.manifest != '' && a.dest_is_read_locked(c.iface) {
			found = c.iface
			break
		}
	}
	if found == '' {
		for c in a.chans {
			if c.monitorable() && c.running {
				found = c.iface
				break
			}
		}
	}
	a.mu.unlock()
	return found
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
