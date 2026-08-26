module transport

// Each of these is a frame a backend USED TO ACCEPT and put a different frame on the wire for.
// They are here rather than in a per-backend test because the rule is not a vendor's — it is
// CAN's — and a check that lives in one backend is a check the next backend does not have, which
// is exactly how the CANsub send path shipped without four of them.

fn test_a_remote_fd_frame_is_refused() {
	f := CanFrame{
		id:  0x123
		rtr: true
		fd:  true
	}
	assert frame_shape_error(f) != none, 'CAN-FD has no remote frame — the bit RTR sat in carries FDF'
}

fn test_brs_without_fd_is_refused() {
	// Dropped rather than refused, this records a rate change that never happened: a classic
	// frame has no data phase to switch into.
	f := CanFrame{
		id:  0x123
		brs: true
	}
	assert frame_shape_error(f) != none
}

fn test_a_standard_id_above_eleven_bits_is_refused() {
	// MASKED, this transmitted 0x000 while the trace recorded 0x800 — and wiretap matches an echo
	// on the id, so our own frame came back unattributable and was filed as the ECU's.
	f := CanFrame{
		id: 0x800
	}
	assert frame_shape_error(f) != none, '0x800 does not fit an 11-bit identifier'
	ok := CanFrame{
		id: 0x7FF
	}
	assert frame_shape_error(ok) == none, '0x7FF is the largest standard id and must be allowed'
}

fn test_an_extended_id_above_twenty_nine_bits_is_refused() {
	f := CanFrame{
		id:       0x2000_0000
		extended: true
	}
	assert frame_shape_error(f) != none
	ok := CanFrame{
		id:       0x1FFF_FFFF
		extended: true
	}
	assert frame_shape_error(ok) == none
}

// A standard id is checked against ELEVEN bits even though the frame would fit an extended one:
// `extended` is what the caller declared, and a value that overflows it is the frame contradicting
// itself rather than a wider frame being requested.
fn test_the_width_checked_is_the_declared_one() {
	f := CanFrame{
		id:       0x1FFF
		extended: false
	}
	assert frame_shape_error(f) != none
	g := CanFrame{
		id:       0x1FFF
		extended: true
	}
	assert frame_shape_error(g) == none
}

fn test_a_classic_frame_over_eight_bytes_is_refused() {
	f := CanFrame{
		id:   0x123
		data: []u8{len: 9}
	}
	assert frame_shape_error(f) != none
	ok := CanFrame{
		id:   0x123
		data: []u8{len: 8}
	}
	assert frame_shape_error(ok) == none
}

// A DLC cannot express every length above eight, so nine bytes can only reach the wire padded to
// twelve. Refused, so the padding is the caller's decision and the trace matches the wire.
fn test_an_fd_payload_must_be_a_dlc_length() {
	for n in [9, 10, 11, 13, 63] {
		f := CanFrame{
			id:   0x123
			fd:   true
			data: []u8{len: n}
		}
		assert frame_shape_error(f) != none, '${n} bytes is not a DLC length'
	}
	for n in fd_lengths {
		f := CanFrame{
			id:   0x123
			fd:   true
			data: []u8{len: n}
		}
		assert frame_shape_error(f) == none, '${n} bytes is a DLC length and must be allowed'
	}
}

fn test_an_ordinary_frame_passes() {
	assert frame_shape_error(CanFrame{ id: 0x123, data: [u8(1), 2, 3] }) == none
	assert frame_shape_error(CanFrame{ id: 0x123, rtr: true }) == none
	assert frame_shape_error(CanFrame{ id: 0x123, fd: true, brs: true, data: []u8{len: 64} }) == none
}

// ---- the tiers -----------------------------------------------------------

// The IMPOSSIBLE rules and the LENGTH rules are separated because this repo has three tiers and
// only two of them agree about length: SocketCAN clamps and records the clamp, the software buses
// pad an FD payload to a DLC length, the vendor backends refuse. A frame that is impossible is
// impossible in every tier, which is what lets the software buses check those and not these.

fn test_the_impossible_rules_do_not_include_lengths() {
	// Nine bytes of FD payload is refused by a vendor backend and PADDED by a software one. It is
	// a limit, not a contradiction, so it must not be in the impossible set — putting it there
	// would make `inproc:` refuse what it deliberately pads.
	long_fd := CanFrame{
		id:   0x123
		fd:   true
		data: []u8{len: 9}
	}
	assert frame_impossible_error(long_fd) == none, 'a padded length is not an impossible frame'
	assert frame_shape_error(long_fd) != none, 'but a backend that refuses rather than pads still refuses it'

	long_classic := CanFrame{
		id:   0x123
		data: []u8{len: 9}
	}
	assert frame_impossible_error(long_classic) == none
	assert frame_shape_error(long_classic) != none
}

// Every contradiction, on the other hand, is in both.
fn test_every_impossible_frame_is_also_refused_by_the_full_rules() {
	bad := [
		CanFrame{
			id:  0x123
			rtr: true
			fd:  true
		},
		CanFrame{
			id:  0x123
			brs: true
		},
		CanFrame{
			id: 0x800
		},
		CanFrame{
			id:       0x2000_0000
			extended: true
		},
	]
	for f in bad {
		assert frame_impossible_error(f) != none, 'id 0x${f.id:X} must be impossible'
		assert frame_shape_error(f) != none, 'and refused by the full rules too'
	}
}

fn test_an_ordinary_frame_is_impossible_to_nobody() {
	assert frame_impossible_error(CanFrame{ id: 0x7FF, data: [u8(1)] }) == none
	assert frame_impossible_error(CanFrame{ id: 0x123, rtr: true }) == none
	assert frame_impossible_error(CanFrame{ id: 0x123, fd: true, brs: true, data: []u8{len: 64} }) == none
}
