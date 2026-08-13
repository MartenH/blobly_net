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
	assert vendor_iface('pcan:PCAN_USBBUS1@250000')
	assert vendor_iface('kvaser:0')
	assert !vendor_iface('inproc:bench@A')
	assert !vendor_iface('vcan0')
	assert !vendor_iface('pcan0'), 'an ordinary SocketCAN interface named pcan0 is not the driver'
}

// And the same distinction decides whether an echo can be expected at all.
fn test_the_vendor_backends_do_not_echo_our_sends() {
	assert echoes_own_sends('vcan0')
	assert echoes_own_sends('inproc:CAN1')
	assert !echoes_own_sends('pcan:PCAN_USBBUS1@500000')
	assert !echoes_own_sends('kvaser:0')
	assert echoes_own_sends('pcan0'), 'SocketCAN echoes, whatever the interface happens to be called'
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
