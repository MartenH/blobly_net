module flatxml

// A three-way merge: two changed versions of one base, put together on the base.
//
// Each version is compared with the base (`diff`), so both diffs name the base's nodes. Their
// changes are put together node by node: a change only one side makes is taken; the same change
// made on both sides is taken once; where the two change one node differently, that is a
// conflict, and ours is taken. The changes taken are applied to the base, ours first, then
// theirs read through ours (`Diff.apply_to`), so every byte no change touched stays as the base
// has it. A node ours moves into another document is copied there as ours has it, so a change
// of theirs below it is a conflict; a node theirs would copy into another document stays where
// it is when ours changed something below it, and that is a conflict too: no change of either
// side is dropped without one. A conflict is reported with the node's place in all three versions, and the result is
// still made, holding ours: a caller for whom a conflict is an error refuses it when there is one.
//
// The same is a patch: the changes from A to B, made on C, are the merge of C (ours) and B
// (theirs) on the base A.

// What two sides can disagree about.
pub enum ConflictKind {
	text    // the own text of one node, changed to two different texts
	attr    // one attribute of one node, set to two values, or set on one side and removed on the other
	removed // a node removed on one side and changed, or something below it changed, on the other
	// a node moved to two places, or two into each other, or one moved by a side into another
	// file where the other changed something below it
	moved
	added // two different children of one identity (key, or single name) added under one node
}

// Conflict is a node both sides change differently: the base's node, and each side's change.
pub struct Conflict {
pub:
	kind   ConflictKind
	node   MNode  // the node of the base
	ours   Change // ours's change (from the base to ours)
	theirs Change // theirs's
	name   string // attr: the attribute's name
}

// Merge3 is a three-way merge: the two diffs from the base, the conflicts, and the edits on the
// base that make the result.
pub struct Merge3 {
pub:
	base  &Merged = unsafe { nil }
	taken int // changes of theirs taken, besides all of ours
pub mut:
	ours      Diff
	theirs    Diff
	conflicts []Conflict
	edit      &MEdit = unsafe { nil }
}

// Refusals is where the conflicts found while applying go: a heap object, so a callback can add
// to it.
@[heap]
struct Refusals {
mut:
	list []Conflict
}

// merge3 merges ours and theirs, two changed versions of base, all read by the same rules: the
// result is edits on the base's documents (`edit`), written as `MEdit` writes them.
pub fn merge3(base &Merged, ours &Merged, theirs &Merged, opts ApplyOptions) !Merge3 {
	d1 := diff(base, ours)
	d2 := diff(base, theirs)
	side := side_of(&d1)
	mut keep, mut conflicts := combine(&d1, &d2, &side)
	mut me := d1.apply(into: opts.into)!
	// theirs's changes below a node ours copied into another document would land on what it left
	mut kept := []Change{cap: keep.len}
	for c in keep {
		if x := copied_above(me, anchor_of(c)) {
			k := side.moved[x.i] or { -1 }
			if k >= 0 {
				conflicts << Conflict{
					kind:   .moved
					node:   x
					ours:   d1.changes[k]
					theirs: c
				}
				continue
			}
		}
		kept << c
	}
	// a node theirs would copy into another document stays where it is when ours changed below it
	mut refused := &Refusals{}
	across := fn [side, d1, mut refused] (c Change) bool {
		if k := side.below[c.old.i] {
			refused.list << Conflict{
				kind:   .moved
				node:   c.old
				ours:   d1.changes[k]
				theirs: c
			}
			return false
		}
		return true
	}
	mut rest := d2
	rest.changes = kept
	rest.apply_to(mut me, into: opts.into, across: across)!
	conflicts << refused.list
	return Merge3{
		base:      base
		ours:      d1
		theirs:    d2
		conflicts: conflicts
		taken:     kept.len - refused.list.len
		edit:      me
	}
}

// clean reports whether there is no conflict.
pub fn (m &Merge3) clean() bool {
	return m.conflicts.len == 0
}

// Side is what one side's diff does to the base's nodes, each with the number of its change.
struct Side {
mut:
	removed map[u32]int   // a base node removed
	moved   map[u32]int   // a base node moved
	text    map[u32]int   // a base node whose text changed
	attrs   map[u64]int   // (base node, attribute key)
	added   map[u32][]int // a base node -> the changes adding under it
	// a base node something but a removal changes, at it (itself, or a child it gains) or below
	touched map[u32]int
	// a base node anything changes at or below, a removal too
	below map[u32]int
}

fn side_of(d &Diff) Side {
	mut s := Side{}
	for k, c in d.changes {
		match c.kind {
			.removed {
				// a removal is not a change below for the other side's removal: both is one
				s.removed[c.old.i] = k
				mark(mut s.below, d.old, c.old.i, k)
			}
			.moved {
				s.moved[c.old.i] = k
				for n in [c.old.i, c.parent.i] {
					mark(mut s.touched, d.old, n, k)
					mark(mut s.below, d.old, n, k)
				}
			}
			.text, .attr {
				if c.kind == .text {
					s.text[c.old.i] = k
				} else {
					s.attrs[mix(u64(c.old.i), c.akey)] = k
				}
				mark(mut s.touched, d.old, c.old.i, k)
				mark(mut s.below, d.old, c.old.i, k)
			}
			.added {
				s.added[c.parent.i] << k
				mark(mut s.touched, d.old, c.parent.i, k)
				mark(mut s.below, d.old, c.parent.i, k)
			}
		}
	}
	return s
}

// mark notes change k at node n of m and every node above it, where none is noted yet.
fn mark(mut at map[u32]int, m &Merged, n u32, k int) {
	mut c := m.node(n)
	for c.ok() && c.i !in at {
		at[c.i] = k
		c = c.parent()
	}
}

// anchor_of is the base node change c is made at: the node it changes, or the one it puts a node
// under.
fn anchor_of(c Change) MNode {
	return if c.kind == .added { c.parent } else { c.old }
}

// removed_above is the change of side s that removes n or a node above it, if one does.
fn removed_above(s &Side, n MNode) ?int {
	mut c := n
	for c.ok() {
		if k := s.removed[c.i] {
			return k
		}
		c = c.parent()
	}
	return none
}

// copied_above is n or the node above it that an applied diff copied into another document.
fn copied_above(me &MEdit, n MNode) ?MNode {
	if me.copied.len == 0 {
		return none
	}
	mut c := n
	for c.ok() {
		if me.copied[c.i] {
			return c
		}
		c = c.parent()
	}
	return none
}

// run_texts are the texts of runs, in order, their slots left out.
fn run_texts(runs []TextRun) []string {
	return runs.map(it.text)
}

// identity is what tells an added child from its siblings: its name, and its key where the rules
// give it one; none for a child that is its own.
fn identity(d &Diff, n MNode) ?u64 {
	if !identified(d.new, n.i) {
		return none
	}
	return mix(d.nname[n.i], key_hash(0, 0, d.new.key_of(n.i), d.new.rules.fold))
}

// combine is the changes of theirs to take after ours, and the conflicts: a change theirs alone
// makes is taken; one ours makes too, the same, is not taken again; one that disagrees with ours
// is a conflict, and not taken.
fn combine(d1 &Diff, d2 &Diff, ours &Side) ([]Change, []Conflict) {
	mut keep := []Change{}
	mut conflicts := []Conflict{}
	// nodes ours removes and theirs changes below, once each
	mut said := map[u32]bool{}
	// ours's additions matched to one of theirs already
	mut used := map[int]bool{}
	// where theirs's moves taken put a node: a base node -> its new parent
	mut moved_to := map[u32]u32{}
	for c in d2.changes {
		at := anchor_of(c)
		// below a node ours removes: theirs changes something that is gone
		if k := removed_above(ours, at) {
			if c.kind == .removed {
				continue // removed by ours already, or with a node above it
			}
			r := d1.changes[k]
			if !said[r.old.i] {
				said[r.old.i] = true
				conflicts << Conflict{
					kind:   .removed
					node:   r.old
					ours:   r
					theirs: c
				}
			}
			continue
		}
		match c.kind {
			.removed {
				// theirs removes what ours changes at or below it, or moves into it: ours is kept
				if k := ours.touched[c.old.i] {
					conflicts << Conflict{
						kind:   .removed
						node:   c.old
						ours:   d1.changes[k]
						theirs: c
					}
					continue
				}
			}
			.moved {
				if k := ours.moved[c.old.i] {
					o := d1.changes[k]
					if o.parent.i != c.parent.i {
						conflicts << Conflict{
							kind:   .moved
							node:   c.old
							ours:   o
							theirs: c
						}
					}
					continue
				}
				if k := removed_above(ours, c.parent) {
					conflicts << Conflict{
						kind:   .removed
						node:   d1.changes[k].old
						ours:   d1.changes[k]
						theirs: c
					}
					continue
				}
				// into itself, once ours's moves and theirs's taken are made: a cycle
				if k := cycle(d1, ours, moved_to, c) {
					conflicts << Conflict{
						kind:   .moved
						node:   c.old
						ours:   d1.changes[k]
						theirs: c
					}
					continue
				}
				moved_to[c.old.i] = c.parent.i
			}
			.text {
				if k := ours.text[c.old.i] {
					o := d1.changes[k]
					base := run_texts(c.old.text_runs())
					ours_real := run_texts(o.runs) != base
					theirs_real := run_texts(c.runs) != base
					// a text change that only moves runs among the children is ours's structure
					if theirs_real && ours_real && run_texts(o.runs) != run_texts(c.runs) {
						conflicts << Conflict{
							kind:   .text
							node:   c.old
							ours:   o
							theirs: c
						}
						continue
					}
					if !(theirs_real && !ours_real) {
						continue
					}
				}
			}
			.attr {
				key := mix(u64(c.old.i), c.akey)
				if k := ours.attrs[key] {
					o := d1.changes[k]
					if o.after != c.after {
						conflicts << Conflict{
							kind:   .attr
							node:   c.old
							ours:   o
							theirs: c
							name:   c.name
						}
					}
					continue
				}
			}
			.added {
				// an equal subtree added under one node on both sides is one addition; two of
				// one identity that differ are a conflict
				mut same := false
				mut clash := -1
				id := identity(d2, c.new)
				for k in ours.added[c.parent.i] or { []int{} } {
					if used[k] {
						continue
					}
					o := d1.changes[k]
					if d1.nhash[o.new.i] == d2.nhash[c.new.i] {
						same = true
						used[k] = true
						break
					}
					if theirs_id := id {
						if ours_id := identity(d1, o.new) {
							if ours_id == theirs_id {
								clash = k
							}
						}
					}
				}
				if same {
					continue
				}
				if clash >= 0 {
					conflicts << Conflict{
						kind:   .added
						node:   c.parent
						ours:   d1.changes[clash]
						theirs: c
					}
					continue
				}
			}
		}
		keep << c
	}
	return keep, conflicts
}

// cycle is the change of ours that would make theirs's move c put a node inside itself: its new
// parent is the node, or below it, once ours's moves and theirs's moves taken (moved_to) are made.
fn cycle(d1 &Diff, ours &Side, moved_to map[u32]u32, c Change) ?int {
	base := d1.old
	mut p := c.parent.i
	mut via := -1
	for steps := 0; steps < base.len(); steps++ {
		if p == c.old.i {
			return if via >= 0 { via } else { none }
		}
		if k := ours.moved[p] {
			via = k
			p = d1.changes[k].parent.i
		} else if q := moved_to[p] {
			p = q
		} else {
			parent := base.parent[p]
			if parent == no_mnode {
				return none
			}
			p = parent
		}
	}
	return none
}

// describe is a conflict in one line: what, where, and the node's place in the base and each
// side (`-` where a side removed it).
pub fn (mut m Merge3) describe(c Conflict) string {
	what := match c.kind {
		.text {
			'text ${quoted(c.ours.after)} / ${quoted(c.theirs.after)}'
		}
		.attr {
			'@${c.name} ${quoted(c.ours.after)} / ${quoted(c.theirs.after)}'
		}
		.removed {
			'removed on one side, changed on the other (${c.ours.kind} / ${c.theirs.kind})'
		}
		.moved {
			'moved (${c.ours.kind} under ${m.ours.path(anchor_of(c.ours))} / ${c.theirs.kind} under ${m.theirs.path(c.theirs.parent)})'
		}
		.added {
			'two of one identity added (${m.ours.path(c.ours.new)} / ${m.theirs.path(c.theirs.new)})'
		}
	}
	base_pos := m.ours.pos(c.node)
	ours_pos := if c.ours.new.ok() { m.ours.pos(c.ours.new) } else { '-' }
	theirs_pos := if c.theirs.new.ok() { m.theirs.pos(c.theirs.new) } else { '-' }
	return '! ${m.ours.path(c.node)}: ${what}  base ${base_pos}, ours ${ours_pos}, theirs ${theirs_pos}'
}
