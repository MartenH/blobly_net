// flatxml — a non-validating XML parser that builds a flat tree.
//
// The tree is struct-of-arrays: node i is (tag[i], parent[i], end[i], ...), and nodes are
// stored in document order (preorder). That layout makes the links implicit:
//
//   first child of i   i + 1, if i + 1 < end[i]
//   next sibling of i  end[i], if end[i] < end[parent[i]]
//   subtree of i       the index range i .. end[i]
//
// so a node needs no child or sibling pointers, skipping a subtree is one read, and a scan
// over all elements of some kind is a linear walk over a u32 array.
//
// Node 0 is the document; the root element is node 1. Node 0 is never a child or a sibling,
// so `no_node` (0) doubles as "none" for the navigation functions.
//
// Text is never copied while parsing. Spans point into the source, which stays mapped for the
// life of the Doc, and entities are decoded only when text is read (`text`, `attr_value`).
// An element whose only content is text keeps that text on the element itself; text nodes
// exist only for mixed content (text beside child elements). Whitespace-only text between
// tags is dropped, except inside CDATA. Comments, processing instructions and the DOCTYPE
// are skipped. Names are interned to u32 ids, in a table a set of documents can share.
module flatxml

import sync.stdatomic as _

// Reserved name ids. Element names are interned from 2 up.
pub const text_tag = u32(0) // a text node
pub const doc_tag = u32(1) // node 0, the document
pub const no_node = u32(0)

@[heap]
pub struct Doc {
pub:
	path    string
	src     &u8 = unsafe { nil }
	src_len int
pub mut:
	// Nodes, in document order. Node 0 is the document.
	tag      []u32 // name id; text_tag for a text node
	parent   []u32
	end      []u32 // one past the last node in this subtree
	src_off  []u32 // offset of the element's `<`, or of a text node's first byte
	text_off []u32 // element: its text, when text is its only content; text node: its text
	text_len []u32
	attr_lo  []u32 // index of the node's first attribute; it owns attr_lo[i] .. attr_lo[i + 1]
	// Attributes, in document order.
	attr_tag []u32
	attr_off []u32 // span of the raw value, between the quotes
	attr_len []u32
	// Namespaces, filled by `resolve_namespaces`: each node's namespace id (0 for a text node and
	// for an element in no namespace) and each attribute's. The URIs are in the name table.
	ns      []u32
	attr_ns []u32
	// The interned names (shared by the documents of a set) and namespace URIs.
	tab &Names = unsafe { nil }
mut:
	// the line index `line_col` and `pos` answer from, built by the first of them and published
	// once (atomically: documents are read from several threads); nil until then
	lines      voidptr
	own_tab    bool // the table is this document's alone, and free() releases it
	mapped     bool
	keep_bytes []u8   // owns the source when it came from parse_bytes
	keep_str   string // ... or from parse_string
}

// parse_file maps the file at path and parses it.
pub fn parse_file(path string) !&Doc {
	ptr, len := map_file(path)!
	mut d := &Doc{
		path:    path
		src:     ptr
		src_len: len
		mapped:  true
	}
	d.parse() or {
		d.free()
		return err
	}
	return d
}

// parse_bytes parses data, which the Doc keeps a reference to. path is only used in messages.
pub fn parse_bytes(data []u8, path string) !&Doc {
	if data.len > max_src_len {
		return error('${path}: documents of 4 GiB or more are not supported (offsets are u32)')
	}
	mut d := &Doc{
		path:       path
		src:        data.data
		src_len:    data.len
		keep_bytes: data
	}
	d.parse()!
	return d
}

// parse_string parses s, which the Doc keeps a reference to.
pub fn parse_string(s string) !&Doc {
	if s.len > max_src_len {
		return error('documents of 4 GiB or more are not supported (offsets are u32)')
	}
	mut d := &Doc{
		path:     '<string>'
		src:      s.str
		src_len:  s.len
		keep_str: s
	}
	d.parse()!
	return d
}

// free releases the node arrays and unmaps the source. Strings returned by `text_raw`,
// `attr_raw` and the zero-copy cases of `text` and `attr_value` point into the source and
// must not be used afterwards.
pub fn (mut d Doc) free() {
	if d.mapped {
		unmap_file(d.src, d.src_len)
		d.mapped = false
	}
	unsafe {
		d.tag.free()
		d.parent.free()
		d.end.free()
		d.src_off.free()
		d.text_off.free()
		d.text_len.free()
		d.attr_lo.free()
		d.attr_tag.free()
		d.attr_off.free()
		d.attr_len.free()
		d.ns.free()
		d.attr_ns.free()
	}
	free_line_index(d.lines)
	d.lines = unsafe { nil }
	if d.own_tab {
		d.tab.free()
		d.own_tab = false
	}
}

// --- navigation ----------------------------------------------------------------------------

// len is the number of nodes, the document node included.
@[inline]
pub fn (d &Doc) len() int {
	return d.tag.len
}

// root is the root element.
@[inline]
pub fn (d &Doc) root() u32 {
	return 1
}

@[inline]
pub fn (d &Doc) is_element(i u32) bool {
	return d.tag[i] > doc_tag
}

@[inline]
pub fn (d &Doc) is_text(i u32) bool {
	return d.tag[i] == text_tag
}

// name is the element's name; '#text' for a text node, '#document' for node 0.
@[inline]
pub fn (d &Doc) name(i u32) string {
	return d.tab.names[d.tag[i]]
}

@[inline]
pub fn (d &Doc) first_child(i u32) u32 {
	if i + 1 < d.end[i] {
		return i + 1
	}
	return no_node
}

@[inline]
pub fn (d &Doc) next_sibling(i u32) u32 {
	e := d.end[i]
	if e < d.end[d.parent[i]] {
		return e
	}
	return no_node
}

// children lists the child nodes of i, text nodes included.
pub fn (d &Doc) children(i u32) []u32 {
	mut out := []u32{}
	mut c := d.first_child(i)
	for c != no_node {
		out << c
		c = d.next_sibling(c)
	}
	return out
}

// child is the first child element of i with the name id `tag`, or no_node.
@[direct_array_access]
pub fn (d &Doc) child(i u32, tag u32) u32 {
	stop := d.end[i]
	mut c := i + 1
	for c < stop {
		if d.tag[c] == tag {
			return c
		}
		c = d.end[c]
	}
	return no_node
}

// child_named is `child` by name.
pub fn (d &Doc) child_named(i u32, name string) u32 {
	id := d.name_id(name) or { return no_node }
	return d.child(i, id)
}

// --- text ----------------------------------------------------------------------------------

// text_raw is the node's text exactly as the source has it: entities are not decoded. For an
// element it is the element's text when text is its only content, else ''. Zero-copy.
@[inline]
pub fn (d &Doc) text_raw(i u32) string {
	n := d.text_len[i]
	if n == 0 {
		return ''
	}
	return unsafe { tos(d.src + d.text_off[i], int(n)) }
}

// text is `text_raw` with entity references and line endings decoded. It copies only when
// there is something to decode.
pub fn (d &Doc) text(i u32) string {
	raw := d.text_raw(i)
	cdata := d.is_cdata(i)
	if !needs_decode(raw, cdata) {
		return raw
	}
	return decode(raw, if cdata { .cdata } else { .text })
}

// is_cdata reports whether the node's text came from a CDATA section.
pub fn (d &Doc) is_cdata(i u32) bool {
	off := d.text_off[i]
	if d.text_len[i] == 0 || off < 9 {
		return false
	}
	return unsafe { C.memcmp(d.src + off - 9, c'<![CDATA[', 9) } == 0
}

// has_text_children reports whether i has mixed content: text nodes beside child elements.
pub fn (d &Doc) has_text_children(i u32) bool {
	mut c := d.first_child(i)
	for c != no_node {
		if d.tag[c] == text_tag {
			return true
		}
		c = d.next_sibling(c)
	}
	return false
}

// text_content is all text inside i, in document order, decoded and concatenated.
pub fn (d &Doc) text_content(i u32) string {
	if d.text_len[i] != 0 {
		return d.text(i)
	}
	mut parts := []string{}
	for j := i + 1; j < d.end[i]; j++ {
		if d.text_len[j] != 0 {
			parts << d.text(j)
		}
	}
	return parts.join('')
}

// --- attributes ----------------------------------------------------------------------------

// attr_range is the attributes of node i: the indexes lo .. hi.
@[inline]
pub fn (d &Doc) attr_range(i u32) (u32, u32) {
	lo := d.attr_lo[i]
	hi := if int(i) + 1 < d.attr_lo.len { d.attr_lo[i + 1] } else { u32(d.attr_tag.len) }
	return lo, hi
}

@[inline]
pub fn (d &Doc) attr_name(a u32) string {
	return d.tab.names[d.attr_tag[a]]
}

// attr_raw is the attribute's value as the source has it, between the quotes. Zero-copy.
@[inline]
pub fn (d &Doc) attr_raw(a u32) string {
	n := d.attr_len[a]
	if n == 0 {
		return ''
	}
	return unsafe { tos(d.src + d.attr_off[a], int(n)) }
}

// attr_value is the attribute's value with entities decoded and whitespace normalized as XML
// requires (a literal tab, newline or carriage return reads as a space).
pub fn (d &Doc) attr_value(a u32) string {
	raw := d.attr_raw(a)
	if !needs_attr_decode(raw) {
		return raw
	}
	return decode(raw, .attr)
}

// attr_by_id is the value of node i's attribute with the name id `tag`.
@[direct_array_access]
pub fn (d &Doc) attr_by_id(i u32, tag u32) ?string {
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if d.attr_tag[a] == tag {
			return d.attr_value(a)
		}
	}
	return none
}

// attr_named is the value of node i's attribute with id `id`, as written or as its identity
// (`attr_id`: `{uri}local` for one in a namespace), so a key names a namespaced attribute however
// a document spells its prefix.
pub fn (d &Doc) attr_named(i u32, id u32) ?string {
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if d.attr_tag[a] == id || d.attr_id(a) == id {
			return d.attr_value(a)
		}
	}
	return none
}

// attr is the value of node i's attribute `name`.
pub fn (d &Doc) attr(i u32, name string) ?string {
	id := d.name_id(name) or { return none }
	return d.attr_by_id(i, id)
}

// --- positions -----------------------------------------------------------------------------

// line_col is the 1-based line and column (in bytes) of node i. The first call scans the source
// for line starts once (`line_index`); every call then is a binary search, so a position per
// finding stays cheap however many findings a large file has.
pub fn (d &Doc) line_col(i u32) (int, int) {
	return d.lines().line_col(d.src_off[i])
}

// lines is the document's line index, built on first use. Two threads may both build it; the
// first to publish wins and the other's copy is dropped.
fn (d &Doc) lines() &LineIndex {
	slot := voidptr(&d.lines)
	p := C.atomic_load_ptr(slot)
	if p != unsafe { nil } {
		return unsafe { &LineIndex(p) }
	}
	built := &LineIndex{
		...d.line_index()
	}
	mut expected := unsafe { nil }
	if C.atomic_compare_exchange_strong_ptr(slot, voidptr(&expected), isize(built)) {
		return built
	}
	free_line_index(built)
	return unsafe { &LineIndex(C.atomic_load_ptr(slot)) }
}

// free_line_index releases a line index `lines` built (nil: nothing).
fn free_line_index(p voidptr) {
	if p == unsafe { nil } {
		return
	}
	unsafe {
		mut li := &LineIndex(p)
		li.starts.free()
		free(li)
	}
}

// pos is `path:line:col` of node i.
pub fn (d &Doc) pos(i u32) string {
	line, col := d.line_col(i)
	return '${d.path}:${line}:${col}'
}

fn line_col_at(src &u8, off int) (int, int) {
	mut line := 1
	mut line_start := 0
	for k in 0 .. off {
		if unsafe { src[k] } == `\n` {
			line++
			line_start = k + 1
		}
	}
	return line, off - line_start + 1
}

// LineIndex maps source offsets to lines with a binary search, for many lookups in one Doc.
pub struct LineIndex {
	starts []u32
}

// line_index scans the source once for line starts.
pub fn (d &Doc) line_index() LineIndex {
	mut starts := [u32(0)]
	mut k := 0
	for k < d.src_len {
		q := unsafe { &u8(C.memchr(voidptr(d.src + k), `\n`, usize(d.src_len - k))) }
		if isnil(q) {
			break
		}
		k = unsafe { int(q - d.src) } + 1
		starts << u32(k)
	}
	return LineIndex{
		starts: starts
	}
}

// line_col is the 1-based line and column of a source offset.
pub fn (li &LineIndex) line_col(off u32) (int, int) {
	mut lo := 0
	mut hi := li.starts.len - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if li.starts[mid] <= off {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo + 1, int(off - li.starts[lo]) + 1
}

// --- size ----------------------------------------------------------------------------------

// node_bytes is the memory the node and attribute arrays hold (used) and have allocated
// (reserved). Each node is 7 u32 and each attribute 3: 28 and 12 bytes.
pub fn (d &Doc) node_bytes() (i64, i64) {
	mut used := i64(0)
	mut reserved := i64(0)
	for a in [d.tag, d.parent, d.end, d.src_off, d.text_off, d.text_len, d.attr_lo, d.attr_tag,
		d.attr_off, d.attr_len] {
		used += i64(a.len) * 4
		reserved += i64(a.cap) * 4
	}
	return used, reserved
}

// text_node_count is how many nodes are text nodes (mixed content).
pub fn (d &Doc) text_node_count() int {
	mut n := 0
	for t in d.tag {
		if t == text_tag {
			n++
		}
	}
	return n
}
