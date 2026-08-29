module transport

// BUS LOAD: the share of a wire's time its frames occupy, the gauge every CAN tool shows and
// the one counters cannot replace — "is this bus near saturation", "did the rest-bus change
// the load", "was that error burst a load peak". Computed here, GUI-free, from what every
// backend already reports: the frame and the rates the row declared.
//
// THE RULE IS BITS ON THE WIRE, and the bit count is the WORST case: a stuff bit follows five
// equal bits, and since the stuff bit itself opens the next run the next one can follow four
// more — so the bound is (stuffable - 1) / 4, not stuffable / 5 (codex #263 r1), and a frame
// is between its bare length and ~1.25× it. No receiver can tell which without the raw bit
// stream. Tools disagree on this choice (PCAN-View reads
// the controller's own counter; CANalyzer estimates as we do); the choice is stated once,
// here, so two panels cannot show two numbers.

// frame_bits is how many bit-times `f` occupies on a wire whose arbitration rate is
// `nominal` and whose data-phase rate is `data` (equal to nominal when there is no BRS),
// expressed in NOMINAL bit-times so that load = bits / nominal / second.
//
// Classic (ISO 11898-1): SOF 1, ID 11 (+18 and IDE/SRR for extended), RTR 1, IDE 1, r0 1,
// DLC 4, data 8n, CRC 15 + delimiter 1, ACK 1 + delimiter 1, EOF 7, IFS 3 = 47 + 8n for a
// standard id, 67 + 8n for an extended one — before stuffing, which covers everything up to
// the CRC delimiter (the stuffable field is 34 + 8n / 54 + 8n bits, worst case (len-1)/4).
//
// A REMOTE frame carries no data bytes — its DLC is the length it asks for — so `data.len`,
// which the backends fill with that many zeros, is not what was on the wire.
//
// CAN-FD: the arbitration part (SOF..BRS) at the nominal rate, the data part (ESI, DLC, data,
// CRC 17 for n ≤ 16 else 21, plus the stuff-count field and fixed stuff bits) at the data
// rate when BRS is set, then CRC delimiter, ACK, EOF and IFS back at nominal. The data
// part's cost in nominal bit-times is scaled by nominal/data.
pub fn frame_bits(f CanFrame, nominal int, data int) f64 {
	n := if f.rtr && !f.fd { 0 } else { f.data.len }
	if !f.fd {
		fixed := if f.extended { 67 } else { 47 }
		stuffable := if f.extended { 54 } else { 34 } + 8 * n
		return f64(fixed + 8 * n + worst_stuff(stuffable))
	}
	// FD arbitration phase at nominal: SOF 1, ID 11 (+18+SRR+IDE for extended), r1/RRS 1,
	// IDE 1, FDF 1, res 1, BRS 1 — 17 or 37 bits, stuffed classically.
	arb := if f.extended { 37 } else { 17 }
	arb_stuffed := arb + worst_stuff(arb)
	// FD data phase: ESI 1, DLC 4, data 8n, stuff count 4 + parity 1, CRC 17/21 with fixed
	// stuff bits every 4 (crc/4), and the CRC delimiter 1.
	crc := if n <= 16 { 17 } else { 21 }
	data_bits := 1 + 4 + 8 * n + 5 + crc + crc / 4 + 1
	// Dynamic stuffing in the data field, worst case.
	data_stuffed := data_bits + worst_stuff(8 * n)
	// Back at nominal: ACK 1 + delimiter 1, EOF 7, IFS 3.
	tail := 12
	rate := if f.brs && data > 0 && nominal > 0 { f64(nominal) / f64(data) } else { 1.0 }
	return f64(arb_stuffed) + f64(data_stuffed) * rate + f64(tail)
}

// worst_stuff is the most stuff bits `bits` dynamically stuffed bits can grow by: one after
// the first five equal bits, then one per four, because each stuff bit starts the next run.
fn worst_stuff(bits int) int {
	if bits < 5 {
		return 0
	}
	return (bits - 1) / 4
}

// load_percent is the bus load over one interval: `bits` nominal bit-times seen in `ms`
// milliseconds on a wire whose nominal rate is `nominal` bit/s. Clamped to 100: a worst-case
// stuffing estimate can nominally exceed a saturated wire by a few percent.
pub fn load_percent(bits f64, ms i64, nominal int) f32 {
	if ms <= 0 || nominal <= 0 {
		return 0
	}
	capacity := f64(nominal) * f64(ms) / 1000.0
	p := 100.0 * bits / capacity
	if p > 100 {
		return 100
	}
	if p < 0 {
		return 0
	}
	return f32(p)
}
