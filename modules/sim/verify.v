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
			// Compare the WHOLE field at its declared width. Narrowing to u8 threw away the
			// upper bits of a wider checksum — a frame whose low byte happened to match read
			// as clean — while a narrower field is truncated by the sender when stamped, so
			// comparing against the full 8-bit value labelled the sender's own frames !CRC.
			w := mask_of_bits(sig.length)
			got := sig.raw_value(data) & w
			mut probe := data.clone()
			sig.set_raw(mut probe, 0) // the sender computes with this field zeroed
			mut input := probe.clone()
			if id := v.e2e.data_id {
				input << u8(id & 0xFF)
				input << u8((id >> 8) & 0xFF)
				input << u8((id >> 16) & 0xFF)
				input << u8((id >> 24) & 0xFF)
			}
			if got != u64(v.e2e.checksum_of(input)) & w {
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

fn mask_of_bits(bits int) u64 {
	return if bits >= 64 { ~u64(0) } else { (u64(1) << bits) - 1 }
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

// resolve returns the verifier key for a received frame, adopting a J1939 PGN match when the
// exact id is unknown — a live frame carries a different priority and source address than the
// DBC records, so an exact key never matches it.
//
// Lives here rather than in the GUI because it decides how received wire frames are
// INTERPRETED, and a frontend-local copy would give every other consumer different semantics.
// Counter state is kept per ACTUAL id: two source addresses are two senders with two
// independent sequences.
pub fn (mut s VerifySet) resolve(dbs []candb.Database, id u32, ext bool) ?string {
	k := vkey(id, ext)
	if k in s.by_key {
		return k
	}
	for db in dbs {
		m := db.lookup_frame(id, ext) or { continue }
		src := vkey(m.id, m.ext)
		if src !in s.by_key {
			continue
		}
		proto := s.by_key[src] or { continue }
		s.by_key[k] = Verifier{
			msg: proto.msg
			e2e: proto.e2e
		}
		return k
	}
	return none
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
pub fn verifiers_for(db candb.Database, nodes []project.NodeCfg, verify []project.ProtectCfg) VerifySet {
	mut out := VerifySet{}
	// Channel-level `verify:` FIRST, because it describes the ECU under test — the one node a
	// rest-bus setup deliberately does not simulate, and therefore the one whose protection no
	// simulated node's `protect:` can ever describe. Its messages are found anywhere in the
	// database, since we are not the sender.
	for p in verify {
		for m in db.messages {
			if m.name != p.message {
				continue
			}
			if want := p.id {
				if m.id != want {
					continue // an explicit id disambiguates a name carried by several messages
				}
			}
			if want := p.extended {
				if m.ext != want {
					continue // one id can exist in BOTH formats; the selector must say which
				}
			}
			if !verify_usable(m, p) {
				break // reported by validate_verify; building it anyway checks the wrong thing
			}
			k := vkey(m.id, m.ext)
			if k in out.by_key {
				break // first wins; a duplicate is reported by validate_verify
			}
			out.by_key[k] = Verifier{
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
	for n in nodes {
		for p in n.protect {
			// messages_from, not db.messages: the STAMPING path scopes to the sender, so a
			// merged database with the same message name on two transmitters could otherwise
			// verify against a different id, layout and field positions than were sent.
			for m in db.messages_from(n.name) {
				if m.name != p.message {
					continue
				}
				k := vkey(m.id, m.ext)
				if k !in out.by_key {
					out.by_key[k] = Verifier{
						msg: m
						e2e: E2e{
							counter: p.counter
							crc:     p.crc
							profile: p.profile
							data_id: p.data_id
						}
					}
				}
				break
			}
		}
	}
	return out
}

// verify_usable is the single definition of "this entry will actually check something".
//
// The builder and the validator both consult it, because they disagreed: validation reported a
// malformed id as "ignored" while verifiers_for went ahead and built a verifier for the
// repaired value — so the measurement logged a warning and then checked the wrong frame, which
// is worse than either alone. One predicate, no drift.
pub fn verify_usable(m candb.Message, p project.ProtectCfg) bool {
	if p.id_malformed || p.data_id_malformed {
		return false
	}
	if p.counter == '' && p.crc == '' {
		return false
	}
	if p.counter != '' && p.counter == p.crc {
		return false // one field cannot be both; see validate_verify for why
	}
	if p.crc != '' && p.profile !in ['crc8_j1850', 'crc8_autosar', 'sum8', 'xor8'] {
		return false
	}
	mut have := map[string]candb.Signal{}
	for sg in m.signals {
		have[sg.name] = sg
	}
	for name in [p.counter, p.crc] {
		if name == '' {
			continue
		}
		sg := have[name] or { return false }
		if sg.is_multiplexed {
			return false // present only on some frames; the rest would go unchecked
		}
	}
	return true
}

// validate_verify reports channel-level `verify:` entries that will check nothing.
//
// Node-level `protect:` goes through validate_protection; these did not, so a misspelled
// message or signal silently produced no verifier at all and every frame came back clean —
// disabling the bench check the user believes is running. A check that quietly does nothing is
// worse than no check, because it is trusted.
pub fn validate_verify(db candb.Database, verify []project.ProtectCfg) []string {
	mut warns := []string{}
	mut claimed := map[string]string{}
	for p in verify {
		if p.id_malformed {
			// a stripped character produces a different VALID id, so the entry binds to
			// whatever lives there and no range check can see the mistake
			warns << 'verify: the id on "${p.message}" is not a valid number — entry ignored'
			continue
		}
		if p.crc != '' && p.profile !in ['crc8_j1850', 'crc8_autosar', 'sum8', 'xor8'] {
			// checksum_of falls back to sum8, so real traffic using the intended algorithm is
			// reported corrupt while the configuration looks fine
			warns << 'verify: unknown profile "${p.profile}" on ${p.message} — traffic would be reported corrupt'
		}
		mut matches := []candb.Message{}
		for m in db.messages {
			if m.name != p.message {
				continue
			}
			if want := p.id {
				if m.id != want {
					continue
				}
			}
			if want := p.extended {
				if m.ext != want {
					continue
				}
			}
			matches << m
		}
		if matches.len == 0 {
			warns << 'verify: no message "${p.message}" in the database — nothing is checked'
			continue
		}
		if matches.len > 1 {
			ids := matches.map('0x${it.id:X}${if it.ext { ' ext' } else { '' }}').join(', ')
			warns << 'verify: "${p.message}" matches several messages (${ids}) — add an id:/extended: to say which'
			continue
		}
		m := matches[0]
		// Two entries resolving to ONE message: the second replaced the first, so naming a
		// counter in one and a checksum in the other silently disabled half the checks.
		k := '${m.id}|${m.ext}'
		if prev := claimed[k] {
			warns << 'verify: "${p.message}" and "${prev}" both describe 0x${m.id:X} — only the first applies; put counter and crc in ONE entry'
		}
		claimed[k] = p.message
		mut have := map[string]bool{}
		for sg in m.signals {
			have[sg.name] = true
		}
		if p.data_id_malformed {
			warns << 'verify: the data_id on "${p.message}" is not a valid number — entry ignored'
		}
		if p.counter != '' && p.counter == p.crc {
			// check() validates that field as a checksum and then reads the SAME bits as an
			// alive counter, so ordinary frames are reported stalled or skipped whenever their
			// checksum does not happen to increment by one
			warns << 'verify: counter and crc are both "${p.counter}" on ${p.message} — one field cannot be both'
		}
		for sg in m.signals {
			if sg.is_multiplexed && (sg.name == p.counter || sg.name == p.crc) {
				// active_signals excludes it on every frame selecting another branch, so those
				// frames return a clean verdict without the configured check ever running
				warns << 'verify: "${sg.name}" on ${p.message} is multiplexed — frames selecting another branch would go unchecked'
			}
		}
		if p.counter != '' && p.counter !in have {
			warns << 'verify: counter "${p.counter}" is not a signal of ${p.message}'
		}
		if p.crc != '' && p.crc !in have {
			warns << 'verify: checksum "${p.crc}" is not a signal of ${p.message}'
		}
		if p.counter == '' && p.crc == '' {
			warns << 'verify: "${p.message}" names neither counter nor crc — nothing is checked'
		}
	}
	return warns
}
