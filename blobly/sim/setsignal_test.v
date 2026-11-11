module sim

import blobly.candb
import blobly.project

fn sig8(name string, bit int, length int) candb.Signal {
	return candb.Signal{
		name:       name
		start_bit:  bit
		length:     length
		byte_order: .little_endian
		factor:     1
	}
}

fn set_msg() candb.Message {
	return candb.Message{
		name:    'Protected'
		id:      0x123
		dlc:     8
		sender:  'ECU'
		signals: [sig8('AliveCounter', 0, 4), candb.Signal{
			...sig8('Speed', 8, 16)
			maximum: 250
		}, sig8('CRC', 56, 8)]
	}
}

const set_e2e = E2e{
	counter: 'AliveCounter'
	crc:     'CRC'
	profile: 'crc8_j1850'
}

fn set_engine() Engine {
	return Engine{
		ecus: [SimEcu{
			name:     'ECU'
			messages: [SimMessage{
				msg:       set_msg()
				period_ms: 10
				e2e:       [set_e2e]
			}]
		}]
	}
}

fn set_target() FaultTarget {
	plain := candb.Message{
		name:    'Plain'
		id:      0x124
		dlc:     1
		sender:  'ECU'
		signals: [sig8('Full', 0, 8), sig8('Beyond', 8, 8)]
	}
	return FaultTarget{
		channel: 'CAN1'
		iface:   'inproc:SET'
		db:      candb.Database{
			nodes:    ['ECU']
			messages: [set_msg(), plain]
		}
		nodes:   [
			project.NodeCfg{
				name:    'ECU'
				protect: [project.ProtectCfg{
					message: 'Protected'
					counter: 'AliveCounter'
					crc:     'CRC'
					profile: 'crc8_j1850'
				}]
			},
		]
	}
}

fn set_refusal(t FaultTarget, node string, msg string, signal string, value f64) string {
	t.set_signal(node, msg, signal, value) or { return err.msg() }
	return ''
}

// a value set goes out from the next frame, the rest of the message as it was, and the checksum
// and alive counter stamped over it
fn test_a_set_value_goes_out_under_the_checksum() {
	clear_all()
	t := set_target()
	mut e := set_engine()
	apply_injected('inproc:SET', mut e)
	before := e.due_frames(0)[0]
	t.set_signal('ECU', 'Protected', 'Speed', 1234) or { panic(err) }
	apply_injected('inproc:SET', mut e)
	after := e.due_frames(10)[0]
	m := set_msg()
	assert m.signals[1].physical(after.data) == 1234
	assert m.signals[1].physical(before.data) == 0
	assert m.signals[0].raw_value(after.data) == 1, 'the alive counter goes on'
	mut want := after.data.clone()
	set_e2e.apply(m, mut want, 1)
	assert after.data == want, 'the checksum covers the value set'
	t.clear_signal('ECU', 'Protected', 'Speed') or { panic(err) }
	apply_injected('inproc:SET', mut e)
	assert m.signals[1].physical(e.due_frames(20)[0].data) == 0, 'back to the project source'
	assert signal_values('inproc:SET', 'ECU', 'Protected').len == 0
}

// a second set replaces the first; a clear of the message lets go of all of it; a start
// (clear_all) lets go of every value, and clear_faults of none
fn test_set_values_are_kept_replaced_and_cleared() {
	clear_all()
	t := set_target()
	t.set_signal('ECU', 'Protected', 'Speed', 1) or { panic(err) }
	t.set_signal('ECU', 'Protected', 'Speed', 2) or { panic(err) }
	t.set_signal('ECU', 'Plain', 'Full', 3) or { panic(err) }
	assert signal_values('inproc:SET', 'ECU', 'Protected') == [SetValue{'Speed', 2}]
	t.clear_signal('ECU', 'Protected', '') or { panic(err) }
	assert signal_values('inproc:SET', 'ECU', 'Protected').len == 0
	clear_faults()
	assert signal_values('inproc:SET', 'ECU', 'Plain').len == 1
	other := FaultTarget{
		...t
		iface: 'inproc:OTHER'
	}
	assert signal_values(other.iface, 'ECU', 'Plain').len == 0, 'keyed by channel'
	clear_all()
	assert signal_values('inproc:SET', 'ECU', 'Plain').len == 0
}

// a set replaces the table's array, never the one an engine was stamped with, which the
// simulation reads without the table's lock until its next pass
fn test_a_set_leaves_a_stamped_engine_as_it_was() {
	clear_all()
	t := set_target()
	mut e := set_engine()
	t.set_signal('ECU', 'Protected', 'Speed', 9) or { panic(err) }
	apply_injected('inproc:SET', mut e)
	t.set_signal('ECU', 'Protected', 'Speed', 4) or { panic(err) }
	mut held := []SetValue{}
	for m in e.ecus[0].messages {
		if m.msg.name == 'Protected' {
			held = m.set.clone()
		}
	}
	assert held == [SetValue{'Speed', 9}]
	assert signal_values('inproc:SET', 'ECU', 'Protected') == [SetValue{'Speed', 4}]
	clear_all()
}

// a value that could not reach the wire is refused, and nothing is stored
fn test_a_set_that_cannot_take_effect_is_refused() {
	clear_all()
	t := set_target()
	assert set_refusal(t, 'Other', 'Protected', 'Speed', 1) == '"Other" is not simulated on CAN1'
	assert set_refusal(t, 'ECU', 'Missing', 'Speed', 1) == '"ECU" does not send "Missing" on CAN1'
	assert set_refusal(t, 'ECU', 'Protected', 'Nope', 1) == '"Protected" has no signal "Nope"'
	assert set_refusal(t, 'ECU', 'Protected', 'CRC', 1) == '"CRC" on "Protected" is stamped by its E2E protection, which overwrites a value set on it'
	assert set_refusal(t, 'ECU', 'Protected', 'AliveCounter', 1) == '"AliveCounter" on "Protected" is stamped by its E2E protection, which overwrites a value set on it'
	assert set_refusal(t, 'ECU', 'Plain', 'Beyond', 1) == '"Beyond" lies past the 1-byte payload of Plain, so nothing writes it — a value set on it would change nothing'
	assert set_refusal(t, 'ECU', 'Plain', 'Full', 256) == 'Full on "Plain": 256.0 is past what the 8-bit unsigned "Full" holds (0.0 .. 255.0)'
	assert set_refusal(t, 'ECU', 'Plain', 'Full', -1) != ''
	assert set_refusal(t, 'ECU', 'Plain', 'Full', math_nan()) != ''
	eth := FaultTarget{
		...t
		not_can: 'DoIP'
	}
	assert set_refusal(eth, 'ECU', 'Plain', 'Full', 1) == '"CAN1" is a DoIP channel — nothing simulates on it'
	mut cleared := ''
	t.clear_signal('ECU', 'Plain', 'Nope') or { cleared = err.msg() }
	assert cleared == '"Plain" has no signal "Nope"'
	assert signal_values('inproc:SET', 'ECU', 'Protected').len == 0
	assert signal_values('inproc:SET', 'ECU', 'Plain').len == 0
	// past the declared [min|max] is not refused: a tester sends one on purpose
	assert set_refusal(t, 'ECU', 'Protected', 'Speed', 60000) == ''
	clear_all()
}

fn math_nan() f64 {
	z := 0.0
	return z / z
}

// the width bounds a signed and a scaled signal by their physical ends
fn test_encodable_refusal_reads_the_width() {
	s := candb.Signal{
		name:      'T'
		length:    8
		is_signed: true
		factor:    0.5
		offset:    10
	}
	assert encodable_refusal(s, 10 + 127 * 0.5) == none
	assert encodable_refusal(s, 10 - 128 * 0.5) == none
	assert encodable_refusal(s, 10 + 128 * 0.5) != none
	assert encodable_refusal(s, 10 - 129 * 0.5) != none
}

// a multiplexed signal is written only where the frame carries it, the switch set first
fn test_a_set_multiplexed_signal_follows_its_switch() {
	m := candb.Message{
		name:    'Mux'
		id:      0x200
		dlc:     2
		signals: [
			candb.Signal{
				name:              'Page1'
				start_bit:         8
				length:            8
				byte_order:        .little_endian
				factor:            1
				is_multiplexed:    true
				multiplexor_value: 1
			},
			candb.Signal{
				name:           'Mode'
				start_bit:      0
				length:         8
				byte_order:     .little_endian
				factor:         1
				is_multiplexor: true
			},
		]
	}
	mut data := m.template()
	apply_set(m, [SetValue{'Page1', 7}], mut data)
	assert data == [u8(0), 0], 'page 1 is not selected'
	apply_set(m, [SetValue{'Page1', 7}, SetValue{'Mode', 1}], mut data)
	assert data == [u8(1), 7]
}

// a response rule's message carries the value set as a cyclic one does
fn test_a_response_carries_a_set_value() {
	mut e := Engine{
		ecus: [
			SimEcu{
				name:     'ECU'
				messages: [SimMessage{
					msg: candb.Message{
						name:    'Resp'
						id:      0x301
						dlc:     2
						signals: [
							candb.Signal{
								name:       'B'
								start_bit:  8
								length:     8
								byte_order: .little_endian
								factor:     1
							},
						]
					}
					set: [SetValue{'B', 9}]
				}]
				rules:    [ResponseRule{
					req_id:  0x300
					resp_id: 0x301
				}]
			},
		]
	}
	out := e.on_frame(id: 0x300, data: [u8(5)])
	assert out.len == 1 && out[0].data == [u8(5), 9]
}

// a value set goes into every message of the name, so it must fit every layout of the signal
fn test_a_set_value_must_fit_every_message_of_the_name() {
	clear_all()
	wide := candb.Message{
		name:    'Dup'
		id:      0x200
		dlc:     2
		sender:  'ECU'
		signals: [sig8('Val', 0, 16)]
	}
	narrow := candb.Message{
		...wide
		id:      0x201
		dlc:     1
		signals: [sig8('Val', 0, 8)]
	}
	t := FaultTarget{
		channel: 'CAN1'
		iface:   'inproc:DUP'
		db:      candb.Database{
			nodes:    ['ECU']
			messages: [wide, narrow]
		}
		nodes:   [project.NodeCfg{
			name: 'ECU'
		}]
	}
	assert set_refusal(t, 'ECU', 'Dup', 'Val', 1000).contains('8-bit')
	assert signal_values('inproc:DUP', 'ECU', 'Dup').len == 0
	assert set_refusal(t, 'ECU', 'Dup', 'Val', 200) == ''
	clear_all()
}

// two messages of one name, only the second protected: the engine stamps that protection on
// both, so its fields are refused as on a message protected alone
fn test_a_later_protected_message_of_the_name_protects_the_name() {
	clear_all()
	plain := candb.Message{
		name:    'Status'
		id:      0x200
		dlc:     8
		sender:  'ECU'
		signals: [sig8('Counter', 0, 4), sig8('CRC', 56, 8)]
	}
	protected := candb.Message{
		...plain
		id:  0x201
		e2e: [
			candb.E2eDecl{
				counter: 'Counter'
				crc:     'CRC'
				profile: 'crc8_j1850'
			},
		]
	}
	db := candb.Database{
		nodes:    ['ECU']
		messages: [plain, protected]
	}
	cfg := project.NodeCfg{
		name: 'ECU'
	}
	assert from_project(db, cfg).messages.all(it.e2e.len == 1 && it.e2e[0].crc == 'CRC')
	t := FaultTarget{
		channel: 'CAN1'
		iface:   'inproc:SET'
		db:      db
		nodes:   [cfg]
	}
	assert set_refusal(t, 'ECU', 'Status', 'CRC', 1) == '"CRC" on "Status" is stamped by its E2E protection, which overwrites a value set on it'
	assert signal_values('inproc:SET', 'ECU', 'Status').len == 0
	clear_all()
}
