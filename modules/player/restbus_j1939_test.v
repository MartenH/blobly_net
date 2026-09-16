module player

import canlog
import candb
import j1939
import transport

// A J1939 database the way the CSS/Vector ones are written: one BO_ per PGN, the source address
// in the id a PLACEHOLDER (0xFE here), the transmitter named. The ECU under test is the engine.
fn j1939_db(declared bool) candb.Database {
	return candb.Database{
		nodes:    ['Engine', 'Brakes']
		messages: [
			candb.Message{
				name:   'EEC1'
				id:     0x0CF004FE
				ext:    true
				sender: 'Engine'
				j1939:  declared
			},
			candb.Message{
				name:   'EBC1'
				id:     0x18F001FE
				ext:    true
				sender: 'Brakes'
				j1939:  declared
			},
			candb.Message{
				name:   'DM1'
				id:     0x18FECAFE
				ext:    true
				sender: '' // no transmitter
				j1939:  declared
			},
		]
	}
}

fn ext(iface string, id u32, t f64) canlog.LogEntry {
	return canlog.LogEntry{
		t_s:   t
		iface: iface
		frame: transport.CanFrame{
			id:       id
			extended: true
			data:     [u8(1), 2, 3, 4, 5, 6, 7, 8]
		}
	}
}

// The recording: the engine at SA 0x00, the brakes at SA 0x0B, a DM1 from the engine, and one
// 29-bit id no PGN in the database explains.
fn j1939_rec() []canlog.LogEntry {
	return [
		ext('can', 0x0CF00400, 0.00), // EEC1 from the engine
		ext('can', 0x18F0010B, 0.01), // EBC1 from the brakes
		ext('can', 0x18FECA00, 0.02), // DM1 from the engine (no transmitter in the DBC)
		ext('can', 0x0CF00400, 0.03), // EEC1 again
		ext('can', 0x18EAFF0B, 0.04), // a request: not in the database at all
	]
}

// The case #171 names: the SUT's frames carry its real source address, the DBC a placeholder,
// and keyed on the exact id every one of them was "unknown" and replayed back at the SUT.
fn test_declared_j1939_messages_are_subtracted_by_pgn() {
	kept, rep := without_senders(j1939_rec(), j1939_db(true), ['Engine'], true)
	mut ids := []u32{}
	for e in kept {
		ids << e.frame.id
	}
	assert ids == [u32(0x18F0010B), 0x18FECA00, 0x18EAFF0B]
	assert rep.withheld_excluded == 2 // both EEC1 frames, on the engine's account
	assert rep.kept == 3
	assert rep.pgn_matched == 4 // EEC1 x2, EBC1, DM1 — every frame the PGN placed
	assert rep.unknown == 1 // the request
	assert rep.unknown_ids == ['0x18EAFF0B']
	assert rep.unattributed == 1 // DM1, defined with no transmitter — found by PGN
	assert rep.pgn_hint == 0 // nothing undeclared to hint about
}

// Undeclared, the PGN decides nothing — and the coincidence is reported instead of the frames
// silently reading "not in the DBC".
fn test_undeclared_database_reports_the_pgn_coincidence_and_replays() {
	kept, rep := without_senders(j1939_rec(), j1939_db(false), ['Engine'], true)
	assert kept.len == 5 // every frame replayed: the exact ids are not in the database
	assert rep.withheld_excluded == 0
	assert rep.pgn_matched == 0
	assert rep.unknown == 5
	assert rep.pgn_hint == 4 // the four that share a PGN with a defined message
	assert rep.pgn_hint_ids == ['0x0CF00400', '0x18F0010B', '0x18FECA00']
}

// The exact id still wins where the recording happens to carry the DBC's own source address.
fn test_exact_id_is_not_counted_as_a_pgn_match() {
	rec := [ext('can', 0x0CF004FE, 0.0)]
	_, rep := without_senders(rec, j1939_db(true), ['Engine'], true)
	assert rep.withheld_excluded == 1
	assert rep.pgn_matched == 0
}

// A standard-id frame never PGN-matches, whatever the database declares.
fn test_standard_frames_are_never_matched_by_pgn() {
	// 11-bit ids whose PGN computation would land on a defined message if anyone asked it of
	// a standard frame: nobody does.
	rec := [
		canlog.LogEntry{
			t_s:   0.0
			iface: 'can'
			frame: transport.CanFrame{
				id:   0x004
				data: [u8(1)]
			}
		},
		canlog.LogEntry{
			t_s:   0.1
			iface: 'can'
			frame: transport.CanFrame{
				id:   0x400
				data: [u8(1)]
			}
		},
	]
	kept, rep := without_senders(rec, j1939_db(true), ['Engine'], true)
	assert kept.len == 2
	assert rep.pgn_matched == 0
	assert rep.unknown == 2
}

// The decider says HOW it decided, and the verdict-only reading agrees with it.
fn test_decide_carries_provenance_and_verdict_agrees() {
	d := new_decider(j1939_db(true), ['Engine'], false)
	f := ext('can', 0x0CF00400, 0.0).frame
	dec := d.decide(f)
	assert dec.verdict == .drop_excluded
	assert dec.by_pgn
	assert !dec.pgn_hint
	assert d.verdict(f) == .drop_excluded
	// DM1 by PGN, unattributed, policy says withhold
	dm := d.decide(ext('can', 0x18FECA00, 0.0).frame)
	assert dm.verdict == .drop_unattributed
	assert dm.by_pgn
	// undeclared: the hint and nothing else
	u := new_decider(j1939_db(false), ['Engine'], false)
	ud := u.decide(f)
	assert ud.verdict == .keep_unknown
	assert !ud.by_pgn
	assert ud.pgn_hint
}

// Two BO_ entries for one PGN (two source addresses spelled out) are one parameter group when
// they agree about the sender; when they do not, a third address is either's and the PGN decides
// nothing — it hints.
fn test_declared_messages_disagreeing_about_a_pgns_sender_make_it_ambiguous() {
	two := fn (second string) candb.Database {
		return candb.Database{
			messages: [
				candb.Message{
					name:   'EEC1_Engine1'
					id:     0x0CF00400
					ext:    true
					sender: 'Engine'
					j1939:  true
				},
				candb.Message{
					name:   'EEC1_Engine2'
					id:     0x0CF00401
					ext:    true
					sender: second
					j1939:  true
				},
			]
		}
	}
	d := new_decider(two('Engine2'), ['Engine'], true)
	// an exact hit is still the spelled definition's sender
	assert d.decide(ext('can', 0x0CF00401, 0.0).frame).verdict == .keep
	assert d.decide(ext('can', 0x0CF00400, 0.0).frame).verdict == .drop_excluded
	// a third source address: either engine's, so unknown — and said
	dec := d.decide(ext('can', 0x0CF00402, 0.0).frame)
	assert dec.verdict == .keep_unknown
	assert !dec.by_pgn
	assert dec.pgn_hint
	// the same two spellings naming ONE sender agree, and the PGN decides
	agree := new_decider(two('Engine'), ['Engine'], true)
	dec2 := agree.decide(ext('can', 0x0CF00402, 0.0).frame)
	assert dec2.verdict == .drop_excluded
	assert dec2.by_pgn
}

// A declared message and an undeclared extended message on one PGN: the declared one may not
// decide for a frame the undeclared one could equally be a neighbour of.
fn test_an_undeclared_message_on_a_declared_pgn_makes_it_ambiguous() {
	db := candb.Database{
		messages: [
			candb.Message{
				name:   'EEC1'
				id:     0x0CF004FE
				ext:    true
				sender: 'Engine'
				j1939:  true
			},
			candb.Message{
				name:   'Legacy'
				id:     0x0CF00411 // same PGN, not declared J1939
				ext:    true
				sender: 'Other'
				j1939:  false
			},
		]
	}
	d := new_decider(db, ['Engine'], true)
	// the spelled ids still decide exactly
	assert d.decide(ext('can', 0x0CF004FE, 0.0).frame).verdict == .drop_excluded
	assert d.decide(ext('can', 0x0CF00411, 0.0).frame).verdict == .keep
	// a third address: undecidable, said
	dec := d.decide(ext('can', 0x0CF00400, 0.0).frame)
	assert dec.verdict == .keep_unknown
	assert !dec.by_pgn
	assert dec.pgn_hint
}

// TP.CM / TP.DT frames as a J1939 node puts them on the wire, for the walker.
fn tp_cm(sa u8, da u8, ctrl u8, total int, pgn u32, t f64) canlog.LogEntry {
	return canlog.LogEntry{
		t_s:   t
		iface: 'can'
		frame: transport.CanFrame{
			id:       j1939.compose(7, j1939.pgn_tp_cm, da, sa)
			extended: true
			data:     [ctrl, u8(total & 0xFF), u8(total >> 8), u8((total + 6) / 7), 0xFF,
				u8(pgn & 0xFF), u8((pgn >> 8) & 0xFF), u8((pgn >> 16) & 0xFF)]
		}
	}
}

fn tp_dt(sa u8, da u8, seq u8, t f64) canlog.LogEntry {
	return canlog.LogEntry{
		t_s:   t
		iface: 'can'
		frame: transport.CanFrame{
			id:       j1939.compose(7, j1939.pgn_tp_dt, da, sa)
			extended: true
			data:     [seq, 1, 2, 3, 4, 5, 6, 7]
		}
	}
}

// The excluded engine's 20-byte DM1 is a BAM: an announcement and three packets whose own PGNs
// are the transport protocol's. Judged by the announcement, all four are the engine's.
fn test_a_transfer_takes_its_announcements_decision() {
	rec := [
		tp_cm(0x00, 0xFF, j1939.cm_bam, 20, 0xFECA, 0.00), // engine announces DM1
		tp_dt(0x00, 0xFF, 1, 0.01),
		tp_cm(0x0B, 0xFF, j1939.cm_bam, 9, 0xF001, 0.02), // the brakes announce an EBC1 of their own, interleaved
		tp_dt(0x00, 0xFF, 2, 0.03),
		tp_dt(0x0B, 0xFF, 1, 0.04),
		tp_dt(0x00, 0xFF, 3, 0.05),
		tp_dt(0x0B, 0xFF, 2, 0.06),
		tp_dt(0x00, 0xFF, 4, 0.07), // a packet AFTER the transfer completed: nothing to attribute it by
	]
	// DM1 has no transmitter in j1939_db; give it one for this test
	mut db := j1939_db(true)
	db.messages[2].sender = 'Engine'
	kept, rep := without_senders(rec, db, ['Engine'], true)
	mut ids := []u32{}
	for e in kept {
		ids << e.frame.id
	}
	// the brakes' announcement and two packets, and the stray packet
	assert ids == [u32(0x1CECFF0B), 0x1CEBFF0B, 0x1CEBFF0B, 0x1CEBFF00]
	assert rep.withheld_excluded == 4
	assert rep.tp_attributed == 7 // both transfers, every frame the announcement covered
	assert rep.unknown == 1 // the stray
	assert rep.pgn_matched == 7 // the announcements matched by PGN (the DBC spells SA 0xFE), and every packet took that decision
	// the census says the same
	cn := census(rec, db)
	assert cn.nodes['Engine'] == 4
	assert cn.nodes['Brakes'] == 3 // EBC1 is theirs, announcement and packets alike
	assert cn.unattributed == 0
	assert cn.tp_attributed == 7
}

// The receiver's side of a connection is nobody the database can name; an abort from the
// originator ends the transfer with its decision.
fn test_receiver_frames_stay_unknown_and_an_abort_ends_the_transfer() {
	mut db := j1939_db(true)
	db.messages[2].sender = 'Engine'
	cts := canlog.LogEntry{
		t_s:   0.01
		iface: 'can'
		frame: transport.CanFrame{
			id:       j1939.compose(7, j1939.pgn_tp_cm, 0x00, 0x17)
			extended: true
			data:     [j1939.cm_cts, 0xFF, 1, 0xFF, 0xFF, 0xCA, 0xFE, 0x00]
		}
	}
	rec := [
		tp_cm(0x00, 0x17, j1939.cm_rts, 20, 0xFECA, 0.00), // engine -> 0x17
		cts,
		tp_dt(0x00, 0x17, 1, 0.02),
		tp_cm(0x00, 0x17, j1939.cm_abort, 0, 0xFECA, 0.03), // the engine gives up
		tp_dt(0x00, 0x17, 2, 0.04), // after the abort: no transfer to belong to
	]
	kept, rep := without_senders(rec, db, ['Engine'], true)
	assert kept.len == 2 // the CTS and the stray packet
	assert rep.withheld_excluded == 3 // RTS, packet 1, the abort
	assert rep.tp_attributed == 3
	assert rep.unknown == 2
}

// A retransmitted packet does not end the transfer early: the real last packet is still the
// sender's. And an announcement the reassembler refuses is nothing the walker follows either.
fn test_a_duplicate_packet_does_not_end_the_transfer_and_malformed_announcements_are_not_followed() {
	mut db := j1939_db(true)
	db.messages[2].sender = 'Engine'
	rec := [
		tp_cm(0x00, 0xFF, j1939.cm_bam, 20, 0xFECA, 0.00),
		tp_dt(0x00, 0xFF, 1, 0.01),
		tp_dt(0x00, 0xFF, 1, 0.02), // retransmitted
		tp_dt(0x00, 0xFF, 2, 0.03),
		tp_dt(0x00, 0xFF, 3, 0.04), // the real last packet
		// a BAM addressed to one node is not an announcement; its "packets" belong to nobody
		canlog.LogEntry{
			t_s:   0.05
			iface: 'can'
			frame: transport.CanFrame{
				id:       j1939.compose(7, j1939.pgn_tp_cm, 0x17, 0x00)
				extended: true
				data:     [j1939.cm_bam, 20, 0, 3, 0xFF, 0xCA, 0xFE, 0x00]
			}
		},
		tp_dt(0x00, 0x17, 1, 0.06),
	]
	kept, rep := without_senders(rec, db, ['Engine'], true)
	assert rep.withheld_excluded == 5 // announcement and four packets, the duplicate included
	assert rep.tp_attributed == 5
	assert kept.len == 2 // the refused announcement and its packet, unknown
	assert rep.unknown == 2
}

// On a database that declares no J1939, TP-shaped frames are frames like any other: a
// proprietary 29-bit message whose id spells the composed announcement is not a transfer.
fn test_transfers_are_followed_only_on_a_declared_database() {
	db := candb.Database{
		messages: [
			candb.Message{
				name:   'Proprietary'
				id:     0x1CFECA00 // what a BAM from 0x00 carrying 0xFECA would compose to
				ext:    true
				sender: 'Engine'
				j1939:  false
			},
		]
	}
	rec := [
		tp_cm(0x00, 0xFF, j1939.cm_bam, 20, 0xFECA, 0.00),
		tp_dt(0x00, 0xFF, 1, 0.01),
		tp_dt(0x00, 0xFF, 2, 0.02),
		tp_dt(0x00, 0xFF, 3, 0.03),
	]
	kept, rep := without_senders(rec, db, ['Engine'], true)
	assert kept.len == 4 // nothing followed, nothing attributed
	assert rep.tp_attributed == 0
	assert rep.withheld_excluded == 0
	assert rep.unknown == 4
}

// Two spellings of one transmitter pair agree about the sender, whatever their order.
fn test_transmitter_sets_compare_without_order() {
	db := candb.Database{
		messages: [
			candb.Message{
				name:     'EEC1_a'
				id:       0x0CF00400
				ext:      true
				sender:   'Engine'
				tx_nodes: ['Engine2']
				j1939:    true
			},
			candb.Message{
				name:     'EEC1_b'
				id:       0x0CF00401
				ext:      true
				sender:   'Engine2'
				tx_nodes: ['Engine']
				j1939:    true
			},
		]
	}
	d := new_decider(db, ['Engine'], true)
	dec := d.decide(ext('can', 0x0CF00402, 0.0).frame)
	assert dec.by_pgn
	assert dec.verdict == .drop_excluded
}

// The Configuration panel's preview is the subtraction's own decision, so on a J1939 bus it
// offers the SUT for exclusion and says what the PGN did.
fn test_census_attributes_by_pgn_like_the_subtraction() {
	rec := j1939_rec()
	cn := census(rec, j1939_db(true))
	assert cn.nodes['Engine'] == 2 // both EEC1 frames, by PGN
	assert cn.nodes['Brakes'] == 1
	assert cn.unattributed == 1 // DM1, by PGN, no transmitter
	assert cn.unknown == 1 // the request
	assert cn.pgn_matched == 4
	assert cn.pgn_hint == 0
	assert cn.total == 5
	// undeclared: nothing to exclude, and the preview says why
	un := census(rec, j1939_db(false))
	assert un.nodes.len == 0
	assert un.unknown == 5
	assert un.pgn_hint == 4
}

// The multi-bus walk reports the same provenance per bus.
fn test_multibus_report_carries_pgn_counts() {
	rec := j1939_rec()
	plan := build_multi(rec, [
		BusSpec{
			src:     'can'
			dst:     'vector:1'
			db:      j1939_db(true)
			exclude: ['Engine']
		},
	])
	assert plan.buses.len == 1
	assert plan.buses[0].report.pgn_matched == 4
	assert plan.buses[0].report.withheld_excluded == 2
}
