module sysview

import os

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
	// sysnode on both buses; chassis (no server) is not a target
	assert got == ['sysnode@compute/can0 0x7A0/0x7A8', 'sysnode@edge/can1 0x7A0/0x7A8',
		'domain@compute/can0 0x7B0/0x7B8', 'zone_a@edge/can1 0x7C0/0x7C8']
	assert sys.can_targets([ChanRef{'CAN1', 'inproc:CAN1'}]) == []
	assert sys.can_targets(chans).all(!it.shared_name)
	// two channels named edge are two wires: a target on each, each saying its name is shared
	twins := sys.can_targets([ChanRef{'edge', 'can1'}, ChanRef{'edge', 'vcan1'}]).filter(sys.nodes[it.node].name == 'zone_a')
	assert twins.map(it.iface) == ['can1', 'vcan1']
	assert twins.all(it.shared_name)
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
