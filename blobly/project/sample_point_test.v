module project

fn vector_row(name string) Channel {
	return Channel{
		name:         name
		adapter:      'vector'
		address:      '1'
		iface:        'vector:1'
		typ:          'canfd'
		bitrate:      500000
		fd:           true
		data_bitrate: 2000000
	}
}

// A Vector row's sample points reach its address as options the wire ignores, before the mode.
fn test_a_vector_row_carries_its_sample_points() {
	c := Channel{
		...vector_row('CAN1')
		sample_point:      75.0
		data_sample_point: 87.5
		listen_only:       true
	}
	assert c.iface_with_bitrate() == 'vector:1@500000/2000000,sp=75,dsp=87.5,silent'
	assert vector_row('CAN1').iface_with_bitrate() == 'vector:1@500000/2000000'
	if why := c.address_config_error() {
		assert false, 'both points are placeable: ${why}'
	}
	pcan := Channel{
		...c
		adapter: 'pcan'
		address: 'PCAN_USBBUS1'
		iface:   'pcan:PCAN_USBBUS1'
	}
	assert !pcan.iface_with_bitrate().contains('sp=')
}

// A point the clock cannot place is refused at the row, not ignored at the controller.
fn test_a_vector_sample_point_the_clock_cannot_place_is_refused() {
	c := Channel{
		...vector_row('CAN1')
		data_bitrate: 8000000
		sample_point: 76.0
	}
	why := c.address_config_error() or {
		assert false, '76% has no placement at 8 Mbit/s, ten quanta a bit'
		return
	}
	assert why.contains('76%') && why.contains('data phase'), why
	classic := Channel{
		...vector_row('CAN1')
		typ:          'can'
		fd:           false
		data_bitrate: 0
		bitrate:      83333
		sample_point: 75.0
	}
	if _ := classic.address_config_error() {
	} else {
		assert false, 'a classic sample point needs segments, and 83333 divides no clock'
	}
}

fn test_a_data_sample_point_is_refused_where_nothing_places_it() {
	classic := Channel{
		...vector_row('CAN1')
		typ:               'can'
		fd:                false
		data_bitrate:      0
		data_sample_point: 70.0
	}
	assert (classic.address_config_error() or { '' }).contains('classic')
	kv := Channel{
		...vector_row('CAN1')
		adapter:           'kvaser'
		address:           '0'
		iface:             'kvaser:0'
		data_sample_point: 70.0
	}
	assert (kv.address_config_error() or { '' }).contains('kvaser')
	typed := Channel{
		...vector_row('CAN1')
		address: '1,sp=75'
		iface:   'vector:1,sp=75'
	}
	assert (typed.address_config_error() or { '' }).contains('sample_point')
}

// Two rows on one Vector wire sample it one way, as they run it at one rate.
fn test_rows_sharing_a_vector_wire_must_agree_where_it_samples() {
	a := Channel{
		...vector_row('A')
		sample_point: 75.0
	}
	same := Channel{
		...vector_row('B')
		iface:             'vector:ch1'
		sample_point:      75.0
		data_sample_point: 75.0
	}
	assert destination_conflicts([a, same]) == []
	other := Channel{
		...vector_row('B')
		sample_point:      75.0
		data_sample_point: 70.0
	}
	problems := destination_conflicts([a, other])
	assert problems.len == 1 && problems[0].contains('70%'), '${problems}'
}

// data_sample_point is written back, and a project using it says v13.
fn test_a_data_sample_point_round_trips_as_v13() {
	p := parse('
project:
  name: sp
buses:
  - name: CAN1
    adapter: vector
    address: 1
    protocol: canfd
    bitrate: 500000
    fd: true
    data_bitrate: 2000000
    sample_point: 80
    data_sample_point: 70
') or {
		assert false, '${err}'
		return
	}
	assert p.channels[0].data_sample_point == 70.0
	assert version_for(p) == 13
	y := p.to_yaml()
	assert y.contains('data_sample_point: 70')
	back := parse(y) or {
		assert false, '${err}'
		return
	}
	assert back.channels[0].data_sample_point == 70.0
	assert version_for(Project{
		channels: [vector_row('CAN1')]
	}) < 13
}
