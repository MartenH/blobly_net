module taprule

// THE TRANSMIT-TAP LIFECYCLE, AS RULES. Since #257 the taps a run needs open on workers, and
// four decisions follow from that: whether a tap that has just come up is FILED into the run,
// whether a cyclic sender is READY to fire, whether a manual send from a channel may FALL BACK
// to the wire's shared tap, and whether a tap nobody wants any more is DROPPED. #257 took ten
// review rounds, every one a real finding in exactly these decisions, because they lived in
// the GUI where nothing tests them (#260). Here they are pure functions over plain inputs, the
// GUI calls them, and the rounds' scenarios are the test table — the shape ../saverule set
// for Save (#250).

// Run is the run as the rules see it: is a run on, and which generation is current.
pub struct Run {
pub:
	running bool
	gen     u64
}

// file_decision is whether a tap opened for run `opened_for`, keyed `key`, is filed now:
// only into a run still ON, only into the run it was opened for, and only if nobody filed one
// first. Stop drops `running` and empties the taps but leaves the generation — a tap that
// completed after Stop would otherwise land in the emptied map, survive the next Start
// (which sees it and opens no replacement) and refuse every send (#257 rounds 1–2). Not
// filed means closed: the loser must not leak.
pub fn file_decision(run Run, opened_for u64, present bool) bool {
	return run.running && run.gen == opened_for && !present
}

// Taps is what a sender's readiness is decided from: which keys are filed, and which named
// opens have FAILED for good this run. A key is `project.compose_key(chan, iface)`; the
// shared tap of a wire is the key with an empty channel.
pub struct Taps {
pub:
	filed  []string
	failed []string
}

// ready is whether a sender for channel `chan` (empty for none) on `iface` may fire now. A
// sender WITH a channel waits for its OWN tap: the shared tap carries no channel identity, and
// a frame sent through it is filed under the first channel on the wire (#257 rounds 3–4). It
// falls back to the shared tap only once its own is known not to come (round 6) — and an
// existing named tap wins outright, whatever an earlier failure said (round 7). A sender
// without a channel wants the shared tap.
pub fn ready(taps Taps, named string, wire_tap string, has_chan bool) bool {
	if has_chan && named in taps.filed {
		return true
	}
	if has_chan && named !in taps.failed {
		return false
	}
	return wire_tap in taps.filed
}

// Fallback is what a manual send from a channel gets when its own tap is not filed.
pub enum Fallback {
	// send through the wire's shared tap
	via_wire
	// say "still opening" and send nothing — the named tap is neither filed nor failed
	wait
	// no tap at all: "no open bus"
	none_open
}

// fallback is tx_on_chan's rule for a channel whose named tap is absent — the same rule as
// ready(), from the manual side (#257 round 8): the shared tap stands in only when the
// channel's own is known to have failed.
pub fn fallback(taps Taps, named string, wire_tap string, has_chan bool) Fallback {
	if has_chan && named !in taps.failed {
		return .wait
	}
	if wire_tap in taps.filed {
		return .via_wire
	}
	return .none_open
}

// Wants is who still wants a tap once a slow open comes back: which (chan, iface) pairs the
// generators fire on, and which wires an enabled CAN row or a generator uses.
pub struct Wants {
pub:
	pairs []string // named keys the generators fire on
	wires []string // destination keys some row or generator uses
}

// Drop is what drop_unwanted_taps closes after an open for (named, wire) came back.
pub struct Drop {
pub:
	named  bool // the named tap: no generator fires on the pair any more
	wire   bool // the wire's shared tap: no row and no generator uses the wire
}

// drop_decision is decided in ONE step from one snapshot, the way the GUI takes it under one
// hold of its lock — decided in one and acted on in another, a generator retargeted back in
// between found its fresh tap deleted (#257 round 9). An abandoned wire loses its shared tap
// too: on a CANsub that tap is the channel's one WebSocket client (round 9).
pub fn drop_decision(w Wants, named string, wire string) Drop {
	return Drop{
		named:  named !in w.pairs
		wire:   wire !in w.wires
	}
}
