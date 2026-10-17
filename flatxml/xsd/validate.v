module xsd

import flatxml

pub const xsi_ns_uri = 'http://www.w3.org/2001/XMLSchema-instance'

pub enum FindingKind {
	undeclared_element   // no declaration for the element where it is (or no global one, for the root)
	undeclared_attribute // the element's type declares no such attribute
	missing_attribute    // a required attribute is not there
	text_not_allowed     // text in element-only or empty content
	children_not_allowed // child elements in simple or empty content
	abstract_type        // the element's type is abstract
	not_nillable         // xsi:nil="true" on an element that is not nillable (none is, here)
	invalid_value        // an element's text or an attribute's value is not a value of its type
	duplicate_id         // an ID already used by another element in the document
	unknown_idref        // an IDREF naming no ID in the document
	unbound_prefix       // a QName value whose prefix is not declared where it is written
	unexpected_element   // a child in the wrong place, or one too many
	missing_element      // a child the content model requires is not there
	unsupported          // the document uses something this validator does not support (xsi:type)
}

// Finding is one way the document does not match the schema, at node `node`.
pub struct Finding {
pub:
	node u32
	kind FindingKind
	msg  string
}

// Validation is a document checked against a schema: the declaration each element matched, one
// array beside the document's nodes, and what does not match.
pub struct Validation {
pub mut:
	decl     []u32 // per node: element declaration + 1; 0 for a text node or an element not matched
	findings []Finding
	total    int // findings found; at most Options.max_findings are kept
}

@[params]
pub struct Options {
pub:
	max_findings int = 1000
}

// declared is the element declaration node i matched.
pub fn (v &Validation) declared(i u32) ?u32 {
	if int(i) >= v.decl.len || v.decl[i] == 0 {
		return none
	}
	return v.decl[i] - 1
}

// valid reports whether nothing was found.
pub fn (v &Validation) valid() bool {
	return v.total == 0
}

// What a complex type allows, gathered once per type the document uses.
struct TypeIndex {
mut:
	children map[u64]u32 // child element name -> its slot
	decls    []u32       // per slot: the element declaration
	attrs    map[u64]AttrUse
	required []u32 // declarations of the required attributes
}

struct Validator {
mut:
	d       &flatxml.Doc
	s       &Schema
	opts    Options
	v       Validation
	ns_map  []u32 // document namespace id -> schema namespace id (no_match when the schema has none)
	name_map []u32 // document name id -> schema name id
	index   []&TypeIndex // per complex type, filled on first use
	matcher Matcher           // runs the patterns, a DFA each
	checked   []bool          // per simple type: whether its values have anything to check
	ids       map[string]u32  // the IDs seen, to the element that carries each
	idrefs    []IdRef         // the references to IDs, checked once every ID is known
	firsts    []&FirstSet     // per particle: what it can begin with, made on first use
	too_many  bool            // check_content: an element passed over for having its maximum
	dfas      []&ContentDfa   // per complex type: its automaton, nil when the walker decides
	dfa_made  []bool          // per complex type: whether dfas holds its answer
	frames    []Frame         // check_content's stack, kept between elements
	xsi     u32 // the document's id for the xsi namespace
}

const no_match = u32(0xFFFF_FFFF)

// validate checks document d against schema s: each element gets the declaration its context
// gives it, and every element, attribute and run of text the schema does not allow is a finding.
// Namespaces are resolved first; a document that is not namespace-well-formed is an error.
pub fn validate(mut d flatxml.Doc, s &Schema, opts Options) !Validation {
	mut c := new_checker(s, opts)
	return c.validate(mut d)
}

// Checker validates documents against one schema, keeping what it works out about the schema
// from one document to the next: each complex type's index of children and attributes and its
// content automaton, each particle's first set, each pattern's automaton. A document uses
// hundreds of types, and every document of a model the same ones, so validating many with one
// checker builds each once. One per thread: a checker is not safe to share.
@[heap]
pub struct Checker {
mut:
	s        &Schema
	opts     Options
	index    []&TypeIndex
	checked  []bool
	firsts   []&FirstSet
	dfas     []&ContentDfa
	dfa_made []bool
	matcher  Matcher
}

// new_checker is a checker for schema s; opts apply to every document it validates.
pub fn new_checker(s &Schema, opts Options) &Checker {
	return &Checker{
		s:        s
		opts:     opts
		index:    []&TypeIndex{len: s.complex_types.len, init: unsafe { nil }}
		checked:  s.checked()
		firsts:   []&FirstSet{len: s.particles.len, init: unsafe { nil }}
		dfas:     []&ContentDfa{len: s.complex_types.len, init: unsafe { nil }}
		dfa_made: []bool{len: s.complex_types.len}
		matcher:  Matcher{
			use_dfa: true
		}
	}
}

// validate checks document d, as the function validate does, with what earlier documents taught
// the checker.
pub fn (mut c Checker) validate(mut d flatxml.Doc) !Validation {
	mut vr := new_validator(mut d, c)!
	vr.walk()
	vr.check_idrefs()
	// the arrays are the checker's own (filled in place); the matcher is a value, so taken back
	c.matcher = vr.matcher
	return vr.v
}

fn new_validator(mut d flatxml.Doc, c &Checker) !Validator {
	d.resolve_namespaces()!
	mut vr := Validator{
		d:        d
		s:        c.s
		opts:     c.opts
		v:        Validation{
			decl: []u32{len: d.len()}
		}
		xsi:      d.ns_id(xsi_ns_uri) or { no_match }
		index:    c.index
		checked:  c.checked
		firsts:   c.firsts
		dfas:     c.dfas
		dfa_made: c.dfa_made
		matcher:  c.matcher
	}
	vr.map_names()
	return vr
}

// IdRef is a reference to an ID, written at node node (an element, or an element carrying it).
struct IdRef {
	node u32
	id   string
}

// record_reference keeps what a valid value means beyond itself: an ID (unique in the document),
// a reference to IDs (checked once every ID is known), a QName (its prefix declared where it is
// written).
fn (mut vr Validator) record_reference(i u32, root Builtin, v string) {
	match root {
		.id {
			if first := vr.ids[v] {
				if vr.keep() {
					line, _ := vr.d.line_col(first)
					vr.add(i, .duplicate_id, 'ID "${v}" is already used, by <${vr.d.name(first)}> on line ${line}')
				}
			} else {
				vr.ids[v] = i
			}
		}
		.idref {
			vr.idrefs << IdRef{i, v}
		}
		.idrefs {
			for item in v.split(' ') {
				vr.idrefs << IdRef{i, item}
			}
		}
		.qname, .notation {
			colon := v.index_u8(`:`)
			if colon > 0 {
				prefix := v[..colon]
				if _ := vr.d.ns_for_prefix(i, prefix) {
					return
				}
				if vr.keep() {
					vr.add(i, .unbound_prefix, 'the prefix of "${v}" is not declared where it is written')
				}
			}
		}
		else {}
	}
}

// check_idrefs reports each reference to an ID no element carries.
fn (mut vr Validator) check_idrefs() {
	for r in vr.idrefs {
		if r.id !in vr.ids && vr.keep() {
			vr.add(r.node, .unknown_idref, 'IDREF "${r.id}" names no ID in the document')
		}
	}
}

// map_names translates the document's namespace and name ids to the schema's once, so each
// element costs two array reads to look up.
fn (mut vr Validator) map_names() {
	vr.ns_map = []u32{len: vr.d.tab.uri_count(), init: no_match}
	for i in 0 .. vr.d.tab.uri_count() {
		uri := vr.d.tab.uri(u32(i))
		vr.ns_map[i] = vr.s.uri_ids[uri] or { no_match }
	}
	vr.name_map = []u32{len: vr.d.tab.len(), init: no_match}
	for i in 0 .. vr.d.tab.len() {
		name := vr.d.tab.name(u32(i))
		vr.name_map[i] = vr.s.name_ids[name] or { no_match }
	}
}

// key is element i's name as a schema key, or none when the schema has no such name.
fn (vr &Validator) key(i u32) ?u64 {
	ns := vr.ns_map[vr.d.ns_of(i)]
	local := vr.name_map[vr.d.local_id(i)]
	if ns == no_match || local == no_match {
		return none
	}
	return QName{ns, local}.key()
}

fn (mut vr Validator) walk() {
	d := vr.d
	mut k := 1
	// Each element in document order; an element that matches nothing is reported once and its
	// subtree skipped, since nothing inside it can be matched either.
	for k < d.len() {
		i := u32(k)
		p := d.parent[i]
		if d.is_text(i) {
			vr.check_text(i, p)
			k++
			continue
		}
		// xsi:type replaces the declared type, which this validator cannot follow: the subtree is
		// not assessed, and the finding says why
		if vr.xsi_type(i) {
			vr.v.decl[i] = 0
			if vr.keep() {
				vr.add(i, .unsupported, 'xsi:type on <${d.name(i)}> is not supported')
			}
			k = int(d.end[i])
			continue
		}
		// the parent's content check has matched most elements already
		decl := if vr.v.decl[i] != 0 {
			vr.v.decl[i] - 1
		} else {
			vr.match_element(i, p) or {
				k = int(d.end[i])
				continue
			}
		}
		vr.v.decl[i] = decl + 1
		vr.check_element(i, decl)
		k++
	}
}

// located_elsewhere is the namespace of element i when the schema declares nothing in it and the
// root's xsi:schemaLocation names a schema for it: the document expects a schema it was not given.
fn (vr &Validator) located_elsewhere(i u32) ?string {
	if vr.xsi == no_match {
		return none
	}
	uri := vr.d.ns_uri(vr.d.ns_of(i))
	root := vr.d.root()
	lo, hi := vr.d.attr_range(root)
	for a := lo; a < hi; a++ {
		if vr.d.attr_ns_of(a) != vr.xsi {
			continue
		}
		// a document in no namespace names its schema by xsi:noNamespaceSchemaLocation
		if uri == '' && vr.d.attr_local_name(a) == 'noNamespaceSchemaLocation' {
			return 'no namespace'
		}
		if uri != '' && vr.ns_map[vr.d.ns_of(i)] == no_match
			&& vr.d.attr_local_name(a) == 'schemaLocation' {
			pairs := vr.d.attr_value(a).fields()
			for k := 0; k + 1 < pairs.len; k += 2 {
				if pairs[k] == uri {
					return uri
				}
			}
		}
	}
	return none
}

fn (vr &Validator) has_element_child(i u32) bool {
	mut c := vr.d.first_child(i)
	for c != flatxml.no_node {
		if vr.d.is_element(c) {
			return true
		}
		c = vr.d.next_sibling(c)
	}
	return false
}

// nilled reports whether element i carries xsi:nil="true".
fn (vr &Validator) nilled(i u32) bool {
	if vr.xsi == no_match {
		return false
	}
	lo, hi := vr.d.attr_range(i)
	for a := lo; a < hi; a++ {
		if vr.d.attr_ns_of(a) == vr.xsi && vr.d.attr_local_name(a) == 'nil' {
			return vr.d.attr_value(a).trim_space() in ['true', '1']
		}
	}
	return false
}

fn (vr &Validator) xsi_type(i u32) bool {
	if vr.xsi == no_match {
		return false
	}
	lo, hi := vr.d.attr_range(i)
	for a := lo; a < hi; a++ {
		if vr.d.attr_ns_of(a) == vr.xsi && vr.d.attr_local_name(a) == 'type' {
			return true
		}
	}
	return false
}

// match_element finds the declaration for element i under parent p, or reports why there is none.
fn (mut vr Validator) match_element(i u32, p u32) ?u32 {
	if p == flatxml.no_node {
		key := vr.key(i) or { u64(0) }
		return vr.s.global_elems[key] or {
			if uri := vr.located_elsewhere(i) {
				if vr.keep() {
					vr.add(i, .unsupported, 'the schema for ${uri} is named in the document (xsi:schemaLocation), which is not followed')
				}
			} else {
				if vr.keep() {
					vr.add(i, .undeclared_element, '<${vr.d.name(i)}> is not declared as a root element')
				}
			}
			return none
		}
	}
	pd := vr.v.decl[p] - 1
	t := vr.s.elements[pd].typ
	if t.kind != .complex || vr.s.complex_types[t.idx].content in [.simple, .empty] {
		if vr.keep() {
			vr.add(i, .children_not_allowed, '<${vr.d.name(p)}> has no child elements, so <${vr.d.name(i)}> is not allowed')
		}
		return none
	}
	idx := vr.type_index(t.idx)
	key := vr.key(i) or { u64(0) }
	slot := idx.children[key] or {
		if vr.keep() {
			vr.add(i, .undeclared_element, '<${vr.d.name(i)}> is not allowed in <${vr.d.name(p)}>')
		}
		return none
	}
	return idx.decls[slot]
}

// check_element checks what element i holds directly: its own text and its attributes.
fn (mut vr Validator) check_element(i u32, decl u32) {
	t := vr.s.elements[decl].typ
	if t.kind == .complex {
		ct := vr.s.complex_types[t.idx]
		if ct.abstract {
			if vr.keep() {
				vr.add(i, .abstract_type, '<${vr.d.name(i)}> has an abstract type')
			}
		}
		if vr.d.text_len[i] != 0 && ct.content in [.element_only, .empty]
			&& vr.d.text(i).trim_space() != '' {
			if vr.keep() {
				vr.add(i, .text_not_allowed, '<${vr.d.name(i)}> has no text content')
			}
		}
	}
	// the element's value, when its content is simple
	value_type := if t.kind != .complex {
		t
	} else if vr.s.complex_types[t.idx].content == .simple {
		vr.s.complex_types[t.idx].simple
	} else {
		TypeRef{.complex, t.idx}
	}
	// a value that is not the document's (children joined into it, or a nil element's) is not
	// checked: those are reported already
	if vr.checks(value_type) && !vr.has_element_child(i) && !vr.nilled(i) {
		vr.check_value(i, -1, value_type, vr.d.text_content(i))
	}
	vr.check_attrs(i, t)
	if t.kind == .complex {
		ct := vr.s.complex_types[t.idx]
		// a nil element's missing children are not a second finding
		if ct.content in [.element_only, .mixed] && ct.particle != no_particle && !vr.nilled(i) {
			vr.check_content(i, t.idx)
		}
	}
}

// check_text checks a text node of mixed content (beside child elements) under element p.
fn (mut vr Validator) check_text(i u32, p u32) {
	if vr.v.decl[p] == 0 {
		return
	}
	t := vr.s.elements[vr.v.decl[p] - 1].typ
	if t.kind == .complex && vr.s.complex_types[t.idx].content in [.element_only, .empty]
		&& vr.d.text(i).trim_space() != '' {
		if vr.keep() {
			vr.add(i, .text_not_allowed, 'text is not allowed in <${vr.d.name(p)}>')
		}
	}
}

fn (mut vr Validator) check_attrs(i u32, t TypeRef) {
	d := vr.d
	lo, hi := d.attr_range(i)
	mut idx := &TypeIndex(unsafe { nil })
	if t.kind == .complex {
		idx = vr.type_index(t.idx)
	}
	mut seen := 0
	// Each attribute written on the element; namespace declarations are not attributes here.
	for a := lo; a < hi; a++ {
		if d.is_ns_decl(a) {
			continue
		}
		ns := d.attr_ns_of(a)
		if ns != flatxml.no_ns && ns == vr.xsi {
			local := d.attr_local_name(a)
			if local == 'nil' {
				// no declaration is nillable (the reader refuses nillable), so only false is valid
				if d.attr_value(a).trim_space() !in ['false', '0'] {
					if vr.keep() {
						vr.add(i, .not_nillable, '<${d.name(i)}> is not nillable, so xsi:nil must be false')
					}
				}
			} else if local !in ['schemaLocation', 'noNamespaceSchemaLocation'] {
				if vr.keep() {
					vr.add(i, .undeclared_attribute, 'attribute ${d.attr_name(a)} is not an XSD instance attribute')
				}
			}
			continue
		}
		snm := vr.ns_map[ns]
		sloc := vr.name_map[d.attr_local_id(a)]
		key := if snm == no_match || sloc == no_match { u64(0) } else { QName{snm, sloc}.key() }
		if isnil(idx) {
			if vr.keep() {
				vr.add(i, .undeclared_attribute, 'attribute ${d.attr_name(a)} is not allowed on <${d.name(i)}>')
			}
			continue
		}
		use := idx.attrs[key] or {
			if vr.keep() {
				vr.add(i, .undeclared_attribute, 'attribute ${d.attr_name(a)} is not allowed on <${d.name(i)}>')
			}
			continue
		}
		if use.required {
			seen++
		}
		at := vr.s.attributes[use.decl].typ
		if vr.checks(at) {
			vr.check_value(i, i64(a), at, d.attr_value(a))
		}
	}
	if !isnil(idx) && seen < idx.required.len {
		vr.report_missing(i, idx)
	}
}

// report_missing names each required attribute of element i that is not there.
fn (mut vr Validator) report_missing(i u32, idx &TypeIndex) {
	d := vr.d
	lo, hi := d.attr_range(i)
	for decl in idx.required {
		name := vr.s.attributes[decl].name
		mut found := false
		for a := lo; a < hi; a++ {
			if !d.is_ns_decl(a) && vr.ns_map[d.attr_ns_of(a)] == name.ns
				&& vr.name_map[d.attr_local_id(a)] == name.local {
				found = true
				break
			}
		}
		if !found {
			if vr.keep() {
				vr.add(i, .missing_attribute, '<${d.name(i)}> needs attribute ${vr.s.qname(name)}')
			}
		}
	}
}

// type_index is what complex type ct allows, gathered on first use: the element declarations in
// its content model by name, and its attributes.
fn (mut vr Validator) type_index(ct u32) &TypeIndex {
	if !isnil(vr.index[ct]) {
		return vr.index[ct]
	}
	mut idx := &TypeIndex{}
	vr.collect(vr.s.complex_types[ct].particle, mut idx)
	for u in vr.s.complex_types[ct].attrs {
		idx.attrs[vr.s.attributes[u.decl].name.key()] = u
		if u.required {
			idx.required << u.decl
		}
	}
	vr.index[ct] = idx
	return idx
}

// collect adds the element declarations under particle p; when two share a name, the first wins
// (XSD requires them to have the same type).
fn (vr &Validator) collect(p u32, mut idx TypeIndex) {
	if p == no_particle {
		return
	}
	pt := vr.s.particles[p]
	if pt.kind == .element {
		key := vr.s.elements[pt.term].name.key()
		if key !in idx.children {
			idx.children[key] = u32(idx.decls.len)
			idx.decls << pt.term
		}
		return
	}
	for ch in vr.s.particle_children(p) {
		vr.collect(ch, mut idx)
	}
}

// keep counts a finding and says whether it is kept, so a message is only written for one that is.
fn (mut vr Validator) keep() bool {
	vr.v.total++
	return vr.v.findings.len < vr.opts.max_findings
}

fn (mut vr Validator) add(i u32, kind FindingKind, msg string) {
	vr.v.findings << Finding{
		node: i
		kind: kind
		msg:  msg
	}
}
