module project

import blobly.candb

// a generator's `format:` is read, written back, and declares v13 (#608)
fn test_a_sender_format_round_trips_and_declares_v13() {
	y := 'project:\n  name: f\nchannels:\n  - name: CAN1\n    interface: inproc:CAN1\n    senders:\n' +
		'      - name: Wake\n        id: "0x123"\n        trigger: cyclic\n        cycle_ms: 100\n        format: classic\n' +
		'      - name: Plain\n        id: "0x124"\n'
	p := parse(y)!
	assert p.channels[0].senders.map(it.format) == [.classic, .wire]
	assert version_for(p) == 13
	out := p.to_yaml()
	assert out.contains('        format: classic\n')
	assert out.count('format:') == 1, 'absent stays absent'
	back := parse(out)!
	assert back.channels[0].senders.map(it.format) == [.classic, .wire]
	// absent everywhere: no v13
	mut plain := p
	plain.channels[0].senders[0].format = .wire
	assert version_for(plain) < 13
	// an unknown format is refused, naming the generator
	parse(y.replace('format: classic', 'format: fast')) or {
		assert err.msg().contains('generator Wake: format:'), err.msg()
		return
	}
	assert false, 'an unknown format was read'
}

// the caller's format wins, else the message's declared one, else none; a classic statement a
// payload past 8 bytes cannot take states nothing (#607)
fn test_message_format_is_the_callers_then_the_declared() {
	mut m := candb.Message{
		dlc: 8
	}
	assert message_format(m, .wire) == .wire
	m.format = .fd_brs
	assert message_format(m, .wire) == .fd_brs
	assert message_format(m, .classic) == .classic
	m.format = .classic
	assert declared_format(m) == .classic
	m.dlc = 12
	assert declared_format(m) == .wire
}

// a message declared CAN-FD on a classic row, or classic past 8 bytes, is said once per row (#607)
fn test_frame_format_warnings_name_the_contradicted_messages() {
	db := candb.Database{
		messages: [
			candb.Message{
				name:   'Fd'
				id:     1
				dlc:    8
				format: .fd
			},
			candb.Message{
				name:   'Long'
				id:     2
				dlc:    12
				format: .classic
			},
			candb.Message{
				name: 'Plain'
				id:   3
				dlc:  8
			},
		]
	}
	classic := Channel{
		name:    'CAN1'
		iface:   'inproc:CAN1'
		enabled: true
	}
	w := frame_format_warnings(classic, [db])
	assert w.len == 2, w.str()
	assert w[0].contains('CAN1 is classic CAN') && w[0].contains('(Fd)')
	assert w[1].contains('(Long)')
	fd := Channel{
		...classic
		fd: true
	}
	assert frame_format_warnings(fd, [db]).len == 1 // the long classic one only
	assert frame_format_warnings(Channel{ ...classic, enabled: false }, [db]) == []
}
