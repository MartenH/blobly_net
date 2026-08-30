module loadrule

// 500 kbit/s, the formula transport.load_percent answers with in the app.
fn at_500k(bits f64, ms i64) f32 {
	return f32(100.0 * bits / (500000.0 * f64(ms) / 1000.0))
}

// A RUNNING ROW CLOSES AN INTERVAL A SECOND, and not before. 135 000 bit-times in a second at
// 500 kbit/s is 27 %.
fn test_running_row_closes_a_second_into_the_history() {
	mut w := Wire{}
	assert !roll(mut w, .running, 1000, at_500k), 'first roll only opens the interval'
	assert w.at == 1000
	w.bits = 135000
	assert !roll(mut w, .running, 1500, at_500k), 'half a second is not an interval'
	assert w.bits == 135000, 'and the bits are still in flight'
	assert roll(mut w, .running, 2000, at_500k)
	assert w.pct == f32(27.0)
	assert w.hist == [f32(27.0)]
	assert w.bits == 0
	assert w.at == 2000
}

// THE STRIP KEEPS SIXTY: the sixty-first pushes the oldest out.
fn test_history_keeps_sixty_seconds() {
	mut w := Wire{
		at: 0
	}
	roll(mut w, .running, 1000, at_500k)
	for i in 1 .. 62 {
		w.bits = f64(i) * 5000.0
		roll(mut w, .running, 1000.0 + f64(i) * 1000.0, at_500k)
	}
	assert w.hist.len == keep
	// the first closed second (5000 bits = 1 %) is gone, the second one (2 %) is the oldest
	assert w.hist[0] == f32(2.0)
	assert w.hist[keep - 1] == f32(61.0)
}

// A SPAWNING ROW DOES NOT CLOSE INTERVALS AND REBASES: a reader that took three seconds to
// open must not turn those into three idle samples, and the first sample after it starts
// where the spawn ended. Codex #263 r5 and r6 — two rounds in this one path.
fn test_spawning_row_keeps_its_bits_and_rebases_the_interval() {
	mut w := Wire{
		at: 1000
	}
	w.bits = 20000 // a tap's sends, accepted while the reader was on its way
	assert !roll(mut w, .spawning, 2500, at_500k)
	assert !roll(mut w, .spawning, 4000, at_500k)
	assert w.hist.len == 0, 'nothing closed while spawning'
	assert w.bits == 20000, 'the sends stay: they were on the wire'
	assert w.at == 4000, 'rebased to the last spawning roll'
	// the reader runs: one honest second later, the first sample covers THAT second plus the
	// sends that were waiting — not a 4-second window
	assert !roll(mut w, .running, 4500, at_500k)
	w.bits += 115000
	assert roll(mut w, .running, 5000, at_500k)
	assert w.pct == f32(27.0)
}

// A ROW NOBODY READS HAS NO LOAD: interval and history go, so a gap nobody observed cannot
// come back as an idle trough when the row is re-enabled (codex #263 r3).
fn test_unread_row_drops_interval_and_history() {
	mut w := Wire{
		at:   1000
		bits: 5000
		pct:  12
		hist: [f32(10), 11, 12]
	}
	assert !roll(mut w, .unread, 2000, at_500k)
	assert w.bits == 0
	assert w.at == 2000
	assert w.hist.len == 0
	assert w.pct == 0
	// and re-enabled, it starts clean rather than closing the unread stretch as a sample
	assert !roll(mut w, .running, 2500, at_500k)
	assert w.hist.len == 0
}
