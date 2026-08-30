module cyclerule

fn fold(ts []f64) Window {
	mut w := Window{}
	for t in ts {
		w = step(w, t, false)
	}
	return w
}

fn test_steady_cadence_is_the_window_average() {
	w := fold([0.0, 100, 201, 299, 400])
	assert w.count == 5
	assert cycle_ms(w)? == 100.0
}

fn test_one_frame_has_no_cycle() {
	assert cycle_ms(fold([50.0])) == none
}

fn test_a_stop_does_not_enter_the_span() {
	// 10 Hz, a minute stopped, then a Start: the pre-run frames are one window, the first
	// frame of the new run (the caller says so) starts another, and the cadence reads 100 on
	// the second frame — the stopped minute is in neither.
	mut w := fold([0.0, 100, 200])
	assert cycle_ms(w)? == 100.0 // pre-run frames still average among themselves
	

	w = step(w, 60_010, true)
	assert w.count == 1
	assert cycle_ms(w) == none
	w = step(w, 60_110, false)
	assert cycle_ms(w)? == 100.0
}

fn test_a_dropout_mid_run_restarts_the_window() {
	// 10 Hz, then 2 s of silence (20 cycles), then 10 Hz again.
	w := fold([0.0, 100, 200, 300, 2300, 2400, 2500])
	assert w.first_t == 2300
	assert w.count == 3
	assert cycle_ms(w)? == 100.0
}

fn test_jitter_is_not_a_gap() {
	// intervals of up to 4x the average stay in the window; five breaks it
	assert !breaks(Window{0, 200, 3, 100}, 200 + 400)
	assert breaks(Window{0, 200, 3, 100}, 200 + 501)
}

fn test_a_dropout_is_judged_on_one_interval() {
	// the ring was trimmed to two pre-dropout frames of a sparse group: the gap is judged
	// against the one interval left, so the recovered cadence shows and not 575 (codex on
	// #266, and the reason min_intervals is one)
	w := fold([100.0, 200, 2200, 2300, 2400])
	assert w.first_t == 2200
	assert cycle_ms(w)? == 100.0
}

fn test_one_stale_frame_before_a_dropout_is_dropped_once_the_cadence_is_known() {
	// the ring was trimmed to ONE pre-dropout frame: no interval to judge the gap by when the
	// recovery frame comes, so it is folded in — and dropped again on the next frame, once
	// the frames after it say what the cadence is (codex on #266)
	mut w := fold([100.0, 2200])
	assert cycle_ms(w)? == 2100.0 // honest with two frames: that is all it knows
	
	w = step(w, 2300, false)
	assert w.first_t == 2200
	assert cycle_ms(w)? == 100.0
	w = step(w, 2400, false)
	assert cycle_ms(w)? == 100.0
	assert w.count == 3
}

fn test_a_steady_head_interval_is_kept() {
	// the head is judged once and kept when it is in proportion; nothing is lost
	w := fold([0.0, 100, 200, 300])
	assert w.count == 4
	assert w.first_t == 0
}

fn test_a_short_first_interval_costs_one_restart_only() {
	// a burst (two frames 10 ms apart) then the real 100 ms cadence: the first real interval
	// is a "gap" against the burst, the window restarts, and converges on the next frame
	mut w := fold([0.0, 10, 110])
	assert w.count == 1
	w = step(w, 210, false)
	assert cycle_ms(w)? == 100.0
}

fn test_a_new_run_on_the_first_frame_is_just_a_first_frame() {
	// first run of the process: the flag on an empty window invents nothing
	w := step(step(Window{}, 5, true), 105, false)
	assert w.count == 2
	assert cycle_ms(w)? == 100.0
}

fn test_stamps_going_backwards_across_a_run_do_not_matter() {
	// a recording's rows are on the file's clock (say it ran 90 s); live rows appended after a
	// Start are on the app's (uptime 5 s). The boundary is the flag, not the stamps.
	mut w := fold([88_000.0, 89_000, 90_000])
	w = step(w, 5_010, true)
	w = step(w, 5_110, false)
	assert cycle_ms(w)? == 100.0
}
