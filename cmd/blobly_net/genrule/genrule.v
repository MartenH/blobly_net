module genrule

// WHAT A GUI GENERATOR ASKS BEFORE IT SENDS (#691). The GUI's generators are entries of a
// cyclic.Wire per destination, as a headless run's are; the grid — the slots, the ones left out,
// a fire between two of them (cyclic.Grid) — and the J1939 transfer (cyclic.Tp) are blobly's and
// shared. What is left here reads what only the GUI holds — its transmit taps, its rows, its
// edits — and lived inside gen_loop, untested, until the move: when a cycle may send, when the
// frame it built last is stale, how a failure is said, and when an entry asks the GUI again
// rather than trusting what it read last.

// look_every_ms bounds how long an entry trusts what it last read of the GUI: every change it
// reads (a trigger, a cycle, a tap filed or failed, a row retired) moves the GUI's revision and
// so asks again at once; this only bounds a change that moved nothing.
pub const look_every_ms = u64(1000)

// departed is whether a generator's target has LEFT THE RUN: its destination has rows (`rows`
// of them) and none is enabled (`enabled`), which is what a run does to a wire whose adapter
// failed. A target no row names (a wire opened only as a tap) has left nothing, and neither has
// one nobody reads: both are still sent to.
pub fn departed(rows int, enabled int) bool {
	return rows > 0 && enabled == 0
}

// armed is whether a generator's cycle may send: its trigger cyclic with a cycle, its tap up
// (taprule.ready: no frame before it, #257), and its target still in the run.
pub fn armed(cyclic bool, tap_ready bool, gone_from_run bool) bool {
	return cyclic && tap_ready && !gone_from_run
}

// stale is whether the frame a generator built last must be built afresh: none built yet
// (`built` false), an edit since (`built_edits` the edits it was built after, `edits` now), or
// one whose next frame may differ (`varies`: a signal on a value source). Otherwise the frame is
// sent again as it is, which is what lets a static generator send without garbage.
pub fn stale(built bool, built_edits u64, edits u64, varies bool) bool {
	return !built || built_edits != edits || varies
}

// says is whether a cycle's send that ended `why` ('' sent) is said: a failure, once while it
// repeats (`last` the cycle's previous outcome), so a generator on a dead wire is one line and
// not one per frame. A fire's failure is always said: somebody pressed for it.
pub fn says(last string, why string) bool {
	return why != '' && why != last
}

// relook is whether an entry asks the GUI again at `now` (ms): it never has (`looked` false),
// the GUI's revision moved since (`seen` what it was then, `rev` now), or look_every_ms passed
// since it last did (`at`).
pub fn relook(looked bool, seen u64, rev u64, now u64, at u64) bool {
	return !looked || seen != rev || now >= at + look_every_ms
}
