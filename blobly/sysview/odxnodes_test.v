module sysview

import os
import blobly.isotp
import blobly.odx
import blobly.project
import blobly.uds

// The nodes a project row names by ODX, against dbc/odx_demo.odx-d.

fn odx_rows(entries []project.DiagNodeCfg) []project.Channel {
	return [project.Channel{
		name:        'CAN1'
		iface:       'inproc:a'
		diagnostics: entries
	}]
}

fn body(variant string) project.DiagNodeCfg {
	return project.DiagNodeCfg{'Body', 'odx_demo.odx-d', variant, 0x7E0, 0x7E8}
}

fn odx_system(entries []project.DiagNodeCfg) (System, []string) {
	return System{}.with_odx_nodes(os.join_path(@VMODROOT, 'dbc'), odx_rows(entries))
}

fn test_an_odx_node_is_named_reached_and_laid_out() {
	sys, notes := odx_system([body('BodyController_Base')])
	n := sys.node_named('Body') or { panic(err) }
	node := sys.nodes[n]
	assert node.odx == 'odx_demo.odx-d#BodyController_Base' && node.ecu_err == ''
	assert sys.sources.len == 1 && sys.current()
	t := sys.reach(n, [RowRef{
		name: 'CAN1'
		wire: 'inproc:a'
	}], -1) or { panic(err) }
	assert t.req == 0x7E0 && t.rsp == 0x7E8 && !t.ext
	d := node.desc
	vin := d.listed_did('VIN') or { panic(err) }
	assert vin.kind == .text && vin.size == 17 && vin.write_gate.declared
	assert vin.write_gate.sessions == ['extended'] && vin.write_gate.level == 1
	assert vin.write == 'extended, level 1'
	assert vin.texts('WVWZZZ1JZXW000001'.bytes())! == ['WVWZZZ1JZXW000001']
	lamp := d.listed_did('LampConfig') or { panic(err) }
	assert lamp.kind == .fields && lamp.by_label()
	assert lamp.parts().map(it.label) == ['Brightness', 'DelayMs']
	assert lamp.encode(['200', '1500'])! == [u8(200), 0x05, 0xDC]
	trim := d.listed_did('TrimOffset') or { panic(err) }
	assert trim.read_texts([u8(0xFF), 0x9C])! == ['-100']
	serial := d.listed_did('EcuSerial') or { panic(err) }
	assert serial.kind == .data && serial.size == 4 && !serial.write_gate.declared
	assert serial.write_refusal() != none
	assert notes.all(!it.contains('LINEAR'))
	assert d.fault(0x912301) or { panic('no fault') }.name == 'LampOpenCircuit'
	// the ISO identification DIDs it does not declare are listed beside its own
	assert d.listed_dids().any(it.id == 0xF187)
}

fn body_did(name string) DidDesc {
	sys, _ := odx_system([body('BodyController_Base')])
	return sys.nodes[0].desc.listed_did(name) or { panic(err) }
}

fn test_a_linear_value_reads_and_writes_as_its_physical_number() {
	temp := body_did('Temperature')
	assert temp.kind == .fields && temp.parts() == [
		Part{'Temperature', .number, 'number -40..6513.5 °C'},
	]
	// -40 + 0.1 * 3000, its binary noise dropped
	assert temp.read_texts([u8(0x0B), 0xB8])! == ['260']
	assert temp.read_texts([u8(0x0B), 0xB9])! == ['260.1']
	assert temp.read_part([u8(0x00), 0x00], 0)! == '-40'
	assert temp.encode(['260.1'])! == [u8(0x0B), 0xB9]
	// a value between two raw values is written as the nearest
	assert temp.encode(['260.04'])! == [u8(0x0B), 0xB8]
	temp.encode(['7000']) or {
		assert err.msg() == 'Temperature: 7000 is outside -40..6513.5 °C'
		temp.encode(['warm']) or {
			assert err.msg().contains('"warm" is not a number')
			return
		}
	}
	assert false
}

fn test_a_scale_linear_value_reads_through_its_segment() {
	volts := body_did('SupplyVoltage')
	assert volts.parts()[0].hint == 'number 0..85 V'
	assert volts.read_texts([u8(100)])! == ['10']
	assert volts.read_texts([u8(101)])! == ['10.5']
	assert volts.encode(['30'])! == [u8(140)]
	// between the segments' values (10 and 10.5): the nearer one
	assert volts.encode(['10.2'])! == [u8(100)]
	assert volts.encode(['10.3'])! == [u8(101)]
	if _ := volts.encode(['86']) {
		assert false
	} else {
		assert err.msg().contains('86 is outside 0..85 V')
	}
	// 251..255 are in no segment: refused, never read as a number
	volts.read_texts([u8(255)]) or {
		assert err.msg().contains('raw 255 is in no scale')
		return
	}
	assert false
}

fn test_a_texttable_value_reads_and_writes_as_its_label() {
	mode := body_did('LampMode')
	assert mode.parts() == [Part{'LampMode', .label, 'one of Off, On, Auto, Service'}]
	assert mode.read_texts([u8(2)])! == ['Auto']
	assert mode.read_texts([u8(20)])! == ['Service']
	// a raw value no entry names reads as the table's default
	assert mode.read_texts([u8(9)])! == ['Invalid']
	assert mode.encode(['On'])! == [u8(1)]
	assert mode.encode(['Service'])! == [u8(31)]
	assert mode.encode(['7'])! == [u8(7)]
	mode.encode(['Invalid']) or {
		assert err.msg().contains('names no value to write')
		mode.encode(['Dim']) or {
			assert err.msg().contains('"Dim" is not one of Off, On, Auto, Service')
			return
		}
	}
	assert false
}

fn test_a_gate_plans_the_write_it_asks_for() {
	trim := body_did('TrimOffset')
	assert trim.write == 'extended'
	plan := trim.plan_write(uds.ConnState{}, true)
	assert plan.session == 0x03 && plan.unlock == 0 && plan.refusal == ''
	serial := body_did('EcuSerial')
	assert serial.read_gate.sessions == ['default', 'extended'] && serial.read == 'default/extended'
	lamp := body_did('LampConfig')
	assert lamp.write == 'open' && lamp.write_gate.declared && lamp.write_gate.sessions.len == 0
}

fn test_a_session_with_no_name_is_planned_by_its_sub_function() {
	x := DidDesc{
		id:         0x0120
		write_gate: Gate{
			declared: true
			sessions: ['extended', '0x40']
		}
	}
	assert x.write_sessions()! == [u8(0x03), 0x40]
	assert x.plan_write(uds.ConnState{ session: 0x03 }, true).refusal == ''
	assert x.plan_write(uds.ConnState{ session: 0x40 }, true).session == 0
}

fn test_an_unresolved_gate_plans_no_write() {
	x := DidDesc{
		id:         0x0120
		write_gate: odx_gate(odx.Gate{
			declared:   true
			unresolved: ['Extended, a state no 0x10 service enters']
		}, true)
	}
	assert x.write_gate.words() == 'unresolved (Extended, a state no 0x10 service enters)'
	assert x.write_refusal() or { '' } == 'not writable: its write gate is not known: Extended, a state no 0x10 service enters'
}

fn test_an_odx_node_on_two_rows_is_one_node_and_a_clash_is_refused() {
	mut rows := odx_rows([body('BodyController_Base')])
	rows << project.Channel{
		name:        'CAN2'
		diagnostics: [body('BodyController_Base')]
	}
	rows << project.Channel{
		name:        'CAN3'
		diagnostics: [body('BodyController_V2')]
	}
	sys, notes := System{}.with_odx_nodes(os.join_path(@VMODROOT, 'dbc'), rows)
	assert sys.nodes.len == 1 && sys.nodes[0].buses == ['CAN1', 'CAN2']
	assert notes.any(it.starts_with('CAN3: diagnostics Body: a node of that name is already described'))
}

fn test_an_odx_source_that_cannot_be_read_still_names_its_node() {
	sys, notes := odx_system([project.DiagNodeCfg{'Body', 'missing.pdx', 'X', 0x7E0, 0x7E8}])
	assert sys.nodes.len == 1 && sys.nodes[0].ecu_err.contains('cannot read')
	assert notes.len == 1 && notes[0].contains('missing.pdx')
	unknown, said := odx_system([body('NoSuchVariant')])
	assert unknown.nodes[0].ecu_err.contains('no variant "NoSuchVariant"')
	assert said.any(it.contains('BodyController_Base, BodyController_V2'))
}

fn test_the_model_it_extends_is_left_as_it_was() {
	sys := load(os.join_path(@VMODROOT, 'projects', 'described-ecu-demo', 'system.toml'))!
	with, _ := sys.with_odx_nodes(os.join_path(@VMODROOT, 'dbc'), odx_rows([body('BodyController_Base')]))
	assert with.nodes.len == sys.nodes.len + 1 && sys.nodes.len == 1
	assert with.node_named('zone_a') or { -1 } == 0
}

fn test_an_enabled_row_describes_a_node_before_a_disabled_one() {
	rows := [
		project.Channel{
			name:        'CAN1'
			enabled:     false
			diagnostics: [body('BodyController_Base')]
		},
		project.Channel{
			name:        'CAN2'
			diagnostics: [body('BodyController_V2')]
		},
	]
	sys, notes := System{}.with_odx_nodes(os.join_path(@VMODROOT, 'dbc'), rows)
	assert sys.nodes.len == 1 && sys.nodes[0].buses == ['CAN2']
	assert sys.nodes[0].odx == 'odx_demo.odx-d#BodyController_V2'
	assert notes.any(it.starts_with('CAN1: diagnostics Body: a node of that name is already described'))
}

fn test_an_odx_node_is_reached_on_every_row_that_names_it() {
	// system.toml declares CAN1 alone; the rows name the node on CAN1 and on CAN2
	base := System{
		buses: [SysBus{
			name: 'CAN1'
		}]
	}
	mut rows := odx_rows([body('BodyController_Base')])
	rows << project.Channel{
		name:        'CAN2'
		iface:       'inproc:b'
		diagnostics: [body('BodyController_Base')]
	}
	sys, _ := base.with_odx_nodes(os.join_path(@VMODROOT, 'dbc'), rows)
	n := sys.node_named('Body') or { panic(err) }
	refs := [RowRef{
		name: 'CAN1'
		wire: 'inproc:a'
	}, RowRef{
		name: 'CAN2'
		wire: 'inproc:b'
	}]
	assert sys.targets(n, refs).map(it.row) == [0, 1]
	t := sys.reach(n, refs, 1) or { panic(err) }
	assert t.row == 1 && t.req == 0x7E0
}

fn test_an_odx_node_is_reached_on_the_wire_of_the_row_naming_it() {
	// two rows of one name on two wires, each naming a node at the same ids
	rows := [
		project.Channel{
			name:        'CAN1'
			iface:       'inproc:a'
			diagnostics: [body('BodyController_Base')]
		},
		project.Channel{
			name:        'CAN1'
			iface:       'inproc:b'
			diagnostics: [project.DiagNodeCfg{'Door', 'odx_demo.odx-d', 'BodyController_V2', 0x7E0, 0x7E8}]
		},
	]
	sys, _ := System{}.with_odx_nodes(os.join_path(@VMODROOT, 'dbc'), rows)
	refs := [RowRef{
		name: 'CAN1'
		wire: 'inproc:a'
	}, RowRef{
		name: 'CAN1'
		wire: 'inproc:b'
	}]
	body_n := sys.node_named('Body') or { panic(err) }
	door_n := sys.node_named('Door') or { panic(err) }
	assert sys.targets(body_n, refs).map(it.row) == [0]
	assert sys.targets(door_n, refs).map(it.row) == [1]
	chans := [ChanRef{'CAN1', 'inproc:a'}, ChanRef{'CAN1', 'inproc:b'}]
	assert sys.can_targets(chans).map('${it.node}:${it.iface}') == ['${body_n}:inproc:a',
		'${door_n}:inproc:b']
}

fn body_routine(name string) RoutineDesc {
	sys, _ := odx_system([body('BodyController_Base')])
	return sys.nodes[0].desc.listed_routine(name) or { panic(err) }
}

fn test_routines_are_listed_with_their_records() {
	sys, notes := odx_system([body('BodyController_Base')])
	d := sys.nodes[0].desc
	assert d.routines.map(it.name) == ['Start_SelfTest', 'Stop_SelfTest', 'RequestResults_SelfTest',
		'Start_CheckDependencies']
	start := body_routine('Start_SelfTest')
	assert start.id == 0x0203 && control_name(start.control) == 'start'
	assert start.gate.sessions == ['extended'] && start.gate.level == 0
	assert start.option_parts().map(it.label) == ['Level']
	assert start.answer_parts().map(it.kind) == [PartKind.label]
	assert start.encode_option(['5'])! == [u8(5)]
	assert start.answer_texts([u8(1)])! == ['Passed']
	stop := body_routine('Stop_SelfTest')
	assert stop.option_parts().len == 0 && stop.answer_parts().len == 0
	assert stop.encode_option([])! == []u8{}
	results := body_routine('RequestResults_SelfTest')
	assert !results.gate.declared && record_by_label(results.answer)
	assert results.answer_texts([u8(1), 0, 42])! == ['Passed', '42']
	// one part alone reads as it does among the rest
	assert results.answer_part([u8(1), 0, 42], 1)! == '42'
	assert body_routine('Start_CheckDependencies').answer_part([u8(0xAB)], 0)! == 'AB'
	if _ := stop.answer_part([]u8{}, 0) {
		assert false, 'a part of an answer of none'
	}
	// an answer not the size the description gives, or one where it gives none, is undecodable
	if _ := results.answer_texts([u8(1)]) {
		assert false, 'an answer of the wrong size decoded'
	} else {
		assert err is uds.UndecodableAnswer
	}
	if _ := stop.answer_texts([u8(1)]) {
		assert false, 'an answer where the description gives none decoded'
	} else {
		assert err is uds.UndecodableAnswer && err.msg().contains('the description says none')
	}
	// an answer the description does not give is bytes of no fixed size
	deps := body_routine('Start_CheckDependencies')
	assert deps.answer_parts().map(it.kind) == [PartKind.bytes] && deps.answer.size == -1
	assert deps.answer_texts([u8(0xAB), 0xCD])! == ['AB CD']
	assert notes.any(it.contains('Start_CheckDependencies') && it.contains('no POS-RESPONSE'))
	if _ := d.listed_routine('Nope') {
		assert false, 'a routine the description does not list was found'
	} else {
		assert err.msg().contains('there are: "Start_SelfTest"')
	}
}

fn serve_body(mut ch isotp.SoftChannel, srv uds.Server, stop chan bool) {
	mut s := srv
	s.serve(mut ch, stop)
	ch.close()
}

fn test_a_routine_is_run_by_name_through_its_gate() {
	iface := 'inproc:sysview-routine'
	mut srv_ch := isotp.open_software(iface, 0x7E8, 0x7E0, false) or { panic(err) }
	mut cli_ch := isotp.open_software(iface, 0x7E0, 0x7E8, false) or { panic(err) }
	mut srv := uds.Server{}
	srv.declare_routine(0x0203, 1, [u8(0)])
	srv.declare_routine(0x0203, 3, [u8(1), 0, 42])
	stop := chan bool{cap: 1}
	th := spawn serve_body(mut srv_ch, srv, stop)
	defer {
		stop <- true
		th.wait()
		cli_ch.close()
	}
	mut cli := uds.new_client(cli_ch)
	start := body_routine('Start_SelfTest')
	// a value the codec refuses, and a gate the connection has not met: nothing sent
	if _ := run_described(mut cli, start, ['300']) {
		assert false, 'a value the codec refuses was sent'
	} else {
		assert err.msg() == '0x31 01 0x0203 Start_SelfTest: not sent — Level: 300 is outside 0..255'
	}
	if _ := run_described(mut cli, start, ['1']) {
		assert false, 'a gated routine ran before its session'
	} else {
		assert err is WriteGated
		g := err as WriteGated
		assert g.session == uds.extended_session && g.level == 0
		assert err.msg() == '0x31 01 0x0203 Start_SelfTest: not sent — this connection has no session known, security unknown, and its gate needs it to switch to the extended session (0x10 03) first'
	}
	assert cli.sent_count == 0
	cli.diagnostic_session(uds.extended_session) or { panic(err) }
	assert start.answer_texts(run_described(mut cli, start, ['1'])!)! == ['Running']
	// no gate: runs in any session
	results := body_routine('RequestResults_SelfTest')
	cli.diagnostic_session(uds.default_session) or { panic(err) }
	assert results.answer_texts(run_described(mut cli, results, [])!)! == ['Passed', '42']
}

// a routine's gate is planned by a write's rule and refused in a run's words
fn test_a_routine_gate_that_cannot_be_met_is_refused_as_a_run() {
	contradicts := RoutineDesc{
		name: 'R'
		gate: Gate{
			declared: true
			sessions: ['default']
			level:    1
		}
	}
	assert contradicts.plan(uds.ConnState{}, true).refusal == 'not run: its gate needs security level 1 but names only the default session, where 0x27 is not served (ISO 14229-1) — the description contradicts itself'
	unknown := RoutineDesc{
		name: 'R'
		gate: Gate{
			declared: true
			sessions: ['vendor']
		}
	}
	assert unknown.plan(uds.ConnState{}, true).refusal == 'not run: served in the "vendor" session, which no tester here knows'
	unresolved := RoutineDesc{
		name: 'R'
		gate: Gate{
			declared:   true
			unresolved: 'two levels'
		}
	}
	assert unresolved.plan(uds.ConnState{}, true).refusal == 'not run: its gate is not known: two levels'
}
