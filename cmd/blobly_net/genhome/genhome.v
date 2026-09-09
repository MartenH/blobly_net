module genhome

// WHICH CHANNEL DOES A GENERATOR BELONG TO, and what survives an edit to the rows?
//
// A generator lives NESTED UNDER a channel in the project file and may TARGET another through
// `bus:`. Those are different questions and this module answers only the first — where a Save
// writes it back — because that is the one that kept going wrong. (The target is
// `project.resolve_sender_bus`, which is engine-side because it decides what a file MEANS.)
//
// EXTRACTED BECAUSE THE FINDINGS CLUSTERED HERE. Across the self-review and codex round 1 of
// #97, five defects landed in this one path, and the last of them was introduced by the previous
// round's fix — which is the signature CLAUDE.md names for "stop repairing and cover it":
//
//   1. Grouping by INTERFACE put every generator on a shared wire into BOTH channels' lists, so a
//      Save duplicated them and the next load came back with two of each.
//   2. Grouping by NAME instead has the same defect one step removed, because nothing enforces
//      unique channel names: two indistinguishable rows meant the first absorbed the second's
//      generators and the second lost them on reload.
//   3. A generator that matched no row was re-homed onto row 0 — so deleting an `inproc:` row
//      could start its cyclic generator transmitting on whatever real bus was listed first.
//   4. Renames applied one at a time and matched by name skipped the second of A->B, B->C, and
//      left B's generators answering to a name that had moved to another row.
//   5. An address edit rebound EVERY generator on the old wire, so retargeting one alias left the
//      sibling's generators carrying an interface their row does not have — after which the
//      consistency check added for (2) DELETED them on the next Save. A P1, caused by the fix
//      for (2).
//
// Every one of those is a pure question about names, indices and interfaces, with no ImGui and no
// app state in it. So it is answered here, once, and tested — the shape ../saverule set for Save
// (#250), ../taprule for the tap lifecycle (#260) and ../drainrule for the runtime view.

// Gen is a generator as far as "where does it live" is concerned.
pub struct Gen {
pub:
	own     string // the NAME of the channel it is nested under
	own_idx int // and that channel's INDEX, which is what actually carries it home
	iface   string // that channel's interface, as the generator last saw it
}

// Row is a configured channel, reduced to the two things that identify one — neither of which
// identifies one on its own, which is the whole lesson here.
pub struct Row {
pub:
	name  string
	iface string
}

// dropped is the home of a generator no row will take: its channel is gone. Deleting a bus has
// always taken its generators with it, and saying so explicitly is what lets a caller treat every
// other unmatched case as the bookkeeping slip it is.
pub const dropped = -1

// homes decides which row each generator is written under, as one index per generator in the
// order given. `dropped` (-1) means no row claims it.
//
// BY INDEX FIRST, because it is the only identity that separates two rows agreeing on name and
// interface. It is a real identity here: channels are appended and deleted but never reordered,
// and a deletion restacks the generators' copies.
//
// NAME AND INTERFACE ARE A CONSISTENCY CHECK, not the key. A stale index must not be able to hand
// a generator to an unrelated row, so the index is honoured only where the row it points at is
// still the row the generator remembers.
//
// THE SECOND PASS is for a generator whose index went stale anyway — a structural edit nobody told
// this rule about. It goes to a row matching by name and interface, in row order, rather than
// being lost to a bookkeeping slip. Each generator is claimed at most once, so nothing is
// duplicated, and what still matches nothing is dropped rather than re-homed onto row 0.
pub fn homes(gens []Gen, rows []Row) []int {
	mut out := []int{len: gens.len, init: dropped}
	for ri, r in rows {
		for gi, g in gens {
			if out[gi] != dropped {
				continue
			}
			if g.own_idx == ri && g.own == r.name && g.iface == r.iface {
				out[gi] = ri
			}
		}
	}
	for ri, r in rows {
		for gi, g in gens {
			if out[gi] != dropped {
				continue
			}
			if g.own == r.name && g.iface == r.iface {
				out[gi] = ri
			}
		}
	}
	return out
}

// moves_with_row reports whether an address edit on row `row` carries this generator to the new
// interface.
//
// ONLY THE EDITED ROW'S OWN. Matching on the old interface instead moved the generators of EVERY
// channel on that wire — two rows may share one deliberately — so retargeting one alias left the
// other's generators carrying an interface their own row does not have, and `homes` then dropped
// them. An edit to one row silently destroying another row's work.
pub fn moves_with_row(g Gen, row int) bool {
	return g.own_idx == row
}

// restack reports each generator's new `own_idx` after row `removed` is deleted, and `dropped`
// for the generators that go with it.
pub fn restack(gens []Gen, removed int) []int {
	mut out := []int{len: gens.len}
	for i, g in gens {
		out[i] = if g.own_idx == removed {
			dropped
		} else if g.own_idx > removed {
			g.own_idx - 1
		} else {
			g.own_idx
		}
	}
	return out
}
