module sim

import candb
import os
import project
import toml
import transport
import sysview
import uds

// A trimmed copy of blobly_emb's examples/system_full (origin/main a8728c9): zone_a and sysnode as
// written there — their DIDs, parameter, faults, `[uds]` and `[boot]` — and a domain node given an
// OEM key and a read-gated DID, which no system_full node has, to cover the other side of 0x27.

const dx_system = '
[bus.compute]
interface = "can0"
fd        = false
bitrate   = 500000

[bus.edge]
interface = "can1"
fd        = true
bitrate   = 500000

[[signal]]
name     = "SteeringAngle"
fields   = { deg = "u32" }
producer = "zone_a"
bus      = "edge"
frame    = "SteeringFrame"
cycle_ms = 50

[[signal]]
name     = "GwUptime"
fields   = { s = "u32" }
producer = "sysnode"
bus      = "compute"
frame    = "GwStatusFrame"
cycle_ms = 1000

[[node]]
name     = "sysnode"
ecu      = "nodes/sysnode/ecu.toml"
buses    = ["compute", "edge", "tel"]
diag     = { req = 0x7A0, rsp = 0x7A8 }
doip     = { logical = 0x07A0, testers = [0x0E00], allow_bench_key = true }

[[node]]
name  = "domain"
ecu   = "nodes/domain/ecu.toml"
buses = ["compute"]
diag  = { req = 0x7B0, rsp = 0x7B8 }

[[node]]
name  = "zone_a"
ecu   = "nodes/zone_a/ecu.toml"
buses = ["edge"]
diag  = { req = 0x7C0, rsp = 0x7C8 }
'

const dx_zone_a = '
[[param]]
name    = "SteerLimit"
fields  = { deg = "u16" }
default = { deg = 360 }
range   = { deg = { min = 0, max = 360 } }   # refused at 0x2E (0x31) and at restore
apply   = "reset"

[[fault]]
name     = "SpeedImplausible"
dtc      = 0xC40100
from     = "SteerLimiter.on_50ms"
freeze   = [0xF1A0]

[[fault]]
name   = "SafetyCmdTimeout"
dtc    = 0xC16400
signal = "SafetyCmd"
on     = "timeout"

[uds]
s3_ms             = 5000
security_attempts = 3
security_delay_ms = 3000
security_key      = "reference"

[boot]
image_key   = "03a1"

[isotp]
bus   = "can0"
rx_id = 0x7C0
tx_id = 0x7C8

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
id             = 0x0120
tx_saturations = true

[[did]]
id    = 0x0102
bytes = "00"
write = { session = ["extended"], security = 1 }
'

const dx_sysnode = '
[uds]
s3_ms             = 5000
security_key      = "reference"

[uds.services]
"0x10" = {}
"0x10 02" = { security = 1 }
"0x11" = { sessions = ["extended"], security = 1 }
"0x22" = {}
"0x27" = {}
"0x2E" = {}
"0x3E" = {}

[boot]
image_key = "03a1"

[isotp]
rx_id = 0x7A0
tx_id = 0x7A8

[[did]]
id    = 0xF190
ascii = "BLOBLYSYSNODEH735"

[[did]]
id     = 0x0130
signal = "GwUptime"

[[did]]
id    = 0x0102
bytes = "00"
write = { session = ["extended"], security = 1 }
'

const dx_domain = '
[uds]

[isotp]
rx_id = 0x7B0
tx_id = 0x7B8

[[did]]
id    = 0x0200
bytes = "AA BB"
read  = { session = ["extended"], security = 1 }
'

fn dx_load(name string) sysview.System {
	dir := os.join_path(os.temp_dir(), 'sim_described_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	for n in ['sysnode', 'domain', 'zone_a'] {
		os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
	}
	os.write_file(os.join_path(dir, 'system.toml'), dx_system) or { panic(err) }
	os.write_file(os.join_path(dir, 'nodes', 'zone_a', 'ecu.toml'), dx_zone_a) or { panic(err) }
	os.write_file(os.join_path(dir, 'nodes', 'sysnode', 'ecu.toml'), dx_sysnode) or { panic(err) }
	os.write_file(os.join_path(dir, 'nodes', 'domain', 'ecu.toml'), dx_domain) or { panic(err) }
	sys := sysview.load(os.join_path(dir, 'system.toml')) or { panic(err) }
	os.rmdir_all(dir) or {}
	return sys
}

fn zone_a(sys sysview.System) uds.Server {
	d := describe(&sys, sysview.TargetAddr{ req: 0x7C0, rsp: 0x7C8, bus: 'edge' }, 'zone_a',
		none, false)
	assert d.ok, d.notes.str()
	assert d.node == 'zone_a'
	return d.server
}

fn h(mut s uds.Server, req []u8) []u8 {
	return s.handle(req)
}

// the key blobly_net's client computes for a seed answer
fn ref_key(resp []u8) []u8 {
	return uds.security_key(resp[2..])
}

fn unlock(mut s uds.Server) {
	assert h(mut s, [u8(0x10), 0x03])[0] == 0x50
	seed := h(mut s, [u8(0x27), 0x01])
	assert seed[0] == 0x67
	mut key := [u8(0x27), 0x02]
	key << ref_key(seed)
	assert h(mut s, key) == [u8(0x67), 0x02]
}

fn test_values_and_sizes_are_the_descriptions() {
	sys := dx_load('values')
	mut s := zone_a(sys)
	mut want := [u8(0x62), 0xF1, 0x90]
	want << 'BLOBLY-ZONE_A-H723'.bytes()
	assert h(mut s, [u8(0x22), 0xF1, 0x90]) == want
	assert h(mut s, [u8(0x22), 0x01, 0x10]) == [u8(0x62), 0x01, 0x10, 0x01, 0x68] // the default, 360
	assert h(mut s, [u8(0x22), 0x01, 0x11]) == [u8(0x62), 0x01, 0x11, 0x00] // uncoded
	assert h(mut s, [u8(0x22), 0x01, 0x20]) == [u8(0x62), 0x01, 0x20, 0, 0, 0, 0]
	assert h(mut s, [u8(0x22), 0xF1, 0xA0]) == [u8(0x62), 0xF1, 0xA0, 0, 0, 0, 0] // no simulation: zeros
	assert h(mut s, [u8(0x22), 0xF1, 0x95]) == [u8(0x62), 0xF1, 0x95, 0, 0, 0, 0] // [boot]: the image version
	// several DIDs in one request, an undeclared one among them skipped
	r := h(mut s, [u8(0x22), 0x01, 0x02, 0x12, 0x34, 0xF1, 0x89])
	assert r[..6] == [u8(0x62), 0x01, 0x02, 0x00, 0xF1, 0x89]
	assert h(mut s, [u8(0x22), 0x12, 0x34]) == [u8(0x7F), 0x22, 0x31]
	assert h(mut s, [u8(0x22), 0xF1]) == [u8(0x7F), 0x22, 0x13]
	// the fault memory: every declared DTC at its power-on status, availability 0x7F
	assert h(mut s, [u8(0x19), 0x0A]) == [u8(0x59), 0x0A, 0x7F, 0xC4, 0x01, 0x00, 0x50, 0xC1,
		0x64, 0x00, 0x50]
	assert h(mut s, [u8(0x19), 0x03]) == [u8(0x59), 0x03] // nothing failed, nothing frozen
}

fn test_a_gated_write_needs_extended_and_the_level() {
	sys := dx_load('gate')
	mut s := zone_a(sys)
	assert h(mut s, [u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x7F), 0x2E, 0x31] // not writable in default
	assert h(mut s, [u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x7F] // 0x27 is not served in default
	assert h(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert h(mut s, [u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x7F), 0x2E, 0x33] // locked
	assert h(mut s, [u8(0x27), 0x03]) == [u8(0x7F), 0x27, 0x12] // level 2: nothing is gated on it
	assert h(mut s, [u8(0x27), 0x02, 0, 0, 0, 0]) == [u8(0x7F), 0x27, 0x24] // no seed outstanding
	unlock(mut s)
	assert h(mut s, [u8(0x27), 0x01]) == [u8(0x67), 0x01, 0, 0, 0, 0] // unlocked: the zero seed
	assert h(mut s, [u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x6E), 0x01, 0x02]
	assert h(mut s, [u8(0x22), 0x01, 0x02]) == [u8(0x62), 0x01, 0x02, 0x05]
	assert h(mut s, [u8(0x2E), 0xF1, 0x90, 0x41]) == [u8(0x7F), 0x2E, 0x31] // never writable
	// a session entry relocks: back in default, the write is out of its session again
	assert h(mut s, [u8(0x10), 0x01])[0] == 0x50
	assert h(mut s, [u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x7F), 0x2E, 0x31]
}

fn test_a_parameter_is_written_within_its_range() {
	sys := dx_load('param')
	mut s := zone_a(sys)
	unlock(mut s)
	assert h(mut s, [u8(0x2E), 0x01, 0x10, 0x01, 0x90]) == [u8(0x7F), 0x2E, 0x31] // 400 > 360
	assert h(mut s, [u8(0x2E), 0x01, 0x10, 0x00]) == [u8(0x7F), 0x2E, 0x13] // a u16 is two bytes
	assert h(mut s, [u8(0x22), 0x01, 0x11]) == [u8(0x62), 0x01, 0x11, 0x00] // still uncoded
	assert h(mut s, [u8(0x2E), 0x01, 0x10, 0x00, 0x64]) == [u8(0x6E), 0x01, 0x10]
	assert h(mut s, [u8(0x22), 0x01, 0x10]) == [u8(0x62), 0x01, 0x10, 0x00, 0x64]
	assert h(mut s, [u8(0x22), 0x01, 0x11]) == [u8(0x62), 0x01, 0x11, 0x01] // coded
}

fn test_services_outside_the_description_are_refused() {
	sys := dx_load('svc')
	mut s := zone_a(sys)
	assert h(mut s, [u8(0x31), 0x01, 0xFF, 0x00]) == [u8(0x7F), 0x31, 0x11]
	assert h(mut s, [u8(0x28), 0x00, 0x01]) == [u8(0x7F), 0x28, 0x11] // nothing gates the sim's traffic
	assert h(mut s, [u8(0x85), 0x02]) == [u8(0x7F), 0x85, 0x7F] // served, outside default only
	assert h(mut s, [u8(0x11), 0x02]) == [u8(0x7F), 0x11, 0x12]
	// sysnode states its table: 0x19 is not in it (and it has no fault memory), 0x11 needs
	// extended and level 1
	d := describe(&sys, sysview.TargetAddr{ req: 0x7A0, rsp: 0x7A8, bus: 'compute' }, '',
		none, false)
	assert d.ok && d.node == 'sysnode'
	mut n := d.server
	assert h(mut n, [u8(0x19), 0x0A]) == [u8(0x7F), 0x19, 0x11]
	assert h(mut n, [u8(0x11), 0x01]) == [u8(0x7F), 0x11, 0x7F]
	assert h(mut n, [u8(0x10), 0x02]) == [u8(0x7F), 0x10, 0x7E] // the handoff: extended only
	unlock(mut n)
	assert h(mut n, [u8(0x11), 0x01]) == [u8(0x51), 0x01]
	unlock(mut n)
	assert h(mut n, [u8(0x10), 0x02]) == [u8(0x7F), 0x10, 0x22] // no bootloader simulated
}

fn test_the_reference_key_is_refused_where_none_is_named() {
	sys := dx_load('oem')
	d := describe(&sys, sysview.TargetAddr{ req: 0x7B0, rsp: 0x7B8, bus: 'compute' }, '',
		none, false)
	assert d.ok && d.node == 'domain'
	assert d.notes.any(it.contains('refuses the reference key'))
	mut s := d.server
	assert h(mut s, [u8(0x22), 0x02, 0x00]) == [u8(0x7F), 0x22, 0x31] // not readable in default
	assert h(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert h(mut s, [u8(0x22), 0x02, 0x00]) == [u8(0x7F), 0x22, 0x33]
	seed := h(mut s, [u8(0x27), 0x01])
	mut key := [u8(0x27), 0x02]
	key << ref_key(seed)
	assert h(mut s, key) == [u8(0x7F), 0x27, 0x35]
	// the OEM's (oem_key) unlocks it, and the read gate opens
	seed2 := h(mut s, [u8(0x27), 0x01])
	mut okey := [u8(0x27), 0x02]
	okey << uds.oem_key(seed2[2..])
	assert h(mut s, okey) == [u8(0x67), 0x02]
	assert h(mut s, [u8(0x22), 0x02, 0x00]) == [u8(0x62), 0x02, 0x00, 0xAA, 0xBB]
}

fn test_over_doip_the_reference_key_needs_allow_bench_key() {
	sys := dx_load('doip')
	d := describe(&sys, sysview.TargetAddr{ doip: true, logical: 0x07A0 }, '', none, true)
	assert d.ok && d.node == 'sysnode'
	mut s := d.server
	unlock(mut s) // sysnode allows the bench key over the network
	z := sys.nodes.filter(it.name == 'zone_a')[0]
	spec, notes := z.desc.server_spec(true)
	assert !spec.reference_key // zone_a does not
	assert notes.any(it.contains('allow_bench_key'))
}

fn test_over_doip_the_entity_announces_the_described_vin_and_serves_no_reset() {
	sys := dx_load('entity')
	ch := project.Channel{
		name:     'DoIP1'
		typ:      'doip'
		iface:    'doip:127.0.0.1:13400'
		ecu_addr: 0x07A0
	}
	e := doip_entity_described(ch, [], &sys, []) or { panic(err) }
	assert e.described == 'sysnode' && e.node_label() == 'sysnode (described)'
	assert e.announce == 'BLOBLYSYSNODEH735'
	mut s := e.server
	unlock(mut s)
	assert h(mut s, [u8(0x11), 0x01]) == [u8(0x7F), 0x11, 0x11] // a DoIP connection performs no reset
	// a channel VIN where the description has none is served as well as announced
	ch2 := project.Channel{
		...ch
		ecu_addr: 0x0999
		vin:      'CHANNELVIN0000001'
	}
	e2 := doip_entity_described(ch2, [], &sys, []) or { panic(err) }
	mut s2 := e2.server
	assert h(mut s2, [u8(0x22), 0xF1, 0x90])[3..] == 'CHANNELVIN0000001'.bytes()
}

fn test_an_unknown_session_name_closes_the_gate() {
	g := sysview.Gate{
		declared: true
		sessions: ['extended ']
		level:    0
	}
	d := sysview.EcuDesc{
		server: true
		dids:   [
			sysview.DidDesc{
				id:         0x0300
				kind:       .bytes
				size:       1
				data:       [u8(7)]
				write_gate: g
			},
		]
	}
	spec, notes := d.server_spec(false)
	assert notes.any(it.contains('is no session'))
	mut s := uds.server_from(spec)
	for sess in [u8(1), 3] {
		assert h(mut s, [u8(0x10), sess])[0] == 0x50
		assert h(mut s, [u8(0x2E), 0x03, 0x00, 0x01]) == [u8(0x7F), 0x2E, 0x31]
	}
}

fn test_a_bool_parameter_is_read_and_written_as_one() {
	d := sysview.EcuDesc{
		server: true
		params: [sysview.ParamDesc{
			name:     'Flag'
			fields:   [sysview.Field{'on', 'bool'}]
			defaults: {
				'on': i64(1)
			}
		}]
		dids:   [
			sysview.DidDesc{
				id:         0x0400
				kind:       .param
				name:       'Flag'
				size:       1
				fields:     [sysview.Field{'on', 'bool'}]
				write_gate: sysview.Gate{
					declared: true
				}
			},
		]
	}
	spec, _ := d.server_spec(false)
	mut s := uds.server_from(spec)
	assert h(mut s, [u8(0x22), 0x04, 0x00]) == [u8(0x62), 0x04, 0x00, 0x01]
	assert h(mut s, [u8(0x2E), 0x04, 0x00, 0x02]) == [u8(0x7F), 0x2E, 0x31] // a bool is 0 or 1
	assert h(mut s, [u8(0x2E), 0x04, 0x00, 0x00]) == [u8(0x6E), 0x04, 0x00]
}

fn test_the_link_is_addressing_then_name() {
	sys := dx_load('link')
	// addressing wins over the name
	a := describe(&sys, sysview.TargetAddr{ req: 0x7C0, rsp: 0x7C8, bus: 'edge' }, 'whatever',
		none, false)
	assert a.ok && a.node == 'zone_a'
	// no node addressed so: the one of that name
	b := describe(&sys, sysview.TargetAddr{ req: 0x7E0, rsp: 0x7E8, bus: 'edge' }, 'zone_a',
		none, false)
	assert b.ok && b.node == 'zone_a'
	// neither: not described, the project's content stands
	c := describe(&sys, sysview.TargetAddr{ req: 0x7E0, rsp: 0x7E8, bus: 'edge' }, 'SUT', none,
		false)
	assert !c.ok && c.notes.len == 0
}

fn test_the_project_block_overlays_values_and_seeds_faults() {
	sys := dx_load('overlay')
	cfg := project.UdsCfg{
		rx:   0x7C0
		tx:   0x7C8
		dids: [project.DidCfg{
			id:   0xF189
			text: 'bench_copy'
		}, project.DidCfg{
			id:    0x4242
			bytes: [u8(0x01)]
		}]
		dtcs: [project.DtcCfg{
			code:   0xC40100
			status: 0x09
		}]
	}
	d := describe(&sys, sysview.TargetAddr{ req: 0x7C0, rsp: 0x7C8, bus: 'edge' }, 'zone_a',
		cfg, false)
	assert d.ok
	mut s := d.server
	mut want := [u8(0x62), 0xF1, 0x89]
	want << 'bench_copy'.bytes()
	assert h(mut s, [u8(0x22), 0xF1, 0x89]) == want
	assert h(mut s, [u8(0x22), 0x42, 0x42]) == [u8(0x62), 0x42, 0x42, 0x01]
	assert h(mut s, [u8(0x19), 0x02, 0x08]) == [u8(0x59), 0x02, 0x7F, 0xC4, 0x01, 0x00, 0x09]
	assert h(mut s, [u8(0x19), 0x03]) == [u8(0x59), 0x03, 0xC4, 0x01, 0x00, 0x01] // frozen at failure
	assert h(mut s, [u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x54)]
	assert h(mut s, [u8(0x19), 0x02, 0x08]) == [u8(0x59), 0x02, 0x7F]
}

// candb_msg is an 8-byte frame carrying `signal` as a u32 at bit 0, range 0..360 (SteeringFrame's).
fn candb_msg(signal string) candb.Message {
	return candb.Message{
		name:    'F'
		id:      0x132
		dlc:     8
		signals: [candb.Signal{
			name:    signal
			length:  32
			maximum: 360
		}]
	}
}

fn one_signal_engine(node string, signal string, value f64, f Fault) Engine {
	return Engine{
		ecus: [
			SimEcu{
				name:     node
				messages: [
					SimMessage{
						msg:       candb_msg(signal)
						period_ms: 50
						fault:     f
						signals:   [SimSignal{
							name: signal
							gen:  gen_const(value)
						}]
					},
				]
			},
		]
	}
}

fn test_a_live_did_reads_the_simulated_signal() {
	sys := dx_load('live')
	mut s := zone_a(sys)
	clear_live()
	wire_live(mut s, 'inproc:EDGE', 'edge', 'zone_a')
	assert h(mut s, [u8(0x22), 0xF1, 0xA0]) == [u8(0x62), 0xF1, 0xA0, 0, 0, 0, 0] // not sent yet
	mut e := one_signal_engine('zone_a', 'SteeringAngle', 300, Fault{})
	assert e.due_frames(0).len == 1
	publish_live('inproc:EDGE', 'edge', &e)
	assert h(mut s, [u8(0x22), 0xF1, 0xA0]) == [u8(0x62), 0xF1, 0xA0, 0, 0, 0x01, 0x2C]
	clear_live()
}

fn test_a_dropped_frame_publishes_nothing() {
	sys := dx_load('drop')
	mut s := zone_a(sys)
	clear_live()
	wire_live(mut s, 'inproc:EDGE', 'edge', 'zone_a')
	mut e := one_signal_engine('zone_a', 'SteeringAngle', 300, Fault{
		kind: .drop
	})
	assert e.due_frames(0).len == 0 // dropped: nothing reached the bus
	publish_live('inproc:EDGE', 'edge', &e)
	assert h(mut s, [u8(0x22), 0xF1, 0xA0]) == [u8(0x62), 0xF1, 0xA0, 0, 0, 0, 0]
	clear_live()
}

fn test_a_described_doip_entity_reads_its_node_simulated_on_can() {
	sys := dx_load('doiplive')
	ch := project.Channel{
		name:     'DoIP1'
		typ:      'doip'
		iface:    'doip:127.0.0.1:13400'
		ecu_addr: 0x07A0
	}
	// nothing simulates sysnode: said, and it reads zeros
	lone := doip_entity_described(ch, [], &sys, []) or { panic(err) }
	assert lone.notes.any(it.contains('GwUptime') && it.contains('reads zeros'))
	sims := [project.NodeCfg{
		name:    'sysnode'
		signals: [project.GenCfg{
			signal: 'GwUptime'
			value:  7
		}]
	}]
	clear_live()
	e := doip_entity_described(ch, [], &sys, sims) or { panic(err) }
	assert !e.notes.any(it.contains('reads zeros'))
	mut s := e.server
	assert h(mut s, [u8(0x22), 0x01, 0x30]) == [u8(0x62), 0x01, 0x30, 0, 0, 0, 0]
	mut eng := one_signal_engine('sysnode', 'GwUptime', 7, Fault{})
	eng.due_frames(0)
	publish_live('inproc:COMPUTE', 'compute', &eng)
	assert h(mut s, [u8(0x22), 0x01, 0x30]) == [u8(0x62), 0x01, 0x30, 0, 0, 0, 7]
	clear_live()
}

fn test_bytes_that_are_not_hex_are_not_served() {
	doc := toml.parse_text('[uds]\n[isotp]\nrx_id = 0x700\ntx_id = 0x708\n[[did]]\nid = 0x0500\nbytes = "ZZ FF"\n') or {
		panic(err)
	}
	d := sysview.parse_ecu_desc(doc, map[string][]sysview.Field{})
	assert d.errs.any(it.contains('0x0500'))
	spec, notes := d.server_spec(false)
	assert notes.any(it.contains('0x0500') && it.contains('not served'))
	mut s := uds.server_from(spec)
	assert h(mut s, [u8(0x22), 0x05, 0x00]) == [u8(0x7F), 0x22, 0x31]
}

fn test_a_bool_range_narrows_but_never_widens_the_type() {
	d := sysview.EcuDesc{
		server: true
		dids:   [
			sysview.DidDesc{
				id:         0x0400
				kind:       .param
				name:       'Flag'
				size:       1
				fields:     [sysview.Field{'on', 'bool'}]
				ranges:     {
					'on': sysview.Range{0, 5}
				}
				write_gate: sysview.Gate{
					declared: true
				}
			},
		]
	}
	spec, _ := d.server_spec(false)
	mut s := uds.server_from(spec)
	assert h(mut s, [u8(0x2E), 0x04, 0x00, 0x02]) == [u8(0x7F), 0x2E, 0x31]
	assert h(mut s, [u8(0x2E), 0x04, 0x00, 0x01]) == [u8(0x6E), 0x04, 0x00]
}

fn test_an_entity_whose_vin_cannot_be_read_is_refused() {
	mut sys := dx_load('novin')
	// sysnode with a services table that leaves 0x22 out
	for i, n in sys.nodes {
		if n.name == 'sysnode' {
			mut desc := n.desc
			desc.services = desc.services.filter(it.sid != 0x22)
			sys.nodes[i] = sysview.SysNode{
				...n
				desc: desc
			}
		}
	}
	ch := project.Channel{
		name:     'DoIP1'
		typ:      'doip'
		iface:    'doip:127.0.0.1:13400'
		ecu_addr: 0x07A0
		vin:      'BLOBLYSYSNODEH735'
	}
	doip_entity_described(ch, [], &sys, []) or {
		assert err.msg().contains('0xF190') && err.msg().contains('leaves out 0x22')
		return
	}
	assert false, 'an entity announcing a VIN it cannot serve was started'
}

fn test_a_doip_functional_security_access_is_ignored_and_keeps_s3() {
	sys := dx_load('doipfunc')
	ch := project.Channel{
		name:     'DoIP1'
		typ:      'doip'
		iface:    'doip:127.0.0.1:13400'
		ecu_addr: 0x07A0
	}
	e := doip_entity_described(ch, [], &sys, []) or { panic(err) }
	mut host := DoipHost{
		server: e.server
	}
	assert host.handle([u8(0x10), 0x03])[0] == 0x50
	assert host.handle_functional([u8(0x27), 0x01]) == []u8{} // ignored: physical only
	assert host.server.seed_lvl == 0
	assert host.server.rx_seen // but it is a request: S3 saw it
}

// a frame the transport refuses (listen-only, a bus that is down) is not what the ECU sent
fn test_a_refused_send_publishes_nothing() {
	sys := dx_load('refused')
	mut s := zone_a(sys)
	clear_live()
	wire_live(mut s, 'inproc:EDGE', 'edge', 'zone_a')
	mut e := one_signal_engine('zone_a', 'SteeringAngle', 300, Fault{})
	e.step(0, fn (f transport.CanFrame) bool {
		return false
	})
	publish_live('inproc:EDGE', 'edge', &e)
	assert h(mut s, [u8(0x22), 0xF1, 0xA0]) == [u8(0x62), 0xF1, 0xA0, 0, 0, 0, 0]
	e.step(50, fn (f transport.CanFrame) bool {
		return true
	})
	publish_live('inproc:EDGE', 'edge', &e)
	assert h(mut s, [u8(0x22), 0xF1, 0xA0]) == [u8(0x62), 0xF1, 0xA0, 0, 0, 0x01, 0x2C]
	clear_live()
}
