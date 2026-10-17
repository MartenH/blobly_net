module flatxml

import hash

// The merged view of a document set: its documents read as one, by a rule set. A merged node
// is the list of nodes, from any of the documents, that have one identity; its children are
// their children, put together by the rules. Nothing is copied: a merged node keeps where each
// of its contributions is, so a change can go back to the files it came from.
//
// The view is built top down, one merged node at a time, so the children of a merged node are
// consecutive in the arrays below, and so are its contributions.

pub const no_mnode = u32(0xFFFF_FFFF)
const no_rule = u32(0xFFFF_FFFF)
const scan_children = 16 // up to this many children, a child is found by reading them all

// What the rules forbid. The view keeps the first of what disagrees (in the set's order, then
// document order) and leaves the rest out; a caller for whom any problem is an error refuses
// the view when `problems` is not empty.
pub enum ProblemKind {
	collision     // one key (or a single child) more than once where the rule does not merge
	key_reused    // a key another child of its scope already has, under another parent or name
	ordered_split // the children of an ordered aggregation in more than one document
	too_many      // more children than the rule allows
	value_differs // two contributions to one node whose text, or one attribute, differ
	name_differs  // one key under two element names in one aggregation, or roots named differently
	missing_key   // a child of a keyed aggregation without its key: kept, as a child of its own
}

// Problem is one thing the rules forbid, with every node involved.
pub struct Problem {
pub:
	kind ProblemKind
	node u32    // the merged node: the parent of the children concerned, or the node that differs
	key  string // the key concerned, where there is one
	what string // the element named, or `@name` for an attribute that differs
	at   []Node // every node involved; the first is the one kept, where one is
}

enum MKind {
	root
	keyed
	single
	each
}

struct Frag {
	doc u32
	i   u32
}

@[heap]
pub struct Merged {
pub:
	set &DocSet = unsafe { nil }
pub mut:
	problems []Problem
mut:
	rules  CompiledRules
	source []Rule // the rules as given, so a node can say which put it together
	count u32 // merged nodes; the arrays below are allocated for as many as the set has nodes
	// per merged node
	name    []u32
	parent  []u32
	scope   []u32 // the merged node a key is unique in: the nearest ancestor that is not single
	rule    []u32
	kind    []MKind
	key_lo  []u32 // the key of node m is key_buf[key_lo[m] .. key_lo[m + 1]]
	key_buf []u8
	frag_lo []u32 // the contributions of node m are frags[frag_lo[m] .. frag_lo[m + 1]]
	kid_lo  []u32 // the children of node m are kid_lo[m] .. kid_lo[m + 1]
	frags   []Frag
	nfrags  int
	// (parent, name, key) -> node, for the keyed and single children of a node with more than
	// scan_children; fewer are found by reading them
	by_name KeyIndex = KeyIndex{
		by_parent: true
	}
	by_key  KeyIndex // (scope, key) -> node, for keyed nodes
	// scratch, reused for every node; each holds nkids, nouts, nout_frags
	kids       []Kid
	outs       []Out
	out_frags  []Frag
	nkids      int
	nouts      int
	nout_frags int
	order      []int
	group      map[u32]int // a single aggregation's names, numbered as first written
	starts     []int
	fill       []int
	listed     []int
	runs       []Run
	keyed_at   []KeyAt
	missing    []int  // keyed's children without a key
	kid_sort   []Kid  // expand's children, sorted by aggregation
	held       []Held // differs' attributes, of the first fragment to give each
	ignored    map[u32]bool // differs' ignored attribute identities, for one node
	keys       []string
}

struct Kid {
	doc  u32
	i    u32
	tag  u32
	rule u32
	seq  int
}

// Out is a merged child about to be made: its contributions are out_frags[lo .. hi].
struct Out {
	name u32
	rule u32
	kind MKind
	key  string
	lo   int
	hi   int
}

// Run is order[lo .. hi]: kids of one key, or, empty, of one name and no key.
struct Run {
	lo    int
	hi    int
	empty bool
	first int // the run's first child as written (order[lo]): ordered rules keep runs in its order
}

// KeyAt is a keyed child (its index in kids) with its key, for sorting them by key.
struct KeyAt {
	key string
	j   int
}

// compare_key_at orders keyed children by key, then as written; compare_key_at_fold the same
// with keys compared ignoring ASCII case. Plain functions, not closures: keyed sorts the
// children of every keyed parent, and a V closure is allocated (and registered) when made.
fn compare_key_at(a &KeyAt, b &KeyAt) int {
	c := compare_keys(a.key, b.key, false)
	return if c != 0 { c } else { a.j - b.j }
}

fn compare_key_at_fold(a &KeyAt, b &KeyAt) int {
	c := compare_keys(a.key, b.key, true)
	return if c != 0 { c } else { a.j - b.j }
}

fn compare_run_first(a &Run, b &Run) int {
	return a.first - b.first
}

// merge reads the set's documents as one, by the rules: a view over them, and what the rules
// forbid in `problems`. The documents' roots are the merged root, if they share its name.
pub fn (s &DocSet) merge(rules RuleSet) !&Merged {
	// a merged node has an element of its own, so there are at most as many as elements
	mut total := 1
	for d in s.docs {
		total += d.len() - 1 - d.text_node_count()
	}
	if rules.local_ns != '' {
		for d in s.docs {
			if d.ns.len != d.tag.len {
				return error('${d.path}: merging by local names needs namespaces resolved')
			}
		}
	}
	// with a local namespace, the root is a document's in it: with none, there is nothing of it
	// to merge, and a view holding a problem about a root it does not have would be no view
	if rules.local_ns != '' && s.docs.len > 0 {
		if !s.docs.any(it.ns_uri(it.ns_of(it.root())) == rules.local_ns) {
			return error('no document\'s root is in the local namespace ${rules.local_ns} (${s.docs.map(it.path).join(', ')})')
		}
	}
	// one reading of names for every document: a resolved document's prefixes are bound, an
	// unresolved one's are only spellings, and an attribute of one cannot be told to be or not to
	// be the other's. So every document resolved, or none
	if s.docs.len > 1 {
		r0 := s.docs[0].ns.len == s.docs[0].tag.len
		for d in s.docs[1..] {
			if (d.ns.len == d.tag.len) != r0 {
				return error('${d.path}: its namespaces are ${if r0 { 'not' } else { '' }} resolved and ${s.docs[0].path}\'s are${if r0 { '' } else { ' not' }}; resolve every document of the set, or none'.replace('  ', ' '))
			}
		}
	}
	mut m := &Merged{
		set:     s
		rules:   rules.compile(s.tab)!
		source:  rules.rules.clone()
		name:    []u32{len: total}
		parent:  []u32{len: total}
		scope:   []u32{len: total}
		rule:    []u32{len: total}
		kind:    []MKind{len: total}
		key_lo:  []u32{len: total + 1}
		frag_lo: []u32{len: total + 1}
		kid_lo:  []u32{len: total + 1}
		frags:   []Frag{len: total}
	}
	m.by_name.reserve(total / 8)
	m.by_key.reserve(total / 8)
	if s.docs.len > 0 {
		m.build()
	}
	m.fit()
	unsafe {
		m.kids.free()
		m.outs.free()
		m.out_frags.free()
		m.order.free()
		m.starts.free()
		m.fill.free()
		m.listed.free()
		m.runs.free()
		m.keyed_at.free()
		m.keys.free()
		m.group.free()
		m.missing.free()
		m.kid_sort.free()
		m.held.free()
		m.ignored.free()
	}
	return m
}

// fit cuts the arrays to the merged nodes made, releasing what is left over when that is more
// than a quarter: releasing means copying every array, and on a large set of documents that
// costs more time than a smaller surplus is worth in memory.
fn (mut m Merged) fit() {
	n := int(m.count)
	if n * 4 < m.name.len * 3 {
		m.name = m.name[..n].clone()
		m.parent = m.parent[..n].clone()
		m.scope = m.scope[..n].clone()
		m.rule = m.rule[..n].clone()
		m.kind = m.kind[..n].clone()
		m.key_lo = m.key_lo[..n + 1].clone()
		m.frag_lo = m.frag_lo[..n + 1].clone()
		m.kid_lo = m.kid_lo[..n + 1].clone()
	} else {
		m.name.trim(n)
		m.parent.trim(n)
		m.scope.trim(n)
		m.rule.trim(n)
		m.kind.trim(n)
		m.key_lo.trim(n + 1)
		m.frag_lo.trim(n + 1)
		m.kid_lo.trim(n + 1)
	}
	if m.nfrags * 4 < m.frags.len * 3 {
		m.frags = m.frags[..m.nfrags].clone()
	} else {
		m.frags.trim(m.nfrags)
	}
}

// name_of is the name id element i of d is merged by: its local name's when it is in the local
// namespace, its name as written otherwise.
@[inline]
fn (m &Merged) name_of(d &Doc, i u32) u32 {
	return d.name_in(i, m.rules.local)
}

// joins_root reports whether document d's root is merged into the root: of the root's name, and,
// with a local namespace, in it (a root of another namespace may share its local name).
fn (m &Merged) joins_root(d &Doc, root_tag u32) bool {
	if m.name_of(d, 1) != root_tag {
		return false
	}
	return m.rules.local == no_local || d.ns[1] == m.rules.local
}

// build makes the merged root, then the children of every merged node in turn.
fn (mut m Merged) build() {
	s := m.set
	// the root is the first document's, or with a local namespace the first document's in it:
	// a document of another namespace listed first does not decide what the others merge into
	mut first := 0
	if m.rules.local != no_local {
		first = -1
		for k, d in s.docs {
			if d.ns[1] == m.rules.local {
				first = k
				break
			}
		}
		if first < 0 {
			// refused by merge before build: no root is in the namespace
			panic('flatxml: build with no root in the local namespace')
		}
	}
	root_tag := m.name_of(s.docs[first], 1)
	mut at := [s.docs[first].root_node()]
	for k, d in s.docs {
		if k == first || m.joins_root(d, root_tag) {
			put(m.frags, m.nfrags, Frag{u32(k), 1})
			m.nfrags++
		} else {
			at << d.root_node()
		}
	}
	if at.len > 1 {
		m.problems << Problem{
			kind: .name_differs
			node: 0
			what: s.tab.name(root_tag)
			at:   at
		}
	}
	m.add_node(root_tag, no_mnode, 0, no_rule, .root, '')
	m.differs(0)
	for p := u32(0); p < m.count; p++ {
		put(m.kid_lo, int(p), m.count)
		m.expand(p)
	}
	put(m.kid_lo, int(m.count), m.count)
}

// parent_view is merged node p as a classifier may read it while the view is built.
fn (m &Merged) parent_view(p u32) Parent {
	mut frags := []Node{cap: int(m.frag_lo[p + 1] - m.frag_lo[p])}
	for f := m.frag_lo[p]; f < m.frag_lo[p + 1]; f++ {
		frags << m.frag_node(m.frags[f])
	}
	mut ancestors := []Ancestor{}
	for a := m.parent[p]; a != no_mnode; a = m.parent[a] {
		ancestors << Ancestor{m.set.tab.name(m.name[a]), m.key_of(a).clone()}
	}
	return Parent{
		name:      m.set.tab.name(m.name[p])
		key:       m.key_of(p).clone()
		fragments: frags
		ancestors: ancestors
	}
}

// add_node appends a merged node, whose contributions are frags[frag_lo[n] .. nfrags].
@[direct_array_access]
fn (mut m Merged) add_node(name u32, parent u32, scope u32, rule u32, kind MKind, key string) {
	n := int(m.count)
	put(m.name, n, name)
	put(m.parent, n, parent)
	put(m.scope, n, scope)
	put(m.rule, n, rule)
	put(m.kind, n, kind)
	if key.len > 0 {
		unsafe { m.key_buf.push_many(key.str, key.len) }
	}
	put(m.key_lo, n + 1, u32(m.key_buf.len))
	put(m.frag_lo, n + 1, u32(m.nfrags))
	m.count++
}

// expand makes the children of merged node p.
@[direct_array_access]
fn (mut m Merged) expand(p u32) {
	m.nkids, m.nouts, m.nout_frags = 0, 0, 0
	mut ctx := no_rule // the parent's context, found at its first child element
	mut sorted := true
	mut last_rule := u32(0)
	for f := m.frag_lo[p]; f < m.frag_lo[p + 1]; f++ {
		fr := m.frags[f]
		d := m.set.docs[fr.doc]
		stop := d.end[fr.i]
		mut c := fr.i + 1
		for c < stop {
			t := m.name_of(d, c)
			if t != text_tag {
				if ctx == no_rule {
					ctx = m.rules.context(m, p)
				}
				r := m.rules.resolve(ctx, t)
				sorted = sorted && r >= last_rule
				last_rule = r
				room(mut m.kids, m.nkids)
				put(m.kids, m.nkids, Kid{
					doc:  fr.doc
					i:    c
					tag:  t
					rule: r
					seq:  m.nkids
				})
				m.nkids++
			}
			c = d.end[c]
		}
	}
	if m.nkids == 0 {
		return
	}
	// by aggregation, in the order the rules are listed (none last), then as written
	if !sorted {
		m.kid_sort.clear()
		m.kid_sort << m.kids[..m.nkids]
		m.kid_sort.sort_with_compare(compare_kid_rule)
		for j, kid in m.kid_sort {
			put(m.kids, j, kid)
		}
	}
	mut k := 0
	for k < m.nkids {
		r := m.kids[k].rule
		mut e := k + 1
		for e < m.nkids && m.kids[e].rule == r {
			e++
		}
		if r == no_rule {
			for j in k .. e {
				m.out_one(j, no_rule, .each, '')
			}
		} else {
			m.aggregation(p, k, e)
		}
		k = e
	}
	// the children, each checked against the keys its scope already holds
	scope := if m.kind[p] == .single { m.scope[p] } else { p }
	for x in 0 .. m.nouts {
		o := m.outs[x]
		if o.kind == .keyed {
			if other := m.by_key.find(m, scope, 0, o.key) {
				mut at := m.node(other).fragments()
				for j in o.lo .. o.hi {
					at << m.frag_node(m.out_frags[j])
				}
				m.problems << Problem{
					kind: .key_reused
					node: p
					key:  o.key
					what: m.set.tab.name(o.name)
					at:   at
				}
				continue
			}
		}
		for j in o.lo .. o.hi {
			put(m.frags, m.nfrags, m.out_frags[j])
			m.nfrags++
		}
		n := m.count
		m.add_node(o.name, p, scope, o.rule, o.kind, o.key)
		if o.kind == .keyed {
			m.by_key.add(m, n)
		}
		if m.nouts > scan_children && (o.kind == .keyed || o.kind == .single) {
			m.by_name.add(m, n)
		}
		if o.hi - o.lo > 1 {
			m.differs(n)
		}
	}
}

// out_one makes kids[j] a child of its own.
fn (mut m Merged) out_one(j int, rule u32, kind MKind, key string) {
	kid := m.kids[j]
	m.add_out(Out{kid.tag, rule, kind, key, m.nout_frags, m.nout_frags + 1})
	m.add_out_frag(Frag{kid.doc, kid.i})
}

// aggregation puts together kids[k .. e], the children of p under one rule.
fn (mut m Merged) aggregation(p u32, k int, e_ int) {
	r := m.kids[k].rule
	rule := &m.rules.rules[r]
	mut e := e_
	if rule.ordered && rule.kind != .single {
		// every child from the first document they come from
		first := m.kids[k].doc
		mut kept := k
		mut dropped := []Node{}
		for j in k .. e {
			if m.kids[j].doc == first {
				put(m.kids, kept, m.kids[j])
				kept++
			} else {
				dropped << m.kid_node(j)
			}
		}
		if dropped.len > 0 {
			m.problems << Problem{
				kind: .ordered_split
				node: p
				what: m.set.tab.name(m.kids[k].tag)
				at:   first_then(m.kid_node(k), dropped)
			}
			e = kept
		}
	}
	match rule.kind {
		.each {
			e = m.limit(p, rule, k, e)
			for j in k .. e {
				m.out_one(j, r, .each, '')
			}
		}
		.single {
			if e - k == 1 {
				m.out_one(k, r, .single, '')
				return
			}
			// one child per name, in the order first written: the kids of each name together
			m.order.clear()
			for j in k .. e {
				m.order << j
			}
			m.group_names(0)
			for g in 0 .. m.starts.len {
				m.identity_of(p, rule, r, .single, '', m.starts[g], m.fill[g])
			}
		}
		.keyed {
			m.keyed(p, rule, r, k, e)
		}
	}
}

// group_names puts the kids listed in order[base ..] together by name, the names in the order
// first written and each name's kids as written: name g's are then order[starts[g] .. fill[g]].
fn (mut m Merged) group_names(base int) {
	m.group.clear()
	m.starts.clear()
	for x in base .. m.order.len {
		t := m.kids[m.order[x]].tag
		if t !in m.group {
			m.group[t] = m.starts.len
			m.starts << 0
		}
		m.starts[m.group[t]]++
	}
	mut at := base
	for g in 0 .. m.starts.len {
		n := m.starts[g]
		m.starts[g] = at
		at += n
	}
	m.fill.clear()
	m.fill << m.starts
	m.listed.clear()
	m.listed << m.order[base..]
	for j in m.listed {
		g := m.group[m.kids[j].tag]
		m.order[m.fill[g]] = j
		m.fill[g]++
	}
}

// keyed puts together kids[k .. e], the children of p under a keyed rule.
fn (mut m Merged) keyed(p u32, rule &CRule, r u32, k int, e int) {
	m.keys.clear()
	m.order.clear()
	m.runs.clear()
	m.missing.clear()
	// with keyless=empty, a key with no text is the empty key, as an absent one is
	empty_is_absent := rule.keyless == .empty
	for j in k .. e {
		if key := rule.key(m.kid_node(j), m.rules.local) {
			if !(empty_is_absent && empty_key(key)) {
				m.keys << key
				m.order << j
				continue
			}
		}
		m.keys << ''
		m.missing << j
	}
	fold := m.rules.fold
	keys := m.keys
	// by key, then as written; one run of equal keys is one identity
	if m.order.len > 1 {
		m.keyed_at.clear()
		for j in m.order {
			m.keyed_at << KeyAt{keys[j - k], j}
		}
		if fold {
			m.keyed_at.sort_with_compare(compare_key_at_fold)
		} else {
			m.keyed_at.sort_with_compare(compare_key_at)
		}
		for x, ka in m.keyed_at {
			m.order[x] = ka.j
		}
	}
	mut g := 0
	for g < m.order.len {
		mut h := g + 1
		for h < m.order.len && compare_keys(keys[m.order[g] - k], keys[m.order[h] - k], fold) == 0 {
			h++
		}
		m.runs << Run{
			lo:    g
			hi:    h
			first: m.order[g]
		}
		g = h
	}
	// with keyless=empty, the children of one name without a key are one, of the empty key
	if rule.keyless == .empty && m.missing.len > 0 {
		base := m.order.len
		m.order << m.missing
		m.group_names(base)
		for x in 0 .. m.starts.len {
			m.runs << Run{
				lo:    m.starts[x]
				hi:    m.fill[x]
				empty: true
				first: m.order[m.starts[x]]
			}
		}
		m.missing.clear()
	}
	order := m.order
	written := rule.ordered || m.rules.written
	if written {
		m.runs.sort_with_compare(compare_run_first)
	}
	for j in m.missing {
		if rule.keyless == .quiet {
			break
		}
		m.problems << Problem{
			kind: .missing_key
			node: p
			what: m.set.tab.name(m.kids[j].tag)
			at:   [m.kid_node(j)]
		}
	}
	// the most there may be, keyed or not, in the order they were written
	if rule.max > 0 && m.runs.len + m.missing.len > rule.max {
		mut firsts := m.runs.map(it.first)
		firsts << m.missing
		firsts.sort()
		cut := firsts[rule.max - 1]
		mut dropped := []Node{}
		for run in m.runs {
			if run.first > cut {
				for x in run.lo .. run.hi {
					dropped << m.kid_node(order[x])
				}
			}
		}
		for j in m.missing {
			if j > cut {
				dropped << m.kid_node(j)
			}
		}
		m.problems << Problem{
			kind: .too_many
			node: p
			what: m.set.tab.name(m.kids[k].tag)
			at:   dropped
		}
		m.runs = m.runs.filter(it.first <= cut)
		// the children without a key within the cut, kept in place
		mut w := 0
		for j in m.missing {
			if j <= cut {
				m.missing[w] = j
				w++
			}
		}
		m.missing.trim(w)
	}
	// children without a key after the others, or where they were written when order matters
	mut x := 0
	for run in m.runs {
		for written && x < m.missing.len && m.missing[x] < run.first {
			m.out_one(m.missing[x], r, .each, '')
			x++
		}
		if run.empty {
			m.identity_of(p, rule, r, .single, '', run.lo, run.hi)
		} else {
			m.identity_of(p, rule, r, .keyed, keys[run.first - k], run.lo, run.hi)
		}
	}
	for x < m.missing.len {
		m.out_one(m.missing[x], r, .each, '')
		x++
	}
}

// identity_of makes the kids order[lo .. hi], in the order written and all of one identity, one
// child: those of the first one's name, all of them where the rule merges and the first
// otherwise.
fn (mut m Merged) identity_of(p u32, rule &CRule, r u32, kind MKind, key string, lo int, hi int) {
	first := m.kids[m.order[lo]]
	flo := m.nout_frags
	m.add_out_frag(Frag{first.doc, first.i})
	mut other_name := []Node{}
	mut again := []Node{}
	for x in lo + 1 .. hi {
		j := m.order[x]
		kid := m.kids[j]
		if kid.tag != first.tag {
			other_name << m.kid_node(j)
		} else if rule.merge {
			m.add_out_frag(Frag{kid.doc, kid.i})
		} else {
			again << m.kid_node(j)
		}
	}
	if other_name.len > 0 {
		m.problems << Problem{
			kind: .name_differs
			node: p
			key:  key
			what: m.set.tab.name(first.tag)
			at:   first_then(m.kid_node(m.order[lo]), other_name)
		}
	}
	if again.len > 0 {
		m.problems << Problem{
			kind: .collision
			node: p
			key:  key
			what: m.set.tab.name(first.tag)
			at:   first_then(m.kid_node(m.order[lo]), again)
		}
	}
	m.add_out(Out{first.tag, r, kind, key, flo, m.nout_frags})
}

fn (mut m Merged) add_out(o Out) {
	room(mut m.outs, m.nouts)
	put(m.outs, m.nouts, o)
	m.nouts++
}

fn (mut m Merged) add_out_frag(f Frag) {
	room(mut m.out_frags, m.nout_frags)
	put(m.out_frags, m.nout_frags, f)
	m.nout_frags++
}

// put writes a[i], which must exist. (An index assignment checks the bounds again, out of line.)
@[inline]
fn put[T](a []T, i int, v T) {
	unsafe {
		mut p := &T(a.data)
		p[i] = v
	}
}

// room makes a[i] exist, growing a by half at least.
@[inline]
fn room[T](mut a []T, i int) {
	if i >= a.len {
		a << []T{len: a.len / 2 + 16}
	}
}

// limit keeps the first rule.max of kids[k .. e] and reports the rest; the new end.
fn (mut m Merged) limit(p u32, rule &CRule, k int, e int) int {
	if rule.max == 0 || e - k <= rule.max {
		return e
	}
	m.problems << Problem{
		kind: .too_many
		node: p
		what: m.set.tab.name(m.kids[k].tag)
		at:   []Node{len: e - k - rule.max, init: m.kid_node(k + rule.max + index)}
	}
	return k + rule.max
}

// differs reports where the contributions to node n disagree with its first: their own text,
// run by run in its place among the children (`Node.text_runs`), and where text is mixed with
// elements, all the text inside them, which the view does not merge child by child; or the
// value of an attribute, against the first contribution that has it (unless the rules ignore it).
fn (mut m Merged) differs(n u32) {
	lo, hi := m.frag_lo[n], m.frag_lo[n + 1]
	if hi - lo < 2 {
		return
	}
	f0 := m.frags[lo]
	d0 := m.set.docs[f0.doc]
	n0 := Node{d0, f0.i}
	mixed0 := d0.has_text_children(f0.i)
	// the first fragment's text runs, read once a fragment with text mixed among elements needs
	// them: otherwise the text is the one run, and comparing the texts needs no list of runs
	mut t0 := []TextRun{}
	mut t0_read := false
	// and its whole text, read once a comparison gets that far
	mut s0 := ''
	mut s0_read := false
	a_lo, a_hi := d0.attr_range(f0.i)
	// an attribute any contribution spells by an ignored name is ignored in all of them: the
	// identities of the ignored spellings, collected before anything is compared
	// (one map kept between nodes, not a map per node)
	m.ignored.clear()
	if m.rules.ignore.len > 0 {
		for x_f in lo .. hi {
			f := m.frags[x_f]
			d := m.set.docs[f.doc]
			x_lo, x_hi := d.attr_range(f.i)
			for x := x_lo; x < x_hi; x++ {
				if d.attr_tag[x] in m.rules.ignore || d.attr_id(x) in m.rules.ignore {
					m.ignored[d.attr_id(x)] = true
				}
			}
		}
	}
	m.held.clear()
	for a := a_lo; a < a_hi; a++ {
		m.held << Held{d0, f0.i, a}
	}
	for f in m.frags[lo + 1..hi] {
		d := m.set.docs[f.doc]
		nf := Node{d, f.i}
		mixed := mixed0 || d.has_text_children(f.i)
		if mixed && !t0_read {
			t0 = n0.text_runs()
			t0_read = true
		}
		mut differ := mixed && nf.text_runs() != t0
		if !differ {
			if !s0_read {
				s0 = n0.text()
				s0_read = true
			}
			differ = nf.text() != s0
		}
		if differ {
			m.problems << Problem{
				kind: .value_differs
				node: n
				key:  m.key_of(n).clone()
				what: m.set.tab.name(m.name[n]) // the merge's name, not the first file's spelling
				at:   [Node{d0, f0.i}, Node{d, f.i}]
			}
		}
		b_lo, b_hi := d.attr_range(f.i)
		for b := b_lo; b < b_hi; b++ {
			if d.attr_tag[b] in m.rules.ignore || d.attr_id(b) in m.ignored {
				continue
			}
			// the first fragment that has this attribute, which a later one is compared with: the
			// first fragment, or the earlier fragment that brought it
			mut found := false
			for h in m.held {
				if !same_attr(h.doc, h.a, d, b) {
					continue
				}
				found = true
				if h.doc.attr_tag[h.a] in m.rules.ignore || h.doc.attr_id(h.a) in m.ignored {
					break
				}
				if h.doc.attr_value(h.a) != d.attr_value(b) {
					m.problems << Problem{
						kind: .value_differs
						node: n
						key:  m.key_of(n).clone()
						what: '@${d.tab.name(d.attr_id(b))}'
						at:   [Node{h.doc, h.i}, Node{d, f.i}]
					}
				}
				break
			}
			if !found {
				m.held << Held{d, f.i, b}
			}
		}
	}
}

// compare_kid_rule orders children by aggregation, in the order the rules are listed (none
// last), then as written.
fn compare_kid_rule(a &Kid, b &Kid) int {
	if a.rule != b.rule {
		return if a.rule < b.rule { -1 } else { 1 }
	}
	return a.seq - b.seq
}

// Held is an attribute of a merged node's fragment, the first to give it.
struct Held {
	doc &Doc
	i   u32 // the element
	a   u32 // the attribute
}

// same_attr reports whether attribute a of d0 and b of d are one attribute: by expanded name when
// the documents are resolved, by name as written when they are not (a merge takes all or none).
fn same_attr(d0 &Doc, a u32, d &Doc, b u32) bool {
	if d0.attr_ns.len == d0.attr_tag.len && d.attr_ns.len == d.attr_tag.len {
		return d0.attr_id(a) == d.attr_id(b)
	}
	return d0.attr_tag[a] == d.attr_tag[b]
}

// key_of is the key of node n: a view of key_buf, which does not change once the view is built.
@[inline]
fn (m &Merged) key_of(n u32) string {
	lo := m.key_lo[n]
	len := int(m.key_lo[n + 1] - lo)
	return if len == 0 { '' } else { unsafe { tos(&u8(m.key_buf.data) + lo, len) } }
}

fn first_then(first Node, rest []Node) []Node {
	mut out := []Node{cap: rest.len + 1}
	out << first
	out << rest
	return out
}

fn (m &Merged) frag_node(f Frag) Node {
	return Node{m.set.docs[f.doc], f.i}
}

fn (m &Merged) kid_node(j int) Node {
	kid := m.kids[j]
	return Node{m.set.docs[kid.doc], kid.i}
}

// --- keys ------------------------------------------------------------------------------------

@[inline]
fn lower(c u8) u8 {
	return if c >= `A` && c <= `Z` { c + 32 } else { c }
}

// compare_keys orders two keys by their bytes, or by their bytes in lower case.
fn compare_keys(a string, b string, fold bool) int {
	n := if a.len < b.len { a.len } else { b.len }
	for i in 0 .. n {
		x := if fold { lower(a[i]) } else { a[i] }
		y := if fold { lower(b[i]) } else { b[i] }
		if x != y {
			return if x < y { -1 } else { 1 }
		}
	}
	return a.len - b.len
}

// key_hash is a hash of (a, b, key), the key in lower case when fold.
fn key_hash(a u32, b u32, key string, fold bool) u64 {
	seed := name_seed ^ ((u64(a) << 32) | b)
	if fold {
		for i in 0 .. key.len {
			if key[i] >= `A` && key[i] <= `Z` {
				return lower_hash(key, seed)
			}
		}
	}
	return hash.wyhash_c(key.str, u64(key.len), seed)
}

fn lower_hash(key string, seed u64) u64 {
	mut buf := [256]u8{}
	if key.len > buf.len {
		low := key.to_lower_ascii()
		return hash.wyhash_c(low.str, u64(low.len), seed)
	}
	for i in 0 .. key.len {
		buf[i] = lower(key[i])
	}
	return hash.wyhash_c(&buf[0], u64(key.len), seed)
}

// KeyIndex finds a merged node by (parent, name, key), or by (scope, key).
struct KeyIndex {
	by_parent bool
mut:
	slots []u32 // node + 1; 0 for an empty slot
	count int
}

// reserve sizes the table for n nodes.
fn (mut ix KeyIndex) reserve(n int) {
	mut size := 1024
	for size < n * 2 {
		size *= 2
	}
	ix.slots = []u32{len: size}
}

@[inline]
fn (ix &KeyIndex) hash_of(m &Merged, n u32) u64 {
	return if ix.by_parent {
		key_hash(m.parent[n], m.name[n], m.key_of(n), m.rules.fold)
	} else {
		key_hash(m.scope[n], 0, m.key_of(n), m.rules.fold)
	}
}

@[direct_array_access]
fn (mut ix KeyIndex) add(m &Merged, n u32) {
	if (ix.count + 1) * 2 > ix.slots.len {
		ix.grow(m)
	}
	mask := u64(ix.slots.len - 1)
	mut k := ix.hash_of(m, n) & mask
	for ix.slots[k] != 0 {
		k = (k + 1) & mask
	}
	ix.slots[k] = n + 1
	ix.count++
}

fn (mut ix KeyIndex) grow(m &Merged) {
	old := ix.slots
	ix.slots = []u32{len: old.len * 2}
	mask := u64(ix.slots.len - 1)
	for s in old {
		if s != 0 {
			mut k := ix.hash_of(m, s - 1) & mask
			for ix.slots[k] != 0 {
				k = (k + 1) & mask
			}
			ix.slots[k] = s
		}
	}
}

// find is the node with (a, b, key): a parent and a name id, or a scope and 0.
@[direct_array_access]
fn (ix &KeyIndex) find(m &Merged, a u32, b u32, key string) ?u32 {
	if ix.slots.len == 0 {
		return none
	}
	fold := m.rules.fold
	mask := u64(ix.slots.len - 1)
	mut k := key_hash(a, b, key, fold) & mask
	for {
		s := ix.slots[k]
		if s == 0 {
			return none
		}
		n := s - 1
		same := if ix.by_parent {
			m.parent[n] == a && m.name[n] == b
		} else {
			m.scope[n] == a
		}
		if same && m.key_of(n).len == key.len && compare_keys(m.key_of(n), key, fold) == 0 {
			return n
		}
		k = (k + 1) & mask
	}
	return none
}

// --- reading the view --------------------------------------------------------------------------

// MNode is a handle on a merged node. Like Node, a missing one is a valid empty handle.
pub struct MNode {
pub:
	m &Merged = unsafe { nil }
	i u32     = no_mnode // no_mnode for an empty handle
}

// len is the number of merged nodes.
pub fn (m &Merged) len() int {
	return int(m.count)
}

// fragment_total is the number of contributions, over every merged node.
pub fn (m &Merged) fragment_total() int {
	return m.frags.len
}

// root is the merged root.
pub fn (m &Merged) root() MNode {
	return MNode{m, if m.name.len == 0 { no_mnode } else { 0 }}
}

// node is a handle on merged node i.
pub fn (m &Merged) node(i u32) MNode {
	return MNode{m, i}
}

// by_keys is the node at a key path: the keys of its keyed ancestors from the root, then its
// own. Children of a single node are reached through it, so the path skips it.
pub fn (m &Merged) by_keys(keys []string) MNode {
	if m.name.len == 0 {
		return MNode{m, no_mnode}
	}
	mut cur := u32(0)
	for k in keys {
		cur = m.by_key.find(m, cur, 0, k) or { return MNode{m, no_mnode} }
	}
	return MNode{m, cur}
}

// at_path is by_keys with the path written `/a/b`: for keys that hold no `/`.
pub fn (m &Merged) at_path(path string) MNode {
	return m.by_keys(path.split('/').filter(it != ''))
}

// pos is `path:line:column` of a node of the set (each document indexes its lines once).
pub fn (m &Merged) pos(n Node) string {
	return n.pos()
}

// describe is a problem in one line, with every position.
pub fn (mut m Merged) describe(p Problem) string {
	what := match p.kind {
		.collision { '${p.what} `${show_key(p.key)}` more than once, and the rule does not merge' }
		.key_reused { '${p.what} `${show_key(p.key)}`: the key is used in its scope already' }
		.ordered_split { 'ordered ${p.what} in more than one document' }
		.too_many { '${p.what}: more than the rule allows' }
		.value_differs {
			'${p.what} differs' + if p.key != '' { ' in `${show_key(p.key)}`' } else { '' }
		}
		.name_differs {
			if p.at[0].i == 1 {
				'roots named differently (${p.what} first)'
			} else {
				'`${show_key(p.key)}` under two names (${p.what} first)'
			}
		}
		.missing_key { '${p.what} without its key' }
	}
	mut at := []string{cap: p.at.len}
	for n in p.at {
		at << m.pos(n)
	}
	return '${p.kind}: ${what}: ${at.join(', ')}'
}

@[inline]
pub fn (n MNode) ok() bool {
	return n.i != no_mnode
}

// tag is the name id; text_tag for none.
pub fn (n MNode) tag() u32 {
	return if n.i == no_mnode { text_tag } else { n.m.name[n.i] }
}

// name is the element name; '' for none.
pub fn (n MNode) name() string {
	return if n.i == no_mnode { '' } else { n.m.set.tab.name(n.m.name[n.i]) }
}

// local_name is the node's name without its prefix, read from the name alone (no namespace is
// consulted: a foreign `ext:x` is `x` too); '' for none. What the merge names the node by is
// `name()` / `tag()`.
pub fn (n MNode) local_name() string {
	return if n.i == no_mnode { '' } else { local_part(n.name()) }
}

// key is the key that identifies the node, as its first contribution has it; '' for a node
// with no key.
pub fn (n MNode) key() string {
	return if n.i == no_mnode { '' } else { n.m.key_of(n.i) }
}

// rule is the rule, of the rule set the view was merged by, that put the node together with its
// siblings: its aggregation's rule. None for the root, for a child no rule names, and for an
// empty handle. A child of a keyed rule that has no key (one missing its key, a child of its own)
// still has the rule: `keyed` tells it from its keyed siblings.
pub fn (n MNode) rule() ?Rule {
	k := n.rule_number()?
	return n.m.source[k]
}

// rule_number is the number of `rule` in the rule set the view was merged by, from 0: the index
// into `RuleSet.rules` (problems name rule k as `rule k+1`). None where `rule` is.
pub fn (n MNode) rule_number() ?int {
	if n.i == no_mnode || n.m.rule[n.i] == no_rule {
		return none
	}
	return int(n.m.rule[n.i])
}

// keyed reports whether the node is identified by a key.
pub fn (n MNode) keyed() bool {
	return n.i != no_mnode && n.m.kind[n.i] == .keyed
}

// key_path is the keys from the root to the node (see `by_keys`); empty for a node a key path
// does not reach: one below a node of its own (each, or missing its key).
pub fn (n MNode) key_path() []string {
	if n.i == no_mnode {
		return []
	}
	mut out := []string{}
	mut c := n.i
	for c != 0 {
		match n.m.kind[c] {
			.keyed { out << n.m.key_of(c) }
			.each { return [] }
			else {}
		}
		c = n.m.parent[c]
	}
	out.reverse_in_place()
	return out
}

// parent is the merged parent; empty for the root.
pub fn (n MNode) parent() MNode {
	return MNode{n.m, if n.i == no_mnode { no_mnode } else { n.m.parent[n.i] }}
}

// child is the child named name with key (with '' for a single child): named as the merge names
// it, so with a local namespace one of its elements by its local name.
pub fn (n MNode) child(name string, key string) MNode {
	if n.i == no_mnode {
		return n
	}
	id := n.m.set.tab.id(name) or { return MNode{n.m, no_mnode} }
	return n.child_id(id, key)
}

// child_id is child by name id.
pub fn (n MNode) child_id(tag u32, key string) MNode {
	if n.i == no_mnode {
		return n
	}
	m := n.m
	lo, hi := m.kid_lo[n.i], m.kid_lo[n.i + 1]
	if hi - lo > scan_children {
		return MNode{m, m.by_name.find(m, n.i, tag, key) or { no_mnode }}
	}
	for c := lo; c < hi; c++ {
		if m.name[c] == tag && m.kind[c] in [.keyed, .single]
			&& compare_keys(m.key_of(c), key, m.rules.fold) == 0 {
			return MNode{m, c}
		}
	}
	return MNode{m, no_mnode}
}

// child_count is the number of children.
pub fn (n MNode) child_count() int {
	return if n.i == no_mnode { 0 } else { int(n.m.kid_lo[n.i + 1] - n.m.kid_lo[n.i]) }
}

// children are the merged children, in order: `for c in n.children() { ... }`.
pub fn (n MNode) children() MChildren {
	if n.i == no_mnode {
		return MChildren{
			m: n.m
		}
	}
	return MChildren{
		m:    n.m
		cur:  n.m.kid_lo[n.i]
		stop: n.m.kid_lo[n.i + 1]
	}
}

// MChildren iterates over the children of a merged node: a range of indexes.
pub struct MChildren {
	m    &Merged = unsafe { nil }
	stop u32
mut:
	cur u32
}

pub fn (mut it MChildren) next() ?MNode {
	if it.cur >= it.stop {
		return none
	}
	it.cur++
	return MNode{it.m, it.cur - 1}
}

// fragment_count is the number of contributions: nodes of the set that are this one.
pub fn (n MNode) fragment_count() int {
	return if n.i == no_mnode { 0 } else { int(n.m.frag_lo[n.i + 1] - n.m.frag_lo[n.i]) }
}

// fragment is contribution k, in the set's order, then document order.
pub fn (n MNode) fragment(k int) Node {
	if n.i == no_mnode || k < 0 || k >= n.fragment_count() {
		return Node{}
	}
	return n.m.frag_node(n.m.frags[n.m.frag_lo[n.i] + u32(k)])
}

// fragments are the contributions.
pub fn (n MNode) fragments() []Node {
	return []Node{len: n.fragment_count(), init: n.fragment(index)}
}

// text is the text of the first contribution, all of it where text is mixed with elements.
pub fn (n MNode) text() string {
	return n.fragment(0).text()
}

// text_runs are the own text of the first contribution, run by run (`Node.text_runs`).
pub fn (n MNode) text_runs() []TextRun {
	return n.fragment(0).text_runs()
}

// attr is the attribute name of the first contribution that has it; '' for none.
pub fn (n MNode) attr(name string) string {
	for k in 0 .. n.fragment_count() {
		f := n.fragment(k)
		if f.has_attr(name) {
			return f.attr(name)
		}
	}
	return ''
}

// pos is the position of the first contribution.
pub fn (n MNode) pos() string {
	return n.fragment(0).pos()
}
