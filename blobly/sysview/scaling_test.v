module sysview

const any_raw = Range{0, 255}

fn test_a_gap_value_goes_to_the_nearer_raw_value_whatever_the_slopes() {
	s := Scaling{
		segments: [Linear{0, 100, 0, 0.1, 1}, Linear{101, 110, -999, 10, 1}]
	}
	// raw 101 is physical 11, raw 100 is physical 10: 10.2 is nearer 10
	assert s.raw('10.2', any_raw)! == 100
	assert s.raw('10.8', any_raw)! == 101
	assert s.raw('5', any_raw)! == 50
	assert s.raw('21', any_raw)! == 102
}
