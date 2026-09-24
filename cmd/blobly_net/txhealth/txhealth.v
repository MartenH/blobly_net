// WHEN A WIRE NOBODY READS IS ASKED FOR ITS FAULT LADDER, AND WHEN THE ANSWER IS WORTH SAYING.
//
// A transmit-only wire — a generator's target, the retained tap of a disabled row — has a bus
// open and no rx_loop, so nothing ever called health() on it and a generator blasting into a
// shorted bus reported nothing (#142). The tap can ask, because on the backends whose health()
// reads the driver it needs no frames to have arrived (transport.health_source).
//
// WHY THIS IS A PACKAGE AND NOT SIX LINES IN THE SEND PATH. #297 answered #142 by giving each
// such wire its own receive handle, and ran SEVENTEEN review rounds before being closed
// unmerged: who owns the reader, when the claim is released, the handoff between owners, the
// race between the first transmit and the handle being open. Every one of those questions came
// from creating a worker, and none of them is asked here — nothing is spawned and no second
// handle is opened. What remains is a decision with state, taken on the hot path, shared by
// every tap on one wire, and that is precisely the kind this repo covers with a rule and a test
// rather than patching in place (CLAUDE.md, "when findings repeat in one path, write the test").
//
// DEPENDENCY-FREE ON PURPOSE. CI runs `v test cmd/blobly_net/txhealth/` with no `-path modules`,
// so nothing here may import `transport` — hence Rung below rather than transport.BusHealth. The
// caller maps between them in ONE exhaustive match, which V's compiler checks: a rung added to
// BusHealth and not to that match fails the build, which is a stronger guarantee than a test.
module txhealth

// Rung is the controller fault ladder as this rule compares it. The ORDER is the ladder's, and
// `unknown` is deliberately not on it — see reportable().
pub enum Rung {
	unknown // the backend cannot say, or has not said yet
	ok
	warning
	error_passive
	bus_off
}

// Why is what prompted the question, which is the only thing that changes the cadence.
pub enum Why {
	// A send that FAILED. Evidence that something may have changed, so it is asked promptly —
	// but still bounded, because a bus-off controller fails EVERY frame and a generator at
	// 1 kHz would otherwise make a thousand driver calls a second. That is the exact cost #224
	// removed from an idle PCAN wire, and it must not come back through this door.
	failure
	// A send that SUCCEEDED. The routine cadence: this is what catches the `warning` rung, which
	// no failure ever reports because a warning does not stop a controller transmitting.
	success
}

// poll_success_ms is the cadence on a healthy wire: the same once-a-second a monitor already
// uses (SharedHandle.health's comment says so), which is what makes this cost nothing next to
// what the wire is already doing.
pub const poll_success_ms = i64(1000)

// poll_failure_ms bounds the failing wire. Five driver calls a second at worst — prompt enough
// that an operator sees BUS-OFF in the Log while the generator is still running, and three
// orders of magnitude below the per-frame polling #224 was about.
pub const poll_failure_ms = i64(200)

// interval is the floor between two driver calls for one wire.
pub fn interval(why Why) i64 {
	return match why {
		.failure { poll_failure_ms }
		.success { poll_success_ms }
	}
}

// due reports whether this wire's driver may be asked now. `last_ms` is when it was last asked,
// 0 meaning never — and never is always due, so the first frame on a wire reports its state
// rather than waiting out a cadence it has not started.
//
// NOT `>`: a monotonic clock can return the same millisecond twice, and `>` on a never-asked
// wire whose first send lands at tick 0 would refuse for ever.
pub fn due(last_ms i64, now_ms i64, why Why) bool {
	if last_ms <= 0 {
		return true
	}
	// A CLOCK THAT WENT BACKWARDS is due, not blocked until it catches up. time.ticks() is
	// monotonic, but `last_ms` outlives a run and a run resets its epoch — so a stale value from
	// a previous epoch can sit in the future, and a plain subtraction would then refuse every
	// poll for the length of the difference. Asking once too often costs one driver call.
	if now_ms < last_ms {
		return true
	}
	return now_ms - last_ms >= interval(why)
}

// reportable says whether an observed rung is worth narrating, given the last one narrated for
// this wire.
//
// `unknown` IS NEVER REPORTED, in either position. Reaching it as `to` is the ordinary answer
// from a backend that cannot say — every needs_reader wire, and a polled one whose driver call
// failed — and health_name() renders it as the EMPTY STRING, so narrating it would put
// "can0: bus " in the Log. Reaching it as `from` is the first observation of a wire, which IS
// worth saying: rx_loop reports the first non-unknown state it sees and #265 is the ticket that
// made it, so a tap that went quiet about "bus ok" would be the one inconsistency an operator
// could see between a monitored wire and a transmit-only one.
pub fn reportable(from Rung, to Rung) bool {
	if to == .unknown {
		return false
	}
	return to != from
}

// Gate is ONE WIRE's state, shared by every tap on it.
//
// PER WIRE, NOT PER TAP. `tx_bus_key(chan_name, iface)` means several taps can be open on one
// wire — a channel's own, the shared one, a replay group's — and a controller's fault ladder
// belongs to the CONTROLLER. Held per tap, each would keep its own cadence and its own idea of
// what had been said, so one transition would be narrated once per tap; that is the same
// per-wire-not-per-bus argument silence.v makes about the listen-only mark, and the same fold
// `health` and `last RX` already use.
//
// THE CALLER HOLDS A LOCK. Nothing here is synchronised: a Gate is mutated under the app mutex,
// like the maps beside it. It is a decision, not a container.
pub struct Gate {
pub mut:
	// When this wire's driver was last asked. 0 = never.
	last_ms i64
	// What the last GRANTED ask was for. It is what makes a failure after a success urgent —
	// see ask(). Only a granted ask moves it, which is what bounds the escalation.
	last_why Why
	// The last rung actually NARRATED for this wire — not the last one observed. See saw().
	reported Rung
}

// ask records a poll that is about to happen and reports whether it may go ahead.
//
// ONE CALL, not `due()` then a separate assignment, because the gap between them is a window two
// taps on one wire both walk through: both find the wire due, both call the driver, and the
// cadence this exists to enforce is doubled. Checking and claiming together is the same reason
// `take()` in player/control.v reads and clears in one operation.
pub fn (mut g Gate) ask(now_ms i64, why Why) bool {
	// A FAILURE THAT FOLLOWS A SUCCESS IS ALWAYS URGENT, whatever the cadence says. Without this
	// the feature loses the one case it exists for: a successful send polls `.ok`, the controller
	// goes BUS-OFF, and the very next send fails 10 ms later — inside the 200 ms floor, so the
	// gate refuses, nothing else is scheduled, and if that generator stops (a one-shot, a manual
	// send, a producer that gives up on its first error) the terminal fault is never asked about
	// at all. `TX failed` and nothing else, which is exactly the state #142 describes (codex).
	//
	// IT CANNOT RUN AWAY, and the reason is that a REFUSED ask moves nothing. After one escalated
	// poll `last_why` is `.failure`, so the next failure is back on the 200 ms floor; a success in
	// between is itself refused by the one-second floor and so leaves `last_why` alone. An
	// escalation therefore needs a GRANTED success ask before it, which is at most one a second —
	// so a wire alternating success and failure every frame polls about twice a second, not once
	// per frame. That bound is the whole reason this is an edge and not simply a shorter floor.
	escalate := why == .failure && g.last_why == .success
	if !escalate && !due(g.last_ms, now_ms, why) {
		return false
	}
	g.last_ms = now_ms
	g.last_why = why
	return true
}

// Said is what to narrate about an observation, or nothing.
pub struct Said {
pub:
	say  bool
	from Rung
	to   Rung
}

// saw records an observed rung and reports whether it is news.
//
// `reported` ADVANCES ONLY WHEN WE SPEAK, which is why the field is named for what was said and
// not for what was seen. A polled wire whose driver call fails answers `unknown`, and a bus-off
// wire that answers bus_off, then unknown, then bus_off again is one fault and one Log line —
// but had the unknown been stored, the third observation would differ from it and BUS-OFF would
// be narrated twice for a controller that never recovered. The operator would read the second
// line as a second fault.
pub fn (mut g Gate) saw(to Rung) Said {
	from := g.reported
	if !reportable(from, to) {
		return Said{}
	}
	g.reported = to
	return Said{
		say:  true
		from: from
		to:   to
	}
}

// WHO WILL NARRATE A WIRE'S LADDER — the ownership half, and why it is here.
//
// THREE CONSECUTIVE REVIEW ROUNDS LANDED ON THIS ONE QUESTION, and the third was a defect of the
// second one's fix:
//
//   1. the advisory branch never asked it at all, so a MONITORED SocketCAN channel could be told
//      to "enable this channel" (self-review);
//   2. asking `running || spawning` had a window under it — `start()` publishes the run before it
//      marks any row spawning, so a tool bus sending in between saw an about-to-be-monitored wire
//      as unowned (codex round 2);
//   3. widening it to `monitorable()` alone then claimed an owner FOR EVER on a row whose reader
//      failed its open, because that path clears `running`/`spawning` and leaves the row enabled —
//      so a wire with a dead reader went silent instead of falling back to its tap (codex round 3).
//
// That is precisely the signal CLAUDE.md names: "when consecutive rounds find defects introduced
// by the previous round's fix, and they cluster, the loop is designing an untested path one repair
// at a time: cover that path with a test". This is that test's subject. The cadence rules above
// were covered from the start and have not been touched by a single round.
pub struct RowView {
pub:
	// `monitorable()`: enabled, in a reading mode, not an Ethernet row. THE PREDICATE `start()`
	// ITSELF USES to decide which rows get an rx_loop, which is what closes round 2's window — a
	// row that WILL be read answers true from the moment the project is applied, with no interval
	// in which the answer is wrong.
	monitored bool
	// Its reader tried to open and could not. TERMINAL for the run: that path does not retry, and
	// topology is fixed at Start (#120), so nothing will revive it.
	open_failed bool
}

// wire_owned reports whether any of a wire's rows will narrate its fault ladder, so the tap
// should stay quiet. `rows` is the rows ON THAT WIRE; a wire with none — a generator naming a
// bare address — is owned by nobody, which is the case #142 exists for.
//
// WHY `running` AND `spawning` ARE NOT HERE. They describe how far along a reader is, and the
// question is not that: it is whether one is coming at all. A row that is monitored and has not
// failed will be read, whether or not its thread has got there yet.
//
// WHY A RETIRED ROW NEEDS NO FIELD. A reader that fails MID-RUN retires its wire by disabling
// every alias on it (`dest_left_the_run_locked`), and a disabled row is not monitored — so the
// handover is already expressed. `open_failed` exists only because the OTHER failure path, a
// reader that never opened at all, deliberately leaves the row enabled.
pub fn wire_owned(rows []RowView) bool {
	for r in rows {
		if r.monitored && !r.open_failed {
			return true
		}
	}
	return false
}
