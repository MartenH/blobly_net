module transport

// THE BIT COUNTS THE LOAD IS MADE OF, pinned. Worst-case stuffing is the stated choice, so the
// numbers sit a little above the textbook bare lengths.
fn test_classic_frames_cost_their_bits_plus_worst_case_stuffing() {
	std8 := CanFrame{
		id:   0x100
		data: []u8{len: 8}
	}
	// bare 47 + 64 = 111; stuffable 34 + 64 = 98 -> 19 stuff bits
	assert frame_bits(std8, 500000, 500000) == 130.0
	ext8 := CanFrame{
		id:       0x18DAF110
		extended: true
		data:     []u8{len: 8}
	}
	// bare 67 + 64 = 131; stuffable 54 + 64 = 118 -> 23
	assert frame_bits(ext8, 500000, 500000) == 154.0
	empty := CanFrame{
		id: 0x7FF
	}
	// bare 47; stuffable 34 -> 6
	assert frame_bits(empty, 500000, 500000) == 53.0
	// The rates do not matter for a classic frame.
	assert frame_bits(std8, 250000, 2000000) == 130.0
}

// AN FD FRAME'S DATA PHASE IS CHEAPER AT A FASTER RATE, in nominal bit-times — that is the
// whole point of BRS — and no cheaper without it.
fn test_fd_frames_scale_their_data_phase_by_the_rate_switch() {
	fd64 := CanFrame{
		id:   0x100
		fd:   true
		brs:  true
		data: []u8{len: 64}
	}
	no_brs := CanFrame{
		...fd64
		brs: false
	}
	at_nominal := frame_bits(no_brs, 500000, 2000000)
	at_data := frame_bits(fd64, 500000, 2000000)
	assert at_data < at_nominal, 'BRS must shorten the frame in nominal bit-times'
	// arb 17+3=20; data 1+4+512+5+21+5+1=549, +102 stuffing = 651; tail 12
	assert at_nominal == f64(20 + 651 + 12)
	// with BRS at 4x the data part costs a quarter
	assert at_data == f64(20) + 651.0 / 4.0 + f64(12)
	// A classic 64-byte payload is impossible; an FD frame of 8 bytes is a little longer than
	// its classic twin at the same rate (the FD control bits and the longer CRC).
	fd8 := CanFrame{
		id:   0x100
		fd:   true
		data: []u8{len: 8}
	}
	assert frame_bits(fd8, 500000, 500000) > 130.0
}

// LOAD IS BITS OVER CAPACITY, clamped: a worst-case estimate may read a hair over a saturated
// wire, and a reader must never see 103 %.
fn test_load_percent_is_bits_over_capacity_and_never_above_100() {
	// 500 kbit/s for one second is 500 000 bit-times; 1000 standard 8-byte frames are
	// 130 000 of them.
	assert load_percent(130000.0, 1000, 500000) == f32(26.0)
	assert load_percent(0, 1000, 500000) == 0
	assert load_percent(600000.0, 1000, 500000) == 100
	// No interval or no rate: no load, not a division by zero.
	assert load_percent(1000.0, 0, 500000) == 0
	assert load_percent(1000.0, 1000, 0) == 0
	// Over a half-second window the same bits are twice the load.
	assert load_percent(130000.0, 500, 500000) == f32(52.0)
}
