module transport

import sync

// silence.v — what each WIRE's transceiver was last told, who tells it, and in what order.
//
// WHY THIS IS NOT A FIELD ON THE BUS. Listen-only at the transceiver is a property of the
// CONTROLLER, not of a handle: `canSetBusOutputControl` and `CAN_SetValue(PCAN_LISTEN_ONLY)` both
// configure the channel, and every handle open on that wire sees the result. Remembering it per
// bus therefore gets two things wrong at once, in opposite directions:
//
//   - TOO MANY WRITES. The app opens each wire several times per Start (a reader, transmit taps,
//     a diagnostics bus), and on Kvaser a mode change must be bracketed by canBusOff/canBusOn —
//     so one operator tick became one bus bounce per handle, each of them dropping traffic, to
//     apply a setting the first one had already applied.
//   - TOO FEW. A handle that is only ever SENT on never reaches its own reconcile, so on a wire
//     with no reader nothing would notice a mark being lifted and the controller stayed silent
//     while `send` reported success.
//
// Keyed by wire and consulted by every entry point instead, both stop being possible.
//
// EMPTY AT PROCESS START, AND THAT IS LOAD-BEARING. The controller's mode outlives the process
// that set it — Kvaser's `canClose` does not reset it (measured; PCAN's `CAN_Uninitialize` does) —
// so a run that ended while a wire was marked leaves the next one opening a channel that is
// already silent, with no mark to say so. An empty table means the first attempt on every wire
// ALWAYS reaches the driver, whatever the answer.
//
// AND WHAT THE DRIVER RESETS, THE TABLE MUST FORGET. The reverse of that case is just as wrong:
// PCAN's close DOES reset the mode, so a record surviving it would let the next open skip a write
// the controller needs, and hand back an acknowledging channel for a row that is still marked
// (codex round 1 on #219). `forget_wire_silence` is what a backend whose close resets the
// controller must call.

struct SilenceApplied {
mut:
	mu    sync.Mutex
	wires map[string]bool
	// One mutex per wire, so a transition can be held across the driver call without a
	// process-wide lock being held across I/O — see apply_silence.
	locks map[string]&sync.Mutex
	// Wires whose controller REFUSED the mode the policy asks for — see wire_silence_fault.
	faults map[string]SilenceFault
}

// silence_applied is process-wide for the reason listen_tbl is: the side that decides and the
// sides that carry it out are several call chains apart, and a pointer threaded between them
// would have to reach every backend's open.
__global silence_applied = &SilenceApplied{}

// wire_silence_lock returns the mutex that serialises transitions on one wire, creating it on
// first use. The registry lock is held only for the lookup, never across the driver call.
fn wire_silence_lock(k string) &sync.Mutex {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	if m := silence_applied.locks[k] {
		return m
	}
	m := sync.new_mutex()
	silence_applied.locks[k] = m
	return m
}

fn recorded_silence(k string) ?bool {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	return silence_applied.wires[k] or { return none }
}

fn record_silence(k string, silent bool) {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	silence_applied.wires[k] = silent
}

fn unrecord_silence(k string) {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	silence_applied.wires.delete(k)
}

// apply_silence brings this wire's controller to `want`, calling `set` only when the wire is not
// already known to be there. `set` answers 0 for success, and anything else is reported as it is.
//
// SERIALISED PER WIRE, ACROSS THE DRIVER CALL, and that is the point of the second map. Publishing
// the requested state and then doing the I/O unlocked lets two opposite transitions finish in the
// wrong order: mark on, mark off again while the first write is still in flight, and the table
// ends up recording `true` while the `false` write is the one that actually landed last — after
// which every later attempt to silence the wire is suppressed as redundant, and the controller
// acknowledges indefinitely (codex round 1 on #219). Holding the wire's own lock makes the record
// and the controller agree by construction.
//
// It is deliberately NOT the process-wide lock: #211 tracks what holding one of those across I/O
// costs, and there is nothing to be gained by making two different wires wait for each other.
//
// A FAILURE MAKES THE WIRE UNKNOWN rather than restoring the previous value, because a refused
// reconfiguration leaves the controller in a state nobody measured. Unknown is the honest record
// and also the useful one: the next attempt writes instead of comparing against a guess.
pub fn apply_silence(iface string, want bool, set fn (bool) int) ! {
	apply_silence_explained(iface, want, set, generic_silence_reason)!
}

// apply_silence_explained is apply_silence with the backend's own reading of a refused status.
// One rule for every backend — the lock, the record, the fault — and one place a backend may
// differ: what a refusal MEANS.
pub fn apply_silence_explained(iface string, want bool, set fn (bool) int, explain fn (bool, int) SilenceReason) ! {
	apply_silence_impl(iface, want, set, explain, false)!
}

// apply_silence_probe is apply_silence_explained WITHOUT the recorded-state shortcut: the driver is
// asked even when the record says the wire is already where the policy wants it.
//
// For a backend whose controller can be changed behind our back — a CANsub is a REST device that
// another tool can reconfigure, or that reboots — and whose closure therefore reads the device
// before it writes. Called from that backend's poll thread, once per period: the record is what
// makes every OTHER caller free, and the probe is what keeps the record honest (codex round 1 on
// #223: with only the shortcut, the advertised periodic readback never happened once a mode was
// recorded, and an externally re-silenced or re-enabled controller went unnoticed indefinitely).
pub fn apply_silence_probe(iface string, want bool, set fn (bool) int, explain fn (bool, int) SilenceReason) ! {
	apply_silence_impl(iface, want, set, explain, true)!
}

fn apply_silence_impl(iface string, want bool, set fn (bool) int, explain fn (bool, int) SilenceReason, probe bool) ! {
	k := wire_key(iface)
	mut wl := wire_silence_lock(k)
	wl.@lock()
	defer {
		wl.unlock()
	}
	if !probe {
		if have := recorded_silence(k) {
			if have == want {
				return
			}
		}
	}
	st := set(want)
	if st == silence_not_attempted {
		// Nothing was asked of the driver, so nothing is known: not applied, not refused.
		unrecord_silence(k)
		return error('${iface}: listen-only was not applied — the bus is closing or the device could not be reached')
	}
	if st != 0 {
		unrecord_silence(k)
		r := explain(want, st)
		record_silence_fault(k, SilenceFault{
			want:     want
			why:      r.why
			declared: r.declared
		})
		return error(r.why)
	}
	record_silence(k, want)
	clear_silence_fault(k)
}

fn record_silence_fault(k string, f SilenceFault) {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	silence_applied.faults[k] = f
}

fn clear_silence_fault(k string) {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	silence_applied.faults.delete(k)
}

// SilenceFault is a controller that would not do what its row asked.
//
// `want` IS PART OF IT, and leaving it out inverted the diagnosis. A refusal can be in EITHER
// direction: a wire being silenced whose controller keeps acknowledging, or a wire being
// transmit-enabled whose controller will not leave listen-only — and the second is not "still
// acknowledging", it is "nothing this wire sends reaches the bus". Reported as one message, the
// panel described every fault as the first kind and was exactly backwards for half of them
// (codex round 4 on #219).
pub struct SilenceFault {
pub:
	want bool   // what the row asked the controller for
	why  string // the driver's own words
	// DECLARED: the backend is saying "this is how the device works", not "a call failed". A
	// CANsub refusing PHY reconfiguration on a live channel is declared; a Kvaser
	// canSetBusOutputControl returning -13 is not. The distinction is what lets a bench tool
	// report a phase as not applicable for the first and as a failure for the second — without
	// it, any driver hiccup on PCAN or Kvaser would have read as a stated limitation
	// (code-review high on #223).
	declared bool
}

// SilenceReason is what a backend's `explain` returns for a refused driver status: the operator's
// sentence, and whether the refusal is the device's rule rather than a fault.
pub struct SilenceReason {
pub:
	why      string
	declared bool
}

// silence_not_attempted is the status a `set` closure returns when it did NOT reach the driver —
// the bus is closing, or the device could not even be read. apply_silence records nothing for it:
// not an applied mode, and not a fault either, because nothing was refused. The next attempt
// tries again from unknown.
pub const silence_not_attempted = -1_000_000

fn generic_silence_reason(want bool, st int) SilenceReason {
	return SilenceReason{
		why: 'the controller would not be set ${silence_word(want)} (driver status ${st})'
	}
}

// wire_silence_fault reports that this wire's controller REFUSED the mode its row asks for, or
// `none` when it is doing what it was told.
//
// WHY A RECORD AND NOT JUST AN ERROR. The `open` path turns a refusal into a refusal to open, and
// `send` returns it to a caller who can act. Neither reaches the case that matters most: a PASSIVE
// listener never calls send, so on a wire that is only ever RECEIVED from, a mid-run failure to
// silence the controller had no way out at all — the reconcile is best-effort there on purpose,
// because a receive that fails takes the wire's reader down with it and health.v already settles
// that a degraded wire must be degraded and never removed (codex round 3 on #219).
//
// So the failure is recorded rather than discarded, and the Buses panel reads it beside the row.
// It is a FACT about the wire, in the same family as `last RX 45s`: the app said listen-only, the
// controller did not agree, and an operator watching a live vehicle needs to know which of those
// they are looking at. Cleared the moment a later attempt succeeds — every receive retries, so a
// transient refusal disappears on its own.
pub fn wire_silence_fault(iface string) ?SilenceFault {
	k := wire_key(iface)
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	return silence_applied.faults[k] or { return none }
}

// note_silence_applied records a mode this wire's controller was put into by something other than
// apply_silence — an OPEN that set it before the channel joined the bus.
//
// THAT ORDER IS A SAFETY PROPERTY, not an optimisation. Both drivers bring a channel onto the bus
// as part of opening it, so a mode applied afterwards leaves a window, however short, in which a
// row marked listen-only is an ACKNOWLEDGING node on somebody's live vehicle — at a bitrate that
// is a default nobody has confirmed, which is the very thing the silent-by-default rule exists to
// prevent (codex round 1 on #219). So the backends set the mode first and tell the table here.
pub fn note_silence_applied(iface string, silent bool) {
	k := wire_key(iface)
	mut wl := wire_silence_lock(k)
	wl.@lock()
	defer {
		wl.unlock()
	}
	record_silence(k, silent)
	clear_silence_fault(k)
}

// forget_wire_silence drops what this wire is recorded as, so the next attempt reaches the driver.
//
// For a backend whose CLOSE resets the controller — PCAN's `CAN_Uninitialize` does, Kvaser's
// `canClose` does not — because a record that outlives the state it describes is worse than none.
pub fn forget_wire_silence(iface string) {
	k := wire_key(iface)
	mut wl := wire_silence_lock(k)
	wl.@lock()
	defer {
		wl.unlock()
	}
	unrecord_silence(k)
	// AND THE FAULT WITH IT. A fault describes a CONTROLLER that would not do what its row asked;
	// once the driver has reset that controller there is no longer anything for it to describe, and
	// the Buses panel does not ask whether a row is running before it shows one. Left behind, a
	// stopped row went on displaying NOT SILENT about hardware nobody holds, until some later open
	// happened to succeed (codex round 8 on #219).
	clear_silence_fault(k)
}

// forget_silence_claims drops every record, so the next attempt on any wire reaches the driver.
//
// For tests, and for `cmd/silentcheck`, which uses it to make its "the last run ended while this
// wire was marked" phase mean what it says: the controller remembers and a fresh process does not,
// and within one process nothing else reproduces that.
pub fn forget_silence_claims() {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	silence_applied.wires.clear()
	silence_applied.faults.clear()
}

// silence_word is for messages: "listen-only"/"normal" is what an operator recognises, where
// `true` and `false` need the reader to remember which way round the flag runs.
fn silence_word(silent bool) string {
	return if silent { 'listen-only' } else { 'normal' }
}
