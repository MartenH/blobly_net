module xsd

import flatxml

// A content model whose every count is 0, 1 or unbounded (most of them) is decided by Glushkov's
// automaton, which for such a model is exact and, the model being deterministic, a DFA: one table
// read per child. Its states are classes of positions, those followed by the same particles and
// alike in whether the model can end there, so a repeated choice of hundreds of elements is one
// state. Other counts need counting, which the walker (content.v) does; it also explains what the
// automaton refuses.

const max_dfa_cells = 1 << 20

// ContentDfa: next[state * slots + slot] is the state a child in slot (its TypeIndex slot) moves
// to, 0 when none. State 1 is the start.
struct ContentDfa {
	slots u32
mut:
	next   []u16
	accept []bool
}

// build_dfa makes complex type ct's automaton, or none when its counts need counting or its table
// would be too large.
fn build_dfa(s &Schema, root u32, idx &TypeIndex) ?&ContentDfa {
	mut g := new_glushkov(s, root) or { return none }
	for p in g.m.part {
		pt := s.particles[p]
		if pt.min > 1 || (pt.max > 1 && pt.max != unbounded) {
			return none
		}
	}
	nodes := g.m.part.len
	mut ends := []bool{len: nodes}
	for x in g.last_of(0) {
		ends[x] = true
	}
	slots := u32(idx.decls.len)
	mut dfa := &ContentDfa{
		slots:  slots
		next:   []u16{len: int(slots)} // state 0's row
		accept: [false]
	}
	mut ids := map[u64]u16{} // a class's hash -> its state
	mut refs := [][]u32{len: 1} // per state: the nodes whose first sets follow it
	mut class := []u16{len: nodes} // per position: its state, once known
	// the start is followed by the root
	ids[follow_hash([u32(0)], s.nullable(g.m.part[0]))] = 1
	refs << [u32(0)]
	dfa.accept << s.nullable(g.m.part[0])
	dfa.next << []u16{len: int(slots)}
	// Each state's moves, finding the states they reach as they come.
	for st := 1; st < refs.len; st++ {
		for ref in refs[st] {
			for y in g.first_of(ref) {
				if class[y] == 0 {
					h := follow_hash(g.follow[y], ends[y])
					if id := ids[h] {
						// two classes with one hash: rare enough to leave to the walker
						if refs[id] != g.follow[y] || dfa.accept[id] != ends[y] {
							return none
						}
						class[y] = id
					} else {
						if (refs.len + 1) * int(slots) > max_dfa_cells || refs.len >= 0xFFFF {
							return none
						}
						class[y] = u16(refs.len)
						ids[h] = class[y]
						refs << g.follow[y]
						dfa.accept << ends[y]
						dfa.next << []u16{len: int(slots)}
					}
				}
				slot := idx.children[g.key(y)] or { return none }
				dfa.next[u32(st) * slots + slot] = class[y]
			}
		}
	}
	return dfa
}

// content_dfa is complex type ct's automaton, made on first use; nil when the walker decides.
fn (mut vr Validator) content_dfa(ct u32) &ContentDfa {
	if vr.dfa_made[ct] {
		return vr.dfas[ct]
	}
	vr.dfa_made[ct] = true
	if dfa := build_dfa(vr.s, vr.s.complex_types[ct].particle, vr.type_index(ct)) {
		vr.dfas[ct] = dfa
	}
	return vr.dfas[ct]
}

// dfa_accepts runs element i's children through dfa, recording the declaration each matches for
// the typing pass. Children the type does not declare are left out: the typing pass reports them.
@[direct_array_access]
fn (mut vr Validator) dfa_accepts(dfa &ContentDfa, idx &TypeIndex, i u32) bool {
	mut st := u32(1)
	mut c := vr.d.first_child(i)
	for c != flatxml.no_node {
		if vr.d.is_element(c) {
			key := vr.key(c) or { u64(0) }
			if slot := idx.children[key] {
				vr.v.decl[c] = idx.decls[slot] + 1
				st = dfa.next[st * dfa.slots + slot]
				if st == 0 {
					return false
				}
			}
		}
		c = vr.d.next_sibling(c)
	}
	return dfa.accept[st]
}
