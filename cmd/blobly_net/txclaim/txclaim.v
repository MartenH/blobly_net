module txclaim

// WHO OWNS THE HEALTH READER FOR A WIRE, AND WHEN IS IT RELEASED?
//
// A transmit-only wire gets one reader (#142). Deciding when to start one, when a reader may let
// go, and when a wire should stop being retried is a small piece of shared bookkeeping between a
// supervisor and its readers — and it was written inline, among the driver calls, where nothing
// tests it. THREE CONSECUTIVE REVIEW ROUNDS then found a defect in the previous round's fix, every
// one of them in this bookkeeping and none in the reading itself:
//
//   - a marker the supervisor owned could not be cleared by the reader that knew it was stale, so
//     a wire whose tap came back was skipped for the rest of the run;
//   - retiring a wire on the first hard error confused a LIFECYCLE close (a tap dropped by
//     drop_unwanted_taps the instant after the handle was taken) with a dead adapter;
//   - the markers outlived the run they described, so an adapter repaired between a Stop and a
//     Start stayed unwatched forever;
//   - and clearing them at Start let a reader from the OLD generation delete the NEW
//     supervisor's claim, after which a second reader was started on the same tap.
//
// That is the signature this repo's guide names for stopping the repair loop and covering the
// path instead — the same place ../../vectorcheck/restorerule came from, for the same reason.
// Here it is pure state over plain inputs; the driver calls stay in workers.v.
//
// GENERATION IS PART OF THE IDENTITY, not something a reset has to keep in step. An entry from an
// earlier run is not a claim on this one — which is what makes the Start reset unnecessary rather
// than merely correct — and a release only counts when it comes from the generation that made the
// claim, which is what stops a departing reader erasing its successor's.
//
// AND A FAILURE IS COUNTED, NOT DECISIVE. One hard error cannot tell a dead adapter from a tap
// closed under the reader's feet: a wire may carry several taps, so the one this reader holds can
// go while others stay live and transmitting. Counting separates them without needing to identify
// the handle — a lifecycle close happens once and the wire is read again a second later, while an
// adapter that has gone reaches the limit in about three seconds and is retired with at most that
// many notices, instead of being reopened once a second for the rest of the run.

// max_failures is how many hard receive errors on one wire, within one run, retire it.
pub const max_failures = 3

// Claim is what the ledger knows about one wire.
pub struct Claim {
pub:
	gen      u64 // the run that made it; an entry from another run is not a claim on this one
	held     bool // a reader is running for this wire right now
	failures int // hard receive errors this run, not counting lifecycle closes it cannot see
	retired  bool // failures reached the limit: no more readers for this run
}

// Ledger is the shared state. The caller holds ONE lock around every call.
pub struct Ledger {
pub mut:
	wires map[string]Claim
}

// may_claim reports whether a supervisor of run `gen` should start a reader for this wire.
pub fn (l Ledger) may_claim(wire string, gen u64) bool {
	e := l.wires[wire] or { return true }
	if e.gen != gen {
		return true // a previous run's entry says nothing about this one
	}
	return !e.held && !e.retired
}

// may_claim_now reports whether this wire may be claimed OUTSIDE the supervisor's once-a-second
// pass — that is, whether this is the first time in this run that anybody has watched it.
//
// THE FIRST CLAIM IS URGENT AND A RETRY IS NOT. A wire becomes watchable the instant its transmit
// tap is filed, because that is when a generator can start firing into a controller that may go
// bus-off immediately, and waiting up to a second for the next census can lose that transition
// permanently. But once a reader has run and failed, restarting it immediately buys nothing and
// costs the observation window: with several taps filed on one wire, each could claim the wire a
// failing reader had just released, exhausting the three-failure retirement in a few hundred
// milliseconds during a transient controller reset (codex round 8 on #142). Retries stay on the
// supervisor's clock.
pub fn (l Ledger) may_claim_now(wire string, gen u64) bool {
	e := l.wires[wire] or { return true }
	if e.gen != gen {
		return true // nobody has watched it in THIS run
	}
	return false
}

// claim records that a reader is being started. A wire carried over from an earlier run starts
// with a clean count: the failures belonged to that run's adapter, not to this one's.
pub fn (mut l Ledger) claim(wire string, gen u64) {
	prev := l.wires[wire] or { Claim{} }
	l.wires[wire] = Claim{
		gen: gen
		held: true
		failures: if prev.gen == gen { prev.failures } else { 0 }
	}
}

// release records that a reader has stopped. `failed` means a hard receive error rather than an
// ordinary end (the tap went, or the run did).
//
// IGNORED IF THE CLAIM IS NOT THIS READER'S. A reader still blocked in `recv` across a Stop and a
// Start reaches its release after the new supervisor has claimed the wire, and an unconditional
// delete there hands out a second reader for one tap.
pub fn (mut l Ledger) release(wire string, gen u64, failed bool) {
	e := l.wires[wire] or { return }
	if e.gen != gen || !e.held {
		return
	}
	f := if failed { e.failures + 1 } else { e.failures }
	l.wires[wire] = Claim{
		gen: gen
		held: false
		failures: f
		retired: f >= max_failures
	}
}

// retired reports whether this wire has given up for this run — what the caller says in the Log
// on the failure that reaches the limit, so an operator is told once that the wire is no longer
// watched rather than being told nothing or told every second.
pub fn (l Ledger) retired(wire string, gen u64) bool {
	e := l.wires[wire] or { return false }
	return e.gen == gen && e.retired
}
