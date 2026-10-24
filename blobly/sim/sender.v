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
// defines the message: its id and DLC, the listed signals encoded onto a zero payload in order (a
// signal listed twice takes its last entry), a multiplexed one only where the switch selects it.
// None when no database defines it.
pub fn sender_message_frame(s project.Sender, dbs []candb.Database, n int, el f64) ?transport.CanFrame {
	for db in dbs {
		for m in db.messages {
			if m.name != s.message {
				continue
			}
			mut data := m.template()
			// the switch first: it decides which multiplexed signals the frame carries, and only
			// those are encoded, so a value kept for another branch never lands on this one's bits
			sw := m.multiplexor_index()
			if sw >= 0 {
				for ss in s.signals {
					if ss.name == m.signals[sw].name {
						m.signals[sw].encode(mut data, sender_value(ss, n, el))
					}
				}
			}
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
			return transport.CanFrame{
				id:       m.id
				extended: m.ext
				data:     data
			}
		}
	}
	return none
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
