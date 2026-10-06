module watchrule

const eec1 = u32(0x0CF00400)

fn frame(sig string) Ident {
	return on('can0', sig)
}

fn on(wire string, sig string) Ident {
	return Ident{
		id: eec1
		ext: true
		wire: wire
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

// #330: two wires carrying one identifier with different data — or different layouts in their
// own databases — are two signals. Unscoped, a frame watch interleaved both into one line.
fn test_two_wires_carrying_one_frame_are_two_signals() {
	a := on('can0', 'EngineSpeed')
	b := on('can1', 'EngineSpeed')
	assert !a.same(b)
	assert a.key() != b.key(), 'ImPlot keys a series by this'
	assert a.covers(row(a))
	assert !a.covers(row(b))
	assert !b.covers(row(a))
}

// A message picked from the database list has no row behind it, so no wire: it covers nothing
// rather than every wire, which is the behaviour #330 removes.
fn test_an_unbound_watch_covers_nothing() {
	u := on('', 'EngineSpeed')
	for w in ['can0', 'can1', ''] {
		assert !u.covers(Row{
			id: eec1
			ext: true
			wire: w
		}), w
	}
}

fn every(w string) bool {
	return true
}

struct Asked {
mut:
	n map[string]int
}

fn rows_of(rs []Row) fn (int) Row {
	return fn [rs] (k int) Row {
		return rs[k]
	}
}

// The migration for an unbound watch or selection: the OLDEST row's wire among wires whose
// databases define the message — stable as traffic arrives, and never a wire that carries the
// number under no definition of it.
fn test_an_unbound_watch_binds_to_the_oldest_wire_that_defines_its_message() {
	u := on('', 'EngineSpeed')
	rs := [
		Row{
			id: eec1
			ext: true
			wire: 'can2' // carries the number, defines nothing at it
		},
		Row{
			id: eec1
			ext: true
			wire: 'can1'
			someip: true // not a CAN frame at all
		},
		Row{
			id: eec1
			ext: false // another frame kind
			wire: 'can1'
		},
		Row{
			id: eec1
			ext: true
			tp: true // a rejoined message, another kind
			wire: 'can1'
		},
		Row{
			id: eec1
			ext: true
			wire: 'can1'
		},
		Row{
			id: eec1
			ext: true
			wire: 'can0'
		},
	]
	mut asked := &Asked{} // a closure captures by value, so through a pointer
	defines := fn [mut asked] (w string) bool {
		asked.n[w]++
		return w != 'can2'
	}
	assert u.bind(rs.len, rows_of(rs), every, defines) == 'can1'
	assert asked.n == {
		'can2': 1
		'can1': 1
	}, 'each wire asked once, and only until one answers'
	bound := Ident{
		...u
		wire: u.bind(rs.len, rows_of(rs), every, fn (w string) bool {
			return w != 'can2'
		})
	}
	assert bound.covers(rs[4])
	assert !bound.covers(rs[5])
	// nothing to bind to yet: stays unbound
	assert u.bind(1, rows_of(rs), every, fn (w string) bool {
		return w != 'can2'
	}) == ''
	assert u.bind(0, rows_of(rs), every, fn (w string) bool {
		return true
	}) == ''
	// a bound watch keeps its wire, whatever the rows say
	assert on('can0', 'EngineSpeed').bind(rs.len, rows_of(rs), every, fn (w string) bool {
		return true
	}) == 'can0'
}

fn test_nothing_matches_a_someip_row() {
	// no DBC message behind it; its payload layout is the deployment's
	for i in [frame('EngineSpeed'), rejoined('can0', 'EngineSpeed')] {
		assert i.covers(row(i))
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
	// a frame's watch follows the edit by ID, and since #330 only on its own wire
	f := frame('EngineSpeed')
	assert f.renamed_by(eec1, true, 'can0', 0)
	assert !f.renamed_by(eec1, true, 'can1', 0), 'another wire backs another watch'
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

// A recorded bus's wire starts with a NUL, and ImGui reads an id as a C string: every imported
// series' id ended there and the series shared one legend entry. The key carries none, and
// stays one-to-one with the wire.
fn test_the_key_carries_no_nul_and_still_separates_wires() {
	a := on('\x00rec:mf4:bus0', 'EngineSpeed')
	b := on('\x00rec:mf4:bus2', 'EngineSpeed')
	c := on('\\0rec:mf4:bus0', 'EngineSpeed') // a name that spells the escape
	for i in [a, b, c] {
		assert !i.key().contains('\x00'), i.key()
	}
	assert a.key() != b.key()
	assert a.key() != c.key()
	assert id_safe('inproc:CAN1') == 'inproc:CAN1'
}

// After an interface edit or a deleted row the history still carries the old live key, and its
// database lookup falls back to every file — so the rebinding watch landed straight back on the
// dead wire (codex on #410). Only a configured wire or a recorded bus is a candidate.
fn test_a_rebinding_watch_skips_a_live_wire_nothing_configures() {
	assert bind_candidate('can1', true)
	assert !bind_candidate('can0', false), 'a live key no channel is on'
	assert bind_candidate(rec_prefix + 'mf4:bus0', false), 'an unplaced recorded bus'
	assert !bind_candidate('', true)
	u := on('', 'EngineSpeed')
	rs := [
		Row{
			id: eec1
			ext: true
			wire: 'can0' // the old key, oldest in the history
		},
		Row{
			id: eec1
			ext: true
			wire: rec_prefix + 'mf4:bus0'
		},
		Row{
			id: eec1
			ext: true
			wire: 'can1'
		},
	]
	configured := fn (w string) bool {
		return w == 'can1'
	}
	all := fn (w string) bool {
		return true // the fallback: every database defines it
	}
	assert u.bind(rs.len, rows_of(rs), configured, all) == rec_prefix + 'mf4:bus0'
	assert u.bind(1, rows_of(rs), configured, all) == '', 'the dead wire alone binds nothing'
	assert u.bind(rs.len, rows_of(rs), fn (w string) bool {
		return w == 'can1'
	}, fn (w string) bool {
		return !w.starts_with(rec_prefix)
	}) == 'can1'
}

// A selection picked from the database list waits unbound; the DBC editor moving its message to
// another id moves it by the rule the watches follow, compared on the empty wire it has.
fn test_a_pending_selection_follows_an_edit_by_the_watch_rule() {
	pending := on('', '')
	assert pending.renamed_by(eec1, true, '', 0)
	assert !pending.renamed_by(eec1 + 1, true, '', 0)
	assert !pending.renamed_by(eec1, false, '', 0)
}
