// Tests for the DoIP UDS builder and validator. The CAN pair is covered by uds_nodes_test.v;
// these pin the ways the two are DELIBERATELY different (no CAN identifiers) and the ways they
// must stay the SAME (what an ECU serves does not depend on how it is reached).
module sim

import project

fn doip_node(name string, cfg project.UdsCfg) project.NodeCfg {
	return project.NodeCfg{
		name: name
		uds:  cfg
	}
}

fn test_doip_node_needs_no_can_ids() {
	// The whole point: a node with no rx/tx is VALID on DoIP. uds_nodes() rejects this exact
	// config, which is why a DoIP ECU could not be given its own identity at all.
	nodes := [
		doip_node('SUT', project.UdsCfg{
			dids: [project.DidCfg{
				id:   0xF190
				text: 'BLOBLYNETV0SUT001'
			}]
		}),
	]
	built := uds_nodes_doip(nodes)
	assert built.len == 1
	assert built[0].name == 'SUT'
	assert built[0].server.dids[u16(0xF190)].bytestr() == 'BLOBLYNETV0SUT001'
	// and the CAN builder still refuses it, so the two have not been quietly merged
	assert uds_nodes(nodes).len == 0
}

fn test_doip_serves_the_same_content_as_can() {
	cfg := project.UdsCfg{
		rx:   0x7E0
		tx:   0x7E8
		dids: [project.DidCfg{
			id:   0xF18C
			text: 'SN-0001'
		}]
		dtcs: [project.DtcCfg{
			code:   0x123456
			status: 9
		}]
	}
	can := uds_nodes([doip_node('E', cfg)])
	doip := uds_nodes_doip([doip_node('E', cfg)])
	assert can.len == 1 && doip.len == 1
	// identical tables: build_server is shared, and a divergence here means it was forked
	assert can[0].server.dids == doip[0].server.dids
	assert can[0].server.dtcs == doip[0].server.dtcs
}

fn test_doip_reports_can_ids_as_ignored() {
	// Not an error — the node still works — but a block copied from a CAN ECU looks like it
	// addresses something, and it does not.
	warns := validate_uds_doip([
		doip_node('E', project.UdsCfg{
			rx: 0x7E0
			tx: 0x7E8
		}),
	])
	assert warns.len == 1
	assert warns[0].contains('ignored on a DoIP channel')
}

fn test_doip_node_without_ids_is_not_warned_about() {
	warns := validate_uds_doip([
		doip_node('E', project.UdsCfg{
			dids: [project.DidCfg{
				id:   0xF190
				text: 'X'
			}]
		}),
	])
	assert warns.len == 0
}

fn test_doip_rejects_malformed_and_reports_it() {
	nodes := [
		doip_node('E', project.UdsCfg{
			malformed: ['did 0xZZ']
			dids:      [project.DidCfg{
				id:   0xF190
				text: 'X'
			}]
		}),
	]
	assert uds_nodes_doip(nodes).len == 0 // not served
	warns := validate_uds_doip(nodes)
	assert warns.len > 0 // and not in silence
	assert warns.any(it.contains('not a valid identifier'))
}

// The limits are the CARRIER's, not ISO-TP's. A DID too large for one CAN transfer fits a
// DoIP diagnostic message perfectly well, and dropping it there answered NRC 0x31 for data the
// transport could have carried.
fn test_doip_carries_what_iso_tp_cannot() {
	over_can := 'x'.repeat(max_did_bytes + 1)
	nodes := [
		doip_node('E', project.UdsCfg{
			dids: [project.DidCfg{
				id:   0xF190
				text: over_can
			}]
		}),
	]
	assert uds_nodes_doip(nodes)[0].server.dids[u16(0xF190)].len == max_did_bytes + 1
	assert validate_uds_doip(nodes).len == 0 // and no warning about a limit that does not apply
	// the CAN builder still drops it, and still says so
	cfg := project.UdsCfg{
		rx:   0x7E0
		tx:   0x7E8
		dids: [project.DidCfg{
			id:   0xF190
			text: over_can
		}]
	}
	assert uds_nodes([doip_node('E', cfg)])[0].server.dids.len == 0
	assert validate_uds([doip_node('E', cfg)]).any(it.contains('ISO-TP'))
}

fn test_doip_content_limits_are_enforced() {
	big := 'x'.repeat(max_did_bytes_doip + 1)
	nodes := [
		doip_node('E', project.UdsCfg{
			dids: [
				project.DidCfg{
					id:   0xF190
					text: big
				},
				project.DidCfg{
					id:   0x1F190 // above the 16-bit range
					text: 'y'
				},
			]
		}),
	]
	built := uds_nodes_doip(nodes)
	assert built.len == 1
	assert built[0].server.dids.len == 0 // both dropped
	warns := validate_uds_doip(nodes)
	assert warns.any(it.contains('DoIP payload'))
	assert warns.any(it.contains('above the 16-bit range'))
}

fn test_doip_duplicate_did_keeps_the_first() {
	nodes := [
		doip_node('E', project.UdsCfg{
			dids: [
				project.DidCfg{
					id:   0xF190
					text: 'FIRST'
				},
				project.DidCfg{
					id:   0xF190
					text: 'SECOND'
				},
			]
		}),
	]
	built := uds_nodes_doip(nodes)
	// FIRST wins, so the served value cannot depend on YAML order
	assert built[0].server.dids[u16(0xF190)].bytestr() == 'FIRST'
	assert validate_uds_doip(nodes).any(it.contains('defined more than once'))
}

fn test_doip_node_without_uds_is_skipped() {
	nodes := [project.NodeCfg{
		name: 'signals-only'
	}]
	assert uds_nodes_doip(nodes).len == 0
	assert validate_uds_doip(nodes).len == 0
}
