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
}

fn test_kvaser_status_ladder() {
	assert kvaser_status_health(0x10) == .ok // ERROR_ACTIVE alone
	assert kvaser_status_health(0x40) == .warning
	assert kvaser_status_health(0x02) == .error_passive
	assert kvaser_status_health(0x01) == .bus_off
	assert kvaser_status_health(0x01 | 0x02 | 0x40) == .bus_off
}

fn test_xl_chipstat_ladder() {
	assert xl_chipstat_health(0x08) == .ok // ERROR_ACTIVE
	assert xl_chipstat_health(0x04) == .warning
	assert xl_chipstat_health(0x02) == .error_passive
	assert xl_chipstat_health(0x01) == .bus_off
	assert xl_chipstat_health(0x01 | 0x04) == .bus_off
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
