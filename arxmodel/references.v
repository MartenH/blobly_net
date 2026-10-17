module arxmodel

import flatxml
import flatxml.xsd
import strings

// A referrable element names itself by its SHORT-NAME child; its AUTOSAR path is the SHORT-NAMEs
// of it and its referrable ancestors, `/Pkg/Sub/Name`. A variation point does not enter the path.
const short_name = 'SHORT-NAME'

// A reference element carries its target's kind in this attribute, an enumeration of the element
// names it may point at; the schema says which elements have it.
const dest_attribute = 'DEST'

// a reference resolved against another base than the root
const base_attribute = 'BASE'

// no_type marks a merged node whose declaration or type the schema does not give.
const no_type = u32(0xFFFF_FFFF)

// Typing is what the schema says about element kinds and references. A class is a named model
// group: a type is a kind of every class whose group its content model uses. The referrable
// classes are the groups whose own content declares SHORT-NAME. What is asked of a complex type
// is worked out once, the first time it is asked.
@[heap]
pub struct Typing {
mut:
	s          &xsd.Schema = unsafe { nil }
	referrable map[u32]bool     // groups declaring SHORT-NAME in their own content
	child_decl map[string]u32   // holder type and child element name -> element declaration
	kinds      map[u32][]string // complex type -> the classes it is a kind of
	has_name   map[u32]bool     // complex type -> its elements are referrable
	dests      map[u32][]string // element declaration of a reference -> the DESTs it may give
	not_ref    map[u32]bool     // element declarations known not to be references
	read       map[u32]bool     // complex types already read
}

// new_typing reads a schema's referrable classes; the rest is read as it is asked.
pub fn new_typing(s &xsd.Schema) &Typing {
	mut t := &Typing{
		s: s
	}
	for g, mg in s.groups {
		if t.declares_name(mg.root) {
			t.referrable[u32(g)] = true
		}
	}
	return t
}

// declares_name reports whether a content model declares SHORT-NAME, not counting the groups it
// references.
fn (t &Typing) declares_name(p u32) bool {
	if p == xsd.no_particle {
		return false
	}
	mut stack := [p]
	for stack.len > 0 {
		q := stack.pop()
		pt := t.s.particles[q]
		if pt.kind == .element {
			if t.s.names[t.s.elements[pt.term].name.local] == short_name {
				return true
			}
			continue
		}
		for c in t.s.particle_children(q) {
			if t.s.particles[c].group == xsd.no_group {
				stack << c
			}
		}
	}
	return false
}

// read_type works out, once, a complex type's classes, whether its elements are referrable, and
// the declarations of its children.
fn (mut t Typing) read_type(ct u32) {
	if ct in t.read {
		return
	}
	t.read[ct] = true
	mut ks := []string{}
	mut named := false
	root := t.s.complex_types[ct].particle
	mut stack := []u32{}
	if root != xsd.no_particle {
		stack << root
	}
	for stack.len > 0 {
		q := stack.pop()
		pt := t.s.particles[q]
		if pt.group != xsd.no_group {
			g := t.s.names[t.s.groups[pt.group].name.local]
			if g !in ks {
				ks << g
			}
			if pt.group in t.referrable {
				named = true
			}
		}
		if pt.kind == .element {
			key := '${ct} ${t.s.names[t.s.elements[pt.term].name.local]}'
			if key !in t.child_decl {
				t.child_decl[key] = pt.term
			}
			continue
		}
		for c in t.s.particle_children(q) {
			stack << c
		}
	}
	if t.referrable.len == 0 {
		named = '${ct} ${short_name}' in t.child_decl
	}
	t.kinds[ct] = ks
	t.has_name[ct] = named
}

// kinds_of is what a complex type is a kind of: the classes its content uses.
pub fn (mut t Typing) kinds_of(ct u32) []string {
	t.read_type(ct)
	return t.kinds[ct]
}

// referrable_type reports whether elements of a complex type are referrable.
pub fn (mut t Typing) referrable_type(ct u32) bool {
	t.read_type(ct)
	return t.has_name[ct]
}

// child is the declaration of a child element of a holder of complex type ct.
fn (mut t Typing) child(ct u32, name string) ?u32 {
	t.read_type(ct)
	return t.child_decl['${ct} ${name}'] or { return none }
}

// type_of is an element declaration's complex type, or no_type.
fn (t &Typing) type_of(decl u32) u32 {
	e := t.s.elements[decl]
	return if e.typ.kind == .complex { e.typ.idx } else { no_type }
}

// reference_dests says whether an element declaration is a reference (its type carries a DEST
// attribute), and the DESTs it may give: that attribute type's enumeration, empty if it has none.
pub fn (mut t Typing) reference_dests(decl u32) ?[]string {
	if decl in t.not_ref {
		return none
	}
	if ds := t.dests[decl] {
		return ds
	}
	ct := t.type_of(decl)
	if ct != no_type {
		for use in t.s.complex_types[ct].attrs {
			a := t.s.attributes[use.decl]
			if t.s.names[a.name.local] != dest_attribute {
				continue
			}
			mut allowed := []string{}
			if a.typ.kind == .simple {
				allowed = t.s.simple_types[a.typ.idx].enums.clone()
			}
			t.dests[decl] = allowed
			return allowed
		}
	}
	t.not_ref[decl] = true
	return none
}

// root_decl is the global declaration of a root element.
fn (t &Typing) root_decl(name string) ?u32 {
	for d in t.s.global_elements() {
		if t.s.names[t.s.elements[d].name.local] == name {
			return d
		}
	}
	return none
}

// PathIndex is every referrable element of a merged model by its AUTOSAR path, and each node's
// declaration where the schema gives it.

// index_paths walks the merged model in document order and gives each referrable element its
// path. With a schema, an element is referrable when its type is a kind of a referrable class;
// without one, or below an element the schema does not declare, when it has a SHORT-NAME.
@[heap]
pub fn index_paths(v &flatxml.Merged, mut ty Typing, typed bool, fold bool) &PathIndex {
	mut ix := &PathIndex{
		fold: fold
		decl: if typed { []u32{len: v.len(), init: no_type} } else { []u32{} }
		typ:  if typed { []u32{len: v.len(), init: no_type} } else { []u32{} }
		at:   []u32{len: v.len()}
		view: v
	}
	root := v.root()
	if !root.ok() {
		return ix
	}
	sn := v.set.tab.id(short_name) or { u32(0xFFFF_FFFF) }
	ix.sn = sn
	if typed {
		if d := ty.root_decl(root.name()) {
			ix.decl[root.i] = d
			ix.typ[root.i] = ty.type_of(d)
		}
	}
	mut stack := [root.i]
	// per stack entry, the entry of its nearest referrable ancestor (1 + it, 0 for none)
	mut base := [u32(0)]
	mut kids := []flatxml.MNode{}
	mut memo := map[u64]u32{}
	for stack.len > 0 {
		n := v.node(stack.pop())
		mut up := base.pop()
		ct := ix.typ_of(n.i)
		named := !typed || ct == no_type || ty.referrable_type(ct)
		name, doc := if named {
			short_name_and_doc(n, sn)
		} else {
			'', unsafe { &flatxml.Doc(nil) }
		}
		if name != '' {
			up = ix.add(n.i, up, name, doc)
		}
		kids.clear()
		for c in n.children() {
			kids << c
		}
		for j := kids.len - 1; j >= 0; j-- {
			c := kids[j]
			if ct != no_type {
				// the child's declaration, looked up once per holder type and name id
				mk := u64(ct) << 32 | c.tag()
				d := memo[mk] or {
					found := ty.child(ct, c.name()) or { no_type }
					memo[mk] = found
					found
				}
				if d != no_type {
					ix.decl[c.i] = d
					ix.typ[c.i] = ty.type_of(d)
				}
			}
			stack << c.i
			base << up
		}
	}
	return ix
}

// short_name_of is a node's SHORT-NAME text: its single child of that name, or, where the rules
// keep every occurrence apart (the built-in identity rules), its first child of that name — as the
// merge names it, so with a local namespace a document binding it to `ar` is indexed alike.
fn short_name_and_doc(n flatxml.MNode, sn u32) (string, &flatxml.Doc) {
	c := n.child_id(sn, '')
	if c.ok() {
		f := c.fragment(0)
		return trimmed(f.text()), f.doc
	}
	for k in n.children() {
		if k.tag() == sn {
			f := k.fragment(0)
			return trimmed(f.text()), f.doc
		}
	}
	return '', unsafe { &flatxml.Doc(nil) }
}

fn short_name_of(n flatxml.MNode, sn u32) string {
	c := n.child_id(sn, '')
	if c.ok() {
		return trimmed(c.text())
	}
	for k in n.children() {
		if k.tag() == sn {
			return trimmed(k.text())
		}
	}
	return ''
}

// merged_path is a merged node's AUTOSAR path: its nearest referrable ancestor's (or its own)
// path, then, after `#`, the elements below it down to the node, each with its key where the
// merge gives it one (`NAME[key]`); `#` and the elements from the root where no ancestor is
// referrable.
pub fn merged_path(n flatxml.MNode, ix &PathIndex) string {
	// the nodes below the nearest referrable ancestor (or the root), n first; then the path
	// written once into one builder, keys shown and escaped as they are written
	mut chain := []u32{cap: 8}
	mut cur := n
	mut entry := u32(0) // 1 + the ancestor's entry, 0 for none
	for cur.ok() {
		if int(cur.i) < ix.at.len && ix.at[cur.i] != 0 {
			entry = ix.at[cur.i]
			break
		}
		chain << cur.i
		cur = cur.parent()
	}
	mut sb := strings.new_builder(96)
	if entry != 0 {
		ix.write_path(mut sb, entry - 1)
	}
	if chain.len > 0 {
		sb.write_u8(`#`)
		for i := chain.len - 1; i >= 0; i-- {
			if i < chain.len - 1 {
				sb.write_u8(`/`)
			}
			write_segment(mut sb, ix.view.node(chain[i]))
		}
	}
	return sb.str()
}

// write_segment writes a node below a referrable one as a path shows it: its name, and its key
// where the merge gives it one (`NAME[key]`), an item keyed by its content by its place among
// its namesakes (`NAME[#2]`).
fn write_segment(mut sb strings.Builder, m flatxml.MNode) {
	name := m.name()
	sb.write_string(name)
	k := m.key()
	if flatxml.empty_key(k) || is_list_key(k, name) {
		return
	}
	sb.write_u8(`[`)
	if k.starts_with(content_mark) {
		sb.write_u8(`#`)
		sb.write_decimal(place_of(m))
	} else {
		// show_key then escape_key, a byte at a time
		for c in k {
			if c == flatxml.key_sep[0] {
				sb.write_u8(`,`)
			} else if c == flatxml.key_list_sep[0] {
				sb.write_u8(`|`)
			} else {
				if c == `\\` || c == `[` || c == `]` {
					sb.write_u8(`\\`)
				}
				sb.write_u8(c)
			}
		}
	}
	sb.write_u8(`]`)
}

// is_list_key reports whether k is list_key(name), without making it.
fn is_list_key(k string, name string) bool {
	return k.len == name.len + 1 && k[0] == flatxml.key_sep[0]
		&& unsafe { C.memcmp(k.str + 1, name.str, name.len) } == 0
}

// escape_key is a key as a path shows it: its `\\`, `[` and `]` escaped with `\\`, so a path is
// read back segment by segment whatever its keys hold (see `segments`).
pub fn escape_key(k string) string {
	if !k.contains_any('[]\\') {
		return k
	}
	return k.replace('\\', '\\\\').replace('[', '\\[').replace(']', '\\]')
}

// place_of is a node's place among its parent's children of its name, from 1.
fn place_of(n flatxml.MNode) int {
	p := n.parent()
	if !p.ok() {
		return 1
	}
	mut k := 0
	for c in p.children() {
		if c.tag() == n.tag() {
			k++
		}
		if c.i == n.i {
			break
		}
	}
	return k
}

fn join_path(path string, inner []string) string {
	return if inner.len == 0 { path } else { '${path}#${inner.reverse().join('/')}' }
}

// merged_of finds the merged node an element of a document went into: down from the root, the
// child with that element among its fragments.
pub fn merged_of(v &flatxml.Merged, d &flatxml.Doc, i u32) ?flatxml.MNode {
	mut chain := []u32{}
	mut cur := d.node(i)
	for cur.ok() {
		chain << cur.i
		cur = cur.parent()
	}
	mut m := v.root()
	if chain.len == 0 || !m.ok() || !has_fragment(m, d, chain.last()) {
		return none
	}
	for j := chain.len - 2; j >= 0; j-- {
		mut found := false
		for c in m.children() {
			if has_fragment(c, d, chain[j]) {
				m = c
				found = true
				break
			}
		}
		if !found {
			return none
		}
	}
	return m
}

fn has_fragment(n flatxml.MNode, d &flatxml.Doc, i u32) bool {
	for k in 0 .. n.fragment_count() {
		f := n.fragment(k)
		if voidptr(f.doc) == voidptr(d) && f.i == i {
			return true
		}
	}
	return false
}

// RefView is a merged model references are resolved against, with its path index.
pub struct RefView {
pub mut:
	view &flatxml.Merged = unsafe { nil }
	ix   &PathIndex      = unsafe { nil }
}

// RefStats is what the reference layer counted.
pub struct RefStats {
pub mut:
	checked int
	by_top  map[string]int // `kind /Top` -> count, for unresolved and external references
}

// reference_findings resolves every reference of the merged model (an element whose
// declaration's type carries a DEST attribute; with no schema, an element with a DEST, whose
// target may then be of any kind) against the paths of the model and of the extra
// views (models loaded only to resolve references):
// - `empty`: no path;
// - `relative`: BASE, or a path not starting at the root; not resolved here;
// - `external`: nothing at the path, and its nearest existing ancestor is a package (the policy's
//   package_element), or nothing of it exists: definitions not loaded;
// - `unresolved`: nothing at the path, and its nearest existing ancestor is another element,
//   whose content is loaded;
// - `wrong_kind`: a DEST the reference may not give, or no holder of the path that is the DEST
//   element or a kind of it;
// - `case_mismatch`: found only by comparing the path ignoring case, as the merge compares keys.
// A path held by more than one element is itself a finding (`duplicate_path`).
pub fn reference_findings(mut v flatxml.Merged, ix &PathIndex, mut ty Typing, extra []RefView, p Policy) ([]Finding, RefStats) {
	mut out := []Finding{}
	mut st := RefStats{}
	for path in ix.dup() {
		hs := ix.holders(path)
		mut at := []string{}
		for h in hs {
			at << v.node(h).fragments().map(v.pos(it))
		}
		names := hs.map(v.node(it).name())
		out << Finding{
			layer:    .reference
			kind:     'duplicate_path'
			what:     names[0]
			severity: p.severity(.reference, 'duplicate_path', names[0])
			path:     path
			message:  'one path held by ${hs.len} elements (${names.join(', ')}), which the merge keeps apart'
			at:       at
		}
	}
	mut views := [RefView{
		view: v
		ix:   ix
	}]
	views << extra
	typed := ty.s != unsafe { nil }
	// with no schema, a reference is what carries a DEST: read by the name's id, as most nodes
	// carry none
	dest_id := v.set.tab.id(dest_attribute) or { no_type }
	for i in 0 .. v.len() {
		mut allowed := []string{}
		if typed {
			d := ix.decl[i]
			if d == no_type {
				continue
			}
			allowed = ty.reference_dests(d) or { continue }
		} else if !carries_dest(v.node(u32(i)), dest_id) {
			continue
		}
		n := v.node(u32(i))
		st.checked++
		target := trimmed(n.text())
		dest := n.attr(dest_attribute)
		base := n.attr(base_attribute)
		mut kind := ''
		mut msg := ''
		if target == '' {
			kind, msg = 'empty', 'a reference with no path (${dest})'
		} else if base != '' || !target.starts_with('/') {
			via := if base != '' { ' (${base})' } else { '' }
			kind, msg = 'relative', 'a reference to `${target}` relative to a base${via}, not resolved'
		} else if allowed.len > 0 && dest !in allowed {
			kind, msg = 'wrong_kind', '${n.name()} may not point at a ${dest}: `${target}`'
		} else {
			kind, msg = resolve(target, dest, views, p.package_element, mut ty)
			if kind == 'unresolved' || kind == 'external' {
				st.by_top['${kind} ${top_of(target)}']++
			}
		}
		if kind == '' {
			continue
		}
		out << Finding{
			layer:    .reference
			kind:     kind
			what:     n.name()
			severity: p.severity(.reference, kind, n.name())
			path:     merged_path(n, ix)
			message:  msg
			at:       n.fragments().map(v.pos(it))
			base:     base
			dest:     dest
		}
	}
	return out, st
}

// carries_dest reports whether a merged node has a non-empty DEST (dest_id: the name's id), as
// its first fragment holding the attribute gives it.
fn carries_dest(n flatxml.MNode, dest_id u32) bool {
	if dest_id == no_type {
		return false
	}
	for k in 0 .. n.fragment_count() {
		f := n.fragment(k)
		if val := f.doc.attr_by_id(f.i, dest_id) {
			return val != ''
		}
	}
	return false
}

fn top_of(path string) string {
	return '/' + path.all_after('/').all_before('/')
}

// resolve looks a path up in each view: the kind of finding and its message, or '' when a holder
// fits DEST and is spelled as the reference spells it.
fn resolve(target string, dest string, views []RefView, package string, mut ty Typing) (string, string) {
	mut kinds := []string{}
	mut spelled := ''
	for rv in views {
		for h in rv.ix.holders(target) {
			name := rv.view.node(h).name()
			ct := rv.ix.typ_of(h)
			// with no schema, any kind fits: DEST may name a class
			untyped := ty.s == unsafe { nil }
			if untyped || name == dest || (ct != no_type && dest in ty.kinds_of(ct)) {
				if rv.ix.spelled(h, target) {
					return '', ''
				}
				spelled = rv.ix.path_of(h) or { '' }
			} else if name !in kinds {
				kinds << name
			}
		}
	}
	if spelled != '' {
		return 'case_mismatch', '`${target}` is spelled `${spelled}` where it is defined'
	}
	if kinds.len > 0 {
		return 'wrong_kind', '`${target}` is a ${kinds.join(' and a ')}, not the ${dest} the reference says'
	}
	// the nearest ancestor that exists: a package (or none) means definitions not loaded
	mut up := target
	for up.contains('/') {
		up = up.all_before_last('/')
		if up == '' {
			break
		}
		mut found := []string{}
		for rv in views {
			for h in rv.ix.holders(up) {
				found << rv.view.node(h).name()
			}
		}
		if found.len == 0 {
			continue
		}
		if package in found {
			return 'external', 'nothing at `${target}` (${dest}); the package ${up} holds no such element in the files loaded'
		}
		return 'unresolved', 'nothing at `${target}` (${dest}); ${up} is a ${found[0]} with no such element'
	}
	return 'external', 'nothing at `${target}` (${dest}); no file loaded has ${top_of(target)}'
}
