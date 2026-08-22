module transport

// BusHealth is the controller's fault state, normalized across backends: the CAN error
// counters drive every controller through the same ladder (active -> warning at 96 ->
// error-passive at 128 -> bus-off at 256), the vendors merely spell it differently. What a
// status word MEANS belongs here, decoded by pure functions a test can reach — the GUI only
// displays transitions.
pub enum BusHealth {
	unknown // backend cannot say (no status source, or none seen yet)
	ok
	warning       // error counters above the warning limit (96) — the bus is degrading
	error_passive // counters above 128: the controller no longer signals errors actively
	bus_off       // counters hit 256: the controller LEFT the bus and transmits nothing
}

// health_name is the operator-facing word for a state, shared by the Buses panel and the Log.
pub fn health_name(h BusHealth) string {
	return match h {
		.unknown { '' }
		.ok { 'ok' }
		.warning { 'error warning' }
		.error_passive { 'ERROR-PASSIVE' }
		.bus_off { 'BUS-OFF' }
	}
}

// --- per-backend decoders: values from the vendors' own headers, worst state wins ---

// pcan_status_health decodes a PCANBasic status word (CAN_GetStatus). PCAN_ERROR_BUSLIGHT
// 0x04, BUSHEAVY (= BUSWARNING) 0x08, BUSPASSIVE 0x40000, BUSOFF 0x10 — from PCANBasic.h.
// A NONZERO word with none of the ladder bits (ILLHW when the adapter is unplugged,
// INITIALIZE, …) is .unknown: "cannot say" — decoding it .ok painted a physically absent
// adapter green (self-review). Only an exact 0 is the driver saying error-active-and-fine.
pub fn pcan_status_health(st u32) BusHealth {
	if st & 0x10 != 0 {
		return .bus_off
	}
	if st & 0x40000 != 0 {
		return .error_passive
	}
	if st & 0x08 != 0 || st & 0x04 != 0 {
		return .warning
	}
	if st == 0 {
		return .ok
	}
	return .unknown
}

// kvaser_status_health decodes canReadStatus flags — canstat.h: canSTAT_ERROR_PASSIVE 0x01,
// canSTAT_BUS_OFF 0x02, canSTAT_ERROR_WARNING 0x04, canSTAT_ERROR_ACTIVE 0x08 (TX_PENDING
// 0x10, RESERVED_1 0x40 carry no ladder meaning). The first transcription of this table had
// BUS_OFF and ERROR_PASSIVE swapped and a warning mask that does not exist — with the test
// pinning the swap; the review that caught it read the vendor's header, which is the only
// defense a transcription has. .ok requires the EXPLICIT error-active bit: flags without any
// ladder bit are .unknown, not a diagnosis.
pub fn kvaser_status_health(flags u32) BusHealth {
	if flags & 0x02 != 0 {
		return .bus_off
	}
	if flags & 0x01 != 0 {
		return .error_passive
	}
	if flags & 0x04 != 0 {
		return .warning
	}
	if flags & 0x08 != 0 {
		return .ok
	}
	return .unknown
}

// xl_chipstat_health decodes an XL_CHIP_STATE event's busStatus: XL_CHIPSTAT_BUSOFF 0x01,
// ERROR_PASSIVE 0x02, ERROR_WARNING 0x04, ERROR_ACTIVE 0x08 — from vxlapi.h. .ok requires
// the explicit error-active bit; a zero busStatus is a driver that has not said, not a
// healthy bus.
pub fn xl_chipstat_health(bus_status u8) BusHealth {
	if bus_status & 0x01 != 0 {
		return .bus_off
	}
	if bus_status & 0x02 != 0 {
		return .error_passive
	}
	if bus_status & 0x04 != 0 {
		return .warning
	}
	if bus_status & 0x08 != 0 {
		return .ok
	}
	return .unknown
}

// health_rank orders the ladder for worst-of folding (a wire's health is the worst any
// observer on it reports): bus_off worst, unknown least — "cannot say" never outranks a
// diagnosis.
pub fn health_rank(h BusHealth) int {
	return match h {
		.bus_off { 4 }
		.error_passive { 3 }
		.warning { 2 }
		.ok { 1 }
		.unknown { 0 }
	}
}

// socketcan_err_health decodes a kernel error frame (can_id has CAN_ERR_FLAG set; delivery
// requires the CAN_RAW_ERR_FILTER the backend now installs). CAN_ERR_BUSOFF is bit 0x40 of
// the id; controller problems are CAN_ERR_CRTL 0x04 with the detail in data[1]:
// RX/TX_WARNING 0x04|0x08, RX/TX_PASSIVE 0x10|0x20; CAN_ERR_RESTARTED 0x100 returns the
// controller to ok — from linux/can/error.h.
pub fn socketcan_err_health(can_id u32, d1 u8) BusHealth {
	if can_id & 0x40 != 0 {
		return .bus_off
	}
	if can_id & 0x100 != 0 {
		return .ok // controller restarted
	}
	if can_id & 0x04 != 0 {
		if d1 & 0x30 != 0 {
			return .error_passive
		}
		if d1 & 0x0c != 0 {
			return .warning
		}
		if d1 & 0x40 != 0 {
			return .ok // CAN_ERR_CRTL_ACTIVE: back to error-active
		}
	}
	return .unknown // an error frame that names no ladder state (bit error, ACK slot, …)
}

// is_socketcan_err reports a kernel error frame: CAN_ERR_FLAG, bit 29.
pub fn is_socketcan_err(can_id u32) bool {
	return can_id & 0x2000_0000 != 0
}
