module sysview

import os
import blobly.isotp
import blobly.uds

// The tester-by-node rules against projects/described-ecu-demo: zone_a of system_full, whose
// simulated server tests/diag_described.lua and python/tests/test_nodes.py talk to.

fn demo_system() System {
	return load(os.join_path(@VMODROOT, 'projects', 'described-ecu-demo', 'system.toml')) or {
		panic(err)
	}
}

fn test_a_node_is_found_by_its_name_or_refused_naming_the_others() {
	sys := demo_system()
	assert sys.node_named('zone_a') or { -1 } == 0
	sys.node_named('zone_b') or {
		assert err.msg().contains('no node "zone_b"') && err.msg().ends_with('there are: zone_a'), err.msg()
	}
	mut two := sys
	two.nodes << sys.nodes[0]
	two.node_named('zone_a') or { assert err.msg().contains('two nodes') }
	System{}.node_named('zone_a') or { assert err.msg().starts_with('no system.toml describes') }
}

fn test_a_node_is_reached_on_the_row_named_after_its_bus() {
	sys := demo_system()
	rows := [RowRef{
		name: 'other'
	}, RowRef{
		name: 'edge'
	}, RowRef{
		name: 'eth'
		eth:  true
	}]
	t := sys.reach(0, rows, -1) or { panic(err) }
	assert t == RowTarget{
		row: 1
		req: 0x7C0
		rsp: 0x7C8
	}
	assert sys.reach(0, rows, 1) or { panic(err) } == t
	sys.reach(0, rows, 0) or { assert err.msg() == 'zone_a is not reached on other; it is on: edge' }
	// on no row: refused, saying how it is reached
	sys.reach(0, rows[..1], -1) or {
		assert err.msg() == 'zone_a is reached on no enabled row of the project: it is reached at 0x7C0/0x7C8 on a CAN row named edge'
	}
	// on two rows of the bus's name: the channel must be named
	sys.reach(0, [RowRef{
		name: 'edge'
	}, RowRef{
		name: 'edge'
	}], -1) or { assert err.msg().contains('reached on 2 rows (edge, edge)') }
}

fn test_a_node_is_reached_on_the_doip_row_addressing_its_entity() {
	mut sys := demo_system()
	sys.nodes[0].doip = 0x0710
	rows := [RowRef{
		name:    'DoIP1'
		doip:    true
		host:    '127.0.0.1'
		logical: 0x0710
	}, RowRef{
		name:    'DoIP2'
		doip:    true
		logical: 0x0711
	}]
	assert sys.targets(0, rows) == [RowTarget{
		row:  0
		doip: true
	}]
	// a row dialing another address than the node's is another entity; a loopback one simulates it
	sys.nodes[0].address = '192.0.2.1'
	assert sys.targets(0, [RowRef{
		name:    'D'
		doip:    true
		host:    '192.0.2.2'
		logical: 0x0710
	}]) == []
	assert sys.targets(0, rows).len == 1
	sys.nodes[0].address = '2001:db8::1'
	assert sys.targets(0, [RowRef{
		name:    'D'
		doip:    true
		host:    '[2001:0db8:0:0:0:0:0:1]'
		logical: 0x0710
	}]).len == 1
	assert same_host('::ffff:192.0.2.1', '::ffff:c000:201') && same_host('::ffff:192.0.2.1', '192.0.2.1')
	assert !same_host('192.0.2.1', 'c0000201') && !same_host('010.0.0.1', '10.0.0.1')
	assert loopback('::ffff:127.0.0.1')
	assert !same_host('fe80::1%eth0', 'fe80::1%ETH0')
	assert same_host('Board.local', 'board.local') && !same_host('10.0.0.1', '10.0.0.2')
	assert loopback('[0:0:0:0:0:0:0:1]') && loopback('127.0.0.2') && !loopback('::2')
	sys.nodes[0].doip = 0
	sys.reach(0, rows, -1) or { assert !err.msg().contains('DoIP'), err.msg() }
	// two nodes at one pair of ids on one bus: neither is reached there
	mut two := demo_system()
	two.nodes << SysNode{
		...two.nodes[0]
		name: 'zone_b'
	}
	assert two.targets(0, [RowRef{
		name: 'edge'
	}]) == []
}

fn test_a_node_without_a_server_says_so() {
	mut sys := demo_system()
	sys.nodes[0].desc.server = false
	sys.nodes[0].doip = 0x0710
	rows := [RowRef{
		name: 'edge'
	}, RowRef{
		name:    'DoIP1'
		doip:    true
		logical: 0x0710
	}]
	assert sys.targets(0, rows) == [], 'reached on neither carrier'
	sys.reach(0, rows, -1) or { assert err.msg().contains('declares no diagnostic server') }
}

fn test_dids_are_listed_and_found_by_name_or_identifier() {
	d := demo_system().nodes[0].desc
	listed := d.listed_dids()
	assert listed.len == d.dids.len + d.iso_dids().len
	assert listed[..d.dids.len].map(it.id) == d.dids.map(it.id)
	assert d.listed_did('SteerLimit') or { panic(err) }.id == 0x0110
	assert d.listed_id(0x0110).kind == .param
	// an ISO identification DID the description does not declare, by ISO's name
	assert d.listed_did('ECU serial number') or { panic(err) }.id == 0xF18C
	// an identifier nobody lists: a DID of no layout
	x := d.listed_id(0x1234)
	assert x.kind == .unknown && x.parts().map(it.kind) == [PartKind.bytes]
	d.listed_did('SteerLimt') or { assert err.msg().contains('no DID "SteerLimt"') }
	// a name is a name: an identifier written as text names nothing
	d.listed_did('0x0110') or { assert err.msg().contains('no DID "0x0110"') }
}

fn test_a_part_says_what_its_text_holds() {
	d := demo_system().nodes[0].desc
	assert (d.did(0x0110) or { panic('no DID') }).parts().map(it.kind) == [PartKind.integer]
	assert (d.did(0xF190) or { panic('no DID') }).parts().map(it.kind) == [PartKind.text]
	assert (d.did(0x0102) or { panic('no DID') }).parts().map(it.kind) == [PartKind.bytes]
}

fn test_a_value_that_is_not_the_described_size_is_undecodable() {
	x := demo_system().nodes[0].desc.did(0x0110) or { panic('no DID') }
	assert x.read_texts([u8(0x01), 0x68]) or { panic(err) } == ['360']
	vin := demo_system().nodes[0].desc.listed_id(0xF190)
	assert x.read_part([u8(0x01), 0x68], 0) or { panic(err) } == '360'
	mut padded := 'BLOBLY-ZONE_A-H72'.bytes()
	padded << 0
	assert vin.read_texts(padded) or { panic(err) } == ['BLOBLY-ZONE_A-H72']
	mut bad := 'BLOBLY-ZONE_A-H72'.bytes()
	bad << 0xFF
	vin.read_texts(bad) or {
		assert err is uds.UndecodableAnswer && err.msg().contains('byte 18 (0xFF)')
	}
	x.read_texts([u8(0x01)]) or {
		assert err is uds.UndecodableAnswer
		assert err.msg() == 'DID 0x0110 SteerLimit: 1 byte(s), the description says 2'
	}
}

fn serve_zone_a(mut ch isotp.SoftChannel, srv uds.Server, stop chan bool) {
	mut s := srv
	s.serve(mut ch, stop)
	ch.close()
}

fn test_a_gated_write_says_what_the_connection_lacks_until_it_has_it() {
	d := demo_system().nodes[0].desc
	spec, _ := d.server_spec(false)
	iface := 'inproc:sysview-write'
	mut srv_ch := isotp.open_software(iface, 0x7C8, 0x7C0, false) or { panic(err) }
	mut cli_ch := isotp.open_software(iface, 0x7C0, 0x7C8, false) or { panic(err) }
	stop := chan bool{cap: 1}
	th := spawn serve_zone_a(mut srv_ch, uds.server_from(spec), stop)
	defer {
		stop <- true
		th.wait()
		cli_ch.close()
	}
	mut cli := uds.new_client(cli_ch)
	x := d.listed_did('SteerLimit') or { panic(err) }
	// a value the codec refuses: nothing sent
	write_described(mut cli, x, ['400']) or {
		assert err.msg() == '0x2E 0x0110 SteerLimit: not written — deg: 400 is outside 0..360'
	}
	assert cli.sent_count == 0
	// nothing established yet
	write_described(mut cli, x, ['300']) or {
		assert err is WriteGated
		g := err as WriteGated
		assert g.session == uds.extended_session && g.level == 1
		assert err.msg() == '0x2E 0x0110 SteerLimit: not written — this connection has no session known, security unknown, and its write gate needs it to switch to the extended session (0x10 03), then unlock level 1 (0x27 01/02) first'
	}
	assert cli.sent_count == 0
	cli.diagnostic_session(uds.extended_session) or { panic(err) }
	write_described(mut cli, x, ['300']) or {
		g := err as WriteGated
		assert g.session == 0 && g.level == 1
	}
	seed := cli.security_request_seed(0x01) or { panic(err) }
	cli.security_send_key(0x02, uds.security_key(seed)) or { panic(err) }
	write_described(mut cli, x, ['300']) or { panic(err) }
	assert x.read_texts(cli.read_data_by_identifier(0x0110) or { panic(err) }) or { panic(err) } == [
		'300',
	]
	// a DID with no write gate
	vin := d.listed_id(0xF190)
	write_described(mut cli, vin, ['X']) or { assert err.msg().contains('not writable') }
	// back to the default session: relocked, so the next write is gated again
	cli.diagnostic_session(uds.default_session) or { panic(err) }
	write_described(mut cli, x, ['360']) or { assert err is WriteGated }
}
