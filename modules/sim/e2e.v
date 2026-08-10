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
// applied in). The concrete algorithms below are the ones that appear on CAN in practice;
// `sum8`/`xor8` cover the many OEM-specific schemes that are just a byte sum.
module sim

import candb

// crc8_j1850 — CRC-8/SAE-J1850: poly 0x1D, init 0xFF, final xor 0xFF, no reflection.
// The checksum AUTOSAR E2E profile 1 is built on (profile 2 uses CRC8H2F — see crc8_autosar).
// Check value: crc8_j1850('123456789') == 0x4B, pinned in e2e_test.v.
pub fn crc8_j1850(data []u8) u8 {
	return crc8_with(data, 0x1D)
}

// crc8_autosar — CRC-8/AUTOSAR ("CRC8H2F"): poly 0x2F, otherwise as above. Better error
// detection over short payloads, and what AUTOSAR E2E profile 2 uses — picking crc8_j1850 for
// a profile-2 receiver produces a different checksum and it rejects every frame.
// Check value: 0xDF.
pub fn crc8_autosar(data []u8) u8 {
	return crc8_with(data, 0x2F)
}

fn crc8_with(data []u8, poly u8) u8 {
	mut crc := u8(0xFF)
	for b in data {
		crc ^= b
		for _ in 0 .. 8 {
			// bit-at-a-time; a table would buy nothing at CAN payload sizes (≤64 bytes)
			crc = if crc & 0x80 != 0 { (crc << 1) ^ poly } else { crc << 1 }
		}
	}
	return crc ^ 0xFF
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
	profile string // 'crc8_j1850' | 'crc8_autosar' | 'sum8' | 'xor8'
	// Mixed into the checksum as four trailing little-endian bytes. An OPTION, not a plain
	// u32 with 0 meaning "unset": 0 is a legitimate Data ID, and a receiver using it expects
	// those four zero bytes in the checksum input — omitting them yields a different CRC and
	// rejects every frame. Presence and value are separate facts, so the type says so.
	data_id ?u32
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
//  2. the checksum's own bits are zeroed before it is computed, so the result does not depend
//     on whatever the previous cycle left there. This is the usual convention and, more
//     importantly, it is the only one that is self-consistent: a checksum cannot cover itself.
//  3. `data_id` is appended as four little-endian bytes of the CHECKSUM INPUT ONLY, so the
//     whole configured value contributes and two ids cannot collide. It never occupies
//     payload space — it exists so two messages with identical bytes produce different
//     checksums, which is what stops a frame being replayed onto a different id.
//
// `n` is the send index; the counter is `n` modulo the width its DBC signal can hold, so it
// wraps exactly where the receiver expects rather than at an arbitrary configured number.
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
				span := if sig.length >= 64 { u64(0) } else { u64(1) << sig.length }
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
		sig.set_raw(mut data, 0) // zero it: a checksum cannot cover itself (see above)
		mut input := data.clone()
		if id := e.data_id {
			// ALL FOUR bytes, little-endian. Appending only the low byte made 0x012A and
			// 0x022A produce identical checksums — two messages the data id exists to keep
			// apart. The full value is appended in a fixed order so the result is
			// reproducible; see docs/restbus.md, and note this is blobly's own convention,
			// not AUTOSAR E2E's 16-bit header layout.
			input << u8(id & 0xFF)
			input << u8((id >> 8) & 0xFF)
			input << u8((id >> 16) & 0xFF)
			input << u8((id >> 24) & 0xFF)
		}
		// raw again — the checksum byte must land in the field bit-for-bit
		sig.set_raw(mut data, u64(e.checksum_of(input)))
		break
	}
}
