module flatxml

import strconv

// Node is a handle on an element of a document. A missing node is a valid, empty handle: every
// lookup on it gives another empty one, and every read gives the empty value or the default
// asked for, so a chain of lookups needs no check at every step:
//
//   port := doc.root_node().child('ports').child('port')
//   speed := port.attr_int('speed', 100)
//
// A handle is a pointer and an index; it allocates nothing, and neither do the iterators.
pub struct Node {
pub:
	doc &Doc = unsafe { nil }
	i   u32 // the node's index in doc; no_node for an empty handle
}

// node is a handle on node i of d.
@[inline]
pub fn (d &Doc) node(i u32) Node {
	return Node{d, i}
}

// root_node is the root element.
@[inline]
pub fn (d &Doc) root_node() Node {
	return Node{d, d.root()}
}

// ok reports whether the handle names a node.
@[inline]
pub fn (n Node) ok() bool {
	return n.i != no_node
}

// tag is the element's name id; text_tag for none.
@[inline]
pub fn (n Node) tag() u32 {
	return if n.i == no_node { text_tag } else { n.doc.tag[n.i] }
}

// name is the element's name; '' for none.
pub fn (n Node) name() string {
	return if n.i == no_node { '' } else { n.doc.name(n.i) }
}

// local_id is the name id of the element's local name (`Doc.local_id`): the same id for `ar:X`
// and `X`. Needs namespaces resolved; text_tag for none.
pub fn (n Node) local_id() u32 {
	return if n.i == no_node { text_tag } else { n.doc.local_id(n.i) }
}

// local_name is the element's name without its prefix; '' for none. Needs namespaces resolved.
pub fn (n Node) local_name() string {
	return if n.i == no_node { '' } else { n.doc.local_name(n.i) }
}

// is reports whether the element is named name.
pub fn (n Node) is(name string) bool {
	return n.i != no_node && n.doc.name(n.i) == name
}

// text is the element's text, decoded; '' for none. An element with child elements has the text
// beside them, joined (`Doc.text_content`).
pub fn (n Node) text() string {
	if n.i == no_node {
		return ''
	}
	return if n.doc.has_text_children(n.i) { n.doc.text_content(n.i) } else { n.doc.text(n.i) }
}

// TextRun is a run of an element's own text: its text, decoded, and its slot, the number of
// child elements before it.
pub struct TextRun {
pub:
	slot int
	text string
}

// text_runs is the element's own text, not its children's, run by run: one run at slot 0 for an
// element whose only content is text, a run per text node beside child elements, none for no
// text.
pub fn (n Node) text_runs() []TextRun {
	if n.i == no_node {
		return []
	}
	if !n.doc.has_text_children(n.i) {
		return if n.doc.text_len[n.i] == 0 { []TextRun{} } else { [TextRun{0, n.doc.text(n.i)}] }
	}
	mut out := []TextRun{}
	mut slot := 0
	mut c := n.doc.first_child(n.i)
	for c != no_node {
		if n.doc.tag[c] == text_tag {
			out << TextRun{slot, n.doc.text(c)}
		} else {
			slot++
		}
		c = n.doc.next_sibling(c)
	}
	return out
}

// attr is the value of the attribute name, decoded; '' when there is none.
pub fn (n Node) attr(name string) string {
	if n.i == no_node {
		return ''
	}
	return n.doc.attr(n.i, name) or { '' }
}

// has_attr reports whether the element has the attribute name; its value is not read.
pub fn (n Node) has_attr(name string) bool {
	if n.i == no_node {
		return false
	}
	id := n.doc.tab.id(name) or { return false }
	lo, hi := n.doc.attr_range(n.i)
	for a := lo; a < hi; a++ {
		if n.doc.attr_tag[a] == id {
			return true
		}
	}
	return false
}

// parent is the parent element; empty for the root.
pub fn (n Node) parent() Node {
	if n.i == no_node {
		return n
	}
	p := n.doc.parent[n.i]
	return Node{n.doc, if p == 0 { no_node } else { p }}
}

// first is the first child element.
pub fn (n Node) first() Node {
	if n.i == no_node {
		return n
	}
	mut c := n.doc.first_child(n.i)
	for c != no_node && !n.doc.is_element(c) {
		c = n.doc.next_sibling(c)
	}
	return Node{n.doc, c}
}

// next is the next sibling element.
pub fn (n Node) next() Node {
	if n.i == no_node {
		return n
	}
	mut c := n.doc.next_sibling(n.i)
	for c != no_node && !n.doc.is_element(c) {
		c = n.doc.next_sibling(c)
	}
	return Node{n.doc, c}
}

// child is the first child element named name.
pub fn (n Node) child(name string) Node {
	if n.i == no_node {
		return n
	}
	id := n.doc.tab.id(name) or { return Node{n.doc, no_node} }
	return n.child_id(id)
}

// child_id is the first child element with name id tag: child without the name lookup, for loops.
// text_tag means any element, as for children_id.
pub fn (n Node) child_id(tag u32) Node {
	if n.i == no_node || tag == text_tag {
		return n.first()
	}
	return Node{n.doc, n.doc.child(n.i, tag)}
}

// pos is the node's position, `path:line:column`.
pub fn (n Node) pos() string {
	return if n.i == no_node { '' } else { n.doc.pos(n.i) }
}

// --- typed reads ------------------------------------------------------------------------------
// Each reads the trimmed text (or attribute value) and gives def when there is none or it does
// not read as the type.

// int is the element's text as an integer.
pub fn (n Node) int(def i64) i64 {
	return read_int(n.text(), def)
}

// f64 is the element's text as a number.
pub fn (n Node) f64(def f64) f64 {
	return read_f64(n.text(), def)
}

// bool is the element's text as a boolean: true or 1, false or 0.
pub fn (n Node) bool(def bool) bool {
	return read_bool(n.text(), def)
}

// attr_int is the attribute name as an integer.
pub fn (n Node) attr_int(name string, def i64) i64 {
	return read_int(n.attr(name), def)
}

// attr_f64 is the attribute name as a number.
pub fn (n Node) attr_f64(name string, def f64) f64 {
	return read_f64(n.attr(name), def)
}

// attr_bool is the attribute name as a boolean.
pub fn (n Node) attr_bool(name string, def bool) bool {
	return read_bool(n.attr(name), def)
}

fn read_int(s string, def i64) i64 {
	t := s.trim_space()
	if t == '' {
		return def
	}
	mut k := 0
	if t[0] == `-` || t[0] == `+` {
		k = 1
	}
	if k == t.len {
		return def
	}
	for c in t[k..] {
		if !c.is_digit() {
			return def
		}
	}
	return t.parse_int(10, 64) or { def }
}

// read_f64 reads XML's decimal and float forms: an optional sign, digits with an optional
// fraction, and an optional exponent.
fn read_f64(s string, def f64) f64 {
	t := s.trim_space()
	mut k := 0
	if k < t.len && (t[k] == `-` || t[k] == `+`) {
		k++
	}
	mut digits := 0
	for k < t.len && t[k].is_digit() {
		k++
		digits++
	}
	if k < t.len && t[k] == `.` {
		k++
		for k < t.len && t[k].is_digit() {
			k++
			digits++
		}
	}
	if digits == 0 {
		return def
	}
	if k < t.len && (t[k] == `e` || t[k] == `E`) {
		k++
		if k < t.len && (t[k] == `-` || t[k] == `+`) {
			k++
		}
		if k == t.len || !t[k].is_digit() {
			return def
		}
		for k < t.len && t[k].is_digit() {
			k++
		}
	}
	if k != t.len {
		return def
	}
	return strconv.atof64(t) or { def }
}

fn read_bool(s string, def bool) bool {
	return match s.trim_space() {
		'true', '1' { true }
		'false', '0' { false }
		else { def }
	}
}

// --- iteration --------------------------------------------------------------------------------

// Children iterates over child elements, all of them or those with one name id. A child's next
// sibling is where its subtree ends, until the parent's does: one array read per child.
pub struct Children {
	doc  &Doc = unsafe { nil }
	tag  u32 // text_tag for every element
	stop u32 // the parent's end
mut:
	cur u32
}

// children are the child elements: `for c in n.children() { ... }`.
pub fn (n Node) children() Children {
	return n.children_id(text_tag)
}

// children_named are the child elements named name.
pub fn (n Node) children_named(name string) Children {
	id := if n.i == no_node { u32(0) } else { n.doc.tab.id(name) or { u32(0) } }
	if id == 0 {
		return Children{
			doc: n.doc
		}
	}
	return n.children_id(id)
}

// children_id are the child elements with name id tag (text_tag: all of them).
pub fn (n Node) children_id(tag u32) Children {
	if n.i == no_node {
		return Children{
			doc: n.doc
		}
	}
	return Children{
		doc:  n.doc
		tag:  tag
		stop: n.doc.end[n.i]
		cur:  n.i + 1
	}
}

@[direct_array_access]
pub fn (mut it Children) next() ?Node {
	for it.cur < it.stop {
		c := it.cur
		it.cur = it.doc.end[c]
		t := it.doc.tag[c]
		if t != text_tag && (it.tag == text_tag || t == it.tag) {
			return Node{it.doc, c}
		}
	}
	return none
}

// Descendants iterates over the elements below a node with one name id, in document order: a
// scan of one array.
pub struct Descendants {
	doc &Doc = unsafe { nil }
	tag u32
	end u32
mut:
	cur u32
}

// descendants are the elements below n named name, at any depth.
pub fn (n Node) descendants(name string) Descendants {
	id := if n.i == no_node { u32(0) } else { n.doc.tab.id(name) or { u32(0) } }
	if id == 0 {
		return Descendants{
			doc: n.doc
		}
	}
	return n.descendants_id(id)
}

// descendants_id are the elements below n with name id tag (text_tag: all of them).
pub fn (n Node) descendants_id(tag u32) Descendants {
	if n.i == no_node {
		return Descendants{
			doc: n.doc
		}
	}
	return Descendants{
		doc: n.doc
		tag: tag
		cur: n.i + 1
		end: n.doc.end[n.i]
	}
}

@[direct_array_access]
pub fn (mut it Descendants) next() ?Node {
	for it.cur < it.end {
		c := it.cur
		it.cur++
		t := it.doc.tag[c]
		if t != text_tag && (t == it.tag || it.tag == text_tag) {
			return Node{it.doc, c}
		}
	}
	return none
}

// --- paths ------------------------------------------------------------------------------------

// Path is a path of child element names, `a/b/c`, compiled once to name ids so finding it costs
// no hashing. It remembers its table: used on a document with another table, or after a name it
// did not find has been added to its own, its names are looked up again.
pub struct Path {
	names []string
	ids   []u32
	tab   &Names = unsafe { nil }
	known int // the table's length when the ids were looked up
}

const no_name = u32(0xFFFF_FFFF)

// path compiles p (names separated by `/`, an expanded name's `{uri}` read whole) against the
// table: a set's table serves every document of the set.
pub fn (t &Names) path(p string) Path {
	names := split_names(p, `/`).filter(it != '')
	return Path{
		names: names
		ids:   t.ids_of(names)
		tab:   t
		known: t.names.len
	}
}

// split_names splits s at sep, except inside an expanded name's braces: `{http://x/e}id/b` is
// two names.
fn split_names(s string, sep u8) []string {
	mut out := []string{}
	mut depth := 0
	mut start := 0
	for i, c in s {
		if c == `{` {
			depth++
		} else if c == `}` && depth > 0 {
			depth--
		} else if c == sep && depth == 0 {
			out << s[start..i]
			start = i + 1
		}
	}
	out << s[start..]
	return out
}

// index_outside is the index of the first c in s outside an expanded name's braces; -1 for none.
fn index_outside(s string, c u8) int {
	mut depth := 0
	for i, b in s {
		if b == `{` {
			depth++
		} else if b == `}` && depth > 0 {
			depth--
		} else if b == c && depth == 0 {
			return i
		}
	}
	return -1
}

fn (t &Names) ids_of(names []string) []u32 {
	return names.map(t.id(it) or { no_name })
}

// ids_for is p's ids in table t.
fn (p &Path) ids_for(t &Names) []u32 {
	if voidptr(t) == voidptr(p.tab) && (t.names.len == p.known || no_name !in p.ids) {
		return p.ids
	}
	return t.ids_of(p.names)
}

// find is the first element, in document order, at path p below n.
pub fn (n Node) find(p Path) Node {
	return n.find_in(p, no_local)
}

// at is find with the path compiled on the spot: for a one-off lookup.
pub fn (n Node) at(p string) Node {
	if n.i == no_node {
		return n
	}
	return n.find(n.doc.tab.path(p))
}

// find_in is find, each element named as a merge with local namespace `local` names it
// (`Doc.name_in`); no_local is find itself.
fn (n Node) find_in(p Path, local u32) Node {
	if n.i == no_node || p.names.len == 0 {
		return Node{n.doc, no_node}
	}
	return Node{n.doc, n.doc.find_from(n.i, p.ids_for(n.doc.tab), 0, local)}
}

// find_all_in is find_all, each element named as find_in names it.
fn (n Node) find_all_in(p Path, local u32) []Node {
	mut out := []Node{}
	if n.i != no_node && p.names.len > 0 {
		n.doc.collect(n.i, p.ids_for(n.doc.tab), 0, local, mut out)
	}
	return out
}

// find_all is every element at path p below n, in document order.
pub fn (n Node) find_all(p Path) []Node {
	mut out := []Node{}
	if n.i != no_node && p.names.len > 0 {
		n.doc.collect(n.i, p.ids_for(n.doc.tab), 0, no_local, mut out)
	}
	return out
}

// find_from and collect walk a path of name ids below i, each element named by name_in.
fn (d &Doc) find_from(i u32, ids []u32, k int, local u32) u32 {
	mut c := d.first_child(i)
	for c != no_node {
		if d.name_in(c, local) == ids[k] {
			if k == ids.len - 1 {
				return c
			}
			found := d.find_from(c, ids, k + 1, local)
			if found != no_node {
				return found
			}
		}
		c = d.next_sibling(c)
	}
	return no_node
}

fn (d &Doc) collect(i u32, ids []u32, k int, local u32, mut out []Node) {
	mut c := d.first_child(i)
	for c != no_node {
		if d.name_in(c, local) == ids[k] {
			if k == ids.len - 1 {
				out << Node{d, c}
			} else {
				d.collect(c, ids, k + 1, local, mut out)
			}
		}
		c = d.next_sibling(c)
	}
}
