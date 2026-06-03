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
pub:
	name       string
	start_bit  int // start bit (LSB for Intel, MSB for Motorola) in LSB-0 numbering
	length     int // width in bits
	factor     f64 = 1.0
	offset     f64
	minimum    f64 // physical range from the DBC [min|max] (0,0 if unspecified)
	maximum    f64
	unit       string
	desc       string            // human-readable description / interpretation
	values     map[u64]string    // DBC VAL_ table: raw value -> named state (enum)
	is_signed  bool
	byte_order ByteOrder = .little_endian
	// Multiplexing (DBC 'M' / 'm<N>'): a message may have ONE multiplexor switch
	// signal; multiplexed signals are only present when the switch equals their
	// selector value. is_multiplexor and is_multiplexed can both be true for
	// extended multiplexing ('m<N>M').
	is_multiplexor bool // 'M' — selects which multiplexed signals are present
	is_multiplexed bool // 'm<N>' — present only when the switch == multiplexor_value
	multiplexor_value int // the N in 'm<N>'
}

// label returns the VAL_ table name for the signal's current raw value in
// `data` (e.g. Gear 3 -> "Third"), or '' if the signal has no value table /
// no entry for that value.
pub fn (s Signal) label(data []u8) string {
	return s.values[s.raw_value(data)]
}

pub struct Message {
pub:
	name    string
	id      u32
	dlc     int
	signals []Signal
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

// physical applies sign-extension, factor and offset: phys = raw * factor + offset.
pub fn (s Signal) physical(data []u8) f64 {
	raw := s.raw_value(data)
	mut v := f64(raw)
	if s.is_signed && s.length > 0 && s.length < 64 {
		sign_bit := u64(1) << (s.length - 1)
		if raw & sign_bit != 0 {
			v = f64(i64(raw) - (i64(1) << s.length)) // two's-complement negative
		}
	}
	return v * s.factor + s.offset
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
	// round half away from zero; a bare `+ 0.5` truncates negatives wrongly.
	mut raw := i64(math.round((phys - s.offset) / s.factor))
	if raw < 0 {
		raw += i64(1) << s.length
	}
	mask := if s.length >= 64 { ~u64(0) } else { (u64(1) << s.length) - 1 }
	s.set_raw(mut data, u64(raw) & mask)
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
