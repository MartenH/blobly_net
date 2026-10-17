module flatxml

import runtime

// DocSet is many documents read together. They share one name table, so a name has one id in all
// of them, and so does a namespace: comparing names across documents is comparing integers.
// Documents are parsed in parallel, each into a table of its own, and joined to the set's in the
// order given, so ids do not depend on which thread finished first.
@[heap]
pub struct DocSet {
pub mut:
	docs []&Doc
pub:
	tab &Names = Names.new()
}

pub fn DocSet.new() &DocSet {
	return &DocSet{}
}

@[params]
pub struct LoadOptions {
pub:
	jobs       int  // threads that parse; 0 for one per CPU, at most 16
	namespaces bool // resolve each document's namespaces (in parallel, before it joins the set)
}

// LoadError is a file that could not be read: its path, and why (a message that names the file,
// with the line and column where there is one).
pub struct LoadError {
pub:
	path string
	msg  string
}

struct Parsed {
	k   int
	doc &Doc = unsafe { nil }
	err string
}

// load parses every file in paths and adds the ones that parse, in the order given. A file that
// fails is left out and reported; the others are loaded all the same.
pub fn (mut s DocSet) load(paths []string, opts LoadOptions) []LoadError {
	mut jobs := if opts.jobs > 0 { opts.jobs } else { runtime.nr_cpus() }
	jobs = if jobs > 16 { 16 } else { jobs }
	jobs = if jobs > paths.len { paths.len } else { jobs }
	mut got := []Parsed{len: paths.len}
	if jobs <= 1 {
		for k, p in paths {
			got[k] = parse_one(k, p, opts.namespaces)
		}
	} else {
		mut threads := []thread []Parsed{}
		// each thread takes every jobs-th file, so large and small files spread evenly
		for w in 0 .. jobs {
			threads << spawn parse_every(paths, w, jobs, opts.namespaces)
		}
		for t in threads {
			for p in t.wait() {
				got[p.k] = p
			}
		}
	}
	mut errs := []LoadError{}
	for p in got {
		if p.err != '' {
			errs << LoadError{paths[p.k], p.err}
			continue
		}
		mut d := p.doc
		s.add(mut d)
	}
	return errs
}

fn parse_every(paths []string, first int, step int, namespaces bool) []Parsed {
	mut out := []Parsed{}
	for k := first; k < paths.len; k += step {
		out << parse_one(k, paths[k], namespaces)
	}
	return out
}

fn parse_one(k int, path string, namespaces bool) Parsed {
	mut d := parse_file(path) or { return Parsed{
		k:   k
		err: err.msg()
	} }
	if namespaces {
		d.resolve_namespaces() or {
			d.free()
			return Parsed{
				k:   k
				err: err.msg()
			}
		}
	}
	return Parsed{
		k:   k
		doc: d
	}
}

// add joins a document to the set and returns its number in it: its names (and namespaces, when
// resolved) are given the set's ids, and its own table is released. A document belongs to one
// set; one that already shares another table is refused.
pub fn (mut s DocSet) add(mut d Doc) u32 {
	if voidptr(d.tab) == voidptr(s.tab) {
		// already a member: its number, not a second entry
		for k, m in s.docs {
			if voidptr(m) == voidptr(d) {
				return u32(k)
			}
		}
	} else {
		if !d.own_tab {
			panic('flatxml: ${d.path} already belongs to a set')
		}
		s.join(mut d)
	}
	s.docs << d
	return u32(s.docs.len - 1)
}

@[direct_array_access]
fn (mut s DocSet) join(mut d Doc) {
	mut t := s.tab
	own := d.tab
	// each of the document's ids as the set's; ids 0 and 1 are reserved in both
	mut remap := []u32{len: own.names.len}
	remap[1] = 1
	for id in 2 .. own.names.len {
		name := own.names[id]
		remap[id] = t.intern_hashed(name.str, name.len, own.hash[id])
	}
	for i in 0 .. d.tag.len {
		d.tag[i] = remap[d.tag[i]]
	}
	for a in 0 .. d.attr_tag.len {
		d.attr_tag[a] = remap[d.attr_tag[a]]
	}
	if d.ns.len == d.tag.len {
		mut uremap := []u32{len: own.uris.len}
		for u in 0 .. own.uris.len {
			uremap[u] = t.uri_id(own.uris[u])
		}
		for i in 0 .. d.ns.len {
			d.ns[i] = uremap[d.ns[i]]
		}
		for a in 0 .. d.attr_ns.len {
			d.attr_ns[a] = uremap[d.attr_ns[a]]
		}
		for k, v in own.expanded {
			t.expanded[u64(uremap[u32(k >> 32)]) << 32 | remap[u32(k)]] = remap[v]
		}
		t.split()
	}
	d.tab.free()
	d.tab = t
	d.own_tab = false
}

// free releases every document and the table.
pub fn (mut s DocSet) free() {
	for mut d in s.docs {
		d.free()
	}
	mut t := s.tab
	t.free()
	unsafe { s.docs.free() }
}

// name_id is the id of a name in every document of the set, if any of them uses it.
pub fn (s &DocSet) name_id(name string) ?u32 {
	return s.tab.id(name)
}
