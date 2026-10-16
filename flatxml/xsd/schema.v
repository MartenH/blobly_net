// xsd — XML Schema (XSD 1.0) compiled into flat tables.
//
// `load` reads one or more schema documents (and the documents they import) with flatxml and
// compiles them: every reference resolved, groups and attribute groups expanded, anonymous types
// numbered. It supports the subset of XSD listed in docs/plan.md and refuses everything else by
// name and position, never skipping a construct: a validator that ignores a constraint reports
// invalid documents as valid.
//
// Components live in arrays and refer to each other by index, the way the parser's nodes do.
module xsd

pub const xsd_ns_uri = 'http://www.w3.org/2001/XMLSchema'

// unbounded is maxOccurs="unbounded".
pub const unbounded = u32(0xFFFF_FFFF)

// QName is a namespace id and a local-name id, both in the schema's own tables.
pub struct QName {
pub:
	ns    u32
	local u32
}

@[inline]
fn (q QName) key() u64 {
	return u64(q.ns) << 32 | u64(q.local)
}

pub enum TypeKind {
	builtin
	simple
	complex
}

// TypeRef names a type: a built-in (idx is a `Builtin`), or an index into `simple_types` or
// `complex_types`.
pub struct TypeRef {
pub:
	kind TypeKind
	idx  u32
}

pub enum WhiteSpace {
	unset
	preserve
	replace
	collapse
}

pub struct SimpleType {
pub mut:
	name        QName // {0, 0} for an anonymous type
	base        TypeRef
	enums       []string
	patterns    []string  // as written
	compiled    []Pattern // the same, compiled
	root        Builtin   // the built-in type at the end of its derivation chain
	enum_keys   map[string]bool // its enumeration values by value (value_key), for lookup
	enum_qnames []string        // each enumeration value as {uri}local, by the schema's namespaces where it is written ('' when not a qualified name there)
	white_space WhiteSpace
	max_length  int = -1
}

pub enum Content {
	empty
	element_only
	mixed
	simple
}

pub struct ComplexType {
pub mut:
	name     QName // {0, 0} for an anonymous type
	abstract bool
	content  Content
	simple   TypeRef // the content's type when content is .simple
	particle u32     // the content model's root particle, `no_particle` when there is none
	attrs    []AttrUse
}

pub struct ElementDecl {
pub mut:
	name   QName
	typ    TypeRef
	global bool
}

pub struct AttrDecl {
pub mut:
	name   QName
	typ    TypeRef
	global bool
}

// AttrUse is an attribute a complex type allows: its declaration, and whether it is required.
pub struct AttrUse {
pub:
	decl     u32
	required bool
}

pub enum ParticleKind {
	element
	sequence
	choice
	group_ref // only while reading; resolution replaces every one
}

// Particle is a piece of a content model. An element particle's `term` is its declaration; a
// sequence or choice has `count` children, at `children[term .. term + count]`. A reference to a
// named model group becomes a copy of the group's sequence or choice, with the reference's own
// counts, and keeps which group it names in `group`.
pub struct Particle {
pub mut:
	kind  ParticleKind
	min   u32 = 1
	max   u32 = 1
	term  u32
	count u32
	group u32 = no_group // the named model group referenced here (an index into `groups`)
}

pub const no_particle = u32(0)

// no_group is a particle's `group` when it is not a group reference.
pub const no_group = u32(0xFFFF_FFFF)

// no_attr is an Appinfo's `attr` when it does not annotate an attribute.
pub const no_attr = u32(0xFFFF_FFFF)

// no_appinfo ends an owner's chain of appinfo entries.
const no_appinfo = u32(0xFFFF_FFFF)

// ModelGroup is a named model group (`xsd:group name=...`): its name and the sequence or choice it
// holds.
pub struct ModelGroup {
pub:
	name QName
	root u32
}

// AttributeGroup is a named attribute group: its name and the attribute uses it gives a type that
// references it. The first `own` uses are those written in the group itself, in order (so a
// `group_attribute_use` annotation's `sub` indexes them); the rest come from the attribute groups
// it references.
pub struct AttributeGroup {
pub:
	name QName
	uses []AttrUse
	own  u32
}

// OwnerKind says what an annotation belongs to, and so what Appinfo's idx and sub mean.
pub enum OwnerKind {
	schema
	element         // idx: element declaration
	attribute       // idx: attribute declaration
	complex_type    // idx: complex type
	simple_type     // idx: simple type
	group           // idx: the named model group (an index into `groups`)
	attribute_group // idx: index into the schema's attribute groups
	enumeration     // idx: simple type, sub: the value's index
	particle        // idx: a sequence, choice, element reference or group reference
	attribute_use   // idx: complex type, sub: the use's index as written (an attribute reference)
	group_attribute_use // idx: attribute group, sub: the use's index (an attribute reference)
	attribute_group_ref // idx: complex type, sub: the reference's ordinal in it
	group_attribute_group_ref // idx: attribute group, sub: the reference's ordinal in it
}

// Appinfo is one `xsd:appinfo`, kept for the consumer; nothing here interprets it. Its content
// is written back as XML (flatxml's inner_xml), so child elements survive as markup.
pub struct Appinfo {
pub:
	owner  OwnerKind
	idx    u32
	sub    u32
	source string
	text   string
	// the attribute declaration annotated, for the owners attribute, attribute_use and
	// group_attribute_use (a reference's declaration, once resolved); no_attr for the others
	attr u32 = no_attr
	// where the xsd:appinfo is written: a schema document (an index into `files`), and its line
	// and column (from 1, the column in bytes)
	file u32
	line u32
	col  u32
}

@[heap]
pub struct Schema {
pub mut:
	names         []string // local names; id 0 is ''
	uris          []string // namespace URIs; id 0 is no namespace
	simple_types  []SimpleType
	complex_types []ComplexType
	elements      []ElementDecl
	attributes    []AttrDecl
	particles     []Particle // particle 0 is unused, so 0 can mean none
	children      []u32
	empties       []u8 // per particle: bit 0, one occurrence can be empty; bit 1, the particle can match nothing
	files         []string // the schema documents read, in order
	notes         []string // what was read differently from how it is written: imports skipped
pub:
	appinfo          []Appinfo
	groups           []ModelGroup     // the named model groups, in the order they were read
	// the named attribute groups, in the order they were read, then the built-in xml:specialAttrs
	// where a schema refers to it
	attribute_groups []AttributeGroup
mut:
	name_ids      map[string]u32
	uri_ids       map[string]u32
	global_elems  map[u64]u32
	global_attrs  map[u64]u32
	named_simple  map[u64]u32
	named_complex map[u64]u32
	group_ids     map[u64]u32 // model group name -> index into groups
	attr_groups   map[u64]u32 // attribute group name -> index into attribute_groups
	appinfo_head  map[u64]u32 // owner kind and idx -> its first entry in appinfo
	appinfo_next  []u32       // per entry: the owner's next entry, or no_appinfo
}

// name_id is the id of a local name, if any component uses it.
pub fn (s &Schema) name_id(name string) ?u32 {
	return s.name_ids[name] or { return none }
}

// uri_id is the id of a namespace URI, if any component uses it.
pub fn (s &Schema) uri_id(uri string) ?u32 {
	return s.uri_ids[uri] or { return none }
}

// qname spells a name `{uri}local`, or `local` in no namespace.
pub fn (s &Schema) qname(q QName) string {
	return if q.ns == 0 { s.names[q.local] } else { '{${s.uris[q.ns]}}${s.names[q.local]}' }
}

// element is the global element declaration named {uri}local.
pub fn (s &Schema) element(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.global_elems[QName{ns, l}.key()] or { return none }
}

// global_elements lists the global element declarations, in the order they were read.
pub fn (s &Schema) global_elements() []u32 {
	mut out := []u32{}
	for i, e in s.elements {
		if e.global {
			out << u32(i)
		}
	}
	return out
}

// complex_type_named is the named complex type {uri}local.
pub fn (s &Schema) complex_type_named(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.named_complex[QName{ns, l}.key()] or { return none }
}

// simple_type_named is the named simple type {uri}local.
pub fn (s &Schema) simple_type_named(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.named_simple[QName{ns, l}.key()] or { return none }
}

// group_named is the named model group {uri}local, an index into `groups`.
pub fn (s &Schema) group_named(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.group_ids[QName{ns, l}.key()] or { return none }
}

// attribute_group_named is the named attribute group {uri}local, an index into
// `attribute_groups`.
pub fn (s &Schema) attribute_group_named(uri string, local string) ?u32 {
	ns := s.uri_ids[uri] or { return none }
	l := s.name_ids[local] or { return none }
	return s.attr_groups[QName{ns, l}.key()] or { return none }
}

// appinfo_pos is where an appinfo entry is written, as `path:line:col`.
pub fn (s &Schema) appinfo_pos(a Appinfo) string {
	return '${s.files[a.file]}:${a.line}:${a.col}'
}

// appinfo_of is the appinfo of one owner: owner kind, idx and sub as `Appinfo` has them, in the
// order they were read.
pub fn (s &Schema) appinfo_of(owner OwnerKind, idx u32, sub u32) []Appinfo {
	mut out := []Appinfo{}
	mut k := s.appinfo_head[appinfo_key(owner, idx)] or { return out }
	for k != no_appinfo {
		if s.appinfo[k].sub == sub {
			out << s.appinfo[k]
		}
		k = s.appinfo_next[k]
	}
	return out
}

@[inline]
fn appinfo_key(owner OwnerKind, idx u32) u64 {
	return u64(owner) << 32 | u64(idx)
}

// chain_appinfo links every appinfo entry to the next one of the same owner, for `appinfo_of`:
// the first entry of each owner, and per entry the next. An owner's entries are mostly adjacent,
// so the table is asked once per run of them.
fn chain_appinfo(appinfo []Appinfo) (map[u64]u32, []u32) {
	mut first := map[u64]u32{}
	mut next := []u32{len: appinfo.len, init: no_appinfo}
	mut prev := u64(0xFFFF_FFFF_FFFF_FFFF)
	for k := appinfo.len - 1; k >= 0; k-- {
		key := appinfo_key(appinfo[k].owner, appinfo[k].idx)
		if key == prev {
			next[k] = u32(k + 1)
		} else {
			next[k] = first[key] or { no_appinfo }
		}
		first[key] = u32(k)
		prev = key
	}
	return first, next
}

// particle_children are the children of a sequence or choice particle.
pub fn (s &Schema) particle_children(p u32) []u32 {
	pt := s.particles[p]
	if pt.kind == .element {
		return []
	}
	return s.children[pt.term..pt.term + pt.count]
}

fn (mut s Schema) intern_name(name string) u32 {
	if id := s.name_ids[name] {
		return id
	}
	id := u32(s.names.len)
	// a copy: names read from a document are views of its source, which is released after load
	owned := name.clone()
	s.names << owned
	s.name_ids[owned] = id
	return id
}

fn (mut s Schema) intern_uri(uri string) u32 {
	if id := s.uri_ids[uri] {
		return id
	}
	id := u32(s.uris.len)
	owned := uri.clone()
	s.uris << owned
	s.uri_ids[owned] = id
	return id
}
