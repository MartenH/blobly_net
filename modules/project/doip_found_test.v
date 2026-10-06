module project

fn doip_row(address string, ecu u16) Channel {
	return Channel{
		name:     'D'
		adapter:  'doip'
		address:  address
		iface:    compose_iface('doip', address)
		typ:      'doip'
		ecu_addr: ecu
	}
}

fn test_a_found_entity_becomes_a_doip_channel_named_after_its_vin() {
	c := doip_found_channel(DoipFound{
		address: '192.168.0.50:13400'
		logical: 0x07A0
		vin:     'BLOBLYEMBSYSNODE1'
	})
	assert c.name == 'BLOBLYEMBSYSNODE1'
	assert c.adapter == 'doip'
	assert c.typ == 'doip'
	assert c.is_doip()
	assert c.iface == 'doip:192.168.0.50:13400'
	assert c.ecu_addr == 0x07A0
	assert c.tester_addr == 0x0E80
	assert c.vin == 'BLOBLYEMBSYSNODE1'
	host, port := c.doip_endpoint()
	assert host == '192.168.0.50' && port == 13400
}

fn test_without_a_vin_the_channel_is_named_after_its_address() {
	c := doip_found_channel(DoipFound{ address: '[fe80::1]:13400', logical: 0x1000 })
	assert c.name == '[fe80::1]:13400'
	assert c.vin == ''
	host, port := c.doip_endpoint()
	assert host == 'fe80::1' && port == 13400
}

fn test_a_partial_vin_names_the_channel_but_is_not_announced() {
	c := doip_found_channel(DoipFound{ address: '10.0.0.2:13400', logical: 1, vin: 'SHORT' })
	assert c.name == 'SHORT'
	assert c.vin == ''
}

fn test_in_project_matches_the_endpoint_start_would_dial_and_the_ecu() {
	f := DoipFound{
		address: '192.168.0.50:13400'
		logical: 0x07A0
	}
	// the default port is the found one
	assert doip_found_in([doip_row('192.168.0.50', 0x07A0)], f)
	assert doip_found_in([doip_row('192.168.0.50:13400', 0x07A0)], f)
	// another ECU behind the same entity is not this one
	assert !doip_found_in([doip_row('192.168.0.50:13400', 0x1000)], f)
	// another port is another entity
	assert !doip_found_in([doip_row('192.168.0.50:13401', 0x07A0)], f)
	// a CAN row on a look-alike address is not a DoIP channel
	assert !doip_found_in([Channel{
		adapter: 'virtual'
		address: '192.168.0.50:13400'
		iface:   'inproc:192.168.0.50:13400'
	}], f)
}

fn test_found_at_ignores_the_ecu_and_needs_a_doip_row() {
	f := DoipFound{
		address: '192.168.0.50:13400'
		logical: 0x07A0
	}
	assert doip_found_at(doip_row('192.168.0.50', 0x1000), f)
	assert !doip_found_at(doip_row('192.168.0.51', 0x07A0), f)
}

fn test_effective_address_fills_in_the_default_port_and_host() {
	assert doip_row('192.168.0.50', 1).doip_effective_address() == '192.168.0.50:13400'
	assert doip_row('', 1).doip_effective_address() == '127.0.0.1:13400'
	assert doip_row('[fe80::1]', 1).doip_effective_address() == '[fe80::1]:13400'
	// a refused port is shown as typed, not as an IPv6 literal on the default port
	assert doip_row('ecu.local:bad', 1).doip_effective_address() == 'ecu.local:bad'
	s := Channel{
		adapter: 'someip'
		typ:     'someip'
		iface:   compose_iface('someip', '0.0.0.0')
	}
	assert s.someip_effective_address() == '0.0.0.0:30490'
}
