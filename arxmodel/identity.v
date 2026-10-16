module arxmodel

import flatxml
import toml

// Identity is how elements are named without a schema (identity.toml).
pub struct Identity {
pub:
	name          []string // the paths whose texts name an element: the first must be present
	by_definition []string // element name patterns named by their definition
	definition    string   // the child holding the definition
}

// builtin_identity is identity.toml, read.
pub fn builtin_identity() Identity {
	return parse_identity(identity_text) or { panic('the built-in identity.toml: ${err}') }
}

// parse_identity reads identity rules: an [identity] table with name, by_definition and
// definition, nothing else.
pub fn parse_identity(text string) !Identity {
	doc := toml.parse_text(text) or { return error('identity: ${err.msg()}') }
	top := doc.to_any().as_map()
	for k, _ in top {
		if k != 'identity' {
			return error('identity: unknown table [${k}]')
		}
	}
	t := (top['identity'] or { return error('identity: no table [identity]') }).as_map()
	for k, _ in t {
		if k !in ['name', 'by_definition', 'definition'] {
			return error('identity: unknown setting `identity.${k}`')
		}
	}
	name := strings_of(t, 'name')!
	if name.len == 0 {
		return error('identity: `identity.name` names no path')
	}
	def := t['definition'] or { return error('identity: `identity.definition` is not set') }
	if def !is string || def.string() == '' {
		return error('identity: `identity.definition` takes a path')
	}
	return Identity{
		name:          name
		by_definition: strings_of(t, 'by_definition')!
		definition:    def.string()
	}
}

fn strings_of(t map[string]toml.Any, key string) ![]string {
	v := t[key] or { return error('identity: `identity.${key}` is not set') }
	if v !is []toml.Any {
		return error('identity: `identity.${key}` takes a list of strings')
	}
	mut out := []string{}
	for x in v.array() {
		if x !is string || x.string() == '' {
			return error('identity: `identity.${key}` takes a list of strings')
		}
		out << x.string()
	}
	return out
}

// glob reports whether name matches a pattern whose one `*` stands for any part of it.
fn glob(pattern string, name string) bool {
	if !pattern.contains('*') {
		return pattern == name
	}
	head := pattern.all_before('*')
	tail := pattern.all_after('*')
	return name.len >= head.len + tail.len && name.starts_with(head) && name.ends_with(tail)
}

// Identified is identity rules as applied to some documents: what was seen in them decides which
// element names are lists, and which definitions take several values.
@[heap]
pub struct Identified {
pub:
	id Identity
	nm Naming // how the merge names the documents' elements: the model's namespace by local names
pub mut:
	lists map[string]bool // element names some document holds as a list of named elements
	// `definition sep label` of values given more than once under one parent
	multi map[string]bool
mut:
	// per name table seen by `observe`, what depends only on names, decided once; keys are
	// read for every element, so they read these instead of matching and looking up strings
	tabs []&TabFacts
	// per depth of observe_node, one parent's value keys (see ValueKeys.keys_at)
	keys_at [][]string
}

// TabFacts is what the identity rules say about the names of one name table (one document set).
struct TabFacts {
	tab    &flatxml.Names
	by_def []bool  // name id -> an element of that name is named by its definition
	name   [][]u32 // each path of id.name, as name ids (none: a name the table lacks)
	def    []u32   // the definition path
	label  []u32   // the label path ('' when the name has one part)
}

// path_ids is a path of child names as ids of a table, or none when one of them is not in it
// (so no element of the table has the path).
fn path_ids(tab &flatxml.Names, path string) ?[]u32 {
	if path == '' {
		return none
	}
	mut out := []u32{}
	for name in path.split('/') {
		out << tab.id(name) or { return none } // a local name: the split interns it
	}
	return out
}

fn (id &Identity) tab_facts(tab &flatxml.Names) &TabFacts {
	mut by_def := []bool{len: tab.len()}
	for k in 2 .. tab.len() {
		name := tab.name(u32(k))
		// a prefixed or an expanded name ({uri}x, {}x) is never the merge's name for an element
		// of the model's namespace (Naming): another namespace's is no ECUC value
		by_def[k] = !name.contains_u8(`:`) && !name.starts_with('{')
			&& id.by_definition.any(glob(it, name))
	}
	r := id.value_role()
	return &TabFacts{
		tab:    tab
		by_def: by_def
		name:   id.name.map(path_ids(tab, it) or { []u32{} })
		def:    path_ids(tab, r.definition) or { []u32{} }
		label:  path_ids(tab, r.label) or { []u32{} }
	}
}

// facts is what `observe` decided for n's name table, or none for a table it did not see.
@[inline]
fn (x &Identified) facts(n flatxml.Node) ?&TabFacts {
	for t in x.tabs {
		if voidptr(t.tab) == voidptr(n.doc.tab) {
			return t
		}
	}
	return none
}

// ids_text is the trimmed text at a path of child name ids below n ('' where there is none),
// each child named as the merge names it, without copying: a slice of the document's text.
fn ids_text(n flatxml.Node, ids []u32, nm &Naming) string {
	if ids.len == 0 {
		return ''
	}
	mut cur := n
	for tag in ids {
		cur = nm.child_id(cur, tag)
		if !cur.ok() {
			return ''
		}
	}
	return trimmed(cur.text())
}

@[inline]
fn is_space(c u8) bool {
	return c == ` ` || (c >= `\t` && c <= `\r`)
}

// trimmed is s without surrounding whitespace, as trim_space has it, but a slice of s, not a copy.
fn trimmed(s string) string {
	mut lo := 0
	mut hi := s.len
	for lo < hi && is_space(s[lo]) {
		lo++
	}
	for hi > lo && is_space(s[hi - 1]) {
		hi--
	}
	if lo == 0 && hi == s.len {
		return s
	}
	return unsafe { tos(s.str + lo, hi - lo) }
}

// value_role is how a value named by its definition is read.
fn (id &Identity) value_role() IdentityRole {
	return IdentityRole{
		definition: id.definition
		label:      if id.name.len > 1 { id.name[1] } else { '' }
	}
}

// named is the name of an element by these rules, or none: its short name (and the further
// parts); for an element named by its definition, the definition and the label (and a
// container's short name); for a definition of several values, the value's content too.
fn (x &Identified) named(n flatxml.Node) ?string {
	f := x.facts(n) or { x.id.tab_facts(n.doc.tab) }
	return x.named_by(n, f)
}

// named_by is `named` by the facts of n's name table: the same name, read by ids.
fn (x &Identified) named_by(n flatxml.Node, f &TabFacts) ?string {
	tag := x.nm.tag(n.doc, n.i)
	first := ids_text(n, f.name[0], x.nm)
	if int(tag) < f.by_def.len && f.by_def[tag] {
		k := ids_text(n, f.def, x.nm) + flatxml.key_sep + ids_text(n, f.label, x.nm)
		if flatxml.empty_key(k) && first == '' {
			return none
		}
		if first == '' && k in x.multi {
			return k + flatxml.key_sep + content_of(n, x.id.value_role(), x.nm)
		}
		return first + flatxml.key_sep + k
	}
	if first == '' {
		return none
	}
	if f.name.len == 1 {
		return first
	}
	mut parts := [first]
	for p in f.name[1..] {
		parts << ids_text(n, p, x.nm)
	}
	return parts.join(flatxml.key_sep)
}

// observe records, in every document of the models, the names held as lists and the definitions
// given more than once under one parent; and per name table, what keys read of names.
pub fn (mut x Identified) observe(models []&Model) {
	for m in models {
		for d in m.set.docs {
			if x.facts(d.root_node()) == none {
				x.tabs << x.id.tab_facts(d.tab)
			}
			f := x.facts(d.root_node()) or { panic('unreachable') }
			x.observe_node(d.root_node(), f, 0)
		}
	}
}

fn (mut x Identified) observe_node(n flatxml.Node, f &TabFacts, depth int) {
	for x.keys_at.len <= depth {
		x.keys_at << []string{}
	}
	x.keys_at[depth].clear()
	mut any := false
	mut all_named := true
	for c in n.children() {
		any = true
		tag := x.nm.tag(c.doc, c.i)
		by_def := int(tag) < f.by_def.len && f.by_def[tag]
		named := ids_text(c, f.name[0], x.nm) != ''
		if by_def && !named {
			x.keys_at[depth] << ids_text(c, f.def, x.nm) + flatxml.key_sep + ids_text(c, f.label, x.nm)
		} else if !named && !by_def {
			all_named = false
		}
		x.observe_node(c, f, depth + 1)
	}
	note_repeats(mut x.keys_at[depth], mut x.multi)
	if any && all_named {
		name := x.nm.node_name(n)
		if name !in x.lists {
			x.lists[name] = true
		}
	}
}

// key is an element's key by these rules: its name; for a list (an element name some document
// holds as a list of named elements, so an emptied one is still the list), its element name
// (list_key), the one key of its namesakes; else none (matched by place).
pub fn (x &Identified) key(n flatxml.Node) ?string {
	if k := x.named(n) {
		return k
	}
	name := x.nm.node_name(n)
	return if name in x.lists { list_key(name) } else { none }
}

// list_key is the key of a list: its element name, after a separator no text can hold, so it is
// never a name's key, and lists of different names under one parent stay apart.
pub fn list_key(name string) string {
	return flatxml.key_sep + name
}

// identity_flat is the merge rules of identity rules, as applied to the models: every child of
// every parent keyed as `key` says, merged by its key, an unkeyed one each its own.
pub fn identity_flat(id Identity, models []&Model) Flat {
	mut x := &Identified{
		id: id
		nm: naming(model_namespace(models), models)
	}
	x.observe(models)
	key_fn := fn [x] (n flatxml.Node) ?string {
		return x.key(n)
	}
	return Flat{
		rules:             flatxml.RuleSet{
			rules: [
				flatxml.Rule{
					parent:  '*'
					key_fn:  key_fn
					keyless: .quiet
					merge:   true
				},
			]
			// a prefix is a spelling of the namespace: `ar:X` in one file is X in another
			local_ns: x.nm.ns
		}
		described:         ['built-in identity']
		unkeyed_by_design: true
	}
}
