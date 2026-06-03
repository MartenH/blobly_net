// candb — minimal CAN signal database: messages, signals, and bit-level
// encode/decode. GUI-free and independently testable (see candb_test.v). This
// is the foundation the DBC phase will build on; for now signals are defined in
// code. Intel (little-endian) bit ordering only, for now.
module candb

import math

pub enum ByteOrder {
	little_endian // Intel
	big_endian    // Motorola — not yet implemented
}

pub struct Signal {
pub:
	name       string
	start_bit  int // global bit index of the signal's least-significant bit
	length     int // width in bits
	factor     f64 = 1.0
	offset     f64
	unit       string
	desc       string // human-readable description / interpretation
	is_signed  bool
	byte_order ByteOrder = .little_endian
}

pub struct Message {
pub:
	name    string
	id      u32
	dlc     int
	signals []Signal
}

// raw_value extracts the unsigned raw bits of the signal from `data` (Intel/LE).
pub fn (s Signal) raw_value(data []u8) u64 {
	mut raw := u64(0)
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

// set_raw writes `raw` into `data` at the signal's bit position (Intel/LE).
pub fn (s Signal) set_raw(mut data []u8, raw u64) {
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

// owns reports whether global bit index `g` belongs to this signal.
pub fn (s Signal) owns(g int) bool {
	return g >= s.start_bit && g < s.start_bit + s.length
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
