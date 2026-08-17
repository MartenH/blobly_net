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
