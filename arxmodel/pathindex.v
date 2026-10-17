module arxmodel

import flatxml
import strings

// PathIndex is the AUTOSAR path of every referrable merged node, as a trie: an entry per node
// with its parent entry and its path's hash, nothing else. A path's text is never stored: each
// name is the node's SHORT-NAME, read from the document when wanted, and a path is the names
// of its chain. So the index holds no string and no pointer per entry: the collector has no
// object per path to mark, and indexing builds no path text (a path's hash extends its
// parent's). A lookup hashes the path given and compares it with an entry's chain.
@[heap]
pub struct PathIndex {
pub mut:
	fold bool // paths compared ignoring case, as the merge compares keys
	// per merged node: its element declaration and complex type, or no_type; with no schema
	// none is known and both are empty (decl_of, typ_of)
	decl []u32
	typ  []u32
	// the referrable nodes in the order they were indexed (document order)
	nodes []u32
mut:
	view   &flatxml.Merged = unsafe { nil }
	sn     u32   // the SHORT-NAME id
	at     []u32 // per merged node: 1 + its entry (its index in nodes), or 0 when it has none
	parent []u32 // per entry: 1 + its parent entry, or 0 at the top
	hash   []u64 // per entry: its path's hash (lower case with fold)
	// path -> its holders: an open-addressing table of keys (a key is its first entry), each
	// with its first holder; a key held by several has the list of them all, in document order
	slots []u32 // 0 for an empty slot, else 1 + the key's index
	key_e []u32 // per key: the entry that first had it
	first []u32 // per key: its first holder (a merged node)
	many  []int // per key: its index in lists, or -1 when one node holds it
	lists [][]u32
	dups  []u32 // the entries that made a path held twice, in document order
	// per entry, where its name is: a document of the set (its index), the offset and length of
	// the SHORT-NAME's text in its source; a name whose text was decoded (an entity in it) is
	// not in the source, and is kept in odd (doc odd_doc, offset its index there)
	name_doc []u32
	name_off []u32
	name_len []u32
	odd      []string
	doc_of   map[voidptr]u32 // a document of the set -> its index, while indexing
}

const odd_doc = u32(0xFFFF_FFFF)

const fnv_offset = u64(0xcbf29ce484222325)
const fnv_prime = u64(0x100000001b3)

// path_hash extends a path's hash h by `/` and name (lower case with fold).
@[inline]
fn path_hash(h u64, name string, fold bool) u64 {
	mut x := (h ^ u64(`/`)) * fnv_prime
	for c in name {
		b := if fold && c >= `A` && c <= `Z` { c + 32 } else { c }
		x = (x ^ u64(b)) * fnv_prime
	}
	return x
}

// fold_eq_at reports whether s, from byte at, holds name ignoring ASCII case; in place.
fn fold_eq_at(s string, at int, name string) bool {
	if at + name.len > s.len {
		return false
	}
	for i in 0 .. name.len {
		mut a := s[at + i]
		mut b := name[i]
		if a >= `A` && a <= `Z` {
			a += 32
		}
		if b >= `A` && b <= `Z` {
			b += 32
		}
		if a != b {
			return false
		}
	}
	return true
}

// decl_of is a merged node's element declaration, or no_type.
@[inline]
pub fn (ix &PathIndex) decl_of(n u32) u32 {
	return if int(n) < ix.decl.len { ix.decl[n] } else { no_type }
}

// typ_of is a merged node's complex type, or no_type.
@[inline]
pub fn (ix &PathIndex) typ_of(n u32) u32 {
	return if int(n) < ix.typ.len { ix.typ[n] } else { no_type }
}

// key is how a path is looked up.
pub fn (ix &PathIndex) key(path string) string {
	return if ix.fold { path.to_lower_ascii() } else { path }
}

// name_of is entry e's name: its node's SHORT-NAME, a view of the document's source.
@[inline]
fn (ix &PathIndex) name_of(e u32) string {
	d := ix.name_doc[e]
	if d == odd_doc {
		return ix.odd[ix.name_off[e]]
	}
	return unsafe { tos(ix.view.set.docs[d].src + ix.name_off[e], int(ix.name_len[e])) }
}

// keep_name records where entry e's name, the text name of a node of document doc, is.
fn (mut ix PathIndex) keep_name(name string, doc &flatxml.Doc) {
	src := u64(voidptr(doc.src))
	at := u64(voidptr(name.str))
	if at >= src && at + u64(name.len) <= src + u64(doc.src_len) {
		d := ix.doc_of[voidptr(doc)] or {
			mut k := u32(0)
			for i, x in ix.view.set.docs {
				if voidptr(x) == voidptr(doc) {
					k = u32(i)
					break
				}
			}
			ix.doc_of[voidptr(doc)] = k
			k
		}
		ix.name_doc << d
		ix.name_off << u32(at - src)
		ix.name_len << u32(name.len)
		return
	}
	ix.name_doc << odd_doc
	ix.name_off << u32(ix.odd.len)
	ix.name_len << u32(name.len)
	ix.odd << name.clone()
}

// spells reports whether entry e's path is `path`, as written (exact) or ignoring case.
fn (ix &PathIndex) spells(e u32, path string, exact bool) bool {
	mut end := path.len
	mut x := e + 1
	for x != 0 {
		name := ix.name_of(x - 1)
		start := end - name.len
		if start < 1 || path[start - 1] != `/` {
			return false
		}
		if exact || !ix.fold {
			if unsafe { C.memcmp(path.str + start, name.str, name.len) } != 0 {
				return false
			}
		} else if !fold_eq_at(path, start, name) {
			return false
		}
		end = start - 1
		x = ix.parent[x - 1]
	}
	return end == 0
}

// holders are the merged nodes at a path, in document order.
pub fn (ix &PathIndex) holders(path string) []u32 {
	k := ix.find(path)
	if k < 0 {
		return []u32{}
	}
	if ix.many[k] >= 0 {
		return ix.lists[ix.many[k]]
	}
	// a view of the one holder: no list is made for a path one node holds
	return ix.first[k..k + 1]
}

// path_of is the path of a referrable merged node, as its element spells it (built on request).
pub fn (ix &PathIndex) path_of(n u32) ?string {
	if int(n) >= ix.at.len || ix.at[n] == 0 {
		return none
	}
	return ix.path_at(int(ix.at[n] - 1))
}

// spelled is whether a referrable merged node's path is exactly `path`; without building it.
pub fn (ix &PathIndex) spelled(n u32, path string) bool {
	if int(n) >= ix.at.len || ix.at[n] == 0 {
		return false
	}
	return ix.spells(ix.at[n] - 1, path, true)
}

// write_path writes entry e's path into sb.
fn (ix &PathIndex) write_path(mut sb strings.Builder, e u32) {
	mut chain := []u32{cap: 8}
	mut x := e + 1
	for x != 0 {
		chain << x - 1
		x = ix.parent[x - 1]
	}
	for i := chain.len - 1; i >= 0; i-- {
		sb.write_u8(`/`)
		sb.write_string(ix.name_of(chain[i]))
	}
}

// path_at is the path of the j-th node indexed (nodes[j]).
pub fn (ix &PathIndex) path_at(j int) string {
	// its length first, then the names written from the end: one allocation
	mut n := 0
	mut x := u32(j + 1)
	for x != 0 {
		n += 1 + ix.name_of(x - 1).len
		x = ix.parent[x - 1]
	}
	mut out := []u8{len: n}
	mut end := n
	x = u32(j + 1)
	for x != 0 {
		name := ix.name_of(x - 1)
		end -= name.len
		unsafe { vmemcpy(&out[end], name.str, name.len) }
		end--
		out[end] = `/`
		x = ix.parent[x - 1]
	}
	return out.bytestr()
}

// dup is the paths held by more than one node, in document order, each as the node spells it
// that made it a second holder.
pub fn (ix &PathIndex) dup() []string {
	return ix.dups.map(ix.path_at(int(it)))
}

// dup_count is how many paths more than one node holds.
pub fn (ix &PathIndex) dup_count() int {
	return ix.dups.len
}

// path_count is how many distinct paths are indexed (with fold, compared ignoring case).
pub fn (ix &PathIndex) path_count() int {
	return ix.key_e.len
}

// indexed_keys are the distinct paths as they are looked up, in the order first indexed.
pub fn (ix &PathIndex) indexed_keys() []string {
	return ix.key_e.map(ix.key(ix.path_at(int(it))))
}

// find is the index of the key `path` is, or -1.
fn (ix &PathIndex) find(path string) int {
	if ix.slots.len == 0 || path.len < 2 || path[0] != `/` {
		return -1
	}
	// the hash of the whole text is the hash the entries built segment by segment (each `/`
	// and its name in turn): in place, no segment made
	mut h := fnv_offset
	for c in path {
		b := if ix.fold && c >= `A` && c <= `Z` { c + 32 } else { c }
		h = (h ^ u64(b)) * fnv_prime
	}
	mask := u64(ix.slots.len - 1)
	mut s := h & mask
	for {
		k := ix.slots[s]
		if k == 0 {
			return -1
		}
		e := ix.key_e[k - 1]
		if ix.hash[e] == h && ix.spells(e, path, false) {
			return int(k - 1)
		}
		s = (s + 1) & mask
	}
	return -1
}

// same_path reports whether entries a and b have the same path (ignoring case with fold).
fn (ix &PathIndex) same_path(a u32, b u32) bool {
	mut x := a + 1
	mut y := b + 1
	for x != 0 && y != 0 {
		na := ix.name_of(x - 1)
		nb := ix.name_of(y - 1)
		if !(if ix.fold { na.len == nb.len && fold_eq_at(na, 0, nb) } else { na == nb }) {
			return false
		}
		x = ix.parent[x - 1]
		y = ix.parent[y - 1]
	}
	return x == 0 && y == 0
}

// add indexes node n, named name, below entry up (0: at the top), held by n as well when
// another already holds its path.
fn (mut ix PathIndex) add(n u32, up u32, name string, doc &flatxml.Doc) u32 {
	e := u32(ix.nodes.len)
	ix.keep_name(name, doc)
	h := path_hash(if up == 0 { fnv_offset } else { ix.hash[up - 1] }, name, ix.fold)
	ix.nodes << n
	ix.parent << up
	ix.hash << h
	ix.at[n] = e + 1
	if (ix.key_e.len + 1) * 2 > ix.slots.len {
		ix.grow()
	}
	mask := u64(ix.slots.len - 1)
	mut s := h & mask
	for {
		k := ix.slots[s]
		if k == 0 {
			ix.slots[s] = u32(ix.key_e.len + 1)
			ix.key_e << e
			ix.first << n
			ix.many << -1
			break
		}
		x := int(k - 1)
		if ix.hash[ix.key_e[x]] == h && ix.same_path(ix.key_e[x], e) {
			if ix.many[x] < 0 {
				ix.dups << e
				ix.many[x] = ix.lists.len
				ix.lists << [ix.first[x], n]
			} else {
				ix.lists[ix.many[x]] << n
			}
			break
		}
		s = (s + 1) & mask
	}
	return e + 1
}

fn (mut ix PathIndex) grow() {
	size := if ix.slots.len == 0 { 1024 } else { ix.slots.len * 2 }
	ix.slots = []u32{len: size}
	mask := u64(size - 1)
	for k, e in ix.key_e {
		mut s := ix.hash[e] & mask
		for ix.slots[s] != 0 {
			s = (s + 1) & mask
		}
		ix.slots[s] = u32(k + 1)
	}
}
