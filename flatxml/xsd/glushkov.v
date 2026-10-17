module xsd

// Two rules on content models, checked when a schema compiles (XSD 1.0 Part 1, 3.8.6), and the
// automaton most content models are validated by (dfa.v), all from Glushkov's construction:
//
// - The positions of a content model are the places an element can occur. first(n) is the
//   positions node n can begin with, last(n) those it can end with, follow(x) those that can come
//   after position x. A particle repeats (its last positions are followed by its first) when it
//   can occur more than once.
// - Unique Particle Attribution: a child element is matched by one particle, decided without
//   looking ahead. The model is ambiguous when two different positions of one name compete in
//   first(root) or in some follow(x).
// - Element Declarations Consistent: elements of one name in one content model have one type.
//
// A position is a place, not a particle: a group referenced twice in one model puts its particles
// in two places, and merging them would merge what follows each. So the construction runs on the
// model expanded (Model). follow(x) is kept as the nodes whose first sets follow x rather than
// their union: a repeated choice of hundreds of alternatives is one reference for each position,
// not hundreds squared.

const max_model_nodes = 100_000

// Model is a complex type's content model with its group references expanded, in preorder: node 0
// is the root, and each node is one place a particle occurs.
struct Model {
mut:
	part []u32 // per node: its particle
	lo   []u32 // per node: where its children start in kids
	n    []u32 // per node: how many children it has
	kids []u32
}

fn (mut m Model) add(s &Schema, p u32) !u32 {
	if m.part.len >= max_model_nodes {
		return error('has more than ${max_model_nodes} particles once its group references are expanded')
	}
	id := u32(m.part.len)
	m.part << p
	m.lo << 0
	m.n << 0
	mut kids := []u32{}
	for ch in s.particle_children(p) {
		kids << m.add(s, ch)!
	}
	m.lo[id] = u32(m.kids.len)
	m.n[id] = u32(kids.len)
	m.kids << kids
	return id
}

fn (m &Model) children(n u32) []u32 {
	return m.kids[m.lo[n]..m.lo[n] + m.n[n]]
}

struct Glushkov {
	s &Schema = unsafe { nil }
mut:
	m      Model
	first  [][]u32 // per node, made on first use
	last   [][]u32 // per node, made on first use
	made   []u8    // per node: bit 0, first is made; bit 1, last is made
	follow [][]u32 // per position: the nodes whose first sets follow it
}

// new_glushkov expands the content model rooted at particle root and links its positions.
fn new_glushkov(s &Schema, root u32) !Glushkov {
	mut m := Model{}
	m.add(s, root)!
	n := m.part.len
	mut g := Glushkov{
		s:      s
		m:      m
		first:  [][]u32{len: n}
		last:   [][]u32{len: n}
		made:   []u8{len: n}
		follow: [][]u32{len: n}
	}
	g.link(0)
	// each follow list as a set, sorted, so equal sets are equal lists
	for x in 0 .. n {
		if g.follow[x].len > 1 {
			g.follow[x].sort()
			mut k := 1
			for j in 1 .. g.follow[x].len {
				if g.follow[x][j] != g.follow[x][k - 1] {
					g.follow[x][k] = g.follow[x][j]
					k++
				}
			}
			g.follow[x].trim(k)
		}
	}
	return g
}

@[inline]
fn (g &Glushkov) particle(n u32) Particle {
	return g.s.particles[g.m.part[n]]
}

// key is the name of position x.
@[inline]
fn (g &Glushkov) key(x u32) u64 {
	return g.s.elements[g.particle(x).term].name.key()
}

fn (mut g Glushkov) first_of(n u32) []u32 {
	if g.made[n] & 1 != 0 {
		return g.first[n]
	}
	pt := g.particle(n)
	mut out := []u32{}
	// a particle that can occur no times has no positions
	if pt.max > 0 {
		match pt.kind {
			.element {
				out << n
			}
			.choice {
				for ch in g.m.children(n) {
					out << g.first_of(ch)
				}
			}
			else {
				for ch in g.m.children(n) {
					out << g.first_of(ch)
					if !g.s.nullable(g.m.part[ch]) {
						break
					}
				}
			}
		}
	}
	g.first[n] = out
	g.made[n] |= 1
	return out
}

fn (mut g Glushkov) last_of(n u32) []u32 {
	if g.made[n] & 2 != 0 {
		return g.last[n]
	}
	pt := g.particle(n)
	mut out := []u32{}
	if pt.max > 0 {
		match pt.kind {
			.element {
				out << n
			}
			.choice {
				for ch in g.m.children(n) {
					out << g.last_of(ch)
				}
			}
			else {
				kids := g.m.children(n)
				for k := kids.len - 1; k >= 0; k-- {
					out << g.last_of(kids[k])
					if !g.s.nullable(g.m.part[kids[k]]) {
						break
					}
				}
			}
		}
	}
	g.last[n] = out
	g.made[n] |= 2
	return out
}

// link adds the follow references node n makes: within a sequence, an item's last positions are
// followed by the next items' first positions (past any that can be empty); a particle whose
// can occur more than once is followed by itself.
fn (mut g Glushkov) link(n u32) {
	pt := g.particle(n)
	if pt.max == 0 {
		return
	}
	if pt.kind != .element {
		kids := g.m.children(n)
		for k, ch in kids {
			g.link(ch)
			if pt.kind == .sequence {
				mut next := []u32{}
				for j in k + 1 .. kids.len {
					next << kids[j]
					if !g.s.nullable(g.m.part[kids[j]]) {
						break
					}
				}
				if next.len > 0 {
					for x in g.last_of(ch) {
						g.follow[x] << next
					}
				}
			}
		}
	}
	if pt.max > 1 {
		for x in g.last_of(n) {
			g.follow[x] << n
		}
	}
}

// follow_hash hashes a follow list (FNV-1a), with a flag: equal for equal lists and flags.
fn follow_hash(refs []u32, flag bool) u64 {
	mut h := u64(0xcbf29ce484222325)
	for id in refs {
		h = (h ^ id) * 0x100000001b3
	}
	return (h ^ u64(flag)) * 0x100000001b3
}

// check_content_models applies both rules to every complex type's content model.
fn (mut r Reader) check_content_models() ! {
	for ct in 0 .. r.s.complex_types.len {
		root := r.s.complex_types[ct].particle
		if root == no_particle {
			continue
		}
		where := 'type ${r.ct_name(u32(ct))}'
		// a model in which no name occurs twice cannot be ambiguous (most of them)
		if !consistent(r.s, root, where)! {
			continue
		}
		mut g := new_glushkov(r.s, root) or {
			// the walker validates it without expanding it; only this check is given up
			r.s.notes << 'the content model of ${where} ${err.msg()}: not checked for ambiguity'
			continue
		}
		g.distinct(g.first_of(0), where)!
		// each position's followers, once for each set of references they come from
		mut checked := map[u64][]u32{}
		for x in 0 .. g.m.part.len {
			refs := g.follow[x]
			if refs.len == 0 {
				continue
			}
			h := follow_hash(refs, false)
			if done := checked[h] {
				if done == refs {
					continue
				}
			}
			mut positions := []u32{}
			for ref in refs {
				positions << g.first_of(ref)
			}
			g.distinct(positions, where)!
			checked[h] = refs
		}
	}
}

// distinct refuses two different positions of one name among positions.
fn (g &Glushkov) distinct(positions []u32, where string) ! {
	mut seen := map[u64]u32{}
	for x in positions {
		key := g.key(x)
		if other := seen[key] {
			if other != x {
				return error('the content model of ${where} is not deterministic: <${g.s.names[u32(key)]}> could match two particles (Unique Particle Attribution)')
			}
		} else {
			seen[key] = x
		}
	}
}

// consistent refuses two elements of one name and different types in the model rooted at p, and
// reports whether a name occurs in two places (two particles, or one group referenced twice).
fn consistent(s &Schema, p u32, where string) !bool {
	mut types := map[u64]TypeRef{}
	mut stack := [p]
	mut seen := map[u32]bool{}
	mut twice := false
	// every element particle under p, each group once
	for stack.len > 0 {
		q := stack.pop()
		if q in seen {
			twice = true
			continue
		}
		seen[q] = true
		pt := s.particles[q]
		if pt.kind == .element {
			decl := s.elements[pt.term]
			key := decl.name.key()
			if t := types[key] {
				if t != decl.typ {
					return error('the content model of ${where} has elements named <${s.names[decl.name.local]}> of different types (Element Declarations Consistent)')
				}
				twice = true
			} else {
				types[key] = decl.typ
			}
			continue
		}
		stack << s.particle_children(q)
	}
	return twice
}
