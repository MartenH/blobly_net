// Checking the protection on frames we RECEIVE.
//
// e2e.v protects what the simulation sends. This is the other half: given a frame from the ECU
// under test, does its alive counter advance and does its checksum match? Without it the tool
// can drive a bench but cannot fail one — a unit whose own protection is broken looks exactly
// like a unit whose protection is fine, and the fault ships.
//
// Deliberately stateless per call except for the counter, which cannot be judged from a single
// frame: "did it advance" is a question about the previous one. `Verifier` holds only that.
module sim

import candb
import project

// Violation is what is wrong with a received frame, if anything.
pub enum Violation {
	ok
	truncated   // shorter than the DBC message: its protection fields are not all present
	bad_crc     // the checksum does not match the payload
	stalled_ctr // the alive counter repeated
	skipped_ctr // the counter jumped — frames were lost, or the sender restarted
}

// str is the short form used in the trace, where space is scarce and the reader is scanning.
pub fn (v Violation) str() string {
	return match v {
		.ok { '' }
		.truncated { '!LEN' }
		.bad_crc { '!CRC' }
		.stalled_ctr { '!CNT stalled' }
		.skipped_ctr { '!CNT skipped' }
	}
}

// Verifier checks one message's protection across successive frames.
pub struct Verifier {
pub:
	msg candb.Message
	e2e E2e
pub mut:
	// u64 with an explicit "nothing yet" flag rather than a signed sentinel: a counter may be
	// wide, and narrowing it into an int made a high-bit value look negative — which read as
	// "first frame" and skipped the check on every frame after it.
	last_ctr u64
	have_ctr bool
	seen     u64 // frames checked
	bad      u64 // frames that failed
}

// check judges one received payload.
//
// Order matters here as much as it does when stamping: the checksum is verified against the
// frame EXACTLY as received, before anything is inferred from the counter, because a frame
// whose checksum is wrong tells us nothing reliable about its counter — those bits are just as
// likely to be corrupt.
pub fn (mut v Verifier) check(data []u8) Violation {
	v.seen++
	// A short frame cannot be judged: the missing checksum and counter bits read as zero, and
	// an EMPTY payload computes zero for every supported checksum — which then matches the
	// absent checksum field and sails through the first-counter rule as clean. A malformed
	// frame must not be able to look better than a well-formed one.
	if data.len < v.msg.dlc {
		v.bad++
		return .truncated
	}
	if v.e2e.crc != '' {
		for sig in v.msg.active_signals(data) {
			if sig.name != v.e2e.crc {
				continue
			}
			got := u8(sig.raw_value(data))
			mut probe := data.clone()
			sig.set_raw(mut probe, 0) // the sender computes with this field zeroed
			mut input := probe.clone()
			if id := v.e2e.data_id {
				input << u8(id & 0xFF)
				input << u8((id >> 8) & 0xFF)
				input << u8((id >> 16) & 0xFF)
				input << u8((id >> 24) & 0xFF)
			}
			if got != v.e2e.checksum_of(input) {
				v.bad++
				return .bad_crc
			}
			break
		}
	}
	if v.e2e.counter == '' {
		return .ok
	}
	for sig in v.msg.active_signals(data) {
		if sig.name != v.e2e.counter {
			continue
		}
		cur := sig.raw_value(data)
		// The modulus is the signal's own width, at any width: forcing it to zero past 30 bits
		// turned a legal 31-bit wrap into a reported skip.
		span := if sig.length >= 64 { u64(0) } else { u64(1) << sig.length }
		prev := v.last_ctr
		had := v.have_ctr
		v.last_ctr = cur
		v.have_ctr = true
		if !had {
			return .ok // first frame: there is nothing to compare against
		}
		expect := if span > 0 { (prev + 1) % span } else { prev + 1 }
		if cur == prev {
			v.bad++
			return .stalled_ctr
		}
		if cur != expect {
			// A jump is not automatically the sender's fault — frames can be lost on a real
			// bus — but it is exactly what a receiver would reject, so it is reported and the
			// operator decides. Reporting only stalls would miss a sender that skips.
			v.bad++
			return .skipped_ctr
		}
		break
	}
	return .ok
}

// VerifySet is the verifiers for one channel.
//
// Keyed by id AND frame format, which is what identifies a CAN message — the database merge
// already treats them as distinct. Keyed on the number alone, a standard and an extended
// message sharing a raw id overwrote each other and one verifier judged both formats, merging
// two independent counter streams into a stream of reported skips.
pub struct VerifySet {
pub mut:
	by_key map[string]Verifier
}

// vkey identifies a message the way the rest of the codebase does.
pub fn vkey(id u32, ext bool) string {
	return '${id}|${ext}'
}

// verifiers_for builds the set a channel should check, from the same `protect:` configuration
// that decides what the simulation stamps.
//
// Reusing that configuration is the point: a project describes each protected message once, and
// both directions follow it. Having to declare "check this on receive" separately would let the
// two drift, and the drift would look like a bug in the ECU.
pub fn verifiers_for(db candb.Database, nodes []project.NodeCfg) VerifySet {
	mut out := VerifySet{}
	for n in nodes {
		for p in n.protect {
			// messages_from, not db.messages: the STAMPING path scopes to the sender, so a
			// merged database with the same message name on two transmitters could otherwise
			// verify against a different id, layout and field positions than were sent.
			for m in db.messages_from(n.name) {
				if m.name != p.message {
					continue
				}
				out.by_key[vkey(m.id, m.ext)] = Verifier{
					msg: m
					e2e: E2e{
						counter: p.counter
						crc:     p.crc
						profile: p.profile
						data_id: p.data_id
					}
				}
				break
			}
		}
	}
	return out
}
