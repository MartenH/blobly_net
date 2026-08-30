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

// A HANDOFF CARRIES WHAT THE OUTGOING READER MEASURED into the successor's first interval —
// bits AND the time they were watched over — so 900 ms at 27 % followed by 1100 ms at 27 % is
// one sample of 27 % over two seconds: not a spike in the successor's first second (codex
// #263 r7), not a 900 ms column in a strip labelled sixty seconds (r11).
fn test_handoff_carries_the_partial_interval_into_the_next_sample() {
	mut w := Wire{
		at:   1000
		bits: 121500 // 900 ms at 27 %
	}
	handoff(mut w, 1900)
	assert w.hist.len == 0, 'a partial interval is not a sample of its own'
	assert w.bits == 0
	assert w.at == 1900
	assert w.carry_bits == 121500
	assert w.carry_ms == 900
	// the successor spawns (rebasing) and runs; the carry survives the spawn
	assert !roll(mut w, .spawning, 2400, at_500k)
	assert w.carry_ms == 900
	// 900 ms carried: the interval closes once a second has been OBSERVED, which is 100 ms
	// into the successor's own — not a second into it
	assert !roll(mut w, .running, 2450, at_500k)
	w.bits = 13500 // 100 ms at 27 %
	assert roll(mut w, .running, 2500, at_500k)
	assert w.pct == f32(27.0)
	assert w.hist == [f32(27.0)], 'one second observed: one column'
	assert w.carry_ms == 0
	assert w.carry_bits == 0
}

// A SAMPLE THAT COVERS TWO SECONDS TAKES TWO COLUMNS: carries accumulated across handoffs
// while the successor was spawning close as one average, written once per second it stood
// for, so the strip's width stays seconds (codex #263 r12).
fn test_a_sample_spanning_seconds_takes_a_column_per_second() {
	mut w := Wire{
		at:         1000
		carry_bits: 270000 // two seconds at 27 %, carried
		carry_ms:   2000
	}
	w.bits = 135000 // and one more second at 27 %
	assert roll(mut w, .running, 2000, at_500k)
	assert w.pct == f32(27.0)
	assert w.hist == [f32(27.0), 27, 27]
}

// AN IDLE STRETCH BEFORE A HANDOFF IS STILL OBSERVED: zero bits over its time, folded into
// the successor's first sample, which then reads what was seen and not the previous second
// carried on (codex #263 r9).
fn test_handoff_carries_an_idle_stretch_as_observed_time() {
	mut w := Wire{
		at:   1000
		pct:  27
		hist: [f32(27.0)]
	}
	handoff(mut w, 1500)
	assert w.pct == 27, 'the number stands until a sample closes'
	assert w.carry_ms == 500
	// 500 ms carried idle: closes 500 ms into the successor's own interval
	w.bits = 67500 // 13.5 % of a second; over the 1000 ms observed, 13.5 %
	assert roll(mut w, .running, 2000, at_500k)
	assert w.pct == f32(13.5)
	assert w.hist == [f32(27.0), 13.5]
}

// A ROW NOBODY READS DROPS ITS CARRY with the rest.
fn test_unread_row_drops_the_carry() {
	mut w := Wire{
		at:         1000
		carry_bits: 500
		carry_ms:   100
	}
	roll(mut w, .unread, 2000, at_500k)
	assert w.carry_bits == 0
	assert w.carry_ms == 0
}
