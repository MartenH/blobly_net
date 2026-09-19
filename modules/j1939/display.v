// display.v — HOW A J1939 IDENTIFIER READS TO A PERSON (#171).
//
// The trace has nine columns and priority is almost never what anyone is scanning for, so the
// reading is folded into the cells that exist rather than given four new ones: the `id` column
// keeps the raw 29-bit value (it is what sorts, filters, copies and groups), the `name` column
// gains WHO SENT IT, the `flags` column marks a transport session's parts, and the whole split
// is in the hover.
//
// Here and not in the panel, beside `addr_str` and `abort_reason` which are the same kind of
// thing, because every line of it is a reading of the wire format with edges a test must pin: a
// broadcast group has no destination to print, a group the database does not name still has to
// be identified, a session's own frames are named by what they ARE rather than by what they
// carry, and a rebuilt message must never read as something that was on the wire. The GUI rule
// this repo keeps is that a module imports no GUI, not that it never spells anything for a
// person -- and a decision written in `cmd/blobly_net`, which has no tests, is a decision with
// no test, while everything here is covered by `v test modules/`.
module j1939

// Part is a frame's part in a transport session. It lives here, with the rules that read it,
// so a trace row and this reading of it cannot hold two ideas of what a row is.
pub enum Part {
	plain // not a session frame at all — every row that is not one of the three below
	packet // an announcement or a data packet of a session, as it arrived
	bam // a message rebuilt from a broadcast session
	cm // a message rebuilt from a connection-mode session
}

// rebuilt reports whether this row is a message this tool ASSEMBLED rather than a frame it
// received — the one distinction the trace must not blur, since such a row was never on the
// wire in this shape and its identifier is synthesised.
pub fn (t Part) rebuilt() bool {
	return t == .bam || t == .cm
}

// mark is what the flags column shows for it.
pub fn (t Part) mark() string {
	return match t {
		.plain { '' }
		.packet { 'TP' }
		.bam { 'BAM' }
		.cm { 'CM' }
	}
}

// Reading is what a caller must state to get one: the identifier, whether the WIRE was declared
// J1939 (without which the decomposition means nothing — every extended id splits into a
// plausible group number and a plausible source address), the database's name for it if there
// is one, which part of a session it is, and enough of the payload to label a session frame.
pub struct Reading {
pub:
	id       u32
	declared bool // the WIRE was declared J1939 — the caller's question, never this module's
	name     string // the database's name for the group, '' when it names none
	part     Part
	packets  int // the packets a rebuilt message came from
	head     []u8 // the payload's first bytes; two of them label a session frame
	// The destination of a REBUILT message, where the identifier cannot carry one: a broadcast
	// group has no field for it, so a connection-mode transfer of such a group to one node is
	// indistinguishable from a broadcast once its identifier is synthesised. -1 means "ask the
	// identifier", which is every other row.
	to int = -1
}

// name_cell is the name column's text.
//
// The sender goes here because an ordinary bus names a message and a J1939 bus has one
// parameter group arriving from several addresses, so the name alone cannot tell them apart.
// Brackets rather than an arrow: they type into a filter and need no fallback font face.
pub fn name_cell(r Reading) string {
	if !r.declared {
		return r.name
	}
	if r.part == .packet {
		// A session's own frames are named by WHICH PART of the session they are: the name of
		// the group being carried is in the announcement, not in this frame.
		return '${packet_label(r.id, r.head)} ${addr_pair(r.id)}'
	}
	who := if r.name != '' { r.name } else { 'PGN ${decode_id(r.id).pgn():04X}' }
	if r.part.rebuilt() {
		return '${who} ${addr_pair_to(r.id, r.to)} — ${r.packets} packets'
	}
	return '${who} ${addr_pair(r.id)}'
}

// addr_pair is `[00]` for a broadcast and `[00>03]` for a group addressed to one node.
//
// The destination appears only where the identifier HAS one. A broadcast group has no field for
// it, and a group addressed to the global address is a broadcast in the other spelling — both
// would print `>all` on most of the rows on a J1939 bus, which is four characters of noise per
// row to say the ordinary thing.
pub fn addr_pair(id u32) string {
	return addr_pair_to(id, -1)
}

// addr_pair_to is addr_pair with a destination the CALLER knows and the identifier cannot say.
// A connection-mode transfer of a broadcast group is sent to one node, but the identifier
// synthesised for the rebuilt message has no field for that, so without this the row read as a
// broadcast and two transfers to different receivers were one producer (codex).
pub fn addr_pair_to(id u32, to int) string {
	d := decode_id(id)
	da := if to >= 0 { ?u8(u8(to)) } else { d.da() }
	if v := da {
		if v != addr_global {
			return '[${addr_str(d.sa)}>${addr_str(v)}]'
		}
	}
	return '[${addr_str(d.sa)}]'
}

// packet_label says which frame of a session a row is, read from the frame alone: the control
// byte of an announcement, or the sequence number of a data packet.
//
// Never `3 of 5`. How many packets the transfer expects is in its announcement and not in this
// frame, and a denominator this row cannot know is one the trace must not print.
pub fn packet_label(id u32, head []u8) string {
	if head.len == 0 {
		return 'TP'
	}
	if decode_id(id).pf == 0xEB {
		return 'TP.DT #${head[0]}'
	}
	return match head[0] {
		cm_bam { 'TP.CM BAM' }
		cm_rts { 'TP.CM RTS' }
		cm_cts { 'TP.CM CTS' }
		cm_eoma { 'TP.CM EndOfMsgAck' }
		cm_abort {
			if head.len > 1 {
				'TP.CM Abort — ${abort_reason(head[1])}'
			} else {
				'TP.CM Abort'
			}
		}
		else {
			'TP.CM 0x${head[0]:02X}'
		}
	}
}

// tooltip is the whole decomposition, for the hover on the id cell. Priority and the page bits
// live here rather than in a column: they are what somebody looks up when a group is misbehaving
// and never what they scan a screenful of rows for. The group number is given in hex AND in
// decimal because J1939 documents use both, and the filter takes the hex one.
pub fn tooltip(r Reading) string {
	d := decode_id(r.id)
	form := if d.pdu1() { 'PDU1, addressed' } else { 'PDU2, broadcast' }
	dst := if r.to >= 0 {
		addr_str(u8(r.to))
	} else if da := d.da() {
		addr_str(da)
	} else {
		'— (the form has no field for one)'
	}
	mut t := 'J1939  PGN ${d.pgn():04X} (${d.pgn()})\n${form}\nfrom ${addr_str(d.sa)}  to ${dst}\npriority ${d.priority}  EDP ${d.edp}  DP ${d.dp}  PF ${d.pf:02X}  PS ${d.ps:02X}'
	if r.part.rebuilt() {
		t += '\n\nRebuilt here from ${r.packets} packets of a ${r.part.mark()} session. This identifier was never on the wire: it is the group the announcement named, from the sender, at the priority the SESSION ran at, since nothing states what this group would have used had it fitted in one frame.'
	}
	return t
}

// field reads `<name><number>` out of the filter box — `pgn:f004`, `sa:00` — as HEX, which is
// how both are written in this app and in every J1939 document.
//
// A prefix with nothing readable after it is `none` and the caller falls through to its
// ordinary substring search, which matches no row: one keystroke of an empty table while the
// first digit has not landed yet. The filter box is lowercased by its callers, so `PGN:F004`
// arrives here as `pgn:f004`.
pub fn field(filt string, name string) ?u64 {
	if !filt.starts_with(name) {
		return none
	}
	v := filt[name.len..].trim_space()
	if v == '' {
		return none
	}
	return v.parse_uint(16, 64) or { return none }
}

// matches_filter answers the two J1939 filter words for one row, or `none` when the filter is
// not one of them and the caller should search as it always did.
//
// Both are matched against the DECOMPOSITION rather than the row's text, so a filter survives a
// rename in the database and cannot be satisfied by a message whose name happens to contain the
// digits — and both are false on a row the wire did not declare J1939, where an extended
// identifier decomposes just as willingly and would answer a filter it has no business
// answering.
pub fn matches_filter(r Reading, filt string) ?bool {
	if v := field(filt, 'pgn:') {
		return r.declared && u64(decode_id(r.id).pgn()) == v
	}
	if v := field(filt, 'sa:') {
		return r.declared && u64(decode_id(r.id).sa) == v
	}
	return none
}
