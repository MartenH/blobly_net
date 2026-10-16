module flatxml

import hash

const name_seed = u64(0x9E37_79B9_7F4A_7C15)

// Names is a table of interned names. A document has one of its own; the documents of a set
// share one, so a name has the same id in every document and comparing names across documents
// is comparing integers. Once namespaces are resolved it also holds each name's prefix and local
// name, and the namespace URIs. Ids 0 and 1 are reserved (text_tag, doc_tag).
@[heap]
pub struct Names {
mut:
	names   []string
	hash    []u64 // id -> hash of the name
	slots   []u32 // open-addressing table of ids; 0 marks an empty slot
	prefix  []u32 // id -> its prefix's id (0 for none, not_qname when not a qualified name), once split
	local   []u32 // id -> its local name's id, once split
	uris    []string // namespace id -> URI
	uri_ids map[string]u32
	// (namespace id, local name id) -> the id of the expanded name `{uri}local`, for every element
	// and namespaced attribute of a resolved document (Doc.name_in, Doc.attr_id)
	expanded map[u64]u32
}

// intern_expanded interns the expanded name `{uri}local` of namespace ns and local name id local
// (once per pair) and records it: what tells a name of one namespace from another's spelled
// alike. The caller splits the table afterwards.
fn (mut t Names) intern_expanded(ns u32, local u32) u32 {
	k := u64(ns) << 32 | local
	if id := t.expanded[k] {
		return id
	}
	name := '{${t.uris[ns]}}${t.names[local]}'
	id := t.intern(name.str, name.len)
	t.expanded[k] = id
	return id
}

// Names.new is an empty table.
pub fn Names.new() &Names {
	return &Names{
		names:   ['#text', '#document']
		hash:    [u64(0), 0]
		slots:   []u32{len: 1024}
		uris:    ['', xml_ns_uri, xmlns_ns_uri]
		uri_ids: {
			'':           no_ns
			xml_ns_uri:   xml_ns
			xmlns_ns_uri: xmlns_ns
		}
	}
}

// len is the number of ids given out, the two reserved ones included.
@[inline]
pub fn (t &Names) len() int {
	return t.names.len
}

// name is the name with id.
@[inline]
pub fn (t &Names) name(id u32) string {
	return t.names[id]
}

// uri_count is the number of namespace ids given out, the reserved ones included.
@[inline]
pub fn (t &Names) uri_count() int {
	return t.uris.len
}

// uri is the namespace URI with id.
@[inline]
pub fn (t &Names) uri(id u32) string {
	return t.uris[id]
}

// id is the id of a name, if the table has it.
pub fn (t &Names) id(name string) ?u32 {
	h := hash.wyhash_c(name.str, u64(name.len), name_seed)
	mask := u64(t.slots.len - 1)
	mut k := h & mask
	for {
		id := t.slots[k]
		if id == 0 {
			return none
		}
		if t.hash[id] == h && t.names[id] == name {
			return id
		}
		k = (k + 1) & mask
	}
	return none
}

// intern returns the id of the name in p[..len], adding it the first time it is seen. The
// table is keyed by the bytes in the source, so a name is copied once, not per use.
fn (mut t Names) intern(p &u8, len int) u32 {
	return t.intern_hashed(p, len, hash.wyhash_c(p, u64(len), name_seed))
}

// intern_hashed is intern with the name's hash already known (from another table).
@[direct_array_access]
fn (mut t Names) intern_hashed(p &u8, len int, h u64) u32 {
	mask := u64(t.slots.len - 1)
	mut k := h & mask
	for {
		id := t.slots[k]
		if id == 0 {
			break
		}
		if t.hash[id] == h {
			s := t.names[id]
			if s.len == len && unsafe { C.memcmp(s.str, p, len) } == 0 {
				return id
			}
		}
		k = (k + 1) & mask
	}
	id := u32(t.names.len)
	t.names << unsafe { tos(p, len) }.clone()
	t.hash << h
	t.slots[k] = id
	if t.names.len * 2 > t.slots.len {
		t.grow()
	}
	return id
}

fn (mut t Names) intern_str(s string) u32 {
	return t.intern(s.str, s.len)
}

fn (mut t Names) grow() {
	t.slots = []u32{len: t.slots.len * 2}
	mask := u64(t.slots.len - 1)
	for id in 2 .. t.names.len {
		mut k := t.hash[id] & mask
		for t.slots[k] != 0 {
			k = (k + 1) & mask
		}
		t.slots[k] = u32(id)
	}
}

// split records, for every name not yet split, its prefix (`not_qname` when it is not a
// qualified name) and local name ids. Prefixes and local names are interned too, and split in
// turn: they have no colon, so each is its own local name.
fn (mut t Names) split() {
	for t.prefix.len < t.names.len {
		id := u32(t.prefix.len)
		name := t.names[id]
		c := name.index_u8(`:`)
		if c < 0 || name.starts_with('{') {
			// no prefix: a plain name, or an expanded one (`{uri}local`), whose URI's colons
			// are not a prefix's
			t.prefix << 0
			t.local << id
			continue
		}
		if c == 0 || c == name.len - 1 || name.last_index_u8(`:`) != c {
			t.prefix << not_qname
			t.local << id
			continue
		}
		p := t.intern(name.str, c)
		l := t.intern(unsafe { name.str + c + 1 }, name.len - c - 1)
		t.prefix << p
		t.local << l
	}
}

// uri_id is the namespace id of uri, given out the first time it is seen.
fn (mut t Names) uri_id(uri string) u32 {
	if id := t.uri_ids[uri] {
		return id
	}
	id := u32(t.uris.len)
	// a copy: the value may be a view of a document's source, which free() releases
	owned := uri.clone()
	t.uris << owned
	t.uri_ids[owned] = id
	return id
}

fn (mut t Names) free() {
	unsafe {
		t.names.free()
		t.hash.free()
		t.slots.free()
		t.prefix.free()
		t.local.free()
		t.uris.free()
		t.uri_ids.free()
		t.expanded.free()
	}
}

// name_id is the id of an element or attribute name, if the document's table has it. Once
// namespaces are resolved, prefixes and local names have ids too (`local_id`), and so do `xml`
// and `xmlns`. In a set, the table is the set's, so the name may be used by another document.
pub fn (d &Doc) name_id(name string) ?u32 {
	return d.tab.id(name)
}
