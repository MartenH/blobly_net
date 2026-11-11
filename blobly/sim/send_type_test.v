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
	assert note == '2 of its 4 messages are never sent, with no cycle to send them on (Event, Quiet); an event message is sent when a generator changes one of its signals'
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
	sent := frames_by(mut e, grid(320, 5)).filter(it[1] == '257').map(it[0])
	assert sent == ['0.0', '100.0', '200.0', '250.0', '280.0', '300.0', '310.0']
}
