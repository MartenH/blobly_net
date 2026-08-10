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
