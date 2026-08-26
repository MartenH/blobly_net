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

// frame_shape_error reports why this frame is not a frame any controller could send, or none.
//
// ADAPTER-INDEPENDENT ONLY. Whether a channel was opened for CAN-FD, whether a vendor library is
// present, whether the wire is silenced — none of that is here; those are properties of the
// channel and each backend answers them with its own address in the message.
pub fn frame_shape_error(f CanFrame) ?string {
	// CAN-FD HAS NO REMOTE FRAME. The standard reused the bit: an FD frame's control field carries
	// FDF where RTR sat, so there is nothing to ask for. Left through, a backend builds an ordinary
	// FD data frame and reports success for a message nobody asked for.
	if f.rtr && f.fd {
		return 'rtr with fd (id 0x${f.id:X}) — CAN-FD has no remote frames; the bit RTR used to occupy carries FDF'
	}
	// BRS SWITCHES INTO A DATA PHASE, and a classic frame has none. Dropped instead of refused,
	// the trace records a rate change that never happened.
	if f.brs && !f.fd {
		return 'brs without fd (id 0x${f.id:X}) — bit-rate switching belongs to a CAN-FD frame\'s data phase, and a classic frame has none'
	}
	// THE ID AGAINST ITS DECLARED WIDTH. `extended` is what the caller says the frame is, so an id
	// too big for it is a contradiction in the frame itself — and masking it transmits a different
	// identifier under the name of the one asked for.
	limit := if f.extended { u32(0x1FFF_FFFF) } else { u32(0x7FF) }
	if f.id > limit {
		width := if f.extended { '29-bit' } else { '11-bit' }
		return 'id 0x${f.id:X} does not fit a ${width} identifier'
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
