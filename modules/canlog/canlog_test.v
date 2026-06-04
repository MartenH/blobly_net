module canlog

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
