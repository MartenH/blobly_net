module sim

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
