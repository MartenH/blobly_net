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

fn t(rtt i64, pending int, pending_us i64) Timing {
	return Timing{
		sent:       true
		rtt_us:     rtt
		pending:    pending
		pending_us: pending_us
	}
}

fn test_a_refused_counter_read_leaves_its_row_and_the_batch_goes_on() {
	mut b := CounterBatch{}
	b.answered(t(1000, 0, 0))
	b.refusal(t(800, 0, 0), 'NRC 0x31', nrc_per_dtc(0x31))
	assert b.going()
	b.answered(t(900, 0, 0))
	b.refusal(t(700, 0, 0), 'undecodable', true)
	assert b.going()
	assert b.read == 2 && b.refused == 2 && b.asked() == 4
	assert b.summary() == '2 refused, the first: NRC 0x31'
	b.failure(t(0, 0, 0), 'timeout')
	assert !b.going() // the connection failing ends it
	// the refusals before it are still said
	assert b.summary() == '2 refused, the first: NRC 0x31; timeout'
}

fn test_a_refusal_of_the_service_ends_the_batch() {
	for nrc in [u8(0x11), 0x12, 0x13, 0x22, 0x33, 0x7E, 0x7F] {
		assert !nrc_per_dtc(nrc)
		mut b := CounterBatch{}
		b.refusal(t(10, 0, 0), 'NRC 0x${nrc:02X}', nrc_per_dtc(nrc))
		assert !b.going()
		assert b.failed == '' // the ECU answered: the connection is kept
		assert b.summary() == 'NRC 0x${nrc:02X}; the rest not asked'
	}
}

fn test_a_single_refusal_is_said_as_itself() {
	mut b := CounterBatch{}
	assert b.summary() == ''
	b.refusal(t(10, 0, 0), 'NRC 0x31', true)
	assert b.summary() == 'NRC 0x31'
}

fn test_the_batch_time_sums_the_0x78_waits_too() {
	mut b := CounterBatch{}
	b.answered(t(1000, 0, 0))
	b.answered(t(50_000, 2, 40_000))
	b.refusal(t(30_000, 1, 20_000), 'NRC 0x31', true)
	assert b.t.sent
	assert b.t.rtt_us == 81_000
	assert b.t.pending == 3
	assert b.t.pending_us == 60_000
	assert b.t.prefix().contains('0x78 ×3 for 60.0 ms')
}

fn test_the_signature_is_what_the_table_shows() {
	none_read := dtc_sig_entry(0x123456, 0x2F, '')
	absent := dtc_sig_entry(0x123456, 0x2F, '—/—/—')
	zero := dtc_sig_entry(0x123456, 0x2F, '0/—/—')
	assert none_read != absent // no answer, or an answer without the records
	assert absent != zero // '—' became '0'
	assert dtc_sig_entry(0x123456, 0x2F, '3/—/—') != zero
	assert dtc_sig_entry(0x123456, 0x2E, '0/—/—') != zero
}

fn test_the_detail_shows_the_newer_status() {
	// read after the list: the detail answer's
	s1, own1 := shown_status(0x2F, 1000, true, 0x2E, 2000)
	assert s1 == 0x2E && own1
	// a list read since (an auto-refresh): the list's
	s2, own2 := shown_status(0x2C, 3000, true, 0x2E, 2000)
	assert s2 == 0x2C && !own2
	// nothing answered for the detail: the list's
	s3, own3 := shown_status(0x2F, 1000, false, 0x00, 2000)
	assert s3 == 0x2F && !own3
}

fn test_a_failed_refresh_does_not_make_old_rows_fresh() {
	r := read_at(1000)
	assert r.read_ms == 1000 && r.tried_ms == 1000
	f := r.failed(5000)
	assert f.read_ms == 1000 // "read N s ago" still says the rows' own age
	assert f.tried_ms == 5000 // the auto-refresh waits from the attempt
	assert read_at(9000).read_ms == 9000
	assert ReadTimes{}.failed(7).read_ms == 0 // never read
}

fn test_a_read_asked_of_the_previous_project_is_not_published() {
	assert view_writable(4, 4)
	assert !view_writable(3, 4)
}
