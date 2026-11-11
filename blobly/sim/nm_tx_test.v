module sim

import blobly.candb
import blobly.nm
import blobly.project
import blobly.transport

fn nm_engine() Engine {
	mut e := Engine{
		ecus: [SimEcu{
			name: 'Body'
		}, SimEcu{
			name: 'Gw'
		}]
	}
	e.attach_announcements([nm.Announce{
		node:     'Body'
		id:       0x511
		nid:      0x11
		cycle_ms: 200
	}])
	return e
}

fn nm_frames_at(mut e Engine, now_ms f64) []transport.CanFrame {
	return e.due_frames(now_ms)
}

fn test_an_announcing_node_sends_its_pdu_on_the_cycle() {
	mut e := nm_engine()
	assert e.ecus[1].nm_tx.len == 0
	first := nm_frames_at(mut e, 0)
	assert first.len == 1
	assert first[0].id == 0x511 && !first[0].extended
	assert first[0].data == [u8(0x11), 0, 0, 0, 0, 0, 0, 0]
	assert nm_frames_at(mut e, 100).len == 0
	assert nm_frames_at(mut e, 200).len == 1
	// a pass that comes late sends once and keeps the grid
	assert nm_frames_at(mut e, 650).len == 1
	assert nm_frames_at(mut e, 800).len == 0
	assert nm_frames_at(mut e, 850).len == 1
}

fn test_a_released_node_falls_silent_and_announces_at_once_on_a_request() {
	clear_nm_requests()
	defer {
		clear_nm_requests()
	}
	mut e := nm_engine()
	assert nm_frames_at(mut e, 0).len == 1
	nm_set_request('inproc:NMTX', 'Body', false)
	assert !nm_requested('inproc:NMTX', 'Body')
	assert nm_requested('inproc:OTHER', 'Body') // keyed by the bus
	apply_nm_requests('inproc:NMTX', mut e)
	for t in [200.0, 400, 600] {
		assert nm_frames_at(mut e, t).len == 0
	}
	nm_set_request('inproc:NMTX', 'Body', true)
	apply_nm_requests('inproc:NMTX', mut e)
	assert nm_frames_at(mut e, 650).len == 1 // at once, not at the next grid slot
	assert nm_frames_at(mut e, 750).len == 0
	assert nm_frames_at(mut e, 850).len == 1
}

fn test_a_script_releases_the_row_announcing_nodes_and_is_refused_where_none_does() {
	clear_nm_requests()
	defer {
		clear_nm_requests()
	}
	cfg := nm.Config{
		lo:       0x500
		hi:       0x53F
		cycle_ms: 100
	}
	nodes := [project.NodeCfg{
		name: 'Body'
		nm:   project.NodeNm{
			id:  0x511
			nid: 0x11
		}
	}, project.NodeCfg{
		name: 'Plain'
	}]
	t := FaultTarget{
		channel: 'CAN1'
		iface:   'inproc:NMREQ'
		nodes:   nodes
		nm:      cfg
	}
	assert t.nm_request(false)! == 1
	assert !nm_requested('inproc:NMREQ', 'Body')
	assert nm_requested('inproc:NMREQ', 'Plain')
	assert t.nm_request(true)! == 1
	assert nm_requested('inproc:NMREQ', 'Body')
	quiet := FaultTarget{
		channel: 'CAN1'
		iface:   'inproc:NMREQ'
		nodes:   nodes
	}
	if _ := quiet.nm_request(false) {
		assert false, 'a release that changes nothing is refused'
	} else {
		assert err.msg().contains('announces NM'), err.msg()
	}
	doip := FaultTarget{
		channel: 'DoIP1'
		not_can: 'DoIP'
	}
	if _ := doip.nm_request(false) {
		assert false
	} else {
		assert err.msg().contains('DoIP'), err.msg()
	}
}

fn test_the_dbc_message_on_the_announced_id_is_not_sent_beside_the_announcement() {
	clear_nm_requests()
	defer {
		clear_nm_requests()
	}
	mut e := Engine{
		ecus: [SimEcu{
			name:     'Body'
			messages: [SimMessage{
				msg:       candb.Message{
					name: 'NM_Body'
					id:   0x511
					dlc:  8
				}
				period_ms: 100
			}, SimMessage{
				msg:       candb.Message{
					name: 'Status'
					id:   0x300
					dlc:  8
				}
				period_ms: 100
			}]
		}]
	}
	e.attach_announcements([nm.Announce{
		node:     'Body'
		id:       0x511
		nid:      0x11
		cycle_ms: 200
	}])
	first := nm_frames_at(mut e, 0)
	assert first.map(it.id) == [u32(0x300), 0x511]
	assert first[1].data[0] == 0x11
	assert nm_frames_at(mut e, 100).map(it.id) == [u32(0x300)]
	// released, the id falls silent: the database's message does not keep it awake
	nm_set_request('inproc:NMTX', 'Body', false)
	apply_nm_requests('inproc:NMTX', mut e)
	for t in [200.0, 300, 400] {
		assert nm_frames_at(mut e, t).map(it.id) == [u32(0x300)]
	}
}

// a drop armed on the database message of the announced frame holds the announcement back, on
// its cycle, and the announcement resumes once the drop is lifted
fn test_a_drop_on_the_announced_message_drops_the_announcement() {
	mut e := Engine{
		ecus: [SimEcu{
			name:     'Body'
			messages: [SimMessage{
				msg:       candb.Message{
					name: 'NM_Body'
					id:   0x511
					dlc:  8
				}
				period_ms: 100
			}]
		}]
	}
	e.attach_announcements([nm.Announce{
		node:     'Body'
		id:       0x511
		nid:      0x11
		cycle_ms: 200
	}])
	assert nm_frames_at(mut e, 0).len == 1
	e.ecus[0].messages[0].fault = Fault{
		kind: .drop
	}
	assert nm_frames_at(mut e, 200).len == 0
	assert nm_frames_at(mut e, 400).len == 0
	e.ecus[0].messages[0].fault = Fault{}
	assert nm_frames_at(mut e, 500).len == 0 // the cycle kept through the drop
	assert nm_frames_at(mut e, 600).len == 1
}

// on the announced frame only a drop reaches the wire, so every other kind is refused there
fn test_a_fault_other_than_drop_on_the_announced_message_is_refused() {
	clear_all()
	defer {
		clear_all()
	}
	nm_msg := candb.Message{
		name:    'NM_Body'
		id:      0x511
		dlc:     8
		sender:  'Body'
		signals: [
			candb.Signal{
				name:       'Level'
				start_bit:  8
				length:     8
				byte_order: .little_endian
				factor:     1
				maximum:    100
			},
		]
	}
	t := FaultTarget{
		channel: 'CAN1'
		iface:   'inproc:NMFAULT'
		db:      candb.Database{
			nodes:    ['Body']
			messages: [nm_msg]
		}
		nodes:   [project.NodeCfg{
			name: 'Body'
			nm:   project.NodeNm{
				id:  0x511
				nid: 0x11
			}
		}]
		nm:      nm.Config{
			lo:       0x500
			hi:       0x53F
			cycle_ms: 100
		}
	}
	t.arm('Body', 'NM_Body', 'out_of_range', 0, '') or {
		assert err.msg() == '"NM_Body" is the frame "Body" announces NM on, sent as its NM PDU — only drop applies to it'
		t.arm('Body', 'NM_Body', 'drop', 0, '') or { panic(err) }
		assert injected_fault('inproc:NMFAULT', 'Body', 'NM_Body').kind == .drop
		return
	}
	assert false, 'out_of_range on the announced frame was armed'
}

// what the Simulation panel offers on the announced frame is drop alone, the rule arm refuses by;
// the same message on a frame nobody announces on offers what its protection allows
fn test_the_fault_offer_on_the_announced_frame_is_drop_alone() {
	msg := candb.Message{
		name:    'NM_Body'
		id:      0x511
		dlc:     8
		sender:  'Body'
		signals: [
			candb.Signal{
				name:       'Ctr'
				start_bit:  0
				length:     4
				byte_order: .little_endian
				factor:     1
				maximum:    14
			},
			candb.Signal{
				name:       'Crc'
				start_bit:  8
				length:     8
				byte_order: .little_endian
				factor:     1
				maximum:    255
			},
			candb.Signal{
				name:       'Level'
				start_bit:  16
				length:     8
				byte_order: .little_endian
				factor:     1
				maximum:    100
			},
		]
	}
	node := project.NodeCfg{
		name:    'Body'
		protect: [project.ProtectCfg{
			message: 'NM_Body'
			counter: 'Ctr'
			crc:     'Crc'
			profile: 'sum8'
		}]
	}
	ann := nm.Announce{
		node:     'Body'
		id:       0x511
		nid:      0x11
		cycle_ms: 100
	}
	prot := protection_for(node, msg) or { panic('no protection') }
	open := fault_offer(node, msg, prot, [])
	assert open.kinds == [FaultKind.none_, .drop, .bad_crc, .freeze_ctr, .out_of_range]
	assert open.oor_signal == 'Level'
	announced := fault_offer(node, msg, prot, [ann])
	assert announced.kinds == [FaultKind.none_, .drop]
	assert announced.oor_signal == ''
	assert fault_offer(node, msg, prot, [nm.Announce{ ...ann, node: 'Gw' }]).kinds == open.kinds
	assert fault_offer(node, msg, prot, [nm.Announce{ ...ann, ext: true }]).kinds == open.kinds
}
