// A WIRE NOBODY READS REPORTS ITS FAULT LADDER (#142).
//
// `hstate` advances inside recv and `health()` is polled by rx_loop, which is spawned only for
// monitorable channels — so a generator-target wire, or the retained transmit tap of a disabled
// row (#165), had a bus open and nothing asking it anything. A generator blasting into a shorted
// bus reported `TX failed:` per frame and never the one word that explains them: BUS-OFF.
//
// ASKED ON THE TAP ALREADY OPEN. Nothing here spawns a worker or opens a second handle, which is
// the whole difference from #297 — that PR gave each such wire its own receive reader and spent
// seventeen review rounds on the questions a reader brings with it (who owns the claim, when it
// is released, the handoff, the race between the first transmit and the handle being open)
// before being closed unmerged. None of those questions exists here: the handle is the one the
// frame just went out on, and its lifetime is the tap's.
//
// WHAT THIS CANNOT DO, said rather than hidden. Only the backends whose health() reads the
// driver can answer a wire nobody drains — transport.health_source is that rule, and it is three
// states because "no ladder" and "the ladder needs a reader" want opposite treatment. On a
// needs_reader wire this reports the LIMIT once, and only when a send has actually failed, so an
// operator looking for a cause is told why the ladder is blank instead of reading its silence as
// a healthy bus. On a software bus it says nothing at all, for ever: there are no error counters
// to report and nothing is missing.
module main

import time
import transport
import txhealth

// rung_of maps the transport ladder onto the rule's own.
//
// EXHAUSTIVE, WITH NO `else`, ON PURPOSE. txhealth is dependency-free — CI runs its test without
// `-path modules`, so it cannot name transport.BusHealth — which leaves this the one place the
// two vocabularies meet. V requires a match over an enum to be exhaustive, so a rung added to
// BusHealth and not handled here FAILS THE BUILD. That is a stronger guarantee than any test of
// the mapping could give, and it is why there is no `else` to be tempted by.
fn rung_of(h transport.BusHealth) txhealth.Rung {
	return match h {
		.unknown { txhealth.Rung.unknown }
		.ok { txhealth.Rung.ok }
		.warning { txhealth.Rung.warning }
		.error_passive { txhealth.Rung.error_passive }
		.bus_off { txhealth.Rung.bus_off }
	}
}

// health_of maps back, for the one caller that needs the transport word: health_msg already
// phrases every rung for the Log, including the BUS-OFF diagnosis hints, and a second wording
// here would be the same sentence in two places drifting apart.
fn health_of(r txhealth.Rung) transport.BusHealth {
	return match r {
		.unknown { transport.BusHealth.unknown }
		.ok { transport.BusHealth.ok }
		.warning { transport.BusHealth.warning }
		.error_passive { transport.BusHealth.error_passive }
		.bus_off { transport.BusHealth.bus_off }
	}
}

// tx_health_gate_locked is a wire's gate, created on first use. Caller holds app.mu.
//
// PER WIRE, keyed the way tx_mutex and wiretap's matching are: a fault belongs to the
// CONTROLLER, and `vector:1` and `vector:ch1` are one transceiver. Several taps share a wire
// (`tx_bus_key` includes the channel), so keyed per TAP each would keep its own cadence and its
// own idea of what had been said, and one transition would be narrated once per tap.
fn (mut app App) tx_health_gate_locked(wire string) &txhealth.Gate {
	if g := app.tx_health[wire] {
		return g
	}
	g := &txhealth.Gate{}
	app.tx_health[wire] = g
	return g
}

// wire_reader_owns_locked reports whether somebody else will narrate this wire's ladder.
// Caller holds app.mu.
//
// `monitorable()` ALONE — not `running || spawning`, which is what this asked first and which has
// a window under it. `start()` sets `app.running = true` (run.v:1016) BEFORE it marks any row
// `spawning` (run.v:1056), and a Lua or tool bus that deliberately survives Stop can send in
// between: nothing is marked yet, so the tap read the wire as unowned, and a failed SocketCAN
// send there spent the once-per-run advisory on a channel that was about to be monitored — while
// on a polled wire it could narrate a state the rx_loop then narrated again (codex round 2). The
// same window `load_owner_locked` already documents in trace.v, found the same way.
//
// `monitorable()` is the very predicate `start()` uses to decide which rows get an rx_loop, so a
// row that WILL be read answers true from the moment the project is applied — which closes the
// window by construction rather than by ordering two writes.
//
// AND A DEAD READER STILL HANDS OVER, which is what makes the broader test safe: when an adapter
// stops answering, `rx_loop` retires that wire's rows by disabling them
// (`dest_left_the_run_locked`), and a disabled row is not monitorable — so the tap takes the wire
// back exactly when there is genuinely nobody left to narrate it. A row DISABLED from the start,
// whose transmit tap is retained on purpose (#165), is not monitorable either, which is one of
// the two shapes #142 is about; the other — a generator naming a bare wire — has no row at all.
fn (app &App) wire_reader_owns_locked(wire string) bool {
	for c in app.chans {
		if transport.wire_key(c.iface) == wire && c.monitorable() {
			return true
		}
	}
	return false
}

// note_health asks this tap's wire for its fault ladder and narrates a change.
//
// Called from TapBus.send on BOTH outcomes: a failure asks promptly (something may have just
// changed), a success asks on the slow cadence — which is what catches the `warning` rung, since
// a controller over the warning limit still transmits and so never produces a failure to ask
// about.
//
// THE DRIVER CALL IS NOT UNDER app.mu. SharedHandle.health()'s own comment records what holding
// a lock across it costs — a stalled write froze the Buses row and the toolbar — and app.mu is
// the GUI's global mutex, so holding it across a vendor DLL call would freeze the window. The
// lock is taken twice, briefly: once to claim the cadence slot, once to record what was seen.
//
// IT IS STILL UNDER tx_mu, because send holds that for its whole body, so a status call does
// delay the next sender ON THIS WIRE. Deliberate and cheap: the calls are CAN_GetStatus,
// canReadStatus or a field read, microseconds each, against the 200 ms this same lock is already
// held for while send_waiting_for_room waits out a full transmit queue. Taking it outside would
// mean restructuring send's lock, on the hot path, for a hundredth of what the path already
// spends — and the lock order (tx_mu then app.mu) is the one send already establishes through
// note_emit, so following it is what keeps this deadlock-free.
// `mut t` FOR THE INTERFACE CALL, not to mutate the tap. transport.Bus.health() is a mut method
// — a vendor backend caches the chip state it last read — so `t.inner.health()` needs a mutable
// receiver and nothing on TapBus itself is written here. Worth stating because this compiles with
// an immutable receiver on Linux, where `inner` resolves to a concrete SocketCAN bus, and fails on
// the Windows target where it does not: the `-os windows -check` cross-compile in CLAUDE.md is
// what caught it, in seconds, for a ten-minute CI round trip.
// reached_the_driver reports whether a failed send is evidence ABOUT THE CONTROLLER.
//
// A refusal that never touched the wire says nothing about the bus: a listen-only mark and a
// frame no controller could carry are decided in software, above or inside the backend, and the
// transceiver was never asked. Counted as evidence they do real damage — on an unmonitored wire
// the FIRST such refusal spends the once-per-run advisory latch, so the genuine fault that
// follows says nothing at all, and on a polled wire it pins the gate to the 200 ms failure
// cadence for a wire that is perfectly healthy (code-review high).
//
// WHY NOT `err is transport.NotWritten`, which is exactly this concept and already exists:
// because its own comment lists "a listen-only mark" and "a frame the wire cannot carry" among
// its cases and the CODE does not return it for either — only shared.v's "bus is not open yet"
// and one CANsub refusal construct one. Widening it is the right end state and is NOT done here:
// the hub reads that type to decide whether a pending echo entry stays matchable, so changing
// which refusals carry it changes the echo matcher on a path with a great deal of history, and
// that belongs in its own change with its own review. Until then this asks the two pure
// predicates the backends themselves ask, which is a duplication named rather than hidden.
fn (t &TapBus) reached_the_driver(err IError, wire transport.CanFrame) bool {
	// WHAT THE BACKEND ITSELF SAID, first and cheapest. `NotWritten` IS this concept — "a send
	// that was never attempted" — and where a driver returns it there is nothing to infer.
	if err is transport.NotWritten {
		return false
	}
	if transport.wire_policy(t.iface).silent {
		return false // SilentBus refused it; the transceiver never saw a thing
	}
	// THE FRAME RULES OF THIS WIRE'S OWN TIER. `frame_send_refusal` is the impossible-frame set
	// that every backend shares; the VENDOR backends additionally refuse a length rather than
	// clamping it, and that whole tier is `frame_shape_error` (frame_rules.v names it as such).
	// Asking the shared set alone read a PCAN/Kvaser/Vector length refusal as a fault of the
	// controller, which polled a healthy wire and could narrate `bus ok` at it (codex).
	//
	// `vendor_iface` is $if windows, which is exactly right here and not a platform bug: on Linux
	// `vector:1` opens as SocketCAN, which CLAMPS an over-wide length instead of refusing it, so
	// the shared set really is the whole of that wire's tier.
	refusal := if transport.vendor_iface(t.iface) {
		transport.frame_shape_error(wire)
	} else {
		transport.frame_send_refusal(wire)
	}
	if _ := refusal {
		return false
	}
	return true
}

// WHAT IS STILL NOT COVERED, and why it is not guessed at. A vendor backend also refuses on
// CHANNEL properties — an FD frame on a channel opened classic, a Vector port opened `,silent` —
// and `frame_rules.v` says in as many words that those belong to the backend and not to the
// shared rules, because only the backend knows how its channel was opened. A tap cannot ask them
// without keeping its own copy of each backend's open state, which is the per-backend duplication
// this repo already refuses.
//
// The complete answer is `NotWritten` at those sites, which the branch above already reads: its
// own comment lists "a frame the wire cannot carry" and "a listen-only mark" among its cases and
// the code returns it for neither, so widening it makes this path better with no change here.
// Not done in this PR because the hub reads that type to decide whether a pending echo entry
// stays matchable, so it moves echo attribution on a path with a great deal of history and wants
// its own change and its own review. Filed as #350 rather than left as a comment nobody will find.
//
// Until then the residue is small and one-directional: on a vendor wire, a frame refused for a
// CHANNEL reason may prompt one health poll that says something true (`bus ok`) at a moment
// nothing asked about, and on an unmonitored Vector wire it may spend the once-per-run advisory —
// whose text does not depend on the cause, so the operator is told the same true thing either
// way, only earlier.

// NOT DEMONSTRATED ON THIS BENCH, and worth saying so. Neither refusal can be produced on a
// wire that is both unmonitored and SocketCAN: SocketCAN CLAMPS an over-wide id rather than
// refusing it (clamps_to_classic — the refusing tier is the vendor backends), and a listen-only
// mark is published from an ENABLED row, which by definition has a reader and so is suppressed a
// step earlier. The damage this prevents is therefore on vendor hardware: a refused frame shape
// spending the once-per-run advisory latch, and the 200 ms failure cadence pinned to a healthy
// wire. Reasoned from the code and the predicates, not measured — no CI runner has a PCAN.

// note_health_failure is the failure entry point: it decides whether the failure is evidence
// about the controller at all before anything else happens. A refusal that never reached the
// driver is not, and treating it as one is what spends the advisory latch on a healthy wire.
fn (mut t TapBus) note_health_failure(err IError, wire transport.CanFrame) {
	if t.health_src == .no_controller {
		return // the common case, answered without touching wire_policy
	}
	if !t.reached_the_driver(err, wire) {
		return
	}
	t.note_health(.failure)
}

fn (mut t TapBus) note_health(why txhealth.Why) {
	// A SOFTWARE BUS HAS NO LADDER. Checked first and without a lock, because it is the common
	// case — every test, every in-process project, sim-demo entire — and because the answer is a
	// field on the tap rather than a question about the world.
	if t.health_src == .no_controller {
		return
	}
	mut a := unsafe { t.app }
	// Precomputed on the tap: t.iface never changes, so deriving the key here was one string
	// built per send on the one path that is hot enough to care.
	wire := t.health_wire
	if t.health_src == .needs_reader {
		// NOTHING TO ASK, so say why — once per wire per run, and only when a send has failed.
		// Said at Start instead it would be a line about every ordinary SocketCAN generator wire
		// on every run, which is nagging; said here it arrives exactly where an operator is
		// already reading `TX failed:` and wondering what the bus is doing.
		// Nothing to say until a send has actually failed, so the cheap check first.
		if why != .failure {
			return
		}
		a.mu.lock()
		// THE SAME OWNERSHIP QUESTION THE POLLED BRANCH ASKS, and leaving it out was a real
		// defect: on Linux every enabled SocketCAN channel is needs_reader, so a refused frame
		// or a downed link on a perfectly ordinary MONITORED channel produced "cannot be read on
		// a wire nothing monitors — enable this channel" about a channel that is enabled and
		// whose rx_loop is already narrating its ladder (code-review high). The advisory is only
		// ever true of a wire nobody reads.
		owned := a.wire_reader_owns_locked(wire)
		mut gen := u64(0)
		mut first := false
		if !owned {
			gen, first = a.tx_health_claim_locked(wire)
		}
		a.mu.unlock()
		if first {
			notify_gen(a, gen, '${t.iface}: the controller fault ladder cannot be read on a wire nothing monitors — this backend reports it only through frames a reader would drain, so enable this channel to see whether the bus went error-passive or BUS-OFF')
		}
		return
	}
	now := time.ticks()
	a.mu.lock()
	// THE CADENCE FIRST, THEN OWNERSHIP, and the order is a performance decision rather than a
	// semantic one. `wire_reader_owns_locked` walks app.chans rebuilding transport.wire_key per
	// row — the per-frame identity-predicate cost #300 went to some length to remove — while
	// `ask` is one map lookup and an integer compare. Asked first, the walk ran on EVERY send on
	// a polled wire; asked second it runs once a second (code-review high).
	//
	// What it costs: a monitored wire now consumes its own cadence slots, which nothing reads.
	// Harmless — if its reader later dies and this tap takes over, the first poll may be up to
	// one interval late, against a fault that has already lasted that long.
	gen := a.run_gen
	mut ask := false
	if a.running {
		mut g := a.tx_health_gate_locked(wire)
		ask = g.ask(now, why) && !a.wire_reader_owns_locked(wire)
	}
	a.mu.unlock()
	if !ask {
		return
	}
	// OUTSIDE THE LOCK. On PCAN this is CAN_GetStatus, on Kvaser canReadStatus, on a CANsub a
	// read of the verdict its own poll thread keeps current — microseconds each, but through a
	// vendor DLL, and a wire whose driver has wedged must cost its own sender and nobody else.
	seen := rung_of(t.inner.health())
	a.mu.lock()
	mut said := txhealth.Said{}
	// RE-CHECKED under the lock: the run can have ended, or a reader come up, while the driver
	// was being asked. `saw` mutates the gate, so a stale verdict recorded here would make the
	// next run's first real observation look like a repeat and swallow it. Against the SAME
	// generation the cadence slot was claimed under, so a run that turned over in between
	// narrates nothing rather than filing an old wire's verdict under a new run.
	if a.running && a.run_gen == gen && !a.wire_reader_owns_locked(wire) {
		mut g := a.tx_health_gate_locked(wire)
		said = g.saw(seen)
	}
	a.mu.unlock()
	if said.say {
		// health_msg, so a transmit-only wire and a monitored one are narrated in the SAME words
		// — including the BUS-OFF diagnosis hints, which are the whole value of the line at 2am.
		notify_gen(a, gen, health_msg(t.iface, health_of(said.from), health_of(said.to)))
	}
}

// tx_health_claim_locked returns the run to narrate into and whether this wire's limit is still
// unsaid, claiming it if so. Caller holds app.mu.
//
// THE CURRENT RUN, NOT THE TAP'S. A tap's `guard_gen` is 0 for every tap that outlives runs, and
// install_tap opens the SHARED tap that way on purpose — which is the tap a generator naming a
// bare wire (`bus: vcan9`, `bus: pcan:…@250000`) actually sends through, so it is the tap the
// whole of #142 is about. Gating narration on `run_gen == guard_gen` therefore matched nothing in
// exactly the case this feature exists for: measured, 23 failed sends on a down wire and not one
// line, until the run gate was read from the app instead of from the tap.
//
// A wire's fault is a fact about NOW, so the current generation is the right one to file it
// under: a tap surviving into a later run reports that run's faults, and notify_gen's own
// `running && run_gen == gen` check is what drops a line whose run ended while it was being
// composed.
fn (mut app App) tx_health_claim_locked(wire string) (u64, bool) {
	if !app.running {
		return 0, false
	}
	if wire in app.tx_health_noted {
		return app.run_gen, false
	}
	app.tx_health_noted[wire] = true
	return app.run_gen, true
}
