module j1939

// The trace's J1939 reading, as a table of rows and what each one says.
fn plain_row(id u32, name string) Reading {
	return Reading{
		id: id
		declared: true
		name: name
	}
}

// ---------------------------------------------------------------- the name cell
fn test_a_wire_that_was_not_declared_j1939_reads_exactly_as_before() {
	// The same identifier, with the declaration off: no reading, no brackets, no invention.
	// Every extended id decomposes, which is precisely why this bool decides and not the id.
	r := Reading{
		id: 0x0CF00400
		declared: false
		name: 'DiagRsp'
	}
	assert name_cell(r) == 'DiagRsp'
	assert matches_filter(r, 'pgn:f004')? == false
	assert matches_filter(r, 'sa:00')? == false
}

fn test_a_named_broadcast_group_names_its_sender_and_no_destination() {
	assert name_cell(plain_row(0x0CF00400, 'EEC1')) == 'EEC1 [00]'
	assert name_cell(plain_row(0x0CF00421, 'EEC1')) == 'EEC1 [21]'
}

fn test_a_group_the_database_does_not_name_is_still_identified() {
	assert name_cell(plain_row(0x0CF00400, '')) == 'PGN F004 [00]'
	// Four digits, always, so the column does not go ragged over a low group number.
	assert name_cell(plain_row(0x18EF0321, '')) == 'PGN EF00 [21>03]'
}

fn test_an_addressed_group_names_both_ends() {
	assert name_cell(plain_row(0x18EF0321, 'ProprietaryA')) == 'ProprietaryA [21>03]'
}

fn test_a_group_addressed_to_everybody_reads_as_a_broadcast() {
	// PDU1 to the global address IS a broadcast, in the other spelling; printing `>all` on
	// most of the rows of a J1939 bus is noise for the ordinary case.
	assert name_cell(plain_row(0x18ECFF00, '')) == 'PGN EC00 [00]'
	assert addr_pair(0x18ECFF21) == '[21]'
	assert addr_pair(0x18EC0321) == '[21>03]'
	assert addr_pair(0x0CF00421) == '[21]'
}

fn test_the_reserved_addresses_are_named_not_numbered() {
	assert addr_pair(0x0CF004FE) == '[none]' // the null address: not yet claimed
	

	assert addr_pair(0x18EC03FE) == '[none>03]'
}

// ---------------------------------------------------------------- a session's own frames
fn session_row(id u32, head []u8) Reading {
	return Reading{
		id: id
		declared: true
		part: .packet
		head: head
	}
}

fn test_a_session_frame_is_named_by_which_part_of_the_session_it_is() {
	// The name of the group being carried is in the announcement, not in these frames, so a
	// database name would be wrong on every one of them.
	assert name_cell(session_row(0x18ECFF00, [cm_bam, 20, 0, 3, 0xFF, 0xE5, 0xFE, 0])) == 'TP.CM BAM [00]'
	assert name_cell(session_row(0x18EC0300, [cm_rts, 20, 0, 3, 3, 0xE5, 0xFE, 0])) == 'TP.CM RTS [00>03]'
	assert name_cell(session_row(0x18EC0003, [cm_cts, 3, 1, 0xFF, 0xFF, 0xE5, 0xFE, 0])) == 'TP.CM CTS [03>00]'
	assert name_cell(session_row(0x18EC0003, [cm_eoma, 20, 0, 3, 0xFF, 0xE5, 0xFE, 0])) == 'TP.CM EndOfMsgAck [03>00]'
}

fn test_an_abort_frame_carries_its_reason_into_the_name() {
	r := session_row(0x18EC0300, [cm_abort, 3, 0xFF, 0xFF, 0xFF, 0xE5, 0xFE, 0])
	assert name_cell(r) == 'TP.CM Abort — a timeout occurred [00>03]'
	// An unnamed code is its number: it is what the sender said.
	r2 := session_row(0x18EC0300, [cm_abort, 77, 0xFF, 0xFF, 0xFF, 0xE5, 0xFE, 0])
	assert name_cell(r2).contains('reason 77')
}

fn test_a_data_packet_says_which_one_it_is_and_never_how_many_there_are() {
	// `3 of 5` would be a denominator this row cannot know — the count is in the announcement.
	assert name_cell(session_row(0x18EBFF00, [u8(3), 1, 2, 3, 4, 5, 6, 7])) == 'TP.DT #3 [00]'
	assert name_cell(session_row(0x18EB0300, [u8(1), 1, 2, 3, 4, 5, 6, 7])) == 'TP.DT #1 [00>03]'
}

fn test_a_session_frame_with_nothing_readable_still_says_what_it_is() {
	assert packet_label(0x18ECFF00, []) == 'TP'
	assert packet_label(0x18EC0300, [cm_abort]) == 'TP.CM Abort' // no reason byte
	

	assert packet_label(0x18ECFF00, [u8(0x42)]) == 'TP.CM 0x42'
}

// ---------------------------------------------------------------- a rebuilt message
fn test_a_rebuilt_message_says_how_many_packets_it_came_from() {
	r := Reading{
		id: id_for(0xFEE5, 0x00, addr_global, 7)
		declared: true
		name: 'EngineHours'
		part: .bam
		packets: 3
	}
	assert name_cell(r) == 'EngineHours [00] — 3 packets'
	assert r.part.rebuilt()
	assert r.part.mark() == 'BAM'
}

fn test_a_rebuilt_message_is_marked_as_one_in_the_flags() {
	assert Part.plain.mark() == ''
	assert Part.packet.mark() == 'TP'
	assert Part.cm.mark() == 'CM'
	assert !Part.plain.rebuilt()
	assert !Part.packet.rebuilt()
	assert Part.bam.rebuilt() && Part.cm.rebuilt()
}

fn test_the_hover_says_a_rebuilt_identifier_was_never_on_the_wire() {
	r := Reading{
		id: id_for(0xFEE5, 0x00, addr_global, 7)
		declared: true
		part: .cm
		packets: 5
	}
	t := tooltip(r)
	assert t.contains('never on the wire')
	assert t.contains('5 packets')
	// and an ordinary row's hover makes no such claim
	assert !tooltip(plain_row(0x0CF00400, 'EEC1')).contains('never on the wire')
}

fn test_the_hover_carries_the_whole_split_in_both_spellings() {
	t := tooltip(plain_row(0x0CF00400, 'EEC1'))
	assert t.contains('PGN F004 (61444)') // hex for the filter, decimal for the documents
	

	assert t.contains('PDU2, broadcast')
	assert t.contains('from 00')
	assert t.contains('priority 3')
	assert t.contains('PF F0')
	assert t.contains('PS 04')
	// An addressed group states its destination; a broadcast states that it has no field for one.
	assert tooltip(plain_row(0x18EF0321, '')).contains('to 03')
	assert t.contains('no field for one')
}

// ---------------------------------------------------------------- the filter words
fn test_the_filter_words_match_the_decomposition_not_the_text() {
	eec1 := plain_row(0x0CF00400, 'EEC1')
	other := plain_row(0x0CF00421, 'EEC1') // same group, another sender
	assert matches_filter(eec1, 'pgn:f004')? == true
	assert matches_filter(other, 'pgn:f004')? == true
	assert matches_filter(eec1, 'sa:00')? == true
	assert matches_filter(other, 'sa:00')? == false
	assert matches_filter(other, 'sa:21')? == true
	// A name carrying the digits does not answer the group filter.
	assert matches_filter(plain_row(0x0CF00500, 'PGNF004Status'), 'pgn:f004')? == false
}

fn test_anything_else_is_left_to_the_ordinary_search() {
	r := plain_row(0x0CF00400, 'EEC1')
	assert matches_filter(r, 'eec1') == none
	assert matches_filter(r, '') == none
	// A half-typed word has nothing to match yet and is left alone too.
	assert matches_filter(r, 'pgn:') == none
	assert matches_filter(r, 'sa:') == none
	assert matches_filter(r, 'pgn:zz') == none
}

fn test_the_filter_reads_its_number_as_hex() {
	assert field('pgn:f004', 'pgn:')? == 0xF004
	assert field('pgn:ef00', 'pgn:')? == 0xEF00
	assert field('sa:21', 'sa:')? == 0x21
	assert field('sa:0', 'sa:')? == 0
	assert field('pgn: f004 ', 'pgn:')? == 0xF004 // typed with a space after the colon
	

	assert field('eec1', 'pgn:') == none
}

// A connection-mode transfer of a BROADCAST group goes to one node, and the identifier
// synthesised for the rebuilt message has no field to say so — so the caller says it. Without
// this the row read as a broadcast, and two transfers from one sender to different receivers
// were one producer (codex).
fn test_a_rebuilt_message_names_a_destination_its_identifier_cannot_carry() {
	id := id_for(0xFEE5, 0x00, 0x03, 7) // PDU2: the destination is nowhere in this number
	assert decode_id(id).da() == none
	r := Reading{
		id:       id
		declared: true
		part:     .cm
		packets:  3
		to:       0x03
	}
	assert name_cell(r) == 'PGN FEE5 [00>03] — 3 packets'
	assert tooltip(r).contains('to 03')
	// a broadcast rebuild says nothing about a destination, because it really has none
	b := Reading{
		id:       id
		declared: true
		part:     .bam
		packets:  3
	}
	assert name_cell(b) == 'PGN FEE5 [00] — 3 packets'
	assert tooltip(b).contains('no field for one')
	// and `to` never overrides an identifier that CAN carry one
	assert addr_pair_to(0x18EF0321, -1) == '[21>03]'
	assert addr_pair_to(0x0CF00421, -1) == '[21]'
	// including the global address, which is a broadcast in the other spelling
	assert addr_pair_to(id, int(addr_global)) == '[00]'
}
