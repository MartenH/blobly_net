module transport

fn test_an_address_kind_is_its_scheme() {
	assert iface_kind('vcan0') == 'vcan'
	assert iface_kind('can0') == 'socketcan'
	assert iface_kind('pcan:PCAN_USBBUS1@500000') == 'pcan'
	assert iface_kind('kvaser:0') == 'kvaser'
	assert iface_kind('vector:1@500000/2000000') == 'vector'
	assert iface_kind('CANSUB:e5a16adf/1') == 'cansub'
	assert iface_kind('bridge:Ubuntu-24.04/vcan0') == 'bridge'
	assert iface_kind('udp:239.63.42.1:20000') == 'udp'
	assert iface_kind('inproc:SIM') == 'inproc'
	assert iface_kind('inproc') == 'inproc'
	// as the dispatcher reads them: only cansub: in any case
	assert iface_kind('PCAN:PCAN_USBBUS1') == 'socketcan'
	assert iface_kind('udpx') == 'socketcan'
	assert iface_kind('pcan') == 'socketcan', 'a bare vendor name is a SocketCAN interface'
	assert iface_kind('udp') == 'udp'
}

fn test_a_listed_iface_is_described() {
	pcan := describe(Iface{
		name:  'PCAN_USBBUS1'
		iface: 'pcan:PCAN_USBBUS1'
		kind:  'can'
	})
	assert pcan.kind == 'pcan' && pcan.desc == 'PCAN_USBBUS1' && pcan.fd == .unknown
	can0 := describe(Iface{
		name:    'can0'
		iface:   'can0'
		kind:    'can'
		bitrate: 500000
	})
	assert can0.kind == 'socketcan' && can0.desc == 'CAN · 500000' && can0.bitrate == 500000
	vec := describe(Iface{
		name:  'Vector application channel 2 — assigned, hardware not present'
		iface: 'vector:2'
		kind:  'can'
		fd:    .yes
		state: 'hardware not present'
	})
	assert vec.kind == 'vector' && vec.fd == .yes && vec.state == 'hardware not present'
	br := describe(Iface{
		name:  'vcan0 (Ubuntu)'
		iface: 'bridge:Ubuntu/vcan0'
		kind:  'bridge'
	})
	assert br.desc == 'through canbridge on Ubuntu'
	// a software bus carries FD frames
	for v in virtual_ifaces() {
		d := describe(v)
		assert d.virtual && d.fd == .yes
	}
}

fn test_a_socketcan_link_says_fd_by_its_mtu() {
	assert fd_of_mtu(72) == .yes
	assert fd_of_mtu(16) == .no
	assert fd_of_mtu(0) == .unknown
}

fn test_the_listing_has_the_software_buses_once_each() {
	rows := interfaces()
	for v in virtual_ifaces() {
		assert rows.filter(it.address == v.iface).len == 1
	}
	mut seen := map[string]bool{}
	for r in rows {
		assert r.address !in seen, 'one row per address: ${r.address}'
		seen[r.address] = true
		assert r.kind != '' && r.desc != ''
	}
}

fn test_a_cansub_browse_window_is_bounded() {
	for w in [0, -1, cansub_window_max_ms + 1] {
		discover_cansub_within(w) or {
			assert err.msg().contains('1 to ${cansub_window_max_ms} ms')
			continue
		}
		assert false, 'window ${w} browsed'
	}
}

fn test_the_kernel_kind_of_a_link_wins_the_merge() {
	sys := [Interface{
		address: 'bench0'
		kind:    'socketcan'
		desc:    'CAN'
	}, Interface{
		address: 'can0'
		kind:    'socketcan'
		desc:    'PCAN-USB · up'
	}]
	ip := [describe(Iface{
		name:  'bench0'
		iface: 'bench0'
		kind:  'vcan'
	}), describe(Iface{
		name:    'can0'
		iface:   'can0'
		kind:    'can'
		bitrate: 250000
	}), describe(virtual_ifaces()[1])]
	got := merge_interfaces(sys, ip)
	assert got.len == 3
	assert got[0].kind == 'vcan' && got[0].virtual && got[0].desc == 'virtual CAN'
	assert got[1].kind == 'socketcan' && got[1].bitrate == 250000 && got[1].desc == 'PCAN-USB · up · 250000'
	assert got[2].kind == 'inproc'
}
