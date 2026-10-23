module sim

import math
import blobly.candb
import blobly.project

fn test_a_generator_is_found_by_name_else_by_channel_and_name() {
	gs := [GenInfo{
		name:    'Ping'
		channel: 'CAN1'
	}, GenInfo{
		name:    'Dup'
		channel: 'CAN1'
	}, GenInfo{
		name:    'Dup'
		channel: 'CAN2'
	}]
	assert gen_find(gs, 'Ping')! == 0
	assert gen_find(gs, 'CAN2/Dup')! == 2
	gen_find(gs, 'Dup') or {
		assert err.msg().contains('"CAN1/Dup" or "CAN2/Dup"'), err.msg()
	}
	gen_find(gs, 'Nope') or { assert err.msg().contains('"Ping", "Dup", "Dup"'), err.msg() }
	// a name spelled like another's qualified form: neither form answers to one alone
	lit := [gs[0], gs[1], gs[2], GenInfo{
		name:    'CAN1/Dup'
		channel: 'CAN3'
	}]
	gen_find(lit, 'Dup') or {
		assert err.msg().contains('"CAN2/Dup"') == false && err.msg().contains('by its position'), err.msg()
	}
	gen_find(lit, 'CAN1/Dup') or { assert err.msg().contains('answers to 2'), err.msg() }
	assert gen_find(lit, 'CAN3/CAN1/Dup')! == 3
	gen_find([]GenInfo{}, 'x') or { assert err.msg().contains('the run has none') }
}

fn test_an_edit_reaches_only_a_signal_the_message_has() {
	db := candb.parse_dbc('BO_ 257 Request: 8 Tester\n SG_ ReqCode : 0|8@1+ (1,0) [0|255] "" SUT\n SG_ Aux : 8|8@1+ (1,0) [0|255] "" SUT\n')!
	mut s := project.Sender{
		name:    'Ping'
		message: 'Request'
		signals: [project.SenderSig{
			name:  'ReqCode'
			value: 1
			wave:  project.GenCfg{
				typ: 'sine'
			}
		}]
	}
	// a value drops the source; a signal not listed yet is added
	gen_set_value(mut s, [db], 'ReqCode', 5)!
	assert s.signals[0].value == 5 && s.signals[0].wave.typ == ''
	gen_set_source(mut s, [db], 'Aux', project.GenCfg{ typ: 'counter', step: 2 })!
	assert s.signals.len == 2 && s.signals[1].wave.typ == 'counter' && s.signals[1].wave.signal == 'Aux'
	frame := sender_message_frame(s, [db], 3, 0) or { panic('no frame') }
	assert frame.data[0] == 5 && frame.data[1] == 6
	mut refusals := 0
	gen_set_value(mut s, [db], 'Nope', 1) or { refusals++ }
	gen_set_value(mut s, [db], 'ReqCode', math.inf(1)) or { refusals++ }
	gen_set_source(mut s, [db], 'ReqCode', project.GenCfg{ typ: '' }) or { refusals++ }
	gen_set_source(mut s, [db], 'ReqCode', project.GenCfg{ typ: 'stepmod', period: 1 }) or {
		refusals++
	}
	gen_set_source(mut s, [db], 'ReqCode', project.GenCfg{ typ: 'wobble' }) or { refusals++ }
	mut raw := project.Sender{
		name: 'Raw'
		id:   0x321
	}
	gen_set_value(mut raw, [db], 'ReqCode', 1) or {
		assert err.msg().contains('raw frame')
		refusals++
	}
	// a signal past the payload is never sent; one listed twice is edited where the frame reads it
	short := candb.parse_dbc('BO_ 257 Request: 1 Tester\n SG_ ReqCode : 0|8@1+ (1,0) [0|255] "" SUT\n SG_ Aux : 8|8@1+ (1,0) [0|255] "" SUT\n')!
	gen_set_value(mut s, [short], 'Aux', 1) or {
		assert err.msg().contains('do not hold Aux'), err.msg()
		refusals++
	}
	assert refusals == 7
	assert s.signals.len == 2, 'a refused edit added nothing'
	mut twice := project.Sender{
		message: 'Request'
		signals: [project.SenderSig{
			name:  'ReqCode'
			value: 1
		}, project.SenderSig{
			name:  'ReqCode'
			value: 2
		}]
	}
	gen_set_value(mut twice, [db], 'ReqCode', 42)!
	assert (sender_message_frame(twice, [db], 0, 0) or { panic('no frame') }).data[0] == 42
	gen_cycle_check(1)!
	gen_cycle_check(gen_cycle_max_ms)!
	gen_cycle_check(0) or { refusals++ }
	gen_cycle_check(gen_cycle_max_ms + 1) or { refusals++ }
	assert refusals == 9
}

fn test_a_host_with_no_run_refuses_every_call() {
	mut c := GenControl(NoGens{})
	assert c.generators().len == 0
	c.gen_fire(0, 0) or {
		assert err.msg().contains('no generators to control here')
		return
	}
	assert false, 'NoGens fired'
}

// a branch the switch cannot select is never sent: refused; a negative DLC builds an empty frame
fn test_an_unreachable_branch_and_a_bad_dlc() {
	db := candb.parse_dbc('BO_ 256 M: 2 T
 SG_ Mux M : 0|2@1+ (1,0) [0|3] "" Vector__XXX
 SG_ Hidden m4 : 8|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ Shown m3 : 8|8@1+ (1,0) [0|255] "" Vector__XXX
') or { panic(err) }
	mut s := project.Sender{
		message: 'M'
	}
	gen_set_value(mut s, [db], 'Shown', 1)!
	gen_set_value(mut s, [db], 'Hidden', 1) or {
		assert err.msg().contains('cannot hold'), err.msg()
		return
	}
	assert false, 'an unreachable branch was accepted'
}

fn test_a_negative_dlc_builds_an_empty_frame() {
	db := candb.parse_dbc('BO_ 257 Bad: -1 Tester\n SG_ A : 0|8@1+ (1,0) [0|255] "" SUT\n')!
	f := sender_message_frame(project.Sender{ message: 'Bad' }, [db], 0, 0) or { panic('none') }
	assert f.data.len == 0
}
