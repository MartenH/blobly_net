// End-to-end protection for simulated frames: an alive counter and a checksum,
// applied AFTER the signal generators have encoded the payload.
//
// Why this exists: a real ECU does not accept a frame just because the bits are in the
// right places. Production networks protect safety-relevant messages with a counter that
// must advance every cycle and a checksum over the payload, and the receiver rejects — and
// usually DTC-flags — anything that fails either test. Without this, a rest-bus simulation
// can drive a demo bus but cannot talk to the ECU you actually want to test.
//
// Scope: the frame-level mechanics (counter wrap, checksum coverage, the order the two are
// applied in). Two kinds of profile:
//  - `autosar_p01`: AUTOSAR E2E Profile 1 as specified — the one to use against an AUTOSAR (or
//    blobly_emb) receiver. Pinned by vectors taken from an independent implementation
//    (autosar-e2e, sut/e2e_oracle.py);
//  - the checksum PRIMITIVES (`crc8_j1850`, `crc8_autosar`, `sum8`, `xor8`) under blobly's own
//    coverage rule (below), for the OEM schemes no AUTOSAR profile describes.
module sim

import candb
import project

// crc8_j1850 — CRC-8/SAE-J1850: poly 0x1D, init 0xFF, final xor 0xFF, no reflection. AUTOSAR
// E2E Profile 1 uses the same polynomial with start 0x00 and no final XOR (`p01_crc`).
// Check value: crc8_j1850('123456789') == 0x4B, pinned in e2e_test.v.
pub fn crc8_j1850(data []u8) u8 {
	return crc8_with(data, 0x1D, 0xFF, 0xFF)
}

// crc8_autosar — CRC-8/AUTOSAR ("CRC8H2F"): poly 0x2F, otherwise as above. Better error
// detection over short payloads, and what AUTOSAR E2E profile 2 uses — picking crc8_j1850 for
// a profile-2 receiver produces a different checksum and it rejects every frame.
// Check value: 0xDF.
pub fn crc8_autosar(data []u8) u8 {
	return crc8_with(data, 0x2F, 0xFF, 0xFF)
}

// crc8_with is CRC-8 over `poly`, unreflected, from `init`, XORed with `xorout` at the end.
fn crc8_with(data []u8, poly u8, init u8, xorout u8) u8 {
	mut crc := init
	for b in data {
		crc ^= b
		for _ in 0 .. 8 {
			// bit-at-a-time; a table would buy nothing at CAN payload sizes (≤64 bytes)
			crc = if crc & 0x80 != 0 { (crc << 1) ^ poly } else { crc << 1 }
		}
	}
	return crc ^ xorout
}

// sum8 — the low byte of the arithmetic sum. Not a CRC; included because a large number of
// OEM-specific "checksum" signals are exactly this, and calling it a CRC would misdescribe it.
pub fn sum8(data []u8) u8 {
	mut s := u32(0)
	for b in data {
		s += b
	}
	return u8(s & 0xFF)
}

// xor8 — all bytes XORed together. As above: simple, common, and not a CRC.
pub fn xor8(data []u8) u8 {
	mut x := u8(0)
	for b in data {
		x ^= b
	}
	return x
}

// E2e describes the protection applied to ONE simulated message.
//
// `counter` and `crc` name signals of that message, so the placement, width and byte order
// all come from the DBC — this struct never re-states them, and a signal moved in the DBC
// moves here too.
pub struct E2e {
pub mut:
	counter string // signal carrying the alive counter ('' = no counter)
	crc     string // signal carrying the checksum ('' = no checksum)
	profile string // 'autosar_p01' | 'crc8_j1850' | 'crc8_autosar' | 'sum8' | 'xor8'
	// Mixed into the checksum. For a primitive, as four trailing little-endian bytes; for
	// autosar_p01, as its 16-bit Data ID per `data_id_mode`. An OPTION, not a plain u32 with
	// 0 meaning "unset": 0 is a legitimate Data ID, and a receiver using it expects it in the
	// checksum input — omitting it yields a different CRC and rejects every frame.
	data_id ?u32
	// autosar_p01's DataIDMode: 'both' (default: low byte, then high), 'low', or 'alt' (the
	// low byte when the counter is even, the high byte when odd). NIBBLE is not supported.
	data_id_mode string
}

pub const p01 = 'autosar_p01'

// declared_e2e is the protection a message's DBC declares (#271), if it declares a usable one:
// what its sender stamps when no protect: entry says otherwise. The reason is returned beside it
// when the declaration cannot be applied, for validate_protection to say.
pub fn declared_e2e(m candb.Message) ?E2e {
	if !m.e2e.declared() {
		return none
	}
	e := e2e_of_decl(m.e2e)
	if declared_problem(m, e) != '' {
		return none
	}
	return e
}

// e2e_of_decl is the protection a DBC declaration states — the one conversion.
pub fn e2e_of_decl(d candb.E2eDecl) E2e {
	return E2e{
		counter: d.counter
		crc:     d.crc
		profile: d.profile
		data_id: if d.has_data_id { ?u32(d.data_id) } else { none }
	}
}

// declared_problem says why a message's DBC E2E declaration cannot be stamped — '' when it can.
pub fn declared_problem(m candb.Message, e E2e) string {
	if e.profile !in candb.e2e_profiles {
		return 'its profile "${e.profile}" is not one this app implements'
	}
	if e.counter == '' && e.crc == '' {
		return 'it names neither a counter nor a crc signal'
	}
	for name in [e.counter, e.crc] {
		if name != '' && !m.signals.any(it.name == name) {
			return '"${name}" is not a signal of ${m.name}'
		}
	}
	if why := p01_problem(m, e) {
		return why
	}
	return ''
}

// e2e_of is the protection a protect: or verify: entry describes — the ONE place an entry
// becomes an E2e, so the stamping, the checking and the panels cannot each carry a subset.
pub fn e2e_of(p project.ProtectCfg) E2e {
	return E2e{
		counter:      p.counter
		crc:          p.crc
		profile:      p.profile
		data_id:      p.data_id
		data_id_mode: p.data_id_mode
	}
}

// p01_counter_span: a Profile 1 counter runs 0..14 and wraps to 0 — 15 is invalid.
const p01_counter_span = u64(15)

// counter_span is the counter's modulus: P01's, or what the signal's width holds.
fn (e E2e) counter_span(sig candb.Signal) u64 {
	if e.profile == p01 {
		return p01_counter_span
	}
	return if sig.length >= 64 { u64(0) } else { u64(1) << sig.length }
}

// crc_byte is the byte an 8-bit, byte-aligned checksum signal occupies — the only shape
// Profile 1 defines, since its CRC skips that byte of the frame.
pub fn crc_byte(sig candb.Signal) ?int {
	if sig.length != 8 {
		return none
	}
	aligned := if sig.byte_order == .little_endian { sig.start_bit % 8 == 0 } else { sig.start_bit % 8 == 7 }
	return if aligned { sig.start_bit / 8 } else { none }
}

// p01_problem says why `e` cannot be stamped or checked as AUTOSAR Profile 1 on `msg`, if it
// cannot — the ONE rule the protect: and verify: validation both ask.
pub fn p01_problem(msg candb.Message, e E2e) ?string {
	if e.profile != p01 {
		return none
	}
	id := e.data_id or { return 'autosar_p01 needs a data_id' }
	if id > 0xFFFF {
		return 'autosar_p01 data_id 0x${id:X} does not fit its 16 bits'
	}
	if e.data_id_mode !in ['', 'both', 'low', 'alt'] {
		return 'autosar_p01 data_id_mode "${e.data_id_mode}" is not both, low or alt'
	}
	if e.crc == '' {
		return 'autosar_p01 needs a crc signal'
	}
	if e.counter == '' {
		return 'autosar_p01 needs a counter signal (a 4-bit alive counter is part of the profile)'
	}
	for sig in msg.signals {
		if sig.name == e.crc && crc_byte(sig) == none {
			return 'autosar_p01 needs "${e.crc}" to be one whole byte (8 bits, byte-aligned)'
		}
		if sig.name == e.counter && sig.length != 4 {
			return 'autosar_p01 needs a 4-bit counter; "${e.counter}" is ${sig.length} bits'
		}
	}
	return none
}

// checksum is what `sig` (the checksum signal) must hold for `data` as it stands, whatever the
// field holds now: the stamping and the checking path both ask this, so the rule exists once.
fn (e E2e) checksum(msg candb.Message, sig candb.Signal, data []u8) u8 {
	if e.profile == p01 {
		return e.p01_crc(msg, sig, data)
	}
	mut input := data.clone()
	sig.set_raw(mut input, 0) // a checksum cannot cover itself: computed with its field zeroed
	if id := e.data_id {
		// ALL FOUR bytes, little-endian. Appending only the low byte made 0x012A and 0x022A
		// produce identical checksums — two messages the data id exists to keep apart.
		// blobly's own convention for the primitives, not AUTOSAR's (that is autosar_p01).
		input << u8(id & 0xFF)
		input << u8((id >> 8) & 0xFF)
		input << u8((id >> 16) & 0xFF)
		input << u8((id >> 24) & 0xFF)
	}
	return e.checksum_of(input)
}

// p01_crc is AUTOSAR E2E Profile 1's CRC: CRC-8 over poly 0x1D with start value 0x00 and no
// final XOR (AUTOSAR's chained Crc_CalculateCRC8 calls cancel the catalogue's 0xFF/0xFF), over
// the Data ID bytes the mode names, then every byte of the message's DLC except the CRC's own —
// bytes before it included.
fn (e E2e) p01_crc(msg candb.Message, sig candb.Signal, data []u8) u8 {
	at := crc_byte(sig) or { return 0 } // refused by p01_problem; nothing sensible to stamp
	id := e.data_id or { u32(0) }
	mut input := []u8{cap: 2 + msg.dlc}
	match e.data_id_mode {
		'low' {
			input << u8(id)
		}
		'alt' {
			// the counter as this frame carries it: the receiver has nothing else to go by
			mut ctr := u64(0)
			for c in msg.active_signals(data) {
				if c.name == e.counter {
					ctr = c.raw_value(data)
					break
				}
			}
			input << if ctr % 2 == 0 { u8(id) } else { u8(id >> 8) }
		}
		else {
			input << u8(id)
			input << u8(id >> 8)
		}
	}
	// the profile's DataLength is the message's: bytes a frame carries past its DBC length
	// (padding, an FD length rounded up) are not the sender's to have covered
	n := if data.len < msg.dlc { data.len } else { msg.dlc }
	for i in 0 .. n {
		if i != at {
			input << data[i]
		}
	}
	return crc8_with(input, 0x1D, 0x00, 0x00)
}

// active reports whether anything is protected — a zero E2e is the common case and must cost
// nothing on the send path.
pub fn (e E2e) active() bool {
	return e.counter != '' || e.crc != ''
}

// checksum_of dispatches on the profile. An unknown profile returns a plain sum rather than
// erroring: the alternative is a simulation that silently stops transmitting because of a
// typo in a config field, which is harder to diagnose on a bench than a wrong checksum.
fn (e E2e) checksum_of(data []u8) u8 {
	return match e.profile {
		'crc8_j1850' { crc8_j1850(data) }
		'crc8_autosar' { crc8_autosar(data) }
		'xor8' { xor8(data) }
		else { sum8(data) }
	}
}

// apply stamps the counter and checksum onto an already-encoded payload.
//
// Order is not arbitrary and is the part worth getting right:
//  1. the counter is written first, so it is INSIDE the data the checksum covers — a receiver
//     that validated the checksum but not the counter's contribution would accept a replayed
//     frame with a stale counter;
//  2. the checksum never covers its own bits (`checksum`: zeroed for a primitive, skipped for
//     autosar_p01), so the result does not depend on what the previous cycle left there;
//  3. `data_id` is mixed into the CHECKSUM INPUT ONLY — it never occupies payload space; it
//     exists so two messages with identical bytes produce different checksums, which is what
//     stops a frame being replayed onto a different id.
//
// `n` is the send index; the counter is `n` modulo `counter_span` — what its DBC signal can
// hold, or Profile 1's 0..14 — so it wraps exactly where the receiver expects.
pub fn (e E2e) apply(msg candb.Message, mut data []u8, n int) {
	if !e.active() {
		return
	}
	// Only signals ACTUALLY PRESENT in this payload. A multiplexed message's branches may
	// legally reuse the same bits, so writing a checksum field belonging to an inactive branch
	// would corrupt the active one. For a non-multiplexed message active_signals returns
	// everything, so this costs nothing in the ordinary case.
	if e.counter != '' {
		for sig in msg.active_signals(data) {
			if sig.name == e.counter {
				span := e.counter_span(sig)
				v := if span == 0 { u64(n) } else { u64(n) % span }
				// set_raw, NOT encode: a counter is a raw field value, not a physical
				// quantity. encode() would divide by the signal's factor and subtract its
				// offset, so a DBC that declares the counter with factor 0.5 — legal, and
				// nothing stops it — would transmit 2n and fail every receiver check.
				sig.set_raw(mut data, v)
				break
			}
		}
	}
	if e.crc == '' {
		return
	}
	// recomputed after the counter write: if the counter is itself the multiplexor switch,
	// the active branch has just changed
	for sig in msg.active_signals(data) {
		if sig.name != e.crc {
			continue
		}
		// raw again — the checksum byte must land in the field bit-for-bit
		sig.set_raw(mut data, u64(e.checksum(msg, sig, data)))
		break
	}
}
