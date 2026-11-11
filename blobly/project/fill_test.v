module project

import blobly.candb

// a row's and a generator's `fill:` are read (hex or decimal, unquoted or quoted), written back,
// and declare v14 (#671)
fn test_fill_round_trips_and_declares_v14() {
	y := 'project:\n  name: f\nchannels:\n  - name: CAN1\n    interface: inproc:CAN1\n    fill: 0xFF\n    senders:\n' +
		'      - name: Status\n        message: Status\n        fill: "0x00"\n' +
		'      - name: Plain\n        message: Status\n' + '  - name: CAN2\n    interface: inproc:CAN2\n    fill: 170\n'
	p := parse(y)!
	assert p.channels[0].fill? == 0xFF
	assert p.channels[0].senders[0].fill? == 0
	assert p.channels[0].senders[1].fill == none
	assert p.channels[1].fill? == 0xAA
	assert version_for(p) == 14
	out := p.to_yaml()
	assert out.contains('    fill: "0xFF"\n')
	assert out.contains('        fill: "0x00"\n')
	assert out.count('fill:') == 3, 'absent stays absent'
	back := parse(out)!
	assert back.channels.map(it.fill) == p.channels.map(it.fill)
	assert back.channels[0].senders.map(it.fill) == p.channels[0].senders.map(it.fill)
	mut plain := parse('project:\n  name: f\nchannels:\n  - name: CAN1\n    interface: inproc:CAN1\n')!
	assert version_for(plain) < 14
	// a value that is not a byte is refused, naming the row or the generator
	for bad in ['0x100', 'full', '-1'] {
		if _ := parse(y.replace('fill: 170', 'fill: ${bad}')) {
			assert false, '${bad} was read as a fill'
		} else {
			assert err.msg().contains('bus CAN2: fill:'), err.msg()
		}
	}
	if _ := parse(y.replace('fill: "0x00"', 'fill: 256')) {
		assert false, '256 was read as a fill'
	} else {
		assert err.msg().contains('generator Status: fill:'), err.msg()
	}
}

// the generator's fill, else the row's, else the message's own
fn test_fill_order_is_the_generator_then_the_row_then_the_message() {
	mut db := candb.Database{
		messages: [candb.Message{
			name: 'M'
			dlc:  1
			fill: 0x0F
		}]
	}
	m := db.messages[0]
	none_row := Channel{}
	row := Channel{
		fill: u8(0xFF)
	}
	plain := Sender{}
	own := Sender{
		fill: u8(0x00)
	}
	assert plain.sent_message(none_row.row_db(db), m).fill == 0x0F
	assert plain.sent_message(row.row_db(db), m).fill == 0xFF
	assert own.sent_message(row.row_db(db), m).fill == 0x00
	assert db.fill == none, 'the database the trace reads is not changed'
}

// a generator with no bus: is built from its own row's databases, never a sibling's on its wire:
// the row the GUI and the headless runner both take its fill from (sender_target_rows)
fn test_a_generator_takes_its_own_rows_fill_not_its_wires() {
	db := candb.Database{
		messages: [candb.Message{
			name: 'M'
			dlc:  1
		}]
	}
	chs := [Channel{
		name:  'A'
		iface: 'inproc:FILLWIRE'
		fill:  u8(0xFF)
	}, Channel{
		name:  'B'
		iface: 'inproc:FILLWIRE'
	}]
	sb := resolve_sender_bus('', chs[1], chs)
	rows := sender_target_rows(sb, 1, chs)
	assert rows == [1]
	assert Sender{}.sent_message(chs[rows[0]].row_db(db), db.messages[0]).fill == 0
	// a generator naming the wire is built from every row on it, the first defining row's fill
	wire := resolve_sender_bus('inproc:FILLWIRE', chs[1], chs)
	assert sender_target_rows(wire, 1, chs) == [0, 1]
}
