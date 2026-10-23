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
	n, d := wire_rates(rows, 'inproc:A')
	assert n == default_bitrate, 'the first CAN row, its unset rate the default'
	assert d == 2000000
	bn, bd := wire_rates(rows, 'inproc:B')
	assert bn == 125000 && bd == 0
	cn, cd := wire_rates(rows, 'inproc:C')
	assert cn == default_bitrate && cd == 0, 'no row on the wire'
}
