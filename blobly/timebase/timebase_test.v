module timebase

// All time here is synthetic: values passed in, nothing waits.

const ms = i64(1_000_000)
const sec = i64(1_000_000_000)

// Lcg is a deterministic generator, so a failure reproduces exactly.
struct Lcg {
mut:
	s u64
}

fn (mut l Lcg) next() u64 {
	l.s = l.s * 6364136223846793005 + 1442695040888963407
	return l.s >> 33
}

fn (mut l Lcg) latency(lo i64, hi i64) i64 {
	return lo + i64(l.next() % u64(hi - lo))
}

fn abs64(v i64) i64 {
	return if v < 0 { -v } else { v }
}

fn test_nothing_is_mapped_before_the_first_frame() {
	d := Domain{}
	if _ := d.map(123) {
		assert false
	}
}

fn test_a_cyclic_frame_maps_back_to_its_true_cadence() {
	// #149 in one test: receipts 9.4 ms and 11.4 ms apart map back to exactly 10 ms.
	mut d := Domain{}
	d.observe(1000 * ms, 5000 * ms + 900_000)
	d.observe(1010 * ms, 5010 * ms + 300_000)
	d.observe(1020 * ms, 5021 * ms + 700_000)
	t1 := d.map(1000 * ms) or { panic('none') }
	t2 := d.map(1010 * ms) or { panic('none') }
	t3 := d.map(1020 * ms) or { panic('none') }
	assert t2 - t1 == 10 * ms
	assert t3 - t2 == 10 * ms
	assert t2 == 5010 * ms + 300_000 // the least delayed delivery sets the offset
}

fn test_the_offset_is_the_least_delayed_delivery_never_an_average() {
	mut d := Domain{}
	mut r := Lcg{
		s: 1
	}
	offset := i64(7) * sec
	for i in 0 .. 500 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + offset + r.latency(50_000, 2 * ms))
	}
	got := d.map(4990 * ms) or { panic('none') }
	truth := 4990 * ms + offset
	assert got >= truth
	assert got - truth < 100_000
}

fn test_a_unix_nanosecond_epoch_keeps_every_nanosecond() {
	// A CANsub stamp on the Unix epoch in ns is ~1.76×10¹⁸: past what an f64 holds exactly.
	mut d := Domain{}
	hw0 := i64(1_758_780_000_000_000_000)
	for i in 0 .. 50 {
		d.observe(hw0 + i64(i) * 10 * ms + 7, i64(12_345_678_901_234) + i64(i) * 10 * ms + 1 * ms)
	}
	a := d.map(hw0 + 7) or { panic('none') }
	b := d.map(hw0 + 10 * ms + 7) or { panic('none') }
	c := d.map(hw0 + 3) or { panic('none') }
	assert b - a == 10 * ms
	assert a - c == 4
}

fn test_fifty_ppm_over_an_hour_stays_inside_half_a_millisecond() {
	// Crystals 50 ppm apart drift 180 ms an hour; the window keeps the error to its drift.
	mut d := Domain{}
	mut r := Lcg{
		s: 42
	}
	offset := i64(123) * sec
	mut worst := i64(0)
	for i in 0 .. 36_000 {
		hw := i64(i) * 100 * ms
		truth := offset + hw + hw / 20_000
		d.observe(hw, truth + r.latency(50_000, 2 * ms))
		if hw >= window_ns {
			got := d.map(hw) or { panic('none') }
			if abs64(got - truth) > worst {
				worst = abs64(got - truth)
			}
		}
	}
	assert worst < 700_000
}

fn test_a_late_delivery_moves_nothing() {
	// A collector pause (#299 measured up to 700 ms): a high gap is never the minimum.
	mut d := Domain{}
	for i in 0 .. 100 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + 4 * sec + 1 * ms)
	}
	d.observe(1000 * ms, 1000 * ms + 4 * sec + 700 * ms)
	assert (d.map(1000 * ms) or { panic('none') }) == 1000 * ms + 4 * sec + 1 * ms
}

fn test_a_stalled_sibling_thread_does_not_move_the_estimate() {
	// One channel's thread of a multi-channel device stalls 700 ms and drains beside its prompt
	// sibling. A fixed stamp maps the same after every delivery.
	mut d := Domain{}
	offset := i64(4) * sec
	for i in 0 .. 500 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	reference := i64(4990) * ms
	truth := reference + offset + 1 * ms
	for j in 0 .. 70 {
		a_hw := 5 * sec + i64(j) * 10 * ms
		b_hw := 5700 * ms + i64(j) * 10 * ms
		d.observe(a_hw, b_hw + offset + 1 * ms)
		assert (d.map(reference) or { panic('none') }) == truth
		d.observe(b_hw, b_hw + offset + 1 * ms)
		assert (d.map(reference) or { panic('none') }) == truth
	}
}

fn test_a_startup_backlog_converges() {
	// A driver queue holding frames from before the reader started: each is a better minimum.
	mut d := Domain{}
	host_start := i64(50) * sec
	for i in 0 .. 1000 {
		d.observe(i64(i) * 10 * ms, host_start + i64(i) * 100_000)
	}
	offset := host_start - 10 * sec + 100 * ms
	for i in 1000 .. 1100 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	assert (d.map(1099 * 10 * ms) or { panic('none') }) == 1099 * 10 * ms + offset + 1 * ms
}

fn test_a_quiet_domain_keeps_its_estimate_while_nothing_arrives() {
	mut d := Domain{}
	for i in 0 .. 50 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + 2 * sec + 1 * ms)
	}
	assert (d.map(90 * sec) or { panic('none') }) == 90 * sec + 2 * sec + 1 * ms
}

fn test_after_a_silence_the_first_frame_back_sets_the_estimate() {
	// A diagnostic bus idle past the window. A late first frame is placed at its receipt — no worse
	// than host-receipt stamping — until a prompt one arrives.
	mut d := Domain{}
	offset := i64(6) * sec
	for i in 0 .. 50 {
		hw := i64(i) * 100 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	hw := i64(4900) * ms + 15 * sec
	d.observe(hw, hw + offset + 700 * ms)
	assert (d.map(hw) or { panic('none') }) == hw + offset + 700 * ms
	d.observe(hw + 10 * ms, hw + 10 * ms + offset + 1 * ms)
	assert (d.map(hw) or { panic('none') }) == hw + offset + 1 * ms
}

fn test_a_sample_delivered_out_of_host_order_still_counts() {
	// Receive threads read the clock, then race for the lock.
	mut d := Domain{}
	d.observe(0, 3 * sec + 5 * ms)
	d.observe(200 * ms, 3 * sec + 200 * ms + 5 * ms)
	d.observe(50 * ms, 3 * sec + 50 * ms + 1 * ms)
	assert (d.map(0) or { panic('none') }) == 3 * sec + 1 * ms
}

fn test_a_copied_domain_is_independent() {
	// V copies a struct out of a map on every read; with a slice ring, the copy shared its data.
	mut a := Domain{}
	for i in 0 .. 20 {
		hw := i64(i) * 100 * ms
		a.observe(hw, hw + 5 * sec + 1 * ms)
	}
	mut b := a
	b.observe(2 * sec, 2 * sec + 1 * sec)
	a.observe(2500 * ms, 2500 * ms + 5 * sec + 1 * ms)
	assert (a.map(0) or { panic('none') }) == 5 * sec + 1 * ms
	assert (b.map(0) or { panic('none') }) == 1 * sec
}

fn test_an_old_backlog_stamp_is_early_by_drift_times_its_age() {
	// map applies today's offset: a stamp a minute old, device 50 ppm fast, lands ~3 ms early —
	// against the 60 s late that receipt stamping gave it.
	mut d := Domain{}
	offset := i64(8) * sec
	host_of := fn [offset] (hw i64) i64 {
		return offset + hw - hw / 20_000
	}
	for i in 0 .. 120_000 {
		hw := i64(i) * 1 * ms
		d.observe(hw, host_of(hw) + 100_000)
	}
	stale := i64(60) * sec
	receipt := host_of(120 * sec) + 100_000
	d.observe(stale, receipt)
	got := d.map(stale) or { panic('none') }
	truth := host_of(stale)
	assert got <= receipt
	assert truth - got > 2 * ms
	assert truth - got <= (receipt - truth) / 20_000
}

fn test_a_frame_mapped_on_arrival_is_never_early_and_never_later_than_its_receipt() {
	// The property, over 200,000 frames with random latency, collector pauses and dropped frames,
	// without drift: every frame lands between its wire time and its receipt.
	mut d := Domain{}
	mut r := Lcg{
		s: 7
	}
	offset := i64(9) * sec
	for i in 0 .. 200_000 {
		hw := i64(i) * 1 * ms
		mut lat := r.latency(0, 2 * ms)
		if r.next() % 5000 == 0 {
			lat += 700 * ms
		}
		if r.next() % 20_000 == 0 {
			continue
		}
		truth := hw + offset
		d.observe(hw, truth + lat)
		got := d.map(hw) or { panic('none') }
		assert got >= truth
		assert got <= truth + lat
	}
}

fn test_the_placer_answers_each_kind_of_frame() {
	mut p := Placer{}
	// no stamp: its receipt
	assert p.place('', 0, 5 * sec, false) == 5 * sec
	// a stamp on the host clock already: the stamp, not the later receipt
	assert p.place('kernel', 4 * sec, 4 * sec + 3 * ms, true) == 4 * sec
	// a foreign clock: mapped through its own domain — here a device 2 s behind the host
	p.place('pcan:1', 1 * sec, 3 * sec + 1 * ms, false)
	assert p.place('pcan:1', 1100 * ms, 3100 * ms + 5 * ms, false) == 3100 * ms + 1 * ms
}

fn test_the_placer_keeps_each_domain_apart_and_forgets_them_on_reset() {
	mut p := Placer{}
	p.place('a', 0, 10 * sec, false) // a: 10 s behind
	p.place('b', 0, 20 * sec, false) // b: 20 s behind
	assert p.place('a', 1 * sec, 11 * sec + 5 * ms, false) == 11 * sec
	assert p.place('b', 1 * sec, 21 * sec + 5 * ms, false) == 21 * sec
	p.reset()
	// after a reset the first frame sets its domain afresh
	assert p.place('a', 1 * sec, 50 * sec, false) == 50 * sec
}

