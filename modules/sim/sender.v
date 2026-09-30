module sim

import candb
import project
import transport

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
// defines the message: its id and DLC, the listed signals encoded onto a zero payload. None when
// no database defines it.
pub fn sender_message_frame(s project.Sender, dbs []candb.Database, n int, el f64) ?transport.CanFrame {
	for db in dbs {
		for m in db.messages {
			if m.name != s.message {
				continue
			}
			mut data := []u8{len: m.dlc}
			for ss in s.signals {
				for sig in m.signals {
					if sig.name == ss.name {
						sig.encode(mut data, sender_value(ss, n, el))
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
