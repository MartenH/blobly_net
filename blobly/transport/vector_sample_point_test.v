module transport

import math

// A sample point rides as an option after the rate, in any order with the mode.
fn test_sample_point_options_parse_in_any_order() {
	s := parse_vector_spec('1@500000/2000000,sp=75,silent,dsp=87.5') or {
		assert false, '${err}'
		return
	}
	assert s.silent && s.fd && s.sample_point == 75.0 && s.data_sample_point == 87.5
	c := parse_vector_spec('ch2,SP=80') or {
		assert false, '${err}'
		return
	}
	assert c.channel == 2 && !c.fd && c.sample_point == 80.0 && c.data_sample_point == 0
}

fn test_a_malformed_sample_point_option_is_refused() {
	for bad in ['1,sp=', '1,sp=abc', '1,sp=8.0.0', '1,sp=.', '1,sp=-75', '1,sp=80,sp=70',
		'1,silent,normal', '1,brp=4', '1@500000,dsp=70'] {
		if _ := parse_vector_spec(bad) {
			assert false, '${bad} must be refused'
		}
	}
}

// The options are not the wire: one channel at one rate is one destination and one pin key,
// whatever it samples at.
fn test_a_sample_point_is_not_part_of_the_wire() {
	plain := vendor_destination_key('vector:1@500000/2000000')
	for a in ['vector:1@500000/2000000,sp=75', 'vector:1@500000/2000000,sp=75,dsp=70,silent',
		'vector:ch1@500000/2000000,dsp=70'] {
		assert vendor_destination_key(a) == plain, a
	}
	assert vector_key('1,sp=80,silent') == '1'
	assert pinned_wire_key('vector:1,sp=80') == pinned_wire_key('vector:1@250000')
}

// The default split is what an FD phase had before a sample point could be chosen.
fn test_no_sample_point_keeps_the_default_split() {
	t := vector_phase_timing(500_000, .arbitration, 0) or { panic(err) }
	assert t == FdTiming{
		tseg1: 31
		tseg2: 8
		sjw:   4
	}
	d := vector_phase_timing(5_000_000, .data, 0) or { panic(err) }
	assert d.sample_point() == 81.25
}

fn test_a_chosen_sample_point_is_placed() {
	for rate, sp in {
		500_000: 75.0
		250_000: 87.5
		125_000: 70.0
	} {
		t := vector_phase_timing(rate, .arbitration, sp) or { panic(err) }
		assert t.sample_point() == sp, '${rate} at ${sp}: ${t}'
		assert t.sjw == if t.tseg2 > 4 { 4 } else { t.tseg2 }
	}
	d := vector_phase_timing(8_000_000, .data, 70) or { panic(err) }
	assert d.sample_point() == 70.0 && d.tseg1 + d.tseg2 + 1 == 10
}

// Within the allowance the nearest placement is taken; past it the rate is refused, naming the
// nearest it can manage.
fn test_a_sample_point_the_clock_cannot_place_is_refused_by_name() {
	near := vector_phase_timing(5_000_000, .data, 80) or { panic(err) }
	assert near.sample_point() == 81.25
	if t := vector_phase_timing(8_000_000, .data, 76) {
		assert false, '8 Mbit/s has ten quanta, so 76% cannot be placed: ${t}'
	} else {
		assert err.msg().contains('76%') && err.msg().contains('80%'), err.msg()
	}
	for sp in [45.0, 96.0] {
		if _ := vector_phase_timing(500_000, .arbitration, sp) {
			assert false, '${sp}% is outside 50-95%'
		}
	}
}

// Every placement the solver accepts divides the clock and lands within the allowance.
fn test_every_accepted_placement_is_exact_and_near() {
	for phase in [VectorPhase.arbitration, .data] {
		for rate in [125_000, 250_000, 500_000, 800_000, 1_000_000, 2_000_000, 4_000_000, 5_000_000,
			8_000_000] {
			for sp in [50.0, 62.5, 70.0, 75.0, 80.0, 81.0, 87.5, 90.0, 95.0] {
				t := vector_phase_timing(rate, phase, sp) or { continue }
				tq := 1 + t.tseg1 + t.tseg2
				assert vector_fd_clock_hz % (rate * tq) == 0
				assert tq <= phase.tq_max() && t.tseg2 >= 1 && t.tseg1 >= 1
				assert math.abs(t.sample_point() - sp) <= vector_sample_point_tolerance
			}
		}
	}
}

// What an open configures: nothing for a plain classic address (the driver times it), the
// arbitration segments for a classic one with a sample point, and a data phase that samples
// where the arbitration phase does unless told otherwise.
fn test_open_timings_follow_the_address() {
	plain := vector_open_timings(parse_vector_spec('1@83333') or { panic(err) }) or { panic(err) }
	assert plain == VectorTimings{}
	if _ := vector_open_timings(parse_vector_spec('1@83333,sp=75') or { panic(err) }) {
		assert false, 'a classic sample point needs segments, and 83333 divides no clock'
	}
	cl := vector_open_timings(parse_vector_spec('1@500000,sp=75') or { panic(err) }) or {
		panic(err)
	}
	assert cl.arb.sample_point() == 75.0 && cl.dat == FdTiming{}
	fd := vector_open_timings(parse_vector_spec('1@500000/2000000,sp=75') or { panic(err) }) or {
		panic(err)
	}
	assert fd.dat.sample_point() == 75.0
	own := vector_open_timings(parse_vector_spec('1@500000/2000000,dsp=70') or { panic(err) }) or {
		panic(err)
	}
	assert own.arb == vector_phase_timing(500_000, .arbitration, 0) or { panic(err) }
	assert own.dat.sample_point() == 70.0
	if why := vector_address_error('vector:1@500000/8000000,dsp=76') {
		assert why.contains('data phase'), why
	} else {
		assert false, 'the address check must refuse what the open refuses'
	}
}

// The ports pin where the wire samples, like its rates: a port asking for another is a clash.
fn test_the_open_ports_pin_the_sample_point() {
	mut held := pinned_open('vector:21@500000/2000000,sp=75', fn (_ string) !Bus {
		return open_inproc('pin_sample_point')!
	}) or { panic(err) }
	assert wire_pin_clash('vector:21@500000/2000000,sp=75') == ''
	clash := wire_pin_clash('vector:21@500000/2000000')
	assert clash.contains('75%') && clash.contains('80%'), clash
	assert wire_pin_clash('vector:21@500000/2000000,sp=75,dsp=70') != ''
	held.close()
	assert wire_pin_clash('vector:21@500000/2000000') == ''
}
