module watchrule

const eec1 = u32(0x0CF00400)

fn frame(sig string) Ident {
	return Ident{
		id: eec1
		ext: true
		sig: sig
	}
}

fn rejoined(wire string, sig string) Ident {
	return Ident{
		id: eec1
		ext: true
		tp: true
		wire: wire
		sig: sig
		pgn: 0xF004
	}
}

fn row(i Ident) Row {
	return Row{
		id: i.id
		ext: i.ext
		tp: i.tp
		da: i.da
		wire: i.wire
	}
}

fn test_a_frame_and_the_message_rejoined_from_frames_like_it_are_two_signals() {
	// one PGN, sent both short and over a transfer, carries two payload shapes: a series that
	// matched on the identifier alone drew them as one line
	f := frame('EngineSpeed')
	r := rejoined('can0', 'EngineSpeed')
	assert !f.same(r)
	assert f.key() != r.key()
	assert !f.covers(row(r))
	assert !r.covers(row(f))
}

fn test_two_wires_rejoining_one_group_are_two_signals() {
	a := rejoined('can0', 'EngineSpeed')
	b := rejoined('can1', 'EngineSpeed')
	assert !a.same(b)
	assert !a.covers(row(b))
	assert !b.covers(row(a))
	assert a.covers(row(a))
}

fn test_a_frames_watch_is_not_scoped_by_wire() {
	// #330 is about every row, not about this one: a frame's watch takes its samples from any
	// wire, as it did before either field existed
	f := frame('EngineSpeed')
	assert !f.scoped_by_wire()
	assert f.covers(Row{
		id: eec1
		ext: true
		wire: 'can1'
	})
	assert rejoined('can0', 'EngineSpeed').scoped_by_wire()
}

fn test_nothing_matches_a_someip_row() {
	// no DBC message behind it; its payload layout is the deployment's
	for i in [frame('EngineSpeed'), rejoined('can0', 'EngineSpeed')] {
		assert !i.covers(Row{
			id: i.id
			ext: i.ext
			tp: i.tp
			wire: i.wire
			someip: true
		})
	}
}

fn test_the_identity_separates_every_field_it_names() {
	base := rejoined('can0', 'EngineSpeed')
	others := [
		Ident{ ...base, id: 0x0CF00500 },
		Ident{ ...base, ext: false },
		Ident{ ...base, tp: false },
		Ident{ ...base, wire: 'can1' },
		Ident{ ...base, sig: 'EngineTorque' },
	]
	for o in others {
		assert !base.same(o), o.key()
		assert base.key() != o.key(), o.key()
	}
	assert base.same(Ident{ ...base })
}

// An edit to ONE database must not move a watch another wire's database backs — the rewrite
// loops matched (id, ext) alone, so editing the first-loaded DBC moved a rejoined watch
// belonging to another wire to the edited id and kind.
fn test_a_dbc_edit_moves_only_the_watches_that_wire_backs() {
	a := rejoined('can0', 'EngineSpeed')
	b := rejoined('can1', 'EngineSpeed')
	assert a.renamed_by(eec1, true, 'can0', 0xF004)
	assert !a.renamed_by(eec1, true, 'can1', 0xF004)
	assert !b.renamed_by(eec1, true, 'can0', 0xF004)
	// BY PARAMETER GROUP for a rejoined watch: the edited message's BO_ commonly spells
	// another source address, which is the whole reason such a message resolves by PGN at all
	assert a.renamed_by(0x0CF004FE, true, 'can0', 0xF004), 'another SA in the BO_ id'
	assert !a.renamed_by(eec1, true, 'can0', 0xF005), 'another group'
	// a frame's watch follows the edit by ID, whatever wire it was made on
	f := frame('EngineSpeed')
	assert f.renamed_by(eec1, true, 'can0', 0)
	assert f.renamed_by(eec1, true, 'can1', 0)
	assert !f.renamed_by(0x0CF004FE, true, 'can0', 0xF004)
	assert !f.renamed_by(eec1, false, 'can0', 0)
}

// What an edit CHANGES differs by kind: a frame's watch takes the new identifier, a rejoined
// one takes the new GROUP and has its identifier recomposed from it (the caller does that, with
// the sender and priority its own rows carry). Writing the database's raw id into a rejoined
// watch pointed it at a number no row carries; leaving its group alone left it on one the file
// no longer defines.
fn test_a_rejoined_watch_moves_by_group_and_keeps_what_its_rows_carry() {
	r := rejoined('can0', 'EngineSpeed')
	assert r.renamed_by(eec1, true, 'can0', 0xF004), 'the edit concerns it'
	moved := r.moved_to(0xF005)
	assert moved.pgn == 0xF005
	assert moved.wire == r.wire && moved.sig == r.sig && moved.tp
	assert !moved.same(r)
	// its identifier is the caller's to recompose; this package does not invent one
	assert moved.id == r.id
}

// A connection-mode transfer of a BROADCAST group goes to one node, and its identifier has no
// field for that — so two such transfers from one sender to different receivers wore the same
// number and became one producer, and one series (codex).
fn test_two_receivers_of_one_group_are_two_signals() {
	base := rejoined('can0', 'EngineSpeed')
	a := Ident{ ...base, da: 0x03 }
	b := Ident{ ...base, da: 0x21 }
	assert !a.same(b)
	assert !a.covers(row(b))
	assert !b.covers(row(a))
	assert a.covers(row(a))
	// a broadcast really has no destination, and says so the same way on both sides
	assert base.da == -1
	assert base.covers(row(base))
	assert !base.covers(row(a))
}
