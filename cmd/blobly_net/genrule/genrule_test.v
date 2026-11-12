module genrule

// a target whose rows were all retired has left the run; one with no rows, or one row still
// enabled, has not — and a target nobody reads is not a departed one
fn test_only_a_target_whose_rows_all_left_the_run_has_departed() {
	assert departed(2, 0)
	assert departed(1, 0)
	assert !departed(2, 1)
	assert !departed(1, 1)
	// a wire no row names: opened as a tap on purpose, still sent to
	assert !departed(0, 0)
}

// a cycle sends only cyclic, with its tap up, and onto a target still in the run
fn test_a_cycle_is_armed_only_cyclic_with_its_tap_up_and_its_target_in_the_run() {
	assert armed(true, true, false)
	assert !armed(false, true, false), 'manual or on-key: never on a cycle'
	assert !armed(true, false, false), 'no frame before its tap is up (#257)'
	assert !armed(true, true, true), 'not onto a wire that left the run'
}

// the frame is built again on the first send, after an edit, and every send of one that varies;
// otherwise the frame built last goes out as it is
fn test_a_frame_is_built_again_only_when_something_it_is_built_from_changed() {
	assert stale(false, 0, 0, false), 'nothing built yet'
	assert !stale(true, 3, 3, false), 'built after every edit there is: sent again as it is'
	assert stale(true, 3, 4, false), 'an edit since: a value, a source, the payload, the message, the format'
	assert stale(true, 3, 3, true), 'a value source: the next frame may differ'
	// edits move one way only, but the comparison is equality: a reset counter is an edit too
	assert stale(true, 4, 0, false)
}

// a cycle's failure is said once while it repeats, and again when it changes; a send that went
// out says nothing
fn test_a_cycles_failure_is_said_once_while_it_repeats() {
	assert says('', 'TX failed: no open bus for vcan9')
	assert !says('TX failed: no open bus for vcan9', 'TX failed: no open bus for vcan9')
	assert says('TX failed: no open bus for vcan9', 'TX failed: run ended')
	assert !says('TX failed: run ended', '')
	assert !says('', '')
}

// an entry asks again the first time, when the GUI's revision moved, and once a second at most
// otherwise
fn test_an_entry_asks_the_gui_again_on_a_revision_or_a_second() {
	assert relook(false, 0, 0, 10, 0)
	assert !relook(true, 5, 5, 999, 0)
	assert relook(true, 5, 6, 1, 0)
	assert relook(true, 5, 5, look_every_ms, 0)
	assert !relook(true, 5, 5, 2 * look_every_ms - 1, look_every_ms)
}
