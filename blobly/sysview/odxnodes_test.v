module sysview

import os
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
