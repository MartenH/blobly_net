module arxmodel

import flatxml

// never_ns is a namespace id no element has: a local namespace no document declares.
const never_ns = u32(0xFFFF_FFFE)

// Naming is how a merge names a document's elements (flatxml's Doc.name_in): by its local name
// when the element is in the rules' local namespace, as written otherwise. Every reading of a
// document's element names that keys, hashes or counts for a merge goes through one, so it names
// what the merge names: `ar:X` in a file binding the model's namespace to `ar` is X, and a foreign
// `ext:X` is not.
pub struct Naming {
pub:
	ns string // the local namespace's URI; '' for none
mut:
	tab voidptr // the name table `id` was read from
	id  u32 = flatxml.no_local
}

// naming is the naming of a model's documents by the local namespace ns: its id read once from
// the models' name table (the documents of one set share it).
pub fn naming(ns string, models []&Model) Naming {
	for m in models {
		for d in m.set.docs {
			return Naming{
				ns:  ns
				tab: voidptr(d.tab)
				id:  ns_id_in(d, ns)
			}
		}
	}
	return Naming{
		ns: ns
	}
}

// ns_id_in is the local namespace's id for Doc.name_in: flatxml.no_local for none, an id no
// element has for a URI no document declares (as flatxml's merge compiles it).
fn ns_id_in(d &flatxml.Doc, ns string) u32 {
	return if ns == '' { flatxml.no_local } else { d.ns_id(ns) or { never_ns } }
}

// tag is the name id element i of d is merged by.
@[inline]
pub fn (nm &Naming) tag(d &flatxml.Doc, i u32) u32 {
	if d.ns.len != d.tag.len {
		return d.tag[i] // namespaces not resolved: names as written
	}
	id := if voidptr(d.tab) == nm.tab { nm.id } else { ns_id_in(d, nm.ns) }
	return d.name_in(i, id)
}

// name is the name element i of d is merged by.
pub fn (nm &Naming) name(d &flatxml.Doc, i u32) string {
	return d.tab.name(nm.tag(d, i))
}

// node_name is a node's name as the merge names it; '' for none.
pub fn (nm &Naming) node_name(n flatxml.Node) string {
	return if n.ok() { nm.name(n.doc, n.i) } else { '' }
}

// child is the first child element of n the merge names `name`.
pub fn (nm &Naming) child(n flatxml.Node, name string) flatxml.Node {
	if !n.ok() {
		return n
	}
	id := n.doc.tab.id(name) or { return flatxml.Node{} }
	return nm.child_id(n, id)
}

// child_id is child by name id.
pub fn (nm &Naming) child_id(n flatxml.Node, id u32) flatxml.Node {
	for c in n.children() {
		if nm.tag(c.doc, c.i) == id {
			return c
		}
	}
	return flatxml.Node{}
}

// text_at is the trimmed text of the element at a path of child names below n, each named as the
// merge names it; '' where there is none.
pub fn (nm &Naming) text_at(n flatxml.Node, path string) string {
	mut cur := n
	for name in path.split('/') {
		cur = nm.child(cur, name)
		if !cur.ok() {
			return ''
		}
	}
	return cur.text().trim_space()
}
