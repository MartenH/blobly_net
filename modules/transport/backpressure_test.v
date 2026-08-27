module transport

// One vocabulary for "the adapter has no room". Every backend composes its message with
// `busy_error` and `send_waiting_for_room` reads it with `is_backpressure`, so a new backend cannot
// quietly opt out of being retried — which is what happened when the marker was `vector: busy` and
// PCAN's queue-full ended a frame permanently (codex round 2 on #217).
fn test_every_backend_says_busy_in_the_one_way_the_retry_loop_reads() {
	for who in ['Vector', 'PCAN', 'Kvaser'] {
		e := busy_error(who, 0x123)
		assert is_backpressure(e), '${who}: ${e.msg()}'
		// The vendor is still named for whoever reads the log; nothing matches on it.
		assert e.msg().contains(who)
		assert e.msg().contains('0x123')
	}
}

// AND ONLY THAT. A retry loop that treats every error as back-pressure spends its whole budget
// talking to an unplugged adapter, which is the mistake the loop's own comment records.
fn test_an_ordinary_failure_is_not_backpressure() {
	assert !is_backpressure(error('CAN_Write failed (0x8000000)'))
	assert !is_backpressure(error('canWrite failed (canStatus -13)'))
	assert !is_backpressure(error('Vector: the port is closed'))
}

// PCAN's write status is a BIT FIELD with the fault ladder ORed in, exactly as its read status is —
// so the verdict has to mask before it judges, or a degraded-but-working wire reports every send as
// a failure.
fn test_pcan_write_verdict_separates_the_ladder_from_the_frame() {
	assert pcan_write_verdict(0x00) == .sent
	// Degradations: the controller still transmits, so the frame went.
	assert pcan_write_verdict(0x04) == .sent // BUSLIGHT
	assert pcan_write_verdict(0x08) == .sent // BUSHEAVY/BUSWARNING
	assert pcan_write_verdict(0x40000) == .sent // BUSPASSIVE
	// BUSOFF is the rung where write and read must disagree: a controller off the bus sends nothing.
	assert pcan_write_verdict(0x10) == .failed
	// No room, in either buffer, alone or alongside a degradation.
	assert pcan_write_verdict(0x01) == .busy // XMTFULL
	assert pcan_write_verdict(0x80) == .busy // QXMTFULL
	assert pcan_write_verdict(0x80 | 0x08) == .busy
	// A real fault carrying a queue-full bit is a real fault, not something to retry.
	assert pcan_write_verdict(0x80 | 0x10) == .failed
	assert pcan_write_verdict(0x8000000) == .failed // ILLOPERATION
}
