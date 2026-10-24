module project

fn test_a_wire_is_priced_by_its_first_row_and_first_declared_data_rate() {
	rows := [
		Channel{
			name:    'eth'
			typ:     'doip'
			iface:   'inproc:A'
			bitrate: 1000
		},
		Channel{
			name:  'a1'
			iface: 'inproc:A'
		},
		Channel{
			name:         'a2'
			iface:        'inproc:A'
			bitrate:      250000
			data_bitrate: 2000000
		},
		Channel{
			name:    'b'
			iface:   'inproc:B'
			bitrate: 125000
		},
	]
	n, d := wire_rates(rows, 'inproc:A') or { panic('no row on inproc:A') }
	assert n == default_bitrate, 'the first CAN row, its unset rate the default'
	assert d == 2000000
	bn, bd := wire_rates(rows, 'inproc:B') or { panic('no row on inproc:B') }
	assert bn == 125000 && bd == 0
	if _, _ := wire_rates(rows, 'inproc:C') {
		assert false, 'no row is on inproc:C'
	}
}

fn test_an_address_states_its_own_rates() {
	an, ad := address_rates('kvaser:0@250000/2000000')
	assert an == 250000 && ad == 2000000
	pn, pd := address_rates('pcan:PCAN_USBBUS1@125000')
	assert pn == 125000 && pd == 0
	vn, _ := address_rates('vector:1@1000000,silent')
	assert vn == 1000000
	sn, sd := address_rates('inproc:bench@250000')
	assert sn == default_bitrate && sd == 0, 'a software bus name carries no rate'
	xn, _ := address_rates('pcan:X@fast')
	assert xn == default_bitrate, 'a rate that is not one'
}

fn test_a_bare_vendor_address_finds_the_row_that_states_its_rate() {
	rows := [
		Channel{
			name:    'c'
			adapter: 'cansub'
			iface:   'cansub:12345678/1'
			bitrate: 250000
		},
	]
	n, _ := wire_rates(rows, 'cansub:12345678/1') or { panic('the bare address found no row') }
	assert n == 250000
	m, _ := wire_rates(rows, rows[0].iface_with_bitrate()) or { panic('the row found no row') }
	assert m == 250000
}
