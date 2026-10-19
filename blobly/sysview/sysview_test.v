module sysview

import os

// A miniature two-node system written to a temp dir: the system_bench shape
// (bus + NM cluster + once-declared signals + nodes with internals), plus a
// PLANTED id collision (diag req == an NM alive id) the allocation table must
// surface.

fn fixture_dir() string {
	dir := os.join_path(os.temp_dir(), 'sysview_fix_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(os.join_path(dir, 'nodes')) or { panic(err) }
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
fd        = false
bitrate   = 500000
dbc       = "compute.dbc"
nm        = { peers = [0x500, 0x53F], timeout_ms = 300 }

[bus.tel]
kind    = "someip"
service = 0x0100
version = 1

[[signal]]
name     = "VehicleSpeed"
fields   = { kph = "u32" }
producer = "sysnode"
bus      = "compute"
frame    = "VehSpeedFrame"
cycle_ms = 100

[[signal]]
name     = "EngineRpm"
fields   = { rpm = "u32" }
producer = "domain"
bus      = "compute"
frame    = "EngineRpmFrame"
cycle_ms = 50

[[node]]
name  = "sysnode"
ecu   = "nodes/sysnode.toml"
buses = ["compute", "tel"]
nm    = 0x11
diag  = { req = 0x7A0, rsp = 0x7A8 }

[[node]]
name  = "domain"
ecu   = "nodes/domain.toml"
buses = ["compute"]
nm    = 0x13
diag  = { req = 0x511, rsp = 0x7B8 }
') or {
		panic(err)
	}
	// 0x511 collides with sysnode NM alive (0x500 + 0x11) — planted.
	os.write_file(os.join_path(dir, 'nodes', 'sysnode.toml'), '
[[fb]]
name = "Hmi"
thread = "app_main"
  [[fb.handler]]
  name = "on_10ms"
  period_ms = 10
  reads = ["EngineRpm"]
  writes = ["VehicleSpeed"]
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'nodes', 'domain.toml'), '
[[fb]]
name = "Engine"
thread = "ctrl_main"
  [[fb.handler]]
  name = "on_10ms"
  period_ms = 10
  reads = ["VehicleSpeed"]
  writes = ["EngineRpm"]
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: sysnode domain

BO_ 256 VehSpeedFrame: 8 sysnode
 SG_ VehicleSpeed : 0|32@1+ (1,0) [0|0] "" Vector__XXX

BO_ 512 EngineRpmFrame: 8 domain
 SG_ EngineRpm : 0|32@1+ (1,0) [0|0] "" Vector__XXX
') or {
		panic(err)
	}
	return dir
}

fn test_load_and_derive() {
	dir := fixture_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }

	assert sys.buses.len == 2
	compute := sys.buses.filter(it.name == 'compute')[0]
	assert compute.nm_lo == 0x500 && compute.kind == 'can'
	assert sys.nodes.len == 2
	assert sys.nodes[0].ecu_err == '' && sys.nodes[1].ecu_err == ''

	// consumers derived from the node internals
	assert sys.signals[0].name == 'VehicleSpeed'
	assert sys.signals[0].consumers == ['domain']
	assert sys.signals[1].consumers == ['sysnode']

	// matrix cells: producer / consumer, and locals line up
	assert sys.matrix_cell(sys.signals[0], sys.nodes[0]) == 'P'
	assert sys.matrix_cell(sys.signals[0], sys.nodes[1]) == 'C'
	assert sys.matrix_cell(sys.signals[1], sys.nodes[0]) == 'C'
	assert sys.matrix_cell(sys.signals[1], sys.nodes[1]) == 'P'
}

fn test_id_allocation_and_planted_collision() {
	dir := fixture_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }

	alloc := sys.id_allocation('compute')
	// 2 DBC frames + 2 NM alive + 2 diag pairs = 8 entries
	assert alloc.len == 8, '${alloc.len}'
	assert alloc[0].id == 0x100 && alloc[0].kind == 'frame'

	// the planted collision: domain diag req 0x511 == sysnode NM (0x500+0x11)
	assert sys.collision_count('compute') == 1
	assert sys.is_collision('compute', 0x511, false)
	// kind-awareness: a std/ext numeric twin of a clean id is untouched, and
	// even at the COLLIDING number an ext identity would be innocent
	assert !sys.is_collision('compute', 0x511, true)
	assert !sys.is_collision('compute', 0x100, false)
}

fn test_someip_bus_has_no_can_allocation() {
	dir := fixture_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }

	// no DBC is the someip contract, not an omission; and sysnode's CAN diag/NM ids are not tel's
	assert sys.buses.filter(it.name == 'tel')[0].kind == 'someip'
	assert sys.id_allocation('tel').len == 0
	assert sys.errs.filter(it.starts_with('bus tel')).len == 0, '${sys.errs}'
}

fn test_unknown_bus_kind_is_said() {
	dir := fixture_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'system.toml')
	os.write_file(path, os.read_file(path) or { panic(err) }.replace('kind    = "someip"',
		'kind    = "CAN"')) or { panic(err) }
	sys := load(path) or { panic(err) }
	assert sys.errs.any(it.contains('unknown kind "CAN"')), '${sys.errs}'
	assert !sys.buses.filter(it.name == 'tel')[0].is_can()
}

fn test_missing_node_ecu_degrades_not_fails() {
	dir := fixture_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	os.rm(os.join_path(dir, 'nodes', 'domain.toml')) or {}
	sys := load(os.join_path(dir, 'system.toml')) or { panic(err) }
	assert sys.nodes[1].ecu_err != '' // reported, not fatal
	assert sys.signals[1].consumers == ['sysnode'] // the readable side still derives
}
