module transport

fn test_vector_channel_spellings() {
	assert vector_app_channel('1')! == 1
	assert vector_app_channel('ch1')! == 1
	assert vector_app_channel('app1')! == 1
	assert vector_app_channel('channel2')! == 2
	assert vector_app_channel(' 3 ')! == 3
	assert vector_app_channel('CH4')! == 4
	assert vector_app_channel('01')! == 1, 'a leading zero is the same channel'
}

fn test_vector_channel_rejects_nonsense() {
	if _ := vector_app_channel('') {
		assert false, 'an empty channel must not resolve'
	}
	if _ := vector_app_channel('0') {
		assert false, 'Vector Hardware Config numbers from 1; 0 is a typo, not a channel'
	}
	if _ := vector_app_channel('65') {
		assert false, 'above XL_CONFIG_MAX_CHANNELS'
	}
	if _ := vector_app_channel('bench') {
		assert false, 'a name is not a channel'
	}
	if _ := vector_app_channel('1a') {
		assert false, 'trailing rubbish must not be silently truncated to 1'
	}
}

// The identity test that matters: two spellings of one wire must be ONE destination, or the
// conflict check lets two recordings onto the same bus.
fn test_vector_spellings_are_one_destination() {
	assert vector_key('1') == vector_key('ch1')
	assert vector_key('app01') == vector_key('1')
	assert vector_key('1') != vector_key('2')
}

// An unresolvable channel keeps its spelling, so two identical bad strings still collide
// rather than being treated as two different buses that both fail to open.
fn test_unresolvable_channel_still_collides_with_itself() {
	assert vector_key('bench') == vector_key(' BENCH ')
	assert vector_key('bench') != vector_key('other')
}

// The project migration KEEPS a malformed rate so that this parser refuses it. That only works
// if it does: `.int()` takes a numeric prefix, so `250000garbage` opened at 250 kbit/s and the
// preservation was pointless.
fn test_vector_spec_rejects_partial_bitrate() {
	if _ := parse_vector_spec('1@250000garbage') {
		assert false, 'a rate that is nearly a number must not open a channel'
	}
	if _ := parse_vector_spec('1@') {
		assert false, 'an empty rate is not the default'
	}
	if _ := parse_vector_spec('1@oops') {
		assert false, 'not a number at all'
	}
	ok := parse_vector_spec('1@250000') or {
		assert false, '${err}'
		return
	}
	assert ok.bitrate == 250000
	assert ok.channel == 1
}

// …and the mode still rides after the rate.
fn test_vector_spec_mode_after_rate() {
	s := parse_vector_spec('1@250000,silent') or {
		assert false, '${err}'
		return
	}
	assert s.silent && s.bitrate == 250000
}

// Two rates is a contradiction, not a preference for the first. Reachable by typing a
// legacy-style `1@250000` into the address field of a channel whose bitrate is 500000.
fn test_vector_spec_rejects_two_bitrates() {
	if _ := parse_vector_spec('1@250000@500000') {
		assert false, 'the model would say 500k while the hardware ran at 250k'
	}
}

// The rate rule every vendor backend shares. A prefix that happens to parse is not a rate.
fn test_vendor_bitrate_is_strict() {
	assert vendor_bitrate('250000', 500000)! == 250000
	for bad in ['250000garbage', '', 'oops', '25 000', '-1'] {
		if _ := vendor_bitrate(bad, 500000) {
			assert false, '"${bad}" must not parse as a bitrate'
		}
	}
}

// One rule, checked once, for every backend that has an `@rate` suffix.
fn test_vendor_split_rate() {
	c1, r1 := vendor_split_rate('PCAN_USBBUS1@250000', 500000)!
	assert c1 == 'PCAN_USBBUS1' && r1 == 250000
	c2, r2 := vendor_split_rate('0', 500000)!
	assert c2 == '0' && r2 == 500000
	for bad in ['x@250000@500000', 'x@', 'x@250000garbage', 'x@oops'] {
		if _, _ := vendor_split_rate(bad, 500000) {
			assert false, '"${bad}" must not open a channel'
		}
	}
}

// The vendor resolvers describe how the VENDOR reads a name, which is a fact about the vendor
// and not about the machine. This runs on Linux, where the old version resolved nothing.
fn test_vendor_destination_key_resolves_off_windows() {
	assert vendor_destination_key('vector:1') == vendor_destination_key('vector:ch1')
	assert vendor_destination_key('vector:app01@500000') == vendor_destination_key('vector:1@500000')
	assert vendor_destination_key('kvaser:0') == vendor_destination_key('kvaser:00')
	assert vendor_destination_key('vector:1') != vendor_destination_key('vector:2')
}

// …while destination_key keeps its platform guard, because on Linux a prefixed name really is
// an ordinary SocketCAN interface and opening it must not be redirected.
fn test_destination_key_keeps_its_platform_guard() {
	$if !windows {
		assert destination_key('vector:1') != destination_key('vector:ch1')
	}
}

// An adapter with no address must report, not panic. This became reachable when the vendor
// resolvers stopped being Windows-only, so the headless validation pass could reach them.
fn test_empty_vendor_addresses_do_not_panic() {
	if _ := pcan_handle('') {
		assert false, 'an empty PCAN channel is not a channel'
	}
	// And the destination keys built on them survive it.
	assert vendor_destination_key('pcan:') != ''
	assert vendor_destination_key('vector:') != ''
	assert vendor_destination_key('kvaser:') != ''
}

// ---- CAN-FD addressing -------------------------------------------------------------------
//
// The data bitrate IS the FD flag, so these check that one thing rather than two: an address
// with no second rate must not open an FD channel, and one with a second rate must not open a
// classic one. Both directions have a way of going wrong quietly — a channel that runs classic
// while the project believes it is FD refuses every 64-byte frame at send() with nothing saying
// why, and one that runs FD while the project believes it is classic puts EDL on a wire whose
// other nodes cannot read it.
fn test_a_data_bitrate_is_what_asks_for_fd() {
	classic := parse_vector_spec('1@500000')!
	assert !classic.fd
	assert classic.data_bitrate == 0, 'a classic address must not carry a data phase'

	fd := parse_vector_spec('1@500000/2000000')!
	assert fd.fd
	assert fd.bitrate == 500000
	assert fd.data_bitrate == 2000000

	// FD WITH NO BIT-RATE SWITCH is a real configuration — 64-byte payloads at the arbitration
	// rate — and the only way to spell it is with the two rates equal. If this were rejected as
	// "pointless" there would be no way to ask for it at all.
	same := parse_vector_spec('1@500000/500000')!
	assert same.fd && same.data_bitrate == 500000

	// The mode suffix still comes off the end, after the rate rather than inside it.
	quiet := parse_vector_spec('1@500000/2000000,silent')!
	assert quiet.fd && quiet.data_bitrate == 2000000 && quiet.silent
}

fn test_a_malformed_fd_rate_is_refused() {
	for bad in [
		'1@500000/',           // no data rate after the separator
		'1@/2000000',          // no arbitration rate before it
		'1@500000/2000000/4',  // three rates
		'1@500000/oops',       // not a number
		'1@500000/2000000garbage',
		'1@2000000/500000',    // the data phase cannot be the slow one
		'1@500000/9000000',    // past what ISO 11898-1 allows
		'1@500000/1000',       // below the range
	] {
		if s := parse_vector_spec(bad) {
			assert false, '"${bad}" must not open a channel (got fd=${s.fd} dbr=${s.data_bitrate})'
		}
	}
	// And the arbitration phase keeps its OWN ceiling: it is still classic CAN however fast the
	// payload goes, so a 4 Mbit/s arbitration rate is wrong even in an FD address.
	if _ := parse_vector_spec('1@4000000/4000000') {
		assert false, 'arbitration above 1 Mbit/s is not a CAN rate'
	}
}

// ONE WIRE, TWO BUSES. An FD address and a classic one on the same channel address the same
// physical wire — so they must group together for the conflict check — but they are not one bus,
// and a transport table that keyed them identically would hand the second opener a port running
// the other protocol.
fn test_fd_and_classic_are_one_wire_but_not_one_bus() {
	assert wire_key_for('vector', 'vector:1@500000') == wire_key_for('vector', 'vector:1@500000/2000000'),
		'the same channel is the same wire whatever protocol it runs'
	assert vendor_destination_key('vector:1@500000') != vendor_destination_key('vector:1@500000/2000000'),
		'classic and FD on one channel are two different buses'
	// Two data rates likewise: same wire, different bus.
	assert vendor_destination_key('vector:1@500000/2000000') != vendor_destination_key('vector:1@500000/4000000')
	// …and the key still normalises numerically, as it does for the classic rate.
	assert vendor_destination_key('vector:1@500000/2000000') == vendor_destination_key('vector:ch1@0500000/02000000')
	// The mode is still not part of the address, with an FD rate as without one.
	assert vendor_destination_key('vector:1@500000/2000000') == vendor_destination_key('vector:1@500000/2000000,silent')
}

// The segment arithmetic is the part with no second opinion available: XLcanFdConf has no
// prescaler field, so a segment count that does not divide the controller clock exactly is
// refused by the driver and the channel does not come up. These are the rates a bench actually
// uses, and every one of them was exercised on a VN1630A.
// PER PHASE, which is the whole point: each phase gets its own quanta count and its own
// prescaler, aiming at the same sample-point RATIO. The first version searched for one count
// satisfying BOTH rates and so refused pairs the hardware can do — see the 800k/5M case.
fn test_fd_timing_divides_the_controller_clock_per_phase() {
	for pair in [[500000, 2000000], [500000, 4000000], [500000, 5000000], [500000, 8000000],
		[250000, 2000000], [1000000, 4000000], [1000000, 8000000],
		// THE CASE A SHARED QUANTA COUNT COULD NOT DO. 800k is exact at 20 quanta and 5M at 16;
		// their only common counts are below the 8-quanta minimum, so the joint search fell back
		// to a shape dividing neither and the driver refused an open the parser had accepted.
		[800000, 5000000]] {
		arb, data := pair[0], pair[1]
		for rate in [arb, data] {
			t := vector_fd_timing(rate) or { continue }
			tq := 1 + t.tseg1 + t.tseg2
			assert vector_fd_clock_hz % (rate * tq) == 0,
				'${arb}/${data}: ${tq} quanta gives no whole prescaler for ${rate}'
			brp := vector_fd_clock_hz / (rate * tq)
			assert brp >= 1 && brp <= 256, '${arb}/${data}: prescaler ${brp} for ${rate}'
			assert tq >= 8
			// sjw may not exceed the segment it shortens, or resync runs past the bit.
			assert t.sjw >= 1 && t.sjw <= t.tseg2
			// The sample point sits where CiA 601-3 asks, within rounding of one quantum.
			sp := f64(1 + t.tseg1) / f64(tq)
			assert sp > 0.72 && sp < 0.86, '${arb}/${data}: sample point at ${sp} for ${rate}'
		}
	}
}

// THE INVARIANT, swept rather than sampled: for every rate the parser accepts, the timing either
// works or SAYS IT DOES NOT. A hand-picked grid asserted the first half and missed the second —
// 500000/750000 parses, and 750000 needs brp*tq = 106.67, which no division of a bit can give, so
// the old fallback handed the driver a shape that could not produce the rate and the operator got
// a bare XL status against an address the parser had promised (codex #181 r4).
//
// The sweep is over the whole accepted range at a fine step, not a list of rates a bench happens
// to use — the previous version of this test was exactly such a list, and that is why it passed.
fn test_every_accepted_rate_either_has_timing_or_is_refused() {
	mut checked := 0
	mut refused := 0
	for rate := 5000; rate <= 8_000_000; rate += 1000 {
		// Only rates an ADDRESS can actually carry: the data phase is the wider range, so parsing
		// as a data phase is what decides whether this rate is reachable at all.
		parse_vector_spec('1@500000/${rate}') or { continue }
		checked++
		t := vector_fd_timing_data(rate) or {
			refused++
			continue
		}
		tq := 1 + t.tseg1 + t.tseg2
		brp := vector_fd_clock_hz / (rate * tq)
		assert vector_fd_clock_hz % (rate * tq) == 0,
			'${rate} accepted with ${tq} quanta, which gives no whole prescaler'
		assert brp >= 1 && brp <= 256, '${rate} accepted with prescaler ${brp}'
		assert t.sjw >= 1 && t.sjw <= t.tseg2
		sp := f64(1 + t.tseg1) / f64(tq)
		assert sp > 0.72 && sp < 0.86, '${rate}: sample point at ${sp}'
	}
	assert checked > 1000, 'the sweep must actually cover the range, checked ${checked}'
	// Most rates on an 80 MHz clock are NOT producible, which is the point: the old code returned
	// a shape for every one of them.
	assert refused > 0, 'a sweep this wide must contain rates this clock cannot produce'
}

// The concrete cases behind the rule, named so a regression says which one broke.
fn test_the_rates_that_cannot_be_produced_are_refused() {
	// UNPRODUCIBLE AT ANY COUNT, on either phase: 80e6 / 750e3 is 106.67, so no (brp, tq) exists.
	// This is arithmetic about the clock, not a bound anything here chose.
	if t := vector_fd_timing(750_000) {
		tq := 1 + t.tseg1 + t.tseg2
		assert false, 'arbitration 750000 must be refused; got ${tq} quanta'
	}
	if _ := vector_fd_timing_data(750_000) {
		assert false, 'data 750000 must be refused'
	}
	// …while the rates a bench actually uses still resolve on both phases.
	for good in [125000, 250000, 500000, 800000, 1000000] {
		vector_fd_timing(good) or { assert false, 'arbitration ${good} must resolve: ${err}' }
	}
	for good in [500000, 1000000, 2000000, 4000000, 5000000, 8000000] {
		vector_fd_timing_data(good) or { assert false, 'data ${good} must resolve: ${err}' }
	}
}

// THE PHASES HAVE DIFFERENT CEILINGS, and 5 kbit/s is the case that shows why. An FD controller's
// NOMINAL segment fields are wide — the arbitration phase is ordinary CAN — while the DATA phase's
// are narrow because it has to switch fast. Applying the data bound to both refused an arbitration
// timing the hardware can do: 5000 is exact at 64 quanta with prescaler 250. The round-4 claim
// that 5 kbit/s "needs prescaler 640" was true only under that self-imposed 25-quanta ceiling
// (codex #181 r5).
fn test_the_arbitration_phase_searches_further_than_the_data_phase() {
	t := vector_fd_timing(5000) or {
		assert false, '5000 is producible on the arbitration phase: ${err}'
		return
	}
	tq := 1 + t.tseg1 + t.tseg2
	brp := vector_fd_clock_hz / (5000 * tq)
	assert vector_fd_clock_hz % (5000 * tq) == 0, '5000 at ${tq} quanta gives no whole prescaler'
	assert brp >= 1 && brp <= 256, '5000 resolved to prescaler ${brp}'
	assert tq > fd_tq_max_data, 'the point of this case is a count beyond the data ceiling'
	// The DATA phase still refuses it, because its fields cannot hold that many quanta.
	if _ := vector_fd_timing_data(5000) {
		assert false, '5000 must not resolve on the data phase, whose segments are narrow'
	}
}

// A CLASSIC RATE IS THE DRIVER'S PROBLEM, NOT OURS. Classic opens call xlCanSetChannelBitrate and
// let XL derive the timing; only the FD path needs segments, because XLcanFdConf takes them and
// nothing derives them for us. Deriving them for classic too refused opens that had always
// worked — 83333 bit/s is an ordinary CAN rate and 80e6/83333 is 960.0038, so no prescaler
// produces it from this clock and the channel stopped opening (codex #182 r1).
//
// The parser is what must keep accepting those rates; open_vector is where the FD-only condition
// lives, and this pins the half that can be tested off-hardware.
fn test_a_classic_rate_the_clock_cannot_divide_is_still_a_valid_address() {
	for rate in [83333, 95238, 33333] {
		s := parse_vector_spec('1@${rate}') or {
			assert false, '${rate} is a legal classic CAN rate: ${err}'
			continue
		}
		assert !s.fd && s.bitrate == rate
		// It genuinely has no timing on this clock — which is why deriving one for classic was
		// a refusal rather than a formality.
		if _ := vector_fd_timing(rate) {
			assert false, '${rate} was expected to have no whole prescaler at 80 MHz'
		}
	}
	// …and as an FD ARBITRATION rate the same value must still be refused, because there the
	// segments are load-bearing.
	if _ := parse_vector_spec('1@83333/2000000') {
		// The address parses — the range check allows it — and the refusal comes at open, from
		// vector_fd_timing. That split is deliberate: the parser validates the standard, the open
		// validates this controller.
		if _ := vector_fd_timing(83333) {
			assert false, 'an FD arbitration phase at 83333 has no timing and must be refused'
		}
	}
}

// WHAT THE EDITOR ASKS AND WHAT THE OPEN REFUSES MUST BE THE SAME QUESTION. Three rounds running,
// a front-end pre-flight was a SUBSET of the open's own checks: ordering without ranges, then
// syntax+ranges without timing — so `500000/750000` was accepted, saved, and refused only while
// opening (codex #183 r2). vector_address_error runs the parser AND the timing feasibility that
// open_vector runs, and open_vector calls the same function, so they cannot drift again.
fn test_the_address_check_covers_timing_not_only_syntax() {
	// Syntactically fine, in range, correctly ordered — and unproducible on this clock.
	if why := vector_address_error('vector:1@500000/750000') {
		assert why.contains('750000'), 'the message must name the offending rate: ${why}'
		assert why.contains('data phase'), 'and say which phase: ${why}'
	} else {
		assert false, '500000/750000 parses but cannot be opened; the check must say so'
	}
	// An arbitration phase with no timing is caught too, and named as the other phase.
	if why := vector_address_error('vector:1@83333/2000000') {
		assert why.contains('arbitration'), 'got ${why}'
	} else {
		assert false, 'an FD arbitration phase at 83333 has no timing'
	}
	// A CLASSIC address at that same rate is fine — the driver derives its own timing, and this
	// is exactly the distinction #182 r1 was about.
	if why := vector_address_error('vector:1@83333') {
		assert false, 'a classic rate needs no timing from us: ${why}'
	}
	// And the ordinary FD cases still pass, prefix present or absent.
	for ok in ['vector:1@500000/2000000', '1@500000/2000000', 'vector:1@500000', 'vector:1@800000/5000000'] {
		if why := vector_address_error(ok) {
			assert false, '${ok} must be openable: ${why}'
		}
	}
	// Malformed addresses still come back with the parser's own complaint.
	if _ := vector_address_error('vector:1@500000/oops') {} else {
		assert false, 'a malformed rate must still be reported'
	}
}


// ---- assigning an application channel -------------------------------------------------------
//
// SIX ROUNDS OF REVIEW LANDED IN assign_refusal, and CLAUDE.md's rule for that is to cover the path
// rather than keep repairing it. So the truth table below is exhaustive: every AppSlot, stated once,
// with the reason it decides the way it does. A fifth state cannot be added without this failing to
// compile-or-assert, which is the point — the defect underneath all six rounds was a state whose
// meaning was ambiguous, and an exhaustive table is what makes the next ambiguity visible.
//
// NOTHING PROPOSES A CHANNEL. Rounds 3 and 4 tried to infer which channels were free and produced a
// contradictory pair of findings; the operator names the channel and this checks THAT one.
fn test_assign_refusal_decides_every_slot_state() {
	// The permitted two: both mean "no mapping is at risk", by different routes.
	for slot in [AppSlot.empty, AppSlot.absent] {
		if why := assign_refusal(1, slot, true) {
			assert false, '${slot} must be assignable: ${why}'
		}
	}
	// The refused two: both mean "something may be under there".
	for slot in [AppSlot.taken, AppSlot.unreadable] {
		if _ := assign_refusal(1, slot, true) {} else {
			assert false, '${slot} must be refused'
		}
	}
}

// THE CONSENT FLAG MOVES EXACTLY ONE STATE, and that is the whole of its contract. `absent` is the
// only verdict the driver reports with a GENERIC error, so it is the only one an operator has to
// stand behind; letting it soften `taken` or `unreadable` would turn a safety rule into a checkbox
// (codex #192 r9).
fn test_only_absent_depends_on_the_operators_consent() {
	// Default off: a generic error never authorizes a write on its own.
	if why := assign_refusal(7, .absent, false) {
		assert why.contains('not registered'), 'the message must say what is being created: ${why}'
		assert why.contains('create unregistered channel'), 'and name the affordance: ${why}'
	} else {
		assert false, 'an unregistered channel must not be written without the operator saying so'
	}
	// Stated: creating is what they asked for.
	if why := assign_refusal(7, .absent, true) {
		assert false, 'a stated create must go through: ${why}'
	}
	// EVERY OTHER STATE DECIDES THE SAME WAY BOTH WAYS. This is the assertion that stops the flag
	// growing into a general override.
	for slot in [AppSlot.taken, AppSlot.unreadable, AppSlot.empty] {
		off := assign_refusal(7, slot, false)
		on := assign_refusal(7, slot, true)
		assert (off == none) == (on == none), '${slot} must not depend on the consent flag'
	}
	// And consent never rescues an out-of-range channel.
	if _ := assign_refusal(0, .absent, true) {} else {
		assert false, '0 is not a channel, however willing the operator is'
	}
}

// THE CODES, PINNED. ct_vector_appl_get in vector_shim.h is the other half of this: 0 assigned,
// -2 registered-and-free, -3 no-such-channel, anything else the driver could not be reached. -1 is
// the one that must NOT read as `absent` — it is the driver-unreachable case, and the r5 finding
// was precisely about not treating an unanswered question as permission to write.
fn test_the_driver_codes_map_to_the_states_they_mean() {
	assert slot_of(0) == .taken
	assert slot_of(-2) == .empty
	assert slot_of(-3) == .absent
	assert slot_of(-1) == .unreadable, 'driver-unreachable must never read as an unregistered channel'
	// Nothing else is defined, and an undefined code is silence rather than permission.
	for rc in [-4, -99, 1, 255] {
		assert slot_of(rc) == .unreadable, 'an unrecognised code (${rc}) must be the refusing state'
	}
}

// A GENERIC ERROR MAY NOT AUTHORIZE A WRITE ON ITS OWN. `absent` is the only verdict that permits
// one and the only one resting on XL's generic error, so it is asked twice; every disagreement must
// resolve away from permission (codex #192 r8).
fn test_a_second_reading_overrides_a_generic_absent() {
	// Agreement is the only way a write stays authorized.
	assert reconcile_absent(.absent, .absent) == .absent
	// Any answer that actually describes the channel wins, whichever way it decides.
	assert reconcile_absent(.absent, .taken) == .taken, 'an occupied channel must not be overwritten'
	assert reconcile_absent(.absent, .unreadable) == .unreadable, 'silence must not read as absent'
	assert reconcile_absent(.absent, .empty) == .empty
	// And the three that permit or refuse on real evidence are never re-litigated: a first answer
	// that is not `absent` stands whatever a second reading might say.
	for first in [AppSlot.taken, AppSlot.empty, AppSlot.unreadable] {
		for second in [AppSlot.taken, AppSlot.empty, AppSlot.unreadable, AppSlot.absent] {
			assert reconcile_absent(first, second) == first, '${first} must not be revised by ${second}'
		}
	}
	// The property that matters, stated as itself: a write is authorized only when BOTH readings
	// agree the channel is not there.
	for second in [AppSlot.taken, AppSlot.unreadable] {
		if _ := assign_refusal(9, reconcile_absent(.absent, second), true) {} else {
			assert false, 'a disagreeing second reading (${second}) must end in a refusal'
		}
	}
}

// EVERY OTHER DRIVER STATUS REFUSES, and this is the half the shim has to hold up. Mapping all
// non-zero statuses to `absent` put the r6 P1 back one layer down: a transient per-call error would
// have read as an unregistered channel and so as writable. The shim now converts one measured
// status to -3 and encodes the rest, and what makes that safe is that the encoding lands in
// slot_of's default (codex #192 r7).
fn test_an_unexpected_driver_status_refuses_and_keeps_its_number() {
	// A sample across the XL status range, including the generic error the measured value shares a
	// space with. None of these may come out as permission to write.
	for st in [1, 10, 13, 101, 129, 254, 256, 65535] {
		rc := -(1000 + st)
		assert slot_of(rc) == .unreadable, 'XL status ${st} must refuse, not permit'
		if got := xl_status_of(rc) {
			assert got == st, 'the status must survive the encoding: wanted ${st}, got ${got}'
		} else {
			assert false, 'XL status ${st} should be recoverable from ${rc}'
		}
		if why := assign_refusal(1, slot_of(rc), true) {
			assert why.contains('would not say'), 'got ${why}'
		} else {
			assert false, 'XL status ${st} must not permit an assignment'
		}
	}
	// The plain codes carry no status, and must not be misread as one.
	for rc in [0, -1, -2, -3] {
		if got := xl_status_of(rc) {
			assert false, '${rc} is a plain code, not an encoded status (got ${got})'
		}
	}
}

fn test_a_channel_the_driver_says_is_taken_is_refused() {
	if why := assign_refusal(3, .taken, true) {
		assert why.contains('vector:3'), 'the message must name the channel: ${why}'
		assert why.contains('release'), 'and say how to proceed: ${why}'
	} else {
		assert false, 'a channel the driver reports as assigned must not be written'
	}
}

// THE DISTINCTION THE WHOLE OF R6 IS ABOUT. `absent` and `unreadable` were one state called
// `unknown`, and no rule over it could be right for both: r5 refused it to protect an occupied
// channel, and r6 showed that refusing it also blocked extending an application — which is 57 of
// the 64 channels on a measured bench, i.e. the feature. They decide OPPOSITE ways, and neither
// needs to know whether the application exists.
fn test_absent_and_unreadable_are_not_the_same_answer() {
	// The driver ANSWERED: no such channel. xlSetApplConfig creates it — the documented way to
	// extend an application, and measured as the state of 57 of 64 channels on a working bench.
	if why := assign_refusal(7, .absent, true) {
		assert false, 'an unregistered channel is exactly what Assign is for: ${why}'
	}
	// The driver did not answer at all. Anything could be under there.
	if why := assign_refusal(7, .unreadable, true) {
		assert why.contains('would not say'), 'the message must say the driver was silent: ${why}'
	} else {
		assert false, 'a channel the driver would not describe must never be overwritten'
	}
}

fn test_the_channel_number_must_be_one_the_library_addresses() {
	for bad in [0, -1, 65, 1000] {
		if _ := assign_refusal(bad, .empty, false) {} else {
			assert false, '${bad} is not a Vector application channel'
		}
	}
	// The ends of the range are valid.
	if why := assign_refusal(1, .empty, false) {
		assert false, '1 is valid: ${why}'
	}
	if why := assign_refusal(64, .empty, false) {
		assert false, '64 is valid: ${why}'
	}
	// The range is checked BEFORE the slot: an out-of-range channel is refused whatever the driver
	// says about it, including the states that would otherwise be permitted.
	for slot in [AppSlot.empty, AppSlot.absent, AppSlot.taken, AppSlot.unreadable] {
		if _ := assign_refusal(0, slot, true) {} else {
			assert false, '0 is out of range whatever the slot says (${slot})'
		}
	}
}
