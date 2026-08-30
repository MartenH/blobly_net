module cyclerule

fn fold(ts []f64, run_start f64) Window {
	mut w := Window{}
	for t in ts {
		w = step(w, t, run_start)
	}
	return w
}

fn test_steady_cadence_is_the_window_average() {
	w := fold([0.0, 100, 201, 299, 400], 0)
	assert w.count == 5
	assert cycle_ms(w)? == 100.0
}

fn test_one_frame_has_no_cycle() {
	assert cycle_ms(fold([50.0], 0)) == none
}

fn test_a_stop_does_not_enter_the_span() {
	// 10 Hz, a minute stopped, run restarts at t=60_000: the pre-run frames are one window,
	// the first post-run frame starts another, and the cadence reads 100 on the second frame.
	mut w := fold([0.0, 100, 200], 60_000)
	assert cycle_ms(w)? == 100.0 // pre-run frames still average among themselves
	w = step(w, 60_010, 60_000)
	assert w.count == 1
	assert cycle_ms(w) == none
	w = step(w, 60_110, 60_000)
	assert cycle_ms(w)? == 100.0
}

fn test_a_dropout_mid_run_restarts_the_window() {
	// 10 Hz, then 2 s of silence (20 cycles), then 10 Hz again.
	w := fold([0.0, 100, 200, 300, 2300, 2400, 2500], 0)
	assert w.first_t == 2300
	assert w.count == 3
	assert cycle_ms(w)? == 100.0
}

fn test_jitter_is_not_a_gap() {
	// intervals of up to 4x the average stay in the window; five breaks it
	assert !breaks(Window{0, 200, 3}, 200 + 400)
	assert breaks(Window{0, 200, 3}, 200 + 501)
}

fn test_a_gap_is_not_judged_before_two_intervals() {
	// two frames 100 apart, then one 10 s later: with one interval nothing is a cadence yet,
	// so the window keeps all three and reports their (honest) average
	w := fold([0.0, 100, 10_100], 0)
	assert w.count == 3
	assert cycle_ms(w)? == 5050.0
	// ...and the next frame at the true cadence breaks it against that inflated average only
	// once it is out of proportion — it is not, so the window keeps converging honestly
	w2 := step(w, 10_200, 0)
	assert w2.count == 4
}

fn test_run_boundary_with_nothing_before_it() {
	// first run of the process: nothing precedes run_start, no reset is invented
	w := fold([5.0, 105, 205], 0)
	assert w.count == 3
}
