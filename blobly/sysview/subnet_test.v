module sysview

fn segment() System {
	return System{
		buses: [SysBus{
			name:   'tel'
			subnet: '192.168.77.0/24'
		}, SysBus{
			name: 'compute'
		}]
		nodes: [SysNode{
			name:  'sysnode'
			buses: ['compute', 'tel']
			host:  50
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
	two.buses[1].subnet = '192.168.78.0/24'
	two.resolve_hosts('10.0.0.0/24')
	assert two.errs.any(it.contains('2 buses declare one'))
}
