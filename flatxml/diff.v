module flatxml

import hash

// The difference between two merged views (two document sets read by their rules, or two
// documents read as their own trees): what was removed, added, moved, and whose text or
// attributes changed, each change naming the node on both sides.
//
// The views are compared top down from their roots. Children that the rules identify (keyed by
// their key, single by their name) are matched by identity; the others are aligned in order, by
// the longest common subsequence of their subtrees (Myers' algorithm), and between the subtrees
// that align, paired by name. Each node's subtree has a hash, computed once, so a matched pair
// whose hashes agree is equal and is not entered. Matched children whose order changed, and a
// removed subtree equal to an added one, are moves.
//
// A change says enough to make the old view into the new one (see `Change`): apply every
// removal and lift every moved node out, then, parent by parent, put each added or moved node at
// its index, lowest first, and set the texts and attributes.

pub enum ChangeKind {
	removed // old: the node removed, with everything below it
	added   // new: the node added, with everything below it; parent and index: where it goes
	moved   // old: where it was; new: where it is; parent and index: where it goes
	text    // old and new: the node whose own text changed; runs: its new text, run by run
	attr    // old and new: the node; name: the attribute; before / after: none when absent
}

// Change is one difference. Nodes are of the old view (`old`, `parent`) or the new one (`new`).
pub struct Change {
pub:
	kind   ChangeKind
	old    MNode     // the node in the old view; empty for added
	new    MNode     // the node in the new view; empty for removed
	parent MNode     // added and moved: the node of the old view it goes under (empty for a root)
	index  int       // added and moved: its place among the children of new's parent
	name   string    // attr: the attribute's name, as the new node writes it
	before ?string   // text: the old text (`show_runs`); attr: the old value, none when absent
	after  ?string   // text: the new text (`show_runs`); attr: the new value, none when gone
	runs   []TextRun // text: the new own text, run by run, each in its slot among the children
	// attr: the name as the old node writes it, where it has one (by namespace, the prefix may
	// differ)
	old_name string
mut:
	akey u64 // attr: the attribute's name, hashed as the diff compared it (`attr_key`)
}

// Diff is the changes from one view to another.
pub struct Diff {
pub:
	old &Merged = unsafe { nil }
	new &Merged = unsafe { nil }
pub mut:
	changes []Change
mut:
	ohash    []u64 // each node's subtree, hashed
	nhash    []u64
	oname    []u64 // each node's name, hashed: as written, or by namespace and local name
	nname    []u64
	by_ns    bool // names compared by namespace and local name: both views resolved them
	compared int  // pairs of nodes entered
	max_d    int  // the most differences an alignment searches for before it pairs greedily
	// a node of the new view -> the node of the old one it was matched with, for the children of
	// every pair compared
	matched map[u32]u32
	// for describing: each parent's children's places among their names
	old_places map[u32][]int
	new_places map[u32][]int
}

@[params]
pub struct DiffOptions {
pub:
	// the most differences one list of children is searched for (Myers' D) before the rest of it
	// is paired greedily, in order: a bound on the time and memory one alignment takes
	max_d int = 1000
}

// diff is the changes that make the view old into the view new. Both must be read by the same
// rules for their identities to agree.
pub fn diff(old &Merged, new &Merged, opts DiffOptions) Diff {
	mut d := Diff{
		old:   old
		new:   new
		max_d: opts.max_d
	}
	d.by_ns = names_resolved(old) && names_resolved(new)
	// the two views hashed at once, one of them on a thread of its own
	t := spawn view_hashes(new, d.by_ns)
	d.ohash, d.oname = view_hashes(old, d.by_ns)
	d.nhash, d.nname = t.wait()
	o, n := old.root(), new.root()
	if !o.ok() && !n.ok() {
		return d
	}
	if !o.ok() || !n.ok() || d.nname[n.i] != d.oname[o.i] {
		if o.ok() {
			d.changes << Change{
				kind: .removed
				old:  o
			}
		}
		if n.ok() {
			d.changes << Change{
				kind: .added
				new:  n
			}
		}
		return d
	}
	d.matched[n.i] = o.i
	d.pair(o.i, n.i)
	d.moves()
	return d
}

// Doc.view is the document as a merged view by rules: with none, its own tree, one merged node
// per element. The view reads the document, which must outlive it.
pub fn (d &Doc) view(rules RuleSet) !&Merged {
	s := &DocSet{
		docs: [d]
		tab:  d.tab
	}
	return s.merge(rules)
}

// diff_docs is the changes that make document a into document b, read by rules (none: each as
// its own tree).
pub fn diff_docs(a &Doc, b &Doc, rules RuleSet, opts DiffOptions) !Diff {
	return diff(a.view(rules)!, b.view(rules)!, opts)
}

// equal reports whether there is no change.
pub fn (d &Diff) equal() bool {
	return d.changes.len == 0
}

// compared is how many pairs of nodes were entered: the rest were equal subtrees, skipped whole.
pub fn (d &Diff) compared() int {
	return d.compared
}

// --- hashing --------------------------------------------------------------------------------

// What each part of a node adds to its hash starts from a seed of its own, so that no two parts
// can stand in for each other (a name for a text, an attribute's name for its value).
const seed_node = u64(0x243F_6A88_85A3_08D3)
const seed_run = u64(0x1319_8A2E_0370_7344)
const seed_attr = u64(0xA409_3822_299F_31D0)
const seed_child = u64(0x082E_FA98_EC4E_6C89)

// fmix is the 64-bit finaliser of MurmurHash3: every bit of x moves every bit of the result.
@[inline]
fn fmix(x_ u64) u64 {
	mut x := x_
	x ^= x >> 33
	x *= 0xff51_afd7_ed55_8ccd
	x ^= x >> 33
	x *= 0xc4ce_b9fe_1a85_ec53
	x ^= x >> 33
	return x
}

// mix is h followed by v: not the same as v followed by h.
@[inline]
fn mix(h u64, v u64) u64 {
	return fmix(h * 0x9E37_79B9_7F4A_7C15 + v)
}

fn text_hash(s string) u64 {
	return hash.wyhash_c(s.str, u64(s.len), name_seed)
}

// names_resolved reports whether every document of the view has its namespaces resolved.
fn names_resolved(m &Merged) bool {
	return m.set.docs.len > 0 && m.set.docs.all(it.ns.len == it.tag.len)
}

// name_key is node i's name, hashed: as written, or, by_ns, its namespace and local name.
fn name_key(m &Merged, i u32, by_ns bool) u64 {
	t := m.set.tab
	if !by_ns {
		return t.hash[m.name[i]]
	}
	f := m.frags[m.frag_lo[i]]
	d := m.set.docs[f.doc]
	return mix(text_hash(d.ns_uri(d.ns[f.i])), t.hash[d.local_id(f.i)])
}

// attr_key is attribute a of d's name, hashed as name_key hashes an element's.
@[inline]
fn attr_key(d &Doc, a u32, by_ns bool) u64 {
	if !by_ns {
		return d.tab.hash[d.attr_tag[a]]
	}
	return mix(text_hash(d.ns_uri(d.attr_ns[a])), d.tab.hash[d.attr_local_id(a)])
}

// view_hashes hashes every node of m with what is below it, and its name alone (`name_key`).
// A subtree's hash is of its name, its own text run by run with each run's slot, its
// attributes (each name with its value, in any order; by_ns, namespace declarations left out)
// and its children (in order). Children come after their parent, so one pass from the end finds
// every child hashed before its parent.
fn view_hashes(m &Merged, by_ns bool) ([]u64, []u64) {
	mut h := []u64{len: m.len()}
	mut names := []u64{len: m.len()}
	for i := m.len() - 1; i >= 0; i-- {
		n := MNode{m, u32(i)}
		nk := name_key(m, u32(i), by_ns)
		put(names, i, nk)
		mut x := mix(seed_node, nk)
		x = mix(x, runs_hash(n))
		x = mix(x, attrs_hash(n, by_ns))
		for c := m.kid_lo[i]; c < m.kid_lo[i + 1]; c++ {
			x = mix(mix(x, seed_child), h[c])
		}
		put(h, i, x)
	}
	return h, names
}

// runs_hash hashes the node's own text as `text_runs` has it, without making the list where it
// is the text of an element that holds only text.
fn runs_hash(n MNode) u64 {
	f := n.fragment(0)
	if !f.doc.has_text_children(f.i) {
		if f.doc.text_len[f.i] == 0 {
			return seed_run
		}
		return mix(mix(seed_run, 0), text_hash(f.doc.text(f.i)))
	}
	mut h := seed_run
	for r in f.text_runs() {
		h = mix(mix(h, u64(r.slot)), text_hash(r.text))
	}
	return h
}

// attrs_hash hashes the node's attributes as `attr_list` has them, in any order: without making
// the list where there is one contribution.
fn attrs_hash(n MNode, by_ns bool) u64 {
	mut h := u64(0)
	if n.fragment_count() == 1 {
		f := n.fragment(0)
		lo, hi := f.doc.attr_range(f.i)
		for a := lo; a < hi; a++ {
			if by_ns && f.doc.is_ns_decl(a) {
				continue
			}
			h += mix(mix(seed_attr, attr_key(f.doc, a, by_ns)), text_hash(f.doc.attr_value(a)))
		}
		return h
	}
	for a in attr_list(n, by_ns) {
		h += mix(mix(seed_attr, a.key), text_hash(a.value))
	}
	return h
}

// KAttr is an attribute of a merged node as a diff compares it: its name hashed (`attr_key`).
struct KAttr {
	key   u64
	name  string
	value string
}

// attr_list is the node's attributes as a diff compares them: each name once, from the first
// contribution that has it; by_ns, namespace declarations left out.
fn attr_list(n MNode, by_ns bool) []KAttr {
	mut out := []KAttr{}
	for k in 0 .. n.fragment_count() {
		f := n.fragment(k)
		lo, hi := f.doc.attr_range(f.i)
		for a := lo; a < hi; a++ {
			if by_ns && f.doc.is_ns_decl(a) {
				continue
			}
			key := attr_key(f.doc, a, by_ns)
			if k == 0 || !out.any(it.key == key) {
				out << KAttr{key, f.doc.attr_name(a), f.doc.attr_value(a)}
			}
		}
	}
	return out
}

// MAttr is an attribute of a merged node.
pub struct MAttr {
pub:
	tag   u32
	value string
}

// attrs are the node's attributes: each name once, from the first contribution that has it.
pub fn (n MNode) attrs() []MAttr {
	mut out := []MAttr{}
	for k in 0 .. n.fragment_count() {
		f := n.fragment(k)
		lo, hi := f.doc.attr_range(f.i)
		for a := lo; a < hi; a++ {
			t := f.doc.attr_tag[a]
			if k == 0 || !out.any(it.tag == t) {
				out << MAttr{t, f.doc.attr_value(a)}
			}
		}
	}
	return out
}

// --- comparing ------------------------------------------------------------------------------

// pair compares old node o with new node n, which match: their texts, attributes and children.
fn (mut d Diff) pair(o u32, n u32) {
	if d.ohash[o] == d.nhash[n] {
		return
	}
	d.compared++
	om, nm := d.old.node(o), d.new.node(n)
	ot, nt := om.text_runs(), nm.text_runs()
	if ot != nt {
		d.changes << Change{
			kind:   .text
			old:    om
			new:    nm
			before: show_runs(ot)
			after:  show_runs(nt)
			runs:   nt
		}
	}
	d.attrs(om, nm)
	d.children(o, n)
}

// attrs reports the attributes changed, added and removed from om to nm.
fn (mut d Diff) attrs(om MNode, nm MNode) {
	oa, na := attr_list(om, d.by_ns), attr_list(nm, d.by_ns)
	for a in na {
		mut found := false
		for b in oa {
			if b.key == a.key {
				found = true
				if b.value != a.value {
					d.changes << Change{
						kind:     .attr
						old:      om
						new:      nm
						name:     a.name
						old_name: b.name
						before:   b.value
						after:    a.value
						akey:     a.key
					}
				}
				break
			}
		}
		if !found {
			d.changes << Change{
				kind:   .attr
				old:    om
				new:    nm
				name:   a.name
				before: none
				after:  a.value
				akey:   a.key
			}
		}
	}
	for b in oa {
		if !na.any(it.key == b.key) {
			d.changes << Change{
				kind:     .attr
				old:      om
				new:      nm
				name:     b.name
				old_name: b.name
				before:   b.value
				after:    none
				akey:     b.key
			}
		}
	}
}

// identified reports whether a node is found by its identity: keyed, or single.
@[inline]
fn identified(m &Merged, i u32) bool {
	return m.kind[i] == .keyed || m.kind[i] == .single
}

// children matches the children of o (old) and n (new), reports what is removed, added and
// moved among them, and compares each matched pair.
fn (mut d Diff) children(o u32, n u32) {
	olo, ohi := d.old.kid_lo[o], d.old.kid_lo[o + 1]
	nlo, nhi := d.new.kid_lo[n], d.new.kid_lo[n + 1]
	// for each new child, its match among the old ones (no_mnode: none), and the other way
	mut to_old := []u32{len: int(nhi - nlo), init: no_mnode}
	mut to_new := []u32{len: int(ohi - olo), init: no_mnode}
	// identified children by identity: name and key
	on := d.old.node(o)
	fold := d.old.rules.fold
	mut ids := map[u64][]u32{} // the old identified children, by name and key
	for c := olo; c < ohi; c++ {
		if identified(d.old, c) {
			ids[mix(d.oname[c], key_hash(0, 0, d.old.key_of(c), fold))] << c
		}
	}
	for c := nlo; c < nhi; c++ {
		if !identified(d.new, c) {
			continue
		}
		key := d.new.key_of(c)
		for m in ids[mix(d.nname[c], key_hash(0, 0, key, fold))] or { continue } {
			if d.old.kind[m] == d.new.kind[c] && to_new[m - olo] == no_mnode
				&& compare_keys(d.old.key_of(m), key, fold) == 0 {
				to_old[c - nlo] = m
				to_new[m - olo] = c
				break
			}
		}
	}
	// the others aligned in order: equal subtrees first, then by name between them
	mut xs := []u32{}
	mut ys := []u32{}
	for c := olo; c < ohi; c++ {
		if !identified(d.old, c) {
			xs << c
		}
	}
	for c := nlo; c < nhi; c++ {
		if !identified(d.new, c) {
			ys << c
		}
	}
	if xs.len > 0 && ys.len > 0 {
		a := xs.map(d.ohash[it])
		b := ys.map(d.nhash[it])
		pairs := align(a, b, d.max_d)
		mut px, mut py := 0, 0
		for p in pairs {
			d.pair_by_name(xs[px..p.x], ys[py..p.y], olo, nlo, mut to_old, mut to_new)
			to_old[ys[p.y] - nlo] = xs[p.x]
			to_new[xs[p.x] - olo] = ys[p.y]
			px, py = p.x + 1, p.y + 1
		}
		d.pair_by_name(xs[px..], ys[py..], olo, nlo, mut to_old, mut to_new)
	}
	// matched children out of order: the fewest moved, those off a longest increasing run
	mut seq := []int{}
	mut seq_at := []int{}
	for k, m in to_old {
		if m != no_mnode {
			seq << int(m)
			seq_at << k
		}
	}
	mut stays := []bool{len: seq.len}
	for k in increasing_run(seq) {
		stays[k] = true
	}
	for c := olo; c < ohi; c++ {
		if to_new[c - olo] == no_mnode {
			d.changes << Change{
				kind: .removed
				old:  d.old.node(c)
			}
		}
	}
	mut s := 0
	for k in 0 .. to_old.len {
		c := nlo + u32(k)
		m := to_old[k]
		if m != no_mnode {
			d.matched[c] = m
		}
		if m == no_mnode {
			d.changes << Change{
				kind:   .added
				new:    d.new.node(c)
				parent: on
				index:  k
			}
			continue
		}
		if !stays[s] {
			d.changes << Change{
				kind:   .moved
				old:    d.old.node(m)
				new:    d.new.node(c)
				parent: on
				index:  k
			}
		}
		s++
		d.pair(m, c)
	}
}

// pair_by_name pairs, in order, the old and new children of one gap between aligned ones that
// have the same name: each name's old children in a queue, read past the ones passed.
fn (mut d Diff) pair_by_name(xs []u32, ys []u32, olo u32, nlo u32, mut to_old []u32, mut to_new []u32) {
	if xs.len == 0 || ys.len == 0 {
		return
	}
	mut places := map[u64][]int{}
	for k, x in xs {
		places[d.oname[x]] << k
	}
	mut next := map[u64]int{}
	mut from := 0
	for y in ys {
		t := d.nname[y]
		at := places[t] or { continue }
		mut k := next[t]
		for k < at.len && at[k] < from {
			k++
		}
		if k < at.len {
			x := xs[at[k]]
			to_old[y - nlo] = x
			to_new[x - olo] = y
			from = at[k] + 1
			k++
		}
		next[t] = k
	}
}

// moves makes each removed subtree that equals an added one (the same hash), in the order
// reported, a move.
fn (mut d Diff) moves() {
	mut removed := map[u64][]int{}
	for k, c in d.changes {
		if c.kind == .removed {
			removed[d.ohash[c.old.i]] << k
		}
	}
	if removed.len == 0 {
		return
	}
	mut drop := []bool{len: d.changes.len}
	mut taken := map[u64]int{} // how many of each bucket are moves already
	for k, c in d.changes {
		if c.kind != .added {
			continue
		}
		h := d.nhash[c.new.i]
		ks := removed[h] or { continue }
		at := taken[h]
		if at == ks.len {
			continue
		}
		taken[h] = at + 1
		r := ks[at]
		drop[r] = true
		d.changes[k] = Change{
			kind:   .moved
			old:    d.changes[r].old
			new:    c.new
			parent: c.parent
			index:  c.index
		}
	}
	mut kept := []Change{cap: d.changes.len}
	for k, c in d.changes {
		if !drop[k] {
			kept << c
		}
	}
	d.changes = kept
}

// --- alignment ------------------------------------------------------------------------------

struct XY {
	x int
	y int
}

// align is a longest common subsequence of a and b, as index pairs in order: Myers' algorithm
// after the common start and end are taken off. Past max_d differences the rest is matched
// greedily, each element of b with the next equal one of a.
fn align(a []u64, b []u64, max_d int) []XY {
	mut out := []XY{}
	mut lo := 0
	for lo < a.len && lo < b.len && a[lo] == b[lo] {
		out << XY{lo, lo}
		lo++
	}
	mut ea, mut eb := a.len, b.len
	for ea > lo && eb > lo && a[ea - 1] == b[eb - 1] {
		ea--
		eb--
	}
	out << myers(a[lo..ea], b[lo..eb], lo, max_d)
	for k in 0 .. a.len - ea {
		out << XY{ea + k, eb + k}
	}
	return out
}

// myers is the pairs of a longest common subsequence of a and b (offset by base), or, past
// max_d differences, a greedy one.
fn myers(a []u64, b []u64, base int, max_d int) []XY {
	n, m := a.len, b.len
	if n == 0 || m == 0 {
		return []
	}
	off := n + m
	mut v := []int{len: 2 * off + 2}
	// before each round dd, the diagonals it reads: v[off - dd - 1 .. off + dd + 2]
	mut trace := [][]int{}
	mut end_d := -1
	for dd in 0 .. n + m + 1 {
		if dd > max_d {
			return greedy(a, b, base)
		}
		trace << v[imax(0, off - dd - 1)..imin(v.len, off + dd + 2)].clone()
		for k := -dd; k <= dd; k += 2 {
			mut x := if k == -dd || (k != dd && v[off + k - 1] < v[off + k + 1]) {
				v[off + k + 1]
			} else {
				v[off + k - 1] + 1
			}
			mut y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[off + k] = x
			if x >= n && y >= m {
				end_d = dd
				break
			}
		}
		if end_d >= 0 {
			break
		}
	}
	// back from the end: each round's snake, after its one step, is a run of matches
	mut out := []XY{}
	mut x, mut y := n, m
	for dd := end_d; dd >= 0; dd-- {
		vp := trace[dd]
		o := off - imax(0, off - dd - 1) // where diagonal 0 is in vp
		k := x - y
		pk := if k == -dd || (k != dd && vp[o + k - 1] < vp[o + k + 1]) { k + 1 } else { k - 1 }
		px := vp[o + pk]
		py := px - pk
		for x > px && y > py {
			x--
			y--
			out << XY{base + x, base + y}
		}
		x, y = px, py
	}
	out.reverse_in_place()
	return out
}

// greedy matches each element of b with the next equal element of a not yet passed: each value's
// places in a in a queue, read past the ones passed, so the whole costs one pass of each list.
fn greedy(a []u64, b []u64, base int) []XY {
	mut places := map[u64][]int{}
	for i, h in a {
		places[h] << i
	}
	mut next := map[u64]int{}
	mut out := []XY{}
	mut from := 0
	for j, h in b {
		at := places[h] or { continue }
		mut k := next[h]
		for k < at.len && at[k] < from {
			k++
		}
		if k < at.len {
			out << XY{base + at[k], base + j}
			from = at[k] + 1
			k++
		}
		next[h] = k
	}
	return out
}

@[inline]
fn imax(a int, b int) int {
	return if a > b { a } else { b }
}

@[inline]
fn imin(a int, b int) int {
	return if a < b { a } else { b }
}

// increasing_run is the positions of a longest strictly increasing subsequence of s.
fn increasing_run(s []int) []int {
	if s.len == 0 {
		return []
	}
	mut tails := []int{} // position in s of the smallest tail of a run of each length
	mut prev := []int{len: s.len, init: -1}
	for i, x in s {
		mut lo, mut hi := 0, tails.len
		for lo < hi {
			mid := (lo + hi) / 2
			if s[tails[mid]] < x {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > 0 {
			prev[i] = tails[lo - 1]
		}
		if lo == tails.len {
			tails << i
		} else {
			tails[lo] = i
		}
	}
	mut out := []int{len: tails.len}
	mut k := tails.last()
	for j := tails.len - 1; j >= 0; j-- {
		out[j] = k
		k = prev[k]
	}
	return out
}

// --- describing -----------------------------------------------------------------------------

// path is where a merged node is, from the root: each step its name, with its key where it has
// one, or its place among the siblings of its name where there are several (`/r/item[pump]/x[2]`).
// It reads the siblings at every step; `Diff.path` remembers them, for many paths.
pub fn (n MNode) path() string {
	mut places := map[u32][]int{}
	return path_in(n, mut places)
}

// path_in is `path`, with each parent's children's places among their names kept in places, by
// the parent's index in the node's view.
fn path_in(n MNode, mut places map[u32][]int) string {
	if !n.ok() {
		return ''
	}
	mut parts := []string{}
	mut c := n
	for c.ok() {
		mut step := c.name()
		if c.keyed() {
			step += '[${show_key(c.key())}]'
		} else if c.m.kind[c.i] == .each {
			p := c.parent()
			if p.i !in places {
				places[p.i] = ordinals(p)
			}
			nth := places[p.i][c.i - c.m.kid_lo[p.i]]
			if nth > 0 {
				step += '[${nth}]'
			}
		}
		parts << step
		c = c.parent()
	}
	parts.reverse_in_place()
	return '/' + parts.join('/')
}

// ordinals is, for each child of p, its place among the children of its name, counting from 1,
// or 0 where it is the only one.
fn ordinals(p MNode) []int {
	m := p.m
	lo, hi := m.kid_lo[p.i], m.kid_lo[p.i + 1]
	mut count := map[u32]int{}
	mut out := []int{len: int(hi - lo)}
	for c := lo; c < hi; c++ {
		count[m.name[c]]++
		out[c - lo] = count[m.name[c]]
	}
	for c := lo; c < hi; c++ {
		if count[m.name[c]] == 1 {
			out[c - lo] = 0
		}
	}
	return out
}

// path is `MNode.path` for a node of either view, the places among siblings kept between calls.
pub fn (mut d Diff) path(n MNode) string {
	if voidptr(n.m) == voidptr(d.old) {
		return path_in(n, mut d.old_places)
	}
	return path_in(n, mut d.new_places)
}

// pos is the position of a node of either view (its first contribution).
pub fn (d &Diff) pos(n MNode) string {
	return n.pos()
}

// describe is a change in one line: what, where (the node's path), and its positions.
pub fn (mut d Diff) describe(c Change) string {
	return match c.kind {
		.removed {
			'- ${d.path(c.old)}  ${d.pos(c.old)}'
		}
		.added {
			'+ ${d.path(c.new)}  ${d.pos(c.new)}'
		}
		.moved {
			'> ${d.path(c.old)} -> ${d.path(c.new)}  ${d.pos(c.old)} -> ${d.pos(c.new)}'
		}
		.text {
			'~ ${d.path(c.new)}: ${quoted(c.before)} -> ${quoted(c.after)}  ${d.pos(c.old)} -> ${d.pos(c.new)}'
		}
		.attr {
			'@ ${d.path(c.new)}/@${c.name}: ${quoted(c.before)} -> ${quoted(c.after)}  ${d.pos(c.old)} -> ${d.pos(c.new)}'
		}
	}
}

// show_runs is an own text for reading: as it is, where it is one run before every child, else
// each run after the number of children before it, in braces (`a{1}b`).
pub fn show_runs(runs []TextRun) string {
	if runs.len == 1 && runs[0].slot == 0 {
		return runs[0].text
	}
	return runs.map(if it.slot == 0 { it.text } else { '{${it.slot}}${it.text}' }).join('')
}

fn quoted(s ?string) string {
	v := s or { return '(none)' }
	cut := if v.len > 60 { v[..57] + '...' } else { v }
	return '"' + cut.replace('\n', '\\n') + '"'
}
