module sysview

import os
import toml
import blobly.uds

// A trimmed copy of blobly_emb's examples/system_full (origin/main, 2026-10-06): the system.toml
// node and signal declarations the diagnostic link reads, and zone_a's ecu.toml with its faults,
// parameter and DIDs as written there (inline comments included — the reader must take them).

const fx_system = '
[bus.compute]
interface = "can0"
fd        = false
bitrate   = 500000

[bus.edge]
interface = "can1"
fd        = true
bitrate   = 500000

[[signal]]
name     = "VehicleSpeed"
fields   = { kph = "u32" }
producer = "domain"
bus      = "compute"
frame    = "VehSpeedFrame"
cycle_ms = 100

[[signal]]
name     = "SteeringAngle"
fields   = { deg = "u32" }
producer = "zone_a"
bus      = "edge"
frame    = "SteeringFrame"
cycle_ms = 50

[[node]]
name     = "sysnode"
ecu      = "nodes/sysnode/ecu.toml"
buses    = ["compute", "edge", "tel"]
nm       = 0x11
diag     = { req = 0x7A0, rsp = 0x7A8 }
trace    = 1
endpoint = { address = "192.168.0.50", port = 30490 }
doip     = { logical = 0x07A0, testers = [0x0E00], allow_bench_key = true }

[[node]]
name  = "domain"
ecu   = "nodes/domain/ecu.toml"
buses = ["compute"]
nm    = 0x12
diag  = { req = 0x7B0, rsp = 0x7B8 }
trace = 2

[[node]]
name  = "zone_a"
ecu   = "nodes/zone_a/ecu.toml"
buses = ["edge"]
nm    = 0x13
diag  = { req = 0x7C0, rsp = 0x7C8 }
trace = 3

[[node]]
name  = "chassis"
ecu   = "nodes/chassis/ecu.toml"
buses = ["edge"]
'

const fx_zone_a = '
[[signal]]
name   = "RawSteer"
fields = { deg = "u32" }
from   = "front"
to     = "front"

[[param]]
name    = "SteerLimit"
fields  = { deg = "u16" }
default = { deg = 360 }
range   = { deg = { min = 0, max = 360 } }   # refused at 0x2E (0x31) and at restore
apply   = "reset"

[[fault]]
name     = "SpeedImplausible"
dtc      = 0xC40100                    # U0401-00: invalid data received from the powertrain
from     = "SteerLimiter.on_50ms"
debounce = { kind = "counter", fail = 3, pass = 3 }   # accumulating: 150 ms to fail from 0, 300 ms back
confirm  = 1
aging    = 3                           # three passing power cycles after the last failure age it out
freeze   = [0xF1A0]

[[fault]]
name   = "SafetyCmdTimeout"
dtc    = 0xC16400                      # U0164-00: lost communication with the safety command source
signal = "SafetyCmd"
on     = "timeout"

[[fault]]
name   = "SafetyCmdIntegrity"
dtc    = 0xC46400                      # U0464-00: invalid data received (an E2E CRC failure)
signal = "SafetyCmd"
on     = "integrity"

[[fault]]
name   = "SafetyCmdLost"
dtc    = 0xC46401                      # frames missing from the command E2E sequence
signal = "SafetyCmd"
on     = "lost"

[fault_memory]
cycle = "power"

[uds]
s3_ms        = 5000
security_key = "reference"

[isotp]
bus           = "can0"
rx_id         = 0x7C0
tx_id         = 0x7C8
functional_id = 0x7DF
bs            = 8
stmin_ms      = 0

[[did]]
id    = 0xF190
ascii = "BLOBLY-ZONE_A-H723"

[[did]]
id    = 0xF189
ascii = "system_full"

[[did]]
id     = 0xF1A0
signal = "SteeringAngle"

[[did]]
id    = 0x0110
param = "SteerLimit"
write = { session = ["extended"], security = 1 }

[[did]]
id           = 0x0111
param_status = true

[[did]]
id    = 0x0102
bytes = "00"
write = { session = ["extended"], security = 1 }
'

// sysnode as a gateway on two buses, and a planted twin of zone_a's addressing on the compute bus
const fx_sysnode = '
[isotp]
bus   = "can0"
rx_id = 0x7A0
tx_id = 0x7A8

[[did]]
id    = 0xF190
ascii = "BLOBLYSYSNODEH735"
'

const fx_domain = '
[isotp]
rx_id = 0x7B0
tx_id = 0x7B8
'

fn desc_fixture(name string) string {
	dir := os.join_path(os.temp_dir(), 'sysview_desc_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	for n in ['sysnode', 'domain', 'zone_a', 'chassis'] {
		os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
	}
	os.mkdir_all(os.join_path(dir, 'test')) or { panic(err) }
	os.write_file(os.join_path(dir, 'system.toml'), fx_system) or { panic(err) }
	os.write_file(os.join_path(dir, 'nodes', 'zone_a', 'ecu.toml'), fx_zone_a) or { panic(err) }
	os.write_file(os.join_path(dir, 'nodes', 'sysnode', 'ecu.toml'), fx_sysnode) or { panic(err) }
	os.write_file(os.join_path(dir, 'nodes', 'domain', 'ecu.toml'), fx_domain) or { panic(err) }
	return dir
}

fn test_zone_a_description() {
	dir := desc_fixture('zone')
	defer {
		os.rmdir_all(dir) or {}
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	z := sys.nodes.filter(it.name == 'zone_a')[0] or { panic('no zone_a') }
	d := z.desc
	assert d.errs == []
	assert d.faults.len == 4
	f := d.fault(0xC40100) or { panic('no U0401-00') }
	assert f.name == 'SpeedImplausible'
	assert f.source == 'SteerLimiter.on_50ms'
	assert f.freeze == [u16(0xF1A0)]
	assert f.aging == 3 && f.confirm == 1
	assert (d.fault(0xC16400) or { panic('') }).source == 'SafetyCmd (timeout)'
	assert d.fault(0xC40200) == none

	assert d.isotp_req == 0x7C0 && d.isotp_rsp == 0x7C8
	assert d.params.len == 1 && d.params[0].fields == [Field{'deg', 'u16'}]
	assert d.params[0].apply == 'reset'

	// sizes: text, a live signal (system.toml's u32), a parameter, its status, fixed bytes
	assert d.did_sizes() == {
		u16(0xF190): 18
		0xF189:      11
		0xF1A0:      4
		0x0110:      2
		0x0111:      1
		0x0102:      1
	}
	assert d.did_name(0xF1A0) == 'SteeringAngle'
	assert d.did_name(0x0110) == 'SteerLimit'
	assert d.did_name(0xF190) == 'VIN' // ISO's name for an ascii DID
	assert d.did_name(0xF18C) == 'ECU serial number' // not declared: ISO's name still
	assert d.did_name(0x4242) == ''
	assert (d.did(0x0110) or { panic('') }).write == 'extended, level 1'
	assert (d.did(0x0110) or { panic('') }).read == ''
	// the gates as data, for a tester to establish them
	lim := d.did(0x0110) or { panic('') }
	assert lim.write_gate == Gate{
		declared: true
		sessions: ['extended']
		level:    1
	}
	assert !lim.read_gate.declared
	assert lim.ranges['deg'] or { panic('') } == Range{0, 360}
	assert !(d.did(0x0111) or { panic('') }).write_gate.declared // the status is read-only
	assert d.security_key == 'reference'
	assert d.params[0].defaults == {
		'deg': i64(360)
	}
	assert session_id('extended') or { 0 } == 0x03
	assert session_id('nonsense') == none
	// the coding DID and the status DID of a parameter
	assert (d.param_did('SteerLimit') or { panic('') }).id == 0x0110
	assert d.param_did('Nope') == none
	assert (d.param_status_did() or { panic('') }).id == 0x0111
	// the ISO identification DIDs beside the node's own: not the ones it declares
	iso := d.iso_dids()
	assert iso.len > 20
	assert !iso.any(it.id in [u16(0xF190), 0xF189])
	assert iso.any(it.id == 0xF18C && it.name == 'ECU serial number' && it.size == -1)
	assert EcuDesc{}.iso_dids().len == iso.len + 2 // no description: every one

	// values through the description
	assert d.decode_did(0xF1A0, [u8(0), 0, 0, 100]) == '100'
	assert d.decode_did(0x0110, [u8(0x01), 0x68]) == '360'
	assert d.decode_did(0x0111, [u8(1)]) == 'SteerLimit coded'
	assert d.decode_did(0xF190, 'BLOBLY-ZONE_A-H723'.bytes()) == '"BLOBLY-ZONE_A-H723"'
	assert d.decode_did(0xF1A0, [u8(0), 100]) == '' // not the declared length: the caller shows bytes
	assert d.decode_did(0x0102, [u8(0)]) == '' // fixed bytes have no layout
	assert d.decode_did(0x4242, [u8(0)]) == ''
}

fn test_signed_and_multi_field_values() {
	assert field_value(Field{'x', 'i16'}, [u8(0xFF), 0xFE]) == '-2'
	assert field_value(Field{'x', 'i8'}, [u8(0x7F)]) == '127'
	assert field_value(Field{'x', 'bool'}, [u8(1)]) == 'true'
	assert field_value(Field{'x', 'u32'}, [u8(0xFF), 0xFF, 0xFF, 0xFF]) == '4294967295'
}

fn test_a_target_finds_its_node_by_addressing() {
	dir := desc_fixture('link')
	defer {
		os.rmdir_all(dir) or {}
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	name := fn [sys] (l NodeLink) string {
		return if l.node >= 0 { sys.nodes[l.node].name } else { '' }
	}
	// CAN: the request AND response ids
	assert name(sys.node_for(TargetAddr{ req: 0x7C0, rsp: 0x7C8, bus: 'edge' })) == 'zone_a'
	assert name(sys.node_for(TargetAddr{ req: 0x7B0, rsp: 0x7B8 })) == 'domain'
	// a request id alone is not an address
	miss := sys.node_for(TargetAddr{ req: 0x7C0, rsp: 0x7E8 })
	assert miss.node == -1 && miss.why.contains('0x7C0/0x7E8')
	// DoIP: the entity's logical address, never a CAN id that happens to share the number
	assert name(sys.node_for(TargetAddr{ doip: true, logical: 0x07A0 })) == 'sysnode'
	assert sys.node_for(TargetAddr{ doip: true, logical: 0x07C0 }).node == -1
	// the plain default 0x7E0/0x7E8 is nobody in this system
	assert sys.node_for(TargetAddr{ req: 0x7E0, rsp: 0x7E8 }).node == -1
}

fn test_one_address_on_two_nodes_is_settled_by_bus_or_not_at_all() {
	dir := desc_fixture('twin')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	// plant a twin: domain (compute) answers zone_a's ids too
	for i, n in sys.nodes {
		if n.name == 'domain' {
			sys.nodes[i].diag_req = 0x7C0
			sys.nodes[i].diag_rsp = 0x7C8
		}
	}
	on_edge := sys.node_for(TargetAddr{ req: 0x7C0, rsp: 0x7C8, bus: 'edge' })
	assert on_edge.node >= 0 && sys.nodes[on_edge.node].name == 'zone_a'
	on_compute := sys.node_for(TargetAddr{ req: 0x7C0, rsp: 0x7C8, bus: 'compute' })
	assert on_compute.node >= 0 && sys.nodes[on_compute.node].name == 'domain'
	unsettled := sys.node_for(TargetAddr{ req: 0x7C0, rsp: 0x7C8, bus: 'CAN1' })
	assert unsettled.node == -1 && unsettled.why.contains('domain, zone_a')
}

// A DoIP target is settled by its channel's bus the same way: the Diagnostics panel passes the
// DoIP channel's name, as it does a CAN one's.
fn test_one_logical_address_on_two_nodes_is_settled_by_bus_too() {
	dir := desc_fixture('twin_doip')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	for i, n in sys.nodes {
		if n.name == 'zone_a' {
			sys.nodes[i].doip = 0x07A0 // sysnode's entity address
		}
	}
	on_edge := sys.node_for(TargetAddr{ doip: true, logical: 0x07A0, bus: 'compute' })
	assert on_edge.node >= 0 && sys.nodes[on_edge.node].name == 'sysnode'
	unsettled := sys.node_for(TargetAddr{ doip: true, logical: 0x07A0, bus: 'edge' })
	assert unsettled.node == -1 // both sit on edge
	assert sys.node_for(TargetAddr{ doip: true, logical: 0x07A0 }).node == -1
}

// Discover's "+ Add ticked" asks which tester an entity it found lets in: the description's
// `testers`, matched by logical address, and by endpoint address where two nodes share one.
fn test_the_tester_a_described_entity_accepts() {
	dir := desc_fixture('testers')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	n := sys.nodes.filter(it.name == 'sysnode')[0] or { panic('no sysnode') }
	assert n.testers == [u16(0x0E00)]
	assert n.address == '192.168.0.50'
	assert sys.doip_tester_for(0x07A0, '192.168.0.50')? == 0x0E00
	assert sys.doip_tester_for(0x07A0, '')? == 0x0E00
	// not described: the caller keeps its default
	assert sys.doip_tester_for(0x1000, '192.168.0.50') == none
	// the described entity lives elsewhere: this one is not it
	assert sys.doip_tester_for(0x07A0, '10.0.0.9') == none
	// two nodes on one logical address: the endpoint address settles it, or nothing does
	for i, x in sys.nodes {
		if x.name == 'zone_a' {
			sys.nodes[i].doip = 0x07A0
			sys.nodes[i].testers = [u16(0x0E01)]
			sys.nodes[i].address = '192.168.0.51'
		}
	}
	assert sys.doip_tester_for(0x07A0, '192.168.0.51')? == 0x0E01
	assert sys.doip_tester_for(0x07A0, '192.168.0.50')? == 0x0E00
	assert sys.doip_tester_for(0x07A0, '') == none
	// a node that names no testers leaves the default
	for i, x in sys.nodes {
		if x.name == 'zone_a' {
			sys.nodes[i].testers = []
		}
	}
	assert sys.doip_tester_for(0x07A0, '192.168.0.51') == none
	// describes: the default CAN pair is nobody here
	assert !sys.describes(TargetAddr{ req: 0x7E0, rsp: 0x7E8 })
	assert sys.describes(TargetAddr{ req: 0x7C0, rsp: 0x7C8 })
}

fn test_targets_on_the_buses_a_project_names() {
	dir := desc_fixture('targets')
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'nodes', 'chassis', 'ecu.toml'), '[[fb]]\nname = "X"\n') or {
		panic(err)
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	chans := [ChanRef{'compute', 'can0'}, ChanRef{'edge', 'can1'}]
	got := sys.can_targets(chans).map('${sys.nodes[it.node].name}@${it.bus}/${it.iface} 0x${it.req:X}/0x${it.rsp:X}')
	// sysnode sits on both buses but serves on the one its [isotp] names (can0 = compute); chassis
	// (no server) is not a target
	assert got == ['sysnode@compute/can0 0x7A0/0x7A8', 'domain@compute/can0 0x7B0/0x7B8',
		'zone_a@edge/can1 0x7C0/0x7C8']
	assert sys.can_targets([ChanRef{'CAN1', 'inproc:CAN1'}]) == []
	assert sys.can_targets(chans).all(!it.shared_name)
	// two channels named edge are two wires: a target on each, each saying its name is shared
	twins := sys.can_targets([ChanRef{'edge', 'can1'}, ChanRef{'edge', 'vcan1'}]).filter(sys.nodes[it.node].name == 'zone_a')
	assert twins.map(it.iface) == ['can1', 'vcan1']
	assert twins.all(it.shared_name)
}

// A node's server is on the CAN bus its [isotp] names in the node's own terms — `can0` on a node
// with one bus, the system bus's interface on a node with several — and on every CAN bus it sits
// on where that cannot be told.
fn test_the_diag_bus_is_the_one_the_isotp_names() {
	dir := desc_fixture('diagbus')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	idx := sys.nodes.map(it.name).index('sysnode')
	zi := sys.nodes.map(it.name).index('zone_a')
	assert sys.diag_bus(&sys.nodes[idx])? == 'compute'
	// one bus: can0 is its only controller, whatever the system bus's interface
	assert sys.diag_bus(&sys.nodes[zi])? == 'edge'
	sys.nodes[idx].desc.isotp_bus = 'can1'
	assert sys.diag_bus(&sys.nodes[idx])? == 'edge'
	chans := [ChanRef{'compute', 'can0'}, ChanRef{'edge', 'can1'}]
	assert sysnode_buses(sys, chans) == ['edge']
	// a controller the node does not have: nothing tells, so every CAN bus it is on
	sys.nodes[idx].desc.isotp_bus = 'can7'
	assert sys.diag_bus(&sys.nodes[idx]) == none
	assert sysnode_buses(sys, chans) == ['compute', 'edge']
	// a someip segment is not a CAN bus, even when a channel bears its name
	sys.buses << SysBus{
		name: 'tel'
		kind: 'someip'
	}
	assert sysnode_buses(sys, [ChanRef{'tel', 'udp:tel'}]) == []
	// a bus the node names but the system does not declare tells nothing about where it serves
	sys.nodes[zi].buses = ['edge', 'undeclared']
	sys.nodes[zi].desc.isotp_bus = ''
	assert sys.diag_bus(&sys.nodes[zi])? == 'edge'
}

// Two nodes on one CAN address are told apart by the bus each SERVES on, the bus can_targets
// offers it on — not by every bus it sits on; two on one DoIP address by the endpoint.
fn test_a_shared_address_is_settled_where_the_node_serves() {
	dir := desc_fixture('shared')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	zi := sys.nodes.map(it.name).index('zone_a')
	sys.nodes[zi].diag_req = 0x7A0 // sysnode's pair; sysnode sits on edge too but serves on compute
	sys.nodes[zi].diag_rsp = 0x7A8
	name := fn [sys] (l NodeLink) string {
		return if l.node >= 0 { sys.nodes[l.node].name } else { '' }
	}
	assert name(sys.node_for(TargetAddr{ req: 0x7A0, rsp: 0x7A8, bus: 'edge' })) == 'zone_a'
	assert name(sys.node_for(TargetAddr{ req: 0x7A0, rsp: 0x7A8, bus: 'compute' })) == 'sysnode'
	sys.nodes[zi].doip = 0x07A0
	sys.nodes[zi].address = '192.168.0.51'
	assert sys.node_for(TargetAddr{ doip: true, logical: 0x07A0 }).node == -1
	assert name(sys.node_for(TargetAddr{ doip: true, logical: 0x07A0, host: '192.168.0.51' })) == 'zone_a'
	assert name(sys.node_for(TargetAddr{ doip: true, logical: 0x07A0, host: '192.168.0.50' })) == 'sysnode'
	// one at that endpoint beats one whose endpoint is unknown
	si := sys.nodes.map(it.name).index('sysnode')
	sys.nodes[zi].address = ''
	assert name(sys.node_for(TargetAddr{ doip: true, logical: 0x07A0, host: '192.168.0.50' })) == 'sysnode'
	// endpoints unknown: the bus still settles it
	sys.nodes[si].address = ''
	sys.nodes[zi].address = ''
	sys.nodes[si].buses = ['compute']
	assert name(sys.node_for(TargetAddr{ doip: true, logical: 0x07A0, host: '10.0.0.1', bus: 'edge' })) == 'zone_a'
}

fn sysnode_buses(sys System, chans []ChanRef) []string {
	return sys.can_targets(chans).filter(sys.nodes[it.node].name == 'sysnode').map(it.bus)
}

// A node is a DoIP target where the system gives it an entity and an address; the tester is the
// first it lets in.
fn test_doip_targets_from_the_system() {
	dir := desc_fixture('doiptargets')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	got := sys.doip_targets()
	assert got.len == 1
	assert sys.nodes[got[0].node].name == 'sysnode'
	assert got[0].host == '192.168.0.50' && got[0].logical == 0x07A0 && got[0].tester == 0x0E00
	idx := sys.nodes.map(it.name).index('sysnode')
	sys.nodes[idx].testers = []
	assert sys.doip_targets()[0].tester == 0
	sys.nodes[idx].doip = 0x10001 // not a 16-bit address
	assert sys.doip_targets() == []
	sys.nodes[idx].doip = 0x07A0
	// no address the model can state: nothing says where it is
	sys.nodes[idx].address = ''
	assert sys.doip_targets() == []
}

fn test_system_diag_ids_supersede_the_node_isotp_pair() {
	dir := desc_fixture('override')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	for i, n in sys.nodes {
		if n.name == 'zone_a' { // the system re-allocates zone_a; its ecu.toml still says 0x7C0
			sys.nodes[i].diag_req = 0x7C1
			sys.nodes[i].diag_rsp = 0x7C9
		}
		if n.name == 'domain' { // no `diag`: its own [isotp] is what addresses it
			sys.nodes[i].diag_req = 0
			sys.nodes[i].diag_rsp = 0
		}
	}
	assert sys.node_for(TargetAddr{ req: 0x7C0, rsp: 0x7C8 }).node == -1
	z := sys.node_for(TargetAddr{ req: 0x7C1, rsp: 0x7C9 })
	assert z.node >= 0 && sys.nodes[z.node].name == 'zone_a'
	d := sys.node_for(TargetAddr{ req: 0x7B0, rsp: 0x7B8 })
	assert d.node >= 0 && sys.nodes[d.node].name == 'domain'
	got := sys.can_targets([ChanRef{'edge', 'can1'}]).filter(sys.nodes[it.node].name == 'zone_a')
	assert got.len == 1 && got[0].req == 0x7C1
}

// The model is current while every file it was read from is as it was read — an ecu.toml edited
// behind an unchanged system.toml included, and one that appears where it was missing.
// The allocation table lists the ids a tester addresses a node by: a node with no `diag` in
// system.toml has its own [isotp] pair allocated, and a collision with it is shown.
fn test_the_allocation_uses_the_addressing_rule() {
	dir := desc_fixture('alloc')
	defer {
		os.rmdir_all(dir) or {}
	}
	sys_path := os.join_path(dir, 'system.toml')
	// domain loses its `diag`; its ecu.toml answers on 0x7B0/0x7B8, and chassis (edge) gets an
	// [isotp] pair colliding with zone_a request id
	text := os.read_file(sys_path) or { panic(err) }
	os.write_file(sys_path, text.replace('diag  = { req = 0x7B0, rsp = 0x7B8 }\n', '')) or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'nodes', 'chassis', 'ecu.toml'), '[isotp]\nrx_id = 0x7C0\ntx_id = 0x7E9\n') or {
		panic(err)
	}
	sys := load(sys_path) or { panic(err) }
	compute := sys.id_allocation('compute').filter(it.owner == 'domain' && it.kind.starts_with('diag'))
	assert compute.map(it.id) == [u32(0x7B0), 0x7B8]
	edge := sys.id_allocation('edge').filter(it.owner == 'chassis')
	assert edge.map(it.id) == [u32(0x7C0), 0x7E9]
	assert sys.is_collision('edge', 0x7C0, false)
}

fn test_the_model_knows_when_it_is_stale() {
	dir := desc_fixture('stale')
	defer {
		os.rmdir_all(dir) or {}
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	assert sys.current()
	assert sys.sources.map(os.file_name(os.dir(it.path))).contains('zone_a')
	before := sys.identity()
	os.write_file(os.join_path(dir, 'nodes', 'zone_a', 'ecu.toml'), fx_zone_a + '\n# edited\n') or {
		panic(err)
	}
	assert !sys.current()
	again := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	assert again.current() && again.identity() != before
	// a same-length rewrite within the same second: the content says so, mtime and size cannot
	zpath := os.join_path(dir, 'nodes', 'zone_a', 'ecu.toml')
	text := os.read_file(zpath) or { panic(err) }
	os.write_file(zpath, text.replace('SpeedImplausible', 'SpeedImplausiblX')) or { panic(err) }
	assert os.file_size(zpath) == u64(text.len)
	assert !again.current()
	os.write_file(zpath, text) or { panic(err) } // and back: current again
	assert again.current()
	// chassis has no ecu.toml in the fixture: writing one is a change too

	os.write_file(os.join_path(dir, 'nodes', 'chassis', 'ecu.toml'), '[uds]\n') or { panic(err) }
	assert !again.current()
}

fn test_find_system_beside_the_project_or_its_databases() {
	dir := desc_fixture('find')
	defer {
		os.rmdir_all(dir) or {}
	}
	sys_path := os.norm_path(os.join_path(dir, 'system.toml'))
	// beside the project
	assert find_system(os.join_path(dir, 'bench.blobnet'), []) or { '' } == sys_path
	// a test project one folder down, naming ../edge.dbc
	in_test := os.join_path(dir, 'test', 'diag_bench.blobnet')
	assert find_system(in_test, ['../edge.dbc']) or { '' } == sys_path
	// a reference that resolves only from the working directory (project.resolve_asset's
	// repo-root-relative form) is looked beside where it resolves
	far_proj := os.join_path(dir, 'nodes', 'zone_a', 'x', 'p.blobnet')
	old := os.getwd()
	os.chdir(dir) or { panic(err) }
	assert find_system(far_proj, ['edge.dbc']) == none // edge.dbc does not exist: nothing resolves
	os.write_file(os.join_path(dir, 'edge.dbc'), '') or { panic(err) }
	assert os.real_path(find_system(far_proj, ['edge.dbc']) or { '' }) == os.real_path(sys_path)
	os.chdir(old) or { panic(err) }
	os.rm(os.join_path(dir, 'edge.dbc')) or {}
	// the parent folder is the last resort, so it is found without a database too
	assert find_system(in_test, []) or { '' } == sys_path
	// nothing anywhere near
	far := os.join_path(dir, 'nodes', 'zone_a', 'x', 'p.blobnet')
	assert find_system(far, ['y.dbc']) == none
	assert find_system('', []) == none
}

// A gate's `security` must be a level 1..8 (blobly_emb's): 256 would be cast to no unlock, so
// such a DID is refused by name, not read.
fn test_a_gate_security_that_is_not_a_level_is_refused() {
	doc := toml.parse_text('
[[did]]
id = 0x0110
bytes = "00"
write = { session = ["extended"], security = 256 }

[[did]]
id = 0x0111
bytes = "00"
write = { security = 9 }

[[did]]
id = 0x0112
bytes = "00"
read = { security = -1 }

[[did]]
id = 0x0113
bytes = "00"
write = { security = "1" }

[[did]]
id = 0x0114
bytes = "00"
write = { session = ["extended"], security = 8 }

[[did]]
id = 0x0115
bytes = "00"
write = { security = 2 }
') or { panic(err) }
	d := parse_ecu_desc(doc, map[string][]Field{})
	assert d.dids.map(it.id) == [u16(0x0114), 0x0115]
	assert d.dids.map(it.write_gate.level) == [8, 2]
	assert d.errs.len == 4, d.errs.str()
	assert d.errs[0] == 'did 0x0110: write security 256 is not a security level (1..8); not read'
	assert d.errs[1].starts_with('did 0x0111: write security 9 ')
	assert d.errs[2].starts_with('did 0x0112: read security -1 ')
	assert d.errs[3].starts_with('did 0x0113: write security "1" ')
}

// A level in a gate that names only the default session cannot be met: said, the DID kept.
fn test_a_secured_default_only_gate_is_said() {
	doc := toml.parse_text('
[[did]]
id = 0x0120
bytes = "00"
write = { session = ["default"], security = 1 }
read = { session = ["default"], security = 2 }

[[did]]
id = 0x0121
bytes = "00"
write = { session = ["default", "extended"], security = 1 }
read = { session = ["default"] }
') or { panic(err) }
	d := parse_ecu_desc(doc, map[string][]Field{})
	assert d.dids.map(it.id) == [u16(0x0120), 0x0121]
	assert d.errs == []
	assert d.warns == [
		'did 0x0120: read gate needs security level 2 but names only the default session, where 0x27 is not served',
		'did 0x0120: write gate needs security level 1 but names only the default session, where 0x27 is not served',
	], d.warns.str()
}

// The levels an Unlock offers first: the DIDs' gates and the `[uds] services` rows, each once.
fn test_the_security_levels_a_description_names() {
	doc := toml.parse_text('
[uds]
security_key = "reference"

[uds.services]
"0x10" = {}
"0x11" = { sessions = ["extended"], security = 3 }
"0x28" = { security = 9 }
"0x31" = { security = "1" }

[[did]]
id = 0x0110
bytes = "00"
write = { session = ["extended"], security = 2 }

[[did]]
id = 0x0111
bytes = "00"
read = { security = 2 }
') or { panic(err) }
	d := parse_ecu_desc(doc, map[string][]Field{})
	assert d.security_levels() == [2, 3]
	assert d.errs == ['[uds] services 0x28 security 9 is not a security level (1..8); not read',
		'[uds] services 0x31 security "1" is not a security level (1..8); not read']
	assert parse_ecu_desc(toml.parse_text('[uds]') or { panic(err) }, map[string][]Field{}).security_levels() == []
}

// Over DoIP the reference key needs the node's opt-in: the system.toml node's `doip` table (which
// sysgen lowers into [doip]) or, for a node on its own, its ecu.toml's [doip].
fn test_the_bench_key_opt_in_is_carried() {
	dir := desc_fixture('benchkey')
	defer {
		os.rmdir_all(dir) or {}
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	sn := sys.nodes.filter(it.name == 'sysnode')[0] or { panic('no sysnode') }
	assert sn.desc.allow_bench_key
	z := sys.nodes.filter(it.name == 'zone_a')[0] or { panic('no zone_a') }
	assert !z.desc.allow_bench_key
	on := parse_ecu_desc(toml.parse_text('[doip]\nallow_bench_key = true') or { panic(err) },
		map[string][]Field{})
	assert on.allow_bench_key
	bad := parse_ecu_desc(toml.parse_text('[doip]\nallow_bench_key = "yes"') or { panic(err) },
		map[string][]Field{})
	assert !bad.allow_bench_key
}

// A label no binding can carry — a NUL in a parameter's or a signal's field name, or in a
// parameter's name — is refused at load, as a duplicate parameter is (#542).
fn test_a_field_name_holding_a_nul_is_refused() {
	doc := toml.parse_text('
[[signal]]
name = "Speed"
fields = { "v\\u0000a" = "u16" }

[[param]]
name = "Limit"
fields = { "x\\u0000a" = "u16", "x\\u0000b" = "u16" }

[[param]]
name = "Lim\\u0000it"
fields = { deg = "u16" }

[[param]]
name = "Limit"
fields = { deg = "u16" }

[[param]]
name = "Trim"
fields = { deg = "u16" }

[[signal]]
name = "Sp\\u0000eed"
fields = { v = "u16" }

[[signal]]
name = "Pair"
fields = { "a\\u0000" = "u8", b = "u8" }

[[did]]
id = 0x0203
signal = "Sp\\u0000eed"

[[did]]
id = 0x0204
signal = "Pair"

[[did]]
id = 0x0205
param_status = true

[[did]]
id = 0x0200
signal = "Speed"

[[did]]
id = 0x0201
param = "Limit"

[[did]]
id = 0x0202
param = "Trim"
') or { panic(err) }
	d := parse_ecu_desc(doc, map[string][]Field{})
	assert d.params.map(it.name) == ['Trim']
	// a two-field signal's fields are not carried by a DID, so its NUL drops nothing
	assert d.dids.map(it.id) == [u16(0x0204), 0x0205, 0x0201, 0x0202]
	assert d.dids[1].fields.len == 0 && d.param_status_did() == none
	assert d.errs.len == 8, d.errs.str()
	assert d.errs[0] == 'param Limit: field "x\\0a" holds a NUL; not read'
	assert d.errs[1] == 'param Lim\\0it: the name holds a NUL; not read'
	assert d.errs[2] == 'param Limit: declared twice; the second not read'
	assert d.errs[3] == 'did 0x0203: signal Sp\\0eed: the name holds a NUL; not read'
	assert d.errs[4].starts_with('did 0x0204: signal Pair has no single integer field')
	assert d.errs[5] == 'did 0x0205: parameter status: a [[param]] was not read, so its byte positions are not known'
	assert d.errs[6] == 'did 0x0200: signal Speed: field "v\\0a" holds a NUL; not read'
	assert d.errs[7] == 'did 0x0201: [[param]] Limit was not read'
}

// The format is part of a node's identity (blobly_emb docs/can-tp.md §3.8): three nodes on one bus,
// one 29-bit on 0x123/0x124, one 11-bit on the same numbers, one on normal fixed addressing — each
// found by its own format, allocated in it, and reached by a script in it.
const fx_formats = '
[bus.body]
interface = "can0"

[[node]]
name  = "n29"
ecu   = "nodes/n29/ecu.toml"
buses = ["body"]
diag  = { req = 0x123, rsp = 0x124, ext = true }

[[node]]
name  = "n11"
ecu   = "nodes/n11/ecu.toml"
buses = ["body"]
diag  = { req = 0x123, rsp = 0x124 }

[[node]]
name  = "nf"
ecu   = "nodes/nf/ecu.toml"
buses = ["body"]
diag  = { addressing = "normal_fixed", sa = 0x10, ta = 0xF1 }

[[node]]
name  = "nl"
ecu   = "nodes/nl/ecu.toml"
buses = ["body"]
diag  = { addressing = "normal_fixed", sa = 0x20, ta = 0xF1, functional_ta = 0x33 }
'

fn test_a_nodes_id_format_is_part_of_its_address() {
	dir := os.join_path(os.temp_dir(), 'sysview_formats_${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	for n, isotp in {
		'n29': 'rx_id = 0x123\ntx_id = 0x124\next = true'
		'n11': 'rx_id = 0x123\ntx_id = 0x124'
		'nf':  'addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1'
		// a dissolved node's [isotp] that states no ids: blobly_emb's sysgen lowers its diag into it
		'nl':  ''
	} {
		os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
		os.write_file(os.join_path(dir, 'nodes', n, 'ecu.toml'), '[isotp]\nbus = "can0"\n${isotp}\n') or {
			panic(err)
		}
	}
	os.write_file(os.join_path(dir, 'system.toml'), fx_formats) or { panic(err) }
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	idx := fn [sys] (name string) int {
		return sys.node_named(name) or { panic(err) }
	}
	n29, n11, nf := idx('n29'), idx('n11'), idx('nf')
	q29, p29 := sys.nodes[n29].can_ids()
	q11, p11 := sys.nodes[n11].can_ids()
	qf, pf := sys.nodes[nf].can_ids()
	assert q29 == 0x123 && p29 == 0x124 && sys.nodes[n29].can_ext()
	assert q11 == 0x123 && p11 == 0x124 && !sys.nodes[n11].can_ext()
	assert qf == 0x18DA10F1 && pf == 0x18DAF110 && sys.nodes[nf].can_ext()
	assert sys.nodes[n29].desc.isotp_ext && !sys.nodes[n11].desc.isotp_ext && sys.nodes[nf].desc.isotp_ext
	// node_for: one number, two formats, two nodes
	assert sys.node_for(TargetAddr{ req: 0x123, rsp: 0x124, ext: true }).node == n29
	assert sys.node_for(TargetAddr{ req: 0x123, rsp: 0x124 }).node == n11
	assert sys.node_for(TargetAddr{ req: 0x18DA10F1, rsp: 0x18DAF110 }).node == nf // past 0x7FF: 29-bit
	miss := sys.node_for(TargetAddr{ req: 0x125, rsp: 0x126, ext: true })
	assert miss.node == -1 && miss.why.contains('0x125/0x126 (29-bit)'), miss.why
	// the allocation keeps the two formats apart: neither id collides
	alloc := sys.id_allocation('body').filter(it.id == 0x123)
	assert alloc.len == 2 && alloc.any(it.ext && it.owner == 'n29') && alloc.any(!it.ext && it.owner == 'n11')
	assert !sys.is_collision('body', 0x123, true) && !sys.is_collision('body', 0x123, false)
	// can_targets carry the format, which the GUI's target key holds apart
	ts := sys.can_targets([ChanRef{'body', 'can0'}])
	assert ts.filter(it.node == n29).all(it.ext) && ts.filter(it.node == n11).all(!it.ext)
	assert ts.filter(it.node == nf).all(it.ext && it.req == 0x18DA10F1)
	// reach: the 11-bit node is not contested by its 29-bit twin, and opens
	rows := [RowRef{
		name: 'body'
		wire: 'can0'
	}]
	r11 := sys.reach(n11, rows, -1) or { panic(err) }
	assert r11.req == 0x123 && !r11.ext
	// the 29-bit node on 11-bit-sized ids is reached in its width, which the opener is handed
	// (udsconn.Ask.ext)
	assert sys.targets(n29, rows).len == 1 && sys.targets(n29, rows)[0].ext
	r29 := sys.reach(n29, rows, -1) or { panic(err) }
	assert r29.req == 0x123 && r29.rsp == 0x124 && r29.ext
	r29b := sys.reach(n29, rows, 0) or { panic(err) }
	assert r29b == r29
	// normal fixed addressing's ids are past 0x7FF: a script opens them as 29-bit
	rf := sys.reach(nf, rows, -1) or { panic(err) }
	assert rf.ext && rf.req == 0x18DA10F1 && rf.rsp == 0x18DAF110
	// an [isotp] stating no ids serves on the node's diag (blobly_emb REQ-TOPO-014): addressed by it
	nl := idx('nl')
	assert sys.nodes[nl].desc.isotp_req == 0 && sys.nodes[nl].desc.isotp_rsp == 0
	ql, pl := sys.nodes[nl].can_ids()
	assert ql == 0x18DA20F1 && pl == 0x18DAF120 && sys.nodes[nl].can_ext()
	rl := sys.reach(nl, rows, -1) or { panic(err) }
	assert rl.ext && rl.req == 0x18DA20F1 && rl.rsp == 0x18DAF120
}

// A diag or an [isotp] that states ids nothing can read is said, and addresses nothing: a diag's
// [isotp] pair does not stand in for it (the system gave the node no address), an addressing this
// reader does not know is not read as normal addressing, and a tester is told why the node has no
// CAN target.
const fx_unreadable = '
[bus.body]
interface = "can0"

[[node]]
name  = "half"
ecu   = "nodes/half/ecu.toml"
buses = ["body"]
diag  = { addressing = "normal_fixed", ta = 0xF1 }

[[node]]
name  = "ext"
ecu   = "nodes/ext/ecu.toml"
buses = ["body"]
diag  = { addressing = "extended", req = 0x7A0, rsp = 0x7A8 }

[[node]]
name  = "str"
ecu   = "nodes/str/ecu.toml"
buses = ["body"]
diag  = { req = "0x7A0", rsp = "0x7A8" }

[[node]]
name  = "one"
ecu   = "nodes/one/ecu.toml"
buses = ["body"]
diag  = { rsp = 0x7A8 }

[[node]]
name  = "own"
ecu   = "nodes/own/ecu.toml"
buses = ["body"]
'

fn test_an_unreadable_addressing_addresses_nothing_and_says_why() {
	dir := os.join_path(os.temp_dir(), 'sysview_unreadable_${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	for n, isotp in {
		'half': 'rx_id = 0x7C0\ntx_id = 0x7C8'
		'ext':  'rx_id = 0x7D0\ntx_id = 0x7D8'
		'own':  'addressing = "mixed"\nrx_id = 0x7E0\ntx_id = 0x7E8'
		'str':  'rx_id = 0x7E0\ntx_id = 0x7E8'
		'one':  'rx_id = 0x7F0\ntx_id = 0x7F8'
	} {
		os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
		os.write_file(os.join_path(dir, 'nodes', n, 'ecu.toml'), '[isotp]\nbus = "can0"\n${isotp}\n') or {
			panic(err)
		}
	}
	os.write_file(os.join_path(dir, 'system.toml'), fx_unreadable) or { panic(err) }
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	assert 'node half: diag addressing = "normal_fixed" needs sa (the node\'s own address, 0..255); it addresses nothing' in sys.errs, sys.errs.str()
	assert 'node ext: diag addressing "extended" is not "normal" or "normal_fixed" (extended and mixed addressing are not supported); it addresses nothing' in sys.errs, sys.errs.str()
	rows := [RowRef{
		name: 'body'
		wire: 'can0'
	}]
	assert 'node str: diag req = "0x7A0" is not an integer CAN id; it addresses nothing' in sys.errs, sys.errs.str()
	assert 'node one: diag gives rsp without req (normal addressing states both); it addresses nothing' in sys.errs, sys.errs.str()
	for name in ['half', 'ext', 'str', 'one'] {
		i := sys.node_named(name) or { panic(err) }
		n := sys.nodes[i]
		assert n.diag_err != ''
		// the node's own [isotp] pair is not an address the system gave it
		q, p := n.can_ids()
		assert q == 0 && p == 0, name
		assert sys.can_targets([ChanRef{'body', 'can0'}]).filter(it.node == i).len == 0
		sys.reach(i, rows, -1) or {
			assert err.msg().contains('its diag in system.toml could not be read (${n.diag_err})'), err.msg()
			continue
		}
		assert false, '${name} was reached on an address its system never gave it'
	}
	// an [isotp] of an addressing not known here: said in its ecu.toml's errors, and no target
	i := sys.node_named('own') or { panic(err) }
	own := sys.nodes[i]
	assert '[isotp] addressing "mixed" is not "normal" or "normal_fixed" (extended and mixed addressing are not supported); it addresses nothing' in own.desc.errs
	assert own.desc.isotp_err != '' && own.desc.isotp_req == 0 && own.desc.isotp_rsp == 0
	sys.reach(i, rows, -1) or {
		assert err.msg().contains('its ecu.toml [isotp] could not be read'), err.msg()
		return
	}
	assert false, 'a node whose [isotp] is mixed addressing was reached with normal addressing'
}

// An [isotp] id that is not an integer is said in its ecu.toml's errors and addresses nothing, never
// read as id 0 beside the other.
fn test_an_isotp_id_that_is_not_an_integer_addresses_nothing() {
	dir := os.join_path(os.temp_dir(), 'sysview_isotp_str_${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	os.mkdir_all(os.join_path(dir, 'nodes', 'ostr')) or { panic(err) }
	os.write_file(os.join_path(dir, 'nodes', 'ostr', 'ecu.toml'), '[isotp]\nbus = "can0"\nrx_id = "0x7E0"\ntx_id = 0x7E8\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'system.toml'), '[bus.body]\ninterface = "can0"\n\n[[node]]\nname = "ostr"\necu = "nodes/ostr/ecu.toml"\nbuses = ["body"]\n') or {
		panic(err)
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	i := sys.node_named('ostr') or { panic(err) }
	n := sys.nodes[i]
	assert '[isotp] rx_id = "0x7E0" is not an integer CAN id; it addresses nothing' in n.desc.errs, n.desc.errs.str()
	assert n.desc.isotp_err != ''
	q, p := n.can_ids()
	assert q == 0 && p == 0
	sys.reach(i, [RowRef{
		name: 'body'
		wire: 'can0'
	}], -1) or {
		assert err.msg().contains('its ecu.toml [isotp] could not be read'), err.msg()
		return
	}
	assert false, 'a node whose [isotp] rx_id is a string was reached'
}

const auth_desc = '
[uds]
access    = "authentication"
auth_keys = { "1" = "reference" }

[[did]]
id    = 0xF1B0
ascii = "SECRET"
read  = { session = ["extended"], security = 1 }

[[did]]
id    = 0x0110
bytes = "00"
write = { session = ["extended"], security = 1 }
'

// `[uds] access` and `auth_keys` are read as blobly_emb reads them, what loom2v refuses said in errs,
// and the server a simulation serves authenticates with the same keys
fn test_an_authenticating_description() {
	d := parse_ecu_desc(toml.parse_text(auth_desc) or { panic(err) }, map[string][]Field{})
	assert d.errs == [], d.errs.str()
	assert d.authenticates() && d.auth_ref[1] && d.auth_keys[1] == uds.dev_tester_public()
	spec, notes := d.server_spec(false)
	assert spec.authenticates && spec.auth_key(1) or { []u8{} } == uds.dev_tester_public()
	assert !notes.any(it.contains('0x27')), notes.str()
	// over DoIP without allow_bench_key the dev key is refused, as the node refuses it
	rs, rn := d.server_spec(true)
	assert rs.auth_key(1) or { []u8{} } != uds.dev_tester_public()
	assert rn.any(it.contains('0x29 refuses the dev tester key'))
	// a gated write plans an authenticate, and WriteGated names 0x29
	w := d.dids.filter(it.id == 0x0110)[0]
	p := w.plan_write(uds.ConnState{ session: 0x03 }, true)
	assert p.authenticates && p.steps() == ['authenticate level 1 (0x29 05/06)']
	g := WriteGated{
		did:           0x0110
		level:         1
		authenticates: true
	}
	assert g.msg().contains('0x29') && !g.msg().contains('0x27')
}

fn test_an_authentication_description_that_cannot_work_is_said() {
	zero := '00'.repeat(32)
	for text, want in {
		auth_desc.replace('"1" = "reference"', '"2" = "reference"'):                           'security level 1 is gated but auth_keys has no key'
		auth_desc.replace('"1" = "reference"', '"1" = "reference", "2" = "reference"'):        'no gate names security level 2'
		auth_desc.replace('"reference"', '"abcd"'):                                             'is not 64 hex characters'
		auth_desc.replace('"reference"', '"${zero}"'):                                          'is all zeros'
		auth_desc.replace('"reference"', '"02${'00'.repeat(31)}"'):                             'not a curve point'
		auth_desc.replace('"reference"', '"01${'00'.repeat(31)}"'):                             'is a point of small order'
		auth_desc.replace('"reference"', '"EE${'FF'.repeat(30)}7F"'):                           'is a point of small order'
		auth_desc.replace('"1" = ', '"9" = '):                                                  'is not a security level'
		auth_desc.replace('access    = "authentication"', 'access = "password"'):              'is neither'
		auth_desc.replace('access    = "authentication"\n', ''):                               'access is "seed_key"'
		auth_desc.replace('access    = "authentication"', 'access = "authentication"\nsecurity_key = "reference"'): 'security_key is the 0x27 key'
	} {
		d := parse_ecu_desc(toml.parse_text(text) or { panic(err) }, map[string][]Field{})
		assert d.errs.any(it.contains(want)), '${want}: ${d.errs}'
	}
}

// a key of small order is refused, in every encoding, and so cannot unlock the simulated node with
// the forged proof that verifies under it (R = the neutral point, S = 0)
fn test_a_small_order_auth_key_is_refused() {
	for h in ['0100000000000000000000000000000000000000000000000000000000000000',
		'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
		'0000000000000000000000000000000000000000000000000000000000000080',
		'26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05',
		'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa',
		'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'] {
		d := parse_ecu_desc(toml.parse_text(auth_desc.replace('"reference"', '"${h}"')) or {
			panic(err)
		}, map[string][]Field{})
		assert d.errs.any(it.contains('small order')), '${h}: ${d.errs}'
		assert 1 !in d.auth_keys
		spec, _ := d.server_spec(false)
		mut s := uds.server_from(spec)
		s.handle([u8(0x10), 0x03])
		ans := s.handle(uds.auth_challenge_request(1))
		mut forged := []u8{len: 64}
		forged[0] = 1
		assert s.handle(uds.auth_proof_request(forged))[0] != 0x69, '${h}: a forged proof unlocked'
		assert s.unlocked == 0 && ans[0] == 0x7F // no key for the level: its challenge is refused
	}
}

// the dev tester key written as its hex, in either case, IS the bench key: over DoIP without
// allow_bench_key the level is refused as for "reference"
fn test_the_dev_key_written_as_hex_is_the_bench_key() {
	hex := uds.dev_tester_public().hex()
	for spelling in [hex, hex.to_upper()] {
		d := parse_ecu_desc(toml.parse_text(auth_desc.replace('"reference"', '"${spelling}"')) or {
			panic(err)
		}, map[string][]Field{})
		assert d.errs == [] && d.auth_ref[1], spelling
		_, notes := d.server_spec(true)
		assert notes.any(it.contains('0x29 refuses the dev tester key')), spelling
	}
}

// a level whose key the node refuses here verifies NO proof — neither the dev seed's nor any seed's
// (no stand-in key whose seed is in the source); its challenge is served as the node serves one
fn test_a_refused_bench_key_verifies_no_proof() {
	d := parse_ecu_desc(toml.parse_text(auth_desc) or { panic(err) }, map[string][]Field{})
	spec, _ := d.server_spec(true)
	assert spec.auth_refused == 0x01
	for seed in [uds.dev_tester_seed(), []u8{len: 32, init: 0xA5}, []u8{len: 32, init: 0x11}] {
		mut s := uds.server_from(spec)
		s.handle([u8(0x10), 0x03])
		ans := s.handle(uds.auth_challenge_request(1))
		assert ans[0] == 0x69, 'the challenge of a refused level was not served'
		ch := ans[uds.auth_answer_challenge_at..uds.auth_answer_challenge_at + uds.auth_challenge_len]
		proof := uds.app_proof_of(seed, 1, ch) or { panic(err) }
		assert s.handle(uds.auth_proof_request(proof)) == [u8(0x7F), 0x29, 0x58], 'seed ${seed[0]:02X} unlocked'
		assert s.unlocked == 0
	}
}

// an ecu.toml's [[routine]] tables are not read yet: said, so an empty listing is not taken for
// none declared
fn test_routine_tables_are_said_not_read() {
	doc := toml.parse_text('[[routine]]
id = 0x0203
name = "SelfTest"

[[routine]]
id = 0x0204
name = "SensorCalibration"
') or { panic(err) }
	d := parse_ecu_desc(doc, map[string][]Field{})
	assert d.routines.len == 0
	assert d.errs.any(it.starts_with('2 [[routine]] not read'))
}
