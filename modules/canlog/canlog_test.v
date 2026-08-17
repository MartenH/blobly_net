module canlog

import transport

fn test_parse_standard() {
	e := parse_line('(1.234567) vcan0 100#AABBCCDD') or { panic('parse failed') }
	assert e.t_s == 1.234567
	assert e.iface == 'vcan0'
	assert e.frame.id == 0x100
	assert e.frame.extended == false
	assert e.frame.rtr == false
	assert e.frame.data == [u8(0xAA), 0xBB, 0xCC, 0xDD]
}

fn test_parse_extended() {
	e := parse_line('(0.000000) can0 18FEF100#0102030405060708') or { panic('parse failed') }
	assert e.frame.id == 0x18FEF100
	assert e.frame.extended == true
	assert e.frame.data.len == 8
}

fn test_parse_empty_payload() {
	e := parse_line('(2.0) vcan0 700#') or { panic('parse failed') }
	assert e.frame.id == 0x700
	assert e.frame.extended == false
	assert e.frame.data.len == 0
}

fn test_parse_rtr() {
	e := parse_line('(3.0) vcan0 200#R') or { panic('parse failed') }
	assert e.frame.rtr == true
	assert e.frame.data.len == 0
}

fn test_skips_blank_and_comment_and_garbage() {
	assert parse_line('') == none
	assert parse_line('   ') == none
	assert parse_line('# a comment') == none
	assert parse_line('not a log line') == none
	assert parse_line('(1.0) vcan0') == none // missing payload
	assert parse_line('(1.0) vcan0 100') == none // missing '#'
	assert parse_line('(1.0) vcan0 ZZ#AA') == none // bad id
	assert parse_line('(1.0) vcan0 100#A') == none // odd-length data
	assert parse_line('(1.0) vcan0 100#GG') == none // bad data nibble
}

fn test_parse_multi_skips_noise() {
	text := '(0.0) vcan0 100#AA\n# comment\n\n(0.1) vcan0 200#BBCC\ngarbage\n'
	entries := parse(text)
	assert entries.len == 2
	assert entries[0].frame.id == 0x100
	assert entries[1].frame.id == 0x200
	assert entries[1].frame.data == [u8(0xBB), 0xCC]
}

fn test_round_trip_extended() {
	line := '(1.234567) vcan0 18FEF100#0102030405060708'
	e := parse_line(line) or { panic('parse failed') }
	assert format_line(e) == line
}

fn test_round_trip_standard() {
	line := '(0.500000) vcan0 100#AABBCC'
	e := parse_line(line) or { panic('parse failed') }
	assert format_line(e) == line
}

fn test_round_trip_rtr() {
	line := '(0.000000) vcan0 200#R'
	e := parse_line(line) or { panic('parse failed') }
	assert format_line(e) == line
}

// The interface field is whitespace-delimited and the payload follows a '#', so a label carrying
// either breaks the whole LINE. The recorder stores a logical channel name and the project editor
// accepts any name, so the writer guarantees the token.
fn test_a_channel_name_with_a_space_still_round_trips() {
	e := LogEntry{
		t_s:   1.5
		iface: 'Powertrain CAN'
		frame: transport.CanFrame{
			id:   0x100
			data: [u8(1), 2]
		}
	}
	line := format_line(e)
	assert line.contains('Powertrain%20CAN'), 'unsafe interface field: ${line}'
	assert line.split(' ').len == 3, 'the line must still have exactly three fields: ${line}'
	back := parse_line(line) or {
		assert false, 'the line we wrote does not parse: ${line}'
		return
	}
	assert back.frame.id == 0x100
	assert back.frame.data == [u8(1), 2]
	// the identity SURVIVES: a lossy token would match no configured channel, so the channel
	// filter would hide its own rows and the verifier could not place them
	assert back.iface == 'Powertrain CAN'
}

// Distinct names must stay distinct — substitution collapsed these two into one channel.
fn test_two_names_that_differ_only_by_the_escape_stay_distinct() {
	a := iface_token('Powertrain CAN')
	b := iface_token('Powertrain_CAN')
	assert a != b
	assert iface_from_token(a) == 'Powertrain CAN'
	assert iface_from_token(b) == 'Powertrain_CAN'
}

// An ordinary candump file has nothing to decode, so foreign logs are untouched.
fn test_a_plain_interface_name_is_left_alone() {
	assert iface_token('vcan0') == 'vcan0'
	assert iface_from_token('vcan0') == 'vcan0'
	assert iface_from_token('can1') == 'can1'
}

fn test_the_payload_separator_cannot_leak_into_the_interface() {
	assert iface_token('a#b') == 'a%23b'
	assert iface_from_token('a%23b') == 'a#b'
	assert iface_token('(x)') == '%28x%29'
	assert iface_token('') == 'can'
	// a literal % is escaped too, or decoding would invent a character
	assert iface_from_token(iface_token('100% sure')) == '100% sure'
}

// A foreign log may legally hold a percent triplet that was never our escaping: decoding it
// would silently rename that channel, and every consumer keys on the name.
fn test_a_foreign_percent_sequence_is_left_alone() {
	assert iface_from_token('CAN%31') == 'CAN%31'
	assert iface_from_token('can%41x') == 'can%41x'
	// …while the ones we actually emit still round-trip
	assert iface_from_token(iface_token('Powertrain CAN')) == 'Powertrain CAN'
	assert iface_from_token(iface_token('a#b')) == 'a#b'
	assert iface_from_token(iface_token('100% sure')) == '100% sure'
}

// candump marks CAN-FD with a second '#' and a flags digit. Without it, a recorded 64-byte frame
// came back as a classic frame with a payload no classic frame can hold, and the FD/BRS bits
// were gone — a recording that cannot reproduce what was captured.
fn test_fd_frames_survive_a_candump_round_trip() {
	mut payload := []u8{len: 64}
	for i in 0 .. 64 {
		payload[i] = u8(i)
	}
	e := LogEntry{
		t_s:   1.5
		iface: 'can0'
		frame: transport.CanFrame{
			id:       0x123
			fd:       true
			brs:      true
			data:     payload
		}
	}
	line := format_line(e)
	assert line.contains('123##1'), 'got ${line[..40]}'
	back := parse_line(line) or {
		assert false, 'the FD line does not parse back'
		return
	}
	assert back.frame.fd
	assert back.frame.brs
	assert back.frame.data.len == 64
	assert back.frame.data == payload
	assert back.frame.id == 0x123
}

// An FD frame without BRS keeps the flag digit at 0 and stays FD.
fn test_fd_without_brs() {
	e := LogEntry{
		t_s:   0.25
		iface: 'can0'
		frame: transport.CanFrame{
			id:   0x7FF
			fd:   true
			data: [u8(1), 2, 3]
		}
	}
	back := parse_line(format_line(e)) or {
		assert false, 'does not parse'
		return
	}
	assert back.frame.fd
	assert !back.frame.brs
	assert back.frame.data == [u8(1), 2, 3]
}

// A classic line must be untouched by any of this.
fn test_classic_lines_are_unchanged() {
	back := parse_line('(1.000000) vcan0 100#AABB') or {
		assert false, 'classic parse broke'
		return
	}
	assert !back.frame.fd
	assert !back.frame.brs
	assert back.frame.data == [u8(0xAA), 0xBB]
}
