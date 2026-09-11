module panerule

// The scenarios of codex #305 r2 (System panel) and #306 (Discover, Script), as a table.

fn test_an_unset_pane_takes_the_default_and_stores_it_unscaled() {
	h, stored := drawn(0, 160, 1.5, 60, 1000)
	assert stored == 160
	assert h == 240
}

fn test_a_short_dock_clamps_the_frame_and_not_the_stored_value() {
	// the container has room for 250 above its reserve
	h, stored := drawn(400, 160, 1.0, 60, 250)
	assert h == 250
	assert stored == 400
	// the splitter hands back the clamped value: nothing was dragged, nothing is persisted
	kept, was_drag := dragged(stored, h, 250, 1.0)
	assert kept == 400
	assert !was_drag
	// and when the room comes back, so does the pane
	h2, _ := drawn(stored, 160, 1.0, 60, 1000)
	assert h2 == 400
}

fn test_a_drag_persists_unscaled() {
	h, stored := drawn(160, 160, 2.0, 60, 1000)
	assert h == 320
	after, was_drag := dragged(stored, h, 500, 2.0) // dragged to 500 device px at 200%
	assert after == 250
	assert was_drag
	h2, _ := drawn(after, 160, 1.0, 60, 1000)
	assert h2 == 250 // at 100% the same proportion
}

fn test_a_dock_shorter_than_the_minimum_gives_the_minimum() {
	h, stored := drawn(300, 160, 1.0, 60, 20)
	assert h == 60
	assert stored == 300
	h2, _ := drawn(300, 160, 1.0, 60, -50)
	assert h2 == 60
}

fn test_a_stored_value_below_the_minimum_is_raised_for_the_frame_only() {
	h, stored := drawn(10, 160, 1.0, 60, 1000)
	assert h == 60
	assert stored == 10
}
