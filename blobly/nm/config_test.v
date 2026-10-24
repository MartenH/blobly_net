module nm

import os
import blobly.candb
import blobly.project
import blobly.sysview

fn system_with_nm() sysview.System {
	return sysview.System{
		buses: [
			sysview.SysBus{
				name:          'body'
				nm_lo:         0x500
				nm_hi:         0x53F
				nm_timeout_ms: 250
				nm_repeat_ms:  200
			},
			sysview.SysBus{
				name: 'chassis'
			},
		]
		nodes: [
			sysview.SysNode{
				name:  'sysnode'
				buses: ['body']
				nm:    0x11
			},
			sysview.SysNode{
				name:  'domain'
				buses: ['body', 'chassis']
				nm:    0x13
			},
			sysview.SysNode{
				name:  'quiet' // on the bus, no NM offset: not a member
				buses: ['body']
			},
			sysview.SysNode{
				name:  'elsewhere'
				buses: ['chassis']
				nm:    0x20
			},
		]
	}
}

fn row(name string) project.Channel {
	return project.Channel{
		name: name
	}
}

fn arxml_db() candb.Database {
	return candb.Database{
		arxml: candb.ArxmlBus{
			name: 'Body'
			nm:   [candb.ArxmlNmFrame{
				id:  0x601
				ecu: 'ECU_A'
			}, candb.ArxmlNmFrame{
				id: 0x60F
			}]
		}
	}
}

fn own_row(name string) project.Channel {
	return project.Channel{
		name: name
		nm:   project.NmCfg{
			lo:         0x700
			hi:         0x70F
			timeout_ms: 500
		}
	}
}

fn test_the_system_model_names_the_cluster_of_the_bus_a_row_is_named_after() {
	sys := system_with_nm()
	c := configure(&sys, [row('body')], []) or { panic('no configuration') }
	assert c.source == .system
	assert c.lo == 0x500 && c.hi == 0x53F && !c.ext
	assert c.timeout_ms == 250 && !c.timeout_default
	assert c.origin == 'system.toml bus body'
	assert c.declared.map(it.name) == ['sysnode', 'domain']
	assert c.declared[0].nid == 0x11 && c.declared[0].id == 0x511
	// a bus without an NM range configures nothing from the model
	if _ := configure(&sys, [row('chassis')], []) {
		assert false, 'chassis states no NM cluster'
	}
	// an alias row on the wire named after the bus is enough
	alias := configure(&sys, [row('CAN1'), row('body')], []) or { panic('') }
	assert alias.source == .system
}

fn test_a_system_bus_without_a_timeout_takes_the_default() {
	mut sys := system_with_nm()
	sys.buses[0].nm_timeout_ms = 0
	c := configure(&sys, [row('body')], []) or { panic('') }
	assert c.timeout_ms == default_timeout_ms && c.timeout_default
}

fn test_else_the_arxml_nm_frames() {
	sys := sysview.System{}
	c := configure(&sys, [row('body')], [candb.Database{}, arxml_db()]) or { panic('') }
	assert c.source == .arxml
	assert c.lo == 0x601 && c.hi == 0x60F
	assert c.origin == 'ARXML cluster Body'
	assert c.timeout_ms == arxml_timeout_ms && c.timeout_default, 'the description states no CanNm timeout'
	assert c.covers(0x601, false) && c.covers(0x60F, false)
	assert !c.covers(0x605, false), 'an id between two NM frames is not NM'
	assert c.describe() == 'NM frames 0x601, 0x60F'
	assert c.declared.len == 1, 'a frame with no sender names nobody'
	assert c.declared[0].name == 'ECU_A' && c.declared[0].id == 0x601 && c.declared[0].nid == -1
}

fn test_else_the_rows_own_setting() {
	sys := sysview.System{}
	c := configure(&sys, [row('A'), own_row('B')], [candb.Database{}]) or { panic('') }
	assert c.source == .project
	assert c.lo == 0x700 && c.hi == 0x70F && c.timeout_ms == 500
	assert c.declared.len == 0
	assert c.origin == 'channel B'
}

fn test_the_order_is_system_then_arxml_then_project() {
	sys := system_with_nm()
	a := configure(&sys, [own_row('body')], [arxml_db()]) or { panic('') }
	assert a.source == .system
	empty := sysview.System{}
	b := configure(&empty, [own_row('body')], [arxml_db()]) or { panic('') }
	assert b.source == .arxml
}

fn test_with_none_there_is_no_reading() {
	sys := sysview.System{}
	if c := configure(&sys, [row('CAN1')], [candb.Database{}]) {
		assert false, 'nothing guesses a frame is NM: ${c.origin}'
	}
}

fn test_an_extended_range_reads_29_bit_frames() {
	sys := sysview.System{}
	c := configure(&sys, [
		project.Channel{
			name: 'X'
			nm:   project.NmCfg{
				lo: 0x18FF0000
				hi: 0x18FF00FF
			}
		},
	], []) or { panic('') }
	assert c.ext
	assert c.covers(0x18FF0011, true)
	assert !c.covers(0x18FF0011, false)
	// a 29-bit cluster on low ids says so
	low := configure(&sys, [
		project.Channel{
			name: 'X'
			nm:   project.NmCfg{
				lo:  0x500
				hi:  0x53F
				ext: true
			}
		},
	], []) or { panic('') }
	assert low.covers(0x511, true) && !low.covers(0x511, false)
}

fn test_a_system_toml_the_way_blobly_emb_writes_it() {
	dir := os.join_path(os.temp_dir(), 'nm_cfg_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'system.toml')
	os.write_file(path, '[bus.can0]
interface = "can0"
bitrate   = 500000
nm        = { peers = [0x500, 0x53F], timeout_ms = 300, repeat_ms = 200 }

[[node]]
name  = "sysnode"
buses = ["can0"]
nm    = 0x11

[[node]]
name  = "domain"
buses = ["can0"]
nm    = 0x13
') or {
		panic(err)
	}
	sys := sysview.load(path) or { panic(err) }
	assert sys.buses[0].nm_timeout_ms == 300
	assert sys.buses[0].nm_repeat_ms == 200
	c := configure(&sys, [row('can0')], []) or { panic('') }
	assert c.declared.map('${it.name}@0x${it.id:X}') == ['sysnode@0x511', 'domain@0x513']
	mut t := new_tracker(c)
	t.note(0x513, false, [u8(0x13), 0], 0)
	assert t.name_of(0) == 'domain'
}

fn test_arxml_frames_of_both_kinds_at_their_pdu_byte_read_once() {
	db := candb.Database{
		arxml: candb.ArxmlBus{
			name: 'Body'
			nm:   [candb.ArxmlNmFrame{
				id:  0x511
				ecu: 'A'
			}, candb.ArxmlNmFrame{
				id:   0x1511
				ext:  true
				ecu:  'B'
				byte: 2
			}]
		}
	}
	sys := sysview.System{}
	// the same file through two rows of one wire
	c := configure(&sys, [row('body')], [db, db]) or { panic('') }
	assert c.declared.map(it.name) == ['A', 'B'], 'read once'
	assert c.covers(0x511, false) && c.covers(0x1511, true)
	assert !c.covers(0x1511, false) && !c.covers(0x511, true)
	assert c.describe() == 'NM frames 0x511, 0x1511 (29-bit) at byte 2'
	mut t := new_tracker(c)
	t.note(0x511, false, [u8(0x05), 0x00], 0)
	t.note(0x1511, true, [u8(0), 0, 0x07, 0x08], 0) // the PDU starts at byte 2
	assert t.nodes.len == 2
	assert t.name_of(0) == 'A' && t.name_of(1) == 'B'
	assert t.nodes[1].nid == 0x07 && t.nodes[1].ready_to_sleep()
	assert t.missing().len == 0
	// a frame too short to reach its PDU is malformed
	t.note(0x1511, true, [u8(0), 0], 10)
	assert t.malformed == 1
}
