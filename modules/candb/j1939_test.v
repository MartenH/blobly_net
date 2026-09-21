module candb

// J1939 PGN extraction + PGN-fallback lookup. Real J1939 DBCs encode
// priority+PGN+source-address into the BO_ id, so a live frame from any other
// source address never matches exactly — lookup_frame falls back to the PGN.

// A miniature J1939 database: EEC1 (PDU2 broadcast, PGN 0xF004 = 61444, SA FE
// in the DBC id) and a PDU1 destination-specific message (PGN 0xEA00, dest FF).
const j1939_dbc = '
BO_ 2364540158 EEC1: 8 Vector__XXX
 SG_ EngineSpeed : 24|16@1+ (0.125,0) [0|8031.875] "rpm" Vector__XXX

BO_ 2565537536 RQST: 3 Vector__XXX
 SG_ RequestedPGN : 0|24@1+ (1,0) [0|16777215] "" Vector__XXX

BO_ 256 Plain: 8 Vector__XXX
 SG_ Counter : 0|8@1+ (1,0) [0|255] "" Vector__XXX
'

fn j1939_db() Database {
	return parse_dbc(j1939_dbc) or { panic('parse: ${err}') }
}

fn test_pgn_pdu2_keeps_ps_drops_priority_and_sa() {
	// EEC1: prio 3, PF 0xF0 (PDU2), PS 0x04, any SA -> PGN 0xF004 (61444).
	assert j1939_pgn(0x0CF00400) == 0xF004
	assert j1939_pgn(0x0CF004FE) == 0xF004 // different source address
	assert j1939_pgn(0x1CF00427) == 0xF004 // different priority
}

fn test_pgn_pdu1_drops_destination() {
	// PF 0xEA (PDU1): the PS byte is a destination address, not part of the PGN.
	assert j1939_pgn(0x18EA1234) == 0xEA00
	assert j1939_pgn(0x18EAFF00) == 0xEA00 // broadcast destination, same PGN
}

fn test_pgn_data_page_bit_included() {
	// DP=1 shifts the parameter group into the second data page.
	assert j1939_pgn(0x19F01234) == 0x1F012
}

fn test_dbc_ids_parsed_extended() {
	db := j1939_db()
	// 2364540158 = 0x8CF004FE: EFF flag stripped, ext set.
	m := db.lookup(0x0CF004FE) or { panic('no EEC1 by exact id') }
	assert m.name == 'EEC1'
	assert m.ext
	plain := db.lookup(256) or { panic('no Plain') }
	assert !plain.ext
}

fn test_lookup_frame_pgn_fallback() {
	db := j1939_db()
	// Same PGN, different source address (00 vs the DBC's FE) -> PGN match.
	m := db.lookup_frame(0x0CF00400, true) or { panic('no PGN match for EEC1') }
	assert m.name == 'EEC1'
	// Different priority too.
	m2 := db.lookup_frame(0x1CF00427, true) or { panic('no PGN match (prio)') }
	assert m2.name == 'EEC1'
	// PDU1: any destination + source matches the DBC's broadcast entry.
	r := db.lookup_frame(0x18EA1234, true) or { panic('no PGN match for RQST') }
	assert r.name == 'RQST'
}

fn test_lookup_frame_exact_still_wins() {
	db := j1939_db()
	m := db.lookup_frame(256, false) or { panic('no Plain') }
	assert m.name == 'Plain'
}

fn test_lookup_pgn_prefers_a_declared_message() {
	db := j1939_db()
	assert db.lookup_pgn(0xF004)?.name == 'EEC1'
	assert db.lookup_pgn(0xEA00)?.name == 'RQST'
	assert db.lookup_pgn(0xF005) == none
	// an undeclared extended message at the composed id does not outrank a declared one
	trap := parse_dbc('
BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BO_ 2633943552 Trap: 8 Vector__XXX
BO_ 2566834942 DM1: 8 Vector__XXX
BA_ "VFrameFormat" BO_ 2566834942 3;
') or {
		panic(err)
	}
	assert trap.lookup_pgn(0xFECA)?.name == 'DM1'
	// 2633943552 = 0x9CFECA00: the exact id a priority-7 BAM from 0x00 carrying DM1 composes to
	assert trap.lookup_frame(0x1CFECA00, true)?.name == 'Trap'
}

fn test_lookup_pgn_sa_takes_the_spelled_address_first() {
	two := parse_dbc('
BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BA_DEF_DEF_ "VFrameFormat" "J1939PG";
BO_ 2566834688 DM1_Engine: 8 Vector__XXX
BO_ 2566834699 DM1_Brakes: 8 Vector__XXX
') or {
		panic(err)
	}
	// 2566834688 = 0x98FECA00, 2566834699 = 0x98FECA0B
	assert two.lookup_pgn_sa(0xFECA, 0x0B)?.name == 'DM1_Brakes'
	assert two.lookup_pgn_sa(0xFECA, 0x00)?.name == 'DM1_Engine'
	assert two.lookup_pgn_sa(0xFECA, 0x17) == none // not spelled: the caller falls back to lookup_pgn
	assert two.lookup_pgn(0xFECA)?.name == 'DM1_Engine'
	assert !two.pgn_sa_contested(0xFECA, 0x00)
	// two definitions at one (PGN, SA) — two priorities — cannot be told apart by a transfer
	con := parse_dbc('
BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BA_DEF_DEF_ "VFrameFormat" "J1939PG";
BO_ 2566834688 DM1_p6: 8 Vector__XXX
BO_ 2633943552 DM1_p7: 8 Vector__XXX
') or {
		panic(err)
	}
	// 2566834688 = 0x98FECA00, 2633943552 = 0x9CFECA00
	assert con.pgn_sa_contested(0xFECA, 0x00)
	assert !con.pgn_sa_contested(0xFECA, 0x0B)
	// the same PGN at two addresses with ONE layout agrees; with two layouts it does not
	assert two.pgn_layouts_agree(0xFECA)
	assert two.pgn_layouts_agree(0xF005) // undefined: nothing to disagree
	diff := parse_dbc('
BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BA_DEF_DEF_ "VFrameFormat" "J1939PG";
BO_ 2566834688 DM1_Engine: 8 Vector__XXX
 SG_ Lamp : 0|8@1+ (1,0) [0|255] "" Vector__XXX
BO_ 2566834699 DM1_Brakes: 8 Vector__XXX
 SG_ Lamp : 8|8@1+ (1,0) [0|255] "" Vector__XXX
') or {
		panic(err)
	}
	assert !diff.pgn_layouts_agree(0xFECA)
	assert diff.lookup_pgn_sa(0xFECA, 0x0B)?.name == 'DM1_Brakes' // a spelled address still decodes
	// the same geometry with another value table or unit is another layout too
	lbl := parse_dbc('
BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BA_DEF_DEF_ "VFrameFormat" "J1939PG";
BO_ 2566834688 DM1_Engine: 8 Vector__XXX
 SG_ Lamp : 0|8@1+ (1,0) [0|255] "" Vector__XXX
BO_ 2566834699 DM1_Brakes: 8 Vector__XXX
 SG_ Lamp : 0|8@1+ (1,0) [0|255] "" Vector__XXX
VAL_ 2566834699 Lamp 1 "On" 0 "Off" ;
') or {
		panic(err)
	}
	assert !lbl.pgn_layouts_agree(0xFECA)
	// and across two databases each defining the PGN once
	a := parse_dbc('
BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BA_DEF_DEF_ "VFrameFormat" "J1939PG";
BO_ 2566834688 DM1: 8 Vector__XXX
 SG_ Lamp : 0|8@1+ (1,0) [0|255] "" Vector__XXX
') or {
		panic(err)
	}
	b := parse_dbc('
BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BA_DEF_DEF_ "VFrameFormat" "J1939PG";
BO_ 2566834699 DM1: 8 Vector__XXX
 SG_ Lamp : 8|8@1+ (1,0) [0|255] "" Vector__XXX
') or {
		panic(err)
	}
	assert a.pgn_layouts_agree(0xFECA) && b.pgn_layouts_agree(0xFECA)
	assert !pgn_layouts_agree_in([a, b], 0xFECA)
	assert pgn_layouts_agree_in([a, a], 0xFECA)
}

fn test_lookup_frame_no_false_positives() {
	db := j1939_db()
	// Standard-id frames never PGN-match (ext=false).
	assert db.lookup_frame(0x0F004, false) == none
	// Extended frame with an unknown PGN stays unknown.
	assert db.lookup_frame(0x0CF00500, true) == none
}

fn test_decode_via_pgn_match() {
	db := j1939_db()
	m := db.lookup_frame(0x0CF00400, true) or { panic('no EEC1') }
	// EngineSpeed at bit 24, 16 bits, 0.125 rpm/bit: raw 0x1A20 = 6688 -> 836 rpm.
	data := [u8(0), 0, 0, 0x20, 0x1A, 0, 0, 0]
	s := m.signals[0]
	assert s.name == 'EngineSpeed'
	assert s.physical(data) == 836.0
}
