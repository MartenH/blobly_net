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

// PcanRead is what a CAN_Read return value MEANS. Three answers, because the vendor packs
// three different things into one word and conflating any two of them loses a wire.
pub enum PcanRead {
	frame  // a message was returned
	empty  // nothing waiting — poll again
	failed // the channel is broken: stop reading it
}

// pcan_ladder_mask is the fault ladder CAN_Read ORs into its return value: BUSLIGHT 0x04,
// BUSHEAVY/BUSWARNING 0x08, BUSOFF 0x10, BUSPASSIVE 0x40000 — the same PCANBasic.h bits
// pcan_status_health decodes above, and the reason this function exists.
const pcan_ladder_mask = u32(0x04 | 0x08 | 0x10 | 0x40000)

// pcan_read_verdict classifies CAN_Read's status word.
//
// THE LADDER IS NOT A READ FAILURE. CAN_Read reports the channel's condition alongside the
// message, so a wire in trouble returns BUSHEAVY *and* whatever it had (or nothing). The
// backend used to answer "any status that is neither OK nor QRCVEMPTY" with a hard error, and
// rx_loop answers a hard error by disabling every channel on the wire — so transmitting into a
// disconnected bus reported 0x08 and killed its own reader. A warning must degrade the wire,
// never remove it: the ladder belongs to health() (which polls it every second and narrates
// the transition), and only what is left after masking it off decides whether the READ worked.
//
// Masks the ladder and nothing else. PCAN_ERROR_QOVERRUN (0x40) and QXMTFULL (0x80) are
// arguably the same class — conditions rather than read failures — but nothing has been
// observed to raise them here, and widening this mask on reasoning alone is how a genuine
// failure (ILLHW when an adapter is unplugged, NODRIVER, INITIALIZE) ends up silently swallowed
// and a dead channel is polled forever.
pub fn pcan_read_verdict(st u32) PcanRead {
	rest := st & ~pcan_ladder_mask
	if rest == 0 {
		return .frame
	}
	if rest == 0x20 { // PCAN_ERROR_QRCVEMPTY
		return .empty
	}
	return .failed
}

// PcanWrite is what CAN_Write / CAN_WriteFD's status word means for the frame just offered.
pub enum PcanWrite {
	sent
	busy   // the adapter's transmit queue is full - back off and offer it again
	failed // the channel is broken: this frame is not going out and nor is the next
}

// pcan_write_ladder_mask is the part of the fault ladder that does NOT stop a transmission.
//
// BUSLIGHT (0x04), BUSHEAVY/BUSWARNING (0x08) and BUSPASSIVE (0x40000) are degradations: a
// controller in any of them still transmits, so they are news about the wire and not a verdict on
// the frame -- the same argument pcan_read_verdict makes about reads.
//
// BUSOFF (0x10) IS DELIBERATELY ABSENT. A bus-off controller has LEFT the bus; the frame is going
// nowhere and neither is the next one. That is the one rung where the read side and the write side
// must disagree, and it is why this mask exists instead of reusing pcan_ladder_mask.
const pcan_write_ladder_mask = u32(0x04 | 0x08 | 0x40000)

// pcan_xmt_full_mask is PCANBasic's two "no room" answers: PCAN_ERROR_XMTFULL (0x01, the
// CONTROLLER's buffer) and PCAN_ERROR_QXMTFULL (0x80, the DRIVER's queue behind it). Different
// buffers, one meaning for a caller -- offer it again in a moment.
const pcan_xmt_full_mask = u32(0x01 | 0x80)

// pcan_write_verdict classifies CAN_Write's and CAN_WriteFD's status word.
//
// WHY BACK-PRESSURE IS NOT A FAILURE. This backend answered "any status but 0" with a hard error,
// so a full transmit queue ended a frame permanently -- and a replay of a dense capture reaches a
// full queue constantly, by construction: it is asking the adapter to go at the speed the
// recording went. The frame was then counted failed and the replay acquired a hole exactly where
// the recording was busiest, which is the failure `send_waiting_for_room` exists to prevent and
// which it could not see, because it recognised only Vector's wording (codex round 2 on #217).
pub fn pcan_write_verdict(st u32) PcanWrite {
	rest := st & ~pcan_write_ladder_mask
	if rest == 0 {
		return .sent
	}
	// Only if there is NOTHING ELSE left. A queue-full bit arriving alongside a real fault is a
	// real fault: retrying that one waits out the whole budget talking to a broken channel.
	if rest & ~pcan_xmt_full_mask == 0 {
		return .busy
	}
	return .failed
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
