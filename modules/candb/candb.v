// candb — minimal CAN signal database: messages, signals, and bit-level
// encode/decode. GUI-free and independently testable (see candb_test.v). This
// is the foundation the DBC phase will build on; for now signals are defined in
// code. Intel (little-endian) bit ordering only, for now.
module candb

import math

pub enum ByteOrder {
	little_endian // Intel:    start_bit = LSB, bits ascend in the LSB-0 numbering
	big_endian    // Motorola: start_bit = MSB, bits descend sawtooth across bytes
}

pub struct Signal {
pub mut:
	name       string
	start_bit  int // start bit (LSB for Intel, MSB for Motorola) in LSB-0 numbering
	length     int // width in bits
	factor     f64 = 1.0
	offset     f64
	minimum    f64 // physical range from the DBC [min|max] (0,0 if unspecified)
	maximum    f64
	unit       string
	desc       string         // human-readable description / interpretation
	values     map[u64]string // DBC VAL_ table: raw value -> named state (enum)
	is_signed  bool
	byte_order ByteOrder = .little_endian
	// Multiplexing (DBC 'M' / 'm<N>'): a message may have ONE multiplexor switch
	// signal; multiplexed signals are only present when the switch equals their
	// selector value. is_multiplexor and is_multiplexed can both be true for
	// extended multiplexing ('m<N>M').
	// the ECUs that receive this signal (DBC SG_ receiver list; an ARXML frame's IN ports and
	// I-PDU groups). Empty means none declared — 'Vector__XXX' is normalised away, like sender.
	receivers         []string
	is_multiplexor    bool // 'M' — selects which multiplexed signals are present
	is_multiplexed    bool // 'm<N>' — present only when the switch == multiplexor_value
	multiplexor_value int  // the N in 'm<N>'
}

// label returns the VAL_ table name for the signal's current raw value in
// `data` (e.g. Gear 3 -> "Third"), or '' if the signal has no value table /
// no entry for that value.
// senders is every node the database says transmits this message: the BO_ transmitter plus any
// BO_TX_BU_ additions, without duplicates and without the 'no transmitter' placeholders. Asking
// `m.sender == node` instead misses a node declared only as an additional transmitter — which,
// where the question is "is this the ECU under test's own message?", answers a safety question
// with the wrong half of the data.
pub fn (m Message) senders() []string {
	mut out := []string{}
	if m.sender != '' && m.sender != 'Vector__XXX' {
		out << m.sender
	}
	for n in m.tx_nodes {
		if n != '' && n != 'Vector__XXX' && n !in out {
			out << n
		}
	}
	return out
}

pub fn (s Signal) label(data []u8) string {
	return s.values[s.raw_value(data)]
}

pub struct Message {
pub mut:
	name     string
	id       u32
	ext      bool // 29-bit extended identifier (DBC EFF high-bit was set)
	dlc      int
	sender   string // transmitting node (DBC BO_ transmitter); '' / 'Vector__XXX' = none
	// ADDITIONAL transmitters, from a `BO_TX_BU_` record. A DBC may declare that several nodes
	// send the same message; `sender` names only the first. Anything asking "does node X send
	// this?" must consult both — see senders(). Empty for the overwhelming majority of messages.
	tx_nodes []string
	cycle_ms int    // GenMsgCycleTime attribute if present (0 = not cyclic / unknown)
	signals  []Signal
}

// raw_value extracts the unsigned raw bits of the signal from `data`. Handles
// both Intel (little-endian) and Motorola (big-endian) bit ordering. Bits use
// the LSB-0 numbering: position p -> byte p/8, bit p%8 (bit 0 = byte LSB).
pub fn (s Signal) raw_value(data []u8) u64 {
	mut raw := u64(0)
	if s.byte_order == .little_endian {
		for i in 0 .. s.length {
			g := s.start_bit + i
			byte_idx := g / 8
			bit_idx := g % 8
			if byte_idx >= data.len {
				continue
			}
			bit := (data[byte_idx] >> bit_idx) & 1
			raw |= u64(bit) << i
		}
	} else {
		// Motorola: start_bit is the MSB; walk MSB->LSB, dropping to the next
		// byte's bit 7 each time we fall off the bottom of a byte (sawtooth).
		mut pos := s.start_bit
		for _ in 0 .. s.length {
			byte_idx := pos / 8
			bit_idx := pos % 8
			raw <<= 1
			if byte_idx < data.len {
				raw |= u64((data[byte_idx] >> bit_idx) & 1)
			}
			pos = if bit_idx == 0 { pos + 15 } else { pos - 1 }
		}
	}
	return raw
}

// phys_from_raw applies sign-extension, factor and offset to a raw bit value:
// phys = signed(raw) * factor + offset. Use for raw values not read from a frame,
// e.g. a VAL_ table key (which is stored two's-complement for signed signals).
pub fn (s Signal) phys_from_raw(raw u64) f64 {
	mut v := f64(raw)
	if s.is_signed && s.length == 64 {
		// the full word: the pattern IS the i64, and the shift below would be by 64
		v = f64(i64(raw))
	} else if s.is_signed && s.length > 0 && s.length < 64 {
		sign_bit := u64(1) << (s.length - 1)
		if raw & sign_bit != 0 {
			v = f64(i64(raw) - (i64(1) << s.length)) // two's-complement negative
		}
	}
	return v * s.factor + s.offset
}

// raw_from_phys is the inverse of phys_from_raw: physical -> raw bits (two's-complement,
// masked to the signal width for signed signals).
pub fn (s Signal) raw_from_phys(phys f64) u64 {
	// round half away from zero; a bare `+ 0.5` truncates negatives wrongly.
	r := math.round((phys - s.offset) / s.factor)
	mask := if s.length >= 64 { ~u64(0) } else { (u64(1) << s.length) - 1 }
	// CLAMPED TO THE DOMAIN'S ENDPOINTS before the cast: f64 cannot hold 2^64-1 or 2^63-1
	// exactly, so a wide signal set to its maximum rounded to 2^64 (zero, on the C backend) or
	// to 2^63 (the sign bit: the MINIMUM) — the opposite endpoint (codex on #273 round 31).
	if s.is_signed && s.length > 0 {
		top := if s.length >= 64 { u64(1) << 63 } else { u64(1) << (s.length - 1) }
		if r >= f64(top) {
			return (top - 1) & mask
		}
		if r < -f64(top) {
			return top & mask
		}
	} else if r >= f64(mask) + 1.0 {
		// f64(mask) + 1 is exactly 2^length for every width, 64 included
		return mask
	}
	// A negative goes through i64: its two's-complement pattern masked to the width IS the raw
	// value. A non-negative goes through u64 DIRECTLY — via i64 it saturates at 2^63, so the
	// top half of an unsigned 64-bit signal's domain encoded as INT64_MIN.
	raw := if r < 0 { u64(i64(r)) } else { u64(r) }
	return raw & mask
}

// physical applies sign-extension, factor and offset: phys = raw * factor + offset.
pub fn (s Signal) physical(data []u8) f64 {
	return s.phys_from_raw(s.raw_value(data))
}

// set_raw writes `raw` into `data` at the signal's bit position. Mirrors
// raw_value for both Intel (little-endian) and Motorola (big-endian) ordering.
pub fn (s Signal) set_raw(mut data []u8, raw u64) {
	if s.byte_order == .little_endian {
		for i in 0 .. s.length {
			g := s.start_bit + i
			byte_idx := g / 8
			bit_idx := g % 8
			if byte_idx >= data.len {
				continue
			}
			mask := u8(1) << bit_idx
			bit := u8((raw >> i) & 1)
			data[byte_idx] = (data[byte_idx] & ~mask) | (bit << bit_idx)
		}
	} else {
		// Motorola: write MSB-first along the same sawtooth as raw_value.
		mut pos := s.start_bit
		for i in 0 .. s.length {
			byte_idx := pos / 8
			bit_idx := pos % 8
			bit := u8((raw >> (s.length - 1 - i)) & 1)
			if byte_idx < data.len {
				mask := u8(1) << bit_idx
				data[byte_idx] = (data[byte_idx] & ~mask) | (bit << bit_idx)
			}
			pos = if bit_idx == 0 { pos + 15 } else { pos - 1 }
		}
	}
}

// encode converts a physical value to raw and writes it into `data`.
pub fn (s Signal) encode(mut data []u8, phys f64) {
	s.set_raw(mut data, s.raw_from_phys(phys))
}

// owns reports whether global bit index `g` (LSB-0 numbering) belongs to this
// signal. Little-endian signals occupy a contiguous range; big-endian (Motorola)
// signals zig-zag across bytes, so we walk the sawtooth to test membership.
pub fn (s Signal) owns(g int) bool {
	if s.byte_order == .little_endian {
		return g >= s.start_bit && g < s.start_bit + s.length
	}
	mut pos := s.start_bit
	for _ in 0 .. s.length {
		if pos == g {
			return true
		}
		pos = if pos % 8 == 0 { pos + 15 } else { pos - 1 }
	}
	return false
}

// signal_at returns the index of the signal owning global bit `g`, or -1.
pub fn (m Message) signal_at(g int) int {
	for i, s in m.signals {
		if s.owns(g) {
			return i
		}
	}
	return -1
}

// multiplexor_index returns the index of the message's multiplexor switch
// signal ('M'), or -1 if the message is not multiplexed.
pub fn (m Message) multiplexor_index() int {
	for i, s in m.signals {
		if s.is_multiplexor {
			return i
		}
	}
	return -1
}

// active_signals returns the signals actually present in `data`: every
// non-multiplexed signal, plus the multiplexed signals whose selector matches
// the current value of the multiplexor switch. For a non-multiplexed message it
// returns all signals unchanged.
pub fn (m Message) active_signals(data []u8) []Signal {
	mux_idx := m.multiplexor_index()
	if mux_idx < 0 {
		return m.signals
	}
	mux_val := m.signals[mux_idx].raw_value(data)
	mut out := []Signal{}
	for s in m.signals {
		if !s.is_multiplexed || u64(s.multiplexor_value) == mux_val {
			out << s
		}
	}
	return out
}
