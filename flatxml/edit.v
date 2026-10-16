module flatxml

import io

// Edits over one document: texts and attributes set, elements inserted, removed and moved. The
// document is never changed; an edit set keeps its changes beside it, keyed by node, and reads
// through them (`ENode` answers like a node of the edited document). Written, the document keeps
// every byte no edit touched: the bytes of untouched elements, and the comments, processing
// instructions and whitespace between them. A removed element takes with it the indentation
// before it, and an inserted one gets the indentation of its neighbours.
//
// Inserted content is a piece of its own: a fragment parsed from a string, or a node of any
// document (copied, so its document must outlive the edit set). A node of the edited document
// is the piece and its index there, so edits can go on inside inserted content too. A node
// copied or moved keeps its namespaces: where the bindings in scope at its new place differ from
// those at its old one, it is given declarations that restore them, `xmlns=""` included. A
// fragment is read in the namespaces in scope where it is first put, and keeps them when moved.

const no_key = u64(0xFFFF_FFFF_FFFF_FFFF)

@[inline]
fn ekey(piece u32, i u32) u64 {
	return u64(piece) << 32 | u64(i)
}

@[inline]
fn kpiece(k u64) u32 {
	return u32(k >> 32)
}

@[inline]
fn kindex(k u64) u32 {
	return u32(k)
}

// Piece is content an edit set holds: the edited document (piece 0), a parsed fragment, or a
// node copied from a document.
struct Piece {
	doc   &Doc
	root  u32
	owned bool // a fragment the edit set parsed, freed with it
	// a fragment's bindings: those in scope where it was put first, which it keeps
	scope map[string]string
}

// NodeEdit is what changed at one node.
struct NodeEdit {
mut:
	runs  ?[]TextRun // its own text, run by run, when set
	attrs []AttrChange
	// elements put under this one, by the original child each goes before (no_key: after the
	// last), in order
	ins      map[u64][]u64
	lost     int  // original children removed or moved away
	detached bool // not where it was: removed, or moved
	placed   bool // put under `parent`, before its original child `anchor`, by an insert or a move
	parent   u64 = no_key
	anchor   u64 = no_key
}

struct AttrChange {
	name  string
	value ?string // none: removed
}

// Edit is a set of edits over a document.
@[heap]
pub struct Edit {
pub:
	doc &Doc = unsafe { nil }
mut:
	pieces []Piece
	nodes  map[u64]NodeEdit
	// child lists `put` and `relocate` asked for (`kids`), kept current by every edit that
	// changes them, so a run of edits under one parent does not rebuild its list each time
	kid_lists map[u64][]u64
	number    int = -1 // its document's number in a set, when it is one of a merged view's (`MEdit`)
}

// edit starts an empty edit set over the document, which must outlive it.
pub fn (d &Doc) edit() &Edit {
	return &Edit{
		doc:    d
		pieces: [Piece{
			doc:  d
			root: 0
		}]
	}
}

// free releases the fragments the edit set parsed and drops every edit: the edit set is empty
// again, and a node of inserted content reads as a missing one.
pub fn (mut e Edit) free() {
	for mut p in e.pieces {
		if p.owned {
			mut d := p.doc
			d.free()
		}
	}
	e.pieces = [e.pieces[0]]
	e.nodes = map[u64]NodeEdit{}
	e.kid_lists = map[u64][]u64{}
}

// ENode is a node of an edited document: an element, read with the edits applied.
pub struct ENode {
pub:
	e   &Edit = unsafe { nil }
	key u64   = no_key
}

// EAttr is an attribute of an edited element.
pub struct EAttr {
pub:
	name  string
	value string
}

// root is the root element.
pub fn (e &Edit) root() ENode {
	return ENode{e, ekey(0, 1)}
}

// node is element i of the document, as edited.
pub fn (e &Edit) node(i u32) ENode {
	return ENode{e, ekey(0, i)}
}

// ok reports whether the handle names a node.
pub fn (n ENode) ok() bool {
	return n.key != no_key && !isnil(n.e) && int(kpiece(n.key)) < n.e.pieces.len
}

// source is the node this one reads: in the edited document, or in inserted content.
pub fn (n ENode) source() Node {
	if !n.ok() {
		return Node{}
	}
	return Node{n.e.pieces[kpiece(n.key)].doc, kindex(n.key)}
}

// name is the element's name.
pub fn (n ENode) name() string {
	if !n.ok() {
		return ''
	}
	src := n.source()
	return src.doc.name(src.i)
}

// text is the element's own text, decoded: beside child elements, the text beside them, joined.
pub fn (n ENode) text() string {
	return n.text_runs().map(it.text).join('')
}

// text_runs is the element's own text run by run, each with its slot: the number of child
// elements, as edited, before it.
pub fn (n ENode) text_runs() []TextRun {
	if !n.ok() {
		return []
	}
	ne := n.e.nodes[n.key] or { NodeEdit{} }
	if runs := ne.runs {
		return runs
	}
	d := n.e.doc_of(n.key)
	i := kindex(n.key)
	if d.text_len[i] != 0 {
		return [TextRun{0, d.text(i)}]
	}
	// the original runs, each after the child elements that are now before it
	pc := kpiece(n.key)
	mut out := []TextRun{}
	mut slot := 0
	mut c := d.first_child(i)
	for c != no_node {
		ck := ekey(pc, c)
		slot += (ne.ins[ck] or { [] }).len
		if d.is_text(c) {
			out << TextRun{slot, d.text(c)}
		} else if !n.e.detached(ck) {
			slot++
		}
		c = d.next_sibling(c)
	}
	return out
}

// attr is the value of the attribute name; '' when there is none.
pub fn (n ENode) attr(name string) string {
	return n.attr_opt(name) or { '' }
}

// has_attr reports whether the element has the attribute name.
pub fn (n ENode) has_attr(name string) bool {
	return n.attr_opt(name) != none
}

fn (n ENode) attr_opt(name string) ?string {
	for a in n.attrs() {
		if a.name == name {
			return a.value
		}
	}
	return none
}

// attrs are the element's attributes, in order: the original ones as changed, then the new.
pub fn (n ENode) attrs() []EAttr {
	if !n.ok() {
		return []
	}
	src := n.source()
	ne := n.e.nodes[n.key] or { NodeEdit{} }
	return final_attrs(src.doc, src.i, ne.attrs).map(EAttr{it.name, it.value})
}

// FinalAttr is an attribute of an edited element: src is the original attribute it is (-1 for a
// new one), changed whether its value was set.
struct FinalAttr {
	name    string
	value   string
	src     int
	changed bool
}

// final_attrs applies changes, in order, to the attributes of element i: a value set replaces
// the one the element has, in its place, or comes after the others; a removed attribute set again
// is a new one.
fn final_attrs(d &Doc, i u32, changes []AttrChange) []FinalAttr {
	mut out := []FinalAttr{}
	mut at := map[string]int{} // name -> its entry in out
	mut gone := []bool{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		at[d.attr_name(a)] = out.len
		out << FinalAttr{d.attr_name(a), d.attr_value(a), int(a), false}
		gone << false
	}
	for c in changes {
		k := at[c.name] or { -1 }
		if v := c.value {
			if k >= 0 {
				out[k] = FinalAttr{c.name, v, out[k].src, true}
			} else {
				at[c.name] = out.len
				out << FinalAttr{c.name, v, -1, true}
				gone << false
			}
		} else if k >= 0 {
			gone[k] = true
			at.delete(c.name)
		}
	}
	mut kept := []FinalAttr{cap: out.len}
	for k, f in out {
		if !gone[k] {
			kept << f
		}
	}
	return kept
}

// children are the child elements, in order.
pub fn (n ENode) children() []ENode {
	if !n.ok() {
		return []
	}
	return n.e.kids(n.key).map(ENode{n.e, it})
}

// child is the first child element named name, or an empty handle.
pub fn (n ENode) child(name string) ENode {
	for c in n.children() {
		if c.name() == name {
			return c
		}
	}
	return ENode{n.e, no_key}
}

// parent is the parent element; an empty handle for the root and for a removed element.
pub fn (n ENode) parent() ENode {
	if !n.ok() {
		return n
	}
	return ENode{n.e, n.e.parent_of(n.key)}
}

// removed reports whether the element is not in the edited document.
pub fn (n ENode) removed() bool {
	return !n.ok() || !n.e.in_tree(n.key)
}

// --- structure ------------------------------------------------------------------------------

fn (e &Edit) doc_of(k u64) &Doc {
	return e.pieces[kpiece(k)].doc
}

fn (e &Edit) is_element(k u64) bool {
	return e.doc_of(k).is_element(kindex(k))
}

// original_parent is the parent k has where it was read, within its piece; no_key for the root
// and for a piece's own root.
fn (e &Edit) original_parent(k u64) u64 {
	p := kpiece(k)
	i := kindex(k)
	if i == e.pieces[p].root {
		return no_key
	}
	up := e.pieces[p].doc.parent[i]
	if p == 0 && up == 0 {
		return no_key
	}
	return ekey(p, up)
}

fn (e &Edit) detached(k u64) bool {
	ne := e.nodes[k] or { return false }
	return ne.detached
}

// parent_of is k's parent in the edited document.
fn (e &Edit) parent_of(k u64) u64 {
	if ne := e.nodes[k] {
		if ne.placed {
			return ne.parent
		}
		if ne.detached {
			return no_key
		}
	}
	return e.original_parent(k)
}

// in_tree reports whether k is in the edited document: its chain of parents reaches the root.
fn (e &Edit) in_tree(k u64) bool {
	mut c := k
	for c != no_key {
		if c == ekey(0, 1) {
			return true
		}
		ne := e.nodes[c] or { NodeEdit{} }
		if ne.detached && !ne.placed {
			return false
		}
		c = e.parent_of(c)
	}
	return false
}

// kids are the child elements of p in the edited document: its original children that are still
// there, and before each, what was put before it; then what was put at the end.
fn (e &Edit) kids(p u64) []u64 {
	d := e.doc_of(p)
	pc := kpiece(p)
	ne := e.nodes[p] or { NodeEdit{} }
	mut out := []u64{}
	mut c := d.first_child(kindex(p))
	for c != no_node {
		ck := ekey(pc, c)
		if put := ne.ins[ck] {
			out << put
		}
		if d.is_element(c) && !e.detached(ck) {
			out << ck
		}
		c = d.next_sibling(c)
	}
	if put := ne.ins[no_key] {
		out << put
	}
	return out
}

// kid_list is `kids(p)`, from `kid_lists` when it is there.
fn (mut e Edit) kid_list(p u64) []u64 {
	if l := e.kid_lists[p] {
		return l
	}
	l := e.kids(p)
	e.kid_lists[p] = l
	return l
}

// kid_left takes k out of p's kept child list.
fn (mut e Edit) kid_left(p u64, k u64) {
	mut l := e.kid_lists[p] or { return }
	i := l.index(k)
	if i >= 0 {
		l.delete(i)
		e.kid_lists[p] = l
	}
}

// --- edits ----------------------------------------------------------------------------------

// check_node fails unless n is an element of this edit set.
fn (e &Edit) check_node(n ENode, what string) ! {
	if !n.ok() || voidptr(n.e) != voidptr(e) {
		return error('${what}: not a node of this edit set')
	}
	if !e.is_element(n.key) {
		return error('${what}: not an element')
	}
}

// check fails unless n is an element of this edit set in the edited document.
fn (e &Edit) check(n ENode, what string) ! {
	e.check_node(n, what)!
	if !e.in_tree(n.key) {
		return error('${what}: <${n.name()}> is not in the document')
	}
}

// set_text makes text the element's own text, before its first child element; the text it had
// beside its children goes.
pub fn (mut e Edit) set_text(n ENode, text string) ! {
	e.set_text_runs(n, if text == '' { []TextRun{} } else { [TextRun{0, text}] })!
}

// set_text_runs makes runs the element's own text: each run after as many of its child elements
// (as they are when it is written) as its slot says, in place of the text it had beside them.
// Slots must not decrease; a run whose slot is past the last child goes after it.
pub fn (mut e Edit) set_text_runs(n ENode, runs []TextRun) ! {
	e.check(n, 'set_text_runs')!
	for k := 1; k < runs.len; k++ {
		if runs[k].slot < runs[k - 1].slot {
			return error('set_text_runs: the slots of the runs decrease')
		}
	}
	mut ne := e.nodes[n.key] or { NodeEdit{} }
	ne.runs = runs.filter(it.text != '')
	e.nodes[n.key] = ne
}

// set_attr gives the element the attribute name with value: in place of the one it has, or after
// its others.
pub fn (mut e Edit) set_attr(n ENode, name string, value string) ! {
	e.check(n, 'set_attr')!
	if name == '' || name.contains_any(' \t\r\n<>&=/"\'') {
		return error('set_attr: `${name}` is not an attribute name')
	}
	mut ne := e.nodes[n.key] or { NodeEdit{} }
	ne.attrs << AttrChange{name, value}
	e.nodes[n.key] = ne
}

// remove_attr removes the attribute name from the element, if it has it.
pub fn (mut e Edit) remove_attr(n ENode, name string) ! {
	e.check(n, 'remove_attr')!
	if !n.has_attr(name) {
		return
	}
	mut ne := e.nodes[n.key] or { NodeEdit{} }
	ne.attrs << AttrChange{name, none}
	e.nodes[n.key] = ne
}

// insert parses xml, an element (whitespace, comments and processing instructions around it are
// left out), and puts it under parent as its child element number index. It is read in the
// namespaces in scope where it is put, so a prefix it uses must be bound there or in it.
pub fn (mut e Edit) insert(parent ENode, index int, xml string) !ENode {
	e.check(parent, 'insert')!
	mut d := parse_string(xml)!
	scope := e.scope_in(parent.key)
	if p := unbound_prefix(d, scope) {
		d.free()
		return error('insert: the prefix `${p}` is not bound in the fragment or where it goes')
	}
	e.pieces << Piece{
		doc:   d
		root:  d.root()
		owned: true
		scope: scope
	}
	k := ekey(u32(e.pieces.len - 1), d.root())
	e.put(k, parent.key, index) or {
		e.drop_last_piece()
		return err
	}
	return ENode{e, k}
}

// insert_copy puts a copy of element src, from any document, under parent as its child element
// number index. It keeps the namespaces it has where it is; src's document must outlive the edit
// set.
pub fn (mut e Edit) insert_copy(parent ENode, index int, src Node) !ENode {
	e.check(parent, 'insert_copy')!
	if src.i == no_node || !src.doc.is_element(src.i) {
		return error('insert_copy: the source is not an element')
	}
	e.pieces << Piece{
		doc:  src.doc
		root: src.i
	}
	k := ekey(u32(e.pieces.len - 1), src.i)
	e.put(k, parent.key, index) or {
		e.pieces.delete_last()
		return err
	}
	return ENode{e, k}
}

// unbound_prefix is a prefix that an element or attribute name of d uses and that neither d's
// declarations in scope there nor scope bind.
fn unbound_prefix(d &Doc, scope map[string]string) ?string {
	for k in 1 .. d.len() {
		j := u32(k)
		if !d.is_element(j) {
			continue
		}
		mut names := [d.name(j)]
		lo, hi := d.attr_range(j)
		for a := lo; a < hi; a++ {
			if !is_ns_decl_name(d.attr_name(a)) {
				names << d.attr_name(a)
			}
		}
		for name in names {
			colon := name.index(':') or { continue }
			p := name[..colon]
			if p == 'xml' || (scope[p] or { '' }) != '' || d.binds(j, p) {
				continue
			}
			return p
		}
	}
	return none
}

// binds reports whether element i or one above it declares the prefix p.
fn (d &Doc) binds(i u32, p string) bool {
	decl := 'xmlns:' + p
	mut j := i
	for j != no_node {
		lo, hi := d.attr_range(j)
		for a := lo; a < hi; a++ {
			if d.attr_name(a) == decl {
				return d.attr_raw(a) != ''
			}
		}
		j = d.parent[j]
	}
	return false
}

fn (mut e Edit) drop_last_piece() {
	mut d := e.pieces.last().doc
	d.free()
	e.pieces.delete_last()
}

// remove takes the element out of the document. It can be put back with `place`.
pub fn (mut e Edit) remove(n ENode) ! {
	e.check(n, 'remove')!
	if n.key == ekey(0, 1) {
		return error('remove: the root element cannot be removed')
	}
	e.detach(n.key)
}

// place puts an element that is not in the document (removed, or inside a removed one) under
// parent, as its child element number index.
pub fn (mut e Edit) place(n ENode, parent ENode, index int) ! {
	e.check_node(n, 'place')!
	if e.in_tree(n.key) {
		return error('place: <${n.name()}> is in the document; remove it first, or move it')
	}
	e.relocate(n, parent, index, 'place')!
}

// move puts the element under parent as its child element number index, from wherever it is: in
// the document or not. Nothing changes if it cannot.
pub fn (mut e Edit) move(n ENode, parent ENode, index int) ! {
	e.check_node(n, 'move')!
	if n.key == ekey(0, 1) {
		return error('move: the root element cannot be moved')
	}
	e.relocate(n, parent, index, 'move')!
}

// relocate checks that n can go under parent at index, which counts parent's child elements
// without n, then takes n from where it is and puts it there.
fn (mut e Edit) relocate(n ENode, parent ENode, index int, what string) ! {
	e.check(parent, what)!
	// an element cannot go under itself
	mut a := parent.key
	for a != no_key {
		if a == n.key {
			return error('${what}: <${n.name()}> cannot go inside itself')
		}
		a = e.parent_of(a)
	}
	list := e.kid_list(parent.key)
	count := if e.parent_of(n.key) == parent.key { list.len - 1 } else { list.len }
	if index < 0 || index > count {
		return error('${what}: index ${index} is out of range: <${parent.name()}> has ${count} child elements')
	}
	e.detach(n.key)
	e.put(n.key, parent.key, index)!
}

// detach takes k from where it is: out of the elements put under its parent, or out of its
// original place.
fn (mut e Edit) detach(k u64) {
	mut ne := e.nodes[k] or { NodeEdit{} }
	if ne.placed {
		e.kid_left(ne.parent, k)
		mut pe := e.nodes[ne.parent] or { NodeEdit{} }
		mut group := pe.ins[ne.anchor] or { []u64{} }
		group.delete(group.index(k))
		if group.len == 0 {
			pe.ins.delete(ne.anchor)
		} else {
			pe.ins[ne.anchor] = group
		}
		e.nodes[ne.parent] = pe
		ne.placed = false
		ne.parent = no_key
		ne.anchor = no_key
	} else if !ne.detached {
		op := e.original_parent(k)
		if op != no_key {
			e.kid_left(op, k)
			mut pe := e.nodes[op] or { NodeEdit{} }
			pe.lost++
			e.nodes[op] = pe
		}
	}
	ne.detached = true
	e.nodes[k] = ne
}

// put files k, which is detached, under p before what is now its child element number index.
fn (mut e Edit) put(k u64, p u64, index int) ! {
	mut list := e.kid_list(p)
	if index < 0 || index > list.len {
		return error('index ${index} is out of range: <${e.doc_of(p).name(kindex(p))}> has ${list.len} child elements')
	}
	mut pe := e.nodes[p] or { NodeEdit{} }
	mut anchor := no_key
	mut before := no_key // a node put there already that k goes before
	if index < list.len {
		target := list[index]
		te := e.nodes[target] or { NodeEdit{} }
		if te.placed {
			anchor = te.anchor
			before = target
		} else {
			anchor = target
		}
	}
	mut group := pe.ins[anchor] or { []u64{} }
	if before == no_key {
		group << k
	} else {
		group.insert(group.index(before), k)
	}
	pe.ins[anchor] = group
	e.nodes[p] = pe
	list.insert(index, k)
	e.kid_lists[p] = list
	mut ne := e.nodes[k] or { NodeEdit{} }
	ne.placed = true
	ne.parent = p
	ne.anchor = anchor
	e.nodes[k] = ne
}

// --- writing --------------------------------------------------------------------------------

// write writes the edited document as XML to w.
pub fn (e &Edit) write(mut w io.Writer) ! {
	mut em := emitter_to(e.doc, mut w, e.plan())
	em.walk(0)!
	em.flush()!
}

// write_file writes the edited document to path, as `Doc.write_file` does.
pub fn (e &Edit) write_file(path string) ! {
	write_file_with(e.doc, path, e.plan())!
}

// xml is the edited document as a string.
pub fn (e &Edit) xml() string {
	mut em := emitter_in(e.doc, e.plan(), e.doc.src_len + 64)
	em.walk(0) or { return '' }
	em.settle() or { return '' }
	return em.buf.str()
}

// EditPlan writes the edited document: what no edit touched is copied, an element whose own
// attributes, text or children changed is written by `write_element`, and the elements above
// one are walked.
struct EditPlan {
	e       &Edit
	touched map[u64]bool // elements whose own start tag or content changed
	dirty   map[u64]bool // those and every element above them, in their pieces
}

fn (e &Edit) plan() EditPlan {
	mut touched := map[u64]bool{}
	mut dirty := map[u64]bool{}
	for k, ne in e.nodes {
		if ne.runs != none || ne.attrs.len > 0 || ne.ins.len > 0 || ne.lost > 0 {
			touched[k] = true
			mut a := k
			for a != no_key && a !in dirty {
				dirty[a] = true
				a = e.original_parent(a)
			}
		}
	}
	return EditPlan{
		e:       e
		touched: touched
		dirty:   dirty
	}
}

fn (p EditPlan) how(i u32) How {
	k := ekey(0, i)
	if k in p.touched {
		return .write
	}
	if k in p.dirty {
		return .content
	}
	return .whole
}

fn (p EditPlan) write(mut em Emitter, i u32) ! {
	em.write_element(p, ekey(0, i), []string{})!
}

// edited_child writes an original child c of an element being written.
fn (mut em Emitter) edited_child(p EditPlan, c u64) ! {
	if kpiece(c) == 0 {
		em.node(kindex(c))!
		return
	}
	d := p.e.doc_of(c)
	i := kindex(c)
	if d.is_element(i) && c in p.dirty {
		em.write_element(p, c, []string{})!
		return
	}
	a, b := d.span(i)
	em.copy_in(d, a, b)!
}

// placed writes k, put where it is by an insert or a move, with the namespace declarations that
// keep its names what they were.
fn (mut em Emitter) placed(p EditPlan, k u64) ! {
	decls := p.e.carried_decls(k)
	if k in p.dirty {
		em.write_element(p, k, decls)!
		return
	}
	d := p.e.doc_of(k)
	i := kindex(k)
	a, b := d.span(i)
	if decls.len == 0 {
		em.copy_in(d, a, b)!
		return
	}
	after_name := d.src_off[i] + 1 + u32(d.name(i).len)
	em.copy_in(d, a, after_name)!
	em.put(decls.join(''))!
	em.copy_in(d, after_name, b)!
}

// write_element writes element k with its edits: its start tag with the attribute changes (and
// decls, declarations to add), then its content: the bytes between its children kept, removed
// children left out with the indentation before them, inserted ones each after the indentation
// of the child they go before (or of the last child), and its text replaced.
fn (mut em Emitter) write_element(p EditPlan, k u64, decls []string) ! {
	e := p.e
	d := e.doc_of(k)
	i := kindex(k)
	ne := e.nodes[k] or { NodeEdit{} }
	ste := d.start_tag_end(i)
	if d.self_closing(ste) {
		// `<a/>`: content only from the edits, so whether there is any is known once written
		mut body := emitter_in(em.d, em.plan, 64)
		body.edited_content(p, k, ne, ste, ste)!
		body.settle()!
		if body.buf.len == 0 {
			em.start_tag(d, i, ne.attrs, decls, ste, true)!
			return
		}
		em.start_tag(d, i, ne.attrs, decls, ste, false)!
		em.put(body.buf.str())!
		em.put('</${d.name(i)}>')!
		return
	}
	em.start_tag(d, i, ne.attrs, decls, ste, false)!
	end_tag_lo := d.end_tag_at(d.content_end(i, ste))
	em.edited_content(p, k, ne, ste, end_tag_lo)!
	em.copy_in(d, end_tag_lo, d.close_after(i, end_tag_lo))!
}

// content_end is where the last child of i ends, or its text, or its start tag (ste): the end
// tag is the first one after it.
fn (d &Doc) content_end(i u32, ste u32) u32 {
	if i + 1 < d.end[i] {
		return d.span_end(d.last_child_node(i))
	}
	if d.text_len[i] != 0 {
		return d.text_end(i)
	}
	return ste
}

// last_child_node is element i's last child node, text or element; i has one.
fn (d &Doc) last_child_node(i u32) u32 {
	mut c := i + 1
	mut last := c
	for c < d.end[i] {
		last = c
		c = d.end[c]
	}
	return last
}

// start_tag writes element i's start tag with the attribute changes, decls after its name, and
// `/>` or `>` as closed says. What no change touched is copied.
fn (mut em Emitter) start_tag(d &Doc, i u32, changes []AttrChange, decls []string, ste u32, closed bool) ! {
	after_name := d.src_off[i] + 1 + u32(d.name(i).len)
	if changes.len == 0 && decls.len == 0 && (closed || !d.self_closing(ste)) {
		em.copy_in(d, d.src_off[i], ste)!
		return
	}
	final := final_attrs(d, i, changes)
	em.copy_in(d, d.src_off[i], after_name)!
	if decls.len > 0 {
		em.put(decls.join(''))!
	}
	mut pos := after_name // copied up to here
	lo, hi := d.attr_range(i)
	mut entry := map[int]int{} // an original attribute -> its entry in final
	for k, f in final {
		if f.src >= 0 {
			entry[f.src] = k
		}
	}
	for a := lo; a < hi; a++ {
		vend := d.attr_off[a] + d.attr_len[a] + 1 // past the closing quote
		k := entry[int(a)] or { -1 }
		if k < 0 {
			// removed, with the whitespace before it
			em.copy_in(d, pos, d.attr_lead(a))!
			pos = vend
		} else if final[k].changed {
			// the value replaced, between the quote it had if it can be
			q := attr_quote(final[k].value, d.attr_source_quote(a))
			em.copy_in(d, pos, d.attr_off[a] - 1)!
			em.put(q.ascii_str() + escape_attr(final[k].value, q) + q.ascii_str())!
			pos = vend
		} else {
			em.copy_in(d, pos, vend)!
			pos = vend
		}
	}
	for f in final {
		if f.src < 0 {
			q := attr_quote(f.value, `"`)
			em.put(' ${f.name}=${q.ascii_str()}${escape_attr(f.value, q)}${q.ascii_str()}')!
		}
	}
	if !closed && d.self_closing(ste) {
		// `/>` becomes `>`: what was before the slash is kept
		em.copy_in(d, pos, ste - 2)!
		em.put('>')!
	} else {
		em.copy_in(d, pos, ste)!
	}
}

// attr_lead is where attribute a starts, with the whitespace before it.
fn (d &Doc) attr_lead(a u32) u32 {
	mut k := int(d.attr_off[a]) - 2 // before the opening quote
	for is_ws(unsafe { d.src[k] }) {
		k--
	}
	k-- // the `=`
	for is_ws(unsafe { d.src[k] }) {
		k--
	}
	k -= d.attr_name(a).len - 1 // the name's first byte
	for is_ws(unsafe { d.src[k - 1] }) {
		k--
	}
	return u32(k)
}

// edited_content writes the content of element k, lo .. hi of its document: see write_element.
// Text that was set is written run by run, each after as many child elements as its slot says,
// in place of the text the element had; whitespace the parser left out is never written next to
// text, where it would join it.
fn (mut em Emitter) edited_content(p EditPlan, k u64, ne NodeEdit, lo u32, hi u32) ! {
	e := p.e
	d := e.doc_of(k)
	i := kindex(k)
	pc := kpiece(k)
	mut w := ContentWriter{
		runs:  ne.runs or { []TextRun{} }
		set:   ne.runs != none
		cdata: d.first_text_is_cdata(i)
	}
	mut pos := lo
	mut indent_last := ''
	// Each original child, after the bytes before it and what was put before it.
	mut c := d.first_child(i)
	for c != no_node {
		ck := ekey(pc, c)
		start := d.span_start(c)
		ind := ws_suffix_start(d, pos, start)
		indent := unsafe { tos(d.src + ind, int(start - ind)) }
		if d.is_element(c) {
			indent_last = indent
		}
		if w.text_last {
			pos = ws_prefix_end(d, pos, ind)
		}
		if pos < ind {
			em.copy_in(d, pos, ind)!
			w.text_last = false
		}
		for x in ne.ins[ck] or { [] } {
			em.runs_before(mut w)!
			if !w.text_last {
				em.put(indent)!
			}
			em.placed(p, x)!
			w.element_done()
		}
		if d.is_text(c) {
			if !w.set {
				em.copy_in(d, ind, d.span_end(c))!
				w.text_last = true
			}
		} else if !e.detached(ck) {
			em.runs_before(mut w)!
			if !w.text_last {
				em.copy_in(d, ind, start)!
			}
			em.edited_child(p, ck)!
			w.element_done()
		}
		pos = d.span_end(c)
		c = d.next_sibling(c)
	}
	// The rest: text that is the element's only content, comments, and the whitespace before the
	// end tag; what was put at the end goes before that whitespace.
	if w.text_last {
		pos = ws_prefix_end(d, pos, hi)
	}
	mut ws := ws_suffix_start(d, pos, hi)
	if d.text_len[i] != 0 {
		tlo := d.text_off[i] - if d.is_cdata(i) { u32(9) } else { 0 }
		thi := d.text_end(i)
		if ws < thi {
			ws = thi
		}
		if w.set {
			em.copy_in(d, pos, tlo)!
			em.runs_before(mut w)!
			if thi < ws {
				em.copy_in(d, thi, ws)!
				w.text_last = false
			}
		} else {
			em.copy_in(d, pos, ws)!
			w.text_last = ws == thi
		}
	} else if pos < ws {
		em.copy_in(d, pos, ws)!
		w.text_last = false
	}
	for x in ne.ins[no_key] or { [] } {
		em.runs_before(mut w)!
		if !w.text_last {
			em.put(indent_last)!
		}
		em.placed(p, x)!
		w.element_done()
	}
	w.count = max_int
	em.runs_before(mut w)!
	if !w.text_last {
		em.copy_in(d, ws, hi)!
	}
}

// ContentWriter is where edited_content is in the element's content: the runs of a text that was
// set and how many are written, how many child elements are, and whether text was written last.
struct ContentWriter {
	runs  []TextRun
	set   bool
	cdata bool // the element's text was CDATA, and the new text is too
mut:
	next      int // the next run to write
	count     int // child elements written
	text_last bool
}

fn (mut w ContentWriter) element_done() {
	w.count++
	w.text_last = false
}

// runs_before writes the runs that come before the next child element.
fn (mut em Emitter) runs_before(mut w ContentWriter) ! {
	for w.next < w.runs.len && w.runs[w.next].slot <= w.count {
		em.text(w.runs[w.next].text, w.cdata)!
		w.next++
		w.text_last = true
	}
}

// first_text_is_cdata reports whether the first run of element i's own text is a CDATA section.
fn (d &Doc) first_text_is_cdata(i u32) bool {
	if d.text_len[i] != 0 {
		return d.is_cdata(i)
	}
	mut c := d.first_child(i)
	for c != no_node {
		if d.is_text(c) {
			return d.is_cdata(c)
		}
		c = d.next_sibling(c)
	}
	return false
}

// ws_prefix_end is where the whitespace that starts lo .. hi of d's source ends.
fn ws_prefix_end(d &Doc, lo u32, hi u32) u32 {
	mut k := lo
	for k < hi && is_ws(unsafe { d.src[k] }) {
		k++
	}
	return k
}

// ws_suffix_start is where the whitespace that ends lo .. hi of d's source starts.
fn ws_suffix_start(d &Doc, lo u32, hi u32) u32 {
	mut k := hi
	for k > lo && is_ws(unsafe { d.src[k - 1] }) {
		k--
	}
	return k
}

// --- namespaces -----------------------------------------------------------------------------

// carried_decls are the namespace declarations an inserted or moved element k needs where it is:
// for each prefix bound differently in the scope of its new parent than where it was read, its
// binding there (` xmlns:p="uri"`, or ` xmlns=""` for a default namespace it did not have).
fn (e &Edit) carried_decls(k u64) []string {
	ne := e.nodes[k] or { return [] }
	if !ne.placed {
		return []
	}
	return scope_decls(e.source_scope(k), e.scope_in(ne.parent), e.own_decls(k))
}

// own_decls are the namespace declarations element k makes itself, as edited: prefix ('' for
// the default) -> URI.
fn (e &Edit) own_decls(k u64) map[string]string {
	mut out := map[string]string{}
	for a in ENode{e, k}.attrs() {
		if is_ns_decl_name(a.name) {
			out[decl_prefix(a.name)] = a.value
		}
	}
	return out
}

// source_scope is the bindings in scope where k was read: the declarations of the elements
// above it in its document as it was, and for a fragment, those where it was first put.
fn (e &Edit) source_scope(k u64) map[string]string {
	d := e.doc_of(k)
	mut out := e.pieces[kpiece(k)].scope.clone()
	for p, u in d.bindings_above(kindex(k)) {
		out[p] = u
	}
	return out
}

// decl_prefix is the prefix a namespace declaration binds: '' for `xmlns`, p for `xmlns:p`.
@[inline]
fn decl_prefix(name string) string {
	return if name == 'xmlns' { '' } else { name['xmlns:'.len..] }
}

// scope_in is the bindings in scope inside element k of the edited document: its own
// declarations, then those of where it was read if it was put where it is (inserted or moved),
// else its parent's.
fn (e &Edit) scope_in(k u64) map[string]string {
	mut out := e.own_decls(k)
	ne := e.nodes[k] or { NodeEdit{} }
	pc := kpiece(k)
	outer := if ne.placed {
		e.source_scope(k)
	} else {
		p := e.parent_of(k)
		if p == no_key {
			if pc != 0 && kindex(k) == e.pieces[pc].root {
				map[string]string{}
			} else {
				e.source_scope(k)
			}
		} else {
			e.scope_in(p)
		}
	}
	for p, u in outer {
		if p !in out {
			out[p] = u
		}
	}
	return out
}
