module cyclerule

// THE `cycle (ms)` COLUMN, AS A RULE. The trace's grouped view shows a message's cadence as
// the span its frames cover divided by the intervals between them — averaged over the window,
// because arrival stamps are host-side and a single interval mostly shows poll jitter. Two
// things make that average lie, and both are a window that spans a silence:
//
//   1. A Stop. The ring survives it, so the first frames of the next run were averaged with
//      the last frames of the previous one, the whole stopped gap inside the span: a 10 Hz
//      message read hundreds of ms after a minute's pause, converging only as the old rows
//      aged out of the 2000-row ring (2026-08-30).
//   2. A dropout mid-run — a node bus-off and back, a cable reseated — same shape without
//      a Stop to blame.
//
// So the window RESTARTS at a run boundary and at a gap out of proportion to the cadence seen
// so far. Pure over plain numbers, like ../taprule and ../saverule, so the scenarios are a
// test table rather than something to reproduce on a bench.

// Window is one group's cycle measurement: the frames it is averaging over.
pub struct Window {
pub:
	first_t f64 // stamp of the oldest frame in the measurement
	last_t  f64 // stamp of the newest
	count   int // frames in it; count-1 intervals
}

// gap_factor is how many cadences of silence break the window. A cyclic message's jitter is a
// fraction of its cycle, so five cycles is far outside anything a live sender does and well
// inside what a dropout worth knowing about lasts (a bus-off recovery alone is 128 x 11 bits).
pub const gap_factor = 5.0

// min_intervals is how many intervals the window needs before a gap can be judged against its
// average: one interval is not a cadence, and breaking on it would restart the window on the
// second frame of every burst.
pub const min_intervals = 2

// step folds one accepted frame at `t` into `w`. `new_run` says this frame is the first of the
// group in the current measurement — the caller knows it from row IDENTITY (a row's seq
// against the base Start/Clear/Load reset), never from comparing stamps: a loaded recording's
// rows are on the file's clock, and a Resume appends live rows behind them, so no stamp
// comparison can tell the two apart (codex on #266). A new run starts the window over; frames
// from BEFORE it are averaged among themselves as before, so a group that stopped sending
// keeps its last cadence until its rows age out.
pub fn step(w Window, t f64, new_run bool) Window {
	if w.count == 0 || new_run || breaks(w, t) {
		return Window{t, t, 1}
	}
	return Window{w.first_t, t, w.count + 1}
}

// breaks reports whether the silence between the window's newest frame and one at `t` is out
// of proportion to the cadence the window has measured.
pub fn breaks(w Window, t f64) bool {
	if w.count - 1 < min_intervals {
		return false
	}
	avg := (w.last_t - w.first_t) / f64(w.count - 1)
	if avg <= 0 {
		return false
	}
	return t - w.last_t > gap_factor * avg
}

// cycle_ms is the window's cadence, or none with fewer than two frames — a single frame has no
// interval, and inventing one from "now" would show a cycle for a message that may never come
// again.
pub fn cycle_ms(w Window) ?f64 {
	if w.count < 2 {
		return none
	}
	span := w.last_t - w.first_t
	if span <= 0 {
		return none
	}
	return span / f64(w.count - 1)
}
