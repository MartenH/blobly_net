module flatxml

import io

// Writing a merged view as one document. Each merged node is written once. A node made of one
// contribution whose children are its contribution's own, unchanged all the way down, is copied
// byte for byte. Any other node is written from its first contribution: its start tag as written
// there, with the attributes only other contributions have after its own (first wins, as the
// view reads them); its merged children in the view's order, each after the bytes that stood
// before it where it was read (its indentation, and the comments before it); the text, comments
// and processing instructions that followed each of the first contribution's own children, after
// that child; and the bytes before the end tag. The bytes before and after the root are its first
// contribution's document's. An element read where other namespace bindings were in scope than
// where it is written is given the declarations that restore them, as an edit's is; namespace
// declarations are never taken from other contributions as attributes.

@[params]
pub struct MergedWriteOptions {
pub:
	// attributes the root is written with, in place of the ones it has of those expanded names,
	// or after its others. A namespace declaration among them binds its prefix for the whole
	// document, and may not change what a prefix in scope means (an absent default namespace is
	// bound to none); a prefixed name's prefix must be bound.
	root_attrs []EAttr
}

// write writes the merged view as one XML document to w.
pub fn (m &Merged) write(mut w io.Writer, opts MergedWriteOptions) ! {
	root := m.root()
	if !root.ok() {
		return error('the merged view is empty')
	}
	mut em := emitter_to(root.fragment(0).doc, mut w, ModePlan{})
	m.emit(mut em, opts)!
	em.flush()!
}

// write_file writes the merged view as one XML document to path, as `Doc.write_file` does.
pub fn (m &Merged) write_file(path string, opts MergedWriteOptions) ! {
	write_through_temp(path, fn [m, opts] (mut f FileOut) ! {
		m.write(mut f, opts)!
	})!
}

// xml is the merged view as one XML document.
pub fn (m &Merged) xml(opts MergedWriteOptions) !string {
	root := m.root()
	if !root.ok() {
		return error('the merged view is empty')
	}
	mut em := emitter_in(root.fragment(0).doc, ModePlan{}, 4096)
	m.emit(mut em, opts)!
	em.settle()!
	return em.buf.str()
}

fn (m &Merged) emit(mut em Emitter, opts MergedWriteOptions) ! {
	root := m.root()
	f := root.fragment(0)
	over := root_override(f.doc, f.i, opts.root_attrs)!
	lo, hi := f.doc.span(f.i)
	em.copy_in(f.doc, 0, lo)!
	mut w := MergedWriter{
		m:    m
		pure: m.pure_nodes()
		root: root.i
		over: over
	}
	w.element(mut em, root.i, hi, map[string]string{})!
	em.copy_in(f.doc, hi, u32(f.doc.src_len))!
}

// pure_nodes says, per merged node, whether it is its one contribution unchanged: one
// contribution, whose child elements are, in order, the contributions of its merged children,
// each pure too. Children come after their parent, so one pass from the end decides them all.
fn (m &Merged) pure_nodes() []bool {
	mut pure := []bool{len: m.len()}
	for n := m.len() - 1; n >= 0; n-- {
		if m.frag_lo[n + 1] - m.frag_lo[n] != 1 {
			continue
		}
		f := m.frags[m.frag_lo[n]]
		d := m.set.docs[f.doc]
		mut ok := true
		mut k := m.kid_lo[n]
		mut c := d.first_child(f.i)
		for c != no_node && ok {
			if d.is_element(c) {
				if k >= m.kid_lo[n + 1] || !pure[k] {
					ok = false
				} else {
					kf := m.frags[m.frag_lo[k]]
					ok = kf.doc == f.doc && kf.i == c
				}
				k++
			}
			c = d.next_sibling(c)
		}
		pure[n] = ok && k == m.kid_lo[n + 1]
	}
	return pure
}

@[heap]
struct MergedWriter {
	m    &Merged
	pure []bool
	root u32
	over RootOverride // what the root is written with
mut:
	// the bindings in scope inside an element of a document, by (document, element)
	inside map[u64]map[string]string
}

// bindings_in is the namespace bindings in scope inside element i of document doc: those above
// it and its own, worked out once per element.
fn (mut w MergedWriter) bindings_in(doc u32, i u32) map[string]string {
	key := u64(doc) << 32 | u64(i)
	if b := w.inside[key] {
		return b
	}
	d := w.m.set.docs[doc]
	p := d.parent[i]
	above := if p == 0 { map[string]string{} } else { w.bindings_in(doc, p) }
	if !d.declares(i) {
		// the same bindings as above it: the same map
		w.inside[key] = above
		return above
	}
	mut b := above.clone()
	for pre, u in d.own_bindings(i) {
		b[pre] = u
	}
	w.inside[key] = b
	return b
}

// bindings_above is the namespace bindings in scope where element i of document doc is.
fn (mut w MergedWriter) bindings_above(doc u32, i u32) map[string]string {
	p := w.m.set.docs[doc].parent[i]
	return if p == 0 { map[string]string{} } else { w.bindings_in(doc, p) }
}

// Layout is where the children of one contribution are: per child element, where the bytes
// before it start (lead), where it ends, and where the text and comments after it end (tail);
// where the first child element's bytes start, and where the last child node ends.
struct Layout {
mut:
	elems       []u32 // in document order
	lead        []u32
	ends        []u32
	tail        []u32
	first_lead  u32
	content_end u32
}

// entry is the entry of child element c; -1 for none.
fn (l &Layout) entry(c u32) int {
	mut lo, mut hi := 0, l.elems.len
	for lo < hi {
		mid := (lo + hi) / 2
		if l.elems[mid] < c {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return if lo < l.elems.len && l.elems[lo] == c { lo } else { -1 }
}

fn layout_of(d &Doc, i u32, ste u32) Layout {
	mut l := Layout{
		first_lead:  ste
		content_end: ste
	}
	mut prev_end := ste
	mut c := d.first_child(i)
	for c != no_node {
		end := d.span_end(c)
		if d.is_element(c) {
			if l.elems.len == 0 {
				l.first_lead = prev_end
			} else {
				l.tail[l.tail.len - 1] = prev_end
			}
			l.elems << c
			l.lead << prev_end
			l.ends << end
			l.tail << end
		}
		prev_end = end
		c = d.next_sibling(c)
	}
	if l.elems.len > 0 {
		l.tail[l.tail.len - 1] = prev_end
		l.content_end = prev_end
	} else {
		l.content_end = if d.text_len[i] != 0 { d.text_end(i) } else { prev_end }
		l.first_lead = l.content_end
	}
	return l
}

// element writes merged node n, which ends at end in its first contribution's document, where
// the bindings scope are in scope.
fn (mut w MergedWriter) element(mut em Emitter, n u32, end u32, scope map[string]string) ! {
	m := w.m
	f0 := m.frags[m.frag_lo[n]]
	d := m.set.docs[f0.doc]
	i := f0.i
	own := if d.declares(i) { d.own_bindings(i) } else { map[string]string{} }
	mut decls := scope_decls(w.bindings_above(f0.doc, i), scope, own)
	if w.pure[n] && !(n == w.root && w.over.changes.len > 0) {
		after_name := d.src_off[i] + 1 + u32(d.name(i).len)
		em.copy_in(d, d.src_off[i], after_name)!
		if decls.len > 0 {
			em.put(decls.join(''))!
		}
		em.copy_in(d, after_name, end)!
		return
	}
	// in scope inside it: where it was read, and what its attributes from others declare
	mut inner := w.bindings_in(f0.doc, i)
	if n == w.root && w.over.decls.len > 0 {
		inner = inner.clone() // the cached bindings stay as read
		for p, u in w.over.decls {
			inner[p] = u
		}
	}
	mut extras := w.extra_attrs(n, d, i, mut inner, mut decls)!
	if n == w.root && w.over.changes.len > 0 {
		// the attributes given in place of those of their expanded names
		extras = extras.filter(expanded_attr(it.name, inner) !in w.over.names)
		extras << w.over.changes
	}
	ste := d.start_tag_end(i)
	closed := d.self_closing(ste)
	nkids := m.kid_lo[n + 1] - m.kid_lo[n]
	if closed && nkids == 0 {
		em.start_tag(d, i, extras, decls, ste, true)!
		return
	}
	em.start_tag(d, i, extras, decls, ste, false)!
	ets := w.content(mut em, n, d, ste, closed, inner)!
	if closed {
		em.put('</${d.name(i)}>')!
	} else {
		em.copy_in(d, ets, d.close_after(i, ets))!
	}
}

// extra_attrs are the attributes of merged node n that only other contributions than its first
// (element i of d) have, as attribute changes to its start tag: never a namespace declaration;
// a prefixed one by a prefix bound to its namespace where it is written, declared (in decls and
// inner) where none is.
fn (mut w MergedWriter) extra_attrs(n u32, d &Doc, i u32, mut inner map[string]string, mut decls []string) ![]AttrChange {
	m := w.m
	if m.frag_lo[n + 1] - m.frag_lo[n] == 1 {
		return []
	}
	// an attribute already given, by its expanded name where it has a namespace: p:id and q:id
	// with p and q bound to one URI are one attribute, and the first fragment's value stands
	mut have := map[string]string{} // expanded name -> the value written
	mut spelled := map[string]string{} // expanded name -> its name as the written value spells it
	mut used := map[string]bool{} // prefixes the element's own names use
	used[prefix_of(d.name(i))] = true
	lo, hi := d.attr_range(i)
	f0 := m.frags[m.frag_lo[n]] // d's element i
	own := w.bindings_in(f0.doc, f0.i)
	resolved := d.attr_ns.len == d.attr_tag.len
	for a := lo; a < hi; a++ {
		name := d.attr_name(a)
		used[prefix_of(name)] = true
		// a declaration is a binding, not an attribute: `xmlns:id` is not `id`
		if !is_ns_decl_name(name) {
			k := written_attr_key(name, own)
			have[k] = d.attr_value(a)
			spelled[k] = name
		}
	}
	mut out := []AttrChange{}
	for k := m.frag_lo[n] + 1; k < m.frag_lo[n + 1]; k++ {
		f := m.frags[k]
		fd := m.set.docs[f.doc]
		flo, fhi := fd.attr_range(f.i)
		scope := w.bindings_in(f.doc, f.i)
		for a := flo; a < fhi; a++ {
			name := fd.attr_name(a)
			if is_ns_decl_name(name) {
				continue
			}
			// an element holds one attribute of an expanded name: the first fragment's value stands
			// where the merge compared the two (both documents resolved, or one name as written: a
			// difference reported, or ignored as the rules say); where it could not (two spellings
			// of one expanded name, unresolved), a different value is refused, not dropped in silence
			key := written_attr_key(name, scope)
			if first := have[key] {
				compared := (resolved && fd.attr_ns.len == fd.attr_tag.len) || spelled[key] == name
				if first != fd.attr_value(a) && !compared {
					return error('${w.m.pos(Node{fd, f.i})}: ${name} is the attribute ${key.all_after(' ')} of namespace ${key.all_before(' ')} that another fragment gives the value "${first}"; resolve the documents\' namespaces and the merge reports the difference')
				}
				continue
			}
			have[key] = fd.attr_value(a)
			spelled[key] = name
			p := prefix_of(name)
			if p == '' || p == 'xml' {
				out << AttrChange{name, fd.attr_value(a)}
				continue
			}
			uri := scope[p] or { '' }
			if uri == '' {
				out << AttrChange{name, fd.attr_value(a)}
				continue
			}
			mut q := ''
			if (inner[p] or { '' }) == uri {
				q = p
			} else {
				for cand, u in inner {
					if u == uri && cand != '' {
						q = cand
						break
					}
				}
			}
			if q == '' {
				// declare one: its own prefix, unless that means something else here
				q = p
				mut k2 := 1
				for (q in inner) || (q in used) {
					q = '${p}${k2}'
					k2++
				}
				decls << ' xmlns:${q}="${escape_attr(uri, `"`)}"'
				inner = inner.clone() // the cached bindings stay as read
				inner[q] = uri
			}
			out << AttrChange{'${q}:${name.all_after(':')}', fd.attr_value(a)}
		}
	}
	return out
}

// RootOverride is the attributes a root is written with: as changes to its start tag, the
// namespace declarations among them, and their expanded names (`uri local`).
struct RootOverride {
mut:
	changes []AttrChange
	decls   map[string]string
	names   map[string]bool
}

// root_override checks attrs against root element i of d and makes them its override. A name
// that is not an attribute name or is given twice, a reserved prefix declared or bound, a
// declaration that changes what a prefix in scope means (the default is bound to none where none
// is declared), and a prefix not bound are refused. One whose expanded name the root has under
// another name replaces that attribute.
fn root_override(d &Doc, i u32, attrs []EAttr) !RootOverride {
	mut scope := if d.declares(i) { d.own_bindings(i) } else { map[string]string{} }
	if '' !in scope {
		scope[''] = ''
	}
	mut o := RootOverride{}
	mut seen := map[string]bool{}
	for a in attrs {
		parts := a.name.split(':')
		if a.name == '' || a.name.contains_any(' \t\r\n<>&=/"\'') || parts.len > 2
			|| parts.any(it == '') {
			return error('root attribute `${a.name}` is not an attribute name')
		}
		if a.name in seen {
			return error('root attribute ${a.name} is given twice')
		}
		seen[a.name] = true
		if !is_ns_decl_name(a.name) {
			continue
		}
		p := decl_prefix(a.name)
		if p == 'xmlns' || a.value == xmlns_ns_uri || (p == 'xml') != (a.value == xml_ns_uri) {
			return error('root attribute ${a.name}: the prefixes xml and xmlns are reserved')
		}
		if p != '' && a.value == '' {
			return error('root attribute ${a.name} binds a prefix to no namespace')
		}
		if u := scope[p] {
			if u != a.value {
				return error('root attribute ${a.name} rebinds a prefix the document binds to `${u}`')
			}
		}
		o.decls[p] = a.value
		scope[p] = a.value
	}
	// the root's own attributes by expanded name
	mut have := map[string]string{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		name := d.attr_name(a)
		if !is_ns_decl_name(name) {
			have[expanded_attr(name, scope)] = name
		}
	}
	for a in attrs {
		if is_ns_decl_name(a.name) {
			o.changes << AttrChange{a.name, a.value}
			continue
		}
		p := prefix_of(a.name)
		if p != '' && p != 'xml' && (scope[p] or { '' }) == '' {
			return error('root attribute ${a.name}: the prefix `${p}` is not bound')
		}
		key := expanded_attr(a.name, scope)
		if key in o.names {
			return error('root attribute ${a.name} is given twice, under another prefix')
		}
		o.names[key] = true
		o.changes << AttrChange{have[key] or { a.name }, a.value}
	}
	return o
}

// written_attr_key is what tells an attribute of one element from another for the writer: its expanded
// name where its prefix is bound (or it has none), its name as written where the prefix is bound
// to nothing in scope (an unresolved document's), so an unbound `p:id` is not the unprefixed `id`.
fn written_attr_key(name string, scope map[string]string) string {
	p := prefix_of(name)
	if p != '' && p != 'xml' && p !in scope {
		return name
	}
	return expanded_attr(name, scope)
}

// expanded_attr is an attribute name's expanded name, `uri local`, by the bindings in scope: an
// unprefixed attribute is in no namespace.
fn expanded_attr(name string, scope map[string]string) string {
	p := prefix_of(name)
	uri := if p == '' {
		''
	} else if p == 'xml' {
		xml_ns_uri
	} else {
		scope[p] or { '' }
	}
	return '${uri} ${name.all_after(':')}'
}

// prefix_of is the prefix of a qualified name; '' for none.
@[inline]
fn prefix_of(name string) string {
	return if name.contains(':') { name.all_before(':') } else { '' }
}

// content writes the content of merged node n, whose first contribution is an element of d, and
// returns where that contribution's end tag starts. Whitespace is not written next to text,
// where it would join it.
fn (mut w MergedWriter) content(mut em Emitter, n u32, d &Doc, ste u32, closed bool, scope map[string]string) !u32 {
	m := w.m
	// the layout of every contribution's children, where they are needed
	flo := m.frag_lo[n]
	mut layouts := []Layout{cap: int(m.frag_lo[n + 1] - flo)}
	for k := flo; k < m.frag_lo[n + 1]; k++ {
		f := m.frags[k]
		fd := m.set.docs[f.doc]
		layouts << layout_of(fd, f.i, if k == flo { ste } else { fd.start_tag_end(f.i) })
	}
	l0 := layouts[0]
	// what comes before the first contribution's first child element: its text and comments
	em.copy_in(d, ste, l0.first_lead)!
	mut text_last := l0.first_lead > ste
	mut written := []bool{len: l0.elems.len}
	for k := m.kid_lo[n]; k < m.kid_lo[n + 1]; k++ {
		kf := m.frags[m.frag_lo[k]]
		kd := m.set.docs[kf.doc]
		// the contribution it is a child of
		mut c := 0
		for c < layouts.len {
			cf := m.frags[flo + u32(c)]
			if cf.doc == kf.doc && cf.i == kd.parent[kf.i] {
				break
			}
			c++
		}
		lk := if c < layouts.len { layouts[c] } else { Layout{} }
		x := lk.entry(kf.i)
		start := kd.span_start(kf.i)
		mut lead := if x >= 0 { lk.lead[x] } else { start }
		if text_last {
			lead = ws_prefix_end(kd, lead, start)
		}
		em.copy_in(kd, lead, start)!
		end := if x >= 0 { lk.ends[x] } else { kd.span_end(kf.i) }
		w.element(mut em, k, end, scope)!
		text_last = false
		// the text after it, where it was the first contribution's own child
		if x >= 0 && c == 0 {
			em.copy_in(d, l0.ends[x], l0.tail[x])!
			text_last = l0.tail[x] > l0.ends[x]
			written[x] = true
		}
	}
	// the text after the first contribution's children the view left out
	for x, done in written {
		if !done && l0.tail[x] > l0.ends[x] {
			em.copy_in(d, l0.ends[x], l0.tail[x])!
			text_last = true
		}
	}
	// the bytes before the end tag: the first contribution's, or, where it has no end tag, those
	// of one that has
	mut td := unsafe { d }
	mut tl := l0
	mut tste := ste
	if closed {
		for k := m.frag_lo[n] + 1; k < m.frag_lo[n + 1]; k++ {
			f := m.frags[k]
			fd := m.set.docs[f.doc]
			s := fd.start_tag_end(f.i)
			if !fd.self_closing(s) {
				td = fd
				tl = layouts[k - flo]
				tste = s
				break
			}
		}
		if voidptr(td) == voidptr(d) {
			return ste
		}
	}
	ets := td.end_tag_at(tl.content_end)
	mut from := tl.content_end
	if voidptr(td) != voidptr(d) && tl.elems.len == 0 {
		from = ws_suffix_start(td, tste, ets)
	}
	if text_last {
		from = ws_prefix_end(td, from, ets)
	}
	em.copy_in(td, from, ets)!
	return ets
}
