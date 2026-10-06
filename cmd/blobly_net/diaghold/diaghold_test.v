module diaghold

fn held(key string) View {
	return View{
		held_key: key
		selected_key: key
		panel_open: true
		run_live: true
	}
}

// --- release ---
fn test_a_held_connection_on_the_selected_target_is_kept() {
	assert release(held('doip:A')) == .keep
}

fn test_nothing_held_is_nothing_to_release() {
	assert release(View{}) == .keep
	assert release(View{ command: .disconnect, tool_running: true }) == .keep
}

fn test_each_reason_on_its_own() {
	assert release(View{ ...held('a'), selected_key: 'b' }) == .deselected
	assert release(View{ ...held('a'), panel_open: false }) == .panel_closed
	assert release(View{ ...held('a'), run_live: false }) == .run_ended
	assert release(View{ ...held('a'), command: .disconnect }) == .disconnect
	assert release(View{ ...held('a'), command: .tool }) == .tool
	assert release(View{ ...held('a'), tool_running: true }) == .tool
}

// A Stop overrules everything else that is also true: the strip says the reason that reached
// furthest, and a Stop is not the operator's Disconnect.
fn test_the_run_ending_overrules_every_other_reason() {
	v := View{
		held_key: 'a'
		selected_key: 'b'
		panel_open: false
		run_live: false
		command: .disconnect
		tool_running: true
	}
	assert release(v) == .run_ended
}

fn test_an_explicit_disconnect_is_said_even_when_the_panel_also_closed() {
	assert release(View{ ...held('a'), command: .disconnect, panel_open: false }) == .disconnect
}

// A tool that starts while a press is in flight: the request it was opened for ends, and the
// connection goes with it rather than surviving into the tool's run.
fn test_a_running_tool_releases_whatever_else_holds() {
	assert release(View{ ...held('a'), tool_running: true, panel_open: false }) == .tool
}

fn test_every_release_has_words_and_keep_has_none() {
	assert Release.keep.words() == ''
	for r in [Release.run_ended, .disconnect, .tool, .panel_closed, .deselected] {
		assert r.words() != ''
	}
}

// --- keep-alive ---
fn test_keepalive_only_in_a_known_non_default_session() {
	assert !keepalive_due(true, default_session, 0, 10_000)
	assert !keepalive_due(true, 0, 0, 10_000) // nothing answered 0x10 on this connection
	

	assert keepalive_due(true, 0x03, 0, 10_000)
	assert keepalive_due(true, 0x02, 0, 10_000)
}

fn test_keepalive_never_without_a_connection() {
	assert !keepalive_due(false, 0x03, 0, 10_000)
}

fn test_keepalive_period_runs_from_the_last_thing_sent() {
	assert !keepalive_due(true, 0x03, 1000, 1000 + keepalive_ms - 1)
	assert keepalive_due(true, 0x03, 1000, 1000 + keepalive_ms)
}

// The period must sit below the default S3server (5000 ms) with room for a carrier's latency,
// or the session it exists to keep lapses between two keep-alives.
fn test_keepalive_period_is_well_inside_s3() {
	assert keepalive_ms * 2 <= 5000
}

fn test_session_names() {
	assert session_name(0) == '—'
	assert session_name(0x01) == 'default'
	assert session_name(0x02) == 'programming'
	assert session_name(0x03) == 'extended'
	assert session_name(0x60) == '0x60'
}

// --- timing text ---
fn test_a_plain_request_prints_its_round_trip() {
	assert Timing{ sent: true, rtt_us: 3149 }.prefix() == '[   3.1 ms]'
	assert Timing{ sent: true, rtt_us: 12_345_678 }.prefix() == '[12345.7 ms]'
}

// a request that failed before the send has no round trip: it says so rather than '0.0 ms'
fn test_a_request_that_never_went_out_has_no_round_trip() {
	assert Timing{ rtt_us: 0 }.prefix() == '[not sent]'
	assert Timing{ rtt_us: 5000, pending: 1 }.prefix() == '[not sent]'
}

fn test_a_pending_wait_is_said_with_its_count_and_length() {
	t := Timing{
		sent: true
		rtt_us: 1_503_200
		pending: 2
		pending_us: 1_490_000
	}
	assert t.prefix() == '[1503.2 ms, 0x78 ×2 for 1490.0 ms]'
}

fn test_a_doip_open_tells_connect_and_routing_activation_apart() {
	o := Open{
		doip: true
		total_us: 441_500
		connect_us: 1_300
		activate_us: 440_200
	}
	assert o.line('doip 192.168.0.50:13400') == '[ 441.5 ms] opened doip 192.168.0.50:13400: connect 1.3 ms, routing activation 440.2 ms'
}

fn test_an_isotp_open_has_only_its_total() {
	assert Open{ total_us: 200 }.line('ISO-TP on vcan0') == '[   0.2 ms] opened ISO-TP on vcan0'
}

// --- a connection found dead before the send ---
fn test_a_request_that_never_went_out_on_a_stale_connection_is_retried_once() {
	assert retry_on_reopen(true, true, 0, false)
}

fn test_a_request_that_went_out_is_never_repeated() {
	assert !retry_on_reopen(true, true, 1, false)
}

// A clear sent and answered, then the refresh after it finds the connection closed before ITS
// send: the press is not retried, so the clear is not sent a second time unconfirmed. The refresh
// failing unsent is what `last` would say; the press's count says the clear went out.
fn test_a_completed_step_of_a_press_is_never_replayed() {
	clear_then_refresh := 1 // the 0x14 reached the carrier; the 0x19 02 never did
	assert !retry_on_reopen(true, true, clear_then_refresh, false)
	assert !retry_on_reopen(true, true, 2, false) // a session switch and its 0x85
}

fn test_a_fresh_connection_that_fails_is_not_retried() {
	assert !retry_on_reopen(true, false, 0, false)
}

fn test_a_negative_response_is_an_answer_not_a_failure() {
	assert !retry_on_reopen(true, true, 0, true)
	assert !retry_on_reopen(true, true, 1, true)
}

// a CAN send refused before it went out (listen-only, a wire that is down, a busy response id) is
// not a stale connection: CAN holds none between exchanges, and repeating it would hide the error
fn test_a_can_failure_is_never_retried() {
	assert !retry_on_reopen(false, true, 0, false)
}

fn test_a_keepalive_listens_far_less_than_its_period() {
	assert keepalive_wait_ms * 5 <= keepalive_ms
}


// --- commands and the token ---

fn test_a_holder_handles_only_its_own_generations_commands() {
	mut c := Commands{}
	t := c.issue(2, .disconnect, '')
	assert c.pending(2, 0)
	assert !c.pending(1, 0) // the old holder never consumes the new one's Disconnect
	assert !c.pending(2, t.seq) // handled
	assert !c.cancels(1, 0, true, 'a')
	assert c.cancels(2, 0, true, 'a')
}

fn test_no_holder_is_nothing_to_command() {
	mut c := Commands{}
	assert c.issue(0, .tool, '') == Ticket{}
	assert !c.pending(0, 0)
}

fn test_a_target_change_keeps_the_new_target_only() {
	mut c := Commands{}
	c.issue(1, .deselected, 'b')
	assert c.releases(0, 'a') == .deselected
	assert c.releases(0, 'b') == .keep
	assert c.releases(0, '') == .keep
	assert c.cancels(1, 0, true, 'a')
	assert !c.cancels(1, 0, true, 'b')
}

// The defect the holder model found: a target change issued after a tool's release must not
// un-cancel the work the tool is waiting on.
fn test_a_newer_target_change_does_not_hide_an_older_release() {
	mut c := Commands{}
	c.issue(1, .tool, '')
	c.issue(1, .deselected, 'b')
	assert c.cancels(1, 0, true, 'b')
	assert c.releases(0, 'b') == .tool
}

fn test_the_run_ending_cancels_everything() {
	c := Commands{}
	assert c.cancels(1, 0, false, 'a')
}

fn test_commands_of_an_ended_generation_are_dropped() {
	mut c := Commands{}
	c.issue(1, .tool, '')
	t := c.issue(2, .deselected, 'b')
	assert !c.cancels(2, 0, true, 'b')
	assert t.seq == 2 // numbering continues across generations
}

fn test_a_tool_starts_once_its_holder_released_or_left() {
	mut c := Commands{}
	t := c.issue(3, .tool, '')
	assert !tool_may_start(1, 3, Mark{3, t.seq - 1}, t)
	assert tool_may_start(1, 3, Mark{3, t.seq}, t)
	assert tool_may_start(0, 0, Mark{}, t) // the holder exited
	assert !tool_may_start(1, 3, Mark{2, 99}, t) // another generation's release is not this one
	assert !tool_may_start(2, 3, Mark{3, t.seq}, t) // an older holder is still on its way out
	assert !tool_may_start(1, 0, Mark{}, Ticket{}) // a holder it did not command is alive
}

fn test_presses_wait_for_a_tool() {
	assert press_refusal(true, false, 0) == ''
	assert press_refusal(true, false, 1) != ''
	assert press_refusal(false, false, 0) != ''
	assert press_refusal(true, true, 0) == 'busy'
}

fn test_a_keepalive_answered_pending_fails() {
	assert keepalive_verdict(false, false, 0) == .ok
	assert keepalive_verdict(true, true, 0) == .refused
	assert keepalive_verdict(true, false, 0) == .failed
	assert keepalive_verdict(true, false, 1) == .pending
	assert keepalive_verdict(false, false, 1) == .pending
}
