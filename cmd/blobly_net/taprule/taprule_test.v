module taprule

// THE TEN ROUNDS OF #257, AS A TABLE. Each block is one round's scenario; the rule that
// answers it is named. Keys are spelled the way project.compose_key spells them, but the
// rules treat them as opaque strings.

const on = Run{
	running: true
	gen:     7
}

// FILING (rounds 1–2, 5): the run must be on, be the one the tap was opened for, and not
// already hold the key.
fn test_a_tap_is_filed_only_into_the_run_it_was_opened_for_while_that_run_is_on() {
	assert file_decision(on, 7, false)
	// Stop drops `running` and leaves the generation: a tap completing after Stop is not filed.
	assert !file_decision(Run{ running: false, gen: 7 }, 7, false)
	// A new Start moved the generation: a tap from the old run is not filed into the new one.
	assert !file_decision(Run{ running: true, gen: 8 }, 7, false)
	// Somebody filed first: the loser is closed, not stacked.
	assert !file_decision(on, 7, true)
}

// READINESS (rounds 3, 4, 6, 7): a sender with a channel waits for ITS OWN tap, falls back to
// the shared one only once its own is known to have failed, and an existing named tap wins
// whatever an earlier failure said. A sender with no channel wants the shared tap.
fn test_a_cyclic_sender_waits_for_its_own_tap_and_falls_back_only_on_a_terminal_failure() {
	named := 'Gen1|inproc:CAN1'
	wire_tap := '|inproc:CAN1'
	// Round 3: the shared tap is up, the named one still opening — not ready, unstamped.
	assert !ready(Taps{ filed: [wire_tap] }, named, wire_tap, true)
	// Its own tap lands: ready.
	assert ready(Taps{ filed: [wire_tap, named] }, named, wire_tap, true)
	// Round 6: the named open failed for good — the shared tap is the answer.
	assert ready(Taps{ filed: [wire_tap], failed: [named] }, named, wire_tap, true)
	// …but only if the shared one is actually there.
	assert !ready(Taps{ failed: [named] }, named, wire_tap, true)
	// Round 7: a named tap that landed after a failure wins back its sender.
	assert ready(Taps{ filed: [wire_tap, named], failed: [named] }, named, wire_tap, true)
	// A sender with no channel: the shared tap, nothing else to wait for.
	assert ready(Taps{ filed: [wire_tap] }, named, wire_tap, false)
	assert !ready(Taps{}, named, wire_tap, false)
}

// THE MANUAL SIDE (round 8): Fire and its hotkey follow the same rule — wait rather than
// misattribute — and a send with no channel takes the shared tap or reports no bus.
fn test_a_manual_send_waits_rather_than_borrow_another_channels_identity() {
	named := 'Gen1|inproc:CAN1'
	wire_tap := '|inproc:CAN1'
	assert fallback(Taps{ filed: [wire_tap] }, named, wire_tap, true) == .wait
	assert fallback(Taps{ filed: [wire_tap], failed: [named] }, named, wire_tap, true) == .via_wire
	assert fallback(Taps{ failed: [named] }, named, wire_tap, true) == .none_open
	assert fallback(Taps{ filed: [wire_tap] }, named, wire_tap, false) == .via_wire
	assert fallback(Taps{}, named, wire_tap, false) == .none_open
}

// DROPPING (rounds 8–9): after a slow open comes back, the named tap goes if no generator
// fires on the pair any more, and the wire's shared tap goes too if nothing uses the wire.
// One decision from one snapshot.
fn test_an_abandoned_tap_is_dropped_and_an_abandoned_wire_loses_its_shared_tap_too() {
	named := 'Gen1|inproc:CAN1'
	wire := 'inproc:can1'
	// Still wanted on both counts: nothing dropped.
	d := drop_decision(Wants{ pairs: [named], wires: [wire] }, named, wire)
	assert !d.named && !d.wire
	// Retargeted away, but another row keeps the wire: only the named tap goes.
	d2 := drop_decision(Wants{ wires: [wire] }, named, wire)
	assert d2.named && !d2.wire
	// Nothing left on the wire: both go — on a CANsub the shared tap is the channel's one
	// WebSocket client, and holding it until Stop blocked the next legitimate use.
	d3 := drop_decision(Wants{}, named, wire)
	assert d3.named && d3.wire
	// Retargeted BACK before the open returned: nothing goes — this is the case that a
	// two-step decide-then-delete got wrong.
	d4 := drop_decision(Wants{ pairs: [named], wires: [wire] }, named, wire)
	assert !d4.named && !d4.wire
}
