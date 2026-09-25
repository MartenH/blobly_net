module timebase

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

// latency is a delivery delay in [lo, hi) nanoseconds.
fn (mut l Lcg) latency(lo i64, hi i64) i64 {
	return lo + i64(l.next() % u64(hi - lo))
}

fn abs64(v i64) i64 {
	return if v < 0 { -v } else { v }
}

// --- nothing observed ---

fn test_a_domain_maps_nothing_before_its_first_frame() {
	d := Domain{}
	if _ := d.map(123) {
		assert false, 'mapped a stamp with no estimate behind it'
	}
	assert d.observed() == 0
}

// --- the headline: the issue's own example ---

fn test_a_cyclic_frame_maps_back_to_its_true_cadence() {
	// #149 in one test. A 10 ms frame whose host receipts are 9.4 ms and 11.4 ms apart — the
	// scheduler jitter the trace printed — maps back to exactly 10.000 ms: the offset is the least
	// delayed delivery, and the deltas are the device's.
	mut d := Domain{}
	d.observe(1000 * ms, 5000 * ms + 900_000)
	d.observe(1010 * ms, 5010 * ms + 300_000)
	d.observe(1020 * ms, 5021 * ms + 700_000)
	t1 := d.map(1000 * ms) or { panic('none') }
	t2 := d.map(1010 * ms) or { panic('none') }
	t3 := d.map(1020 * ms) or { panic('none') }
	assert t2 - t1 == 10 * ms
	assert t3 - t2 == 10 * ms
	assert t2 == 5010 * ms + 300_000 // the smallest gap, 4000.3 ms
}

fn test_the_offset_is_the_smallest_gap_because_latency_is_only_added() {
	// Receipt is always after the wire, so the estimate is the least delayed delivery — never an
	// average, which would be late by the mean latency — and it is never early.
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

// --- exactness at the magnitudes real devices use ---

fn test_a_utc_nanosecond_epoch_keeps_its_deltas_exact() {
	// A CANsub stamps in UTC nanoseconds, ~1.7×10¹⁸ — past the 2⁵³ an f64 holds exactly, so through
	// floating point a stamp rounds to 256 ns. The host side is monotonic, ~10¹³. Every nanosecond
	// must survive; this is what keeps floating point out of the module for good.
	mut d := Domain{}
	hw0 := i64(1_758_780_000_000_000_000)
	host0 := i64(12_345_678_901_234)
	for i in 0 .. 50 {
		d.observe(hw0 + i64(i) * 10 * ms + 7, host0 + i64(i) * 10 * ms + 1 * ms)
	}
	a := d.map(hw0 + 7) or { panic('none') }
	b := d.map(hw0 + 10 * ms + 7) or { panic('none') }
	c := d.map(hw0 + 3) or { panic('none') }
	assert b - a == 10 * ms
	assert a - c == 4 // four nanoseconds, at 1.7×10¹⁸
}

// --- drift ---

fn test_fifty_ppm_over_an_hour_stays_inside_half_a_millisecond() {
	// Two crystals 50 ppm apart drift 180 ms in an hour, which is what a single fixed offset would
	// be wrong by at the end. The window follows it: the minimum is at most one window old, so the
	// error is bounded by 50 ppm × 10 s = 0.5 ms, plus the minimum latency.
	mut d := Domain{}
	mut r := Lcg{
		s: 42
	}
	offset := i64(123) * sec
	mut worst := i64(0)
	mut worst_fixed := i64(0)
	for i in 0 .. 36_000 { // one hour at 10 Hz
		hw := i64(i) * 100 * ms
		truth := offset + hw + hw / 20_000 // +50 ppm: the host runs fast of this device
		d.observe(hw, truth + r.latency(50_000, 2 * ms))
		if hw >= window_ns {
			got := d.map(hw) or { panic('none') }
			if abs64(got - truth) > worst {
				worst = abs64(got - truth)
			}
			if abs64(hw + offset - truth) > worst_fixed {
				worst_fixed = abs64(hw + offset - truth)
			}
		}
	}
	assert worst_fixed > 170 * ms // the problem is real at this magnitude…
	assert worst < 700_000 // …and the window keeps it to the bound: 0.5 ms drift + min latency
}

// --- clock steps: nothing is detected, so nothing can be detected wrongly ---

fn test_a_forward_step_is_adopted_at_once() {
	// The device clock jumps a minute ahead: every gap drops, and the first frame on the new clock
	// is the new minimum.
	mut d := Domain{}
	for i in 0 .. 100 {
		hw := i64(i) * 100 * ms
		d.observe(hw, hw + 5 * sec + 1 * ms)
	}
	jump := i64(60) * sec
	hw := i64(100) * 100 * ms
	d.observe(hw + jump, hw + 5 * sec + 1 * ms)
	got := d.map(hw + jump) or { panic('none') }
	assert got == hw + 5 * sec + 1 * ms
}

fn test_a_small_forward_step_does_not_tilt_anything() {
	// THE REVIEW'S THIRD FINDING, against the fitted-line design: a 1.5 s forward step after five
	// minutes of traffic — below the step threshold that design had — tilted the line and mapped
	// hundreds of ms wrong, both ways, for five minutes, with a fitted rate of −7500 ppm. With no
	// line there is nothing to tilt: the step is right from the first frame after it, and stays so.
	mut d := Domain{}
	for i in 0 .. 3000 {
		hw := i64(i) * 100 * ms
		d.observe(hw, hw + 9 * sec + 1 * ms)
	}
	step := i64(1500) * ms
	mut worst := i64(0)
	for i in 3000 .. 6000 {
		hw := i64(i) * 100 * ms
		d.observe(hw + step, hw + 9 * sec + 1 * ms)
		got := d.map(hw + step) or { panic('none') }
		if abs64(got - (hw + 9 * sec + 1 * ms)) > worst {
			worst = abs64(got - (hw + 9 * sec + 1 * ms))
		}
	}
	assert worst == 0
}

fn test_a_backward_step_heals_within_one_window() {
	// The one price of the design, pinned so it stays bounded. A PCAN channel re-initialised
	// mid-run restarts its stamps at zero: every gap RISES, and the old minimum lingers until its
	// samples leave the window. Mapped early meanwhile — by the size of the step — and right after.
	mut d := Domain{}
	host := i64(900) * sec
	for i in 0 .. 300 {
		d.observe(i64(i) * 100 * ms, host + i64(i) * 100 * ms + 1 * ms)
	}
	restart := host + 30 * sec
	for i in 0 .. 200 { // 20 s on the new clock
		d.observe(i64(i) * 100 * ms, restart + i64(i) * 100 * ms + 1 * ms)
	}
	got := d.map(199 * 100 * ms) or { panic('none') }
	assert got == restart + 199 * 100 * ms + 1 * ms
}

fn test_a_backward_step_maps_early_until_the_window_passes() {
	// The other half of the same statement, so the price cannot quietly grow: halfway through the
	// window the domain is still on the old minimum.
	mut d := Domain{}
	host := i64(900) * sec
	for i in 0 .. 300 {
		d.observe(i64(i) * 100 * ms, host + i64(i) * 100 * ms + 1 * ms)
	}
	restart := host + 30 * sec
	for i in 0 .. 50 { // 5 s on the new clock: half a window
		d.observe(i64(i) * 100 * ms, restart + i64(i) * 100 * ms + 1 * ms)
	}
	got := d.map(49 * 100 * ms) or { panic('none') }
	assert got < restart + 49 * 100 * ms
}

// --- the review's findings against the fitted-line design, as regression tests ---

fn test_a_stalled_sibling_thread_does_not_disturb_the_domain() {
	// THE REVIEW'S FIRST FINDING: two threads feed one domain at 10 ms each; one stalls 3 s and then
	// drains its backlog interleaved with the other's prompt frames. The fitted design re-anchored
	// 599 times from that one stall, alternating between the two threads' frames. Watched through a
	// FIXED stamp mapped after every single delivery, that is the estimate thrashing by three seconds
	// on each frame. Here a late delivery is only ever a HIGH gap, a high gap is never the minimum,
	// and the fixed stamp never moves.
	//
	// (Checking the prompt thread's own frame straight after it arrives would not see the thrash:
	// in the fitted design that frame had just re-anchored the domain onto itself.)
	mut d := Domain{}
	offset := i64(4) * sec
	for i in 0 .. 500 { // 5 s, both threads prompt
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	reference := i64(4990) * ms
	truth := reference + offset + 1 * ms
	for j in 0 .. 300 { // A stalled from 5.0 s and drains at 8.0 s, interleaved with B
		a_hw := 5 * sec + i64(j) * 10 * ms
		b_hw := 8 * sec + i64(j) * 10 * ms
		d.observe(a_hw, b_hw + offset + 1 * ms)
		assert (d.map(reference) or { panic('none') }) == truth
		d.observe(b_hw, b_hw + offset + 1 * ms)
		assert (d.map(reference) or { panic('none') }) == truth
	}
}

fn test_a_straggler_only_delays_the_heal_by_one_window() {
	// A pre-step frame still in flight after a backward step. The fitted design flipped back to the
	// old epoch on it and forward again on the next frame — a ONE-FRAME glitch, since its step
	// detection then re-anchored correctly. Stated plainly because it is the one scenario where that
	// design recovered faster: here the straggler is simply one more old-clock sample, and the heal
	// completes one window after it rather than one window after the step. Bounded, with nothing to
	// flip — and backward steps are the rare case (a PCAN channel re-initialised mid-run, which this
	// app never does: a reopen is a new run, and a new run is a new domain), where stalls and
	// backlogs, which that design got wrong, happen every day.
	mut d := Domain{}
	host := i64(900) * sec
	for i in 0 .. 300 {
		d.observe(i64(i) * 100 * ms, host + i64(i) * 100 * ms + 1 * ms)
	}
	restart := host + 30 * sec
	for i in 0 .. 30 {
		d.observe(i64(i) * 100 * ms, restart + i64(i) * 100 * ms + 1 * ms)
	}
	d.observe(i64(300) * 100 * ms, restart + 3 * sec + 1 * ms) // on the OLD clock, 3 s into the new
	for i in 30 .. 150 { // a further 12 s: past one window after the straggler
		d.observe(i64(i) * 100 * ms, restart + i64(i) * 100 * ms + 1 * ms)
	}
	got := d.map(149 * 100 * ms) or { panic('none') }
	assert got == restart + 149 * 100 * ms + 1 * ms
}

fn test_a_startup_backlog_converges_rather_than_stepping() {
	// THE REVIEW'S FIFTH FINDING: a driver queue holding frames from before the reader started. The
	// first frame delivered is ten seconds late; the backlog behind it arrives almost at once, each
	// frame less late than the last. The fitted design reported a clock step. Here each one is just
	// a better minimum, and the prompt frames that follow map exactly.
	mut d := Domain{}
	host_start := i64(50) * sec
	for i in 0 .. 1000 { // 10 s of backlog, all delivered within the first 100 ms
		hw := i64(i) * 10 * ms
		d.observe(hw, host_start + i64(i) * 100_000)
	}
	offset := host_start - 10 * sec + 100 * ms // from here on, frames are delivered in 1 ms
	for i in 1000 .. 1100 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	got := d.map(1099 * 10 * ms) or { panic('none') }
	assert got == 1099 * 10 * ms + offset + 1 * ms
}

fn test_a_collector_pause_moves_nothing() {
	// #299 measured collector pauses of 100–700 ms. A frame delivered after one is late, which is a
	// high gap, which is never the minimum.
	mut d := Domain{}
	for i in 0 .. 100 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + 4 * sec + 1 * ms)
	}
	d.observe(100 * 10 * ms, 100 * 10 * ms + 4 * sec + 700 * ms)
	got := d.map(100 * 10 * ms) or { panic('none') }
	assert got == 100 * 10 * ms + 4 * sec + 1 * ms
}

fn test_a_straggler_across_a_forward_step_is_placed_early_by_the_step() {
	// THE MIRROR OF THE BACKWARD-STEP PRICE, pinned so it is stated rather than discovered. One
	// domain has one offset, and after a forward step it describes the new clock — so a frame stamped
	// on the old one, delivered late, is placed early by the whole step. The estimate is right; that
	// frame cannot be placed by it.
	mut d := Domain{}
	for i in 0 .. 100 {
		hw := i64(i) * 100 * ms
		d.observe(hw, hw + 5 * sec + 1 * ms)
	}
	jump := i64(60) * sec
	d.observe(100 * 100 * ms + jump, 100 * 100 * ms + 5 * sec + 1 * ms) // the new clock
	late := i64(9950) * ms // stamped on the OLD clock, delivered 20 ms late
	d.observe(late, late + 5 * sec + 20 * ms)
	got := d.map(late) or { panic('none') }
	truth := late + 5 * sec + 1 * ms
	assert truth - got == jump - 0 // early by exactly the step
}

fn test_a_silence_longer_than_the_window_starts_afresh() {
	// Every slot expires on the first arrival after a silence longer than the window, so that frame
	// sets the estimate by itself. Prompt, it is right at once.
	mut d := Domain{}
	offset := i64(6) * sec
	for i in 0 .. 50 {
		hw := i64(i) * 100 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	hw := i64(4900) * ms + 3600 * sec
	d.observe(hw, hw + offset + 2 * ms)
	got := d.map(hw) or { panic('none') }
	assert got == hw + offset + 2 * ms
}

fn test_a_late_first_frame_after_a_silence_is_no_worse_than_its_receipt() {
	// THE STATED LIMIT, pinned. That lone first frame may itself have been delivered after a 700 ms
	// collector pause, and then it is the estimate: the burst is placed late by the pause — exactly
	// where host-receipt stamping put it before #149, and no later — until a prompt frame arrives.
	//
	// Carrying the old estimate across the silence would do better HERE, and was tried: it needed a
	// drift allowance, the minimum's true age, and a plausibility threshold, and it still could not
	// be reconciled with the backward-step bound — a step during the silence was carried past it.
	// A pause degrading to today's accuracy is the price; the same one a forward step pays when it
	// coincides with a pause (below), treated the same way.
	mut d := Domain{}
	offset := i64(6) * sec
	for i in 0 .. 50 {
		hw := i64(i) * 100 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	hw := i64(4900) * ms + 15 * sec
	receipt := hw + offset + 700 * ms
	d.observe(hw, receipt)
	assert (d.map(hw) or { panic('none') }) == receipt // no better than receipt, and no worse
	d.observe(hw + 10 * ms, hw + 10 * ms + offset + 1 * ms) // a prompt frame
	assert (d.map(hw) or { panic('none') }) == hw + offset + 1 * ms // right from here
}

fn test_a_copied_domain_is_independent() {
	// THE REVIEW'S FIRST FINDING AGAINST THIS DESIGN. The ring was a slice, and V copies a slice's
	// header and not its data — so `mut b := a` shared one ring between two estimates, and each
	// corrupted the other at its next slide. A fixed array is copied whole.
	mut a := Domain{}
	for i in 0 .. 20 {
		hw := i64(i) * 100 * ms
		a.observe(hw, hw + 5 * sec + 1 * ms)
	}
	mut b := a
	b.observe(2 * sec, 2 * sec + 1 * sec) // a far lower gap, into b alone
	a.observe(2500 * ms, 2500 * ms + 5 * sec + 1 * ms) // a slides and recomputes
	assert (a.map(0) or { panic('none') }) == 5 * sec + 1 * ms
	assert (b.map(0) or { panic('none') }) == 1 * sec
}

fn test_a_small_forward_step_during_a_pause_waits_for_a_prompt_frame() {
	// CODEX ON #351. "Adopted at once" is true when the first post-step frame is delivered faster
	// than the step. A 100 ms step coinciding with a 700 ms pause is not: every gap still sits above
	// the old minimum, so the frames delivered through the pause are placed 100 ms late — within
	// their receipts — until a prompt frame arrives and the step is adopted.
	//
	// NOT fixed by detecting the step, which is what codex suggested and what this module was first
	// written with: that detector is where 599 phantom steps from one 3 s stall came from.
	mut d := Domain{}
	offset := i64(5) * sec
	for i in 0 .. 100 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + offset + 1 * ms)
	}
	step := i64(100) * ms
	hw := i64(1000) * ms
	truth := hw + offset // after the step the device reads `hw + step` at this instant
	d.observe(hw + step, truth + 700 * ms)
	got := d.map(hw + step) or { panic('none') }
	assert got == truth + step + 1 * ms // late by the step, still before its 700 ms receipt
	d.observe(hw + step + 10 * ms, truth + 10 * ms + 1 * ms) // a prompt frame
	assert (d.map(hw + step + 10 * ms) or { panic('none') }) == truth + 10 * ms + 1 * ms
}

fn test_an_old_stamp_is_early_by_drift_times_its_own_latency_and_no_more() {
	// CODEX ROUND 2 ON #351. `map` applies TODAY'S offset, so a backlog frame whose stamp is a minute
	// old gets today's clock phase applied to a minute-old device time. With the device running
	// 50 ppm fast of the host, that places it ~3 ms early — well past one window's drift, which is
	// what the guarantee first claimed.
	//
	// The bound that does hold, and is stronger: a stamp mapped ON ARRIVAL is old by exactly its own
	// delivery latency, so its early error is drift × latency — parts per million of how late
	// host-receipt stamping put the same frame. A minute-old backlog frame: 3 ms early here, where the
	// trace used to put it 60 s late. Correcting even the 3 ms would mean estimating the rate, which is
	// the fitted line this module was rewritten without.
	mut d := Domain{}
	offset := i64(8) * sec
	// the device runs 50 ppm FAST: host − hw falls as time goes on
	host_of := fn [offset] (hw i64) i64 {
		return offset + hw - hw / 20_000
	}
	for i in 0 .. 120_000 { // a sibling thread keeps the estimate current for two minutes
		hw := i64(i) * 1 * ms
		d.observe(hw, host_of(hw) + 100_000)
	}
	stale := i64(60) * sec // a frame stamped a minute ago…
	receipt := host_of(120 * sec) + 100_000 // …delivered now, by a thread that was stuck
	got := d.place(stale, receipt)
	truth := host_of(stale)
	early := truth - got
	latency := receipt - truth
	assert got <= receipt // the floor, as ever
	assert early > 2 * ms // the cost is real at this age…
	assert early <= latency / 20_000 // …and is drift × the frame's own latency, no more
}

fn test_a_frame_whose_observation_is_too_late_is_still_not_placed_after_its_receipt() {
	// CODEX ROUND 3 ON #351. A receive thread reads the clock and then waits more than a window for
	// the lock, while a sibling advances the domain — here across a backward step, so the offset
	// RISES. observe() rejects the frame as too old, its gap never enters the window, and the current
	// offset would place it well after the moment it was received. place() is bounded by the receipt
	// itself, so whatever the window has done since, the frame cannot land later than its own receipt.
	mut d := Domain{}
	for i in 0 .. 100 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + 4 * sec + 1 * ms)
	}
	// a thread reads its clock here, stamping this frame's receipt…
	hw := i64(1000) * ms
	receipt := hw + 4 * sec + 1 * ms
	// …and before it gets the lock, 12 s pass with the device clock set back 30 s
	for i in 0 .. 1200 {
		h := i64(i) * 10 * ms
		d.observe(h, h + 4 * sec + 30 * sec + 12 * sec + 1 * ms)
	}
	unbounded := d.map(hw) or { panic('none') }
	assert unbounded > receipt // what the estimate alone would say — after the frame was received
	assert d.place(hw, receipt) == receipt // bounded by the receipt, as promised
}

fn test_within_an_epoch_a_frame_is_never_early_and_never_later_than_its_receipt() {
	// THE GUARANTEE, as a property over two hundred thousand frames with random latency, collector
	// pauses and dropped observations: mapped on arrival, every frame sits between its true wire time
	// and the moment our thread saw it. NEVER WORSE THAN HOST-RECEIPT STAMPING, because the frame's
	// own gap is in the window, so the minimum can be no larger than it — the floor #149 promised.
	// And never early, which holds exactly here because there is no drift; with drift, a stamp
	// mapped on arrival is early by at most drift × its own delivery latency (the test above).
	mut d := Domain{}
	mut r := Lcg{
		s: 7
	}
	offset := i64(9) * sec
	for i in 0 .. 200_000 {
		hw := i64(i) * 1 * ms // 1 kHz
		mut lat := r.latency(0, 2 * ms)
		if r.next() % 5000 == 0 {
			lat += 700 * ms
		}
		if r.next() % 20_000 == 0 {
			continue
		}
		truth := hw + offset
		receipt := truth + lat
		got := d.place(hw, receipt)
		assert got >= truth
		assert got <= receipt
	}
}

// --- the window's mechanics ---

fn test_a_sample_delivered_out_of_host_order_still_counts() {
	// Several receive threads read the clock and then race for the lock, so a sample can arrive
	// carrying a host time a slot behind the newest. Filed under its own slot, it can still be the
	// minimum.
	mut d := Domain{}
	d.observe(0, 3 * sec + 5 * ms)
	d.observe(200 * ms, 3 * sec + 200 * ms + 5 * ms) // slot advances
	d.observe(50 * ms, 3 * sec + 50 * ms + 1 * ms) // earlier slot, better gap
	got := d.map(0) or { panic('none') }
	assert got == 3 * sec + 1 * ms
}

fn test_an_out_of_order_sample_leaves_the_window_on_its_own_schedule() {
	// Filed under ITS slot, not the newest, so it expires one window after its own HOST time. Filed
	// under the newest it would outstay that by however far out of order it arrived — and a minimum
	// that outstays the window is how a backward step goes on mapping early after it should have
	// healed. The arrival is at the very edge: slot 0 while the newest is slot 99, one inside.
	//
	// Written in HOST time throughout, because that is what the window slides by: placed by the
	// device's stamps instead, the sample lands outside the window and is ignored — correctly, and
	// the first version of this test asserted otherwise.
	mut d := Domain{}
	newest := i64(slots - 1) * slot_ns
	d.observe(newest - 5 * sec, newest) // slot 99, gap 5 s
	d.observe(-3 * sec, 0) // slot 0, out of order: gap 3 s, the best
	assert (d.map(0) or { panic('none') }) == 3 * sec
	// one slot later, slot 0 has left the window, and its gap with it
	d.observe(i64(slots) * slot_ns - 5 * sec, i64(slots) * slot_ns)
	assert (d.map(0) or { panic('none') }) == 5 * sec
}

fn test_a_sample_older_than_the_window_is_ignored() {
	mut d := Domain{}
	d.observe(20 * sec, 20 * sec + 3 * sec + 2 * ms)
	d.observe(1 * sec, 1 * sec + 3 * sec) // host 4 s: sixteen seconds behind the newest
	got := d.map(0) or { panic('none') }
	assert got == 3 * sec + 2 * ms
	assert d.observed() == 2
}

fn test_a_quiet_domain_keeps_its_estimate() {
	// Nothing expires while nothing arrives: a domain that goes quiet for a minute still maps, on
	// the estimate it had. The window only slides when a frame comes.
	mut d := Domain{}
	for i in 0 .. 50 {
		hw := i64(i) * 10 * ms
		d.observe(hw, hw + 2 * sec + 1 * ms)
	}
	got := d.map(90 * sec) or { panic('none') }
	assert got == 90 * sec + 2 * sec + 1 * ms
}

fn test_a_negative_host_time_is_slotted_by_flooring() {
	// V's `/` and `%` truncate toward zero. For −150 ms that files the sample in slot −1 instead of
	// −2 — so it would outstay the window by a slot — and a plain `%` on a negative slot is a
	// negative ring index: a panic, not a wrong answer. A monotonic clock is never negative, but a
	// caller subtracting a base can be.
	//
	// −150 ms and not −5 ms, which is what this first used: that truncates to slot 0, where
	// flooring and truncation agree, so the test passed with the rule removed.
	mut d := Domain{}
	d.observe(-3 * sec - 150 * ms, -150 * ms) // slot −2, the best gap: 3 s
	d.observe(97 * slot_ns - 5 * sec, 97 * slot_ns) // slot 97: slot −2 is still inside
	assert (d.map(0) or { panic('none') }) == 3 * sec
	d.observe(98 * slot_ns - 5 * sec, 98 * slot_ns) // slot 98: slot −2 has just left
	assert (d.map(0) or { panic('none') }) == 5 * sec
}
