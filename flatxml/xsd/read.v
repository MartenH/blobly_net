module xsd

import flatxml
import os

// What a reference by name points at, and so where its target is written once resolved.
enum RefKind {
	element_type // slot: element declaration
	attr_type    // slot: attribute declaration
	simple_base  // slot: simple type
	content_base // slot: complex type with simple content
	element_ref  // slot: particle
	attr_ref     // slot: owner (complex type or attribute group), sub: index of the use
	group_ref    // slot: particle
	agroup_ref   // slot: owner (complex type or attribute group)
}

struct Pending {
	kind     RefKind
	slot     u32
	sub      u32
	in_group bool // attr_ref and agroup_ref: the owner is an attribute group
	required bool // attr_ref: the use's `use`
	name     QName
	doc      u32
	node     u32
}

// DocCtx is what a schema document says about the components declared in it.
struct DocCtx {
	d              &flatxml.Doc
	di             u32
	xs             u32 // the document's own id for the XSD namespace
	target         u32 // targetNamespace, as a schema URI id
	elem_qualified bool
	attr_qualified bool
	dir            string
}

struct Reader {
mut:
	s          &Schema
	docs       []&flatxml.Doc
	loaded     map[string]string // real path -> the document's targetNamespace
	ids        map[string]bool   // the id attributes of the XSD elements of the document being read
	pending    []Pending
	ct_agroups map[u32][]u32 // complex type -> attribute groups it references
	// complex type -> its uses (use_key) that came through an attribute group, inherited ones
	// too, each with where it is written (AttrGroup.origins)
	ct_from_group map[u32]map[u64]u64
	ct_base    map[u32]u32   // complex type -> the complex type its simple content extends
	ct_state   []u8          // finish: 0 not yet, 1 in progress, 2 done
	agroup_ord map[u64]u32   // attribute group references made so far, per owner
	st_where   []Pending     // per simple type: where it is declared (doc and node), for messages
	st_done    []u8          // finish_simple_types: 0 not yet, 1 in progress, 2 done
	// per document with appinfo: its line starts
	lines map[u32]flatxml.LineIndex
	// what the schema gets once it is compiled
	appinfo []Appinfo
	mgroups []ModelGroup
	agroups []AttrGroup
}

// AttrGroup is an attribute group while the schema is compiled.
struct AttrGroup {
mut:
	name  QName
	attrs []AttrUse
	// where each of attrs is written, once flattened: the group and its place there
	origins []u64
	own     u32 // how many of attrs are written in the group itself
	refs  []u32 // the attribute groups it references
	done  bool
	busy  bool
	doc   u32 // where it is declared (the built-in xml:specialAttrs: where it is first referred to)
	node  u32
}

// load reads and compiles the schema documents at paths, and the documents they import.
pub fn load(paths ...string) !&Schema {
	mut s := &Schema{}
	s.intern_name('')
	s.intern_uri('')
	s.particles << Particle{}
	mut r := Reader{
		s: s
	}
	defer {
		for mut d in r.docs {
			d.free()
		}
	}
	for p in paths {
		r.read_file(p)!
	}
	r.resolve()!
	first, next := chain_appinfo(r.appinfo)
	return &Schema{
		...*s
		appinfo:          r.appinfo
		groups:           r.mgroups
		attribute_groups: r.agroups.map(AttributeGroup{
			name: it.name
			uses: it.attrs
			own:  it.own
		})
		appinfo_head:     first
		appinfo_next:     next
	}
}

// read_file reads one schema document, and the documents it imports, and returns its target
// namespace. A document already read is not read again.
fn (mut r Reader) read_file(path string) !string {
	real := os.real_path(path)
	if target := r.loaded[real] {
		return target
	}
	mut d := flatxml.parse_file(path)!
	r.docs << d
	d.resolve_namespaces()!
	root := d.root()
	xs := d.ns_id(xsd_ns_uri) or { no_xs }
	if d.ns_of(root) != xs || d.local_name(root) != 'schema' {
		return error('${d.pos(root)}: the root element is not xsd:schema')
	}
	r.s.files << path.clone()
	c0 := DocCtx{
		d:   d
		di:  u32(r.docs.len - 1)
		xs:  xs
		dir: os.dir(path)
	}
	// an import is read in the middle of its importer, whose ids come back after it
	outer := r.ids
	r.ids = map[string]bool{}
	defer {
		r.ids = outer
	}
	r.check_attrs(c0, root, ['targetNamespace', 'elementFormDefault', 'attributeFormDefault',
		'version', 'id'])!
	target := d.attr(root, 'targetNamespace') or { '' }
	r.loaded[real] = target
	c := DocCtx{
		...c0
		target:         r.s.intern_uri(target)
		elem_qualified: r.form(c0, root, 'elementFormDefault')!
		attr_qualified: r.form(c0, root, 'attributeFormDefault')!
	}
	// The top-level components, in document order.
	for i in r.xs_children(c, root)! {
		match d.local_name(i) {
			'annotation' { r.annotation(c, i, .schema, 0, 0)! }
			'import' { r.import(c, i)! }
			'element' { r.global_element(c, i)! }
			'attribute' { r.global_attribute(c, i)! }
			'complexType' { r.complex_type(c, i, true)! }
			'simpleType' { r.simple_type(c, i, true)! }
			'group' { r.group_def(c, i)! }
			'attributeGroup' { r.attr_group_def(c, i)! }
			else { return r.refuse(c, i) }
		}
	}
	return target
}

const no_xs = u32(0xFFFF_FFFF)

const vc_ns_uri = 'http://www.w3.org/2007/XMLSchema-versioning'

fn (mut r Reader) import(c DocCtx, i u32) ! {
	r.check_attrs(c, i, ['namespace', 'schemaLocation', 'id'])!
	r.only_annotations(c, i, .schema, 0)!
	ns := c.d.attr(i, 'namespace') or { '' }
	// the XML namespace's attributes and attribute group are built in (xml_attr, xml_agroup), as
	// processors have them: its schema document, often shipped beside the importing one, is not read
	if ns == xml_ns_uri {
		r.s.notes << '${c.d.pos(i)}: import of the XML namespace: its attributes and xml:specialAttrs are built in, nothing read'
		return
	}
	loc := (c.d.attr(i, 'schemaLocation') or {
		r.s.notes << '${c.d.pos(i)}: import of "${ns}" has no schemaLocation: nothing read'
		return
	}).trim_space()
	path := if os.is_abs_path(loc) { loc } else { os.join_path(c.dir, loc) }
	// schemaLocation is a hint: a document that is not there (or a URL, which is not fetched)
	// is skipped, and a reference into its namespace then fails as undeclared
	if loc.contains('://') || !os.is_file(path) {
		r.s.notes << '${c.d.pos(i)}: import of ${loc} skipped: not a local file'
		return
	}
	target := r.read_file(path) or { return error('${c.d.pos(i)}: importing ${loc}: ${err}') }
	if target != ns {
		return error('${c.d.pos(i)}: ${loc} has target namespace "${target}", not "${ns}"')
	}
}

// --- elements ------------------------------------------------------------------------------

fn (mut r Reader) global_element(c DocCtx, i u32) ! {
	r.check_attrs(c, i, ['name', 'type', 'id'])!
	name := r.required_attr(c, i, 'name')!
	q := QName{c.target, r.s.intern_name(name)}
	if q.key() in r.s.global_elems {
		return error('${c.d.pos(i)}: element ${r.s.qname(q)} is declared twice')
	}
	idx := u32(r.s.elements.len)
	r.s.elements << ElementDecl{
		name:   q
		global: true
	}
	r.s.global_elems[q.key()] = idx
	r.element_type(c, i, idx)!
}

// local_element reads an element in a content model and returns its particle.
fn (mut r Reader) local_element(c DocCtx, i u32) !u32 {
	r.check_attrs(c, i, ['name', 'type', 'ref', 'minOccurs', 'maxOccurs', 'form', 'id'])!
	min, max := r.occurs(c, i)!
	p := u32(r.s.particles.len)
	if ref := c.d.attr(i, 'ref') {
		for a in ['name', 'type', 'form'] {
			if _ := c.d.attr(i, a) {
				return error('${c.d.pos(i)}: an element with ref has no ${a}')
			}
		}
		r.s.particles << Particle{
			kind: .element
			min:  min
			max:  max
		}
		r.pend(c, i, .element_ref, p, ref)!
		r.only_annotations(c, i, .particle, p)!
		return p
	}
	name := r.required_attr(c, i, 'name')!
	qualified := match c.d.attr(i, 'form') or { '' } {
		'' { c.elem_qualified }
		'qualified' { true }
		'unqualified' { false }
		else { return error('${c.d.pos(i)}: form must be qualified or unqualified') }
	}
	idx := u32(r.s.elements.len)
	r.s.elements << ElementDecl{
		name: QName{if qualified { c.target } else { 0 }, r.s.intern_name(name)}
	}
	r.s.particles << Particle{
		kind: .element
		min:  min
		max:  max
		term: idx
	}
	r.element_type(c, i, idx)!
	return p
}

// element_type gives element declaration idx its type: named by `type`, or declared inline.
fn (mut r Reader) element_type(c DocCtx, i u32, idx u32) ! {
	mut typed := false
	if t := c.d.attr(i, 'type') {
		r.pend(c, i, .element_type, idx, t)!
		typed = true
	}
	for ch in r.xs_children(c, i)! {
		match c.d.local_name(ch) {
			'annotation' {
				r.annotation(c, ch, .element, idx, 0)!
			}
			'complexType', 'simpleType' {
				if typed {
					return error('${c.d.pos(ch)}: an element has one type, named or inline')
				}
				r.s.elements[idx].typ = if c.d.local_name(ch) == 'complexType' {
					TypeRef{.complex, r.complex_type(c, ch, false)!}
				} else {
					TypeRef{.simple, r.simple_type(c, ch, false)!}
				}
				typed = true
			}
			else {
				return r.refuse(c, ch)
			}
		}
	}
	if !typed {
		return error('${c.d.pos(i)}: element ${r.s.qname(r.s.elements[idx].name)} has no type, and xsd:anyType is not supported')
	}
}

// --- model groups --------------------------------------------------------------------------

// model_group reads a sequence or choice and returns its particle.
fn (mut r Reader) model_group(c DocCtx, i u32, kind ParticleKind) !u32 {
	r.check_attrs(c, i, ['minOccurs', 'maxOccurs', 'id'])!
	min, max := r.occurs(c, i)!
	mut kids := []u32{}
	mut notes := []u32{}
	// Each child is a particle; nested groups put their own children in place first.
	for ch in r.xs_children(c, i)! {
		match c.d.local_name(ch) {
			'annotation' { notes << ch }
			'element' { kids << r.local_element(c, ch)! }
			'group' { kids << r.group_ref(c, ch)! }
			'sequence' { kids << r.model_group(c, ch, .sequence)! }
			'choice' { kids << r.model_group(c, ch, .choice)! }
			else { return r.refuse(c, ch) }
		}
	}
	p := u32(r.s.particles.len)
	r.s.particles << Particle{
		kind:  kind
		min:   min
		max:   max
		term:  u32(r.s.children.len)
		count: u32(kids.len)
	}
	r.s.children << kids
	for n in notes {
		r.annotation(c, n, .particle, p, 0)!
	}
	return p
}

fn (mut r Reader) group_ref(c DocCtx, i u32) !u32 {
	r.check_attrs(c, i, ['ref', 'minOccurs', 'maxOccurs', 'id'])!
	ref := r.required_attr(c, i, 'ref')!
	min, max := r.occurs(c, i)!
	p := u32(r.s.particles.len)
	r.s.particles << Particle{
		kind: .group_ref
		min:  min
		max:  max
	}
	r.pend(c, i, .group_ref, p, ref)!
	r.only_annotations(c, i, .particle, p)!
	return p
}

fn (mut r Reader) group_def(c DocCtx, i u32) ! {
	r.check_attrs(c, i, ['name', 'id'])!
	name := r.required_attr(c, i, 'name')!
	q := QName{c.target, r.s.intern_name(name)}
	if q.key() in r.s.group_ids {
		return error('${c.d.pos(i)}: group ${r.s.qname(q)} is declared twice')
	}
	mut root := no_particle
	mut notes := []u32{}
	for ch in r.xs_children(c, i)! {
		local := c.d.local_name(ch)
		if local == 'annotation' {
			notes << ch
			continue
		}
		if root != no_particle {
			return error('${c.d.pos(ch)}: a group has one sequence or choice')
		}
		if local != 'sequence' && local != 'choice' {
			return r.refuse(c, ch)
		}
		for a in ['minOccurs', 'maxOccurs'] {
			if _ := c.d.attr(ch, a) {
				return error('${c.d.pos(ch)}: the model group of a group definition has no ${a}')
			}
		}
		root = r.model_group(c, ch, if local == 'sequence' { .sequence } else { .choice })!
	}
	if root == no_particle {
		return error('${c.d.pos(i)}: group ${r.s.qname(q)} has no sequence or choice')
	}
	g := u32(r.mgroups.len)
	r.s.group_ids[q.key()] = g
	r.mgroups << ModelGroup{
		name: q
		root: root
	}
	for n in notes {
		r.annotation(c, n, .group, g, 0)!
	}
}

// --- complex types -------------------------------------------------------------------------

fn (mut r Reader) complex_type(c DocCtx, i u32, named bool) !u32 {
	r.check_attrs(c, i, if named { ['name', 'abstract', 'mixed', 'id'] } else { ['mixed', 'id'] })!
	idx := u32(r.s.complex_types.len)
	mut ct := ComplexType{
		abstract: r.bool_attr(c, i, 'abstract')!
	}
	if named {
		ct.name = QName{c.target, r.s.intern_name(r.required_attr(c, i, 'name')!)}
		if ct.name.key() in r.s.named_complex || ct.name.key() in r.s.named_simple {
			return error('${c.d.pos(i)}: type ${r.s.qname(ct.name)} is declared twice')
		}
		r.s.named_complex[ct.name.key()] = idx
	}
	r.s.complex_types << ct
	mixed := r.bool_attr(c, i, 'mixed')!
	mut simple := false
	mut attributes := false
	// At most one content model, then the attributes.
	for ch in r.xs_children(c, i)! {
		local := c.d.local_name(ch)
		match local {
			'annotation' {
				r.annotation(c, ch, .complex_type, idx, 0)!
			}
			'sequence', 'choice', 'group', 'simpleContent' {
				if simple || r.s.complex_types[idx].particle != no_particle {
					return error('${c.d.pos(ch)}: a complex type has one content model')
				}
				if attributes {
					return error('${c.d.pos(ch)}: the content model comes before the attributes')
				}
				if local == 'simpleContent' {
					r.simple_content(c, ch, idx)!
					simple = true
				} else if local == 'group' {
					r.s.complex_types[idx].particle = r.group_ref(c, ch)!
				} else {
					kind := if local == 'sequence' { ParticleKind.sequence } else { .choice }
					r.s.complex_types[idx].particle = r.model_group(c, ch, kind)!
				}
			}
			'attribute' {
				if simple {
					return error('${c.d.pos(ch)}: the attributes of simple content are in its extension')
				}
				attributes = true
				r.attribute_use(c, ch, idx, false)!
			}
			'attributeGroup' {
				if simple {
					return error('${c.d.pos(ch)}: the attributes of simple content are in its extension')
				}
				attributes = true
				r.agroup_use(c, ch, idx, false)!
			}
			else {
				return r.refuse(c, ch)
			}
		}
	}
	r.s.complex_types[idx].content = if simple {
		.simple
	} else if mixed {
		.mixed
	} else if r.s.complex_types[idx].particle != no_particle {
		.element_only
	} else {
		.empty
	}
	return idx
}

fn (mut r Reader) simple_content(c DocCtx, i u32, ct u32) ! {
	r.check_attrs(c, i, ['id'])!
	mut seen := false
	for ch in r.xs_children(c, i)! {
		local := c.d.local_name(ch)
		if local == 'annotation' {
			r.annotation(c, ch, .complex_type, ct, 0)!
			continue
		}
		if local != 'extension' || seen {
			return r.refuse(c, ch)
		}
		seen = true
		r.check_attrs(c, ch, ['base', 'id'])!
		r.pend(c, ch, .content_base, ct, r.required_attr(c, ch, 'base')!)!
		for a in r.xs_children(c, ch)! {
			match c.d.local_name(a) {
				'annotation' { r.annotation(c, a, .complex_type, ct, 0)! }
				'attribute' { r.attribute_use(c, a, ct, false)! }
				'attributeGroup' { r.agroup_use(c, a, ct, false)! }
				else { return r.refuse(c, a) }
			}
		}
	}
	if !seen {
		return error('${c.d.pos(i)}: simple content needs an extension')
	}
}

// --- attributes ----------------------------------------------------------------------------

fn (mut r Reader) global_attribute(c DocCtx, i u32) ! {
	r.check_attrs(c, i, ['name', 'type', 'id'])!
	q := QName{c.target, r.s.intern_name(r.required_attr(c, i, 'name')!)}
	if q.key() in r.s.global_attrs {
		return error('${c.d.pos(i)}: attribute ${r.s.qname(q)} is declared twice')
	}
	idx := u32(r.s.attributes.len)
	r.s.attributes << AttrDecl{
		name:   q
		global: true
	}
	r.s.global_attrs[q.key()] = idx
	r.attr_type(c, i, idx)!
}

// attribute_use reads an attribute of a complex type (or of an attribute group, in_group) and
// adds it to the owner's uses.
fn (mut r Reader) attribute_use(c DocCtx, i u32, owner u32, in_group bool) ! {
	r.check_attrs(c, i, ['name', 'type', 'ref', 'use', 'form', 'id'])!
	required := match c.d.attr(i, 'use') or { 'optional' } {
		'optional' { false }
		'required' { true }
		'prohibited' { return error('${c.d.pos(i)}: use="prohibited" is not supported') }
		else { return error('${c.d.pos(i)}: use must be optional, required or prohibited') }
	}
	mut decl := u32(0)
	if ref := c.d.attr(i, 'ref') {
		for a in ['name', 'type', 'form'] {
			if _ := c.d.attr(i, a) {
				return error('${c.d.pos(i)}: an attribute with ref has no ${a}')
			}
		}
		sub := u32(if in_group { r.agroups[owner].attrs.len } else { r.s.complex_types[owner].attrs.len })
		r.pending << Pending{
			kind:     .attr_ref
			slot:     owner
			sub:      sub
			in_group: in_group
			required: required
			name:     r.qname_value(c, i, ref)!
			doc:      c.di
			node:     i
		}
		r.only_annotations(c, i, if in_group { .group_attribute_use } else { .attribute_use },
			owner, int(sub))!
	} else {
		qualified := match c.d.attr(i, 'form') or { '' } {
			'' { c.attr_qualified }
			'qualified' { true }
			'unqualified' { false }
			else { return error('${c.d.pos(i)}: form must be qualified or unqualified') }
		}
		decl = u32(r.s.attributes.len)
		r.s.attributes << AttrDecl{
			name: QName{if qualified { c.target } else { 0 }, r.s.intern_name(r.required_attr(c,
				i, 'name')!)}
		}
		r.attr_type(c, i, decl)!
	}
	use := AttrUse{
		decl:     decl
		required: required
	}
	if in_group {
		r.agroups[owner].attrs << use
	} else {
		r.s.complex_types[owner].attrs << use
	}
}

// attr_type gives attribute declaration idx its type: named, inline, or anySimpleType.
fn (mut r Reader) attr_type(c DocCtx, i u32, idx u32) ! {
	r.s.attributes[idx].typ = TypeRef{.builtin, u32(Builtin.any_simple_type)}
	mut typed := false
	if t := c.d.attr(i, 'type') {
		r.pend(c, i, .attr_type, idx, t)!
		typed = true
	}
	for ch in r.xs_children(c, i)! {
		match c.d.local_name(ch) {
			'annotation' {
				r.annotation(c, ch, .attribute, idx, 0)!
			}
			'simpleType' {
				if typed {
					return error('${c.d.pos(ch)}: an attribute has one type, named or inline')
				}
				r.s.attributes[idx].typ = TypeRef{.simple, r.simple_type(c, ch, false)!}
				typed = true
			}
			else {
				return r.refuse(c, ch)
			}
		}
	}
}

fn (mut r Reader) attr_group_def(c DocCtx, i u32) ! {
	r.check_attrs(c, i, ['name', 'id'])!
	q := QName{c.target, r.s.intern_name(r.required_attr(c, i, 'name')!)}
	if q.key() in r.s.attr_groups {
		return error('${c.d.pos(i)}: attribute group ${r.s.qname(q)} is declared twice')
	}
	g := u32(r.agroups.len)
	r.agroups << AttrGroup{
		name: q
		doc:  c.di
		node: i
	}
	r.s.attr_groups[q.key()] = g
	for ch in r.xs_children(c, i)! {
		match c.d.local_name(ch) {
			'annotation' { r.annotation(c, ch, .attribute_group, g, 0)! }
			'attribute' { r.attribute_use(c, ch, g, true)! }
			'attributeGroup' { r.agroup_use(c, ch, g, true)! }
			else { return r.refuse(c, ch) }
		}
	}
	r.agroups[g].own = u32(r.agroups[g].attrs.len)
}

// agroup_use reads a reference to an attribute group from a complex type or another group.
fn (mut r Reader) agroup_use(c DocCtx, i u32, owner u32, in_group bool) ! {
	r.check_attrs(c, i, ['ref', 'id'])!
	r.pending << Pending{
		kind:     .agroup_ref
		slot:     owner
		in_group: in_group
		name:     r.qname_value(c, i, r.required_attr(c, i, 'ref')!)!
		doc:      c.di
		node:     i
	}
	key := u64(owner) << 1 | u64(in_group)
	ord := r.agroup_ord[key]
	r.agroup_ord[key] = ord + 1
	r.only_annotations(c, i, if in_group { .group_attribute_group_ref } else { .attribute_group_ref },
		owner, int(ord))!
}

// --- simple types --------------------------------------------------------------------------

const supported_facets = ['enumeration', 'pattern', 'whiteSpace', 'maxLength']

fn (mut r Reader) simple_type(c DocCtx, i u32, named bool) !u32 {
	r.check_attrs(c, i, if named { ['name', 'id'] } else { ['id'] })!
	idx := u32(r.s.simple_types.len)
	mut st := SimpleType{}
	if named {
		st.name = QName{c.target, r.s.intern_name(r.required_attr(c, i, 'name')!)}
		if st.name.key() in r.s.named_simple || st.name.key() in r.s.named_complex {
			return error('${c.d.pos(i)}: type ${r.s.qname(st.name)} is declared twice')
		}
		r.s.named_simple[st.name.key()] = idx
	}
	r.s.simple_types << st
	r.st_where << Pending{
		doc:  c.di
		node: i
	}
	mut seen := false
	for ch in r.xs_children(c, i)! {
		local := c.d.local_name(ch)
		if local == 'annotation' {
			r.annotation(c, ch, .simple_type, idx, 0)!
			continue
		}
		if local != 'restriction' || seen {
			return r.refuse(c, ch)
		}
		seen = true
		r.restriction(c, ch, idx)!
	}
	if !seen {
		return error('${c.d.pos(i)}: a simple type needs a restriction')
	}
	return idx
}

fn (mut r Reader) restriction(c DocCtx, i u32, idx u32) ! {
	r.check_attrs(c, i, ['base', 'id'])!
	mut based := false
	if base := c.d.attr(i, 'base') {
		r.pend(c, i, .simple_base, idx, base)!
		based = true
	}
	mut seen := map[string]bool{}
	// An optional inline base type, then the facets.
	for ch in r.xs_children(c, i)! {
		local := c.d.local_name(ch)
		if local == 'annotation' {
			r.annotation(c, ch, .simple_type, idx, 0)!
			continue
		}
		if local == 'simpleType' {
			if based {
				return error('${c.d.pos(ch)}: a restriction has one base, named or inline')
			}
			if seen.len > 0 {
				return error('${c.d.pos(ch)}: the inline base type comes before the facets')
			}
			r.s.simple_types[idx].base = TypeRef{.simple, r.simple_type(c, ch, false)!}
			based = true
			continue
		}
		if local !in supported_facets {
			return r.refuse(c, ch)
		}
		if local in ['whiteSpace', 'maxLength'] && local in seen {
			return error('${c.d.pos(ch)}: xsd:${local} appears twice in one restriction')
		}
		seen[local] = true
		r.check_attrs(c, ch, ['value', 'id'])!
		// a copy, since it outlives the document
		value := (c.d.attr(ch, 'value') or {
			return error('${c.d.pos(ch)}: xsd:${local} needs value')
		}).clone()
		match local {
			'enumeration' {
				n := r.s.simple_types[idx].enums.len
				r.s.simple_types[idx].enums << value
				// as a QName, should the type turn out to be one: resolved where it is written
				r.s.simple_types[idx].enum_qnames << expanded_at(c.d, ch, value.trim_space())
				r.only_annotations(c, ch, .enumeration, idx, n)!
				continue
			}
			'pattern' {
				pat := compile_pattern(value) or { return error('${c.d.pos(ch)}: ${err}') }
				r.s.simple_types[idx].patterns << value
				r.s.simple_types[idx].compiled << pat
			}
			'whiteSpace' {
				r.s.simple_types[idx].white_space = match value {
					'preserve' { .preserve }
					'replace' { .replace }
					'collapse' { .collapse }
					else { return error('${c.d.pos(ch)}: whiteSpace must be preserve, replace or collapse') }
				}
			}
			else {
				n := non_negative(value) or {
					return error('${c.d.pos(ch)}: maxLength must be a non-negative integer')
				}
				c32 := capped(n)
				r.s.simple_types[idx].max_length = if c32 > u32(max_i32) { max_i32 } else { int(c32) }
			}
		}
		r.only_annotations(c, ch, .simple_type, idx)!
	}
	if !based {
		return error('${c.d.pos(i)}: a restriction needs a base, named or inline')
	}
}

// --- annotations ---------------------------------------------------------------------------

// annotation keeps the text of every xsd:appinfo under i; documentation is not kept.
fn (mut r Reader) annotation(c DocCtx, i u32, owner OwnerKind, idx u32, sub int) ! {
	r.check_attrs(c, i, ['id'])!
	for ch in r.xs_children(c, i)! {
		match c.d.local_name(ch) {
			'appinfo' {
				if c.di !in r.lines {
					r.lines[c.di] = c.d.line_index()
				}
				line, col := r.lines[c.di].line_col(c.d.src_off[ch])
				r.appinfo << Appinfo{
					owner:  owner
					idx:    idx
					sub:    u32(sub)
					source: (c.d.attr(ch, 'source') or { '' }).clone()
					text:   c.d.inner_xml(ch)
					attr:   if owner == .attribute { idx } else { no_attr }
					file:   c.di
					line:   u32(line)
					col:    u32(col)
				}
			}
			'documentation' {}
			else {
				return r.refuse(c, ch)
			}
		}
	}
}

// only_annotations accepts nothing under i but annotations.
fn (mut r Reader) only_annotations(c DocCtx, i u32, owner OwnerKind, idx u32, sub ...int) ! {
	for ch in r.xs_children(c, i)! {
		if c.d.local_name(ch) != 'annotation' {
			return r.refuse(c, ch)
		}
		r.annotation(c, ch, owner, idx, if sub.len > 0 { sub[0] } else { 0 })!
	}
}

// --- helpers -------------------------------------------------------------------------------

// xs_children are the element children of i, all of which must be XSD elements; text is an
// error, since every XSD element but appinfo and documentation has element-only content.
fn (r &Reader) xs_children(c DocCtx, i u32) ![]u32 {
	d := c.d
	if d.text_len[i] != 0 {
		return error('${d.pos(i)}: text in xsd:${d.local_name(i)}')
	}
	mut out := []u32{}
	mut ch := d.first_child(i)
	for ch != flatxml.no_node {
		if d.is_text(ch) {
			return error('${d.pos(ch)}: text in xsd:${d.local_name(i)}')
		}
		if d.ns_of(ch) != c.xs {
			return error('${d.pos(ch)}: <${d.name(ch)}> is not an XSD element')
		}
		if out.len > 0 && i != d.root() && d.local_name(ch) == 'annotation' {
			return error('${d.pos(ch)}: xsd:annotation comes first in xsd:${d.local_name(i)}, once')
		}
		out << ch
		ch = d.next_sibling(ch)
	}
	return out
}

// check_attrs refuses an unqualified attribute of i that is not in allowed, and XSD 1.1's
// conditional inclusion (the vc: attributes), which decides whether a component exists at all.
// Attributes in other namespaces are annotations and are ignored.
fn (mut r Reader) check_attrs(c DocCtx, i u32, allowed []string) ! {
	lo, hi := c.d.attr_range(i)
	for a := lo; a < hi; a++ {
		ns := c.d.attr_ns_of(a)
		if ns != flatxml.no_ns {
			if c.d.ns_uri(ns) == vc_ns_uri {
				return error('${c.d.pos(i)}: ${c.d.attr_name(a)} (conditional inclusion) is not supported')
			}
			continue
		}
		name := c.d.attr_local_name(a)
		if name !in allowed {
			return error('${c.d.pos(i)}: ${name} on xsd:${c.d.local_name(i)} is not supported')
		}
		// a component's id is an ID: a name, unique in its document
		if name == 'id' {
			id := c.d.attr_value(a).trim_space()
			if !is_name(id, false) {
				return error('${c.d.pos(i)}: id "${id}" is not a valid name')
			}
			if id in r.ids {
				return error('${c.d.pos(i)}: id "${id}" is used twice')
			}
			r.ids[id.clone()] = true
		}
	}
}

fn (r &Reader) refuse(c DocCtx, i u32) IError {
	return error('${c.d.pos(i)}: xsd:${c.d.local_name(i)} is not supported here')
}

fn (r &Reader) required_attr(c DocCtx, i u32, name string) !string {
	v := c.d.attr(i, name) or {
		return error('${c.d.pos(i)}: xsd:${c.d.local_name(i)} needs ${name}')
	}
	return v.trim_space()
}

fn (r &Reader) bool_attr(c DocCtx, i u32, name string) !bool {
	return match (c.d.attr(i, name) or { 'false' }).trim_space() {
		'true', '1' { true }
		'false', '0' { false }
		else { error('${c.d.pos(i)}: ${name} must be true or false') }
	}
}

fn (r &Reader) form(c DocCtx, i u32, name string) !bool {
	return match (c.d.attr(i, name) or { 'unqualified' }).trim_space() {
		'qualified' { true }
		'unqualified' { false }
		else { error('${c.d.pos(i)}: ${name} must be qualified or unqualified') }
	}
}

fn (r &Reader) occurs(c DocCtx, i u32) !(u32, u32) {
	min := r.count_attr(c, i, 'minOccurs', false)!
	max := r.count_attr(c, i, 'maxOccurs', true)!
	if max != 'unbounded' && (min.len > max.len || (min.len == max.len && min > max)) {
		return error('${c.d.pos(i)}: minOccurs is greater than maxOccurs')
	}
	return capped(min), if max == 'unbounded' { unbounded } else { capped(max) }
}

// count_attr is a nonNegativeInteger attribute (default 1) as its decimal digits, without
// leading zeros, so counts of any size compare exactly; or `unbounded`.
fn (r &Reader) count_attr(c DocCtx, i u32, name string, may_be_unbounded bool) !string {
	v := (c.d.attr(i, name) or { return '1' }).trim_space()
	if may_be_unbounded && v == 'unbounded' {
		return v
	}
	return non_negative(v) or {
		error('${c.d.pos(i)}: ${name} must be a non-negative integer${if may_be_unbounded { ' or unbounded' } else { '' }}')
	}
}

// non_negative is a nonNegativeInteger (an optional `+`, then digits) as its digits without
// leading zeros, so values of any size compare exactly.
fn non_negative(value string) ?string {
	v := value.trim_space()
	digits := if v.starts_with('+') { v[1..] } else { v }
	if digits == '' || !digits.bytes().all(it.is_digit()) {
		return none
	}
	n := digits.trim_left('0')
	return if n == '' { '0' } else { n }
}

// count_cap is the largest count kept: no document under 4 GiB holds more elements.
const count_cap = u32(0xFFFF_FFFE)

// capped is a count of decimal digits as a u32, at most count_cap.
fn capped(digits string) u32 {
	if digits.len > 10 {
		return count_cap
	}
	n := digits.u64()
	return if n > u64(count_cap) { count_cap } else { u32(n) }
}

// qname_value reads a qualified name written in an attribute value of element i.
fn (mut r Reader) qname_value(c DocCtx, i u32, value string) !QName {
	v := value.trim_space()
	colon := v.index_u8(`:`)
	prefix := if colon < 0 { '' } else { v[..colon] }
	local := if colon < 0 { v } else { v[colon + 1..] }
	if local == '' || local.contains(':') || (colon == 0) {
		return error('${c.d.pos(i)}: "${v}" is not a qualified name')
	}
	ns := c.d.ns_for_prefix(i, prefix) or {
		return error('${c.d.pos(i)}: the prefix of "${v}" is not bound to a namespace')
	}
	return QName{r.s.intern_uri(c.d.ns_uri(ns)), r.s.intern_name(local)}
}

fn (mut r Reader) pend(c DocCtx, i u32, kind RefKind, slot u32, value string) ! {
	r.pending << Pending{
		kind: kind
		slot: slot
		name: r.qname_value(c, i, value)!
		doc:  c.di
		node: i
	}
}

// expanded_at is a value written at element i of schema document d, read as a QName: {uri}local
// by the namespaces in scope there (unprefixed: the default namespace), or '' when it is not one.
fn expanded_at(d &flatxml.Doc, i u32, v string) string {
	if !is_qname(v) {
		return ''
	}
	colon := v.index_u8(`:`)
	prefix := if colon < 0 { '' } else { v[..colon] }
	ns := d.ns_for_prefix(i, prefix) or { return '' }
	return '{${d.ns_uri(ns)}}${v[colon + 1..]}'.clone()
}
