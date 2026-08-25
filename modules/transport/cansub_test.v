module transport

// The address, and the identity derived from it. Both are string logic, so both are checked here
// rather than discovered on a bench with four channels running.

fn test_a_plain_address() {
	s := parse_cansub_iface('cansub:e5a16adf/1')!
	assert s.id == 'e5a16adf'
	assert s.channel == 1
	assert s.arb == 500000, 'the default rate should apply when none is named'
	assert !s.fd
	assert s.data == 0, 'a classic address must not configure a data phase'
}

fn test_an_address_with_a_bitrate() {
	s := parse_cansub_iface('cansub:e5a16adf/3@250000')!
	assert s.channel == 3
	assert s.arb == 250000
	assert !s.fd
}

// The data rate IS the FD flag, the same rule the Vector address follows — one thing to say, so
// there is no address that claims FD while naming a single rate.
fn test_a_data_rate_asks_for_fd() {
	s := parse_cansub_iface('cansub:e5a16adf/2@500000/2000000')!
	assert s.fd
	assert s.arb == 500000
	assert s.data == 2000000
}

fn test_fd_at_the_same_rate_is_a_real_configuration() {
	s := parse_cansub_iface('cansub:e5a16adf/1@500000/500000')!
	assert s.fd, '64-byte payloads with no bit-rate switch is a configuration, and must be spellable'
	assert s.data == 500000
}

// The device numbers its channels from 1 and answers 404 for 0 — several seconds into an open, as
// an unhelpful HTTP error. Caught while it is still a string somebody typed.
fn test_channel_zero_is_refused() {
	parse_cansub_iface('cansub:e5a16adf/0') or {
		assert err.msg().contains('from 1')
		return
	}
	assert false, 'accepted channel 0, which the device does not have'
}

fn test_addresses_that_make_no_sense_are_refused() {
	for bad in ['cansub:e5a16adf', 'cansub:/1', 'cansub:e5a16adf/x', 'cansub:e5a16adf/1@abc',
		'cansub:e5a16adf/1@250000@500000', 'vector:1'] {
		parse_cansub_iface(bad) or { continue }
		assert false, 'accepted "${bad}"'
	}
}

// A data phase slower than arbitration is refused by the shared rule — the data phase is the fast
// one, and a controller asked for the reverse produces a bus nothing else can read.
fn test_a_slower_data_phase_is_refused() {
	parse_cansub_iface('cansub:e5a16adf/1@500000/125000') or { return }
	assert false, 'accepted a data phase slower than arbitration'
}

// IDENTITY. The wire is the device and the channel; the rate is a setting on it. Keyed with the
// rate, a 250k row and a 500k row on one channel would be two wires that never meet, and the
// check that exists to find exactly that disagreement could not fire.
fn test_the_rate_is_not_part_of_the_wire() {
	a := wire_key_for('cansub', 'cansub:e5a16adf/1@250000')
	b := wire_key_for('cansub', 'cansub:e5a16adf/1@500000')
	assert a == b, 'one channel at two rates must be one wire: ${a} vs ${b}'
}

fn test_different_channels_are_different_wires() {
	a := wire_key_for('cansub', 'cansub:e5a16adf/1@500000')
	b := wire_key_for('cansub', 'cansub:e5a16adf/2@500000')
	assert a != b
}

fn test_different_devices_are_different_wires() {
	a := wire_key_for('cansub', 'cansub:e5a16adf/1@500000')
	b := wire_key_for('cansub', 'cansub:aabbccdd/1@500000')
	assert a != b, 'two devices are not one wire — a bench has several'
}

// Two spellings of one address are one destination, or a project mapping the same channel twice
// goes undetected.
fn test_spelling_does_not_split_a_destination() {
	a := destination_key_for('cansub', 'cansub:E5A16ADF/1@500000')
	b := destination_key_for('cansub', ' cansub:e5a16adf/1@0500000 ')
	assert a == b, '${a} vs ${b}'
}

// Classic and FD on one channel are the same WIRE — so the conflict check groups them and can
// report the disagreement — but NOT the same destination, so nothing hands an FD opener a
// connection configured for classic.
fn test_classic_and_fd_share_a_wire_but_not_a_destination() {
	classic := 'cansub:e5a16adf/1@500000'
	fd := 'cansub:e5a16adf/1@500000/2000000'
	assert wire_key_for('cansub', classic) == wire_key_for('cansub', fd)
	assert destination_key_for('cansub', classic) != destination_key_for('cansub', fd)
}

// A CANsub reports its own transmissions back over the same socket. Told otherwise, every frame
// this tester sends would be filed a second time as the ECU's — the defect #139 fixed for Vector.
fn test_a_cansub_echoes_its_own_sends() {
	assert echoes_own_sends('cansub:e5a16adf/1@500000')
}

// It refuses an out-of-range frame rather than truncating it, like the other hardware backends —
// a malformed frame is something a bench wants rejected, not quietly turned into a valid
// different one.
fn test_a_cansub_does_not_clamp() {
	assert !clamps_to_classic('cansub:e5a16adf/1@500000')
}

// Recognised on BOTH platforms, unlike the vendor-DLL backends. On Linux `pcan:bench` is an
// ordinary SocketCAN name, but a CANsub is an HTTP server on the end of a USB cable and means the
// same thing everywhere.
fn test_a_cansub_is_hardware_on_every_platform() {
	assert vendor_iface('cansub:e5a16adf/1'), 'a CANsub is not a SocketCAN name on Linux'
}

// The project layer asks by ADAPTER whether FD can reach the wire. A CANsub can.
fn test_the_adapter_carries_fd() {
	assert adapter_carries_fd('cansub')
}
