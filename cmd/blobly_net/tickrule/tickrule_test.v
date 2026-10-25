module tickrule

fn test_the_tick_shows_the_project_bit() {
	assert tick(true, false, true) == Tick{
		ticked: true
	}
	assert tick(false, false, false) == Tick{
		ticked: false
	}
}

fn test_a_retired_row_stays_ticked_and_says_so() {
	// the #287 case: the run retired the row, the project still opens it
	t := tick(true, true, true)
	assert t.ticked
	assert t.note.contains('retired for this run')
	after := tick(true, true, false)
	assert after.ticked
	assert after.note.contains('Start opens it again')
}

fn test_an_unticked_row_says_no_retirement() {
	// unticked by the operator after the retirement: the next run does not open it either way
	assert tick(false, true, true) == Tick{
		ticked: false
	}
}
