module project

import transport

// ---- how a channel frames what this app originates (#185) -------------------------------------
//
// Until this existed, every frame the app BUILT was classic, so a channel configured as CAN-FD and
// verified on hardware at an 8 Mbit/s data phase could only be exercised by replay. The rule is
// declared rather than inferred: `type: canfd` is the operator saying so, and nothing here reads a
// format out of a payload size.

fn test_a_classic_channel_originates_classic_frames() {
	c := Channel{
		name:    'CAN1'
		adapter: 'vector'
		iface:   'vector:1'
		bitrate: 500000
	}
	fr := c.origination_framing()
	assert !fr.fd, 'a classic channel must not originate FD'
	assert !fr.brs, 'and cannot switch a rate it has not got'
}

fn test_an_fd_channel_originates_fd_and_switches_when_the_phases_differ() {
	c := Channel{
		name:         'CAN1'
		adapter:      'vector'
		iface:        'vector:1'
		bitrate:      500000
		fd:           true
		data_bitrate: 2000000
	}
	fr := c.origination_framing()
	assert fr.fd
	assert fr.brs, 'a distinct data phase is what BRS switches into'
}

// A REAL CONFIGURATION, and the only way to ask for it: 64-byte payloads at the arbitration rate.
// With equal phases there is no faster phase to switch into and the XL library refuses the flag,
// which is why vectorcheck's own probe derives BRS the same way.
fn test_equal_phases_are_fd_without_the_bit_rate_switch() {
	c := Channel{
		bitrate:      500000
		fd:           true
		data_bitrate: 500000
	}
	fr := c.origination_framing()
	assert fr.fd, '64-byte payloads are still FD'
	assert !fr.brs, 'there is no faster phase to switch into'
}

fn test_framed_stamps_a_plain_frame_from_the_channel() {
	c := Channel{
		bitrate:      500000
		fd:           true
		data_bitrate: 2000000
	}
	got := c.framed(transport.CanFrame{ id: 0x100, data: []u8{len: 64} })
	assert got.fd && got.brs
	assert got.id == 0x100, 'everything else survives the stamp'
	assert got.data.len == 64
}

// STAMPS UPWARD ONLY. A caller that has already said `fd` keeps it whatever the channel says —
// demoting an FD frame to classic silently is the truncation this change exists to stop.
fn test_framed_never_contradicts_a_frame_that_already_says_fd() {
	classic_chan := Channel{ bitrate: 500000 }
	f := transport.CanFrame{ id: 0x100, fd: true, brs: true, data: []u8{len: 64} }
	got := classic_chan.framed(f)
	assert got.fd, 'a classic channel must not demote an FD frame it was handed'
	assert got.brs
}

fn test_framed_leaves_a_classic_channels_frames_alone() {
	c := Channel{ bitrate: 500000 }
	got := c.framed(transport.CanFrame{ id: 0x100, data: []u8{len: 8} })
	assert !got.fd && !got.brs
}

// AN UNSET NOMINAL RATE IS THE DEFAULT, here as it is where the address is composed. Reading the
// raw zero made a 500000 data phase look DIFFERENT from the arbitration rate, so an equal-phase
// channel originated frames demanding a switch the wire has no faster phase for (codex #202 r2).
fn test_brs_compares_against_the_rate_the_channel_will_open_with() {
	c := Channel{ fd: true, bitrate: 0, data_bitrate: default_bitrate }
	assert c.nominal_bitrate() == default_bitrate, 'an unset nominal rate reads as the default'
	fr := c.origination_framing()
	assert fr.fd
	assert !fr.brs, 'an unset nominal rate is the default, so these phases are equal'
}

// ---- what gets published per WIRE ------------------------------------------------------------

fn test_an_fd_row_publishes_its_wire() {
	rows := [
		Channel{ name: 'A', adapter: 'virtual', iface: 'inproc:W1', bitrate: 500000, fd: true, data_bitrate: 2000000, enabled: true },
	]
	m := wire_framings(rows)
	got := m[transport.wire_key('inproc:W1')] or { transport.Framing{} }
	assert got.fd && got.brs
}

fn test_a_disabled_or_classic_row_publishes_nothing() {
	rows := [
		Channel{ name: 'off', adapter: 'virtual', iface: 'inproc:W2', fd: true, data_bitrate: 2000000, enabled: false },
		Channel{ name: 'classic', adapter: 'virtual', iface: 'inproc:W3', bitrate: 500000, enabled: true },
	]
	assert wire_framings(rows).len == 0
}

// AN ADAPTER THAT REFUSES FD MUST NOT BE DECLARED FD. PCAN and Kvaser reject an FD frame outright,
// so declaring the wire would turn the row's traffic into nothing — while fd_capability_warnings
// promises the classic half of such a run is real (codex #202 r2).
// PCAN ONLY, since #200 — Kvaser carries FD now, so it is no longer an example of this rule and
// asserting that it still refuses would pin a fact the repo has moved past.
fn test_an_adapter_that_cannot_carry_fd_is_not_declared_fd() {
	rows := [
		Channel{ name: 'A', adapter: 'pcan', iface: 'pcan:PCAN_USBBUS1', bitrate: 500000, fd: true, data_bitrate: 2000000, enabled: true },
	]
	assert wire_framings(rows).len == 0, 'PCAN refuses FD, so its wire must stay classic'
	// …and an adapter that DOES carry it is declared, which is what keeps the rule from being a
	// blanket refusal. Kvaser is the one that changed, so it is the one worth naming.
	kv := [
		Channel{ name: 'B', adapter: 'kvaser', iface: 'kvaser:0', bitrate: 500000, fd: true, data_bitrate: 2000000, enabled: true },
	]
	assert wire_framings(kv).len == 1, 'Kvaser carries FD since #200'
}

// ROWS ON ONE WIRE MUST AGREE. Only Vector is refused a canfd/can mixture by destination_conflicts,
// so elsewhere two enabled rows can legitimately name one wire and disagree — and the table is per
// WIRE, so the first answer would decide for both and promote the classic row's frames.
fn test_rows_that_disagree_about_one_wire_leave_it_undeclared() {
	rows := [
		Channel{ name: 'fd', adapter: 'virtual', iface: 'inproc:W4', bitrate: 500000, fd: true, data_bitrate: 2000000, enabled: true },
		Channel{ name: 'classic', adapter: 'virtual', iface: 'inproc:W4', bitrate: 500000, enabled: true },
	]
	assert wire_framings(rows).len == 0, 'neither row overrules the other'
	// …while two rows that AGREE still publish.
	agree := [
		Channel{ name: 'a', adapter: 'virtual', iface: 'inproc:W5', bitrate: 500000, fd: true, data_bitrate: 2000000, enabled: true },
		Channel{ name: 'b', adapter: 'virtual', iface: 'inproc:W5', bitrate: 500000, fd: true, data_bitrate: 2000000, enabled: true },
	]
	assert wire_framings(agree).len == 1
}
