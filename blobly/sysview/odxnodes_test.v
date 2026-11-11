module sysview

import os
import blobly.project

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
	// a LINEAR value is its bytes, said, never a number read as if identical
	temp := d.listed_did('Temperature') or { panic(err) }
	assert temp.kind == .data && temp.size == 2 && temp.parts()[0].kind == .bytes
	assert notes.any(it.starts_with('CAN1: diagnostics Body:') && it.contains('LINEAR'))
	assert d.fault(0x912301) or { panic('no fault') }.name == 'LampOpenCircuit'
	// the ISO identification DIDs it does not declare are listed beside its own
	assert d.listed_dids().any(it.id == 0xF187)
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
