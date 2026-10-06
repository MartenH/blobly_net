module diaghold

fn test_autorefresh_waits_its_interval_and_for_the_press_in_flight() {
	assert autorefresh_due(true, true, false, 0, 500) // never read: at once
	assert !autorefresh_due(true, true, false, 1000, 1000 + autorefresh_ms - 1)
	assert autorefresh_due(true, true, false, 1000, 1000 + autorefresh_ms)
	assert !autorefresh_due(true, true, true, 0, 99_999) // a press is out
	assert !autorefresh_due(false, true, false, 0, 99_999) // the tick is off
	assert !autorefresh_due(true, false, false, 0, 99_999) // the tab is not on screen
}

fn test_an_unchanged_autorefresh_is_not_said() {
	assert !autorefresh_logged(true, false, 'U0401-00 0x2F', 'U0401-00 0x2F')
	assert autorefresh_logged(true, false, 'U0401-00 0x2F', 'U0401-00 0x2E')
	assert autorefresh_logged(true, true, 'x', 'x') // a failure is always said
	assert autorefresh_logged(false, false, 'x', 'x') // a press is always said
}

fn test_dtc_setting_off_switches_out_of_the_default_session_only() {
	assert dtc_setting_session(0, false) == 0x03 // unknown: establish one
	assert dtc_setting_session(0x01, false) == 0x03
	assert dtc_setting_session(0x03, false) == 0
	assert dtc_setting_session(0x02, false) == 0 // a non-default session serves it already
}

fn test_dtc_setting_on_never_switches() {
	for s in [u8(0), 0x01, 0x02, 0x03] {
		assert dtc_setting_session(s, true) == 0
	}
}

fn test_a_deferred_row_is_asked_only_of_the_target_it_was_clicked_on() {
	assert deferred_selection(false, false, 'a', 'a') == .none
	assert deferred_selection(true, true, 'a', 'a') == .wait
	assert deferred_selection(true, false, 'a', 'a') == .send
	// the combo moved while the press was out: never sent to the new target, busy or not
	assert deferred_selection(true, true, 'a', 'b') == .drop
	assert deferred_selection(true, false, 'a', 'b') == .drop
}
