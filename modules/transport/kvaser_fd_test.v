module transport

// The Kvaser CAN-FD rules that are pure decisions: which data rates map to which canlib
// constant, and which payload lengths FD can actually carry. The wire itself is verified by
// cmd/kvasercheck on a bench (docs/windows_can_hardware.md) — no CI runner has an adapter, so
// what CI can hold to account is the arithmetic and the refusals.

fn test_fd_data_rates_map_to_canlib_constants() {
	assert kvaser_fd_data_code(500000)! == -1000
	assert kvaser_fd_data_code(1000000)! == -1001
	assert kvaser_fd_data_code(2000000)! == -1002
	assert kvaser_fd_data_code(4000000)! == -1003
	assert kvaser_fd_data_code(8000000)! == -1004
}

// A rate canlib has no constant for is refused by NAME, not silently rounded to a neighbour: the
// operator's bus partner is configured at some exact number, and quietly running at a different
// one is the failure mode that produces error frames nobody can account for.
fn test_an_unlisted_fd_data_rate_is_refused() {
	if _ := kvaser_fd_data_code(3000000) {
		assert false, '3 Mbit/s has no canFD_BITRATE_* constant and must not be accepted'
	}
	if _ := kvaser_fd_data_code(0) {
		assert false, 'zero is not a data rate'
	}
}

// The arbitration map is a DIFFERENT family of constants, and the two must not be confused: both
// are small negative numbers, so a mix-up compiles, runs, and configures the wrong phase.
fn test_arbitration_and_data_codes_are_different_families() {
	assert kvaser_bitrate_code(500000)! == -2 // canBITRATE_500K
	assert kvaser_fd_data_code(500000)! == -1000 // canFD_BITRATE_500K_80P
	assert kvaser_bitrate_code(1000000)! == -1
	assert kvaser_fd_data_code(1000000)! == -1001
}

// FD has sixteen lengths, not sixty-five. 9, 10 and 11 have no DLC encoding at all, and the
// Kvaser send path checks against transport's own `fd_lengths` rather than a second copy of it —
// this test is here to keep that the case, since a private table beside one backend is how the
// same rule ends up with two answers.
fn test_fd_payload_lengths() {
	for n in 0 .. 9 {
		assert n in fd_lengths, '${n} bytes is a valid FD length'
	}
	for n in [12, 16, 20, 24, 32, 48, 64] {
		assert n in fd_lengths, '${n} bytes is a valid FD length'
	}
	for n in [9, 10, 11, 13, 17, 33, 63, 65, 100] {
		assert n !in fd_lengths, '${n} bytes has no CAN-FD encoding'
	}
	assert fd_lengths.len == 16
}

// Kvaser carries FD now, so the shared capability list has to say so — the GUI and the headless
// runner both ask this one function whether a project's adapter can carry an FD frame.
fn test_kvaser_now_carries_fd() {
	assert adapter_carries_fd('kvaser')
	assert adapter_carries_fd('KVASER'), 'the answer is about the adapter, not its spelling'
	assert adapter_carries_fd('pcan'), 'PCAN carries FD too since #217'
	assert !adapter_carries_fd('doip')
	assert adapter_carries_fd('vector')
}

// The address is where FD is asked for, and the data rate IS the flag.
fn test_kvaser_fd_address_shape() {
	arb, data, fd := vendor_split_fd_rate('500000/2000000', 500000)!
	assert arb == 500000 && data == 2000000 && fd

	a2, d2, fd2 := vendor_split_fd_rate('250000', 500000)!
	assert a2 == 250000 && d2 == 0 && !fd2, 'one rate is classic, and names no data phase'

	// Same rate twice is FD without a bit-rate switch — 64-byte payloads at the arbitration
	// rate, which is a real configuration and has to remain spellable.
	a3, d3, fd3 := vendor_split_fd_rate('500000/500000', 500000)!
	assert a3 == 500000 && d3 == 500000 && fd3

	if _, _, _ := vendor_split_fd_rate('2000000/500000', 500000) {
		assert false, 'a data phase slower than arbitration is backwards and must be refused'
	}
}

// The channel half of the address gets the same "digits only" rule the rate has, and for the
// same reason: `.int()` takes a numeric prefix, so a typo opened a channel nobody named.
fn test_kvaser_channel_must_be_a_number() {
	assert kvaser_spec('0')!.channel == 0
	assert kvaser_spec('2@250000')!.channel == 2
	if _ := kvaser_spec('0abc') {
		assert false, '"0abc" is not a channel number'
	}
	if _ := kvaser_spec('') {
		assert false, 'an empty body names no channel'
	}
	if _ := kvaser_spec('0@500000@250000') {
		assert false, 'two bitrates in one address must be refused'
	}
}

fn test_kvaser_spec_carries_the_fd_pair() {
	s := kvaser_spec('1@500000/2000000')!
	assert s.channel == 1 && s.bitrate == 500000 && s.data_bitrate == 2000000 && s.fd
	c := kvaser_spec('1@250000')!
	assert c.channel == 1 && c.bitrate == 250000 && c.data_bitrate == 0 && !c.fd
	d := kvaser_spec('3')!
	assert d.bitrate == 500000 && !d.fd, 'no rate at all means the classic default'
}

// FD ARBITRATION IS A DIFFERENT MAP AGAIN. canlib's classic canBITRATE_500K samples at 62.5%
// while the FD family samples at 80%, so an FD channel that took the classic constant would
// arbitrate at a sample point no ordinary partner uses — and a loopback bench cannot notice,
// because both ends share the timing.
fn test_fd_arbitration_uses_the_80_percent_family() {
	assert kvaser_fd_arb_code(500000)! == -1000
	assert kvaser_fd_arb_code(1000000)! == -1001
	// The classic map answers the same rates with different constants; that is the whole hazard.
	assert kvaser_bitrate_code(500000)! == -2
	assert kvaser_bitrate_code(1000000)! == -1
	// A rate the 80% family does not offer is refused rather than quietly taking the 62.5% one.
	for r in [250000, 125000, 2000000] {
		if _ := kvaser_fd_arb_code(r) {
			assert false, '${r} has no 80% FD arbitration constant and must not fall back'
		}
	}
}

// The address validator runs the SAME rules open_kvaser does, so an editor can refuse before a
// rate is persisted. Anything it accepts, the open accepts.
fn test_kvaser_address_error_matches_the_open_rules() {
	assert kvaser_address_error('kvaser:0@500000/2000000') == none
	assert kvaser_address_error('kvaser:1@1000000/8000000') == none
	assert kvaser_address_error('kvaser:0@250000') == none // classic keeps the full range
	// FD at an arbitration rate the 80% family lacks
	assert kvaser_address_error('kvaser:0@250000/2000000') != none
	// a data rate canlib has no constant for
	assert kvaser_address_error('kvaser:0@500000/3000000') != none
	// and the syntax rules underneath
	assert kvaser_address_error('kvaser:0@500000@250000') != none
	assert kvaser_address_error('kvaser:x@500000') != none
}

// Kvaser composes a data phase into its address now, which is a different question from whether
// it can carry an FD frame: SocketCAN carries FD but its data phase is set by `ip link`.
fn test_which_adapters_configure_a_data_phase() {
	assert adapter_configures_data_phase('vector')
	assert adapter_configures_data_phase('kvaser')
	assert adapter_configures_data_phase('pcan')
	assert !adapter_configures_data_phase('socketcan')
	assert !adapter_configures_data_phase('vcan')
	// carrying and configuring are not the same list
	assert adapter_carries_fd('vcan') && !adapter_configures_data_phase('vcan')
}

// `kvaser:virtual0` was documented as the no-hardware path and never worked as advertised: the
// old parser's `.int()` made it channel 0, which is PHYSICAL wherever an adapter is fitted. It is
// refused now — and refused by name, because a bare "not a number" would leave the reader with
// the same wrong idea about where the number comes from.
fn test_the_documented_virtual_spelling_is_refused_by_name() {
	err := kvaser_spec('virtual0') or {
		assert err.msg().contains('kvasercheck --list'), 'the refusal must say where the number comes from'
		assert err.msg().contains('virtual0')
		return
	}
	assert false, '"virtual0" must not parse as a channel'
}

// The generic refusal points at the same place, without the virtual-specific history.
fn test_a_non_numeric_channel_names_the_listing_tool() {
	if _ := kvaser_spec('abc') {
		assert false, '"abc" is not a channel'
	}
}

// canlib answers a protocol clash with canERR_NOTFOUND, which it renders "Specified device not
// found" — for a device that is enumerated and present. Measured on the bench: classic+classic
// and FD+FD at one rate both open, classic<->FD is refused with -3, and two FD handles at
// DIFFERENT data rates both open (which is why destination_conflicts still has to refuse that
// from the file). The message has to name the probable cause; repeating canlib's is worse than
// useless because it sends the reader after a cable.
fn test_the_lying_open_status_is_translated() {
	m := kvaser_open_refusal(-3, 2, true)
	assert m.contains('channel 2 is enumerated')
	assert m.contains('classic'), 'it must name the protocol this process may already hold'
	assert m.contains('Stop and Start')
	// the FD/classic direction flips with the request
	c := kvaser_open_refusal(-3, 0, false)
	assert c.contains('CAN-FD')
	// anything else is passed through as itself rather than guessed at
	assert kvaser_open_refusal(-7, 0, true) == 'canStatus -7'
}

// THE FLAGS DECODE, pinned. This is the half of #177 that shipped wrong and looked right: canlib
// reports a remote frame by setting canMSG_RTR in the same word it reports everything else in, the
// shim never read that bit, and every remote frame on the wire came up as ordinary data. Nothing
// about that is visible from outside — it needs a Kvaser and a second node — so it went unnoticed
// through the send-side fix that was supposed to close the issue.
//
// The constants are canlib's. A test that restated them would agree with itself; what it catches
// is a value edited, an assignment dropped, or a decode quietly rewired (codex round 1 on #205).

fn test_a_remote_frame_is_decoded_as_remote() {
	f := kvaser_decode_flags(kvaser_msg_std | kvaser_msg_rtr)
	assert f.rtr, 'canMSG_RTR is what says the frame is a request'
	assert !f.extended
	assert !f.fd
}

fn test_an_ordinary_data_frame_is_not_remote() {
	f := kvaser_decode_flags(kvaser_msg_std)
	assert !f.rtr, 'a decode that hard-codes rtr would pass the test above on its own'
	assert !f.error_frame
}

fn test_extended_is_read_from_the_flag_and_not_from_the_id() {
	assert kvaser_decode_flags(kvaser_msg_ext).extended
	assert !kvaser_decode_flags(kvaser_msg_std).extended
}

// FD, BRS and ESI ride the HIGH half of the same word. A decode that masked with the classic
// constants would report every FD frame as classic, which is the silent downgrade this backend
// refuses to make anywhere else.
fn test_the_fd_flags_are_read_from_the_high_half() {
	f := kvaser_decode_flags(kvaser_msg_std | kvaser_fdmsg_fdf | kvaser_fdmsg_brs)
	assert f.fd
	assert f.brs
	assert !f.esi
	assert !f.rtr, 'CAN-FD has no remote frame, and the bits do not collide'
}

// ESI is a RECEIVED STATUS — the transmitter was error-passive — not something the sender chose.
fn test_esi_is_carried() {
	assert kvaser_decode_flags(kvaser_msg_std | kvaser_fdmsg_fdf | kvaser_fdmsg_esi).esi
	assert !kvaser_decode_flags(kvaser_msg_std | kvaser_fdmsg_fdf).esi
}

fn test_an_error_frame_is_not_a_frame() {
	assert kvaser_decode_flags(kvaser_msg_error_frame).error_frame
	assert !kvaser_decode_flags(kvaser_msg_std).error_frame
}

// The values themselves, against canlib's headers. Transcribed once; if one is ever edited this
// is what says so, rather than a bench three commits later.
fn test_the_constants_are_canlibs() {
	assert kvaser_msg_rtr == u32(0x0001)
	assert kvaser_msg_std == u32(0x0002)
	assert kvaser_msg_ext == u32(0x0004)
	assert kvaser_msg_error_frame == u32(0x0020)
	assert kvaser_fdmsg_fdf == u32(0x01_0000)
	assert kvaser_fdmsg_brs == u32(0x02_0000)
	assert kvaser_fdmsg_esi == u32(0x04_0000)
	// The classic flags and the FD flags must not overlap, or one would be read as the other.
	classic := kvaser_msg_rtr | kvaser_msg_std | kvaser_msg_ext | kvaser_msg_error_frame
	fdbits := kvaser_fdmsg_fdf | kvaser_fdmsg_brs | kvaser_fdmsg_esi
	assert classic & fdbits == 0
}
