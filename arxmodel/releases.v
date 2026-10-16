module arxmodel

import os

// Release is where a schema stands among the releases of its vocabulary, read from its file
// name, `<prefix>_<release>[_<qualifier>].xsd`: the release is the first part after the prefix
// that is one number (`_00049`) or numbers joined by `-` (`_4-2-2`). Releases compare only within
// one family (one prefix): numbered releases came after the dotted ones, so any number orders
// after any dotted release, and within each form the numbers compare in turn. A qualifier
// (`_STRICT`) does not change the rank. Case does not matter.
pub struct Release {
pub:
	prefix    string // the family: the name before the release, in lower case
	numbered  bool   // one number, rather than numbers joined by `-`
	parts     []int
	qualifier string // what follows the release, in lower case
}

// release_of reads a schema file name's release; none when no part of it is one.
pub fn release_of(name string) ?Release {
	words := os.file_name(name).all_before_last('.').to_lower().split('_')
	for k in 1 .. words.len {
		nums := words[k].split('-')
		if nums.any(it == '' || !it.bytes().all(it.is_digit())) {
			continue
		}
		return Release{
			prefix:    words[..k].join('_')
			numbered:  nums.len == 1
			parts:     nums.map(it.int())
			qualifier: words[k + 1..].join('_')
		}
	}
	return none
}

// compare orders two releases of one family: negative when a is older, positive when newer, 0
// for one release.
pub fn (a Release) compare(b Release) int {
	if a.numbered != b.numbered {
		return if a.numbered { 1 } else { -1 }
	}
	for k in 0 .. if a.parts.len < b.parts.len { a.parts.len } else { b.parts.len } {
		if a.parts[k] != b.parts[k] {
			return a.parts[k] - b.parts[k]
		}
	}
	return a.parts.len - b.parts.len
}

pub fn (r Release) str() string {
	return r.parts.map(it.str()).join('-')
}

// Governing is the schema whose rules govern the merged model of one namespace: the newest
// release the files declare, or, when that one is not at hand or did not compile, the newest one
// that did.
pub struct Governing {
pub mut:
	ns       string
	use      int = -1 // index into Schemas.uses; -1 when no schema of the namespace compiled
	newest   int = -1 // the newest release declared, whether or not it compiled
	note     string // why the governing schema is not the newest declared
	family   string // the family the release is chosen from
	ranked   []int  // the family's schemas, oldest first
	others   []int  // schemas of other families in the namespace, which are not ranked against it
	unranked []int  // schemas whose names give no release
}

// choose_governing picks, for each namespace the documents declare, the schema that governs.
// Releases rank only within a family; where a namespace has several, the family most documents
// declare is ranked and the others are reported.
pub fn (mut sc Schemas) choose_governing() {
	mut rels := map[int]Release{}
	for k, u in sc.uses {
		if r := release_of(u.name) {
			rels[k] = r
		}
	}
	mut nss := []string{}
	for u in sc.uses {
		if u.ns !in nss {
			nss << u.ns
		}
	}
	for ns in nss {
		mut g := Governing{
			ns: ns
		}
		// the family most documents declare, the first met on a tie
		mut docs := map[string]int{}
		mut families := []string{}
		for k, u in sc.uses {
			if u.ns != ns {
				continue
			}
			r := rels[k] or {
				g.unranked << k
				continue
			}
			if r.prefix !in docs {
				families << r.prefix
			}
			docs[r.prefix] += u.docs.len
		}
		for f in families {
			if g.family == '' || docs[f] > docs[g.family] {
				g.family = f
			}
		}
		for k, u in sc.uses {
			if u.ns != ns || k !in rels {
				continue
			}
			if rels[k].prefix != g.family {
				g.others << k
			} else {
				g.ranked << k
			}
		}
		g.ranked.sort_with_compare(fn [rels] (a &int, b &int) int {
			c := rels[*a].compare(rels[*b])
			return if c != 0 { c } else { *a - *b }
		})
		for k in g.ranked {
			compiled := sc.uses[k].rules != unsafe { nil }
			vs := if g.newest < 0 { 1 } else { rels[k].compare(rels[g.newest]) }
			// one release under two spellings: one that compiled stands for it
			if vs > 0 || (vs == 0 && compiled && sc.uses[g.newest].rules == unsafe { nil }) {
				g.newest = k
			}
			if compiled && (g.use < 0 || rels[k].compare(rels[g.use]) >= 0) {
				g.use = k
			}
		}
		if g.use < 0 {
			// nothing ranked compiled: an unranked schema that did, if only one did
			compiled := g.unranked.filter(sc.uses[it].rules != unsafe { nil })
			if compiled.len == 1 {
				g.use = compiled[0]
				g.note = '${sc.uses[g.use].name} gives no release, and is the only schema compiled'
			} else if compiled.len > 1 {
				g.note = 'no release can be read from the names of the schemas compiled'
			} else {
				g.note = 'no schema compiled'
			}
		} else if sc.uses[g.newest].rules == unsafe { nil } {
			g.note = 'the newest declared, ${sc.uses[g.newest].name}, ${sc.uses[g.newest].error}; the newest at hand governs'
		}
		sc.governing << g
	}
}

// missing_roles lists the rules of an older schema that the governing one has no rule for: by
// qualified name and element, sorted.
pub fn missing_roles(older &RuleSet, gov &RuleSet) []string {
	mut have := map[string]bool{}
	for r in gov.rules {
		have['${r.name} ${r.element}'] = true
	}
	mut out := []string{}
	for r in older.rules {
		if '${r.name} ${r.element}' !in have {
			out << '${r.name} (${r.element})'
		}
	}
	out.sort()
	return out
}

// Undeclared is an element name in the documents that the governing schema does not declare.
pub struct Undeclared {
pub:
	name  string
	count int    // occurrences in all documents
	files int    // documents it occurs in
	first string // its first position
}

// undeclared_elements lists the element names, in the governing schema's namespace, that the
// documents of m use and the schema declares nowhere, most frequent first.
pub fn undeclared_elements(m &Model, sc &Schemas, g Governing) []Undeclared {
	if g.use < 0 {
		return []
	}
	s := sc.uses[g.use].schema
	tab := m.set.tab
	// the declared names as the set's name ids
	mut declared := []bool{len: tab.len()}
	for e in s.elements {
		if id := tab.id(s.names[e.name.local]) {
			declared[id] = true
		}
	}
	mut count := map[u32]int{}
	mut files := map[u32]int{}
	mut first := map[u32]string{}
	for d in m.set.docs {
		ns := d.ns_id(g.ns) or { continue }
		mut seen := map[u32]bool{}
		for i in 1 .. d.len() {
			if !d.is_element(u32(i)) || d.ns_of(u32(i)) != ns {
				continue
			}
			id := d.local_id(u32(i))
			if declared[id] {
				continue
			}
			if id !in count {
				first[id] = d.pos(u32(i))
			}
			count[id]++
			if id !in seen {
				seen[id] = true
				files[id]++
			}
		}
	}
	mut out := []Undeclared{}
	for id, n in count {
		out << Undeclared{tab.name(id), n, files[id], first[id]}
	}
	out.sort_with_compare(fn (a &Undeclared, b &Undeclared) int {
		if a.count != b.count {
			return b.count - a.count
		}
		return compare_strings(a.name, b.name)
	})
	return out
}
