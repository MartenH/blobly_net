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

// wire_reader_owns_locked reports whether an rx_loop on this wire is reading it, or about to.
// Caller holds app.mu.
//
// SPAWNING COUNTS. monitors_locked asks for `running` alone, which is right for "where could an
// echo arrive"; here the question is "will somebody else narrate this wire's ladder", and a row
// whose reader is on its way up will. Counting only `running` would narrate from the tap during
// the open window and then again from the reader a moment later — two lines for one fault, which
// an operator reads as two faults. A wire that is genuinely transmit-only has no such row at all,
// so erring towards silence here costs the case #142 is about nothing.
fn (app &App) wire_reader_owns_locked(wire string) bool {
	for c in app.chans {
		if transport.wire_key(c.iface) == wire && c.monitorable() && (c.running || c.spawning) {
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
fn (mut t TapBus) note_health(why txhealth.Why) {
	// A SOFTWARE BUS HAS NO LADDER. Checked first and without a lock, because it is the common
	// case — every test, every in-process project, sim-demo entire — and because the answer is a
	// field on the tap rather than a question about the world.
	if t.health_src == .no_controller {
		return
	}
	mut a := unsafe { t.app }
	wire := transport.wire_key(t.iface)
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
		gen, first := a.tx_health_claim_locked(wire)
		a.mu.unlock()
		if first {
			notify_gen(a, gen, '${t.iface}: the controller fault ladder cannot be read on a wire nothing monitors — this backend reports it only through frames a reader would drain, so enable this channel to see whether the bus went error-passive or BUS-OFF')
		}
		return
	}
	now := time.ticks()
	a.mu.lock()
	// The reader's question first, so a monitored wire never consumes a cadence slot it has no
	// use for: rx_loop already narrates that wire, on the same words.
	owned := a.wire_reader_owns_locked(wire)
	gen := a.run_gen
	mut ask := false
	if !owned && a.running {
		mut g := a.tx_health_gate_locked(wire)
		ask = g.ask(now, why)
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
