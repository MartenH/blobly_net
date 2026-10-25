module tickrule

fn test_the_tick_shows_the_project_bit() {
	assert tick(true, true, true) == Tick{
		ticked: true
	}
	assert tick(false, false, false) == Tick{
		ticked: false
	}
}

fn test_a_retired_row_stays_ticked_and_says_so() {
	// the #287 case: the run retired the row, the project still opens it
	t := tick(true, false, true)
	assert t.ticked
	assert t.note.contains('retired for this run')
	after := tick(true, false, false)
	assert after.ticked
	assert after.note.contains('Start opens it again')
}

fn test_an_unticked_row_is_not_retired() {
	assert tick(false, false, true).note == ''
	assert tick(false, true, false).note == ''
}
