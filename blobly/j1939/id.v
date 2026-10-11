// SAE J1939 — the READ side: what a 29-bit id says, what a transport-protocol session
// carries, and who claimed which address. GUI-free, like every module here.
//
// This module UNDERSTANDS J1939 traffic and never produces any: no simulated node, no answer
// to a request, no part in address claiming. Replay and the backends already carry a J1939
// recording faithfully (a 29-bit id is a 29-bit id); what was missing is saying what the
// frames MEAN — a PGN and a source address instead of a raw hex number, and a 20-byte
// parameter group as one message instead of three unrelated 8-byte frames (#171).
//
// Nothing in here decides whether a bus IS J1939. A 29-bit id alone is not evidence: `pgn()`
// computes a PGN for any extended id, so a UDS request and its response on 29-bit ids
// (0x18DAxxyy — PDU1 with PF 0xDA) share one. The caller says the bus is J1939 — from the
// database (`candb.Message.j1939`, the `VFrameFormat` declaration) or from the operator — and
// this module answers within that reading.
module j1939

// Id is a 29-bit J1939 identifier taken apart. Layout, MSB to LSB:
//
//   priority(3) | EDP(1) | DP(1) | PF(8) | PS(8) | SA(8)
//
// PDU1 (PF < 0xF0): PS is the DESTINATION address and is not part of the PGN. PDU2
// (PF >= 0xF0): PS is the group extension and is part of the PGN; the message is broadcast.
pub struct Id {
pub:
	priority u8 // 0 (highest) .. 7
	edp      bool
	dp       bool
	pf       u8
	ps       u8
	sa       u8
}

// Well-known protocol PGNs (J1939-21 and J1939-81). Application PGNs are the database's to
// name; these are the ones the protocol itself uses and this module reads.
pub const pgn_tp_cm = u32(0xEC00) // TP.CM — connection management (BAM, RTS, CTS, EOM ack, abort)
pub const pgn_tp_dt = u32(0xEB00) // TP.DT — data transfer, one 7-byte slice per frame
pub const pgn_request = u32(0xEA00) // Request: "send me PGN x"
pub const pgn_ack = u32(0xE800) // Acknowledgment
pub const pgn_address_claimed = u32(0xEE00) // Address Claimed (and Cannot Claim, from SA 0xFE)
pub const pgn_commanded_address = u32(0xFED8) // Commanded Address (carried over TP)

// Addresses with a fixed meaning.
pub const addr_global = u8(0xFF) // the broadcast destination
pub const addr_null = u8(0xFE) // the null address: source of a Cannot Claim

// decompose takes a 29-bit id apart. Bits above 29 are ignored, so a value carrying a
// backend's EFF flag reads the same as the bare id.
pub fn decompose(id u32) Id {
	return Id{
		priority: u8((id >> 26) & 0x7)
		edp:      (id >> 25) & 1 == 1
		dp:       (id >> 24) & 1 == 1
		pf:       u8((id >> 16) & 0xFF)
		ps:       u8((id >> 8) & 0xFF)
		sa:       u8(id & 0xFF)
	}
}

// pdu1 says whether the PS byte is a destination address.
pub fn (i Id) pdu1() bool {
	return i.pf < 0xF0
}

// pgn is the Parameter Group Number: EDP, DP, PF and — for PDU2 only — PS. Priority and source
// address are never part of it, and for PDU1 the destination is not either.
pub fn (i Id) pgn() u32 {
	mut p := u32(i.pf) << 8
	if i.edp {
		p |= 1 << 17
	}
	if i.dp {
		p |= 1 << 16
	}
	if !i.pdu1() {
		p |= u32(i.ps)
	}
	return p
}

// da is the destination address: the PS byte of a PDU1 id, and the global address for a PDU2
// one, which has no destination because it is broadcast.
pub fn (i Id) da() u8 {
	return if i.pdu1() { i.ps } else { addr_global }
}

// pgn is decompose(id).pgn(), for the callers that want only that — candb's PGN-fallback
// lookup is one.
pub fn pgn(id u32) u32 {
	return decompose(id).pgn()
}

// compose builds the 29-bit id a node would put on the wire for `pgn` to `da` from `sa` at
// `priority`. For a PDU1 PGN the destination lands in PS; for a PDU2 one the PGN's own low byte
// does and `da` is ignored, since a broadcast has none. The inverse of decompose for every id
// that is well formed (a PDU1 PGN with a nonzero low byte is not; its low byte is dropped).
pub fn compose(priority u8, pgn u32, da u8, sa u8) u32 {
	pf := u8((pgn >> 8) & 0xFF)
	ps := if pf < 0xF0 { da } else { u8(pgn & 0xFF) }
	mut id := u32(priority & 0x7) << 26
	if (pgn >> 17) & 1 == 1 {
		id |= 1 << 25
	}
	if (pgn >> 16) & 1 == 1 {
		id |= 1 << 24
	}
	id |= u32(pf) << 16
	id |= u32(ps) << 8
	id |= u32(sa)
	return id
}

// pgn_name names a PROTOCOL PGN — the ones J1939-21/-81 define and this module reads. An
// application PGN is the database's to name, so it answers none for everything else rather than
// carrying a table that competes with the DBC.
pub fn pgn_name(pgn u32) ?string {
	return match pgn {
		pgn_tp_cm { 'TP.CM' }
		pgn_tp_dt { 'TP.DT' }
		pgn_request { 'Request' }
		pgn_ack { 'ACK' }
		pgn_address_claimed { 'AddressClaimed' }
		pgn_commanded_address { 'CommandedAddress' }
		else { none }
	}
}

// label is the reading a trace shows beside a 29-bit id: the PGN and who sent it, and for a
// destination-specific message whom to. Compact on purpose — it rides in a table cell — and
// with the priority left out, because on a bench the question is "which message, from whom",
// and the priority is visible in the id's first digit for anyone who wants it.
//
//   PGN 0xF004 SA 0x00            (PDU2: broadcast)
//   PGN 0xEA00 DA 0xFF SA 0x00    (PDU1: destination shown, 0xFF being "everyone")
pub fn (i Id) label() string {
	if i.pdu1() {
		return 'PGN 0x${i.pgn():04X} DA 0x${i.ps:02X} SA 0x${i.sa:02X}'
	}
	return 'PGN 0x${i.pgn():04X} SA 0x${i.sa:02X}'
}

// label is Id.label() for an id.
pub fn label(id u32) string {
	return decompose(id).label()
}
