module canlog

import transport

fn sample() []LogEntry {
	return [
		LogEntry{
			t_s:   1.5
			iface: 'vcan0'
			dir:   .tx
			frame: transport.CanFrame{
				id:   0x123
				data: [u8(1), 2, 3]
			}
		},
		LogEntry{
			t_s:   1.6
			iface: 'vcan1'
			dir:   .rx
			frame: transport.CanFrame{
				id:       0x1ABCDEF
				extended: true
				fd:       true
				brs:      true
				esi:      true
				data:     []u8{len: 64, init: u8(index)}
			}
		},
		LogEntry{
			t_s:   1.7
			iface: 'vcan0'
			frame: transport.CanFrame{
				id:  0x7FF
				rtr: true
			}
		},
	]
}

fn test_a_row_is_eighty_pointer_free_bytes() {
	assert sizeof(Row) == 80
}

fn test_entries_round_trip_through_the_arena() {
	es := sample()
	l := from_entries(es)
	assert l.len() == 3
	assert l.labels == ['vcan0', 'vcan1'], 'one label per bus, in order of first sight'
	assert l.rows[0].bus == 0 && l.rows[1].bus == 1 && l.rows[2].bus == 0
	back := l.entries()
	for i, e in es {
		b := back[i]
		assert b.t_s == e.t_s && b.iface == e.iface && b.dir == e.dir, 'entry ${i}'
		assert b.frame.id == e.frame.id && b.frame.extended == e.frame.extended, 'entry ${i}'
		assert b.frame.rtr == e.frame.rtr && b.frame.fd == e.frame.fd, 'entry ${i}'
		assert b.frame.brs == e.frame.brs && b.frame.esi == e.frame.esi, 'entry ${i}'
		assert b.frame.data == e.frame.data, 'entry ${i}'
	}
	assert l.at(1).frame.data.len == 64 && l.at(1).frame.data[63] == 63
	assert l.at(2).frame.data.len == 0
	assert l.t_s(2) == 1.7 && l.iface(2) == 'vcan0'
}

fn test_a_view_aliases_the_row_and_a_copy_does_not() {
	mut l := from_entries(sample())
	view := l.at(0)
	copy := l.copy_at(0)
	l.rows[0].data[0] = 0xAB
	assert view.frame.data[0] == 0xAB, 'a view reads the row it was taken from'
	assert copy.frame.data[0] == 1, 'a copy owns its payload'
	assert view.frame.data.len == 3 && view.frame.data.cap == 3
}

fn test_relabelled_shares_the_rows_and_replaces_the_labels() {
	l := from_entries(sample())
	m := l.relabelled(['can0', 'can1'])
	assert m.rows.data == l.rows.data, 'the rows are the same block'
	assert m.iface(0) == 'can0' && m.iface(1) == 'can1' && m.iface(2) == 'can0'
	assert l.iface(0) == 'vcan0', 'the source keeps its own labels'
}

fn test_a_payload_past_the_fd_maximum_is_cut_there() {
	r := row_of(LogEntry{
		frame: transport.CanFrame{
			data: []u8{len: 70, init: 1}
		}
	}, 0)
	assert r.len == 64
}

fn test_the_flag_byte_carries_every_kind_bit_and_the_direction() {
	assert pack_flags(false, false, false, false, false, .unknown) == 0
	assert pack_flags(true, true, true, true, true, .tx) == 0x1F | (2 << 5)
	l := from_entries(sample())
	assert l.at(0).dir == .tx && l.at(1).dir == .rx && l.at(2).dir == .unknown
}
