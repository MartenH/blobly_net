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
