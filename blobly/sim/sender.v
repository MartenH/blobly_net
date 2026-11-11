module sim

import blobly.candb
import blobly.project
import blobly.transport

// sender.v — what an interactive generator (`senders:`) puts on the wire: the one frame builder
// the GUI's generators and the headless runner's cyclic senders share, so a project's generator
// sends the same frame however it is run.

// sender_value is one generator signal's value at send `n`, `el` seconds into the run: its value
// SOURCE (sine, sawtooth, counter, stepmod), or its static value when it has none — or has one
// that cannot be evaluated (an unknown type, a zero divisor), which
// project.generator_source_warnings reports rather than sending a constant nobody asked for.
pub fn sender_value(ss project.SenderSig, n int, el f64) f64 {
	if ss.wave.typ == '' || project.gen_source_invalid(ss.wave) != '' {
		return ss.value
	}
	return gen_from_cfg(ss.wave).value(el, n)
}

// sender_message_frame encodes a message generator's frame from the first database that
// defines the message: its id and DLC, the listed signals encoded in order onto the payload the
// message starts from (candb.Message.initial: every other signal at its start value, else raw 0; a
// signal listed twice takes its last entry), a multiplexed one only where the switch selects it;
// its format the generator's `format:`, else the message's declared one (project.message_format).
// An error when no database defines it, or the payload is past its stated format.
pub fn sender_message_frame(s project.Sender, dbs []candb.Database, n int, el f64) !transport.CanFrame {
	for db in dbs {
		for m in db.messages {
			if m.name != s.message {
				continue
			}
			// the switch first: it decides which multiplexed signals the frame carries, and only
			// those are encoded, so a value kept for another branch never lands on this one's bits
			sw := m.multiplexor_index()
			mut switch_raw := ?u64(none)
			if sw >= 0 {
				for ss in s.signals {
					if ss.name == m.signals[sw].name {
						switch_raw = m.signals[sw].raw_from_phys(sender_value(ss, n, el))
					}
				}
			}
			mut data := m.initial(switch_raw)
			carried := m.carried(data)
			for ss in s.signals {
				for i, sig in m.signals {
					if sig.name == ss.name {
						if i != sw && (!sig.is_multiplexed || carried[i]) {
							sig.encode(mut data, sender_value(ss, n, el))
						}
						break
					}
				}
			}
			return project.message_format(m, s.format).stamp(transport.CanFrame{
				id:       m.id
				extended: m.ext
				data:     data
			})!
		}
	}
	return error('message "${s.message}" is not in the channel databases')
}

// sender_raw_frame is a raw generator's frame (id, kind, payload), its format the generator's
// `format:`; an error for a payload past it.
pub fn sender_raw_frame(s project.Sender, id u32, ext bool, data []u8) !transport.CanFrame {
	return s.format.stamp(transport.CanFrame{
		id:       id
		extended: ext
		data:     data
	})!
}

// sender_signal_refusals says each signal the generator lists that carries no number in the first
// database defining its message (candb.Signal.scalar_refusal), one line each: said at Start, and
// never encoded by sender_message_frame.
pub fn sender_signal_refusals(s project.Sender, dbs []candb.Database) []string {
	if s.message == '' {
		return []
	}
	for db in dbs {
		m := db.message_named(s.message) or { continue }
		mut out := []string{}
		mut said := map[string]bool{}
		for ss in s.signals {
			sig := m.signal_named(ss.name) or { continue }
			why := sig.scalar_refusal()
			if why != '' && ss.name !in said {
				said[ss.name] = true
				out << 'generator "${s.name}": ${why} — not sent'
			}
		}
		return out
	}
	return []
}

// next_due is when a frame on a `period` grid is next due, the last one sent in grid slot `slot`
// and its write returned at `done` (all in one clock's units): the first slot after `done`, so a
// write that outlasted a period skips the slots it covered rather than being followed by frames
// sent back to back. A zero period is due at `done`.
pub fn next_due(slot u64, period u64, done u64) u64 {
	if period == 0 {
		return done
	}
	if slot + period > done {
		return slot + period
	}
	return slot + ((done - slot) / period + 1) * period
}

// wait_until is how long a sending loop waits at `now` for a frame due at `due` (one clock's
// units): none when it is due already, never longer than `cap`, which bounds how late the loop
// sees a stop or a change.
pub fn wait_until(due u64, now u64, cap u64) u64 {
	if due <= now {
		return 0
	}
	return if due - now < cap { due - now } else { cap }
}
