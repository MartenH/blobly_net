// cm_fields — what every byte of a TP.CM frame may hold (#341).
//
// The class fix for malformed control frames, in the shape `candb/arxml_leaves.v` gave the
// ARXML reader (#280): ONE table of every field a control frame carries, with what J1939-21
// lets it hold, checked ONCE before the reassembler or `Transfers` acts on the frame.
//
// Two severities, because the fields are of two kinds. A field the readers USE — a size, a
// count, a PGN, the BAM's reserved byte that #329 made the mark of a real announcement — with a
// value J1939-21 does not permit REFUSES the frame (`Cm.refusal`): one `malformed` fault, and
// nobody acts on it — an announcement opens nothing (and still ends the pair's previous
// transfer, as every refused announcement does), a clear-to-send keeps nothing alive, an
// acknowledgement or an abort ends nothing. Both trackers ask the same function, so they cannot
// disagree about it. A RESERVED byte of a CTS, an acknowledgement or an abort, which no reader
// uses, is only SAID (`Cm.nonconformity`, an `off_spec` fault) and the frame is acted on as
// ever: an ECU that fills reserved bytes with 0x00 is common, and refusing its abort would
// replace an abort by a timeout and replay the excluded node's own abort back at it — the wire
// was wrong, the frame is still the abort (the reasoning `padding` already follows).
//
// The table holds what a field may hold ON ITS OWN. What a field may hold given another field
// or an open session is a RELATION and stays beside the reader that knows both: an
// announcement's packet count against its size, a PDU1 group's low byte, the addresses
// (`Cm.admission`); a clear-to-send's packet number against the transfer's count
// (`Cm.names_packet`); an acknowledgement's size and count against the transfer's
// (`Cm.acknowledges`).
//
module j1939

enum FieldRule {
	range // lo..hi inclusive
	fixed // exactly lo
	ones // every bit of the mask `lo` set; the rest are a field of their own
	excludes // the bits under the mask `hi` are anything but `lo` (a reserved code in a field)
	any // every value is meaningful; listed so the table is the whole frame
}

// CmField is one field of one control frame: `width` bytes from byte `at`, little-endian.
struct CmField {
	ctrl  u8
	name  string
	at    int
	width int
	rule  FieldRule
	lo    u32
	hi    u32
	// said, never refused: a reserved byte, or a field, no reader uses (see the header)
	said bool
}

// The PGN field (bytes 5..7) of every control frame: 18 bits. For a PDU1 group the low byte
// must also be zero — a relation on the PF byte, checked beside the table in `refusal` for every
// control frame.
const pgn_hi = u32(0x3FFFF)

const cm_fields = [
	// The data ranges are J1939-21's TP.CM table: "Total Number of Packets: 2 to 255, zero not
	// allowed"; "Maximum Number of Packets: 2 to 255, zero through 1 are not allowed"; "Number
	// of Packets that can be sent: 0 to 255"; "Next Packet Number to be Sent: 1 to 255".
	// RTS: size, packets, packets per clear-to-send (0xFF = no limit), PGN. Packets per CTS is
	// SAID, not refused: this listener paces nobody, and real ECUs send 1.
	CmField{cm_rts, 'size', 1, 2, .range, tp_min_size, tp_max_size, false},
	CmField{cm_rts, 'packet count', 3, 1, .range, 2, 255, false},
	CmField{cm_rts, 'packets per CTS', 4, 1, .range, 2, 255, true},
	CmField{cm_rts, 'PGN', 5, 3, .range, 0, pgn_hi, false},
	// CTS: packets that may be sent (0 holds the sender), next packet, reserved, PGN. The count
	// is not judged against the RTS's per-CTS limit: this listener paces nobody.
	CmField{cm_cts, 'packets to send', 1, 1, .any, 0, 0, false},
	CmField{cm_cts, 'next packet', 2, 1, .any, 0, 0, false}, // a relation: 1..the transfer's count (names_packet)
	CmField{cm_cts, 'reserved byte 3', 3, 1, .fixed, 0xFF, 0, true},
	CmField{cm_cts, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0, true},
	CmField{cm_cts, 'PGN', 5, 3, .range, 0, pgn_hi, false},
	// EndOfMsgACK: size, packets, reserved, PGN
	CmField{cm_eom_ack, 'size', 1, 2, .range, tp_min_size, tp_max_size, false},
	CmField{cm_eom_ack, 'packet count', 3, 1, .range, 2, 255, false},
	CmField{cm_eom_ack, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0, true},
	CmField{cm_eom_ack, 'PGN', 5, 3, .range, 0, pgn_hi, false},
	// BAM: size, packets, reserved, PGN
	CmField{cm_bam, 'size', 1, 2, .range, tp_min_size, tp_max_size, false},
	CmField{cm_bam, 'packet count', 3, 1, .range, 2, 255, false},
	CmField{cm_bam, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0, false},
	CmField{cm_bam, 'PGN', 5, 3, .range, 0, pgn_hi, false},
	// Abort: reason (every value named by `abort_reason`), then byte 2 — reserved 0xFF in the
	// original J1939-21, bits 8..3 reserved at 1 with the abort's role in bits 2..1 since, so
	// the high six bits are what both editions fix — then reserved bytes 3 and 4, PGN.
	CmField{cm_abort, 'reason', 1, 1, .any, 0, 0, false},
	CmField{cm_abort, 'reserved bits of byte 2', 2, 1, .ones, 0xFC, 0, true},
	CmField{cm_abort, 'role', 2, 1, .excludes, 0x02, 0x03, true}, // 10 is reserved; read as no role
	CmField{cm_abort, 'reserved byte 3', 3, 1, .fixed, 0xFF, 0, true},
	CmField{cm_abort, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0, true},
	CmField{cm_abort, 'PGN', 5, 3, .range, 0, pgn_hi, false},
]

// value reads the field out of an eight-byte payload.
fn (f CmField) value(raw [8]u8) u32 {
	mut v := u32(0)
	for i in 0 .. f.width {
		v |= u32(raw[f.at + i]) << (8 * i)
	}
	return v
}

// why is the refusal of `v`, or none where the field may hold it.
fn (f CmField) why(v u32) ?string {
	hex := if f.width == 1 { '0x${v:02X}' } else { '0x${v:X}' }
	match f.rule {
		.range {
			if v < f.lo || v > f.hi {
				return '${cm_name(f.ctrl)} ${f.name} ${v}; J1939-21 permits ${f.lo}..${f.hi}'
			}
		}
		.fixed {
			if v != f.lo {
				return '${cm_name(f.ctrl)} ${f.name} ${hex}; J1939-21 fixes it at 0x${f.lo:02X}'
			}
		}
		.ones {
			if v & f.lo != f.lo {
				return '${cm_name(f.ctrl)} ${f.name} ${hex}; J1939-21 sets bits 0x${f.lo:02X}'
			}
		}
		.excludes {
			if v & f.hi == f.lo {
				return '${cm_name(f.ctrl)} ${f.name} ${hex}; the code ${f.lo:b} under 0x${f.hi:02X} is reserved'
			}
		}
		.any {}
	}
	return none
}

// refusal is THE table check: the first field this frame's readers use that holds a value
// J1939-21 does not let it hold, said. None for a well-formed frame — and for an unknown control
// byte, which has no fields; the readers refuse that by its byte.
pub fn (c Cm) refusal() ?string {
	if why := c.first(false) {
		return why
	}
	// The PGN must be one: for a PDU1 group (PF below 0xF0) a zero low byte, since that byte
	// is a destination there and not part of any PGN. Followed anyway, compose() would drop the
	// bits and present the transfer as a DIFFERENT, valid group (codex on #329) — and a CTS, an
	// acknowledgement or an abort naming one names no transfer (codex on #382).
	if cm_fields.any(it.ctrl == c.ctrl) && ((c.pgn >> 8) & 0xFF) < 0xF0 && (c.pgn & 0xFF) != 0 {
		return '${cm_name(c.ctrl)} carries PGN 0x${c.pgn:05X}, a PDU1 group with a nonzero low byte'
	}
	// A CTS that lets packets flow names the next one: J1939-21's data ranges, "Next Packet Number
	// to be Sent: 1 to 255, zero not allowed". A hold (zero packets) is exempt, since it asks for none.
	if c.ctrl == cm_cts && c.raw[1] > 0 && c.raw[2] == 0 {
		return 'CTS asks for ${c.raw[1]} packets from packet 0; J1939-21 permits 1..255'
	}
	return none
}

// control_refusal is `refusal` for a frame that is not an announcement — the one question the
// reassembler and `Transfers` both ask before acting on a CTS, an acknowledgement or an abort.
// An announcement's refusal is `admission`'s, which also ends the pair's previous transfer.
pub fn (c Cm) control_refusal() ?string {
	if c.ctrl == cm_rts || c.ctrl == cm_bam {
		return none
	}
	return c.refusal()
}

// nonconformity is the first RESERVED byte not at the value J1939-21 fixes — said, not refused.
pub fn (c Cm) nonconformity() ?string {
	return c.first(true)
}

fn (c Cm) first(said bool) ?string {
	for f in cm_fields {
		if f.ctrl != c.ctrl || f.said != said {
			continue
		}
		if why := f.why(f.value(c.raw)) {
			return why
		}
	}
	return none
}

// names_packet is the clear-to-send RELATION: the packet it asks for next is one the transfer
// has (1..`packets` announced). A CTS naming none keeps nothing alive and rewinds nothing; it is
// not refused, since a hold (zero packets to send) may leave the field unused.
pub fn (c Cm) names_packet(packets int) bool {
	return c.raw[2] >= 1 && int(c.raw[2]) <= packets
}

// next_packet is a clear-to-send's next packet number.
pub fn (c Cm) next_packet() u8 {
	return c.raw[2]
}

// reason is an abort's reason byte.
pub fn (c Cm) reason() u8 {
	return c.raw[1]
}

// AbortRole is the role an abort's sender declares in byte 2 bits 2..1 (J1939-21 since its
// second edition): 00 the transfer's originator, 01 its responder; 10 is reserved and 11 "not
// specified" — which is also what the first edition's all-0xFF byte reads as.
pub enum AbortRole {
	originator
	responder
	unspecified
}

// abort_role decodes an abort's byte 2.
pub fn (c Cm) abort_role() AbortRole {
	return match c.raw[2] & 0x03 {
		0 { .originator }
		1 { .responder }
		else { .unspecified }
	}
}

// AbortSide is what an abort's addressing can reach of one open transfer: its group, and
// whether it is a broadcast (which has no responder).
pub struct AbortSide {
pub:
	pgn u32
	bam bool
}

// abort_targets_forward is THE rule for which open transfer an abort ends, for both trackers:
// true for the one keyed (sender -> destination), the frame's sender being its ORIGINATOR;
// false for the one keyed the other way, the sender being its RESPONDER; none for neither.
// `fwd` and `rev` are what is open under those two keys. The transfer must carry the group the
// abort names, and a responder must be able to exist (`receiver_control`). A declared role
// decides the direction outright — two nodes can have the SAME group open towards each other,
// and only the role says which of them is meant; with no role (the first edition's 0xFF, or
// 10/11) the originator's direction is tried first, as before.
pub fn abort_targets_forward(id Id, c Cm, fwd ?AbortSide, rev ?AbortSide) ?bool {
	role := c.abort_role()
	if role != .responder {
		if f := fwd {
			if f.pgn == c.pgn {
				return true
			}
		}
	}
	if role != .originator {
		if r := rev {
			if r.pgn == c.pgn && receiver_control(id, r.bam) {
				return false
			}
		}
	}
	return none
}

// cm_name is a control byte's name, for a refusal.
fn cm_name(ctrl u8) string {
	return match ctrl {
		cm_rts { 'RTS' }
		cm_cts { 'CTS' }
		cm_eom_ack { 'EndOfMsgACK' }
		cm_bam { 'BAM' }
		cm_abort { 'Abort' }
		else { 'TP.CM ${ctrl}' }
	}
}
