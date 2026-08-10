module sim

import project

fn test_uds_nodes_builds_only_configured_ecus() {
	nodes := [
		project.NodeCfg{
			name: 'BCM'
			uds:  project.UdsCfg{
				rx:      0x7E1
				tx:      0x7E9
				session: 3
				dids:    [
					project.DidCfg{ id: 0xF190, text: 'BCM-001' },
					project.DidCfg{ id: 0xF195, bytes: [u8(0x01), 0x00] },
				]
				dtcs: [project.DtcCfg{ code: 0x900101, status: 0x09 }]
			}
		},
		project.NodeCfg{ name: 'Plain' }, // no uds: not a diagnostic target
	]
	built := uds_nodes(nodes)
	assert built.len == 1, 'only configured ECUs get a server'
	assert built[0].name == 'BCM'
	assert built[0].rx == 0x7E1 && built[0].tx == 0x7E9
	assert built[0].server.session == 3
	assert built[0].server.dids[0xF190] == 'BCM-001'.bytes()
	assert built[0].server.dids[0xF195] == [u8(0x01), 0x00]
	assert built[0].server.dtcs.len == 1 && built[0].server.dtcs[0].code == 0x900101

	// and it actually answers as that ECU
	mut srv := built[0].server
	resp := srv.handle([u8(0x22), 0xF1, 0x90])
	assert resp[0] == 0x62
	assert resp[3..] == 'BCM-001'.bytes(), 'the ECU must serve ITS OWN data'
}

fn test_validate_uds_catches_unusable_addresses() {
	same := [project.NodeCfg{
		name: 'A'
		uds:  project.UdsCfg{ rx: 0x7E0, tx: 0x7E0 }
	}]
	w := validate_uds(same)
	assert w.len == 1 && w[0].contains('both 0x7E0')

	clash := [
		project.NodeCfg{ name: 'A', uds: project.UdsCfg{ rx: 0x7E1, tx: 0x7E9 } },
		project.NodeCfg{ name: 'B', uds: project.UdsCfg{ rx: 0x7E1, tx: 0x7EA } },
	]
	c := validate_uds(clash)
	assert c.len == 1, '${c}'
	assert c[0].contains('already answered by "A"')

	missing := [project.NodeCfg{
		name: 'A'
		uds:  project.UdsCfg{ tx: 0x7E9 }
	}]
	assert validate_uds(missing)[0].contains('must both be set')

	assert validate_uds([project.NodeCfg{ name: 'None' }]).len == 0
}

// Unusable configurations must not be STARTED, only warned about: a broken entry that still
// made the list non-empty suppressed the working channel default, and duplicate listeners both
// answered.
fn test_uds_nodes_skips_unusable_configurations() {
	nodes := [
		project.NodeCfg{ name: 'NoTx', uds: project.UdsCfg{ rx: 0x7E1 } },
		project.NodeCfg{ name: 'Same', uds: project.UdsCfg{ rx: 0x7E2, tx: 0x7E2 } },
		project.NodeCfg{ name: 'A', uds: project.UdsCfg{ rx: 0x7E3, tx: 0x7EB } },
		project.NodeCfg{ name: 'Dup', uds: project.UdsCfg{ rx: 0x7E3, tx: 0x7EC } },
	]
	built := uds_nodes(nodes)
	assert built.len == 1, 'only the usable one starts, got ${built.map(it.name)}'
	assert built[0].name == 'A'
	// and every rejection is explained
	w := validate_uds(nodes)
	assert w.len == 3, '${w}'
}

// 29-bit addressing is inferred: opened as standard, SocketCAN masks 0x18DAF110 to 0x110.
fn test_uds_nodes_infer_extended_addressing() {
	ext := uds_nodes([project.NodeCfg{
		name: 'Gw'
		uds:  project.UdsCfg{ rx: 0x18DA10F1, tx: 0x18DAF110 }
	}])
	assert ext.len == 1 && ext[0].ext, '29-bit ids must open an extended channel'

	std := uds_nodes([project.NodeCfg{
		name: 'Std'
		uds:  project.UdsCfg{ rx: 0x7E0, tx: 0x7E8 }
	}])
	assert std.len == 1 && !std[0].ext

	mixed := validate_uds([project.NodeCfg{
		name: 'Mix'
		uds:  project.UdsCfg{ rx: 0x18DA10F1, tx: 0x7E8 }
	}])
	assert mixed.any(it.contains('mix 11-bit and 29-bit'))
}

// A DID above the 16-bit range must be reported and dropped, never narrowed — 0x1F190 would
// otherwise become 0xF190 and masquerade as the VIN.
fn test_out_of_range_did_is_dropped_not_truncated() {
	cfg := project.NodeCfg{
		name: 'X'
		uds:  project.UdsCfg{
			rx:   0x7E0
			tx:   0x7E8
			dids: [
				project.DidCfg{ id: 0xF190, text: 'real' },
				project.DidCfg{ id: 0x1F190, text: 'forged' },
			]
		}
	}
	built := uds_nodes([cfg])
	assert built[0].server.dids[0xF190] == 'real'.bytes(), 'the wide DID must not overwrite'
	assert built[0].server.dids.len == 1
	assert validate_uds([cfg]).any(it.contains('above the 16-bit range'))
}

// A's response id used as B's request id: B's channel receives every reply A sends, treats the
// positive-response SID as an unknown service, and answers it with a negative response.
fn test_cross_addressed_servers_are_rejected() {
	nodes := [
		project.NodeCfg{ name: 'A', uds: project.UdsCfg{ rx: 0x7E1, tx: 0x7E9 } },
		project.NodeCfg{ name: 'B', uds: project.UdsCfg{ rx: 0x7E9, tx: 0x7EA } },
	]
	w := validate_uds(nodes)
	assert w.any(it.contains("is \"A\"'s response id")), '${w}'
	built := uds_nodes(nodes)
	assert built.len == 1 && built[0].name == 'A', 'only A may start, got ${built.map(it.name)}'
}

// A pair mixing 11-bit and 29-bit cannot be opened: ISO-TP uses one format for both, so the
// 11-bit side would go out extended and never reach its peer.
fn test_mixed_format_pair_does_not_start() {
	nodes := [project.NodeCfg{
		name: 'Mix'
		uds:  project.UdsCfg{ rx: 0x18DA10F1, tx: 0x7E8 }
	}]
	assert uds_nodes(nodes).len == 0, 'a mixed pair must not start'
	assert validate_uds(nodes).any(it.contains('mix 11-bit and 29-bit'))
}

// A DTC is three bytes on the wire, so 0x1123456 would be reported as 0x123456 — a different
// and possibly real fault code.
fn test_out_of_range_dtc_is_dropped() {
	cfg := project.NodeCfg{
		name: 'X'
		uds:  project.UdsCfg{
			rx:   0x7E0
			tx:   0x7E8
			dtcs: [
				project.DtcCfg{ code: 0x123456, status: 9 },
				project.DtcCfg{ code: 0x1123456, status: 9 },
			]
		}
	}
	built := uds_nodes([cfg])
	assert built[0].server.dtcs.len == 1, 'the wide DTC must be dropped'
	assert built[0].server.dtcs[0].code == 0x123456
	assert validate_uds([cfg]).any(it.contains('above the 24-bit range'))
}

// A rejected configuration must not reserve ids. Reserving from an entry that is itself thrown
// away poisoned the id for a valid node, which was skipped too — and the channel default
// started instead of the ECU the project asked for.
fn test_rejected_configs_do_not_reserve_ids() {
	nodes := [
		project.NodeCfg{ name: 'Broken', uds: project.UdsCfg{ rx: 0, tx: 0x7E1 } },
		project.NodeCfg{ name: 'Good', uds: project.UdsCfg{ rx: 0x7E1, tx: 0x7E9 } },
	]
	built := uds_nodes(nodes)
	assert built.len == 1 && built[0].name == 'Good', 'got ${built.map(it.name)}'
}

// Two ECUs answering on ONE response id: a tester holding both handles receives every reply on
// both, so one ECU's response can be consumed as the other's result.
fn test_duplicate_response_ids_are_rejected() {
	nodes := [
		project.NodeCfg{ name: 'A', uds: project.UdsCfg{ rx: 0x7E1, tx: 0x7E9 } },
		project.NodeCfg{ name: 'B', uds: project.UdsCfg{ rx: 0x7E2, tx: 0x7E9 } },
	]
	assert validate_uds(nodes).any(it.contains('also used by "A"'))
	assert uds_nodes(nodes).len == 1, 'only one may own a response id'
}

// Above 29 bits SocketCAN masks on send while the software channel matches unmasked, so the
// ECU would transmit on a different valid id and never hear its tester.
fn test_ids_beyond_29_bits_are_rejected() {
	nodes := [project.NodeCfg{
		name: 'Huge'
		uds:  project.UdsCfg{ rx: 0x2FFFFFFF, tx: 0x3FFFFFFF }
	}]
	assert uds_nodes(nodes).len == 0
	assert validate_uds(nodes).any(it.contains('exceeds the 29-bit'))
}

// A DID value past one ISO-TP transfer cannot be sent, and the send error is discarded — the
// tester just times out, with the project reporting nothing wrong.
fn test_oversized_did_and_bad_dtc_status_are_rejected() {
	cfg := project.NodeCfg{
		name: 'X'
		uds:  project.UdsCfg{
			rx:   0x7E0
			tx:   0x7E8
			dids: [
				project.DidCfg{ id: 0xF190, text: 'ok' },
				project.DidCfg{ id: 0xF191, bytes: []u8{len: max_did_bytes + 1} },
			]
			dtcs: [
				project.DtcCfg{ code: 0x123456, status: 9 },
				project.DtcCfg{ code: 0x123457, status: 265 }, // would wrap to 9
			]
		}
	}
	built := uds_nodes([cfg])
	assert built[0].server.dids.len == 1, 'the oversized DID must not be installed'
	assert built[0].server.dtcs.len == 1, 'a non-byte status must not wrap into a valid one'
	w := validate_uds([cfg])
	assert w.any(it.contains('over the 4092-byte'))
	assert w.any(it.contains('status 265 is not a byte'))
}

// An address wider than 32 bits used to WRAP during parsing, so 0x1000007E0 arrived as a
// perfectly ordinary 0x7E0 and the range check never saw a problem.
fn test_over_wide_address_is_not_wrapped_into_a_valid_one() {
	y := 'project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    simulation:
      - name: Bad
        uds: { rx: "0x1000007E0", tx: "0x1000007E8" }
'
	pr := project.parse(y) or { panic(err) }
	nodes := pr.channels[0].nodes
	cfg := nodes[0].uds or { panic('not parsed') }
	assert cfg.rx > 0x1FFFFFFF, 'the value must survive parsing, got 0x${cfg.rx:X}'
	assert uds_nodes(nodes).len == 0, 'it must not start on a wrapped address'
	assert validate_uds(nodes).any(it.contains('exceeds the 29-bit'))
}

// 0x19 sub 0x02 carries 3 header bytes + 4 per fault against ISO-TP's 4095, so a long table
// cannot be transmitted at all — and the send error is discarded.
fn test_oversized_dtc_table_is_capped_and_reported() {
	mut many := []project.DtcCfg{}
	for i in 0 .. max_dtcs + 5 {
		many << project.DtcCfg{ code: u32(0x100000 + i), status: 9 }
	}
	cfg := project.NodeCfg{
		name: 'X'
		uds:  project.UdsCfg{ rx: 0x7E0, tx: 0x7E8, dtcs: many }
	}
	built := uds_nodes([cfg])
	assert built[0].server.dtcs.len == max_dtcs, 'got ${built[0].server.dtcs.len}'
	assert validate_uds([cfg]).any(it.contains('exceed what one 0x19 response can carry'))
}
