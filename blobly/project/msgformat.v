module project

import blobly.candb
import blobly.transport

// msgformat.v — the frame format a frame built from a named DBC message goes out in (#607): the
// format its caller states, else the one its database states for it, else none, which leaves it
// to the row and wire it is sent on. The one rule a simulated node, a generator, a background
// sender, Lua's bus.send_message and the C ABI's bb_encode stamp by.

// declared_format is the format message m's database states, as a send states it
// (transport.FrameFormat.stamp): `wire` where it states none — or states classic for a payload
// past eight bytes, which no classic frame carries (frame_format_warnings says so).
pub fn declared_format(m candb.Message) transport.FrameFormat {
	return match m.format {
		.unstated { .wire }
		.classic { if m.payload_len() > 8 { .wire } else { .classic } }
		.fd { .fd }
		.fd_brs { .fd_brs }
	}
}

// message_format is the format a frame of message m goes out in: `chosen` where its caller states
// one, else m's declared format.
pub fn message_format(m candb.Message, chosen transport.FrameFormat) transport.FrameFormat {
	return if chosen != .wire { chosen } else { declared_format(m) }
}

// frame_format_warnings says, for an enabled CAN row and the databases it reads, the messages
// whose stated format the row contradicts: declared CAN-FD on a row that is classic (their frames
// go out FD, which a classic controller cannot carry), and declared classic with a payload past
// eight bytes (sent as the row decides) unless it is J1939, whose long messages ride TP.CM/TP.DT. One line per kind, said at Start by both front ends.
pub fn frame_format_warnings(ch Channel, dbs []candb.Database) []string {
	if !ch.enabled || ch.kind() != .can {
		return []
	}
	mut fd := []string{}
	mut long := []string{}
	mut seen := map[string]bool{}
	for db in dbs {
		for m in db.messages {
			key := candb.frame_key(m.id, m.ext)
			if key in seen {
				continue // the merge keeps an id's first definition
			}
			seen[key] = true
			if m.format.is_fd() && !ch.origination_framing().fd {
				fd << m.name
			}
			// a J1939 message past eight bytes is a transport-protocol payload, not a frame
			if m.format == .classic && m.payload_len() > 8 && !m.j1939 {
				long << m.name
			}
		}
	}
	mut out := []string{}
	if fd.len > 0 {
		out << '${ch.name} is classic CAN, and its database declares ${fd.len} message(s) CAN-FD (${names_cut(fd)}): sent by a simulated node, a generator or a script, they go out FD'
	}
	if long.len > 0 {
		out << '${ch.name}: ${long.len} message(s) declared classic CAN carry more than 8 bytes (${names_cut(long)}): their stated format is not applied'
	}
	return out
}

// names_cut is the first five names, and how many more.
fn names_cut(names []string) string {
	if names.len <= 5 {
		return names.join(', ')
	}
	return names[..5].join(', ') + ' and ${names.len - 5} more'
}
