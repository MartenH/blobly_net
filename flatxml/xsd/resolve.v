module xsd

// resolve gives every reference its target, then expands attribute groups into the complex
// types that use them, gives a type extending another its base's content and attributes, and
// refuses what cannot be compiled: a reference to nothing, a group that contains itself, an
// attribute group that includes itself (used or not), a type extending itself, a type with an
// attribute twice.
fn (mut r Reader) resolve() ! {
	xs := r.s.uri_ids[xsd_ns_uri] or { u32(0xFFFF_FFFF) }
	// Each reference, in the order it was read.
	for p in r.pending {
		match p.kind {
			.element_type {
				r.s.elements[p.slot].typ = r.lookup_type(p, xs, true)!
			}
			.attr_type {
				r.s.attributes[p.slot].typ = r.lookup_type(p, xs, false)!
			}
			.simple_base {
				r.s.simple_types[p.slot].base = r.lookup_type(p, xs, false)!
			}
			.content_base {
				t := r.lookup_type(p, xs, true)!
				if t.kind == .complex {
					r.ct_base[p.slot] = t.idx
				} else {
					r.s.complex_types[p.slot].simple = t
				}
			}
			.element_ref {
				r.s.particles[p.slot].term = r.s.global_elems[p.name.key()] or {
					return r.at(p, 'element ${r.s.qname(p.name)} is not declared')
				}
			}
			.attr_ref {
				decl := r.s.global_attrs[p.name.key()] or {
					r.xml_attr(p.name) or {
						return r.at(p, 'attribute ${r.s.qname(p.name)} is not declared')
					}
				}
				use := AttrUse{
					decl:     decl
					required: p.required
				}
				if p.in_group {
					r.agroups[p.slot].attrs[p.sub] = use
				} else {
					r.s.complex_types[p.slot].attrs[p.sub] = use
				}
			}
			.group_ref {
				mg := r.s.group_ids[p.name.key()] or {
					return r.at(p, 'group ${r.s.qname(p.name)} is not declared')
				}
				g := r.s.particles[r.mgroups[mg].root]
				r.s.particles[p.slot].kind = g.kind
				r.s.particles[p.slot].term = g.term
				r.s.particles[p.slot].count = g.count
				r.s.particles[p.slot].group = mg
			}
			.agroup_ref {
				g := r.s.attr_groups[p.name.key()] or {
					r.xml_agroup(p) or {
						return r.at(p, 'attribute group ${r.s.qname(p.name)} is not declared')
					}
				}
				if p.in_group {
					r.agroups[p.slot].refs << g
				} else {
					r.ct_agroups[p.slot] << g
				}
			}
		}
	}
	// An annotation on an attribute reference names the declaration the reference resolved to,
	// read while every use is still at the index it was written at.
	for k, a in r.appinfo {
		decl := match a.owner {
			.attribute_use { r.s.complex_types[a.idx].attrs[a.sub].decl }
			.group_attribute_use { r.agroups[a.idx].attrs[a.sub].decl }
			else { continue }
		}
		r.appinfo[k] = Appinfo{
			...a
			attr: decl
		}
	}
	r.check_group_cycles()!
	r.s.compute_empties()
	r.check_content_models()!
	r.check_simple_cycles()!
	r.st_done = []u8{len: r.s.simple_types.len}
	for k in 0 .. r.s.simple_types.len {
		r.finish_simple_type(u32(k))!
	}
	// Each attribute group gets the attributes of the groups it references, then each complex
	// type those of the groups it references; a use reached through two groups is one use.
	for g in 0 .. r.agroups.len {
		r.flatten(u32(g))!
	}
	for ct in 0 .. r.s.complex_types.len {
		mut from := map[u64]u64{}
		for g in r.ct_agroups[u32(ct)] or { []u32{} } {
			// joined as union_of joins, recording the uses it keeps
			for j, u in r.flatten(g)! {
				if !r.s.complex_types[ct].attrs.any(it.decl == u.decl) {
					r.s.complex_types[ct].attrs << u
					from[use_key(u)] = r.agroups[g].origins[j]
				}
			}
		}
		if from.len > 0 {
			r.ct_from_group[u32(ct)] = from.clone()
		}
	}
	// Then what it inherits from a type it extends, and a check for an attribute twice.
	r.ct_state = []u8{len: r.s.complex_types.len}
	for ct in 0 .. r.s.complex_types.len {
		r.finish(u32(ct))!
		r.check_unique_attrs(u32(ct))!
	}
}

// finish gives a complex type whose simple content extends another complex type that type's
// simple content type and its attributes, ahead of its own.
fn (mut r Reader) finish(ct u32) ! {
	if r.ct_state[ct] == 2 {
		return
	}
	if r.ct_state[ct] == 1 {
		return error('type ${r.ct_name(ct)} extends itself')
	}
	base := r.ct_base[ct] or {
		r.ct_state[ct] = 2
		return
	}
	r.ct_state[ct] = 1
	r.finish(base)!
	if r.s.complex_types[base].content != .simple {
		return error('type ${r.ct_name(ct)} extends ${r.ct_name(base)}, which has no simple content')
	}
	r.s.complex_types[ct].simple = r.s.complex_types[base].simple
	// a use both have through attribute groups from the one place it is written (a group,
	// however nested, referred to by both) is one use, once; any other use the base has too is
	// the attribute twice, which check_unique_attrs refuses
	mut attrs := r.s.complex_types[base].attrs.clone()
	inherited := (r.ct_from_group[base] or { map[u64]u64{} }).clone()
	own := (r.ct_from_group[ct] or { map[u64]u64{} }).clone()
	mut joined := map[u64]bool{}
	for u in r.s.complex_types[ct].attrs {
		k := use_key(u)
		if k in own && k in inherited && own[k] == inherited[k] && k !in joined {
			joined[k] = true
			continue
		}
		attrs << u
	}
	r.s.complex_types[ct].attrs = attrs
	if inherited.len > 0 {
		mut from := inherited.clone()
		for k, o in own {
			from[k] = o
		}
		r.ct_from_group[ct] = from
	}
	r.ct_state[ct] = 2
}

fn use_key(u AttrUse) u64 {
	return u64(u.decl) << 1 | u64(u.required)
}

fn (r &Reader) ct_name(ct u32) string {
	return if r.s.complex_types[ct].name.local == 0 {
		'(anonymous)'
	} else {
		r.s.qname(r.s.complex_types[ct].name)
	}
}

// lookup_type finds the type a reference names: a built-in, or a declared simple type, or (when
// complex_ok) a declared complex type.
fn (r &Reader) lookup_type(p Pending, xs u32, complex_ok bool) !TypeRef {
	if p.name.ns == xs {
		local := r.s.names[p.name.local]
		if local == 'anyType' {
			return r.at(p, 'xsd:anyType is not supported')
		}
		b := builtin_named(local) or { return r.at(p, 'xsd:${local} is not a built-in type') }
		if b in [.entity, .entities, .notation] {
			return r.at(p, 'xsd:${local} needs a DTD or notations: not supported')
		}
		return TypeRef{.builtin, u32(b)}
	}
	if st := r.s.named_simple[p.name.key()] {
		return TypeRef{.simple, st}
	}
	if ct := r.s.named_complex[p.name.key()] {
		if !complex_ok {
			return r.at(p, '${r.s.qname(p.name)} is a complex type; a simple type is needed here')
		}
		return TypeRef{.complex, ct}
	}
	return r.at(p, 'type ${r.s.qname(p.name)} is not declared')
}

// flatten is the attribute uses of attribute group g with the groups it references expanded.
fn (mut r Reader) flatten(g u32) ![]AttrUse {
	if r.agroups[g].done {
		return r.agroups[g].attrs
	}
	if r.agroups[g].busy {
		ag := r.agroups[g]
		return error('${r.docs[ag.doc].pos(ag.node)}: attribute group ${r.agroup_name(g)} includes itself')
	}
	r.agroups[g].busy = true
	mut attrs := r.agroups[g].attrs.clone()
	mut origins := []u64{len: attrs.len, init: u64(g) << 32 | u64(index)}
	for sub in r.agroups[g].refs {
		// joined as union_of joins, each kept use with where it is written
		for j, u in r.flatten(sub)! {
			if !attrs.any(it.decl == u.decl) {
				attrs << u
				origins << r.agroups[sub].origins[j]
			}
		}
	}
	r.agroups[g].attrs = attrs
	r.agroups[g].origins = origins
	r.agroups[g].busy = false
	r.agroups[g].done = true
	return attrs
}

// union_of is a then the uses of b whose declaration a does not have: attribute groups combine
// as sets, so a group reached twice contributes its attributes once.
fn union_of(a []AttrUse, b []AttrUse) []AttrUse {
	mut out := a.clone()
	for u in b {
		if !out.any(it.decl == u.decl) {
			out << u
		}
	}
	return out
}

// check_simple_cycles refuses a simple type that is its own base, directly or through others.
fn (r &Reader) check_simple_cycles() ! {
	mut state := []u8{len: r.s.simple_types.len} // 0 unvisited, 1 on the current chain, 2 done
	for st in 0 .. r.s.simple_types.len {
		mut chain := []u32{}
		mut t := u32(st)
		// Follow the bases until a built-in, a type already checked, or a repeat.
		for state[t] == 0 {
			state[t] = 1
			chain << t
			b := r.s.simple_types[t].base
			if b.kind != .simple {
				break
			}
			t = b.idx
			if state[t] == 1 {
				return error('type ${r.st_name(t)} derives from itself')
			}
		}
		for c in chain {
			state[c] = 2
		}
	}
}

// finish_simple_type gives simple type k its built-in root and its enumeration values by value,
// after the types it derives from, and refuses facets that do not apply or loosen the base's:
// maxLength on a type without length, a longer maxLength, a looser whiteSpace, an enumeration
// value its base type does not allow. ENTITY and NOTATION need a DTD's declarations, so they are
// refused.
fn (mut r Reader) finish_simple_type(k u32) ! {
	if r.st_done[k] == 2 {
		return
	}
	if r.st_done[k] == 1 {
		return error('${r.st_pos(k)}type ${r.st_name(k)} derives from itself')
	}
	r.st_done[k] = 1
	st := r.s.simple_types[k]
	if st.base.kind == .simple {
		r.finish_simple_type(st.base.idx)!
	}
	root := r.s.root_of(st.base)
	r.s.simple_types[k].root = root
	name := r.st_name(k)
	if root in [.entity, .entities, .notation] {
		return error('${r.st_pos(k)}type ${name} derives from xsd:${builtin_name(root)}, which needs a DTD or notations: not supported')
	}
	if st.max_length >= 0 && !length_applies(root) {
		return error('${r.st_pos(k)}maxLength does not apply to type ${name}, a ${builtin_name(root)}')
	}
	if st.max_length >= 0 {
		if base_max := r.s.max_length_of(st.base) {
			if st.max_length > base_max {
				return error('${r.st_pos(k)}maxLength ${st.max_length} of type ${name} is longer than its base allows (${base_max})')
			}
		}
	}
	if st.white_space != .unset {
		if !string_like(root) && st.white_space != .collapse {
			return error('${r.st_pos(k)}whiteSpace of type ${name}, a ${builtin_name(root)}, can only be collapse')
		}
		base_ws := r.s.white_space(st.base)
		if int(st.white_space) < int(base_ws) {
			return error('${r.st_pos(k)}whiteSpace ${st.white_space} of type ${name} is looser than its base (${base_ws})')
		}
	}
	if st.enums.len > 0 {
		ws := r.s.white_space(TypeRef{.simple, k})
		mut m := Matcher{}
		// each value valid for the base, then kept by value for lookups
		for j, e in st.enums {
			v := normalized(e, ws)
			qkey := if j < st.enum_qnames.len { st.enum_qnames[j] } else { '' }
			if p := r.s.value_problem(st.base, v, mut m, qkey) {
				return error('${r.st_pos(k)}enumeration value "${shortened(v)}" of type ${name} ${p}')
			}
			r.s.simple_types[k].enum_keys[value_key(root, v, qkey)] = true
		}
	}
	r.st_done[k] = 2
}

// st_pos is where simple type k is declared, for a message ('' for one the reader made itself).
// Worked out only when needed: finding a line scans the file.
fn (r &Reader) st_pos(k u32) string {
	return if int(k) < r.st_where.len {
		r.docs[r.st_where[k].doc].pos(r.st_where[k].node) + ': '
	} else {
		''
	}
}

fn (r &Reader) st_name(st u32) string {
	return if r.s.simple_types[st].name.local == 0 {
		'(anonymous)'
	} else {
		r.s.qname(r.s.simple_types[st].name)
	}
}

fn (r &Reader) agroup_name(g u32) string {
	return r.s.qname(r.agroups[g].name)
}

// check_group_cycles refuses a content model that contains itself through group references,
// which no finite content model can express.
fn (r &Reader) check_group_cycles() ! {
	mut state := []u8{len: r.s.particles.len} // 0 unvisited, 1 on the current path, 2 done
	for root in 1 .. r.s.particles.len {
		if state[root] == 0 {
			r.visit(u32(root), mut state)!
		}
	}
}

fn (r &Reader) visit(p u32, mut state []u8) ! {
	state[p] = 1
	for ch in r.s.particle_children(p) {
		if state[ch] == 1 {
			return error('a model group contains itself through a group reference')
		}
		if state[ch] == 0 {
			r.visit(ch, mut state)!
		}
	}
	state[p] = 2
}

fn (r &Reader) check_unique_attrs(ct u32) ! {
	attrs := r.s.complex_types[ct].attrs
	mut seen := map[u64]bool{}
	mut id := no_id
	for u in attrs {
		k := r.s.attributes[u.decl].name.key()
		if k in seen {
			name := r.s.qname(r.s.attributes[u.decl].name)
			return error('attribute ${name} appears twice in type ${r.ct_name(ct)}')
		}
		seen[k] = true
		// at most one attribute of a type is an ID
		if r.is_id(r.s.attributes[u.decl].typ) {
			if id != no_id {
				return error('attributes ${r.s.qname(r.s.attributes[id].name)} and ${r.s.qname(r.s.attributes[u.decl].name)} of type ${r.ct_name(ct)} are both IDs')
			}
			id = u.decl
		}
	}
}

const no_id = u32(0xFFFF_FFFF)

// is_id reports whether a type is xs:ID or derived from it.
fn (r &Reader) is_id(t TypeRef) bool {
	return match t.kind {
		.builtin { t.idx == u32(Builtin.id) }
		.simple { r.s.simple_types[t.idx].root == .id }
		else { false }
	}
}

// xml_attr_names are the xml namespace's attributes, in the order its schema's xml:specialAttrs
// lists them; xml_attr declares each.
const xml_attr_names = ['base', 'lang', 'space', 'id']

// xml_attr declares one of the xml namespace's attributes for a schema that refers to it without
// importing its schema, as processors do: xml:lang (as a string, since the namespace's schema
// also allows ''), xml:space (default or preserve), xml:base and xml:id.
fn (mut r Reader) xml_attr(q QName) ?u32 {
	if r.s.uris[q.ns] != xml_ns_uri {
		return none
	}
	typ := match r.s.names[q.local] {
		'lang' {
			TypeRef{.builtin, u32(Builtin.string)}
		}
		'base' {
			TypeRef{.builtin, u32(Builtin.any_uri)}
		}
		'id' {
			TypeRef{.builtin, u32(Builtin.id)}
		}
		'space' {
			r.s.simple_types << SimpleType{
				base:  TypeRef{.builtin, u32(Builtin.nc_name)}
				enums: ['default', 'preserve']
			}
			TypeRef{.simple, u32(r.s.simple_types.len - 1)}
		}
		else {
			return none
		}
	}
	idx := u32(r.s.attributes.len)
	r.s.attributes << AttrDecl{
		name:   q
		typ:    typ
		global: true
	}
	r.s.global_attrs[q.key()] = idx
	return idx
}

// xml_agroup declares the xml namespace's attribute group, xml:specialAttrs, for a schema that
// refers to it without importing its schema: xml:base, xml:lang, xml:space and xml:id, as that
// schema has it. It is placed where it is first referred to, since no document declares it.
fn (mut r Reader) xml_agroup(p Pending) ?u32 {
	q := p.name
	if r.s.uris[q.ns] != xml_ns_uri || r.s.names[q.local] != 'specialAttrs' {
		return none
	}
	mut attrs := []AttrUse{}
	for name in xml_attr_names {
		a := QName{q.ns, r.s.intern_name(name)}
		decl := r.s.global_attrs[a.key()] or { r.xml_attr(a)? }
		attrs << AttrUse{
			decl: decl
		}
	}
	g := u32(r.agroups.len)
	r.agroups << AttrGroup{
		name:  q
		attrs: attrs
		own:   u32(attrs.len)
		doc:   p.doc
		node:  p.node
	}
	r.s.attr_groups[q.key()] = g
	return g
}

fn (r &Reader) at(p Pending, msg string) IError {
	return error('${r.docs[p.doc].pos(p.node)}: ${msg}')
}

const xml_ns_uri = 'http://www.w3.org/XML/1998/namespace'
