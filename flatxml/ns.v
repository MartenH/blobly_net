module flatxml

// Namespaces (Namespaces in XML 1.0), resolved on request by `resolve_namespaces`, so a document
// read without them costs nothing extra. Resolution gives every element and attribute a
// namespace id and a local name; names are split once per distinct name, not per node.

pub const xml_ns_uri = 'http://www.w3.org/XML/1998/namespace'
pub const xmlns_ns_uri = 'http://www.w3.org/2000/xmlns/'

// Namespace ids. 0 is no namespace; 1 and 2 are the two reserved namespaces.
pub const no_ns = u32(0)
pub const xml_ns = u32(1)
pub const xmlns_ns = u32(2)

// The prefix recorded for a name that is not a qualified name.
const not_qname = u32(0xFFFF_FFFF)

// resolve_namespaces fills `ns` (per node) and `attr_ns` (per attribute) and the URI table, and
// fails on what the Namespaces recommendation makes an error: an unbound prefix, a name that is
// not a qualified name (`a:b:c`, `:a`, `a:`), a misuse of the reserved prefixes or namespaces,
// undeclaring a prefix, and two attributes of one element with the same expanded name.
// A namespace declaration (`xmlns`, `xmlns:p`) is itself in the xmlns namespace. On an error,
// the document is left as it was before the call (apart from names added to the table). The
// table is changed, so the documents of one set resolve one at a time.
pub fn (mut d Doc) resolve_namespaces() ! {
	if d.ns.len == d.tag.len {
		return
	}
	known := d.tab.uris.len
	d.resolve() or {
		// the URIs this call added name nothing
		mut t := d.tab
		for t.uris.len > known {
			t.uri_ids.delete(t.uris.pop())
		}
		return err
	}
}

@[direct_array_access]
fn (mut d Doc) resolve() ! {
	mut t := d.tab
	xml_id := t.intern_str('xml')
	xmlns_id := t.intern_str('xmlns')
	t.split()
	mut ns := []u32{len: d.tag.len}
	mut attr_ns := []u32{len: d.attr_tag.len}
	// bind[p] is the namespace prefix name p is bound to; slot 0 is the default namespace.
	// 0 means unbound for a prefix and no namespace for the default.
	mut bind := []u32{len: t.names.len}
	bind[xml_id] = xml_ns
	// The declaring elements still open (their `end`), and for each the undo log of the
	// bindings it changed, so a binding ends with the element that made it.
	mut open_end := []u32{}
	mut open_undo := []int{}
	mut undo_slot := []u32{}
	mut undo_old := []u32{}
	// Walk the elements in document order, keeping `bind` to the declarations in scope.
	for k in 1 .. d.tag.len {
		i := u32(k)
		for open_end.len > 0 && i >= open_end[open_end.len - 1] {
			lo := open_undo.pop()
			open_end.delete_last()
			for undo_slot.len > lo {
				bind[undo_slot.pop()] = undo_old.pop()
			}
		}
		tag := d.tag[i]
		if tag == text_tag {
			continue
		}
		lo, hi := d.attr_range(i)
		mut declared := false
		mut prefixed := false
		// Apply this element's declarations first: they are in scope for its own name and its
		// attributes. Note whether any other attribute has a prefix to resolve after them.
		for a := lo; a < hi; a++ {
			an := d.attr_tag[a]
			ap := t.prefix[an]
			slot := if ap == 0 {
				if an != xmlns_id {
					continue
				}
				u32(0)
			} else if ap == xmlns_id {
				d.tab.local[an]
			} else {
				prefixed = true
				continue
			}
			attr_ns[a] = xmlns_ns
			uri := d.attr_value(a)
			id := t.uri_id(uri)
			if slot == xmlns_id {
				return d.err_at(int(d.src_off[i]), 'the prefix xmlns must not be declared')
			}
			if slot == xml_id && id != xml_ns {
				return d.err_at(int(d.src_off[i]), 'the prefix xml must not be bound to another namespace')
			}
			if slot != xml_id && (id == xml_ns || id == xmlns_ns) {
				return d.err_at(int(d.src_off[i]), '${uri} is reserved and must not be bound to ${d.decl_target(slot)}')
			}
			if slot != 0 && id == no_ns {
				return d.err_at(int(d.src_off[i]), 'the prefix ${d.tab.names[slot]} must not be undeclared')
			}
			if !declared {
				open_end << d.end[i]
				open_undo << undo_slot.len
				declared = true
			}
			undo_slot << slot
			undo_old << bind[slot]
			bind[slot] = id
		}
		p := t.prefix[tag]
		if p == not_qname {
			return d.err_at(int(d.src_off[i]), '<${d.tab.names[tag]}> is not a qualified name')
		}
		ns[i] = bind[p]
		if p != 0 && ns[i] == 0 {
			return d.err_at(int(d.src_off[i]), 'the prefix of <${d.tab.names[tag]}> is not bound to a namespace')
		}
		if !prefixed {
			continue
		}
		// The prefixed attributes; unprefixed ones are in no namespace.
		for a := lo; a < hi; a++ {
			an := d.attr_tag[a]
			ap := t.prefix[an]
			if ap == 0 || ap == xmlns_id {
				continue
			}
			if ap == not_qname {
				return d.err_at(int(d.src_off[i]), 'attribute ${d.tab.names[an]} is not a qualified name')
			}
			attr_ns[a] = bind[ap]
			if attr_ns[a] == 0 {
				return d.err_at(int(d.src_off[i]), 'the prefix of attribute ${d.tab.names[an]} is not bound to a namespace')
			}
		}
		d.check_expanded_attrs(i, lo, hi, attr_ns)!
	}
	// every element's and namespaced attribute's expanded name, so a merge with a local namespace
	// (Doc.name_in, Doc.attr_id) reads the table and never writes it
	mut last_tag := []u32{len: t.names.len, init: no_name}
	mut last_ns := []u32{len: t.names.len}
	for k in 1 .. d.tag.len {
		tag := d.tag[k]
		if tag == text_tag || (last_tag[tag] == tag && last_ns[tag] == ns[k]) {
			continue
		}
		last_tag[tag], last_ns[tag] = tag, ns[k]
		t.intern_expanded(ns[k], t.local[tag])
	}
	for a in 0 .. d.attr_tag.len {
		if attr_ns[a] != no_ns && attr_ns[a] != xmlns_ns {
			t.intern_expanded(attr_ns[a], t.local[d.attr_tag[a]])
		}
	}
	t.split()
	d.ns = ns
	d.attr_ns = attr_ns
}

// check_expanded_attrs fails when two attributes of element i, one of them prefixed, have the
// same namespace and local name. Two unprefixed duplicates are the parser's to judge.
fn (d &Doc) check_expanded_attrs(i u32, lo u32, hi u32, attr_ns []u32) ! {
	for a := lo; a < hi; a++ {
		if attr_ns[a] == no_ns || attr_ns[a] == xmlns_ns {
			continue
		}
		for b := lo; b < hi; b++ {
			if b != a && attr_ns[b] == attr_ns[a]
				&& d.tab.local[d.attr_tag[b]] == d.tab.local[d.attr_tag[a]] {
				return d.err_at(int(d.src_off[i]), 'attributes ${d.tab.names[d.attr_tag[a]]} and ${d.tab.names[d.attr_tag[b]]} have the same expanded name')
			}
		}
	}
}

fn (d &Doc) decl_target(slot u32) string {
	return if slot == 0 { 'the default namespace' } else { 'the prefix ${d.tab.names[slot]}' }
}

// --- reading resolved names ------------------------------------------------------------------
// Before `resolve_namespaces` has run, ns_of and attr_ns_of answer no_ns and ns_uri knows the
// reserved ids; the local-name readers need it to have run, and say so.


fn (d &Doc) need_split() {
	if d.ns.len != d.tag.len {
		panic('flatxml: local names need resolve_namespaces() to have run')
	}
}

// name_in is the name id element i is named by in a merge whose local namespace has id `local`
// (`RuleSet.local_ns`): its local name's when it is in that namespace, whatever prefix spells
// it, and its expanded name (`{uri}x`, `{}x` for none) when it is in another, prefixed or not,
// so it is never taken for the namespace's own `x`. no_local: always as written. Reads the table
// only: the expanded names were made when the document was resolved.
@[inline]
pub fn (d &Doc) name_in(i u32, local u32) u32 {
	t := d.tag[i]
	if local == no_local || t == text_tag {
		return t
	}
	l := d.tab.local[t]
	if d.ns[i] == local {
		return l
	}
	return d.tab.expanded[u64(d.ns[i]) << 32 | l] or { t }
}

// attr_id is what identifies attribute a: its name when it is in no namespace (or a namespace
// declaration), its expanded name (`{uri}local`) when it is in one, so `p:id` and `q:id` with
// p and q bound to one URI are one attribute. Before resolution, its name as written.
@[inline]
pub fn (d &Doc) attr_id(a u32) u32 {
	t := d.attr_tag[a]
	if int(a) >= d.attr_ns.len {
		return t
	}
	ns := d.attr_ns[a]
	if ns == no_ns || ns == xmlns_ns {
		return t
	}
	return d.tab.expanded[u64(ns) << 32 | d.tab.local[t]] or { t }
}

// ns_of is the namespace id of element i.
@[inline]
pub fn (d &Doc) ns_of(i u32) u32 {
	return if int(i) < d.ns.len { d.ns[i] } else { no_ns }
}

// local_id is the name id of element i's local name.
@[inline]
pub fn (d &Doc) local_id(i u32) u32 {
	d.need_split()
	return d.tab.local[d.tag[i]]
}

// local_name is element i's name without its prefix.
pub fn (d &Doc) local_name(i u32) string {
	d.need_split()
	return d.tab.names[d.tab.local[d.tag[i]]]
}

// attr_ns_of is the namespace id of attribute a.
@[inline]
pub fn (d &Doc) attr_ns_of(a u32) u32 {
	return if int(a) < d.attr_ns.len { d.attr_ns[a] } else { no_ns }
}

// attr_local_id is the name id of attribute a's local name.
@[inline]
pub fn (d &Doc) attr_local_id(a u32) u32 {
	d.need_split()
	return d.tab.local[d.attr_tag[a]]
}

// attr_local_name is attribute a's name without its prefix.
pub fn (d &Doc) attr_local_name(a u32) string {
	d.need_split()
	return d.tab.names[d.tab.local[d.attr_tag[a]]]
}

// is_ns_decl reports whether attribute a declares a namespace (`xmlns` or `xmlns:p`).
@[inline]
pub fn (d &Doc) is_ns_decl(a u32) bool {
	return d.attr_ns_of(a) == xmlns_ns
}

// ns_uri is the URI of namespace id; '' for no namespace.
pub fn (d &Doc) ns_uri(id u32) string {
	return d.tab.uris[id]
}

// ns_id is the id of a namespace URI, if the document declares it (or it is reserved). In a set,
// ids are the set's, so the URI may be declared by another document.
pub fn (d &Doc) ns_id(uri string) ?u32 {
	return d.tab.uri_ids[uri] or { return none }
}

// ns_for_prefix is the namespace a prefix is bound to at element i, by the declarations on i and
// its ancestors; '' asks for the default namespace (no_ns when none is in scope), and `xml` is
// always bound. It reads qualified names written in attribute values or text, as XML Schema
// does (`type="p:T"`). Needs `resolve_namespaces` to have run; none for an unbound prefix.
pub fn (d &Doc) ns_for_prefix(i u32, prefix string) ?u32 {
	if prefix == 'xml' {
		return xml_ns
	}
	mut e := i
	// The nearest declaration of the prefix, on i or an ancestor, wins.
	for e != no_node {
		lo, hi := d.attr_range(e)
		for a := lo; a < hi; a++ {
			if d.attr_ns_of(a) != xmlns_ns {
				continue
			}
			name := d.tab.names[d.attr_tag[a]]
			declared := if name == 'xmlns' { '' } else { name['xmlns:'.len..] }
			if declared == prefix {
				return d.tab.uri_ids[d.attr_value(a)] or { no_ns }
			}
		}
		e = d.parent[e]
	}
	return if prefix == '' { no_ns } else { none }
}
