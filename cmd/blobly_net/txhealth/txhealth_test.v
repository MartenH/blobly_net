module txhealth

// --- the cadence ---

fn test_a_wire_never_asked_is_due() {
	// The first frame on a wire reports its state rather than waiting out a cadence it has not
	// started. 0 is "never", and never is due for either reason.
	assert due(0, 0, .success)
	assert due(0, 0, .failure)
	assert due(0, 5, .success)
}

fn test_the_success_cadence_is_one_second() {
	assert !due(1000, 1999, .success)
	assert due(1000, 2000, .success)
	// Exactly at the boundary counts: `>` would refuse for ever on a clock that repeats a
	// millisecond, which is the trap `due`'s comment names.
	assert due(1000, 1000 + poll_success_ms, .success)
}

fn test_a_failure_is_prompter_but_still_bounded() {
	// The whole point of the two intervals: a failing wire is asked sooner...
	assert due(1000, 1200, .failure)
	assert !due(1000, 1200, .success)
	// ...and is still bounded, or a bus-off controller failing every frame at 1 kHz would make a
	// thousand driver calls a second — the cost #224 removed.
	assert !due(1000, 1199, .failure)
	assert poll_failure_ms < poll_success_ms
	assert poll_failure_ms > 0
}

fn test_a_clock_that_went_backwards_is_due() {
	// `last_ms` outlives a run and a run resets the epoch, so a stale value can sit in the
	// future. A plain subtraction would refuse every poll until the clock caught up.
	assert due(9000, 10, .success)
	assert due(9000, 10, .failure)
}

fn test_ask_claims_the_slot_so_two_taps_do_not_both_poll() {
	// Several taps share one wire's Gate. Checking and claiming in one call is what stops both
	// of them passing the same gate and doubling the cadence.
	mut g := Gate{}
	assert g.ask(500, .success)
	assert g.last_ms == 500
	assert !g.ask(500, .success)
	assert !g.ask(1499, .success)
	assert g.ask(1500, .success)
}

fn test_a_refused_ask_does_not_move_the_clock() {
	// Otherwise a busy wire pushes its own deadline forward on every frame and never polls at
	// all — the cadence would become "one second after the last ATTEMPT", which on a 1 kHz wire
	// is never.
	mut g := Gate{}
	assert g.ask(1000, .success)
	assert !g.ask(1400, .success)
	assert g.last_ms == 1000
	assert g.ask(2000, .success)
}

// --- what is worth saying ---

fn test_unknown_is_never_narrated() {
	// health_name(.unknown) is the EMPTY STRING, so narrating it puts "can0: bus " in the Log.
	// It is also the ordinary answer from every needs_reader wire.
	assert !reportable(.unknown, .unknown)
	assert !reportable(.ok, .unknown)
	assert !reportable(.bus_off, .unknown)
}

fn test_the_first_observation_is_news() {
	// rx_loop reports the first non-unknown state it sees, and #265 is the ticket that made it
	// say "bus ok" when the wire first answers. A tap going quiet about that would be a visible
	// inconsistency between a monitored wire and a transmit-only one.
	assert reportable(.unknown, .ok)
	assert reportable(.unknown, .bus_off)
}

fn test_recovery_is_news_too() {
	assert reportable(.bus_off, .ok)
	assert reportable(.error_passive, .warning)
}

fn test_the_same_rung_twice_is_not() {
	assert !reportable(.bus_off, .bus_off)
	assert !reportable(.ok, .ok)
}

// --- the two together, which is where the interesting case lives ---

fn test_a_fault_is_narrated_once_however_often_it_is_observed() {
	mut g := Gate{}
	a := g.saw(.bus_off)
	assert a.say
	assert a.from == .unknown
	assert a.to == .bus_off
	assert !g.saw(.bus_off).say
	assert !g.saw(.bus_off).say
}

fn test_a_failed_driver_call_does_not_re_arm_a_fault_already_said() {
	// THE CASE THIS RULE EXISTS FOR. A polled wire whose driver call fails answers `unknown`.
	// Had that been stored as "what we said", the next bus_off would differ from it and BUS-OFF
	// would be narrated a second time for a controller that never recovered — and an operator
	// reads a second line as a second fault.
	mut g := Gate{}
	assert g.saw(.bus_off).say
	assert !g.saw(.unknown).say
	assert g.reported == .bus_off
	assert !g.saw(.bus_off).say
}

fn test_a_real_recovery_after_an_unknown_still_speaks() {
	// The other half of the same rule: holding `reported` at bus_off must not swallow the
	// recovery when it genuinely arrives.
	mut g := Gate{}
	assert g.saw(.bus_off).say
	assert !g.saw(.unknown).say
	r := g.saw(.ok)
	assert r.say
	assert r.from == .bus_off
	assert r.to == .ok
}

fn test_a_gate_starts_silent() {
	// A wire that has never answered says nothing at all — the software buses reach this through
	// their .unknown, and a needs_reader wire lives here for its whole run.
	mut g := Gate{}
	assert g.reported == .unknown
	assert !g.saw(.unknown).say
	assert g.last_ms == 0
}

fn test_the_ladder_keeps_its_order() {
	// The order is the ladder's, and the caller's exhaustive match maps transport.BusHealth onto
	// it positionally in review's eyes if not the compiler's. A reordering here would silently
	// re-label every rung.
	assert int(Rung.unknown) == 0
	assert int(Rung.ok) == 1
	assert int(Rung.warning) == 2
	assert int(Rung.error_passive) == 3
	assert int(Rung.bus_off) == 4
}

// --- a failure that follows a success (codex on #349) ---

fn test_a_failure_after_a_success_is_urgent_whatever_the_cadence_says() {
	// THE CASE THE FEATURE EXISTS FOR. A successful send polls `.ok`; the controller goes BUS-OFF;
	// the next send fails 10 ms later — inside the 200 ms failure floor. Refused, nothing else is
	// scheduled, and a producer that stops on its first error leaves the terminal fault unasked.
	mut g := Gate{}
	assert g.ask(1000, .success)
	assert !g.ask(1010, .success) // the ordinary cadence still holds for a success
	assert g.ask(1010, .failure) // ...and does not hold for the failure behind it
}

fn test_the_escalation_cannot_run_away() {
	// A refused ask moves nothing, so after one escalated poll `last_why` is `.failure` and the
	// next failure is back on the floor. This is what stops a wire alternating success and failure
	// every frame from polling the driver once per frame — the #224 cost.
	mut g := Gate{}
	assert g.ask(1000, .success)
	assert g.ask(1010, .failure) // escalated
	assert !g.ask(1020, .failure) // back on the 200 ms floor
	assert !g.ask(1030, .success) // refused by the one-second floor...
	assert !g.ask(1040, .failure) // ...so it left last_why alone, and this cannot escalate
	assert !g.ask(1209, .failure)
	assert g.ask(1210, .failure) // 200 ms after the escalated poll, on the ordinary floor
}

fn test_an_escalation_needs_a_granted_success_before_it() {
	// The bound stated the other way round: escalation costs one GRANTED success ask, which is at
	// most one a second, so escalated polls are at most about one a second too.
	mut g := Gate{}
	assert g.ask(1000, .failure)
	assert !g.ask(1100, .failure)
	assert !g.ask(1100, .success) // refused: within the one-second floor
	assert !g.ask(1150, .failure) // so still no escalation
	assert g.ask(2000, .success) // granted at last
	assert g.ask(2001, .failure) // and now a failure behind it escalates
}

fn test_a_fresh_gate_needs_no_escalation() {
	// last_ms is 0, so the first ask of either kind is due on its own and the edge never comes
	// into it. Worth pinning because Why's zero value is `.failure`, which is NOT `.success` —
	// the escalation must not depend on which variant happens to be first.
	mut g := Gate{}
	assert g.ask(0, .failure)
	mut h := Gate{}
	assert h.ask(0, .success)
}

fn test_a_granted_ask_records_what_it_was_for() {
	mut g := Gate{}
	assert g.ask(500, .success)
	assert g.last_why == .success
	assert g.ask(510, .failure)
	assert g.last_why == .failure
}

// --- ownership: the class three rounds kept landing in ---

fn test_a_wire_with_no_rows_is_owned_by_nobody() {
	// The case #142 exists for: a generator naming a bare address (`bus: pcan:…@250000`), which
	// is no configured channel at all.
	assert !wire_owned([])
}

fn test_a_monitored_row_owns_its_wire_before_its_reader_starts() {
	// ROUND 2. `start()` sets app.running before it marks any row spawning, so a tool bus sending
	// in between must not read an about-to-be-monitored wire as unowned. `monitored` is the same
	// predicate start() uses to choose readers, so it is true from the moment the project applies.
	assert wire_owned([RowView{ monitored: true }])
}

fn test_a_row_whose_reader_failed_to_open_owns_nothing() {
	// ROUND 3, and a defect of round 2's fix. That path clears running and spawning and leaves the
	// row ENABLED, so `monitorable()` alone claimed an owner that would never narrate — and the
	// wire went silent rather than falling back to its tap.
	assert !wire_owned([RowView{ monitored: true, open_failed: true }])
}

fn test_a_disabled_row_owns_nothing() {
	// #165's retained transmit tap, and the retire path's handover: a reader that dies mid-run
	// disables every alias on its wire, which is how that case is already expressed.
	assert !wire_owned([RowView{ monitored: false }])
	assert !wire_owned([RowView{ monitored: false, open_failed: true }])
}

fn test_one_live_row_is_enough() {
	// A wire with several aliases gets ONE reader, so a failed sibling must not hand the wire to
	// the tap while another row is still reading it.
	assert wire_owned([RowView{ monitored: true, open_failed: true }, RowView{ monitored: true }])
	assert wire_owned([RowView{ monitored: true }, RowView{ monitored: true, open_failed: true }])
}

fn test_every_row_failing_hands_the_wire_back() {
	// The relay race the retire path's comment describes, at open time: if every candidate failed,
	// nobody is reading and the tap is all there is.
	assert !wire_owned([RowView{ monitored: true, open_failed: true }, RowView{
		monitored:   true
		open_failed: true
	}])
}
