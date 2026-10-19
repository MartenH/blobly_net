module sysview

fn segment() System {
	return System{
		buses: [SysBus{
			name:   'tel'
			kind:   'someip'
			subnet: '192.168.77.0/24'
		}, SysBus{
			name: 'compute'
		}]
		nodes: [SysNode{
			name:  'sysnode'
			buses:    ['compute', 'tel']
			host:     50
			has_host: true
			doip:     0x07A0
			testers:  [u16(0x0E00)]
		}, SysNode{
			name:    'old'
			buses:   ['tel']
			address: '10.0.0.9'
		}]
	}
}

fn test_a_host_is_its_segment_subnet_plus_the_number() {
	mut s := segment()
	s.resolve_hosts('')
	assert s.errs == []
	assert s.nodes.map(it.address) == ['192.168.77.50', '10.0.0.9']
}

fn test_the_override_moves_the_hosts_as_blobly_emb_does() {
	mut s := segment()
	s.resolve_hosts('10.20.0.0/16')
	assert s.errs == []
	assert s.nodes[0].address == '10.20.0.50'
}

fn test_what_cannot_be_resolved_has_no_address() {
	for override, why in {
		'10.20.0.5/16': 'is not a network'
		'bogus':        'is not a network'
	} {
		mut s := segment()
		s.resolve_hosts(override)
		assert s.nodes[0].address == ''
		assert s.errs.any(it.contains(why)), '${override}: ${s.errs}'
	}
	mut big := segment()
	big.nodes[0].host = 255
	big.resolve_hosts('')
	assert big.nodes[0].address == '' && big.errs[0].contains('not a host of 192.168.77.0/24')
	mut two := segment()
	two.buses << SysBus{
		name:   'tel2'
		kind:   'someip'
		subnet: '192.168.78.0/24'
	}
	two.resolve_hosts('10.0.0.0/24')
	assert two.errs.any(it.contains('2 buses declare one'))
	// a CAN bus stating a subnet is said, and is not a segment a host could sit on
	mut can := segment()
	can.buses[1].subnet = '192.168.78.0/24'
	can.resolve_hosts('')
	assert can.errs.any(it.contains('a can bus has no addresses')), '${can.errs}'
	assert can.nodes[0].address == '192.168.77.50'
}

fn test_resolving_again_derives_again() {
	mut s := segment()
	s.resolve_hosts('')
	s.resolve_hosts('10.20.0.0/16')
	assert s.nodes[0].address == '10.20.0.50'
	assert s.nodes[1].address == '10.0.0.9'
}

fn test_an_unresolved_host_is_said_and_matches_no_entity() {
	for i in 0 .. 3 {
		mut s := segment()
		match i {
			0 { s.nodes[0].host = 0 }
			1 { s.nodes[0].host = -1 } // not an integer
			else {
				s.buses << SysBus{
					name:   'tel2'
					kind:   'someip'
					subnet: 'bogus'
				}
				s.nodes[0].buses << 'tel2'
			}
		}
		s.resolve_hosts('')
		assert s.nodes[0].address == '', '${i}'
		assert s.errs.len > 0, '${i}'
		assert s.doip_tester_for(0x07A0, '10.0.0.199') == none, '${i}'
	}
	mut ok := segment()
	ok.resolve_hosts('')
	assert ok.doip_tester_for(0x07A0, '192.168.77.50') or { 0 } == 0x0E00
}
