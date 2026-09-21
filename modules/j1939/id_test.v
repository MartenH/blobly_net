module j1939

// EEC1 from the engine: priority 3, PF 0xF0 (PDU2), PS 0x04, SA 0x00.
fn test_decompose_pdu2() {
	i := decompose(0x0CF00400)
	assert i.priority == 3
	assert !i.edp
	assert !i.dp
	assert i.pf == 0xF0
	assert i.ps == 0x04
	assert i.sa == 0x00
	assert !i.pdu1()
	assert i.pgn() == 0xF004
	assert i.da() == addr_global
	assert i.label() == 'PGN 0xF004 SA 0x00'
}

// A request from the tester (SA 0xF9) to the engine (DA 0x00): priority 6, PF 0xEA (PDU1).
fn test_decompose_pdu1() {
	i := decompose(0x18EA00F9)
	assert i.priority == 6
	assert i.pf == 0xEA
	assert i.ps == 0x00
	assert i.sa == 0xF9
	assert i.pdu1()
	assert i.pgn() == 0xEA00 // the destination is not part of the PGN
	assert i.da() == 0x00
	assert i.label() == 'PGN 0xEA00 DA 0x00 SA 0xF9'
}

fn test_data_page_bits_are_in_the_pgn() {
	assert decompose(0x19F01234).pgn() == 0x1F012 // DP
	assert decompose(0x1AF01234).pgn() == 0x2F012 // EDP
	assert decompose(0x1BF01234).pgn() == 0x3F012 // both
}

fn test_flag_bits_above_29_are_ignored() {
	assert decompose(0x8CF00400).pgn() == 0xF004
	assert decompose(0x8CF00400).priority == 3
}

fn test_compose_inverts_decompose() {
	for id in [u32(0x0CF00400), 0x18EA00F9, 0x1CECFF00, 0x1CEB0017, 0x18EEFF0B, 0x19F01234,
		0x1BF01234, 0x18FED800] {
		i := decompose(id)
		assert compose(i.priority, i.pgn(), i.da(), i.sa) == id, '0x${id:08X}'
	}
}

fn test_compose_pdu1_puts_destination_in_ps() {
	// TP.CM from 0x00 to 0x17 at priority 7
	assert compose(7, pgn_tp_cm, 0x17, 0x00) == 0x1CEC1700
	// a PDU2 PGN ignores the destination: it is broadcast
	assert compose(3, 0xF004, 0x17, 0x00) == 0x0CF00400
}

fn test_protocol_pgn_names() {
	assert pgn_name(pgn_tp_cm)? == 'TP.CM'
	assert pgn_name(pgn_tp_dt)? == 'TP.DT'
	assert pgn_name(pgn_request)? == 'Request'
	assert pgn_name(pgn_address_claimed)? == 'AddressClaimed'
	assert pgn_name(0xF004) == none // application PGNs are the database's to name
}

fn test_pgn_free_function_matches_method() {
	assert pgn(0x0CF00400) == 0xF004
	assert pgn(0x18EA00F9) == 0xEA00
	assert label(0x0CF00400) == 'PGN 0xF004 SA 0x00'
}
