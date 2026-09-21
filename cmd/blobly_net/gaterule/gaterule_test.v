module gaterule

const wire = 'socketcan:vcan0'
const other = 'socketcan:can1'

fn one_wire() Sole {
	return Sole{
		dest: wire
		ok: true
	}
}

fn no_wire() Sole {
	return Sole{
		dest: ''
		ok: false
	}
}

// THE ROUTE THAT IDENTIFIES THE BUS. A label naming a configured wire takes that wire's
// reading, and the file does not get to overrule it: the operator said something about this
// bus, and evidence beats silence rather than a statement.
fn test_a_claimed_bus_keeps_its_wire_and_evidence_does_not_move_it() {
	b := Bus{
		claim: wire
		claimed: true
	}
	assert gate_for(b, one_wire()).gate == wire
	assert gate_for(b, one_wire()).guessed == false

	with_ev := Bus{
		claim: wire
		claimed: true
		evident: true
	}
	assert gate_for(with_ev, one_wire()).gate == wire
}

// THE DEFECT ROUND 2 FOUND. One CAN row, one recorded bus, a label naming nothing: the bus is
// placed on that row by arithmetic. If the row declares no J1939 the capture imported unread,
// however plainly the file proved itself.
fn test_the_sole_wire_fallback_is_a_guess_and_evidence_overrides_it() {
	plain := Bus{}
	assert gate_for(plain, one_wire()).gate == wire
	assert gate_for(plain, one_wire()).guessed == true

	proven := Bus{
		evident: true
	}
	assert gate_for(proven, one_wire()).gate == evident
}

// THE DEFECT ROUND 1 FOUND, from the other side: the promotion must reach `undecidable`, which
// is what a bus the project cannot place actually takes. It was written against '' -- a value
// no route produces -- so the whole feature was dead.
fn test_an_unplaceable_bus_is_undecidable_and_evidence_overrides_it() {
	plain := Bus{}
	assert gate_for(plain, no_wire()).gate == undecidable

	proven := Bus{
		evident: true
	}
	assert gate_for(proven, no_wire()).gate == evident
}

// A label two wires on different destinations answer to identifies nothing. Refusing to guess
// is not the same as being told, so evidence still speaks.
fn test_a_clashing_label_is_a_guess_too() {
	clash := Bus{
		clash: true
		claim: wire
		claimed: true
	}
	assert gate_for(clash, one_wire()).gate == undecidable
	assert gate_for(clash, one_wire()).guessed == true

	proven := Bus{
		clash: true
		claim: wire
		claimed: true
		evident: true
	}
	assert gate_for(proven, one_wire()).gate == evident
}

// An MF4's labels are the file's own numbering, so they take the fallback without ever
// consulting the claim table -- a bus numbered like a channel is not that channel.
fn test_an_mf4_label_never_claims_and_follows_the_fallback() {
	numbered := Bus{
		from_mf4: true
		claim: other
		claimed: true
	}
	assert gate_for(numbered, one_wire()).gate == wire
	assert gate_for(numbered, one_wire()).guessed == true
	assert gate_for(numbered, no_wire()).gate == undecidable

	proven := Bus{
		from_mf4: true
		claim: other
		claimed: true
		evident: true
	}
	assert gate_for(proven, one_wire()).gate == evident
}

// THE CLASS, stated once: every route but the claim is a guess, and evidence promotes exactly
// the guesses. Written as a table so a fifth route cannot be added without answering this.
fn test_evidence_promotes_every_guessed_route_and_only_those() {
	routes := [
		Bus{},
		Bus{
			clash: true
		},
		Bus{
			from_mf4: true
		},
		Bus{
			claim: wire
			claimed: true
		},
	]
	for r in routes {
		for sole in [one_wire(), no_wire()] {
			bare := gate_for(r, sole)
			mut with_ev := Bus{
				from_mf4: r.from_mf4
				clash: r.clash
				claim: r.claim
				claimed: r.claimed
				evident: true
			}
			got := gate_for(with_ev, sole)
			if bare.guessed {
				assert got.gate == evident
			} else {
				assert got.gate == bare.gate
			}
		}
	}
}

// The sentinels are not destination keys, and nothing may spell one by accident: they carry a
// space, which no interface or destination key does.
fn test_the_sentinels_cannot_be_mistaken_for_a_destination() {
	assert undecidable.contains(' ')
	assert evident.contains(' ')
	assert undecidable != evident
}
