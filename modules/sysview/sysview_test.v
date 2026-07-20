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
buses = ["compute"]
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

	assert sys.buses.len == 1
	assert sys.buses[0].name == 'compute' && sys.buses[0].nm_lo == 0x500
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
	cols := sys.collisions('compute')
	assert cols == [u32(0x511)], '${cols}'
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
