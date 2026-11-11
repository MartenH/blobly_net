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
