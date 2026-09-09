module canlog

import transport

fn entry(iface string, id u32, t f64) LogEntry {
	return LogEntry{
		t_s:   t
		iface: iface
		frame: transport.CanFrame{
			id:   id
			data: [u8(id)]
		}
	}
}

// index_of is the one label-to-index rule; intern only adds a label it does not find, so a
// label exists in the table only once and only if a row carries it.
fn test_index_of_is_the_one_label_rule() {
	l := from_entries([entry('a', 1, 0), entry('b', 2, 1), entry('a', 3, 2)])
	assert l.labels == ['a', 'b']
	assert l.index_of('a') or { -1 } == 0
	assert l.index_of('b') or { -1 } == 1
	assert l.index_of('c') == none
	assert l.all() == [u32(0), 1, 2]
	assert l.entries_of([u32(2), 0]).map(it.frame.id) == [u32(3), 1]
}

fn test_the_label_table_refuses_past_its_width_and_the_entry_is_dropped() {
	mut l := Log{}
	for i in 0 .. max_labels {
		l.labels << 'bus${i}'
	}
	assert l.intern('bus7') or { u16(9999) } == 7, 'a known label is still found'
	assert l.intern('one-too-many') == none
	assert !l.push(entry('one-too-many', 1, 0)), 'an entry whose bus cannot be named is refused'
	assert l.rows.len == 0
	assert l.push(entry('bus3', 1, 0))
	assert l.rows.len == 1 && l.rows[0].bus == 3
}

fn test_owned_is_the_one_spelling_of_keeping_a_view() {
	mut l := from_entries([entry('a', 1, 0)])
	view := l.at(0)
	kept := view.owned()
	l.rows[0].data[0] = 0xEE
	assert view.frame.data[0] == 0xEE
	assert kept.frame.data[0] == 1
	assert l.copy_at(0).frame.data[0] == 0xEE, 'copy_at is at().owned()'
}

fn test_the_candump_parser_refuses_a_payload_longer_than_a_frame() {
	mut hex := ''
	for _ in 0 .. 65 {
		hex += 'AB'
	}
	assert parse_line('(1.000000) vcan0 123##0${hex}') == none
	mut ok := ''
	for _ in 0 .. 64 {
		ok += 'AB'
	}
	e := parse_line('(1.000000) vcan0 123##0${ok}') or { panic('64 bytes is a frame') }
	assert e.frame.data.len == 64
	// and parse_log is parse into the arena: one row per good line, the bad one skipped
	l :=
		parse_log('(1.000000) vcan0 123#01\n(1.000001) vcan0 123##0${hex}\n(1.000002) vcan1 124#02\n')
	assert l.len() == 2 && l.labels == ['vcan0', 'vcan1']
	assert l.entries().map(it.frame.id) == [u32(0x123), 0x124]
}
