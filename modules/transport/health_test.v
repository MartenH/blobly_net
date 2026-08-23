module transport

// Every constant here is transcribed from the vendor's header; the test pins the decode so a
// refactor cannot silently swap a mask. Worst-state-wins is asserted where flags combine.

fn test_pcan_status_ladder() {
	assert pcan_status_health(0) == .ok
	assert pcan_status_health(0x04) == .warning // BUSLIGHT
	assert pcan_status_health(0x08) == .warning // BUSHEAVY
	assert pcan_status_health(0x40000) == .error_passive
	assert pcan_status_health(0x10) == .bus_off
	// worst wins when combined: a controller going off often carries the lower bits too
	assert pcan_status_health(0x10 | 0x08 | 0x04) == .bus_off
	assert pcan_status_health(0x40000 | 0x04) == .error_passive
	// unplugged / uninitialized (ILLHW 0x1400, INITIALIZE 0x4000000): cannot say — NOT ok
	assert pcan_status_health(0x1400) == .unknown
	assert pcan_status_health(0x4000000) == .unknown
}

fn test_health_rank_orders_worst_first() {
	assert health_rank(.bus_off) > health_rank(.error_passive)
	assert health_rank(.error_passive) > health_rank(.warning)
	assert health_rank(.warning) > health_rank(.ok)
	assert health_rank(.ok) > health_rank(.unknown)
}

fn test_kvaser_status_ladder() {
	// canstat.h: ERROR_PASSIVE 0x01, BUS_OFF 0x02, ERROR_WARNING 0x04, ERROR_ACTIVE 0x08,
	// TX_PENDING 0x10, RESERVED_1 0x40. The first version of this test pinned a transcription
	// with PASSIVE/BUS_OFF swapped and 0x40 invented as warning — a pin is only as good as
	// the header it was read from.
	assert kvaser_status_health(0x08) == .ok // ERROR_ACTIVE alone
	assert kvaser_status_health(0x04) == .warning
	assert kvaser_status_health(0x01) == .error_passive
	assert kvaser_status_health(0x02) == .bus_off
	assert kvaser_status_health(0x02 | 0x01 | 0x04) == .bus_off
	// no ladder bit at all — TX_PENDING, RESERVED_1, or nothing — is "cannot say", never ok
	assert kvaser_status_health(0x10) == .unknown
	assert kvaser_status_health(0x40) == .unknown
	assert kvaser_status_health(0) == .unknown
}

fn test_xl_chipstat_ladder() {
	assert xl_chipstat_health(0x08) == .ok // ERROR_ACTIVE
	assert xl_chipstat_health(0x04) == .warning
	assert xl_chipstat_health(0x02) == .error_passive
	assert xl_chipstat_health(0x01) == .bus_off
	assert xl_chipstat_health(0x01 | 0x04) == .bus_off
	assert xl_chipstat_health(0) == .unknown // the driver has not said — not a healthy bus
}

fn test_socketcan_err_ladder() {
	assert is_socketcan_err(0x2000_0044)
	assert !is_socketcan_err(0x123)
	assert socketcan_err_health(0x2000_0040, 0) == .bus_off
	assert socketcan_err_health(0x2000_0004, 0x08) == .warning // CRTL + TX_WARNING
	assert socketcan_err_health(0x2000_0004, 0x20) == .error_passive // CRTL + TX_PASSIVE
	assert socketcan_err_health(0x2000_0004, 0x40) == .ok // CRTL_ACTIVE: recovered
	assert socketcan_err_health(0x2000_0100, 0) == .ok // RESTARTED
	// a bit-error frame names no ladder state — it must not invent one
	assert socketcan_err_health(0x2000_0008, 0) == .unknown
	// passive outranks warning when both detail bits are present
	assert socketcan_err_health(0x2000_0004, 0x30 | 0x0c) == .error_passive
}

// The bench case: a PCAN channel transmitting into a disconnected bus reports BUSHEAVY
// through CAN_Read's return, and the backend used to call that a failed read — which the GUI
// answers by disabling the wire. A warning must degrade a channel, never remove it.
fn test_pcan_read_verdict_ladder_is_not_a_failure() {
	// plain answers first
	assert pcan_read_verdict(0x00) == .frame // OK, message returned
	assert pcan_read_verdict(0x20) == .empty // QRCVEMPTY, nothing waiting

	// the ladder alone: the channel is in trouble AND handed us a message
	assert pcan_read_verdict(0x04) == .frame // BUSLIGHT
	assert pcan_read_verdict(0x08) == .frame // BUSHEAVY — the one measured on the bench
	assert pcan_read_verdict(0x10) == .frame // BUSOFF
	assert pcan_read_verdict(0x40000) == .frame // BUSPASSIVE

	// the ladder OR'd with "nothing waiting" — a degraded wire that is simply idle. Reported
	// as a failure, this is what disabled the channel and stopped the trace dead.
	assert pcan_read_verdict(0x08 | 0x20) == .empty
	assert pcan_read_verdict(0x10 | 0x20) == .empty
	assert pcan_read_verdict(0x40000 | 0x20) == .empty
	assert pcan_read_verdict(0x04 | 0x08 | 0x10 | 0x40000 | 0x20) == .empty

	// and what MUST still be fatal: the adapter is gone, or was never opened. Masking the
	// ladder must not swallow these — a dead channel polled forever is the opposite failure.
	assert pcan_read_verdict(0x1400) == .failed // ILLHW: unplugged
	assert pcan_read_verdict(0x200) == .failed // NODRIVER
	assert pcan_read_verdict(0x4000000) == .failed // INITIALIZE: channel not open
	assert pcan_read_verdict(0x1400 | 0x08) == .failed // a real fault WITH ladder bits set
}
