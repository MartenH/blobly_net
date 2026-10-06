module project

fn doip_row(name string, address string, nodes []string) Channel {
	return Channel{
		name:     name
		adapter:  'doip'
		address:  address
		iface:    compose_iface('doip', address)
		typ:      'doip'
		simulate: nodes
	}
}

fn test_hosting_lists_loopback_entities_only_by_port() {
	chs := [
		doip_row('A', '127.0.0.1:13400', ['SUT']),
		doip_row('B', '127.0.0.2:13400', ['SUT']),
		doip_row('C', '127.0.0.4:13555', ['SUT']),
		doip_row('Nic', '192.168.0.51:13400', ['SUT']), // reachable from the bench: not moved
		doip_row('Tester', '127.0.0.9:13400', []), // hosts nothing
		Channel{
			...doip_row('Off', '127.0.0.5:14000', ['SUT'])
			enabled: false
		},
	]
	hs := doip_hosting(chs)
	assert hs.len == 2
	assert hs[0].port == 13400 && hs[0].hosts == ['127.0.0.1', '127.0.0.2']
	assert hs[1].port == 13555 && hs[1].hosts == ['127.0.0.4']
}

fn test_moved_rows_are_the_entities_and_their_testers() {
	chs := [
		doip_row('Entity', '127.0.0.1:13400', ['SUT']),
		doip_row('SameEntity', 'localhost:13400', []), // a tester dialing it by another spelling
		doip_row('Other', '127.0.0.9:13400', []), // a loopback entity this run does not host
		doip_row('Real', '192.168.0.51:13400', []), // somebody else's ECU
		doip_row('Alt', '127.0.0.4:13555', ['SUT']),
		Channel{
			name:  'CAN1'
			iface: 'inproc:CAN1'
		},
	]
	out, notes := with_doip_ports(chs, {
		13400: 30001
	})
	assert out[0].iface == 'doip:127.0.0.1:30001'
	assert out[0].doip_effective_address() == '127.0.0.1:30001'
	assert out[1].doip_effective_address() == 'localhost:30001'
	assert out[2].iface == 'doip:127.0.0.9:13400'
	assert out[3].iface == 'doip:192.168.0.51:13400'
	assert out[4].iface == 'doip:127.0.0.4:13555', 'a port the map does not name stays'
	assert out[5].iface == 'inproc:CAN1'
	assert notes.len == 2
	assert notes[0] == 'Entity: DoIP 127.0.0.1:13400 -> 127.0.0.1:30001 for this run'
	assert chs[0].iface == 'doip:127.0.0.1:13400', 'the input is not modified'
}

fn test_an_ipv6_loopback_entity_keeps_its_brackets() {
	out, _ := with_doip_ports([doip_row('V6', '[::1]:13400', ['SUT'])], {
		13400: 30002
	})
	assert out[0].iface == 'doip:[::1]:30002'
	host, port := out[0].doip_endpoint()
	assert host == '::1' && port == 30002
}

fn test_a_default_endpoint_row_is_moved_too() {
	// `type: doip` with no address dials the default, 127.0.0.1:13400
	row := Channel{
		name:     'Bare'
		typ:      'doip'
		iface:    'doip'
		adapter:  'doip'
		address:  ''
		simulate: ['SUT']
	}
	out, _ := with_doip_ports([row], {
		13400: 30003
	})
	host, port := out[0].doip_endpoint()
	assert host == '127.0.0.1' && port == 30003
}

fn test_hosting_keeps_the_spelling_the_entity_binds() {
	hs := doip_hosting([doip_row('L', 'localhost:13400', ['SUT']),
		doip_row('Same', '127.0.0.1:13400', ['SUT'])])
	assert hs.len == 1 && hs[0].hosts == ['localhost'], 'one loopback address, bound as written'
}
