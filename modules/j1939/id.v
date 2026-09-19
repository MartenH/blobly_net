// id.v — a 29-bit J1939 identifier, taken apart.
//
// J1939 spends the extended CAN id on structure rather than on a number: priority, two page
// bits, a PDU format byte, a PDU-specific byte and the sender's address. The trace showed the
// raw value, so `0x0CF00400` said nothing about being EEC1 from address 0x00 (#171).
//
// The split is pure and total — every 29-bit value decomposes — which is exactly why it must
// not be applied to every extended frame. A UDS response on an extended id decomposes just as
// willingly and means nothing by it; `Message.j1939` (the DBC's VFrameFormat) and the channel's
// own declaration are what say a bus is J1939, and the caller asks that question, not this file
// (#289 made the same point about the verifier's PGN matching).
module j1939

// addr_global is the destination that means "everybody" — a PDU1 message addressed to it is a
// broadcast, and every PDU2 message is one by construction.
pub const addr_global = u8(0xFF)

// addr_null is the source an ECU uses before it has claimed an address.
pub const addr_null = u8(0xFE)

// Id is one identifier, decomposed. `ps` is the byte whose MEANING depends on `pf`: below 0xF0
// it is a destination address (PDU1, a message to one node), at or above it a group extension
// that is part of the PGN (PDU2, a broadcast).
pub struct Id {
pub:
	priority u8 // 0 (highest) .. 7
	edp      bool // extended data page
	dp       bool // data page
	pf       u8 // PDU format
	ps       u8 // PDU specific: a destination address (PDU1) or a group extension (PDU2)
	sa       u8 // source address
}

// decode_id splits a 29-bit identifier. Bits above 29 are not ours to read and are ignored:
// the CAN layer owns the frame's width, and `ext` is what says an id is 29 bits wide.
pub fn decode_id(id u32) Id {
	return Id{
		priority: u8((id >> 26) & 0x7)
		edp: (id >> 25) & 1 == 1
		dp: (id >> 24) & 1 == 1
		pf: u8((id >> 16) & 0xFF)
		ps: u8((id >> 8) & 0xFF)
		sa: u8(id & 0xFF)
	}
}

// pdu1 reports the addressed form: a PF below 0xF0 means `ps` is a destination address and is
// NOT part of the PGN. This one comparison is the whole of J1939's addressing.
pub fn (i Id) pdu1() bool {
	return i.pf < 0xF0
}

// pgn is the Parameter Group Number: the pages, the format byte, and the PDU-specific byte only
// where it is a group extension. Priority and source address are never part of it, which is why
// one parameter group sent by three ECUs is one PGN and three identifiers.
pub fn (i Id) pgn() u32 {
	mut p := u32(0)
	if i.edp {
		p |= 0x20000
	}
	if i.dp {
		p |= 0x10000
	}
	p |= u32(i.pf) << 8
	if !i.pdu1() {
		p |= u32(i.ps)
	}
	return p
}

// da is the destination, or none where the form has no such field. PDU2 is broadcast by
// construction, and answering `addr_global` for it would claim the message names a destination
// when the wire has no room to name one.
pub fn (i Id) da() ?u8 {
	if i.pdu1() {
		return i.ps
	}
	return none
}

// broadcast reports whether every node is a recipient — a PDU2 message, or a PDU1 one sent to
// the global address.
pub fn (i Id) broadcast() bool {
	return !i.pdu1() || i.ps == addr_global
}

// encode rebuilds the identifier, so a decomposition can be checked against what it came from
// and a synthesised id (a reassembled message's, for the DBC lookup) is built by one rule.
pub fn (i Id) encode() u32 {
	mut id := (u32(i.priority) & 0x7) << 26
	if i.edp {
		id |= u32(1) << 25
	}
	if i.dp {
		id |= u32(1) << 24
	}
	id |= u32(i.pf) << 16
	id |= u32(i.ps) << 8
	id |= u32(i.sa)
	return id
}

// pgn_of is `decode_id(id).pgn()` for a caller that wants the number and nothing else — the
// shape `candb.j1939_pgn` had, kept so the lookup path costs no struct.
pub fn pgn_of(id u32) u32 {
	mut pgn := (id >> 8) & 0x3FFFF // EDP + DP + PF + PS
	if (id >> 16) & 0xFF < 0xF0 {
		pgn &= 0x3FF00 // PDU1: the PDU-specific byte is a destination, not part of the group
	}
	return pgn
}

// id_for builds the identifier a parameter group would have from `sa` at `priority` — the
// inverse of the split, for a reassembled message that has a PGN and a sender but no id of its
// own (its packets carried the transport PGN, not the data's). A PDU1 group takes the
// destination in its PDU-specific byte; a PDU2 group's is already in the PGN.
pub fn id_for(pgn u32, sa u8, da u8, priority u8) u32 {
	pf := u8((pgn >> 8) & 0xFF)
	ps := if pf < 0xF0 { da } else { u8(pgn & 0xFF) }
	return Id{
		priority: priority
		edp: (pgn >> 17) & 1 == 1
		dp: (pgn >> 16) & 1 == 1
		pf: pf
		ps: ps
		sa: sa
	}.encode()
}
