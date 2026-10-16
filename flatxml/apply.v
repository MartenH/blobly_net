module flatxml

import os

// Edits on a merged view, and a diff applied with them.
//
// A merged view's nodes are lists of nodes of its documents, so an edit on the view is edits on
// those documents: one edit set per document (`Edit`), made the first time that document is
// edited. A value held in several fragments is set in each, and a removed merged node is removed
// from every document that holds part of it. Structure is edited per document: a new element goes
// under one fragment of its parent, in the document the caller names. Written, each changed
// document goes back to its own file, every byte no edit touched kept.

// MEdit is a set of edits on a merged view: an edit set per document of its set.
@[heap]
pub struct MEdit {
pub:
	view &Merged = unsafe { nil }
mut:
	edits map[int]&Edit // a document's number in the set -> its edit set, once edited
	// view nodes whose subtrees a diff applied copied whole into another document
	copied map[u32]bool
}

// edit starts an empty set of edits on the view, whose documents must outlive it.
pub fn (m &Merged) edit() &MEdit {
	return &MEdit{
		view: m
	}
}

// doc_edit is the edit set of document k of the view's set, made the first time it is asked for.
pub fn (mut me MEdit) doc_edit(k int) &Edit {
	if e := me.edits[k] {
		return e
	}
	mut e := me.view.set.docs[k].edit()
	e.number = k
	me.edits[k] = e
	return e
}

// edited are the numbers of the documents with an edit, in order.
pub fn (me &MEdit) edited() []int {
	mut ks := []int{}
	for k, e in me.edits {
		if e.nodes.len > 0 {
			ks << k
		}
	}
	ks.sort()
	return ks
}

// fragment is the fragment of n in document k as that document's edit set reads it; an empty
// handle when n has none there.
pub fn (mut me MEdit) fragment(n MNode, k int) ENode {
	for j in 0 .. n.fragment_count() {
		f := n.m.frags[n.m.frag_lo[n.i] + u32(j)]
		if int(f.doc) == k {
			return me.doc_edit(k).node(f.i)
		}
	}
	return ENode{}
}

// fragments are n's fragments as their documents' edit sets read them, in the set's order.
pub fn (mut me MEdit) fragments(n MNode) []ENode {
	mut out := []ENode{}
	for j in 0 .. n.fragment_count() {
		f := n.m.frags[n.m.frag_lo[n.i] + u32(j)]
		out << me.doc_edit(int(f.doc)).node(f.i)
	}
	return out
}

// set_text_runs sets the own text of every fragment of n (see `Edit.set_text_runs`).
pub fn (mut me MEdit) set_text_runs(n MNode, runs []TextRun) ! {
	for f in me.fragments(n) {
		mut e := f.e
		e.set_text_runs(f, runs)!
	}
}

// set_text sets the own text of every fragment of n (see `Edit.set_text`).
pub fn (mut me MEdit) set_text(n MNode, text string) ! {
	me.set_text_runs(n, if text == '' { []TextRun{} } else { [TextRun{0, text}] })!
}

// set_attr sets the attribute name of every fragment of n.
pub fn (mut me MEdit) set_attr(n MNode, name string, value string) ! {
	for f in me.fragments(n) {
		mut e := f.e
		e.set_attr(f, name, value)!
	}
}

// remove_attr removes the attribute name from every fragment of n that has it.
pub fn (mut me MEdit) remove_attr(n MNode, name string) ! {
	for f in me.fragments(n) {
		mut e := f.e
		e.remove_attr(f, name)!
	}
}

// remove removes every fragment of n from its document.
pub fn (mut me MEdit) remove(n MNode) ! {
	for f in me.fragments(n) {
		if !f.removed() {
			mut e := f.e
			e.remove(f)!
		}
	}
}

// write_files writes each edited document back to its own path (`Edit.write_file`); the others
// are not touched.
pub fn (mut me MEdit) write_files() ! {
	for k in me.edited() {
		e := me.edits[k] or { continue }
		e.write_file(me.view.set.docs[k].path)!
	}
}

// write_to writes every document of the set to the path to gives it: an edited one as edited,
// the others as they are, byte for byte.
pub fn (mut me MEdit) write_to(to fn (d &Doc) string) ! {
	for k, d in me.view.set.docs {
		path := to(d)
		os.mkdir_all(os.dir(path))!
		if e := me.edits[k] {
			e.write_file(path)!
		} else {
			d.write_file(path)!
		}
	}
}

// --- applying a diff ------------------------------------------------------------------------

// IntoFn names the document of the old view a new element goes to: given a fragment of the
// element in the new view and the old node it goes under, the number of a document of the old
// set that holds part of that node; -1 for the default (see `ApplyOptions.into`).
pub type IntoFn = fn (fragment Node, parent MNode) int

@[params]
pub struct ApplyOptions {
pub:
	// where a new element goes, among the documents its parent is in; by default, the document of
	// its nearest new sibling that the parent's fragments hold (of its own aggregation first;
	// before it, else after it), else of its parent's first fragment
	into ?IntoFn
	// asked before a moved node is copied to another document (its original left behind); false
	// leaves it where it was, and the move is not made
	across ?fn (c Change) bool
}

// apply makes the changes of the diff on its old view, as edits on the old view's documents: the
// documents the diff was made from, so that, written, they read as the new view.
//
// Removed nodes are removed from every document that holds part of them, and moved ones lifted
// out, all before anything is put in, so a change inside a lifted node still applies. Then,
// parent by parent and lowest index first, each added node is copied from the new view, each
// fragment into the document `into` names (by default, its nearest sibling's), and each moved one
// put back into its own document; where that is not where it goes (its parent has no fragment
// there, or its siblings are in another document), the new view's node is copied instead, and
// what is below it there is as the new view has it. An element goes after the nearest of its new
// siblings before it that the document holds, so a document keeps its own order. Then texts and
// attribute values are set in the fragments that hold the old ones (a fragment that disagreed
// already keeps its own), a value the node did not have going to one fragment, as an element
// would, and a removed attribute is removed from all. Attributes are found in each fragment by
// namespace and local name where the diff compared them so, and a new one is written with a
// prefix bound to its namespace there, declared where none is.
//
// A diff places text by slot and reports a text change only where the runs differ, so an element
// whose children change (a child removed, added, or moved out or in) has its runs set again at
// their old slots, where they moved, unless it has a text change of its own.
pub fn (d &Diff) apply(opts ApplyOptions) !&MEdit {
	mut me := d.old.edit()
	d.apply_to(mut me, opts)!
	return me
}

// apply_to makes the changes of the diff on edits already begun on its old view, read through
// them: what the diff's old nodes are now, and where they are, is what the edits made of them.
pub fn (d &Diff) apply_to(mut me MEdit, opts ApplyOptions) ! {
	if voidptr(me.view) != voidptr(d.old) {
		return error('apply: the edits are not of the view the diff was made from')
	}
	mut a := Applier{
		d:      d
		me:     me
		into:   opts.into
		across: opts.across
	}
	a.run()!
}

// apply makes the changes of a diff between two documents on the first, as edits: the diff
// must have been made from old (`diff_docs`), and the edit set is old's.
pub fn apply(diff Diff, old &Doc) !&Edit {
	if diff.old.set.docs.len != 1 || voidptr(diff.old.set.docs[0]) != voidptr(old) {
		return error('apply: the diff was not made from this document')
	}
	mut me := diff.apply()!
	return me.doc_edit(0)
}

struct Applier {
	d      &Diff = unsafe { nil }
	into   ?IntoFn
	across ?fn (c Change) bool
mut:
	me &MEdit = unsafe { nil }
	// what this pass put in: (a new view node, document) -> the element there
	made map[u64]ENode
}

// lift takes element k out of the document, wherever it is: in it, or inside an element taken
// out already, so that it can be put back on its own.
fn (mut e Edit) lift(k u64) {
	ne := e.nodes[k] or { NodeEdit{} }
	if !(ne.detached && !ne.placed) {
		e.detach(k)
	}
}

// at_key is a key for a node and a document number.
@[inline]
fn at_key(n u32, k int) u64 {
	return (u64(n) << 32) | u64(u32(k))
}

// fkey is the key of an old fragment f (a node of its document, not inserted content) with its
// document number.
@[inline]
fn fkey(f ENode) u64 {
	return at_key(kindex(f.key), f.e.number)
}

// Slot is the runs of an old fragment before its children change, and the merged node it is of.
struct Slot {
	f    ENode
	of   MNode
	runs []TextRun
}

fn (mut a Applier) run() ! {
	d := a.d
	if d.changes.any(it.kind in [.added, .removed] && !(if it.kind == .added {
		it.parent.ok()
	} else {
		it.old.parent().ok()
	})) {
		return error('apply: the roots differ, so there is nothing to apply the diff to')
	}
	// the parents whose children change, their runs as they were
	mut slots := map[u64]Slot{}
	for c in d.changes {
		if c.kind in [.removed, .moved] {
			a.keep_runs(c.old.parent(), mut slots)
		}
		if c.kind in [.added, .moved] {
			a.keep_runs(c.parent, mut slots)
		}
	}
	for c in d.changes {
		if c.kind == .text {
			for f in a.me.fragments(c.old) {
				slots.delete(fkey(f))
			}
		}
	}
	// out: the removed, and the moved, to be put back; a node inside one lifted already is lifted
	// from it, so that what is done inside it still holds
	for c in d.changes {
		if c.kind in [.removed, .moved] {
			for f in a.me.fragments(c.old) {
				mut e := f.e
				e.lift(f.key)
			}
		}
	}
	// in: parent by parent, lowest index first
	mut ins := d.changes.filter(it.kind in [.added, .moved])
	ins.sort_with_compare(fn (x &Change, y &Change) int {
		if x.parent.i != y.parent.i {
			return if x.parent.i < y.parent.i { -1 } else { 1 }
		}
		return x.index - y.index
	})
	mut g := 0
	for g < ins.len {
		mut h := g + 1
		for h < ins.len && ins[h].parent.i == ins[g].parent.i {
			h++
		}
		if !a.inside_copy(ins[g].parent) {
			a.fill(ins[g..h])!
		}
		g = h
	}
	for _, sl in slots {
		if a.inside_copy(sl.of) || sl.f.removed() {
			continue
		}
		if sl.f.text_runs() != sl.runs {
			mut e := sl.f.e
			e.set_text_runs(sl.f, sl.runs)!
		}
	}
	for c in d.changes {
		if c.kind !in [.text, .attr] || a.inside_copy(c.old) {
			continue
		}
		a.set_value(c)!
	}
}

// set_value sets the text or attribute change c in the fragments of c.old that hold the old value
// (a fragment that disagreed already, a value the rules report as differing, keeps its own); a
// value the node did not have goes to one fragment, as a new element would.
fn (mut a Applier) set_value(c Change) ! {
	old_runs := c.old.text_runs()
	fresh := if c.kind == .text { old_runs.len == 0 } else { c.before == none }
	only := if fresh && c.old.fragment_count() > 1 { a.value_target(c) } else { ENode{} }
	for f in a.me.fragments(c.old) {
		if only.ok() && fkey(only) != fkey(f) {
			continue
		}
		mut e := f.e
		if c.kind == .text {
			if only.ok() || c.old.fragment_count() == 1 || f.text_runs() == old_runs {
				e.set_text_runs(f, a.reslot(c, f))!
			}
			continue
		}
		// the attribute as this fragment writes it
		have := a.attr_in(f, c)
		if v := c.after {
			held := if b := c.before {
				if name := have { f.attr_opt(name) or { '\x00' } == b } else { false }
			} else {
				have == none
			}
			if held || c.old.fragment_count() == 1 {
				name := have or { a.new_attr_name(mut e, f, c)! }
				e.set_attr(f, name, v)!
			}
		} else if name := have {
			e.remove_attr(f, name)!
		}
	}
}

// attr_in is the name fragment f writes the attribute of change c with, if it has it: matched
// by namespace and local name where the diff compared them so, else by name.
fn (a &Applier) attr_in(f ENode, c Change) ?string {
	src := f.source()
	lo, hi := src.doc.attr_range(src.i)
	for x := lo; x < hi; x++ {
		if a.d.by_ns && src.doc.is_ns_decl(x) {
			continue
		}
		if attr_key(src.doc, x, a.d.by_ns) == c.akey {
			return src.doc.attr_name(x)
		}
	}
	return none
}

// new_attr_name is the name to write the attribute of change c with in fragment f, which does
// not have it: as the new node writes it where its prefix means the same there, else with a
// prefix bound to its namespace there, else with one declared on f.
fn (a &Applier) new_attr_name(mut e Edit, f ENode, c Change) !string {
	if !a.d.by_ns || !c.name.contains(':') {
		return c.name
	}
	// the namespace the new node puts it in
	mut uri := ''
	for j in 0 .. c.new.fragment_count() {
		n := c.new.fragment(j)
		lo, hi := n.doc.attr_range(n.i)
		for x := lo; x < hi; x++ {
			if n.doc.attr_name(x) == c.name {
				uri = n.doc.ns_uri(n.doc.attr_ns[x])
			}
		}
	}
	local := c.name.all_after(':')
	scope := e.scope_in(f.key)
	prefix := c.name.all_before(':')
	if scope[prefix] or { '' } == uri {
		return c.name
	}
	for p, u in scope {
		if u == uri && p != '' {
			return '${p}:${local}'
		}
	}
	mut p := prefix
	for n := 1; p in scope; n++ {
		p = 'ns${n}'
	}
	e.set_attr(f, 'xmlns:${p}', uri)!
	return '${p}:${local}'
}

// reslot is the new runs of text change c in fragment f: a run after a child is after the same
// child where f now has it, so that edits made already (another diff's) keep their places.
fn (mut a Applier) reslot(c Change, f ENode) []TextRun {
	d := a.d
	kids := f.children()
	lo := d.new.kid_lo[c.new.i]
	mut out := []TextRun{cap: c.runs.len}
	for r in c.runs {
		if r.slot == 0 {
			out << r
			continue
		}
		n := lo + u32(r.slot - 1)
		mut key := no_key
		if m := a.made[at_key(n, f.e.number)] {
			key = m.key
		} else if old := d.matched[n] {
			o := a.me.fragment(d.old.node(old), f.e.number)
			if o.ok() && o.parent().key == f.key {
				key = o.key
			}
		}
		mut slot := r.slot
		for x, k in kids {
			if k.key == key {
				slot = x + 1
				break
			}
		}
		if out.len > 0 && slot < out.last().slot {
			slot = out.last().slot
		}
		out << TextRun{slot, r.text}
	}
	return out
}

// value_target is the fragment of c.old a value it did not have goes to: in the document `into`
// names for the new node's fragment that holds it, else the old node's first fragment.
fn (mut a Applier) value_target(c Change) ENode {
	if into := a.into {
		for j in 0 .. c.new.fragment_count() {
			f := c.new.fragment(j)
			holds := if c.kind == .text { f.text_runs().len > 0 } else { f.has_attr(c.name) }
			if holds {
				k := into(f, c.old)
				t := if k >= 0 { a.me.fragment(c.old, k) } else { ENode{} }
				if t.ok() {
					return t
				}
				break
			}
		}
	}
	return a.me.fragments(c.old)[0]
}

// keep_runs notes the runs of every fragment of p, as they are before its children change.
fn (mut a Applier) keep_runs(p MNode, mut slots map[u64]Slot) {
	if !p.ok() {
		return
	}
	for f in a.me.fragments(p) {
		k := fkey(f)
		if k !in slots {
			slots[k] = Slot{f, p, f.text_runs()}
		}
	}
}

// inside_copy reports whether old node n is in a subtree copied whole to another document.
fn (a &Applier) inside_copy(n MNode) bool {
	if a.me.copied.len == 0 {
		return false
	}
	mut c := n
	for c.ok() {
		if a.me.copied[c.i] {
			return true
		}
		c = c.parent()
	}
	return false
}

// Spot is a fragment of a parent being filled: its children as edited, and how far into them the
// last sibling the walk has passed is.
struct Spot {
	t ENode
mut:
	kids []u64
	at   int // the place after the last sibling passed that this fragment holds
}

// fill puts the added and moved nodes of one parent in, lowest index first. It walks the new
// parent's children once: a child that stayed moves each fragment's place past it, and a child
// to put in goes to its document at the place reached there.
fn (mut a Applier) fill(changes []Change) ! {
	d := a.d
	p := changes[0].parent
	np := changes[0].new.parent()
	lo, hi := int(d.new.kid_lo[np.i]), int(d.new.kid_lo[np.i + 1])
	mut spots := map[int]Spot{}
	for f in a.me.fragments(p) {
		mut e := f.e
		spots[e.number] = Spot{
			t:    f
			kids: e.kids(f.key)
		}
	}
	// for each child, the document of the nearest sibling after it that stayed, for the default
	holder := a.holders(np, spots)
	mut next_same := []int{len: hi - lo, init: -1}
	mut next_any := []int{len: hi - lo, init: -1}
	for s := hi - lo - 2; s >= 0; s-- {
		r := d.new.rule[lo + s + 1]
		next_any[s] = if holder[s + 1] >= 0 { holder[s + 1] } else { next_any[s + 1] }
		next_same[s] = if d.new.rule[lo + s] == r && holder[s + 1] >= 0 {
			holder[s + 1]
		} else if d.new.rule[lo + s] == r {
			next_same[s + 1]
		} else {
			-1
		}
	}
	mut last_same := map[u32]int{} // a rule -> the document of the last sibling of it passed
	mut last_any := -1
	mut x := 0
	for s in 0 .. hi - lo {
		n := u32(lo + s)
		rule := d.new.rule[n]
		if x < changes.len && changes[x].index == s {
			c := changes[x]
			x++
			default_doc := if k := last_same[rule] {
				k
			} else if next_same[s] >= 0 {
				next_same[s]
			} else if last_any >= 0 {
				last_any
			} else if next_any[s] >= 0 {
				next_any[s]
			} else {
				a.me.fragments(p)[0].e.number
			}
			k := if c.kind == .added {
				a.add(c, mut spots, default_doc)!
			} else {
				a.move(c, mut spots, default_doc)!
			}
			last_same[rule] = k
			last_any = k
			continue
		}
		// a child that stayed: past it in each fragment that holds it
		if old := d.matched[n] {
			for f in a.me.fragments(d.old.node(old)) {
				mut sp := spots[f.e.number] or { continue }
				for y in sp.at .. sp.kids.len {
					if sp.kids[y] == f.key {
						sp.at = y + 1
						spots[f.e.number] = sp
						last_same[rule] = f.e.number
						last_any = f.e.number
						break
					}
				}
			}
		}
	}
}

// holders is, for each new child of np, the document of a fragment of the parent (in spots)
// that holds it (a child that stayed); -1 for none.
fn (mut a Applier) holders(np MNode, spots map[int]Spot) []int {
	d := a.d
	lo, hi := int(d.new.kid_lo[np.i]), int(d.new.kid_lo[np.i + 1])
	mut out := []int{len: hi - lo, init: -1}
	for s in 0 .. hi - lo {
		if old := d.matched[u32(lo + s)] {
			for f in a.me.fragments(d.old.node(old)) {
				if sp := spots[f.e.number] {
					if f.parent().key == sp.t.key {
						out[s] = f.e.number
						break
					}
				}
			}
		}
	}
	return out
}

// doc_for is the document a fragment f of a new node under p goes to: the one `into` names, if p
// has a fragment there, else default_doc.
fn (a &Applier) doc_for(f Node, p MNode, spots map[int]Spot, default_doc int) int {
	if into := a.into {
		k := into(f, p)
		if k >= 0 && k in spots {
			return k
		}
	}
	return default_doc
}

// put_at files element made (just put in) as the next child at the place reached in spot k.
fn put_at(mut spots map[int]Spot, k int, made ENode) {
	mut sp := spots[k] or { return }
	sp.kids.insert(sp.at, made.key)
	sp.at++
	spots[k] = sp
}

// add copies every fragment of the added node c.new into the document each goes to; the document
// of the first.
fn (mut a Applier) add(c Change, mut spots map[int]Spot, default_doc int) !int {
	mut first := -1
	for j in 0 .. c.new.fragment_count() {
		f := c.new.fragment(j)
		k := a.doc_for(f, c.parent, spots, default_doc)
		sp := spots[k] or { return error('apply: no fragment of the parent in document ${k}') }
		mut e := sp.t.e
		made := e.insert_copy(sp.t, sp.at, f)!
		put_at(mut spots, k, made)
		a.made[at_key(c.new.i, k)] = made
		if first < 0 {
			first = k
		}
	}
	return first
}

// move puts each fragment of the moved node back under the parent's fragment in its own
// document. Where the parent has none in one of them, or a node of one fragment goes to another
// document, it copies the new view's node instead (`add`), and marks the old one copied.
fn (mut a Applier) move(c Change, mut spots map[int]Spot, default_doc int) !int {
	frags := a.me.fragments(c.old)
	mut across := frags.any(it.e.number !in spots)
	if frags.len == 1 && !across {
		across = a.doc_for(c.new.fragment(0), c.parent, spots, default_doc) != frags[0].e.number
	}
	if across {
		if ask := a.across {
			if !ask(c) {
				a.stay(frags, mut spots)
				return frags[0].e.number
			}
		}
		a.me.copied[c.old.i] = true
		return a.add(c, mut spots, default_doc)
	}
	for f in frags {
		k := f.e.number
		sp := spots[k] or { continue }
		mut e := f.e
		e.place(f, sp.t, sp.at)!
		put_at(mut spots, k, f)
		a.made[at_key(c.new.i, k)] = f
	}
	return frags[0].e.number
}

// stay puts the lifted fragments of a node whose move is not made back where they were, and
// files each among its parent's children being filled.
fn (mut a Applier) stay(frags []ENode, mut spots map[int]Spot) {
	for f in frags {
		mut e := f.e
		e.unlift(f.key)
		k := e.number
		mut sp := spots[k] or { continue }
		if f.parent().key != sp.t.key {
			continue
		}
		x := e.kids(sp.t.key).index(f.key)
		if x >= 0 && x <= sp.kids.len {
			sp.kids.insert(x, f.key)
			if x < sp.at {
				sp.at++
			}
			spots[k] = sp
		}
	}
}

// unlift puts element k, lifted from its original place and not put anywhere, back there.
fn (mut e Edit) unlift(k u64) {
	mut ne := e.nodes[k] or { return }
	if !ne.detached || ne.placed {
		return
	}
	op := e.original_parent(k)
	if op != no_key {
		mut pe := e.nodes[op] or { NodeEdit{} }
		pe.lost--
		e.nodes[op] = pe
		e.kid_lists.delete(op)
	}
	ne.detached = false
	e.nodes[k] = ne
}
