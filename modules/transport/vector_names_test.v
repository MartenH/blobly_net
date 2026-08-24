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
fn test_fd_segments_divide_the_controller_clock() {
	for pair in [[500000, 2000000], [500000, 4000000], [500000, 5000000], [500000, 8000000],
		[250000, 2000000], [1000000, 4000000], [1000000, 8000000]] {
		arb, data := pair[0], pair[1]
		t1, t2, sjw := vector_fd_segments(arb, data)
		tq := 1 + t1 + t2
		assert vector_fd_clock_hz % (arb * tq) == 0,
			'${arb}/${data}: ${tq} quanta gives no whole prescaler for the arbitration phase'
		assert vector_fd_clock_hz % (data * tq) == 0,
			'${arb}/${data}: ${tq} quanta gives no whole prescaler for the data phase'
		// The prescaler has to be something the controller can hold, and a bit needs enough
		// quanta to place a sample point in.
		assert vector_fd_clock_hz / (arb * tq) <= 256
		assert tq >= 8
		// sjw may not exceed the segment it shortens, or resynchronisation runs past the bit.
		assert sjw >= 1 && sjw <= t2
		// The sample point sits where CiA 601-3 asks, within rounding of one quantum.
		sp := f64(1 + t1) / f64(tq)
		assert sp > 0.72 && sp < 0.86, '${arb}/${data}: sample point at ${sp}'
	}
}

// A classic channel asks the same function for its timing, and must not be made to satisfy a
// data phase it does not have.
fn test_fd_segments_ignore_an_absent_data_phase() {
	t1, t2, _ := vector_fd_segments(500000, 0)
	tq := 1 + t1 + t2
	assert vector_fd_clock_hz % (500000 * tq) == 0
}
