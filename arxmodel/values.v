module arxmodel

import flatxml
import strings

// Values: the values of a merged model, one a line, `path = "text"`, by AUTOSAR path.
//
// A value is an element holding text and no element: its text. Its path is the AUTOSAR path of
// its nearest referrable ancestor, then `#` and the elements below that one down to it, as
// findings and diffs name elements (`/Pkg/Lamp#WATTS`). A value the merge identifies by its
// definition (an item of an identity role, or of the built-in rules' `by_definition`, such as an
// ECUC parameter or reference value) is named by its definition instead: its container's path,
// `/`, and the definition's last name (`/Pkg/LampCfg/Dim`), with its label as a key where it has
// one (`Dim[v1]`). The item's last element, when that holds text only, is the value itself and
// takes that path (the value comes last in such an item); its other parts follow a `#`
// (`/Pkg/LampCfg/Dim#IS-AUTO-VALUE`). A referrable element's SHORT-NAME is its path, not a value;
// attributes are not values; content the merge does not compare (structured comments) is left
// out. The text is the merged node's (its
// first fragment's), without surrounding white space.
//
// A pattern is a path glob, as the policy's filters take them (`*` one segment or part of one,
// `**` any segments, `#` matched only by `#` or `**`, a segment's key matched only by a pattern
// that gives one). A value is wanted when its path matches, or when the path of an element
// above it does: `/Pkg/LampCfg` gives every value of that container and its subcontainers.

// Value is one value of a merged model.
pub struct Value {
pub:
	path string
	text string
	node u32 // the merged node whose text it is
}

// line is the value as one line: `path = "text"`, the text a TOML basic string.
pub fn (v Value) line() string {
	return '${v.path} = ${quoted(v.text)}'
}

const hex_digits = '0123456789ABCDEF'

// quoted is s as a TOML basic string: `"`, `\` and control characters escaped.
fn quoted(s string) string {
	mut sb := strings.new_builder(s.len + 2)
	sb.write_u8(`"`)
	for c in s {
		match c {
			`"` {
				sb.write_string('\\"')
			}
			`\\` {
				sb.write_string('\\\\')
			}
			`\n` {
				sb.write_string('\\n')
			}
			`\r` {
				sb.write_string('\\r')
			}
			`\t` {
				sb.write_string('\\t')
			}
			else {
				if c < 0x20 || c == 0x7f {
					sb.write_string('\\u00')
					sb.write_u8(hex_digits[c >> 4])
					sb.write_u8(hex_digits[c & 15])
				} else {
					sb.write_u8(c)
				}
			}
		}
	}
	sb.write_u8(`"`)
	return sb.str()
}

// any_parent is an identity's parent that is any element (the built-in rules).
const any_parent = u32(0xFFFF_FFFF)

// ItemIdentity is how items of one kind are named by a definition: the element holding them
// (any_parent for any), and the paths below an item of its definition and its label, as name ids
// of the set's table.
struct ItemIdentity {
	parent u32
	def    IdPath
	label  IdPath
	// a role with no wrapper: its items are those whose merge rule keys by the definition first
	by_key string
}

// ValueWalk is one pass over a merged view collecting the values a pattern wants. The path of
// the node being visited is written into one builder, each segment's bounds beside it, and
// matched there: no string is made for a value unless it is wanted. A referrable element, or an
// item named by its definition, starts its path anew after the others (its container's path
// copied, then its name), so the segments of the wrappers above it stay as they were for their
// other children.
struct ValueWalk {
	view &flatxml.Merged = unsafe { nil }
	ix   &PathIndex
	pat  []string // the pattern's segments
	// per name id of the set's table: the item identities of elements of that name (several
	// roles may share an item name, under different parents)
	item_of [][]int
	idents  []ItemIdentity
	skip    []bool // per name id: content the merge does not compare
mut:
	sb     strings.Builder
	bounds []int // per segment written: its start and its end in sb
	// the path of the node being visited: sb[start..], its segments bounds[2 * seg0..]
	start int
	seg0  int
	// the nearest referrable element's (or named item's) path, likewise
	ref_lo int
	ref_hi int
	ref_s0 int
	ref_s1 int
	out    []Value
	each   ?fn (Value) // each value as found, where the caller asks so (each_value)
	count  int
	// terminal's scratch, kept between items: an item's parts, where a fragment writes each, and
	// whether a fragment writes another part after it
	parts    []u32
	at       []u32
	followed []bool
}

// values are the values a path pattern wants, in the order of the merged view (see above).
pub fn (c &Checked) values(pattern string) []Value {
	mut w := c.value_walk(pattern)
	w.walk()
	return w.out
}

// each_value gives f every value a pattern wants, in the order of the merged view, as it is
// found, and returns how many: nothing is kept, so a value's path and text are views valid during
// the call (clone them to keep them).
pub fn (c &Checked) each_value(pattern string, f fn (Value)) int {
	mut w := c.value_walk(pattern)
	w.each = f
	w.walk()
	return w.count
}

// walk visits the merged view from its root.
fn (mut w ValueWalk) walk() {
	if w.view != unsafe { nil } && w.view.root().ok() {
		w.visit(w.view.root(), false, false)
	}
}

// value_walk is a walk for a pattern over the merged view, its tables made.
fn (c &Checked) value_walk(pattern string) ValueWalk {
	v := c.view
	if v == unsafe { nil } || !v.root().ok() {
		return ValueWalk{
			ix: c.index
		}
	}
	tab := v.set.tab
	n := tab.len()
	mut skip := []bool{len: n}
	for name in c.flat.ignored_content {
		if id := tab.id(name) {
			skip[id] = true
		}
	}
	mut item_of := [][]int{len: n}
	mut idents := []ItemIdentity{}
	for r in c.flat.identity_roles {
		parent := tab.id(r.parent) or { continue }
		idents << ItemIdentity{
			parent: parent
			def:    id_path(tab, r.definition)
			label:  id_path(tab, r.label)
		}
		for item in r.items {
			if id := tab.id(item) {
				item_of[id] << idents.len - 1
			}
		}
	}
	for r in c.flat.direct_identities {
		idents << ItemIdentity{
			parent: any_parent
			def:    id_path(tab, r.definition)
			label:  id_path(tab, r.label)
			by_key: r.definition
		}
		for item in r.items {
			if id := tab.id(item) {
				item_of[id] << idents.len - 1
			}
		}
	}
	if c.flat.identified != unsafe { nil } {
		id := c.flat.identified.id
		role := id.value_role()
		idents << ItemIdentity{
			parent: any_parent
			def:    id_path(tab, role.definition)
			label:  id_path(tab, role.label)
		}
		for k in 2 .. n {
			name := tab.name(u32(k))
			if !name.contains_u8(`:`) && !name.starts_with('{')
				&& id.by_definition.any(glob(it, name)) {
				item_of[k] << idents.len - 1
			}
		}
	}
	mut pat := segments(pattern)
	if pat.len == 0 {
		pat = ['**'] // `/`: the root, so every value
	}
	return ValueWalk{
		view:    v
		ix:      c.index
		pat:     pat
		item_of: item_of
		idents:  idents
		skip:    skip
		sb:      strings.new_builder(256)
	}
}

// IdPath is a key path below an item, as name ids of the set's table, ending at an element's
// text or, where its last step is `@NAME`, at that attribute.
struct IdPath {
	ids  []u32
	attr string
	ok   bool // the table has every name (and the path is not empty)
}

// id_path is a key path as an IdPath; not ok where the table lacks a name.
fn id_path(tab &flatxml.Names, path string) IdPath {
	if path == '' {
		return IdPath{}
	}
	mut steps := path.split('/')
	mut attr := ''
	if steps.last().starts_with('@') {
		attr = steps.last()[1..]
		steps = steps[..steps.len - 1].clone()
	}
	mut ids := []u32{}
	for name in steps {
		ids << tab.id(name) or { return IdPath{} }
	}
	return IdPath{
		ids:  ids
		attr: attr
		ok:   true
	}
}

// starts_at reports whether a child element of an item is where the path starts: the item's
// name, not a part of it (an attribute of the item itself starts at none).
fn (p IdPath) starts_at(tag u32) bool {
	return p.ok && p.ids.len > 0 && p.ids[0] == tag
}

// visit collects the values of n and below: inner is whether the path has its `#` part, below
// whether the pattern wants every value below.
fn (mut w ValueWalk) visit(n flatxml.MNode, inner bool, below bool) {
	tag := n.tag()
	if tag == flatxml.text_tag || (int(tag) < w.skip.len && w.skip[tag]) {
		return
	}
	mark, nb := w.sb.len, w.bounds.len
	start, seg0 := w.start, w.seg0
	ref_lo, ref_hi, ref_s0, ref_s1 := w.ref_lo, w.ref_hi, w.ref_s0, w.ref_s1
	defer {
		w.sb.go_back_to(mark)
		w.bounds.trim(nb)
		w.start, w.seg0 = start, seg0
		w.ref_lo, w.ref_hi, w.ref_s0, w.ref_s1 = ref_lo, ref_hi, ref_s0, ref_s1
	}
	entry := if int(n.i) < w.ix.at.len { w.ix.at[n.i] } else { u32(0) }
	// an element with a path of its own (a container named by its short name too) is no item
	ident := if entry != 0 { -1 } else { w.identity_of(n) }
	mut now_inner := inner
	if entry != 0 {
		w.from_ref()
		w.write_name(w.ix.name_of(entry - 1))
		w.as_ref()
		now_inner = false
	} else if ident >= 0 {
		w.from_ref()
		w.write_item_name(n, w.idents[ident])
		w.as_ref()
		now_inner = false
	} else {
		if !inner {
			w.write_hash()
		}
		w.write_inner(n)
		now_inner = true
	}
	nseg := w.bounds.len / 2
	all := below || w.glob_at(0, w.seg0, nseg, false)
	// what lies below extends this path, or (a referrable element, a named item) its nearest
	// referrable's
	if !all && !w.glob_at(0, w.seg0, nseg, true) && !w.glob_at(0, w.ref_s0, w.ref_s1, true) {
		return
	}
	if n.child_count() == 0 {
		if all {
			w.emit(n)
		}
		return
	}
	if ident >= 0 {
		w.item_parts(n, w.idents[ident], all)
		return
	}
	for c in n.children() {
		if entry != 0 && c.tag() == w.ix.sn {
			continue // its path
		}
		w.visit(c, now_inner, all)
	}
}

// identity_of is the item identity n is named by, or -1: none where n gives no definition, as
// the merge then does not name it by one.
fn (w &ValueWalk) identity_of(n flatxml.MNode) int {
	tag := n.tag()
	if int(tag) >= w.item_of.len {
		return -1
	}
	for k in w.item_of[tag] {
		id := w.idents[k]
		if (id.parent == any_parent || n.parent().tag() == id.parent)
			&& path_text(n, id.def) != '' && keyed_by(n, id.by_key) {
			return k
		}
	}
	return -1
}

// keyed_by reports whether a merged node's rule keys it by a definition path first; true where
// none is asked (a wrapper role's items, the built-in rules').
fn keyed_by(n flatxml.MNode, def string) bool {
	if def == '' {
		return true
	}
	r := n.rule() or { return false }
	return def in r.key
}

// item_parts collects an item's values: its value (terminal) at the item's path when it holds
// text only and is compared; the rest after `#`. The definition is its name, not a value.
fn (mut w ValueWalk) item_parts(n flatxml.MNode, id ItemIdentity, all bool) {
	last := w.terminal(n, id)
	last_tag := if last == u32(0xFFFF_FFFF) { flatxml.text_tag } else { n.m.node(last).tag() }
	for c in n.children() {
		if !w.is_part(c, id) {
			continue
		}
		if c.i != last && last_tag != flatxml.text_tag && c.tag() == last_tag
			&& !same_fragment(c, n.m.node(last)) {
			continue // another file's copy of the value: the first file's is the value
		}
		if c.i == last && c.child_count() == 0 {
			if all {
				w.emit(c)
			}
			continue
		}
		w.visit(c, false, all)
	}
}

// same_fragment reports whether two merged children have an element in one fragment of their
// parent: written side by side, not copies from different files.
fn same_fragment(a flatxml.MNode, b flatxml.MNode) bool {
	for i in 0 .. a.fragment_count() {
		fa := a.fragment(i)
		for j in 0 .. b.fragment_count() {
			fb := b.fragment(j)
			if voidptr(fa.doc) == voidptr(fb.doc) && fa.parent().i == fb.parent().i {
				return true
			}
		}
	}
	return false
}

// terminal is the merged child that is an item's value: of its parts (every element but its
// definition, ignored ones too), one that no fragment writes another part after (the value comes
// last in such an item); of several, the last in the merged view (in its rules' order), and of
// several copies of that element (from different files) the first, the first file's. So neither
// the merge's order, nor an ignored value, nor a fragment holding only some of the parts makes
// another part the value. No node where it has no part.
fn (mut w ValueWalk) terminal(n flatxml.MNode, id ItemIdentity) u32 {
	none_ := u32(0xFFFF_FFFF)
	w.parts.clear()
	w.followed.clear()
	for c in n.children() {
		tag := c.tag()
		// neither the definition nor the label (the item's name, the label a part of its own)
		if tag != flatxml.text_tag && !id.def.starts_at(tag) && !id.label.starts_at(tag) {
			w.parts << c.i
			w.followed << false
		}
	}
	if w.parts.len == 0 {
		return none_
	}
	v := n.m
	for k in 0 .. n.fragment_count() {
		f := n.fragment(k)
		w.at.clear()
		for p in w.parts {
			c := v.node(p)
			mut at := none_
			for j in 0 .. c.fragment_count() {
				cf := c.fragment(j)
				if voidptr(cf.doc) == voidptr(f.doc) && cf.parent().i == f.i {
					at = cf.i
					break
				}
			}
			w.at << at
		}
		for a in 0 .. w.parts.len {
			if w.at[a] == none_ {
				continue
			}
			for b in 0 .. w.parts.len {
				if w.at[b] != none_ && w.at[b] > w.at[a] {
					w.followed[a] = true
					break
				}
			}
		}
	}
	// the last part no fragment writes another after; of several of its name (copies of the
	// value, from different files), the first: the first file's, as the merge keeps a value
	for a := w.parts.len - 1; a >= 0; a-- {
		if !w.followed[a] {
			tag := v.node(w.parts[a]).tag()
			for b in 0 .. a + 1 {
				if !w.followed[b] && v.node(w.parts[b]).tag() == tag {
					return w.parts[b]
				}
			}
		}
	}
	return none_
}

// is_part reports whether a child of an item is one of its values' parts: an element, not its
// definition, and not one whose content the merge does not compare.
fn (w &ValueWalk) is_part(c flatxml.MNode, id ItemIdentity) bool {
	tag := c.tag()
	return tag != flatxml.text_tag && !(int(tag) < w.skip.len && w.skip[tag])
		&& !id.def.starts_at(tag)
}

// from_ref starts the path of a node anew, after what is written: its nearest referrable
// element's path, copied, segments and all.
fn (mut w ValueWalk) from_ref() {
	at := w.sb.len
	for i in w.ref_lo .. w.ref_hi {
		w.sb.write_u8(w.sb[i])
	}
	s0 := w.bounds.len / 2
	for k := 2 * w.ref_s0; k < 2 * w.ref_s1; k++ {
		w.bounds << w.bounds[k] - w.ref_lo + at
	}
	w.start, w.seg0 = at, s0
}

// as_ref makes the path written the nearest referrable's, for what lies below.
fn (mut w ValueWalk) as_ref() {
	w.ref_lo, w.ref_hi = w.start, w.sb.len
	w.ref_s0, w.ref_s1 = w.seg0, w.bounds.len / 2
}

// write_name writes `/name` as one segment.
fn (mut w ValueWalk) write_name(name string) {
	w.sb.write_u8(`/`)
	lo := w.sb.len
	w.sb.write_string(name)
	w.bounds << lo
	w.bounds << w.sb.len
}

// write_item_name writes an item's name: `/` and its definition's last name, and its label as
// a key where it has one, escaped as paths escape keys.
fn (mut w ValueWalk) write_item_name(n flatxml.MNode, id ItemIdentity) {
	def := path_text(n, id.def)
	cut := def.last_index_u8(`/`)
	w.sb.write_u8(`/`)
	lo := w.sb.len
	unsafe { w.sb.write_ptr(def.str + cut + 1, def.len - cut - 1) }
	label := path_text(n, id.label)
	if label != '' {
		w.sb.write_u8(`[`)
		for c in label {
			if c == `\\` || c == `[` || c == `]` {
				w.sb.write_u8(`\\`)
			}
			w.sb.write_u8(c)
		}
		w.sb.write_u8(`]`)
	}
	// one definition given several values under one container (a set): each by its place among
	// them, as a path shows an item keyed by its content. The merge orders children by key, so
	// they are neighbours: two siblings are looked at, no list made.
	mut place := 1
	mut k := n.i
	for k > 0 && same_definition(n.m.node(k - 1), n, id, def, label) {
		place++
		k--
	}
	if place > 1 || (int(n.i) + 1 < n.m.len() && same_definition(n.m.node(n.i + 1), n, id, def, label)) {
		w.sb.write_string('[#')
		w.sb.write_decimal(place)
		w.sb.write_u8(`]`)
	}
	w.bounds << lo
	w.bounds << w.sb.len
}

// same_definition reports whether a merged node is a sibling of n giving the same definition and
// label.
fn same_definition(s flatxml.MNode, n flatxml.MNode, id ItemIdentity, def string, label string) bool {
	return s.ok() && s.tag() == n.tag() && s.parent().i == n.parent().i
		&& path_text(s, id.def) == def && path_text(s, id.label) == label
}

// path_text is the text at a key path below a merged node, or the attribute it ends at, trimmed;
// '' where there is none.
fn path_text(n flatxml.MNode, p IdPath) string {
	if !p.ok {
		return ''
	}
	mut cur := n
	for id in p.ids {
		mut found := false
		for c in cur.children() {
			if c.tag() == id {
				cur = c
				found = true
				break
			}
		}
		if !found {
			return ''
		}
	}
	if p.attr != '' {
		return trimmed(cur.attr(p.attr))
	}
	return trimmed(cur.text())
}

// write_hash writes the `#` that starts a path's inner part, a segment of its own.
fn (mut w ValueWalk) write_hash() {
	lo := w.sb.len
	w.sb.write_u8(`#`)
	w.bounds << lo
	w.bounds << w.sb.len
}

// write_inner writes an element below the nearest referrable one as a path shows it, after `#`
// or `/`.
fn (mut w ValueWalk) write_inner(n flatxml.MNode) {
	nb := w.bounds.len
	if !(nb >= 2 && w.bounds[nb - 1] - w.bounds[nb - 2] == 1 && w.sb[w.bounds[nb - 2]] == `#`) {
		w.sb.write_u8(`/`)
	}
	lo := w.sb.len
	write_segment(mut w.sb, n)
	w.bounds << lo
	w.bounds << w.sb.len
}

// emit gives n's text as a value at the path written: to the caller's function, as views valid
// during the call, or kept.
fn (mut w ValueWalk) emit(n flatxml.MNode) {
	w.count++
	if f := w.each {
		f(Value{
			path: unsafe { tos(&w.sb[w.start], w.sb.len - w.start) }
			text: trimmed(n.text())
			node: n.i
		})
		return
	}
	w.out << Value{
		path: w.sb[w.start..].bytestr()
		text: trimmed(n.text()).clone()
		node: n.i
	}
}

// glob_at reports whether the pattern's segments from pi match the path's segments si .. end:
// all of them, or, with prefix, as far as the path goes (a longer path could match).
fn (w &ValueWalk) glob_at(pi int, si int, end int, prefix bool) bool {
	if pi == w.pat.len {
		return si == end
	}
	if w.pat[pi] == '**' {
		for k in si .. end + 1 {
			if w.glob_at(pi + 1, k, end, prefix) {
				return true
			}
		}
		return false
	}
	if si == end {
		return prefix
	}
	return w.segment_matches(w.pat[pi], si) && w.glob_at(pi + 1, si + 1, end, prefix)
}

// segment_matches is glob_segment on segment si of the path written.
fn (w &ValueWalk) segment_matches(pat string, si int) bool {
	lo, mut hi := w.bounds[2 * si], w.bounds[2 * si + 1]
	hash := hi - lo == 1 && w.sb[lo] == `#`
	if hash || pat == '#' {
		return hash && pat == '#'
	}
	if !pat.contains_u8(`[`) {
		for i in lo .. hi {
			if w.sb[i] == `[` {
				hi = i
				break
			}
		}
	}
	return glob_bytes(pat, w.sb, lo, hi)
}

// glob_bytes is glob_name on b[lo..hi].
fn glob_bytes(pat string, b []u8, lo int, hi int) bool {
	if pat == '*' {
		return true
	}
	n := hi - lo
	if !pat.contains_any('*?') {
		if pat.len != n {
			return false
		}
		for i in 0 .. n {
			if pat[i] != b[lo + i] {
				return false
			}
		}
		return true
	}
	mut p, mut i := 0, 0
	mut star, mut mark := -1, 0
	for i < n {
		if p < pat.len && (pat[p] == `?` || pat[p] == b[lo + i]) {
			p++
			i++
		} else if p < pat.len && pat[p] == `*` {
			star = p
			mark = i
			p++
		} else if star >= 0 {
			p = star + 1
			mark++
			i = mark
		} else {
			return false
		}
	}
	for p < pat.len && pat[p] == `*` {
		p++
	}
	return p == pat.len
}
