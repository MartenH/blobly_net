// WHICH J1939 READING A RECORDED BUS TAKES, AND WHEN THE FILE MAY OVERRULE IT.
//
// A live wire has an owner to ask: the row that configures it, through its databases or its
// own `j1939:` tick. A RECORDING has no owner, so `load_recording` decides per recorded bus,
// and the decision comes from four routes -- an MF4's own bus numbering, a label two
// configured wires answer to, a label one wire answers to, and the fallback for a label no
// wire answers to. Three of those four are GUESSES. One is an answer.
//
// That distinction is the whole rule, and it was wrong twice in two review rounds of #344.
// First the evidence promotion was written against a gate value no bus ever takes, so it could
// never fire at all. Then the repair narrowed it to the `undecidable` fallback alone and lost
// the SOLE-WIRE fallback, which is the ordinary case: one CAN row in the project, one bus in
// the file, the label naming nothing -- the recording is placed on that row by arithmetic, not
// by identification, and if that row happens not to declare J1939 a capture that proves itself
// still imports unread.
//
// Both defects were the same question answered in one place at a time, which is what this repo
// covers with a rule instead of repairing again (CLAUDE.md, "when findings repeat in one path,
// write the test").
//
// THE PRINCIPLE: evidence beats SILENCE, never a STATEMENT. A label that names a configured
// wire has been identified, and that row's declaration is an answer about this bus -- the file
// does not get to overrule the operator. Every other route reached its gate without anybody
// saying anything about this bus, and there the bytes are the better witness.
module gaterule

// The gate sentinels. Here rather than beside the reader because this is where the set is
// closed: `load_recording` compared against a value outside it and the comparison was dead.
pub const undecidable = '? undecidable'
pub const evident = '? evident'

// Bus is one recorded bus, as the four routes see it.
pub struct Bus {
pub:
	// the file's own bus numbering (MF4), which names no project wire by construction
	from_mf4 bool
	// two configured wires on DIFFERENT destinations answer to this label, so it identifies
	// nothing -- a refusal to guess, which is still not an answer about the bus
	clash bool
	// the destination key of the one configured wire whose name, interface or key this label
	// spells. This is the only route that IDENTIFIES the bus.
	claim string
	// whether there was such a wire at all (a claim may legitimately be an empty key)
	claimed bool
	// the file carries a well-formed transport announcement on this bus -- a BAM or an RTS
	// whose size, packet count, destination and group number all agree. Nothing weaker counts.
	evident bool
}

// Sole is the one-CAN-wire fallback: available only when the project has exactly one CAN wire
// AND the file exactly one bus, since several unplaceable labels are the file saying it spans
// several buses and reading them all as the one wire reads a diagnostic bus as a truck bus.
pub struct Sole {
pub:
	dest string
	ok   bool
}

// Gate is the reading plus WHY, because the why is what evidence is allowed to act on.
pub struct Gate {
pub:
	gate string
	// nothing in the project said anything about this bus; its gate was reached by fallback,
	// by arithmetic or by refusal
	guessed bool
}

// placed is the gate before evidence: which of the four routes this bus took.
fn placed(b Bus, sole Sole) Gate {
	// An MF4 label names no project wire, so it never reaches the claim route; it takes the
	// fallback directly. Asked first because a numeric label could otherwise collide with a
	// channel named for a number.
	if b.from_mf4 {
		return fallback(sole)
	}
	if b.clash {
		return Gate{
			gate: undecidable
			guessed: true
		}
	}
	if b.claimed {
		return Gate{
			gate: b.claim
			guessed: false
		}
	}
	return fallback(sole)
}

fn fallback(sole Sole) Gate {
	if sole.ok {
		// placed on the one wire by arithmetic: the label identified nothing
		return Gate{
			gate: sole.dest
			guessed: true
		}
	}
	return Gate{
		gate: undecidable
		guessed: true
	}
}

// gate_for is the one answer. Evidence promotes a guessed gate and leaves a claimed one alone.
pub fn gate_for(b Bus, sole Sole) Gate {
	g := placed(b, sole)
	if g.guessed && b.evident {
		return Gate{
			gate: evident
			guessed: true
		}
	}
	return g
}
