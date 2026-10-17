module arxmodel

import flatxml
import flatxml.xsd
import time

// The schema's rules as flatxml's. flatxml names an aggregation by its parent's and its
// children's element names; the schema by the parent's type and the role. So each rule here
// becomes flatxml rules per element name its holding type is declared with:
//
// - A role element that wraps its items is a single child of its holder, merged across
//   fragments, and the items are the wrapper's children: keyed by the split key (merged when
//   the role is splittable), else one child each. Item kinds of one rule are one flatxml rule
//   with several children, so ordered and the most hold across them.
// - A role element that is itself the item is keyed or one child each in the same way.
// - A role of one item (its most 1) is a single, merged child, whatever its key and its
//   splittability: its element is in every fragment of the object that holds it (a SHORT-NAME,
//   a VARIATION-POINT), and two fragments that disagree are reported as differing values.
// - A wrapper holding its items' content holds that content one child each, at most its most
//   items times as often as an item holds each.
// - A split key with a part that did not resolve is not used: one child each (the part is
//   reported by the rules already).
// - Keys are flatxml key paths: '' for the item's own text, `@NAME` for an attribute, a final `+`
//   for a part whose element repeats (every occurrence, in order). An item whose parts are all
//   absent has the empty key (`keyless: .empty`), which every such item of the aggregation
//   shares, so their fragments merge and what differs is reported.
//
// One element pair can be given different rules by roles of different holder types (a
// CONTAINERS keyed under one class and not under another). Where that happens, a holder whose rule
// differs from the pair's first gets its role's rules (every item kind of it together) under a
// parent path: `ECUC-MODULE-DEF/CONTAINERS` for a wrapper's items, `PARENT/HOLDER` for a role
// written in its holder, PARENT being an element whose content holds the holder's type. Each such
// rule is listed where its unscoped counterpart is, so the order of a node's aggregations is the
// schema's. A path that still names holders with different rules, or a holder no path can name
// (the root), is a conflict: one rule is applied, and the view's problems on it are marked as the
// conflict's, not as violations.

// Flat is the flatxml rule set made from a schema's rules, and what could not be said in it.
pub struct Flat {
pub mut:
	rules     flatxml.RuleSet
	described []string // per rule, what it says (`key=SHORT-NAME merge`), its key included
	// element pairs roles of different holders give different rules, each holder given its own
	// rule by a parent path where it differs from the pair's first
	scoped []string
	// paths that still name holders with different rules, or holders no path names; whether the
	// documents use each is `place`'s
	conflicts []Conflict
	// rules whose items have no element of their own (flat wrappers)
	flat_wrappers int
	// item kinds whose split key lost a part, so they are one child each
	lost_keys int
	// an element without a key is matched by its place, by design (the built-in identity rules):
	// not a missing key
	unkeyed_by_design bool
	// roles whose items are identified by a definition (the policy's item_identity)
	identity_roles []IdentityRole
	// such roles whose items have no wrapper: keyed by the identity as their split key (values)
	direct_identities []IdentityRole
	// rules of non-splittable roles allowed in several fragments only as identical repetitions
	repeat_rules []int
	// elements whose content a merge does not compare (structured comments, by the policy)
	ignored_content []string
	// the built-in identity rules the Flat was made of, which name values by their definition
	// (values); nil for a schema's rules
	identified &Identified = unsafe { nil }
}

// Conflict is an element pair under a parent path that roles of different holders still give
// different rules.
pub struct Conflict {
pub:
	parent string // a parent path, `HOLDER/WRAPPER`, or the parent's name where no path names it
	child  string
	rules  []string // `role: rule`, the one applied first
pub mut:
	occurs int // occurrences of the pair under that parent in the documents placed
}

// pair is the conflict's element pair, `parent child`, and what is above the parent: the name its
// path names, '' for the document's root (`/ROOT`), or none for a parent named alone.
fn (c Conflict) pair() (string, ?string) {
	if c.parent.contains('/') {
		return '${c.parent.all_after_last('/')} ${c.child}', c.parent.all_before_last('/')
	}
	return '${c.parent} ${c.child}', none
}

// used is the conflicts the documents placed use.
pub fn (f &Flat) used() []Conflict {
	return f.conflicts.filter(it.occurs > 0)
}

// unused is the conflicts the documents placed do not use.
pub fn (f &Flat) unused() []Conflict {
	return f.conflicts.filter(it.occurs == 0)
}

// place counts, for each conflict, its occurrences in m's documents: under the name its path
// names, or anywhere for one without a path.
pub fn (mut f Flat) place(m &Model) {
	mut pairs := []string{}
	for c in f.conflicts {
		pair, _ := c.pair()
		if pair !in pairs {
			pairs << pair
		}
	}
	contexts := contexts_of(m, pairs, naming(f.rules.local_ns, [m]))
	for mut c in f.conflicts {
		pair, above := c.pair()
		seen := (contexts[pair] or { map[string]int{} }).clone()
		if a := above {
			c.occurs = seen[a] or { 0 }
		} else {
			mut n := 0
			for _, k in seen {
				n += k
			}
			c.occurs = n
		}
	}
}

@[params]
pub struct FlatOptions {
pub:
	// what a keyed rule makes of an item whose key parts are all absent (the policy's)
	keyless flatxml.Keyless = default_policy().absent_keys
}

// Spec is one flatxml rule before it is made.
struct Spec {
	single  bool
	merge   bool
	ordered bool
	max     int
	keyed   bool
	key     []string // flatxml key paths: '' for the item's own text, a final `+` for every occurrence
	// a non-splittable multi-valued role, allowed in several fragments only as an identical
	// repetition (the policy's repeated_content): its items merged, unkeyed ones by content
	repeat bool
}

fn (a Spec) same(b Spec) bool {
	return a.single == b.single && a.merge == b.merge && a.ordered == b.ordered && a.max == b.max
		&& a.keyed == b.keyed && a.key == b.key && a.repeat == b.repeat
}

fn (s Spec) str() string {
	mut out := []string{}
	if s.keyed {
		out << 'key=' + s.key.map(if it == '' { '.' } else { it }).join(',')
	} else if s.single {
		out << 'single'
	} else {
		out << 'each'
	}
	if s.merge {
		out << 'merge'
	}
	if s.ordered {
		out << 'ordered'
	}
	if s.repeat {
		out << 'repeat'
	}
	if s.max > 0 {
		out << 'max=${s.max}'
	}
	return out.join(' ')
}

// Cand is one rule's flatxml rule for an element pair, and the names of the elements above the
// pair's parent where it is the rule: the holders for a wrapper's items, the parents of the
// holder's type for a role written in its holder ('' for the root, which has none).
struct Cand {
	parent string
	child  string
	spec   Spec
	rule   int // index of the rule in the rule set
mut:
	above []string
	types []string // `type name` of the holders, for a role written in its holder
}

fn flat_path(k KeyPath) string {
	p := k.steps.join('/')
	return if k.all { p + '+' } else { p }
}

const single_merge = Spec{
	single: true
	merge:  true
}

fn flat_max(n u32) int {
	return if n == unbounded || n > u32(max_i32) { 0 } else { int(n) }
}

fn (rs &RuleSet) item_spec(r &Rule, it Item) Spec {
	if r.max <= 1 {
		return single_merge
	}
	// a non-splittable role repeated in fragments must repeat identically: its items merge
	repeat := !r.splittable && rs.policy.repeated_content == .identical
	if r.copied {
		return Spec{
			ordered: r.ordered
			max:     flat_max(r.max)
			merge:   repeat
			repeat:  repeat
		}
	}
	if r.key_spec.len > 0 && !it.key_lost && it.key.len == 0 {
		// nothing tells the items apart: one key for all, merged only where the role is
		// splittable (one child of the name; a second is a collision otherwise)
		return Spec{
			single: true
			merge:  r.splittable
		}
	}
	if r.key_spec.len > 0 && !it.key_lost {
		return Spec{
			keyed:   true
			merge:   r.splittable || repeat
			ordered: r.ordered
			max:     flat_max(r.max)
			key:     it.key.map(flat_path(it))
			repeat:  repeat
		}
	}
	return Spec{
		ordered: r.ordered
		max:     flat_max(r.max)
		merge:   repeat
		repeat:  repeat
	}
}

// names_of is, per complex type, the element names declared with it.
fn (rs &RuleSet) names_of() map[u32][]string {
	mut out := map[u32][]string{}
	for name, types in rs.types_of {
		for t in types {
			mut list := (out[t] or { []string{} }).clone()
			list << name
			out[t] = list
		}
	}
	return out
}

// Cands is every rule's flatxml rules, in the schema's order, and per element pair the
// candidates for it.
struct Cands {
mut:
	list      []Cand
	at        map[string]int   // `rule parent child` -> index in list
	by_pair   map[string][]int // `parent child` -> indices in list
	pairs     []string         // in the order first met
	by_parent map[string][]int // a pair's parent -> indices in list
	flats     int
	lost_keys int
}

// add adds a rule's flatxml rule for a pair; one rule reached through several holder names is
// one candidate.
fn (mut c Cands) add(parent string, child string, spec Spec, rule int, above []string, types []string) {
	key := '${rule} ${parent} ${child}'
	if k := c.at[key] {
		for a in above {
			if a !in c.list[k].above {
				c.list[k].above << a
			}
		}
		for t in types {
			if t !in c.list[k].types {
				c.list[k].types << t
			}
		}
		return
	}
	k := c.list.len
	c.at[key] = k
	c.list << Cand{parent, child, spec, rule, above.clone(), types.clone()}
	mut bp := (c.by_parent[parent] or { []int{} }).clone()
	bp << k
	c.by_parent[parent] = bp
	pair := '${parent} ${child}'
	if pair !in c.by_pair {
		c.pairs << pair
		c.by_pair[pair] = [k]
	} else {
		mut l := c.by_pair[pair].clone()
		l << k
		c.by_pair[pair] = l
	}
}

fn (rs &RuleSet) candidates() Cands {
	names := rs.names_of()
	mut c := Cands{}
	// the anonymous types of wrappers holding their items' content: the roles in them repeat
	// once per item, so the wrapper's rule, not theirs, says how they go together
	mut flat_types := map[u32]bool{}
	for r in rs.rules {
		if r.flat {
			flat_types[rs.schema.elements[r.decl].typ.idx] = true
		}
	}
	for k, r in rs.rules {
		mut holders := []string{}
		for ct in r.held_by {
			if ct in flat_types {
				continue
			}
			for h in names[ct] or { []string{} } {
				if h !in holders {
					holders << h
				}
				sp := if r.wrapper { single_merge } else { rs.item_spec(&r, r.items[0]) }
				// what tells a holder of this type from one of another type with its name: the
				// elements above it, found where a pair needs them
				c.add(h, r.element, sp, k, [], ['${ct} ${h}'])
			}
		}
		if r.flat {
			c.flats++
			per_item := rs.per_item(r.decl)
			for it in r.items {
				c.add(r.element, it.element, Spec{
					ordered: r.ordered
					max:     flat_max(sat_mul(r.max, per_item[it.decl] or { unbounded }))
				}, k, holders, [])
			}
		} else if r.wrapper {
			for it in r.items {
				if it.key_lost {
					c.lost_keys++
				}
				c.add(r.element, it.element, rs.item_spec(&r, it), k, holders, [])
			}
		}
	}
	return c
}

// fill_above gives the candidates of the pairs named the elements above their holders: the
// names of the elements whose content holds an element of the holder's name and type. The
// content models are walked once, and only the holders those candidates name are looked for.
fn (rs &RuleSet) fill_above(mut c Cands, pairs []string, names map[u32][]string) {
	mut want := map[string][]string{}
	for pair in pairs {
		for k in c.by_pair[pair] {
			for t in c.list[k].types {
				want[t] = []string{}
			}
		}
	}
	if want.len == 0 {
		return
	}
	s := rs.schema
	mut seen := map[string]bool{}
	for t, ct in s.complex_types {
		if ct.particle == xsd.no_particle {
			continue
		}
		mut occ := []Occ{}
		rs.walk(ct.particle, 1, mut occ)
		for o in occ {
			e := s.elements[o.decl]
			if e.typ.kind != .complex {
				continue
			}
			key := '${e.typ.idx} ${s.names[e.name.local]}'
			if key !in want {
				continue
			}
			for p in names[u32(t)] or { []string{} } {
				if '${key}\t${p}' !in seen {
					seen['${key}\t${p}'] = true
					want[key] << p
				}
			}
		}
	}
	for d in s.global_elements() {
		e := s.elements[d]
		key := '${e.typ.idx} ${s.names[e.name.local]}'
		if e.typ.kind == .complex && key in want {
			want[key] << ''
		}
	}
	for pair in pairs {
		for k in c.by_pair[pair] {
			for t in c.list[k].types {
				for a in want[t] or { []string{} } {
					if a !in c.list[k].above {
						c.list[k].above << a
					}
				}
			}
		}
	}
}

// per_item is, for a wrapper holding its items' content, how often one item holds each element.
fn (rs &RuleSet) per_item(d u32) map[u32]u32 {
	p := rs.content_particle(d) or { return map[u32]u32{} }
	kids := rs.schema.particle_children(p)
	mut occ := []Occ{}
	if kids.len == 1 && rs.schema.particles[kids[0]].kind != .element {
		// one item is one occurrence of the group inside the wrapper's repetition
		for k in rs.schema.particle_children(kids[0]) {
			rs.walk(k, 1, mut occ)
		}
	} else {
		// no group marks out an item: how often one holds an element is not known
		rs.walk(p, 1, mut occ)
		occ = occ.map(Occ{it.decl, unbounded})
	}
	mut out := map[u32]u32{}
	for o in occ {
		out[o.decl] = o.max
	}
	return out
}

// contexts_of counts, for each of the pairs given, the names of the elements above the parent
// where the pair occurs in m's documents, every element named as the merge names it.
pub fn contexts_of(m &Model, pairs []string, nm Naming) map[string]map[string]int {
	tab := m.set.tab
	// the pairs as name ids: a child's id says whether to look at all
	mut wanted := map[u64]int{}
	mut is_child := []bool{len: tab.len()}
	for k, pair in pairs {
		pid := tab.id(pair.all_before(' ')) or { continue }
		cid := tab.id(pair.all_after(' ')) or { continue }
		wanted[u64(pid) << 32 | cid] = k
		is_child[cid] = true
	}
	mut counts := map[u64]int{} // (pair, name id above) -> occurrences
	for d in m.set.docs {
		for i in 2 .. d.len() {
			t := nm.tag(d, i)
			if int(t) >= is_child.len || !is_child[t] {
				continue
			}
			p := d.parent[i]
			k := wanted[u64(nm.tag(d, p)) << 32 | t] or { continue }
			g := d.parent[p]
			counts[u64(k) << 32 | (if g == 0 { u32(0) } else { nm.tag(d, g) })]++
		}
	}
	mut out := map[string]map[string]int{}
	for key, n in counts {
		pair := pairs[int(key >> 32)]
		g := u32(key & 0xFFFF_FFFF)
		mut cnt := (out[pair] or { map[string]int{} }).clone()
		cnt[if g == 0 { '' } else { tab.name(g) }] = n
		out[pair] = cnt
	}
	return out
}

fn (rs &RuleSet) describe(c Cands, ks []int) []string {
	return ks.map('${rs.rules[c.list[it].rule].name}: ${c.list[it].spec}')
}

// to_flat turns the rules into flatxml's.
pub fn (rs &RuleSet) to_flat(opts FlatOptions) Flat {
	mut c := rs.candidates()
	mut f := Flat{
		flat_wrappers:     c.flats
		lost_keys:         c.lost_keys
		identity_roles:    rs.identity_roles()
		direct_identities: rs.direct_identity_roles()
	}
	if rs.policy.ignore_structured {
		f.ignored_content = rs.structured_elements()
	}
	// the pairs roles give different rules
	for pair in c.pairs {
		ks := c.by_pair[pair]
		first := c.list[ks[0]].spec
		if ks.any(!c.list[it].spec.same(first)) {
			f.scoped << pair
		}
	}
	rs.fill_above(mut c, f.scoped, rs.names_of())
	// per parent path, the rules (by their first candidate) to give it: `above parent rule`
	mut scoped := map[string]bool{}
	mut scoped_order := []string{}
	for pair in f.scoped {
		ks := c.by_pair[pair]
		first := c.list[ks[0]]
		// the names above, in the order the candidates give them
		mut aboves := []string{}
		for k in ks {
			for a in c.list[k].above {
				if a !in aboves {
					aboves << a
				}
			}
		}
		for k in ks {
			if c.list[k].above.len == 0 && !c.list[k].spec.same(first.spec) {
				// a holder nothing above names: no path can give it its rule
				f.add_conflict(first.parent, first.child, rs.describe(c, [ks[0], k]))
			}
		}
		for a in aboves {
			under := ks.filter(a in c.list[it].above)
			pick := c.list[under[0]]
			if under.any(!c.list[it].spec.same(pick.spec)) {
				f.add_conflict('${a}/${first.parent}',
					first.child, rs.describe(c, under))
			}
			if pick.spec.same(first.spec) {
				continue
			}
			if a == '' {
				// the document's root: no path names it but `/ROOT`, which flatxml cannot
				f.add_conflict('/${first.parent}', first.child, rs.describe(c, [ks[0], under[0]]))
				continue
			}
			key := '${a} ${first.parent} ${pick.rule}'
			if key !in scoped {
				scoped[key] = true
				scoped_order << key
			}
		}
	}
	// the rules, in the candidates' order: each pair's first candidate, the pairs of one parent,
	// rule and spec together; each scoped rule beside its unscoped counterpart
	mut rules := []flatxml.Rule{}
	mut done := map[int]bool{}
	mut done_scoped := map[string]bool{}
	for k0, x in c.list {
		if k0 in done || c.by_pair['${x.parent} ${x.child}'][0] != k0 {
			continue
		}
		mut group := []int{}
		for k in c.by_pair_parent(x.parent) {
			y := c.list[k]
			if k !in done && y.rule == x.rule && y.spec.same(x.spec)
				&& c.by_pair['${y.parent} ${y.child}'][0] == k {
				group << k
				done[k] = true
			}
		}
		f.emit(c, x.parent, group, opts.keyless, mut rules)
		// the scoped rules of this parent whose rule's first pair this is
		for key in scoped_order {
			if key in done_scoped {
				continue
			}
			a, parent, rule := key.split(' ')[0], key.split(' ')[1], key.split(' ')[2].int()
			if parent != x.parent || !group.any(c.list[it].child in c.children_of(rule, parent)) {
				continue
			}
			done_scoped[key] = true
			// the whole role under the path: every item kind, grouped by spec
			mut left := c.of_rule(rule, parent)
			for left.len > 0 {
				sp := c.list[left[0]].spec
				same := left.filter(c.list[it].spec.same(sp))
				f.emit(c, '${a}/${parent}', same, opts.keyless, mut rules)
				left = left.filter(!c.list[it].spec.same(sp))
			}
		}
	}
	// the rules of one parent in the order its type's content gives their children, which is the
	// order flatxml gives a node's aggregations: the order the schema requires
	order := rs.content_order()
	// a child element no rule names comes after those rules name, so where a parent has rules,
	// its other children get one too, of the kind no rule gives (each its own), for their place
	mut named := map[string]bool{} // `parent child` a rule names
	mut parents := []string{}
	for r in rules {
		tail := r.parent.all_after_last('/')
		if tail !in parents {
			parents << tail
		}
		for kid in r.children {
			named['${tail} ${kid}'] = true
		}
	}
	parents.sort()
	for parent in parents {
		if parent !in order {
			continue
		}
		places := order[parent].clone()
		mut others := places.keys().filter('${parent} ${it}' !in named)
		others.sort_with_compare(fn [places] (a &string, b &string) int {
			return places[*a] - places[*b]
		})
		for kid in others {
			f.described << 'each (for its place)'
			rules << flatxml.Rule{
				parent:   parent
				children: [kid]
			}
		}
	}
	// sorted by parent name, then place in its content, then as made
	tails := rules.map(it.parent.all_after_last('/'))
	mut place := []int{cap: rules.len}
	for k, r in rules {
		place << order[tails[k]][r.children[0]] or { max_int }
	}
	mut at := []int{len: rules.len, init: index}
	at.sort_with_compare(fn [tails, place] (a &int, b &int) int {
		if tails[*a] != tails[*b] {
			return if tails[*a] < tails[*b] { -1 } else { 1 }
		}
		if place[*a] != place[*b] {
			return if place[*a] < place[*b] { -1 } else { 1 }
		}
		return *a - *b
	})
	descs := f.described.clone()
	f.described = at.map(descs[it])
	// the repeated roles' rules, by their place in the sorted list
	old_repeat := f.repeat_rules.clone()
	f.repeat_rules = []
	for k, i in at {
		if i in old_repeat {
			f.repeat_rules << k
		}
	}
	// the settings (case, attributes) are the policy's, given by the caller that merges
	f.rules = flatxml.RuleSet{
		rules: at.map(rules[it])
	}
	return f
}

// content_order is, per element name, the place of each child element name in the content
// models of the types it is declared with: one order all of them keep where they can, a name one
// type adds going before the next name that type shares with the others.
fn (rs &RuleSet) content_order() map[string]map[string]int {
	mut out := map[string]map[string]int{}
	for name, types in rs.types_of {
		mut all := []string{}
		for t in types {
			p := rs.schema.complex_types[t].particle
			if p == xsd.no_particle {
				continue
			}
			mut occ := []Occ{}
			rs.walk(p, 1, mut occ)
			seq := occ.map(rs.schema.names[rs.schema.elements[it.decl].name.local])
			for k, child in seq {
				if child in all {
					continue
				}
				mut at := all.len
				for next in seq[k + 1..] {
					i := all.index(next)
					if i >= 0 {
						at = i
						break
					}
				}
				all.insert(at, child)
			}
		}
		mut places := map[string]int{}
		for k, child in all {
			places[child] = k
		}
		out[name] = places
	}
	return out
}

// by_pair_parent is the candidates whose pair's parent is parent, in order.
fn (c &Cands) by_pair_parent(parent string) []int {
	return c.by_parent[parent] or { []int{} }
}

// of_rule is a rule's candidates with one parent.
fn (c &Cands) of_rule(rule int, parent string) []int {
	return c.by_pair_parent(parent).filter(c.list[it].rule == rule)
}

fn (c &Cands) children_of(rule int, parent string) []string {
	return c.of_rule(rule, parent).map(c.list[it].child)
}

// emit appends one flatxml rule for the candidates ks (one rule, one spec) under parent.
fn (mut f Flat) emit(c Cands, parent string, ks []int, keyless flatxml.Keyless, mut rules []flatxml.Rule) {
	sp := c.list[ks[0]].spec
	if sp.repeat {
		f.repeat_rules << rules.len
	}
	f.described << sp.str()
	rules << flatxml.Rule{
		parent:   parent
		children: ks.map(c.list[it].child)
		key:      sp.key
		keyless:  if sp.keyed { keyless } else { flatxml.Keyless.own }
		single:   sp.single
		merge:    sp.merge
		ordered:  sp.ordered
		max:      sp.max
	}
}

// add_conflict records a pair in conflict under parent (a path, or a name), once.
fn (mut f Flat) add_conflict(parent string, child string, rules []string) {
	if f.conflicts.any(it.parent == parent && it.child == child) {
		return
	}
	f.conflicts << Conflict{
		parent: parent
		child:  child
		rules:  rules
	}
}

// declaration_attrs lists the attribute names, as written, that declare namespaces or belong to
// the XML Schema instance namespace (a schema location): they say how a file is written, not what
// it holds, so fragments may differ in them.
pub fn declaration_attrs(m &Model) []string {
	mut seen := map[string]bool{}
	for d in m.set.docs {
		lo, hi := d.attr_range(d.root())
		for a := lo; a < hi; a++ {
			if d.is_ns_decl(a) || d.ns_uri(d.attr_ns_of(a)) == xsi_ns_uri {
				seen[d.attr_name(a)] = true
			}
		}
	}
	mut out := seen.keys()
	out.sort()
	return out
}

// CheckOptions are the command line's overrides of a merge's settings.
@[params]
pub struct CheckOptions {
pub:
	jobs              int      // threads for the XML schema layer; 0 for `default_jobs`, at most 16
	skip_xml          bool     // no XML schema layer
	skip_multiplicity bool     // no multiplicity layer
	skip_references   bool     // no reference layer
	refs_from         []string // files loaded only to resolve references against
	roots             []string // where a filter's relative file glob is read from; the model's bases where none
	exclude           []string // file globs left out of --refs-from's input set, as of the model's
	result_check      bool     // the model is a merge's result: file filters and unused filters do not apply
	case_sensitive    bool     // keys compared as written, whatever the settings say
	ignore_attrs      []string // attributes that may differ, besides the settings'
	compare_attrs     []string // attributes the settings let differ that are compared after all
}

// Settings are a merge's case and attribute settings: the policy's when the rules come from the
// schema, the rules file's when they come from one.
pub struct Settings {
pub mut:
	fold                bool
	ignore_attrs        []string // by name
	ignore_declarations bool     // and the documents' namespace declarations and xsi: attributes
}

// settings are the policy's merge settings.
pub fn (p Policy) settings() Settings {
	return Settings{
		fold:                p.fold
		ignore_attrs:        p.ignore_attrs.clone()
		ignore_declarations: p.ignore_declarations
	}
}

// apply gives the case setting and the attributes to ignore in m's documents, the overrides
// applied.
pub fn (st Settings) apply(m &Model, opts CheckOptions) (bool, []string) {
	mut ignore := st.ignore_attrs.filter(it !in opts.compare_attrs)
	ignore << opts.ignore_attrs
	if st.ignore_declarations {
		ignore << declaration_attrs(m).filter(it !in opts.compare_attrs)
	}
	return st.fold && !opts.case_sensitive, ignore
}

// Checked is a model merged by its governing schema's rules.
pub struct Checked {
pub mut:
	governing string // the governing schema's name, or the rules file's
	flat      Flat
	view      &flatxml.Merged = unsafe { nil }
	// per problem of the view: it lies on an element pair in conflict, so the rule that judged
	// it may not be the pair's, and it is not counted as a violation
	in_conflict []bool
	violations  int
	elements    int // elements in all documents
	merged      int // merged nodes made of more than one element
	within      int // of those, nodes two of whose elements are in one document
	// every finding of every layer, with its severity
	findings []Finding
	// documents checked against the governing XML schema, their own not being at hand
	xml_fallback int
	// occurrences of roles the multiplicity layer could not count (wrappers of item content)
	unchecked_roles int
	// the referrable elements by AUTOSAR path, and what the reference layer counted
	index  &PathIndex = unsafe { nil }
	typing &Typing    = unsafe { nil }
	refs   RefStats
	// files loaded only to resolve references against
	refs_from_files int
	// what the input sets of --refs-from matched nothing of
	input_warnings []string
	// the policy's filters, and per filter the findings it matched
	filters       []Filter
	filter_counts []int
	// how long each layer took
	times map[string]time.Duration
}

// count is the findings of one severity.
pub fn (c &Checked) count(s Severity) int {
	mut n := 0
	for f in c.findings {
		if f.severity == s {
			n++
		}
	}
	return n
}

// repeats_a_document reports whether two of n's contributions come from one document; without a
// map for the few a node has, as it is asked of every merged node.
fn repeats_a_document(n flatxml.MNode) bool {
	k := n.fragment_count()
	if k > 32 {
		mut docs := map[voidptr]bool{}
		for a in 0 .. k {
			d := voidptr(n.fragment(a).doc)
			if d in docs {
				return true
			}
			docs[d] = true
		}
		return false
	}
	for a in 0 .. k {
		da := n.fragment(a).doc
		for b in a + 1 .. k {
			if n.fragment(b).doc == da {
				return true
			}
		}
	}
	return false
}

// governing_use is the schema governing m's documents. One model has one namespace; a namespace
// no schema governs is an error.
pub fn governing_use(sc &Schemas) !&SchemaUse {
	if sc.governing.len != 1 {
		return error('${sc.governing.len} namespaces declared; one model has one')
	}
	g := sc.governing[0]
	if g.use < 0 {
		return error('no schema governs ${g.ns}: ${g.note}')
	}
	return sc.uses[g.use]
}

// governing_flat is the flatxml rules of the schema governing the documents, by the policy the
// schemas were read with: the schema's namespace named by local names (flatxml's local_ns), so a
// document binding it to a prefix merges as one that does not.
pub fn governing_flat(sc &Schemas) !(Flat, string) {
	gov := governing_use(sc)!
	mut f := gov.rules.to_flat(keyless: sc.policy.absent_keys)
	f.rules = flatxml.RuleSet{
		...f.rules
		local_ns: gov.ns
	}
	return f, gov.name
}

// with_settings is a rule set with the merge's case and attribute settings.
pub fn with_settings(rs flatxml.RuleSet, fold bool, ignore []string) flatxml.RuleSet {
	return flatxml.RuleSet{
		...rs
		fold:         fold
		ignore_attrs: ignore
	}
}

// check merges m's documents by the rules of the schema governing their namespace, with the
// policy's settings and severities, and checks each file against its XML schema and the merged
// model's multiplicities against the meta-model (each layer unless skipped).
pub fn check(m &Model, sc &Schemas, opts CheckOptions) !Checked {
	flat, name := governing_flat(sc)!
	gov := governing_use(sc)!
	mut ty := new_typing(gov.schema)
	mut c := check_typed(m, flat, name, sc.policy.settings(), sc.policy, opts, ty)!
	if !opts.skip_xml {
		sw := time.new_stopwatch()
		found, fallback := xml_findings(m, sc, opts.jobs)
		// a finding's path: the merged node its element went into, else the element's names;
		// gathered at their number, then added at once, not grown a finding at a time
		mut add := []Finding{cap: found.len}
		for f in found {
			mut path := f.finding.path
			if f.doc >= 0 {
				d := m.set.docs[f.doc]
				path = if mn := merged_of(c.view, d, f.node) {
					merged_path(mn, c.index)
				} else {
					'#' + doc_names(d, f.node)
				}
			}
			add << Finding{
				...f.finding
				path: path
			}
		}
		c.findings << add
		c.xml_fallback = fallback
		c.times['xml_schema'] = sw.elapsed()
	}
	if !opts.skip_multiplicity {
		sw := time.new_stopwatch()
		mut v := c.view
		found, unchecked := gov.rules.multiplicity_findings(mut v, c.index, sc.policy)
		c.findings << found
		c.unchecked_roles = unchecked
		c.times['multiplicity'] = sw.elapsed()
	}
	if !opts.skip_references {
		sw := time.new_stopwatch()
		mut extra := []RefView{}
		if opts.refs_from.len > 0 {
			mx := load(opts.refs_from, exclude: opts.exclude)!
			c.input_warnings << mx.warnings.map('--refs-from: ${it}')
			c.refs_from_files = mx.set.docs.len
			cx := check_typed(mx, flat, name, sc.policy.settings(), sc.policy, CheckOptions{
				...opts
				refs_from: []
			}, ty)!
			extra << RefView{
				view: cx.view
				ix:   cx.index
			}
		}
		mut v := c.view
		found, stats := reference_findings(mut v, c.index, mut ty, extra, sc.policy)
		c.findings << found
		c.refs = stats
		c.times['reference'] = sw.elapsed()
	}
	c.filter(sc.policy, opts, m)
	return c
}

// check_with merges m's documents by the rules given (from the schema, or a rules file), with
// the settings given and the overrides; the policy gives the findings their severities.
pub fn check_with(m &Model, flat0 Flat, source string, st Settings, p Policy, opts CheckOptions) !Checked {
	mut c := check_typed(m, flat0, source, st, p, opts, unsafe { nil })!
	c.filter(p, opts, m)
	return c
}

// filter applies the policy's filters, after its severities, to what the check found: every layer
// that ran, the inputs as the paths checked.
fn (mut c Checked) filter(p Policy, opts CheckOptions, m &Model) {
	mut ran := c.times.keys()
	ran << 'policy'
	c.findings, c.filter_counts = apply_filters(c.findings, p, FilterOptions{
		roots:  if opts.roots.len > 0 { opts.roots } else { m.bases }
		ran:    ran
		result: opts.result_check
	})
	c.filters = p.filters
}

// check_typed is check_with, the referrable elements and references known from the schema's
// types where ty is given.
fn check_typed(m &Model, flat0 Flat, source string, st Settings, p Policy, opts CheckOptions, ty &Typing) !Checked {
	sw := time.new_stopwatch()
	fold, ignore := st.apply(m, opts)
	mut flat := flat0
	flat.rules = with_settings(flat0.rules, fold, ignore)
	mut ch := new_content_hashes(ignore, naming(flat.rules.local_ns, [m]))
	ch.observe_ignored([m])
	flat.rules = flat.merge_rules([m], mut ch)
	flat.place(m)
	mut view := m.set.merge(flat.rules)!
	msw := time.new_stopwatch()
	typed := ty != unsafe { nil }
	mut typing := if typed { ty } else { &Typing{} }
	index := index_paths(view, mut typing, typed, fold)
	paths_took := msw.elapsed()
	mut merged, mut within := 0, 0
	for i in 0 .. view.len() {
		n := view.node(u32(i))
		if n.fragment_count() > 1 {
			merged++
			if repeats_a_document(n) {
				within++
			}
		}
	}
	mut conflicted := map[string]bool{}
	for x in flat.conflicts {
		conflicted['${x.parent} ${x.child}'] = true
	}
	mut in_conflict := []bool{len: view.problems.len}
	mut violations := 0
	// at their number (the view's problems are most of them), not grown a finding at a time
	mut findings := []Finding{cap: view.problems.len + flat.conflicts.len}
	for x in flat.used() {
		findings << Finding{
			layer:    .merge
			kind:     'conflict'
			what:     x.child
			severity: p.severity(.merge, 'conflict', x.child)
			path:     '${x.parent}/${x.child}'
			message:  'holders with different rules no parent path tells apart, ${x.occurs} in the documents: ${x.rules.join('; ')}'
		}
	}
	for k, pr in view.problems {
		if flat.unkeyed_by_design && pr.kind == .missing_key {
			continue
		}
		// structured comments are not compared, by the policy
		if ignored_problem(view, pr, flat.ignored_content) {
			continue
		}
		// the merged parent of the children concerned, and its parent: the path a conflict names
		mut parent := view.node(pr.node)
		mut child := pr.what
		if pr.kind == .value_differs {
			child = parent.name()
			parent = parent.parent()
		}
		// the keys are only built where there are conflicts to look them up in
		in_conflict[k] = conflicted.len > 0
			&& ('${parent.parent().name()}/${parent.name()} ${child}' in conflicted
				|| '${parent.name()} ${child}' in conflicted)
		if !in_conflict[k] {
			violations++
		}
		kind := pr.kind.str() // a constant; interpolation would make a string per problem
		findings << Finding{
			layer:       .merge
			kind:        kind
			what:        pr.what
			in_conflict: in_conflict[k]
			severity:    p.merge_severity(kind, pr.what, in_conflict[k])
			path:        merged_path(view.node(pr.node), index)
			message:     problem_message(mut view, pr)
			at:          pr.at.map(view.pos(it))
		}
	}
	// keys that differ only in case, where keys are compared as written; repeated roles
	if !fold {
		findings << case_only_findings(mut view, index, flat.rules, p)
	}
	findings << repeated_findings(mut view, index, flat.rules, flat.repeat_rules, mut ch, p)
	mut times := map[string]time.Duration{}
	times['merge'] = sw.elapsed() - paths_took
	times['paths'] = paths_took
	// with no schema, references are found by their DEST attribute and resolved by path alone
	mut refs := RefStats{}
	mut refs_from_files := 0
	mut input_warnings := []string{}
	if !typed && !opts.skip_references {
		rsw := time.new_stopwatch()
		// files loaded only to resolve references against, merged on their own
		mut extra := []RefView{}
		if opts.refs_from.len > 0 {
			mx := load(opts.refs_from, exclude: opts.exclude)!
			input_warnings << mx.warnings.map('--refs-from: ${it}')
			refs_from_files = mx.set.docs.len
			cx := check_typed(mx, flat0, source, st, p, CheckOptions{
				...opts
				refs_from:       []
				skip_references: true
			}, ty)!
			extra << RefView{
				view: cx.view
				ix:   cx.index
			}
		}
		found, stats := reference_findings(mut view, index, mut typing, extra, p)
		findings << found
		refs = stats
		times['reference'] = rsw.elapsed()
	}
	return Checked{
		refs:            refs
		refs_from_files: refs_from_files
		input_warnings:  input_warnings
		governing:       source
		flat:            flat
		view:            view
		in_conflict:     in_conflict
		violations:      violations
		elements:        m.element_count()
		merged:          merged
		within:          within
		findings:        findings
		times:           times
		index:           index
		typing:          if typed { ty } else { unsafe { nil } }
	}
}

// problem_message is what flatxml says of a problem, without its kind and its positions.
fn problem_message(mut v flatxml.Merged, pr flatxml.Problem) string {
	d := v.describe(pr)
	at := ': ' + pr.at.map(v.pos(it)).join(', ')
	body := if d.ends_with(at) { d[..d.len - at.len] } else { d }
	return body.all_after(': ')
}
