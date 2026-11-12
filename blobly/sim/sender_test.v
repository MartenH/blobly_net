module sim

import blobly.candb
import blobly.project

// a message generator's frame: the DBC's id and DLC, each listed signal encoded, its value
// source evaluated at the send index — the builder the GUI and the headless runner share
fn test_sender_message_frame_encodes_and_evaluates_sources() {
	db := candb.parse_dbc('BO_ 256 M: 2 T
 SG_ A : 0|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ B : 8|8@1+ (1,0) [0|255] "" Vector__XXX
') or { panic(err) }
	s := project.Sender{
		name:    'g'
		message: 'M'
		signals: [
			project.SenderSig{
				name:  'A'
				value: 7
			},
			project.SenderSig{
				name: 'B'
				wave: project.GenCfg{
					typ:    'counter'
					start:  10
					step:   1
					modulo: 256
				}
			},
		]
	}
	f := sender_message_frame(s, [db], 3, 0.0) or { panic('M not built') }
	assert f.id == 256 && !f.extended
	assert f.data == [u8(7), 13] // the counter at send 3: 10 + 3
	if _ := sender_message_frame(project.Sender{ message: 'Nope' }, [db], 0, 0.0) {
		assert false, 'a message no database defines was built'
	}
}

// a generator's frame states its `format:`, else its message's declared one, else none (#607, #608)
fn test_sender_frames_state_their_format() {
	mut db := candb.parse_dbc('BO_ 256 M: 2 T
 SG_ A : 0|8@1+ (1,0) [0|255] "" Vector__XXX
BO_ 257 W: 12 T
 SG_ B : 0|8@1+ (1,0) [0|255] "" Vector__XXX
') or { panic(err) }
	plain := sender_message_frame(project.Sender{ message: 'M' }, [db], 0, 0.0) or { panic(err) }
	assert !plain.format_stated && !plain.fd
	db.messages[0].format = .classic
	cls := sender_message_frame(project.Sender{ message: 'M' }, [db], 0, 0.0) or { panic(err) }
	assert cls.format_stated && !cls.fd
	db.messages[0].format = .fd_brs
	fd := sender_message_frame(project.Sender{ message: 'M' }, [db], 0, 0.0) or { panic(err) }
	assert fd.format_stated && fd.fd && fd.brs
	// the generator's own format wins over the declared one
	own := sender_message_frame(project.Sender{ message: 'M', format: .classic }, [db], 0, 0.0) or {
		panic(err)
	}
	assert own.format_stated && !own.fd
	// a classic frame of 12 bytes is refused where it is stated
	if _ := sender_message_frame(project.Sender{ message: 'W', format: .classic }, [db], 0, 0.0) {
		assert false, 'a 12-byte classic frame was built'
	}
	raw := sender_raw_frame(project.Sender{ format: .fd }, 0x10, false, [u8(1)]) or { panic(err) }
	assert raw.format_stated && raw.fd && !raw.brs
	assert !(sender_raw_frame(project.Sender{}, 0x10, false, [u8(1)]) or { panic(err) }).format_stated
}

// a simulated node's frame states its message's declared format (#607)
fn test_a_simulated_message_states_its_declared_format() {
	mut db := candb.parse_dbc('BO_ 256 M: 2 T
 SG_ A : 0|8@1+ (1,0) [0|255] "" Vector__XXX
') or { panic(err) }
	mut m := SimMessage{
		msg: db.messages[0]
	}
	assert !m.build(0).format_stated
	m.msg.format = .classic
	f := m.build(0)
	assert f.format_stated && !f.fd
	m.msg.format = .fd
	g := m.build(0)
	assert g.format_stated && g.fd && !g.brs
}

// a multiplexed signal is encoded only where the switch selects its branch: a value kept for the
// other branch does not land on the shared bits
fn test_sender_message_frame_encodes_the_selected_branch_only() {
	db := candb.parse_dbc('BO_ 256 M: 2 T
 SG_ Mux M : 0|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ A m1 : 8|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ B m2 : 8|8@1+ (1,0) [0|255] "" Vector__XXX
') or { panic(err) }
	mut s := project.Sender{
		name:    'g'
		message: 'M'
		signals: [project.SenderSig{
			name:  'A'
			value: 10
		}, project.SenderSig{
			name:  'Mux'
			value: 1
		}, project.SenderSig{
			name:  'B'
			value: 20
		}]
	}
	assert (sender_message_frame(s, [db], 0, 0.0) or { panic('M') }).data == [u8(1), 10]
	s.signals[1].value = 2
	assert (sender_message_frame(s, [db], 0, 0.0) or { panic('M') }).data == [u8(2), 20]
}

// a generator's frame fills the bits no signal covers: its own `fill:`, else the row's (the
// database's), else the message's own (#671)
fn test_sender_message_frame_fills_the_uncovered_bits() {
	db := candb.parse_dbc('BO_ 291 Status: 4 Tester
 SG_ Mode : 0|4@1+ (1,0) [0|15] "" Receiver
') or { panic(err) }
	mut s := project.Sender{
		name:    'Status'
		message: 'Status'
		signals: [project.SenderSig{
			name:  'Mode'
			value: 5
		}]
	}
	assert (sender_message_frame(s, [db], 0, 0.0) or { panic('M') }).data == [u8(5), 0, 0, 0]
	row := project.Channel{
		fill: u8(0xFF)
	}
	assert (sender_message_frame(s, [row.row_db(db)], 0, 0.0) or { panic('M') }).data == [u8(0xF5), 0xFF, 0xFF, 0xFF]
	s.fill = u8(0x00)
	assert (sender_message_frame(s, [row.row_db(db)], 0, 0.0) or { panic('M') }).data == [u8(5), 0, 0, 0]
}

// the grid is kept, and a slot a slow write covered is skipped rather than sent late
fn test_next_due_keeps_the_grid_and_skips_what_a_slow_write_covered() {
	assert next_due(0, 10, 1) == 10
	assert next_due(0, 10, 9) == 10
	assert next_due(0, 10, 10) == 20, 'a slot reached as the write returns is not sent back to back'
	assert next_due(0, 10, 35) == 40
	assert next_due(100, 10, 135) == 140
	assert next_due(0, 10, 0) == 10
	assert next_due(5, 0, 7) == 7
	// a 10 ms grid whose second write takes 35 ms: every frame due after the write before it
	mut slot := u64(0)
	mut sent := [u64(0)]
	for write in [u64(1), 35, 1, 1] {
		done := sent.last() + write
		slot = next_due(slot, 10, done)
		assert slot > done, 'a frame due at ${slot}, before the write at ${sent.last()} returned at ${done}'
		sent << slot
	}
	assert sent == [u64(0), 10, 50, 60, 70]
}

// the slots a late write covered are the ones between the slot it was sent in and the next
fn test_slots_skipped_counts_the_slots_a_late_write_covered() {
	assert slots_skipped(0, 10, next_due(0, 10, 1)) == 0
	assert slots_skipped(0, 10, next_due(0, 10, 10)) == 1, 'slot 10 was reached as the write returned'
	assert slots_skipped(10, 10, next_due(10, 10, 45)) == 3, 'slots 20, 30 and 40 were left out'
	assert slots_skipped(5, 0, 7) == 0
	assert slots_skipped(20, 10, 20) == 0
	// over a run, the slots sent and the slots left out are every slot that passed
	mut slot := u64(0)
	mut done := u64(0)
	mut sent := 1
	mut skipped := u64(0)
	for write in [u64(1), 35, 1, 22, 1, 1] {
		done = slot + write
		next := next_due(slot, 10, done)
		skipped += slots_skipped(slot, 10, next)
		slot = next
		sent++
	}
	assert u64(sent) + skipped == slot / 10 + 1
}

// a frame that cannot differ between sends is one with no value source sender_value evaluates
fn test_sender_varies_only_on_a_value_source() {
	mut s := project.Sender{
		message: 'M'
		signals: [project.SenderSig{
			name:  'A'
			value: 1
		}]
	}
	assert !sender_varies(s)
	s.signals << project.SenderSig{
		name: 'B'
		wave: project.GenCfg{
			typ:    'sawtooth'
			min:    0
			max:    10
			period: 0
		}
	}
	assert !sender_varies(s), 'a source that cannot be evaluated sends its static value'
	s.signals[1].wave = project.GenCfg{
		typ:    'counter'
		step:   1
		modulo: 16
	}
	assert sender_varies(s)
}

// a generator listing a signal with no number: said once, and the frame carries none of it
fn test_a_wide_signal_a_generator_lists_is_refused_and_not_sent() {
	db := candb.parse_dbc('BO_ 1280 ConfigData: 24 T
 SG_ Mode : 0|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ Key : 8|128@1+ (1,0) [0|0] "" Vector__XXX
') or { panic(err) }
	s := project.Sender{
		name:    'cfg'
		message: 'ConfigData'
		signals: [
			project.SenderSig{
				name:  'Mode'
				value: 2
			},
			project.SenderSig{
				name:  'Key'
				value: 1
			},
			project.SenderSig{
				name:  'Key'
				value: 3
			},
		]
	}
	assert sender_signal_refusals(s, [db]) == [
		'generator "cfg": Key is 128 bits wide: a value is encoded into 1 .. 64 — not sent',
	]
	f := sender_message_frame(s, [db], 0, 0) or { panic('no frame') }
	assert f.data[0] == 2
	assert f.data[1..].all(it == 0)
}

// the editor's messages over a generator's target rows are what sender_message_frame encodes:
// each name once, at its first definition
fn test_sender_messages_are_the_first_definitions() ! {
	a := candb.parse_dbc('BO_ 256 M: 1 X\n SG_ A : 0|8@1+ (1,0) [0|255] "" X\n')!
	b := candb.parse_dbc('BO_ 256 M: 1 X\n SG_ B : 0|8@1+ (1,0) [0|255] "" X\nBO_ 257 N: 1 X\n SG_ C : 0|8@1+ (1,0) [0|255] "" X\n')!
	ms := sender_messages([a, b])
	assert ms.map(it.name) == ['M', 'N']
	assert ms[0].signals.map(it.name) == ['A']
	s := project.Sender{
		name:    'g'
		message: 'M'
		signals: [project.SenderSig{
			name:  'A'
			value: 7
		}]
	}
	f := sender_message_frame(s, [a, b], 0, 0)!
	assert f.data == [u8(7)]
	assert sender_messages([b]).map(it.name) == ['M', 'N']
}
