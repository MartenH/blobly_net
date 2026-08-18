module transport

// What the caller asked for is not always what goes out: SocketCAN masks the id to its declared
// width and truncates a classic payload to 8 bytes. Recording the request rather than the
// transmission records a frame that never existed — and, for echo matching, one that can never
// come back, so it reads as a false BUS row plus an unconfirmed one of ours.

fn test_a_standard_id_is_masked_to_eleven_bits() {
	f := wire_frame('vcan0', CanFrame{
		id:   0x800
		data: [u8(1)]
	})
	assert f.id == 0x000, 'the wire carries 0x000; recording 0x800 invents a frame'
}

fn test_an_extended_id_is_masked_to_twenty_nine_bits() {
	f := wire_frame('vcan0', CanFrame{
		id:       0x2000_0001
		extended: true
		data:     [u8(1)]
	})
	assert f.id == 0x2000_0001 & 0x1FFF_FFFF
}

fn test_a_classic_payload_is_truncated_to_eight() {
	f := wire_frame('vcan0', CanFrame{
		id:   0x100
		data: []u8{len: 12, init: u8(index)}
	})
	assert f.data.len == 8
	assert f.data[7] == 7
}

fn test_a_frame_that_already_fits_is_returned_unchanged() {
	orig := CanFrame{
		id:   0x7FF
		data: [u8(1), 2, 3]
	}
	f := wire_frame('vcan0', orig)
	assert f.id == orig.id && f.data == orig.data
}

// The vendor backends carry an `@<bitrate>` suffix; nothing else uses `@` as syntax, and
// `inproc:bench@A` is a perfectly good bus NAME — treating it as universal sent every emitter to
// a different hub than the monitor.
fn test_only_the_vendor_backends_carry_a_bitrate_suffix() {
	assert !vendor_iface('inproc:bench@A')
	assert !vendor_iface('vcan0')
	assert !vendor_iface('pcan0'), 'an ordinary SocketCAN interface named pcan0 is not the driver'
	$if windows {
		assert vendor_iface('pcan:PCAN_USBBUS1@250000')
		assert vendor_iface('kvaser:0')
	}
}

// And the same distinction decides whether an echo can be expected at all.
fn test_the_vendor_backends_do_not_echo_our_sends() {
	assert echoes_own_sends('vcan0')
	assert echoes_own_sends('inproc:CAN1')
	assert echoes_own_sends('pcan0'), 'SocketCAN echoes, whatever the interface happens to be called'
	// The vendor backends exist only on Windows — open_linux.v has no pcan:/kvaser: branch, so
	// there such a name is an ordinary SocketCAN interface and DOES echo. Asserting otherwise
	// would encode a Windows-only truth as a universal one.
	$if windows {
		assert !echoes_own_sends('pcan:PCAN_USBBUS1@500000')
		assert !echoes_own_sends('kvaser:0')
		assert vendor_iface('pcan:PCAN_USBBUS1@250000')
	} $else {
		assert echoes_own_sends('pcan:PCAN_USBBUS1@500000')
		assert !vendor_iface('pcan:PCAN_USBBUS1@250000')
	}
}

// The software buses carry what they are handed — that is what makes in-process CAN-FD payloads
// work — so "what the wire will carry" is the frame itself. Normalising there would not describe
// the transmission, it would damage it.
fn test_a_software_bus_is_not_clamped() {
	long := CanFrame{
		id:   0x100
		data: []u8{len: 24, init: u8(index)}
	}
	f := wire_frame('inproc:CAN1', long)
	assert f.data.len == 24, 'an in-process CAN-FD payload was truncated'
	u := wire_frame('udp:239.0.0.1:5000', long)
	assert u.data.len == 24
	assert !clamps_to_classic('inproc:CAN1')
	assert clamps_to_classic('vcan0')
	assert clamps_to_classic('pcan:PCAN_USBBUS1@500000')
}

// …and an id the software bus would carry verbatim is left alone too.
fn test_a_software_bus_keeps_an_over_wide_id() {
	f := wire_frame('inproc:CAN1', CanFrame{
		id:   0x800
		data: [u8(1)]
	})
	assert f.id == 0x800
}

// `udp0` and `inproc0` are valid SocketCAN interface names on Linux and open as SocketCAN, so a
// loose prefix test would leave their frames un-normalised while the kernel clamped them — the
// record and the echo then disagree.
fn test_a_socketcan_interface_named_like_a_software_bus() {
	assert !software_iface('udp0')
	assert !software_iface('inproc0')
	assert clamps_to_classic('udp0')
	assert clamps_to_classic('inproc0')
	// the vendor drivers reject what they cannot send, so nothing is masked for them: a
	// malformed frame must fail loudly rather than go out as a different, valid one
	$if windows {
		assert !clamps_to_classic('pcan:PCAN_USBBUS1@500000')
		assert wire_frame('pcan:PCAN_USBBUS1', CanFrame{ id: 0x800, data: [u8(1)] }).id == 0x800
	}
	assert software_iface('inproc')
	assert software_iface('inproc:CAN1')
	assert software_iface('udp:239.0.0.1:5000')
}

// One bus, several spellings. Keyed by the raw string, a monitor opened as `inproc` and a
// generator override written `inproc:CAN` would not recognise each other's frames — the echo
// arrives and is filed as the device under test's.
fn test_equivalent_bus_spellings_share_one_identity() {
	assert canonical_iface('inproc') == canonical_iface('inproc:CAN')
	assert canonical_iface('udp') == canonical_iface('udp:239.63.42.1:20000')
	assert canonical_iface('udp:239.63.42.1') == canonical_iface('udp')
	// …and genuinely different buses stay different
	assert canonical_iface('inproc:CAN1') != canonical_iface('inproc:CAN2')
	assert canonical_iface('udp:239.0.0.9:20000') != canonical_iface('udp')
	assert canonical_iface('vcan0') == 'vcan0'
}

// A CAN-FD payload is not any length: the DLC encodes 0..8, 12, 16, 20, 24, 32, 48, 64 and
// nothing else. A 9-byte frame does not exist on the wire — it goes out as 12, padded. Sending
// the raw 9 would be rejected by the kernel, and truncating to 8 would change the message.
fn test_fd_lengths_round_up_to_something_encodable() {
	assert fd_padded_len(0) == 0
	assert fd_padded_len(8) == 8
	assert fd_padded_len(9) == 12
	assert fd_padded_len(12) == 12
	assert fd_padded_len(13) == 16
	assert fd_padded_len(33) == 48
	assert fd_padded_len(64) == 64
	// nothing valid exists above 64, so it clamps rather than inventing a length
	assert fd_padded_len(100) == 64
}

// The classic path must not acquire FD semantics by accident: a frame that says nothing about
// FD is a classic frame, and that is what every existing caller constructs.
fn test_a_frame_is_classic_unless_it_says_otherwise() {
	f := CanFrame{
		id:   0x100
		data: [u8(1), 2, 3]
	}
	assert !f.fd
	assert !f.brs
}

// The RECORD must equal the WIRE. wire_frame is what the GUI stores as its pending echo, so if
// a backend pads afterwards the record holds 9 bytes while 12 go out, the echo never matches its
// own record, and the frame appears as somebody else's traffic plus one of ours that never
// returned. Software buses do not clamp ids or lengths, but they DO pad.
fn test_wire_frame_pads_fd_on_a_software_bus() {
	f := CanFrame{
		id:   0x100
		fd:   true
		data: [u8(1), 2, 3, 4, 5, 6, 7, 8, 9]
	}
	w := wire_frame('inproc:x', f)
	assert w.data.len == 12, 'got ${w.data.len}'
	assert w.data[..9] == f.data
	assert w.data[9..] == [u8(0), 0, 0]
	assert w.fd
}

// A classic frame on a software bus is still passed through untouched.
fn test_wire_frame_leaves_classic_software_frames_alone() {
	f := CanFrame{
		id:   0x100
		data: [u8(1), 2, 3]
	}
	assert wire_frame('inproc:x', f).data == [u8(1), 2, 3]
	assert wire_frame('udp:239.0.0.1:9', f).data == [u8(1), 2, 3]
}

// And an FD frame is NOT clamped to 8 on a clamping backend: SocketCAN carries it whole, and the
// vendor backends refuse it outright — truncating here would record a frame that never goes out.
fn test_wire_frame_does_not_clamp_an_fd_payload() {
	mut big := []u8{len: 64}
	big[63] = 0xAB
	w := wire_frame('vcan0', CanFrame{
		id:   0x100
		fd:   true
		data: big
	})
	assert w.data.len == 64
	assert w.data[63] == 0xAB
}

// A conflict check that compares interface STRINGS misses two spellings of one bus. The software
// buses were covered by canonical_iface; the Windows vendor backends were not, and they accept
// several spellings of one channel plus a default bitrate — so two mappings could address one
// physical channel while looking different, and two recorded buses would land on one wire.
//
// PLATFORM-DEPENDENT, exactly as vendor_iface is: on Linux `pcan:usb1` is not a vendor handle at
// all, it is an ordinary SocketCAN interface NAME, and `pcan:1` is a different one. Collapsing
// them there would merge two real interfaces — the opposite mistake.
fn test_one_vendor_channel_has_one_destination_identity() {
	$if windows {
		// 0x51 IS PCAN_USBBUS1 — resolved through the backend's own function, so every spelling
		// of one channel lands on one identity rather than on one of two parallel rule sets.
		for a in ['pcan:PCAN_USBBUS1', 'pcan:usb1', 'pcan:1', 'pcan:0x51', 'pcan:PCAN_USBBUS1@500000'] {
			assert same_destination(a, 'pcan:usb1@500000'), '${a} was treated as a different bus'
		}
		assert !same_destination('pcan:usb1', 'pcan:usb2')
		assert !same_destination('pcan:usb1@500000', 'pcan:usb1@250000')
	} $else {
		// here they are distinct SocketCAN names and must stay distinct
		assert !same_destination('pcan:usb1', 'pcan:1')
		assert same_destination('pcan:usb1', 'pcan:usb1')
	}
}

// The software buses keep the behaviour canonical_iface already gave them, on every platform.
fn test_software_bus_spellings_still_collapse() {
	assert same_destination('inproc', 'inproc:CAN')
	assert same_destination('udp', 'udp:239.63.42.1:20000')
	assert !same_destination('inproc:a', 'inproc:b')
	assert !same_destination('vcan0', 'vcan1')
}

// The spelling→handle rules, tested on any platform because they are pure string logic. They
// decide whether two mappings address one physical channel, and a second implementation of them
// had already drifted: `usb1` keyed as 1 while `0x51` keyed as 81, for the same channel.
fn test_pcan_spellings_resolve_to_one_handle() {
	want := u16(0x51) // PCAN_USBBUS1
	for spelling in ['PCAN_USBBUS1', 'pcan_usbbus1', 'usb1', 'USB1', '1', '0x51', ' usb1 '] {
		got := pcan_handle(spelling) or {
			assert false, '${spelling}: ${err}'
			return
		}
		assert got == want, '${spelling} resolved to 0x${got:X}, not 0x${want:X}'
	}
	assert pcan_handle('usb8') or { 0 } == 0x58
	// out of range and nonsense are errors, not a silent zero that would collide with everything
	if _ := pcan_handle('usb9') {
		assert false, 'usb9 is not a PCAN channel'
	}
	if _ := pcan_handle('nonsense') {
		assert false, 'nonsense is not a PCAN channel'
	}
}

// The backends parse numbers, so the identity must too: open_kvaser takes .int() of the channel
// and both vendor opens take .int() of the bitrate. Compared as strings, `kvaser:0` and
// `kvaser:00`, or `@500000` and `@0500000`, look like different buses while opening the same one.
//
// Windows-only, like every other part of this: on Linux `pcan:`/`kvaser:` are ordinary SocketCAN
// interface NAMES that no vendor backend parses, and normalising their digits would merge two
// real interfaces.
fn test_numeric_vendor_spellings_are_one_destination() {
	$if windows {
		assert same_destination('pcan:usb1@500000', 'pcan:usb1@0500000')
		assert same_destination('kvaser:0', 'kvaser:00')
		assert same_destination('kvaser:1@500000', 'kvaser:01@0500000')
		assert !same_destination('kvaser:0', 'kvaser:1')
		assert !same_destination('kvaser:0@500000', 'kvaser:0@250000')
	} $else {
		// distinct SocketCAN names stay distinct
		assert !same_destination('kvaser:0', 'kvaser:00')
	}
}
