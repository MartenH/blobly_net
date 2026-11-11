module sim

import blobly.candb
import blobly.project

const send_type_dbc = 'BU_: Body
BO_ 256 Door: 2 Body
 SG_ Door_Status : 0|2@1+ (1,0) [0|3] "" X
 SG_ Level : 8|8@1+ (1,0) [0|255] "" X
BO_ 257 Event: 1 Body
 SG_ Value : 0|8@1+ (1,0) [0|255] "" X
BO_ 258 Quiet: 1 Body
 SG_ Q : 0|8@1+ (1,0) [0|255] "" X
BO_ 259 Late: 1 Body
 SG_ L : 0|8@1+ (1,0) [0|255] "" X
BA_DEF_ BO_ "GenMsgSendType" ENUM "cyclic","spontaneous","cyclicAndSpontaneous","NoMsgSendType";
BA_DEF_DEF_ "GenMsgCycleTime" 100;
BA_DEF_DEF_ "GenMsgSendType" "cyclic";
BA_ "GenMsgSendType" BO_ 257 1;
BA_ "GenMsgSendType" BO_ 258 3;
BA_ "GenMsgNrOfRepetition" BO_ 257 2;
BA_ "GenMsgCycleTimeFast" BO_ 257 10;
BA_ "GenMsgDelayTime" BO_ 257 30;
BA_ "GenMsgStartDelayTime" BO_ 259 250;
BA_ "GenSigStartValue" SG_ 256 Door_Status 3;
'

// frames_by is every frame `e` hands out at each step of `times`, as (ms, id, data).
fn frames_by(mut e Engine, times []f64) [][]string {
	mut out := [][]string{}
	for t in times {
		for f in e.due_frames(t) {
			out << ['${t}', '${f.id}', '${f.data}']
		}
	}
	return out
}

fn grid(to f64, step f64) []f64 {
	mut out := []f64{}
	mut t := 0.0
	for t <= to {
		out << t
		t += step
	}
	return out
}

fn test_a_signal_nobody_sets_goes_out_at_its_start_value() {
	db := candb.parse_dbc(send_type_dbc)!
	mut e := Engine{
		ecus: [ecu_from_dbc(db, 'Body')]
	}
	door := e.due_frames(0).filter(it.id == 256)
	assert door.len == 1
	assert door[0].data == [u8(3), 0]
	// a generator's signal takes the generator's value, the other its start value
	mut g := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Level': gen_const(9)
		}, [])]
	}
	assert g.due_frames(0).filter(it.id == 256)[0].data == [u8(3), 9]
}

fn test_the_default_cycle_and_the_send_type_decide_what_is_cyclic() {
	db := candb.parse_dbc(send_type_dbc)!
	mut e := Engine{
		ecus: [ecu_from_dbc(db, 'Body')]
	}
	fr := frames_by(mut e, grid(300, 10))
	ids := fr.map(it[1])
	// Door on the default cycle; Event (spontaneous, no generator) and Quiet (NoMsgSendType) never
	assert ids.filter(it == '256').len == 4
	assert '257' !in ids
	assert '258' !in ids
	// Late from its start delay of 250 ms on
	assert fr.filter(it[1] == '259').map(it[0]) == ['250.0']
}

fn test_an_event_message_is_sent_on_a_change_with_its_repetitions() {
	db := candb.parse_dbc(send_type_dbc)!
	// a staircase stepping every 0.2 s: a change at 200 ms and at 400 ms
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_stepmod(0.2, 100, 0)
		}, [])]
	}
	sent := frames_by(mut e, grid(500, 5)).filter(it[1] == '257')
	// nothing at the start; 1 + 2 repetitions per change, 30 ms apart (the delay beats the fast cycle)
	assert sent.map(it[0]) == ['200.0', '230.0', '260.0', '400.0', '430.0', '460.0']
	assert sent.map(it[2]) == ['[1]', '[1]', '[1]', '[2]', '[2]', '[2]']
}

fn test_a_counter_on_an_event_message_does_not_trigger_itself() {
	db := candb.parse_dbc(send_type_dbc)!
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_counter(0, 1, 256)
		}, [])]
	}
	assert frames_by(mut e, grid(500, 5)).filter(it[1] == '257').len == 0
}

fn test_unsent_note_names_what_a_node_never_sends() {
	db := candb.parse_dbc(send_type_dbc)!
	note := unsent_note(ecu_from_dbc(db, 'Body'))
	assert note == '2 of its 4 messages are never sent, with no cycle to send them on (Event, Quiet); an event message is sent when a generator or a value set changes one of its signals'
	cfg := project.NodeCfg{
		name:    'Body'
		signals: [project.GenCfg{
			signal: 'Value'
			typ:    'sine'
		}]
	}
	assert validate_cfg(db, cfg).any(it == '1 of its 4 messages are never sent, with no cycle to send them on (Quiet)')
}

fn test_a_generator_payload_starts_from_the_start_values() {
	db := candb.parse_dbc(send_type_dbc)!
	s := project.Sender{
		message: 'Door'
		signals: [project.SenderSig{
			name:  'Level'
			value: 5
		}]
	}
	f := sender_message_frame(s, [db], 0, 0.0) or { panic('Door') }
	assert f.data == [u8(3), 5]
}

fn test_a_mixed_message_keeps_its_cycle_and_adds_change_sends() {
	db := candb.parse_dbc(send_type_dbc.replace('BA_ "GenMsgSendType" BO_ 257 1;', 'BA_ "GenMsgSendType" BO_ 257 2;'))!
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_stepmod(0.25, 100, 0)
		}, [])]
	}
	sent := frames_by(mut e, grid(360, 5)).filter(it[1] == '257').map(it[0])
	// the change at 250 and its repetitions, every send held 30 ms (the delay) after the one
	// before, the cyclic one due at 300 too; the cycle stays on its grid
	assert sent == ['0.0', '100.0', '200.0', '250.0', '280.0', '310.0', '340.0']
}

// gaps is the time between consecutive sends of `id` over `times`.
fn gaps(mut e Engine, times []f64, id string) []f64 {
	at := frames_by(mut e, times).filter(it[1] == id).map(it[0].f64())
	mut out := []f64{}
	for i in 1 .. at.len {
		out << at[i] - at[i - 1]
	}
	return out
}

fn test_no_two_sends_of_a_mixed_message_closer_than_its_delay() {
	// cycle 100, delay 50, a change at 200 and 400 where the cyclic send is due as well
	db := candb.parse_dbc(send_type_dbc.replace('BA_ "GenMsgSendType" BO_ 257 1;', 'BA_ "GenMsgSendType" BO_ 257 2;').replace('BO_ 257 30;',
		'BO_ 257 50;').replace('BA_ "GenMsgNrOfRepetition" BO_ 257 2;', ''))!
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_stepmod(0.2, 100, 0)
		}, [])]
	}
	g := gaps(mut e, grid(600, 1), '257')
	assert g.len > 0
	assert g.all(it >= 50.0 - 1e-6)
}

fn test_a_change_send_with_no_stated_spacing_keeps_the_change_gap() {
	// spontaneous with 2 repetitions, no fast cycle and no delay, a value changing every step
	db := candb.parse_dbc(send_type_dbc.replace('BA_ "GenMsgCycleTimeFast" BO_ 257 10;', '').replace('BA_ "GenMsgDelayTime" BO_ 257 30;',
		''))!
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_sawtooth(0, 255, 0.256)
		}, [])]
	}
	g := gaps(mut e, grid(200, 1), '257')
	assert g.len > 0
	assert g.all(it >= f64(change_gap_ms) - 1e-6)
}

fn test_a_counter_on_a_mixed_message_adds_no_change_sends() {
	// mixed, cycle 100, no delay and no repetitions: a counter moves with each cyclic send
	db := candb.parse_dbc(send_type_dbc.replace('BA_ "GenMsgSendType" BO_ 257 1;', 'BA_ "GenMsgSendType" BO_ 257 2;').replace('BA_ "GenMsgDelayTime" BO_ 257 30;',
		'').replace('BA_ "GenMsgNrOfRepetition" BO_ 257 2;', ''))!
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_counter(0, 1, 256)
		}, [])]
	}
	sent := frames_by(mut e, grid(350, 5)).filter(it[1] == '257').map(it[0])
	assert sent == ['0.0', '100.0', '200.0', '300.0']
}

fn test_an_event_message_of_constants_and_counters_is_never_sent() {
	db := candb.parse_dbc(send_type_dbc)!
	for g in [gen_const(5), gen_counter(0, 1, 256)] {
		ecu := build_configured_ecu(db, 'Body', {
			'Value': g
		}, [])
		assert !ecu.messages.filter(it.msg.name == 'Event')[0].sends()
		assert unsent_note(ecu).contains('(Event, Quiet)')
	}
	ecu := build_configured_ecu(db, 'Body', {
		'Value': gen_sine(100, 50, 1, 0)
	}, [])
	assert ecu.messages.filter(it.msg.name == 'Event')[0].sends()
}

fn test_every_cyclic_message_is_due_by_its_start_delay() {
	db := candb.parse_dbc(send_type_dbc)!
	e := Engine{
		ecus: [ecu_from_dbc(db, 'Body')]
	}
	assert e.all_due_by_ms() == 250.0
}

fn test_a_rebuild_mid_burst_keeps_the_burst() {
	db := candb.parse_dbc(send_type_dbc)!
	mk := fn [db] () Engine {
		return Engine{
			ecus: [build_configured_ecu(db, 'Body', {
				'Value': gen_stepmod(0.2, 100, 0)
			}, [])]
		}
	}
	mut e := mk()
	mut sent := frames_by(mut e, grid(215, 5)).filter(it[1] == '257').map(it[0])
	// rebuilt after the first of 1 + 2 sends, as the GUI rebuilds when another ECU is toggled
	mut carry := Carry{}
	e.save_state(mut carry)
	mut fresh := mk()
	fresh.restore_state(carry)
	mut rest := []f64{}
	for t := 220.0; t <= 300.0; t += 5 {
		rest << t
	}
	sent << frames_by(mut fresh, rest).filter(it[1] == '257').map(it[0])
	assert sent == ['200.0', '230.0', '260.0']
}

fn test_a_change_sends_repetition_bounds_the_loop_wait() {
	db := candb.parse_dbc(send_type_dbc)!
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_stepmod(0.2, 100, 0)
		}, [])]
	}
	for t in grid(200, 5) {
		e.due_frames(t)
	}
	// the change at 200 ms went out; its next repetition is due 30 ms later (the delay)
	assert e.next_due_ms()? == 230
	assert e.recv_wait_ms(228.5) == 2
}

// sends_with_sets is every frame of `id` `e` hands out over `times`, as (ms, data), the values set
// in `sets` (ms -> signal value, -1 a clear) put in the table and stamped before each step.
fn sends_with_sets(mut e Engine, times []f64, id u32, sets map[int]f64) [][]string {
	iface := 'test:set-change'
	mut out := [][]string{}
	for t in times {
		if v := sets[int(t)] {
			if v < 0 {
				clear_value(iface, 'Body', 'Event', 'Value')
			} else {
				set_value(iface, 'Body', 'Event', 'Value', v)
			}
		}
		apply_injected(iface, mut e)
		for f in e.due_frames(t) {
			if f.id == id {
				out << ['${t}', '${f.data}']
			}
		}
	}
	clear_value(iface, 'Body', 'Event', '')
	return out
}

fn test_a_value_set_on_an_event_message_is_a_change() {
	db := candb.parse_dbc(send_type_dbc)!
	mut e := Engine{
		ecus: [ecu_from_dbc(db, 'Body')]
	}
	// the start value set (no change), 7 set (a change), 7 again (none), then cleared back to 0
	sent := sends_with_sets(mut e, grid(500, 5), 257, {
		50:  0.0
		100: 7.0
		300: 7.0
		350: -1.0
	})
	assert sent.map(it[0]) == ['100.0', '130.0', '160.0', '350.0', '380.0', '410.0']
	assert sent.map(it[1]) == ['[7]', '[7]', '[7]', '[0]', '[0]', '[0]']
}

fn test_a_value_set_on_a_mixed_message_is_a_change_held_to_its_delay() {
	db := candb.parse_dbc(send_type_dbc.replace('BA_ "GenMsgSendType" BO_ 257 1;', 'BA_ "GenMsgSendType" BO_ 257 2;'))!
	mut e := Engine{
		ecus: [ecu_from_dbc(db, 'Body')]
	}
	sent := sends_with_sets(mut e, grid(360, 5), 257, {
		150: 7.0
	})
	// the cycle, the set at 150 and its repetitions, the cyclic send due at 200 held to the delay
	assert sent.map(it[0]) == ['0.0', '100.0', '150.0', '180.0', '210.0', '240.0', '300.0']
	assert sent.map(it[1]) == ['[0]', '[0]', '[7]', '[7]', '[7]', '[7]', '[7]']
}

fn test_a_value_set_over_a_moving_generator_stops_its_changes() {
	db := candb.parse_dbc(send_type_dbc)!
	mut e := Engine{
		ecus: [build_configured_ecu(db, 'Body', {
			'Value': gen_stepmod(0.2, 100, 0)
		}, [])]
	}
	// held at 50 from 100 ms on: one change there, none where the staircase steps at 200 and 400
	sent := sends_with_sets(mut e, grid(500, 5), 257, {
		100: 50.0
	})
	assert sent.map(it[0]) == ['100.0', '130.0', '160.0']
}
