module arxmodel

import flatxml.xsd

// unbounded is a role with no most.
pub const unbounded = xsd.unbounded

// KeyPath is one part of a split key: the element names below an item whose text is the value
// (`SHORT-NAME`, `VARIATION-POINT/SHORT-LABEL`). A step `@NAME` is an attribute. No steps means
// the item's own text: an item with children is keyed by paths to its single-valued children
// instead (`itself_keys`). When the last step repeats (a role holding several values, written
// one element each), the value is all of them in order.
pub struct KeyPath {
pub:
	steps []string
	all   bool // the last step repeats, and every occurrence is part of the value
}

pub fn (k KeyPath) str() string {
	s := if k.steps.len == 0 { '.' } else { k.steps.join('/') }
	return if k.all { s + '*' } else { s }
}

// Item is one kind of element an aggregation holds: its XML name, its type, and the split key
// resolved against that type.
pub struct Item {
pub:
	element   string
	type_name string // '' for an anonymous or built-in type
	decl      u32    // its element declaration in the schema
	key       []KeyPath
	key_lost  bool // a part of the split key could not be resolved, so key is not the whole key
}

// Rule is what the schema says about one aggregation (a meta-model role): the XML element that
// carries it, the items below it, and how items from several files merge.
pub struct Rule {
pub mut:
	name       string // the meta-model's qualified name, Class.role
	class      string
	role       string
	decl       u32    // the role's element declaration in the schema
	element    string // the role's XML element
	wrapper    bool   // element holds the items; otherwise element is itself the item
	flat       bool   // the items have no element of their own: the wrapper holds each one's content, item after item
	items      []Item
	key_spec   []string        // the split key as the schema writes it, in meta-model roles
	splittable bool            // items of one key from several files are one item
	ordered    bool            // the order of the items means something
	copied     bool            // the items are copied, never merged (a split key of the role alone, by the policy)
	min        u32             // the meta-model's fewest (pureMM.minOccurs); the XML schema makes most roles optional in a file
	max        u32             // unbounded for no most
	held_by    []u32           // the complex types whose content holds the role (indices in the schema)
	naming     map[string]bool // the XML naming tags declared (xml.roleElement, ...), as declared
	problems   []Problem       // what of the annotations could not be applied, with why
	notes      []string        // facts about the rule worth counting, each once
	empty_keys []string        // item types whose item-itself key is empty, for a role of one item
}

// Problem is something an annotation says that could not be applied as written.
pub struct Problem {
pub:
	kind string // a short class, for counting
	msg  string
}

// has_key reports whether the aggregation names a split key.
pub fn (r &Rule) has_key() bool {
	return r.key_spec.len > 0
}

// RuleSet is the rules read from one compiled schema, and an account of every annotation in it.
@[heap]
pub struct RuleSet {
pub mut:
	rules []Rule
	// by_type: a complex type (its index in the schema) and the XML element of a role it holds,
	// as `type_key`, -> the rule
	by_type map[string]int
	// typed: the complex types that hold at least one role
	typed int
	// types_of: an XML element name -> the complex types it is declared with
	types_of map[string][]u32
	census   Census
	policy   Policy
mut:
	schema     &xsd.Schema = unsafe { nil }
	by_decl    map[u32]int
	elem_ann   map[u32]Ann
	attr_ann   map[u32]Ann
	inst_refs  map[u32]bool      // complex types of the stereotype instanceRef: a reference to an instance, by its context and target
	roles      map[string]u32    // complex type and role name (type_key) -> element declaration
	roles_cf   map[string]u32    // the same, the role name in lower case
	attr_roles map[string]string // complex type and role name -> attribute name
	repeat_max map[u32]u32       // element declaration -> the most times a class's content model repeats it, over every class type holding it
	inner_of   map[u32]u32       // an untagged wrapper element -> the role declaration it wraps
	outer_of   map[u32]u32       // a role declaration -> the untagged wrapper element around it
}

// Ann is the tags and stereotypes of one schema component.
struct Ann {
mut:
	tags   map[string]string
	stereo []string
}

// rule_for is the rule for the child element child of an element of complex type ct.
pub fn (rs &RuleSet) rule_for(ct u32, child string) ?&Rule {
	k := rs.by_type[type_key(ct, child)] or { return none }
	return &rs.rules[k]
}

fn type_key(ct u32, name string) string {
	return '${ct} ${name}'
}

// type_name is a complex type's name, '' for an anonymous one.
pub fn (rs &RuleSet) type_name(ct u32) string {
	q := rs.schema.complex_types[ct].name
	return rs.schema.names[q.local]
}

// --- reading ----------------------------------------------------------------------------------

// read_rules reads the rules of a compiled schema from its annotations, by the built-in policy.
pub fn read_rules(s &xsd.Schema) &RuleSet {
	return read_rules_with(s, default_policy())
}

// read_rules_with reads the rules of a compiled schema from its annotations, by a policy.
pub fn read_rules_with(s &xsd.Schema, policy Policy) &RuleSet {
	mut rs := &RuleSet{
		schema: s
		policy: policy
	}
	rs.read_annotations()
	rs.index_types()
	decls_of := rs.collect_type_decls()
	for d in 0 .. s.elements.len {
		ann := rs.elem_ann[u32(d)] or { continue }
		qn := ann.tags['mmt.qualifiedName'] or { continue }
		if !qn.contains('.') {
			rs.census.note('role named by its class (a reference made conditional)')
		}
		rs.by_decl[u32(d)] = rs.rules.len
		rs.rules << rs.role_rule(u32(d), qn, ann)
	}
	for ct, decls in decls_of {
		mut any := false
		for d0 in decls {
			if d0 in rs.outer_of {
				// an item inside the wrapper of no role, which is what holds the role
				continue
			}
			d := rs.inner_of[d0] or { d0 }
			if k := rs.by_decl[d] {
				rs.by_type[type_key(ct, rs.rules[k].element)] = k
				rs.rules[k].held_by << ct
				any = true
			}
		}
		if any {
			rs.typed++
		}
	}
	for mut r in rs.rules {
		rs.resolve_keys(mut r)
		rs.check_naming(mut r)
		for p in r.problems {
			rs.census.problem(p.kind)
		}
		for n in r.notes {
			rs.census.note(n)
		}
	}
	rs.take_census()
	return rs
}

// read_annotations sorts every appinfo by its owner and counts its tags.
fn (mut rs RuleSet) read_annotations() {
	s := rs.schema
	for a in s.appinfo {
		match a.source {
			'tags' {
				tags, _ := parse_tags(a.text)
				for t in tags {
					match a.owner {
						.element { rs.elem_ann[a.idx].tags[t.key] = t.value }
						.attribute { rs.attr_ann[a.idx].tags[t.key] = t.value }
						else {}
					}
				}
			}
			'stereotypes' {
				st := parse_stereotypes(a.text)
				match a.owner {
					.element { rs.elem_ann[a.idx].stereo << st }
					.attribute { rs.attr_ann[a.idx].stereo << st }
					.complex_type {
						if instance_ref_stereotype in st {
							rs.inst_refs[a.idx] = true
						}
					}
					else {}
				}
			}
			else {}
		}
	}
}

// index_types records which XML element names have which complex types, and which untagged
// elements wrap a role: an element with no role of its own whose anonymous type holds exactly
// one element, and that one a role.
fn (mut rs RuleSet) index_types() {
	s := rs.schema
	for d, e in s.elements {
		if e.typ.kind != .complex {
			continue
		}
		name := s.names[e.name.local]
		mut list := (rs.types_of[name] or { []u32{} }).clone()
		if e.typ.idx !in list {
			list << e.typ.idx
			rs.types_of[name] = list
		}
		if rs.tagged(u32(d)) {
			continue
		}
		t := s.complex_types[e.typ.idx]
		if t.name.local != 0 || t.content != .element_only || t.particle == xsd.no_particle {
			continue
		}
		mut occ := []Occ{}
		rs.walk(t.particle, 1, mut occ)
		if occ.len == 1 && rs.tagged(occ[0].decl) {
			rs.inner_of[u32(d)] = occ[0].decl
			rs.outer_of[occ[0].decl] = u32(d)
		}
	}
}

// Occ is an element declaration in a content model, and the most times it occurs there.
struct Occ {
	decl u32
mut:
	max u32
}

// sat_add adds two occurrence counts, unbounded absorbing.
fn sat_add(a u32, b u32) u32 {
	p := u64(a) + u64(b)
	return if p >= u64(unbounded) { unbounded } else { u32(p) }
}

// sat_mul multiplies two occurrence counts, unbounded absorbing.
fn sat_mul(a u32, b u32) u32 {
	if a == unbounded || b == unbounded {
		return unbounded
	}
	p := u64(a) * u64(b)
	return if p >= u64(unbounded) { unbounded } else { u32(p) }
}

// collect_type_decls lists, for each complex type, the element declarations of its content
// model (through its sequences and choices, not into the elements).
fn (mut rs RuleSet) collect_type_decls() map[u32][]u32 {
	s := rs.schema
	mut out := map[u32][]u32{}
	for ct, t in s.complex_types {
		if t.particle == xsd.no_particle {
			continue
		}
		mut occ := []Occ{}
		rs.walk(t.particle, 1, mut occ)
		// a class's own content (a named type, or anonymous mixed content; not the anonymous
		// type of a role element, whose repetition belongs to that role) may repeat a role more
		// often than the meta-model says: mixed content always counts; element-only content
		// counts a repeated choice's repetition only where the policy says so
		mut class_occ := []Occ{}
		if t.content == .mixed || (t.name.local != 0 && rs.policy.repeated_choice_as_mixed) {
			class_occ = occ.clone()
		} else if t.name.local != 0 {
			rs.walk_skipping_choices(t.particle, 1, mut class_occ)
		}
		for o in class_occ {
			if o.max > (rs.repeat_max[o.decl] or { u32(0) }) {
				rs.repeat_max[o.decl] = o.max
			}
		}
		mut decls := []u32{}
		for o in occ {
			decls << o.decl
		}
		out[u32(ct)] = decls
		for d0 in decls {
			d := rs.inner_of[d0] or { d0 }
			if qn := rs.qualified_name(d) {
				rs.roles[type_key(u32(ct), role_of(qn))] = d
				rs.roles_cf[type_key(u32(ct), role_of(qn).to_lower())] = d
			}
		}
		for use in t.attrs {
			if use.decl in rs.attr_ann {
				if qn := rs.attr_ann[use.decl].tags['mmt.qualifiedName'] {
					rs.attr_roles[type_key(u32(ct), role_of(qn))] = s.names[s.attributes[use.decl].name.local]
				}
			}
		}
	}
	return out
}

// walk lists the element declarations under particle p (through sequences and choices, not
// into the elements), each with the most times it occurs: the product of the maxOccurs on the
// way down, times mx.
fn (rs &RuleSet) walk(p u32, mx u32, mut out []Occ) {
	pt := rs.schema.particles[p]
	hi := sat_mul(mx, pt.max)
	if pt.kind == .element {
		for mut o in out {
			if o.decl == pt.term {
				// a second particle for one declaration: both occurrences count
				o.max = sat_add(o.max, hi)
				return
			}
		}
		out << Occ{pt.term, hi}
		return
	}
	for c in rs.schema.particle_children(p) {
		rs.walk(c, hi, mut out)
	}
}

// walk_skipping_choices is walk with a choice's own maxOccurs left out: what a role's count is
// without the repetition of the choices around it.
fn (rs &RuleSet) walk_skipping_choices(p u32, mx u32, mut out []Occ) {
	pt := rs.schema.particles[p]
	hi := if pt.kind == .choice { mx } else { sat_mul(mx, pt.max) }
	if pt.kind == .element {
		for mut o in out {
			if o.decl == pt.term {
				o.max = sat_add(o.max, hi)
				return
			}
		}
		out << Occ{pt.term, hi}
		return
	}
	for c in rs.schema.particle_children(p) {
		rs.walk_skipping_choices(c, hi, mut out)
	}
}

// content_particle is the root particle of a role element's type's content model; none when
// its type is not complex or has no content model.
fn (rs &RuleSet) content_particle(d u32) ?u32 {
	e := rs.schema.elements[d]
	if e.typ.kind != .complex {
		return none
	}
	t := rs.schema.complex_types[e.typ.idx]
	if t.particle == xsd.no_particle {
		return none
	}
	return t.particle
}

// content_decls is the element declarations of a role element's type's content model.
fn (rs &RuleSet) content_decls(d u32) []u32 {
	p := rs.content_particle(d) or { return [] }
	mut occ := []Occ{}
	rs.walk(p, 1, mut occ)
	return occ.map(it.decl)
}

// count_elements is the most elements particle p can match: a sequence's parts add up, a
// choice takes its largest alternative, and both repeat by their maxOccurs.
fn (rs &RuleSet) count_elements(p u32) u32 {
	pt := rs.schema.particles[p]
	if pt.kind == .element {
		return pt.max
	}
	mut n := u32(0)
	for c in rs.schema.particle_children(p) {
		k := rs.count_elements(c)
		n = if pt.kind == .sequence {
			sat_add(n, k)
		} else if k > n {
			k
		} else {
			n
		}
	}
	return sat_mul(pt.max, n)
}

// items_max is the most items a wrapper element holds: its elements, or for a wrapper holding
// its items' content directly (flat), the repetitions of the one group of content inside it.
fn (rs &RuleSet) items_max(d u32, flat bool) u32 {
	p := rs.content_particle(d) or { return 0 }
	if flat {
		kids := rs.schema.particle_children(p)
		if kids.len == 1 && rs.schema.particles[kids[0]].kind != .element {
			return sat_mul(rs.schema.particles[p].max, rs.schema.particles[kids[0]].max)
		}
	}
	return rs.count_elements(p)
}

// role_of is the role a qualified name names: `Class.role`, or a bare class name, which names
// the role referring to that class (the reference inside a conditional wrapper), spelled with a
// lower-case first letter.
fn role_of(qn string) string {
	if qn.contains('.') {
		return qn.all_after('.')
	}
	return if qn == '' { '' } else { qn[..1].to_lower() + qn[1..] }
}

fn class_of(qn string) string {
	return if qn.contains('.') { qn.all_before('.') } else { '' }
}

fn (rs &RuleSet) qualified_name(d u32) ?string {
	if d !in rs.elem_ann {
		return none
	}
	return rs.elem_ann[d].tags['mmt.qualifiedName'] or { return none }
}

fn (rs &RuleSet) tagged(d u32) bool {
	_ := rs.qualified_name(d) or { return false }
	return true
}

// wrapped_items is the element declarations a role element wraps: its type is anonymous, holds
// elements only, and none of them is a role of its own. None when the role element is the item.
fn (rs &RuleSet) wrapped_items(d u32) ?[]u32 {
	s := rs.schema
	e := s.elements[d]
	if e.typ.kind != .complex {
		return none
	}
	t := s.complex_types[e.typ.idx]
	if t.name.local != 0 || t.content != .element_only || t.particle == xsd.no_particle {
		return none
	}
	mut occ := []Occ{}
	rs.walk(t.particle, 1, mut occ)
	if occ.len == 0 {
		return none
	}
	mut decls := []u32{}
	for o in occ {
		if rs.tagged(o.decl) {
			return none
		}
		decls << o.decl
	}
	return decls
}

// role_rule reads the rule of role declaration d, named qn.
fn (mut rs RuleSet) role_rule(d u32, qn string, ann Ann) Rule {
	s := rs.schema
	mut r := Rule{
		name:       qn
		class:      class_of(qn)
		role:       role_of(qn)
		decl:       d
		element:    s.names[s.elements[d].name.local]
		splittable: 'atpSplitable' in ann.stereo
		ordered:    (ann.tags['pureMM.isOrdered'] or { '' }).to_lower() == 'true'
	}
	mut items := []u32{}
	// the most items one parent holds in a file, by the XML schema; 0 where it does not say
	mut xsd_max := u32(0)
	declared_flat := (ann.tags['xml.roleWrapperElement'] or { '' }) == 'true'
		&& (ann.tags['xml.typeElement'] or { '' }) == 'false'
		&& (ann.tags['xml.roleElement'] or { '' }) == 'false'
	flat_items := if declared_flat { rs.content_decls(d) } else { []u32{} }
	if w := rs.wrapped_items(d) {
		// the role element wraps its items
		r.wrapper = true
		items = w.clone()
		xsd_max = rs.items_max(d, false)
	} else if outer := rs.outer_of[d] {
		// an element with no role of its own wraps the role's elements
		r.wrapper = true
		r.element = s.names[s.elements[outer].name.local]
		items = [d]
		xsd_max = rs.items_max(outer, false)
		rs.census.note('role elements wrapped by an element of no role')
	} else if flat_items.len > 0 {
		// declared as a wrapper whose items have no element: it holds their content directly
		r.wrapper = true
		r.flat = true
		items = flat_items.clone()
		xsd_max = rs.items_max(d, true)
		rs.census.note("role wrapper holding its items' content, with no element per item")
	} else {
		items = [d]
	}
	for x in items {
		e := s.elements[x]
		r.items << Item{
			element:   s.names[e.name.local]
			type_name: if e.typ.kind == .complex { rs.type_name(e.typ.idx) } else { '' }
			decl:      x
		}
	}
	r.min = occurs(ann.tags['pureMM.minOccurs'] or { '' }) or {
		if v := ann.tags['pureMM.minOccurs'] {
			r.problems << Problem{'count', 'pureMM.minOccurs "${v}" is not a count'}
		}
		0
	}

	fallback := if xsd_max > 0 { xsd_max } else { u32(1) }
	if 'pureMM.maxOccurs' !in ann.tags {
		rs.census.note('role with no pureMM.maxOccurs')
	}
	r.max = occurs(ann.tags['pureMM.maxOccurs'] or { '' }) or {
		if v := ann.tags['pureMM.maxOccurs'] {
			r.problems << Problem{'count', 'pureMM.maxOccurs "${v}" is not a count; the schema\'s ${occ_str(fallback)} is used'}
		}
		fallback
	}
	// mixed content (text between elements, or a class whose content is a repeated choice of
	// its roles) writes each occurrence of a role as one more element, so there the XML schema's
	// count is the most
	if m := rs.repeat_max[d] {
		if m > r.max {
			rs.census.note("mixed content allows more than pureMM.maxOccurs; the schema's count is used")
			r.max = m
		}
	} else if xsd_max > r.max {
		rs.census.note('a wrapper holds more items in the XML schema than pureMM.maxOccurs')
	} else if xsd_max > 0 && xsd_max < r.max {
		rs.census.note('a wrapper holds fewer items in the XML schema than pureMM.maxOccurs')
	}
	if spec := ann.tags['atp.Splitkey'] {
		for part in spec.split(',') {
			p := part.trim_space()
			if p != '' {
				r.key_spec << p
			}
		}
	}
	for k in ['xml.roleElement', 'xml.roleWrapperElement', 'xml.typeElement', 'xml.typeWrapperElement'] {
		if v := ann.tags[k] {
			r.naming[k] = v.to_lower() == 'true'
		}
	}
	return r
}

// occurs reads a meta-model multiplicity: a count, or -1 for no most.
fn occurs(v string) ?u32 {
	t := v.trim_space()
	if t == '-1' || t == '*' {
		return unbounded
	}
	if t == '' || !t.bytes().all(it.is_digit()) {
		return none
	}
	n := t.u64()
	return if n >= u64(unbounded) { unbounded } else { u32(n) }
}

fn occ_str(n u32) string {
	return if n == unbounded { 'unbounded' } else { n.str() }
}

// --- split keys -------------------------------------------------------------------------------

// resolve_keys turns each part of r's split key, a path of meta-model roles, into a path of XML
// element names below each item: the role's own name stands for the item itself, and each
// further role is the element of that role in the type reached so far. A key is resolved once
// per item type; a wrapper holding its items' content resolves it in its own type.
fn (rs &RuleSet) resolve_keys(mut r Rule) {
	if r.key_spec.len == 0 {
		return
	}
	s := rs.schema
	mut done := map[string][]KeyPath{}
	mut lost := map[string]bool{}
	mut items := []Item{}
	for it in r.items {
		start := if r.flat { s.elements[r.decl].typ } else { s.elements[it.decl].typ }
		tk := '${start.kind} ${start.idx}'
		if tk !in done {
			mut names := []string{}
			for x in r.items {
				if r.flat || s.elements[x.decl].typ == start {
					names << x.element
				}
			}
			before := r.problems.filter(it.kind in key_failures).len
			done[tk] = rs.resolve_key(mut r, start, names.join(', '))
			lost[tk] = r.problems.filter(it.kind in key_failures).len > before
		}
		items << Item{
			...it
			key:      done[tk]
			key_lost: lost[tk]
		}
	}
	// items of several types: by the policy, every type keyed by the union of their key parts
	// (the types whose key resolved: a type whose key lost a part keeps its own)
	if done.len > 1 && rs.policy.abstract_items == .@union {
		mut all := []KeyPath{}
		mut seen := map[string]bool{}
		for it in items {
			if it.key_lost {
				continue
			}
			for k in it.key {
				if k.str() !in seen {
					seen[k.str()] = true
					all << k
				}
			}
		}
		items = items.map(if it.key_lost {
			it
		} else {
			Item{
				...it
				key: all
			}
		})
	}
	r.items = items
}

// structured_comment is the stereotype of a structured comment, which a merge may ignore.
const structured_comment = 'atpStructuredComment'

// structured_elements are the elements of roles of structured comments.
pub fn (rs &RuleSet) structured_elements() []string {
	mut out := []string{}
	for r in rs.rules {
		ann := rs.elem_ann[r.decl] or { continue }
		if structured_comment in ann.stereo && r.element !in out {
			out << r.element
		}
	}
	return out
}

// key_failures are the problems that leave a part of a split key out.
const key_failures = ['key role not found', 'key through a multi-valued role']

// resolve_key resolves r's split key from type start, for the items named in for_items.
fn (rs &RuleSet) resolve_key(mut r Rule, start xsd.TypeRef, for_items string) []KeyPath {
	mut keys := []KeyPath{}
	mut empty_itself := []string{}
	for spec in r.key_spec {
		if spec == r.role {
			// the policy identifies the item by one role of its, in place of its single values
			if by := rs.policy.item_identity[r.name] {
				w := rs.walk_roles(start, [by]) or {
					r.problems << Problem{'key role not found', 'item identity "${by}" for ${for_items}: ${err.msg()}'}
					continue
				}
				keys << KeyPath{w.steps, w.all}
				continue
			}
			// a split key of the role alone, on a multi-valued role: the policy may copy the items
			if r.key_spec.len == 1 && r.max > 1 {
				with_children := rs.has_children(start)
				if (with_children && rs.policy.item_itself == .copy)
					|| (!with_children && rs.policy.primitive_values == .copy) {
					r.copied = true
					continue
				}
			}
			own := rs.itself_keys(start)
			if own.len == 0 {
				empty_itself << spec
			}
			keys << own
			continue
		}
		rest := if spec.starts_with(r.role + '.') { spec[r.role.len + 1..] } else { spec }
		w := rs.walk_roles(start, rest.split('.')) or {
			kind := if err is KeyError { err.kind } else { 'key role not found' }
			r.problems << Problem{kind, 'split key "${spec}" for ${for_items}: ${err.msg()}'}
			continue
		}
		if w.folded {
			r.problems << Problem{'key role differs in case', 'split key "${spec}" for ${for_items}: a role differs from its spelling here only in case'}
		}
		keys << KeyPath{w.steps, w.all}
	}
	// the item itself gave nothing: what tells two items apart is the rest of the key
	if empty_itself.len > 0 && keys.len == 0 {
		type_name := if start.kind == .complex { rs.type_name(start.idx) } else { '' }
		if r.max > 1 {
			r.problems << Problem{'key item has no single-valued children', 'split key "${empty_itself.join(', ')}" for ${for_items}: type ${type_name} has no single-valued child, and nothing else is in the key, so every item has one key'}
		} else {
			note := 'key of a single item with no single-valued children: every fragment is the one item'
			if note !in r.notes {
				r.notes << note
			}
			r.empty_keys << type_name
		}
	}
	return keys
}

// itself_keys is the key of an item named by the role's own name: a value is its own key; an
// item with children is identified by its single-valued element children, in the order its type
// writes them (attributes do not count). A child counts when it is a role holding one value as
// text: not a wrapper, at most one by its rule, not splittable, its type simple or mixed. A child that is a reference to an instance
// (its type of the stereotype instanceRef) counts by its own such children, below it; other
// objects do not count. None when the item has children and none of them qualifies.
fn (rs &RuleSet) itself_keys(start xsd.TypeRef) []KeyPath {
	if !rs.has_children(start) {
		return [KeyPath{}]
	}
	mut out := []KeyPath{}
	rs.single_values(start, []string{}, mut []u32{}, mut out)
	return out
}

// has_children reports whether a type holds elements, so its value is not its text.
fn (rs &RuleSet) has_children(t xsd.TypeRef) bool {
	if t.kind != .complex {
		return false
	}
	ct := rs.schema.complex_types[t.idx]
	return ct.particle != xsd.no_particle && ct.content == .element_only
}

// one_value reports whether a role holds one value by its rule (its most, which mixed content
// may raise above pureMM.maxOccurs) and is not splittable.
fn (rs &RuleSet) one_value(d u32) bool {
	k := rs.by_decl[d] or { return false }
	r := rs.rules[k]
	// a role behind an element of no role is a wrapper by its shape, and may still hold one
	return (!r.wrapper || d in rs.outer_of) && r.max <= 1 && !r.splittable
}

// single_values appends, below path, the single-valued text children of type t,
// and those of its references to instances; seen guards against a type that holds itself.
fn (rs &RuleSet) single_values(t xsd.TypeRef, path []string, mut seen []u32, mut out []KeyPath) {
	if t.idx in seen {
		return
	}
	seen << t.idx
	defer {
		seen.pop()
	}
	s := rs.schema
	ct := s.complex_types[t.idx]
	mut occ := []Occ{}
	rs.walk(ct.particle, 1, mut occ)
	for o in occ {
		// a role behind an element of no role of its own is reached through that element
		d := rs.inner_of[o.decl] or { o.decl }
		if !rs.tagged(d) || !rs.one_value(d) {
			continue
		}
		mut steps := path.clone()
		if d != o.decl {
			steps << s.names[s.elements[o.decl].name.local]
		}
		steps << s.names[s.elements[d].name.local]
		typ := s.elements[d].typ
		if rs.has_children(typ) {
			if typ.idx in rs.inst_refs {
				rs.single_values(typ, steps, mut seen, mut out)
			}
		} else {
			out << KeyPath{
				steps: steps
			}
		}
	}
}

// KeyError is why a split key's path could not be followed, with a kind for counting.
struct KeyError {
	Error
	kind string
	text string
}

fn (e KeyError) msg() string {
	return e.text
}

fn key_error(kind string, text string) IError {
	return KeyError{
		kind: kind
		text: text
	}
}

struct Walk {
	steps  []string
	folded bool // a role was matched ignoring case
	all    bool // the last role repeats
}

// walk_roles follows a path of role names from a type, giving the XML element (or `@attribute`)
// of each. A role spelled with another case is matched, and said.
fn (rs &RuleSet) walk_roles(start xsd.TypeRef, parts []string) !Walk {
	s := rs.schema
	mut steps := []string{}
	mut folded := false
	mut typ := start
	for k, part in parts {
		if typ.kind != .complex {
			return key_error('key role not found', '"${part}" is below a value, not an object')
		}
		ct := typ.idx
		mut d := rs.roles[type_key(ct, part)] or { u32(0) }
		mut found := type_key(ct, part) in rs.roles
		if !found {
			if x := rs.roles_cf[type_key(ct, part.to_lower())] {
				d = x
				found = true
				folded = true
			}
		}
		if !found {
			if attr := rs.attr_roles[type_key(ct, part)] {
				if k != parts.len - 1 {
					return key_error('key role not found', '"${part}" is an attribute, with nothing below it')
				}
				steps << '@' + attr
				return Walk{steps, folded, false}
			}
			return key_error('key role not found', 'no role "${part}" in ${rs.type_desc(ct)}')
		}
		if _ := rs.wrapped_items(d) {
			return key_error('key through a multi-valued role', '"${part}" holds many items, so it cannot be a key')
		}
		ann := rs.elem_ann[d] or { Ann{} }
		if outer := rs.outer_of[d] {
			steps << s.names[s.elements[outer].name.local]
		}
		steps << s.names[s.elements[d].name.local]
		if m := occurs(ann.tags['pureMM.maxOccurs'] or { '' }) {
			if m > 1 {
				if k != parts.len - 1 {
					return key_error('key through a multi-valued role', '"${part}" holds many items, so nothing below it can be a key')
				}
				return Walk{steps, folded, true}
			}
		}
		typ = s.elements[d].typ
	}
	return Walk{steps, folded, false}
}

fn (rs &RuleSet) type_desc(ct u32) string {
	n := rs.type_name(ct)
	return if n == '' { 'an anonymous type' } else { 'type ${n}' }
}

// check_naming compares the XML naming tags with the shape the schema gives the role: a role
// wrapper element must wrap its items.
fn (mut rs RuleSet) check_naming(mut r Rule) {
	if w := r.naming['xml.roleWrapperElement'] {
		if w == r.wrapper {
			rs.census.note('xml.roleWrapperElement agrees with the schema')
		} else {
			r.problems << Problem{'xml.roleWrapperElement disagrees with the schema', 'xml.roleWrapperElement="${w}", but the schema ${if r.wrapper {
				'wraps'
			} else {
				'does not wrap'
			}} the items'}
		}
	}
}

// direct_identity_roles are the roles the policy identifies by one role of their items whose items
// are written in their holder with no wrapper: merged by that identity as their split key
// (resolve_key), named by it by values as a wrapper role's items are. Their parent is left empty.
pub fn (rs &RuleSet) direct_identity_roles() []IdentityRole {
	mut out := []IdentityRole{}
	for r in rs.rules {
		if r.name !in rs.policy.item_identity || r.wrapper || r.flat || r.items.len == 0 {
			continue
		}
		def, label := rs.identity_parts(r) or { continue }
		out << IdentityRole{
			items:      r.items.map(it.element)
			definition: def
			label:      label
		}
	}
	return out
}

// identity_parts are the paths of an item_identity role's identity and label in its items' key:
// the part the policy's identity gave (resolve_key), wherever it stands, and the part after it.
fn (rs &RuleSet) identity_parts(r Rule) ?(string, string) {
	by := rs.policy.item_identity[r.name] or { return none }
	if r.items.len == 0 {
		return none
	}
	w := rs.walk_roles(rs.schema.elements[r.items[0].decl].typ, [by]) or { return none }
	def := w.steps.join('/')
	key := r.items[0].key
	for j, k in key {
		if k.steps.join('/') == def {
			return def, if j + 1 < key.len { key[j + 1].steps.join('/') } else { '' }
		}
	}
	return none
}

// identity_roles are the wrapper roles the policy identifies by one role of their items: the
// wrapper, its items, and the resolved paths of their identity and of the rest of the key.
pub fn (rs &RuleSet) identity_roles() []IdentityRole {
	mut out := []IdentityRole{}
	for r in rs.rules {
		if r.name !in rs.policy.item_identity || !r.wrapper || r.flat || r.items.len == 0 {
			continue
		}
		// the policy's identity wherever it stands in the key, and the part after it
		def, label := rs.identity_parts(r) or { continue }
		out << IdentityRole{
			parent:     r.element
			items:      r.items.map(it.element)
			definition: def
			label:      label
		}
	}
	return out
}
