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
	if !sourced(ss) {
		return ss.value
	}
	return gen_from_cfg(ss.wave).value(el, n)
}

// sourced is whether generator signal `ss` takes its value from its source: it has one, and one
// that can be evaluated.
fn sourced(ss project.SenderSig) bool {
	return ss.wave.typ != '' && project.gen_source_invalid(ss.wave) == ''
}

// sender_message_frame encodes a message generator's frame from the first database that
// defines the message: its id and DLC, the listed signals encoded in order onto the payload the
// message starts from (candb.Message.initial: every other signal at its start value, else raw 0; a
// signal listed twice takes its last entry), each only where the frame carries it (payload_of),
// the bits no signal covers at its fill (project.Sender.sent_message); its format the generator's
// `format:`, else the message's declared one (project.message_format).
// An error when no database defines it, or the payload is past its stated format.
pub fn sender_message_frame(s project.Sender, dbs []candb.Database, n int, el f64) !transport.CanFrame {
	m := sender_message_of(s, dbs) or {
		return error('message "${s.message}" is not in the channel databases')
	}
	mut vals := []SetValue{cap: s.signals.len}
	sender_values(mut vals, s, n, el)
	return sender_frame(m, s.format, vals)
}

// sender_message_of is the message a message generator's frames are built from: its first
// definition in `dbs`, as that database sends it (project.Sender.sent_message); none where no
// database defines it. Found once by a sender that keeps it.
pub fn sender_message_of(s project.Sender, dbs []candb.Database) ?candb.Message {
	for db in dbs {
		for dm in db.messages {
			if dm.name == s.message {
				return s.sent_message(db, dm)
			}
		}
	}
	return none
}

// sender_values puts generator `s`'s signal values at send `n`, `el` seconds into the run, into
// `out` (emptied first, its storage kept), in the order it lists them (sender_value).
pub fn sender_values(mut out []SetValue, s project.Sender, n int, el f64) {
	out.clear()
	for ss in s.signals {
		out << SetValue{ss.name, sender_value(ss, n, el)}
	}
}

// sender_varies is whether generator `s`'s frame may differ from one send to the next: a signal
// on a value source sender_value evaluates. Every other frame is the same until it is edited.
pub fn sender_varies(s project.Sender) bool {
	return s.signals.any(sourced(it))
}

// sender_frame is message `m`'s frame (sender_message_of) with the signal values `vals` encoded
// in order (payload_of), the bits no signal covers at its fill, in format `ff` where stated, else
// the message's declared one (project.message_format); an error for a payload past it.
pub fn sender_frame(m candb.Message, ff transport.FrameFormat, vals []SetValue) !transport.CanFrame {
	mut data := payload_of(m, vals)
	m.fill_unused(mut data)
	return project.message_format(m, ff).stamp(transport.CanFrame{
		id:       m.id
		extended: m.ext
		data:     data
	})!
}

// sender_messages are the messages a generator whose frame is built from `dbs` (its target rows'
// databases) can send, in load order, each name once at its first definition: the one
// sender_message_frame encodes, so the editor offers and describes what a fire sends.
pub fn sender_messages(dbs []candb.Database) []candb.Message {
	mut out := []candb.Message{}
	mut seen := map[string]bool{}
	for db in dbs {
		for m in db.messages {
			if m.name !in seen {
				seen[m.name] = true
				out << m
			}
		}
	}
	return out
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

// sender_j1939 says whether the message generator `s` sends is one its first defining database
// declares J1939 (`VFrameFormat` J1939PG), the message whose frame sender_message_frame builds — so
// past eight bytes on a classic row it goes out as a BAM (j1939.message_frames).
pub fn sender_j1939(s project.Sender, dbs []candb.Database) bool {
	if s.message == '' {
		return false
	}
	for db in dbs {
		for m in db.messages {
			if m.name == s.message {
				return m.j1939
			}
		}
	}
	return false
}

// slots_skipped is how many slots of a `period` grid lie strictly between slot `slot` and slot
// `next` (next_due's answer): the frames a sender left out because its last write, or its loop,
// was late. 0 for a zero period, or a `next` less than a period after `slot`.
pub fn slots_skipped(slot u64, period u64, next u64) u64 {
	if period == 0 || next < slot + period {
		return 0
	}
	return (next - slot) / period - 1
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
