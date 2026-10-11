// Frame shape — the rules that hold for every CAN controller, said ONCE.
//
// WHY THIS FILE EXISTS. Vector's send path refuses an id that does not fit its declared width, a
// payload that is not a DLC length, `brs` without `fd` and `rtr` with `fd`. Kvaser's refuses most
// of them. The CANsub backend then landed with a fresh send path and inherited none of it: it
// masked an oversized standard id down to eleven bits and dropped `brs` from a classic frame, both
// silently, both reported as success (codex round 1 on #204, findings 4 and 5).
//
// That is not four backends making four mistakes. It is one policy living in four places, which is
// the shape this repo already knows: a check written per backend is a check the NEXT backend does
// not have. None of these rules is a vendor fact — they are CAN itself — so none of them belongs in
// a vendor file.
//
// WHY REFUSE RATHER THAN CORRECT. A backend that masks, truncates or drops a flag puts a DIFFERENT
// frame on the wire from the one it was handed, and reports success. `wiretap` then records what
// was ASKED, matches the echo against it, and cannot match — so our own frame comes back
// unattributed and is filed as the ECU's. Every one of these silently produces a trace that
// disagrees with the wire, which is the one thing a bus tester may not do.
//
// The reason is returned unprefixed; each backend names itself, because "Kvaser:" and "CANsub:"
// are what tell an operator which row to go and look at.
module transport

// NotWritten is a send that was REFUSED before anything reached the socket: a frame the wire
// cannot carry, a listen-only mark, a bus that has failed, a connection that is over for
// writing. The hub reads the type: a write that FAILED may still have put the frame on the
// wire, and its pending entry is kept matchable for a grace; a send that was never attempted
// has no acknowledgement coming, and an entry kept for it could claim a late acknowledgement
// meant for the original write and file that frame under the wrong handle (codex round 9 on
// #251). Drivers return it through not_written().
pub struct NotWritten {
	Error
pub:
	msg string
}

pub fn (e NotWritten) msg() string {
	return e.msg
}

// not_written is the refusal a driver returns for a send it did not attempt.
pub fn not_written(msg string) IError {
	return NotWritten{
		msg: msg
	}
}

// frame_send_refusal reports why this frame will not be put on a wire, or none.
//
// TWO KINDS OF REASON, and they are not the same kind of thing. Most are contradictions IN THE
// FRAME that no controller of any tier could transmit. One — a remote frame — is a PRODUCT
// DECISION: a classic controller can send one perfectly well, and this app has chosen not to
// (#215). The function was called `frame_send_refusal` while enforcing both, which invited
// the next backend to read a decision of ours as a law of CAN (codex round 2 on #216).
//
// SEPARATE FROM THE LENGTH RULES because this repo has three tiers and only two of them agree
// about length. SocketCAN CLAMPS (the kernel masks an over-wide id, and `wire_frame` records the
// clamp so the record matches the wire); the software buses PAD an FD payload to a length a DLC
// can express; the vendor backends REFUSE. That is a deliberate design, documented at
// `clamps_to_classic`, and not something to overturn in a review round.
//
// None of the rules below is a length or a clamp, though. An `rtr` FD frame, a classic frame with
// `brs`, an id that will not fit the width the caller DECLARED — no controller of any tier can
// transmit those, so carrying them is a simulation modelling something that cannot happen, and a
// test that passes in `inproc:` and fails on a bench (codex round 2 on #204).
pub fn frame_send_refusal(f CanFrame) ?string {
	// ---- a decision, not a law -----------------------------------------------------------
	//
	// THIS APP DOES NOT TRANSMIT REMOTE FRAMES.
	//
	// A remote frame is a REQUEST for a message rather than a transmission of one. CAN-FD removed
	// it outright — the bit RTR occupied carries FDF — and nothing in modern automotive practice
	// uses it: not AUTOSAR, not J1939, not UDS or ISO-TP, and most OEM networks forbid it. Nothing
	// in this repo asks for one either: no DBC message, no project, no simulated ECU, no test.
	//
	// So the send paths that carried it are gone, and this is what keeps their removal HONEST. A
	// backend that simply ignored the flag would put an ordinary data frame on the wire and report
	// success, which is the silent substitution every other rule in this file exists to prevent —
	// the worst possible way to drop a feature. Refused, a caller finds out.
	//
	// RECEIVING one is unaffected: the wire and a recording can both carry a remote frame, and a
	// trace that showed it as data would be lying about the bus. Decoding stays.
	if f.rtr {
		return 'rtr (id 0x${f.id:X}) — this app does not transmit remote frames; CAN-FD has none at all, and nothing here requests one'
	}
	// ---- frames no controller could transmit ----------------------------------------------
	//
	// BRS SWITCHES INTO A DATA PHASE, and a classic frame has none. Dropped instead of refused,
	// the trace records a rate change that never happened.
	if f.brs && !f.fd {
		return 'brs without fd (id 0x${f.id:X}) — bit-rate switching belongs to a CAN-FD frame\'s data phase, and a classic frame has none'
	}
	// ESI IS A CAN-FD BIT and a classic frame has nowhere to put it. It reports that the
	// TRANSMITTER was error-passive, which only an FD frame's control field carries.
	//
	// Not merely meaningless: the CANsub's own wire format puts ESI in bit 5 of the flags byte,
	// and its decoder reads `b6 & 0xE0 == 0x20` — a classic frame with ESI and nothing else — as
	// an ERROR RECORD. So the encoder turned a transmission somebody asked for into something the
	// receiver reads as a bus error (codex round 3 on #204). A frame that decodes as a different
	// KIND of thing is the strongest form of the disagreement this file exists to prevent.
	if f.esi && !f.fd {
		return 'esi without fd (id 0x${f.id:X}) — ESI reports an error-passive transmitter in a CAN-FD control field, and a classic frame has none'
	}
	// THE ID AGAINST ITS DECLARED WIDTH. `extended` is what the caller says the frame is, so an id
	// too big for it is a contradiction in the frame itself — and masking it transmits a different
	// identifier under the name of the one asked for.
	limit := if f.extended { u32(0x1FFF_FFFF) } else { u32(0x7FF) }
	if f.id > limit {
		width := if f.extended { '29-bit' } else { '11-bit' }
		return 'id 0x${f.id:X} does not fit a ${width} identifier'
	}
	return none
}

// frame_shape_error is the full rule set: everything impossible, plus the lengths a backend that
// REFUSES rather than clamps has to check. The vendor backends are that tier.
//
// ADAPTER-INDEPENDENT ONLY. Whether a channel was opened for CAN-FD, whether a vendor library is
// present, whether the wire is silenced — none of that is here; those are properties of the
// channel and each backend answers them with its own address in the message.
pub fn frame_shape_error(f CanFrame) ?string {
	if why := frame_send_refusal(f) {
		return why
	}
	if f.fd {
		// A DLC CANNOT EXPRESS EVERY LENGTH above eight, so a 9-byte payload can only go out
		// padded to 12 — deliberately, by the caller, or the trace records nine against twelve.
		if f.data.len !in fd_lengths {
			return '${f.data.len} bytes is not a CAN-FD payload size (id 0x${f.id:X}) — a DLC can only express ${fd_lengths}'
		}
		return none
	}
	if f.data.len > 8 {
		return '${f.data.len} bytes is not a classic CAN frame (id 0x${f.id:X}) — 8 is the maximum without FD'
	}
	return none
}
