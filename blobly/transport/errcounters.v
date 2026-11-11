module transport

// ErrorCounters is the controller's transmit and receive error counters (TEC, REC) as it last
// reported them: what drives the health ladder (warning at 96, error-passive at 128, bus-off at
// 256), so a test can watch a counter climb and come back while the rung still reads `ok`.
// `known` false is "this backend cannot say", never zero counters: the software buses have no
// controller, PCAN and Kvaser are not read, and a SocketCAN or Vector wire says nothing until an
// error frame or chip-state event has been read off it (health_source's `needs_reader`).
pub struct ErrorCounters {
pub:
	tx    int
	rx    int
	known bool
}

// str is the operator's spelling: empty when unknown.
pub fn (c ErrorCounters) str() string {
	if !c.known {
		return ''
	}
	return 'TEC ${c.tx} REC ${c.rx}'
}

// socketcan_err_counters reads a kernel error frame's counters: CAN_ERR_CNT (0x200 in the id)
// says data[6] is the transmit counter and data[7] the receive one (linux/can/error.h). none
// where the frame does not carry them.
pub fn socketcan_err_counters(can_id u32, data []u8) ?ErrorCounters {
	if can_id & 0x200 == 0 || data.len < 8 {
		return none
	}
	return ErrorCounters{
		tx:    int(data[6])
		rx:    int(data[7])
		known: true
	}
}

// vector_chip_word packs an XL chip-state event the way the shim hands it over: busStatus in
// the low byte, txErrorCounter in the next, rxErrorCounter in the third — one int, so the
// receive path latches all three in one store and -1 stays "no event".
pub fn vector_chip_word(bus_status u8, tx u8, rx u8) int {
	return int(bus_status) | (int(tx) << 8) | (int(rx) << 16)
}

// vector_chip_status is the busStatus byte of a packed chip-state word (-1: none seen).
pub fn vector_chip_status(word int) int {
	return if word < 0 { -1 } else { word & 0xff }
}

// vector_chip_counters reads the counters out of a packed chip-state word. Known only where an
// event was seen and its busStatus says something, as xl_chipstat_health reads it: a zero
// busStatus is a driver that has not said.
pub fn vector_chip_counters(word int) ErrorCounters {
	if word < 0 || word & 0xff == 0 {
		return ErrorCounters{}
	}
	return ErrorCounters{
		tx:    (word >> 8) & 0xff
		rx:    (word >> 16) & 0xff
		known: true
	}
}

// cansub_counters reads a CANsub status body's `tx_error_count` and `rx_error_count`. Reported as
// the device reports them: its firmware starts a channel at TEC 129 and a monitor never lowers it
// (see cansub_ladder), so a monitor's tx reads 129 for the life of the run. none where either is
// missing.
fn cansub_counters(body string) ?ErrorCounters {
	tx := extract_json_int(body, 'tx_error_count')?
	rx := extract_json_int(body, 'rx_error_count')?
	return ErrorCounters{
		tx:    tx
		rx:    rx
		known: true
	}
}
