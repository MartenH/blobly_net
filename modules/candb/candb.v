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
	// DECLARED J1939, from `BA_ "VFrameFormat" … J1939PG`. False means "the file did not say
	// so", never "this is not J1939" — most J1939 DBCs carry no such attribute at all.
	//
	// It exists because a 29-bit id ALONE is not evidence. `j1939_pgn` will compute a PGN for
	// any extended id, and lookup_frame's fallback matches on it, so two unrelated messages —
	// a UDS request and its response, say — can share one. Anything that would make a CLAIM
	// about a frame from a PGN match needs the file to have said the bus is J1939; anything
	// merely choosing how to decode a frame it already has may use the fallback and accept the
	// ambiguity (#95).
	j1939   bool
	// The E2E contract the file DECLARES for this message (#271: `BA_ "E2ECounterSignal"` /
	// `"E2ECrcSignal"` / `"E2EProfile"` / `"E2EDataId"` / `"E2ETimeout"`, docs/dbc_attributes.md) — stated once in the file the whole
	// bench shares, for its sender to stamp and its receivers to check. The simulation stamps it
	// (sim.protection_for); `verify:` checks only what a verify: entry names. Empty when the
	// file does not declare one.
	e2e     E2eDecl
	signals []Signal
}

// E2eDecl is a message's declared E2E contract: the counter and CRC SIGNALS (so positions come
// from the layout), the profile (`autosar_p01`, or one of the primitives in e2e_profiles) and
// the Data ID.
pub struct E2eDecl {
pub mut:
	counter     string
	crc         string
	profile     string
	data_id     u32
	has_data_id bool   // 0 is a legitimate Data ID, so presence is its own fact
	bad_data_id string // an E2EDataId the file wrote that is not a Data ID — never read as absent
	// E2ETimeout: a receiver's E2E sender-loss timeout in ms (REQ-E2E-002 on blobly_emb), 0
	// meaning none. The simulation does not use it; it is carried so a Save and an export keep it.
	timeout_ms  u32
	has_timeout bool   // stated per message (0 included)
	bad_timeout string // an E2ETimeout the file wrote that is not a number of ms
}

// e2e_p01_dbc is how a DBC spells AUTOSAR E2E Profile 1 in `E2EProfile` (docs/dbc_attributes.md).
pub const e2e_p01_dbc = 'P01'

// profile_from_dbc is the profile an `E2EProfile` value names: Profile 1 under any of its
// spellings — `P01`, AUTOSAR's `PROFILE_01`, and `autosar_p01`, the name the simulation uses —
// and anything else as written, for the validators to refuse or accept.
pub fn profile_from_dbc(v string) string {
	return if v in ['P01', 'PROFILE_01', 'autosar_p01'] { 'autosar_p01' } else { v }
}

// profile_to_dbc is the `E2EProfile` value a profile is written as.
pub fn profile_to_dbc(p string) string {
	return if profile_from_dbc(p) == 'autosar_p01' { e2e_p01_dbc } else { p }
}

// declared: the file said anything about this message's E2E at all.
pub fn (d E2eDecl) declared() bool {
	return d.counter != '' || d.crc != '' || d.profile != '' || d.has_data_id || d.bad_data_id != ''
}

// states_anything: the file wrote any E2E attribute for this message — a receiver-only timeout
// included, which on its own declares no protection.
pub fn (d E2eDecl) states_anything() bool {
	return d.declared() || d.has_timeout || d.bad_timeout != ''
}

// follow_rename keeps the declaration naming a signal the editor renamed.
pub fn (mut d E2eDecl) follow_rename(old string, new string) {
	if d.counter == old {
		d.counter = new
	}
	if d.crc == old {
		d.crc = new
	}
}

// forget drops a deleted signal from the declaration — which then says it is incomplete, rather
// than naming a signal that no longer exists.
pub fn (mut d E2eDecl) forget(name string) {
	if d.counter == name {
		d.counter = ''
	}
	if d.crc == name {
		d.crc = ''
	}
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
// masked to the signal width for signed signals). Only the WIDTH is enforced: a value past what
// the width holds clamps to its nearer end (an unsigned signal's negative to 0, its overflow to
// the mask; ±inf likewise), and NaN encodes as raw 0. The DBC's [min|max] is NOT applied — a
// tester must be able to send an out-of-range value on purpose.
pub fn (s Signal) raw_from_phys(phys f64) u64 {
	// round half away from zero; a bare `+ 0.5` truncates negatives wrongly.
	r := math.round((phys - s.offset) / s.factor)
	if math.is_nan(r) {
		return 0 // stated rather than left to a C cast, which is undefined for NaN
	}
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
		// through i64: a negative's two's-complement pattern masked to the width IS the raw value
		return u64(i64(r)) & mask
	}
	if r >= f64(mask) + 1.0 {
		// f64(mask) + 1 is exactly 2^length for every width, 64 included
		return mask
	}
	if r < 0 {
		return 0 // below an unsigned width: its bottom end, never wrapped to the top
	}
	// through u64 DIRECTLY — via i64 it saturates at 2^63, so the top half of an unsigned
	// 64-bit signal's domain encoded as INT64_MIN.
	return u64(r) & mask
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
