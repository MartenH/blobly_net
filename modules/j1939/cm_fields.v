// cm_fields — what every byte of a TP.CM frame may hold (#341).
//
// The class fix for malformed control frames, in the shape `candb/arxml_leaves.v` gave the
// ARXML reader (#280): ONE table of every field a control frame carries, with what J1939-21
// lets it hold, checked ONCE (`Cm.refusal`) before the reassembler or `Transfers` acts on the
// frame. A frame the table refuses is one `malformed` fault and is acted on by nobody — an
// announcement opens nothing (and still ends the pair's previous transfer, as every refused
// announcement does), a clear-to-send keeps nothing alive, an acknowledgement or an abort ends
// nothing. Both trackers ask the same function, so they cannot disagree about it.
//
// The table holds what a field may hold ON ITS OWN. What a field may hold given another field
// or an open session is a RELATION and stays beside the reader that knows both: an
// announcement's packet count against its size, a PDU1 group's low byte, the addresses
// (`Cm.admission`); a clear-to-send's packet number against the transfer's count
// (`Cm.names_packet`); an acknowledgement's size and count against the transfer's
// (`Cm.acknowledges`).
//
// Reserved bytes are judged too, although this listener reads nothing from them: a frame whose
// reserved bytes are not the 0xFF J1939-21 fixes is not a frame the standard describes, and
// admitting it is how a stray frame at this identifier became a synthetic message (the BAM's
// byte 4, codex on #329).
module j1939

enum FieldRule {
	range // lo..hi inclusive
	fixed // exactly lo
	ones // every bit of the mask `lo` set; the rest are a field of their own
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
}

// The PGN field (bytes 5..7) of every control frame: 18 bits. For a PDU1 group the low byte
// must also be zero — a relation on the PF byte, stated in `admission`.
const pgn_hi = u32(0x3FFFF)

const cm_fields = [
	// RTS: size, packets, packets per clear-to-send (0xFF = no limit), PGN
	CmField{cm_rts, 'size', 1, 2, .range, tp_min_size, tp_max_size},
	CmField{cm_rts, 'packet count', 3, 1, .range, 1, 255},
	CmField{cm_rts, 'packets per CTS', 4, 1, .range, 1, 255},
	CmField{cm_rts, 'PGN', 5, 3, .range, 0, pgn_hi},
	// CTS: packets that may be sent (0 holds the sender), next packet, reserved, PGN. The count
	// is not judged against the RTS's per-CTS limit: this listener paces nobody.
	CmField{cm_cts, 'packets to send', 1, 1, .any, 0, 0},
	CmField{cm_cts, 'next packet', 2, 1, .range, 1, 255},
	CmField{cm_cts, 'reserved byte 3', 3, 1, .fixed, 0xFF, 0},
	CmField{cm_cts, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0},
	CmField{cm_cts, 'PGN', 5, 3, .range, 0, pgn_hi},
	// EndOfMsgACK: size, packets, reserved, PGN
	CmField{cm_eom_ack, 'size', 1, 2, .range, tp_min_size, tp_max_size},
	CmField{cm_eom_ack, 'packet count', 3, 1, .range, 1, 255},
	CmField{cm_eom_ack, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0},
	CmField{cm_eom_ack, 'PGN', 5, 3, .range, 0, pgn_hi},
	// BAM: size, packets, reserved, PGN
	CmField{cm_bam, 'size', 1, 2, .range, tp_min_size, tp_max_size},
	CmField{cm_bam, 'packet count', 3, 1, .range, 1, 255},
	CmField{cm_bam, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0},
	CmField{cm_bam, 'PGN', 5, 3, .range, 0, pgn_hi},
	// Abort: reason (every value named by `abort_reason`), then byte 2 — reserved 0xFF in the
	// original J1939-21, bits 8..3 reserved at 1 with the abort's role in bits 2..1 since, so
	// the high six bits are what both editions fix — then reserved bytes 3 and 4, PGN.
	CmField{cm_abort, 'reason', 1, 1, .any, 0, 0},
	CmField{cm_abort, 'reserved bits of byte 2', 2, 1, .ones, 0xFC, 0},
	CmField{cm_abort, 'reserved byte 3', 3, 1, .fixed, 0xFF, 0},
	CmField{cm_abort, 'reserved byte 4', 4, 1, .fixed, 0xFF, 0},
	CmField{cm_abort, 'PGN', 5, 3, .range, 0, pgn_hi},
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
		.any {}
	}
	return none
}

// refusal is THE table check: the first field of this control frame that holds a value
// J1939-21 does not let it hold, said. None for a well-formed frame — and for an unknown control
// byte, which has no fields; the readers refuse that by its byte.
pub fn (c Cm) refusal() ?string {
	for f in cm_fields {
		if f.ctrl != c.ctrl {
			continue
		}
		if why := f.why(f.value(c.raw)) {
			return why
		}
	}
	return none
}

// names_packet is the clear-to-send RELATION: the packet it asks for next is one the transfer
// has (`packets` announced). The table has already refused packet 0.
pub fn (c Cm) names_packet(packets int) bool {
	return int(c.raw[2]) <= packets
}

// next_packet is a clear-to-send's next packet number.
pub fn (c Cm) next_packet() u8 {
	return c.raw[2]
}

// reason is an abort's reason byte.
pub fn (c Cm) reason() u8 {
	return c.raw[1]
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
