module flatxml

// KeyFn computes a child's key where paths cannot say it; none means the child has no key.
pub type KeyFn = fn (n Node) ?string

// ClassFn names the class of a parent whose children are being put together, for the rules that
// name a parent by class (`%class`); '' for none.
pub type ClassFn = fn (parent Parent) string

// Parent is what a classifier reads of a merged node whose children are being put together. The
// merged view is not readable while it is built, so this is all of it there is: the node's
// name and key, the nodes of the set it is made of (whose attributes, text and children are the
// documents', complete), and the names and keys of its merged ancestors.
pub struct Parent {
pub:
	name      string
	key       string     // its key; '' for a node without one
	fragments []Node     // the nodes of the set that make it, in the set's order
	ancestors []Ancestor // its merged ancestors, nearest first, the root last
}

// Ancestor is a merged ancestor of a Parent: its name and key.
pub struct Ancestor {
pub:
	name string
	key  string
}

// key_sep joins the parts of a key made of several paths. XML text cannot hold it, so two keys
// of different parts never read alike.
pub const key_sep = '\x1f'

// key_list_sep joins the texts of a key part that reads every occurrence (`ITEM/ID+`). XML text
// cannot hold it either.
pub const key_list_sep = '\x1e'

// show_key is a key for reading: its parts joined with `,` and a part's occurrences with `|`.
pub fn show_key(k string) string {
	return k.replace(key_sep, ',').replace(key_list_sep, '|')
}

// empty_key reports whether a key holds no text: '', or only separators.
pub fn empty_key(k string) bool {
	for c in k {
		if c != `\x1f` && c != `\x1e` {
			return false
		}
	}
	return true
}

// Keyless is what a keyed rule makes of a child whose key parts are all absent.
pub enum Keyless {
	// a child of its own, reported as missing its key
	own
	// the one child of its name with the empty key (absent, or no text in any part), merged like
	// a single child (with merge)
	empty
	// a child of its own, as with own, but not reported: for rules under which a child without a
	// key is expected (a caller naming only some elements), where a report per child would be
	// one per unnamed element of the documents
	quiet
}

// Rule says how the children of one aggregation are told apart and put together: the children
// named `children` of a parent that `parent` names, by its element name (`b`), by the names of
// its nearest ancestors too (`a/b`: a b whose parent is an a), or by the class the rule set's
// classifier gives it (`%c`). A rule is of one of three kinds:
//
// - keyed (`key` or `key_fn` given): children are identified by their key, which is unique in
//   their scope, the nearest ancestor that is not a single child; with `merge`, the children
//   of one key are one child, else the second is a collision;
// - single: one child of each name, identified by its name; with `merge`, every occurrence is
//   that child, else the second is a collision;
// - each: every occurrence is a child of its own.
//
// A child no rule names is of the kind each.
pub struct Rule {
pub:
	parent   string   // the parent: a name, a path of ancestor names, `%class`; '' or '*' for any
	children []string // the child element names the aggregation holds; empty (or '*') for any
	// key is the paths below the child whose texts make its key: `NAME`, `ITEM/ID`; `.` (or '')
	// is the child's own text, absent when it has none; an attribute is `@id` (the child's own)
	// or `ITEM/@id`; a part ending in `+` reads every occurrence, in order, joined with
	// key_list_sep (`REFS/REF+`). A missing part reads as ''; a child missing every part has no
	// key, and is what keyless says.
	key     []string
	key_fn  ?KeyFn  // the key computed by the caller, in place of key
	keyless Keyless // a child of a keyed rule with no key: its own (the default, or quietly) or the empty one
	single  bool    // the aggregation holds one child
	merge   bool    // occurrences of one key (or of a single child) are one child
	// ordered and max are for keyed and each aggregations; a single one holds one child a name
	ordered bool // the order means something: every child from one document, kept as written
	max     int  // the most children the aggregation may hold; 0 for no limit
}

// RuleSet is the rules of a merge. A child is matched by the most specific rule for its parent:
// the parent's class (from classify), then the longest path of ancestor names that ends at the
// parent, then the parent's name alone, then any parent; for each, the rule for the child's
// name before the rule for any child. Children of different aggregations are ordered as their
// rules are listed, and children no rule names come after them, as written.
pub struct RuleSet {
pub:
	rules        []Rule
	fold         bool     // keys compared ignoring ASCII case
	ignore_attrs []string // attributes whose values may differ between contributions to a node
	classify     ?ClassFn // the class of a parent, for rules that name one (`%class`)
	// a namespace URI whose elements are named by their local name, whatever prefix a document
	// spells it with: `<p:x xmlns:p="U">` and `<x xmlns="U">` are both `x`, to the merge, a rule,
	// a key path and `MNode.child` alike. An element of any other namespace is named by its
	// expanded name, `{V}x` (`{}x` for none), prefixed or not, so it is never taken for the
	// namespace's `x`, nor for another namespace's spelled alike. A document whose root is in
	// another namespace is not merged with the others. Namespace declarations are compared as
	// any attribute is (`ignore_attrs` leaves them out). '' for none; else the set's namespaces
	// must be resolved. (An attribute in a namespace is told by its expanded name with or without
	// this: `Doc.attr_id`.)
	local_ns string
	// the identities of an aggregation in the order first written, as an ordered rule has them,
	// without requiring an ordered rule's children to come from one document
	written_order bool
}

enum RuleKind as u8 {
	each
	single
	keyed
}

struct KeyPart {
	path Path
	attr u32  // the attribute's name id; no_name for the element's text
	all  bool // every occurrence, not the first
	own  bool // the child's own text
}

struct CRule {
	kind    RuleKind
	parts   []KeyPart
	key_fn  ?KeyFn
	keyless Keyless
	merge   bool
	ordered bool
	max     int
}

// CompiledRules is a rule set with its names as ids of one table. Each way a rule names a parent
// is a selector: 0 is any parent; the others are a parent's name, a path of ancestor names, or
// a class. The selectors that apply to a parent, most specific first, are its context.
struct CompiledRules {
	rules    []CRule
	fold     bool
	local    u32  // the namespace id of local_ns: no_local for none
	written  bool // identities in the order first written
	ignore   []u32 // ids of the attributes not compared
	classify ?ClassFn
mut:
	pairs       map[u64]u32   // (selector, child id) -> rule; child id 0 stands for any child
	by_name     map[u32]u32   // a parent name id -> the selector naming it alone
	paths       map[u32][]Sel // a parent name id -> the paths ending in it, longest first
	classes     map[string]u32
	nsel        u32            // selectors made
	contexts    map[string]u32 // a context's selectors, written out -> its number
	ctx_sels_of [][]u32        // a context's number -> its selectors
	name_ctx    map[u32]u32    // a parent name id -> its context, where only its name decides
	met_ctx     map[u32][]Met  // a parent name id -> the contexts met with a class or a path
	resolved    map[u64]u32    // (context, child id) -> rule, as met
}

// Met is a context met for a parent name: with this class selector (0: none) and these of its
// paths matching (a bit each, in the order of `paths`).
struct Met {
	class u32
	mask  u64
	ctx   u32
}

// Sel is a selector that names a parent by a path: its ancestors' name ids, nearest first.
struct Sel {
	id    u32
	above []u32
}

fn pair_key(sel u32, child u32) u64 {
	return (u64(sel) << 32) | child
}

fn any_name(s string) bool {
	return s == '' || s == '*'
}

// compile checks the rules and turns their names into ids of t. Two rules for one pair of
// names, a rule both keyed and single, or one with both key paths and a key function, are
// refused.
fn (rs &RuleSet) compile(t &Names) !CompiledRules {
	mut out := CompiledRules{
		fold:    rs.fold
		local:   local_ns_id(t, rs.local_ns)
		written: rs.written_order
	}
	mut seen := map[string]int{}
	mut rules := []CRule{cap: rs.rules.len}
	for k, r in rs.rules {
		keyed := r.key.len > 0 || r.key_fn != none
		if r.keyless != .own && !keyed {
			return error('rule ${k + 1} (${r.parent} ${r.children}): keyless is for a keyed rule')
		}
		if r.key.len > 0 && r.key_fn != none {
			return error('rule ${k + 1} (${r.parent} ${r.children}): key paths and a key function')
		}
		if keyed && r.single {
			return error('rule ${k + 1} (${r.parent} ${r.children}): keyed and single')
		}
		if r.max < 0 {
			return error('rule ${k + 1} (${r.parent} ${r.children}): max ${r.max}')
		}
		mut parts := []KeyPart{}
		for p_ in r.key {
			if p_ == '' || p_ == '.' {
				parts << KeyPart{
					own: true
				}
				continue
			}
			all := p_.ends_with('+')
			p := if all { p_[..p_.len - 1] } else { p_ }
			if all && (p == '.' || p == '') {
				return error('rule ${k + 1}: key part `${p_}`: the own text (`.`) is one text, ' +
					'and `+` reads every element at a path')
			}
			if all && p.starts_with('@') {
				return error('rule ${k + 1}: key part `${p_}`: `+` reads every element at a path, and names none')
			}
			at := index_outside(p, `@`)
			if at >= 0 && (index_outside(p[at..], `/`) >= 0 || at + 1 == p.len) {
				return error('rule ${k + 1}: key path `${p}`: an attribute ends a path')
			}
			path := if at < 0 { p } else { p[..at] }
			// an attribute no document has gets an id no attribute has
			attr := if at < 0 { no_name } else { t.id(p[at + 1..]) or { no_name - 1 } }
			parts << KeyPart{t.path(path), attr, all, false}
		}
		mut kind := RuleKind.each
		if keyed {
			kind = .keyed
		} else if r.single {
			kind = .single
		}
		rules << CRule{
			kind:    kind
			parts:   parts
			key_fn:  r.key_fn
			keyless: r.keyless
			merge:   r.merge
			ordered: r.ordered
			max:     r.max
		}
		parent := if any_name(r.parent) { '*' } else { r.parent }
		kids := if r.children.len == 0 || (r.children.len == 1 && any_name(r.children[0])) {
			['*']
		} else {
			r.children
		}
		for c in kids {
			if any_name(c) && kids.len > 1 {
				return error('rule ${k + 1}: `*` among other child names')
			}
			pair := '${parent} ${c}'
			if prev := seen[pair] {
				return error('rules ${prev + 1} and ${k + 1} both name ${pair}')
			}
			seen[pair] = k
			sel := out.selector(parent, t, rs.classify != none) or {
				if err.msg() != '' {
					return error('rule ${k + 1}: ${err.msg()}')
				}
				continue
			}
			cid := if c == '*' { u32(0) } else { t.id(c) or { continue } }
			out.pairs[pair_key(sel, cid)] = u32(k)
		}
	}
	mut ignore := []u32{}
	for a in rs.ignore_attrs {
		ignore << t.id(a) or { continue }
	}
	for _, mut ps in out.paths {
		ps.sort(a.above.len > b.above.len)
	}
	return CompiledRules{
		...out
		rules:    rules
		ignore:   ignore
		classify: rs.classify
		local:    out.local
		written:  rs.written_order
	}
}

// no_local is the local namespace id of rules with none: Doc.name_in then names every element
// as written.
pub const no_local = u32(0xFFFF_FFFF)

// local_ns_id is the id of the local namespace in the table: no_local for none, and for a URI no
// document declares, an id no element has.
fn local_ns_id(t &Names, uri string) u32 {
	if uri == '' {
		return no_local
	}
	return t.uri_ids[uri] or { no_local - 1 }
}

// local_part is a name without its prefix, sharing its bytes; an expanded name's (`{uri}local`)
// local name.
fn local_part(name string) string {
	if name.starts_with('{') {
		e := name.index_u8(`}`)
		return if e < 0 { name } else { unsafe { tos(name.str + e + 1, name.len - e - 1) } }
	}
	c := name.last_index_u8(`:`)
	return if c < 0 { name } else { unsafe { tos(name.str + c + 1, name.len - c - 1) } }
}

// selector is the selector of a parent as a rule names it, made the first time it is named: an
// error with no message when it names an element no document has (the rule applies to nothing).
fn (mut cr CompiledRules) selector(parent string, t &Names, classifies bool) !u32 {
	if parent == '*' {
		return 0
	}
	if parent.starts_with('%') {
		if parent.len == 1 {
			return error('`%` names no class')
		}
		if !classifies {
			return error('`${parent}` names a class, and the rule set has no classifier')
		}
		if id := cr.classes[parent[1..]] {
			return id
		}
		id := cr.new_selector()
		cr.classes[parent[1..]] = id
		return id
	}
	names := split_names(parent, `/`)
	if names.any(it == '' || it == '*' || it.starts_with('%')) {
		return error('parent `${parent}`: a path is of element names')
	}
	mut ids := []u32{}
	for nm in names.reverse() {
		ids << t.id(nm) or { return error('') }
	}
	if ids.len == 1 {
		if id := cr.by_name[ids[0]] {
			return id
		}
		id := cr.new_selector()
		cr.by_name[ids[0]] = id
		return id
	}
	for s in cr.paths[ids[0]] {
		if s.above == ids[1..] {
			return s.id
		}
	}
	id := cr.new_selector()
	cr.paths[ids[0]] << Sel{id, ids[1..].clone()}
	return id
}

fn (mut cr CompiledRules) new_selector() u32 {
	cr.nsel++
	return cr.nsel
}

// context is the context of merged node p of m: the selectors that apply to it as a parent,
// most specific first. Where no class and no path can apply, its name alone decides it, once.
fn (mut cr CompiledRules) context(m &Merged, p u32) u32 {
	name := m.name[p]
	classify := if cr.classes.len > 0 { cr.classify } else { none }
	if classify == none && name !in cr.paths {
		if c := cr.name_ctx[name] {
			return c
		}
		c := cr.intern(cr.name_sels(name, []))
		cr.name_ctx[name] = c
		return c
	}
	mut class := u32(0)
	if f := classify {
		class = cr.classes[f(m.parent_view(p))] or { 0 }
	}
	paths := cr.paths[name] or { []Sel{} }
	mut mask := u64(0)
	for k, s in paths {
		if k < 64 && s.matches(m, p) {
			mask |= u64(1) << k
		}
	}
	if paths.len <= 64 {
		for met in cr.met_ctx[name] or { []Met{} } {
			if met.class == class && met.mask == mask {
				return met.ctx
			}
		}
	}
	mut sels := []u32{}
	if class != 0 {
		sels << class
	}
	for k, s in paths {
		if k < 64 && mask & (u64(1) << k) != 0 {
			sels << s.id
		} else if k >= 64 && s.matches(m, p) {
			sels << s.id
		}
	}
	c := cr.intern(cr.name_sels(name, sels))
	if paths.len <= 64 {
		cr.met_ctx[name] << Met{class, mask, c}
	}
	return c
}

// matches reports whether the ancestors of merged node p are the path's.
fn (s &Sel) matches(m &Merged, p u32) bool {
	mut a := m.parent[p]
	for id in s.above {
		if a == no_mnode || m.name[a] != id {
			return false
		}
		a = m.parent[a]
	}
	return true
}

// name_sels is sels, then the selector of the name alone and any parent.
fn (cr &CompiledRules) name_sels(name u32, sels []u32) []u32 {
	mut out := sels.clone()
	if s := cr.by_name[name] {
		out << s
	}
	out << 0
	return out
}

// intern is the number of the context made of sels.
fn (mut cr CompiledRules) intern(sels []u32) u32 {
	k := sels.map(it.str()).join(',')
	if c := cr.contexts[k] {
		return c
	}
	c := u32(cr.contexts.len)
	cr.contexts[k] = c
	cr.ctx_sels_of << sels
	return c
}

// resolve is the rule for a child named child of a parent with context ctx; no_rule for none.
fn (mut cr CompiledRules) resolve(ctx u32, child u32) u32 {
	k := pair_key(ctx, child)
	if r := cr.resolved[k] {
		return r
	}
	mut r := no_rule
	for s in cr.ctx_sels_of[ctx] {
		if found := cr.pairs[pair_key(s, child)] {
			r = found
			break
		}
		if found := cr.pairs[pair_key(s, 0)] {
			r = found
			break
		}
	}
	cr.resolved[k] = r
	return r
}

// key is the child's key under a keyed rule; none when it has none.
fn (cr &CRule) key(c Node, local u32) ?string {
	if f := cr.key_fn {
		return f(c)
	}
	if cr.parts.len == 1 {
		return cr.parts[0].read(c, local)
	}
	mut parts := []string{len: cr.parts.len}
	mut any := false
	for k, p in cr.parts {
		if s := p.read(c, local) {
			parts[k] = s
			any = true
		}
	}
	return if any { parts.join(key_sep) } else { none }
}

fn (p &KeyPart) read(c Node, local u32) ?string {
	if p.own {
		t := own_key_text(c)
		return if t == '' { none } else { t }
	}
	if p.all && p.path.names.len > 0 {
		mut texts := []string{}
		// one slot an occurrence, '' where its attribute is absent, so length and order count
		for n in c.find_all_in(p.path, local) {
			texts << if p.attr == no_name {
				n.text()
			} else {
				n.doc.attr_named(n.i, p.attr) or { '' }
			}
		}
		return if texts.len == 0 { none } else { texts.join(key_list_sep) }
	}
	n := if p.path.names.len == 0 { c } else { c.find_in(p.path, local) }
	if !n.ok() {
		return none
	}
	if p.attr == no_name {
		return n.text()
	}
	return n.doc.attr_named(n.i, p.attr)
}

// own_key_text is element c's own text as a key: its text when that is all it holds; beside
// child elements, its runs of text joined, each without the whitespace around it, which is the
// indentation beside the children. Only c's own children are read.
fn own_key_text(c Node) string {
	d := c.doc
	if d.text_len[c.i] != 0 {
		return d.text(c.i)
	}
	mut out := ''
	mut k := d.first_child(c.i)
	for k != no_node {
		if d.is_text(k) {
			out += d.text(k).trim_space()
		}
		k = d.next_sibling(k)
	}
	return out
}

// parse_rules reads rules from text, one per line:
//
//   # a comment; blank lines are ignored
//   !fold                   keys are compared ignoring ASCII case
//   !local <uri>            the elements of a namespace named by their local name (resolved)
//   !written                an aggregation's identities in the order first written
//   !ignore <attr>...       attributes whose values may differ between contributions
//   <parent> <child>[,<child>...] [key=<path>[,<path>...]] [keyless=own|empty|quiet] [single] [merge]
//                           [ordered] [max=<n>]
//
// A parent is a name, a path of ancestor names (`a/b`) or a class (`%c`); `*` stands for any
// parent or any child. A key part `.` is the child's own text, which no element name can spell.
// Rules that name a class need a classifier, which text cannot give: `RuleSet{...rules,
// classify: f}`. A setting starts with `!`, which no element name can, so every name can have a
// rule. Rules are listed in the order their children are written.
pub fn parse_rules(text string) !RuleSet {
	mut rules := []Rule{}
	mut fold, mut written := false, false
	mut local := ''
	mut ignore := []string{}
	for n, raw in text.split_into_lines() {
		// a comment starts at a `#` outside an expanded name's braces (`{…ns#}x` holds one)
		hash := index_outside(raw, `#`)
		line := (if hash < 0 { raw } else { raw[..hash] }).trim_space()
		if line == '' {
			continue
		}
		mut words := line.fields()
		// a namespace URI may hold `#` (`…/rdf-syntax-ns#`): read from the line as written, a
		// comment after it set off by white space
		if words[0] == '!local' {
			words = raw.trim_space().fields()
			for c, w in words {
				if w.starts_with('#') {
					words = words[..c].clone()
					break
				}
			}
		}
		if words[0].starts_with('!') {
			match words[0] {
				'!fold' {
					if words.len > 1 {
						return error('line ${n + 1}: `!fold` takes nothing')
					}
					fold = true
				}
				'!ignore' {
					ignore << words[1..]
				}
				'!local' {
					if words.len != 2 {
						return error('line ${n + 1}: `!local` takes a namespace URI')
					}
					local = words[1]
				}
				'!written' {
					if words.len > 1 {
						return error('line ${n + 1}: `!written` takes nothing')
					}
					written = true
				}
				else {
					return error('line ${n + 1}: unknown setting `${words[0]}`')
				}
			}
			continue
		}
		if words.len < 2 {
			return error('line ${n + 1}: expected `<parent> <children> [options]`')
		}
		mut key := []string{}
		mut single, mut merge, mut ordered := false, false, false
		mut max := 0
		mut keyless := Keyless.own
		for w in words[2..] {
			if w.starts_with('key=') {
				key = split_names(w[4..], `,`).filter(it != '')
				if key.len == 0 {
					return error('line ${n + 1}: an empty key')
				}
			} else if w.starts_with('keyless=') {
				keyless = match w[8..] {
					'own' { Keyless.own }
					'empty' { Keyless.empty }
					'quiet' { Keyless.quiet }
					else { return error('line ${n + 1}: `${w}`: keyless is own, empty or quiet') }
				}
			} else if w.starts_with('max=') {
				max = w[4..].int()
				if max <= 0 || '${max}' != w[4..] {
					return error('line ${n + 1}: `${w}` is not a count')
				}
			} else {
				match w {
					'single' { single = true }
					'merge' { merge = true }
					'ordered' { ordered = true }
					else { return error('line ${n + 1}: unknown option `${w}`') }
				}
			}
		}
		rules << Rule{
			parent:   words[0]
			children: split_names(words[1], `,`).filter(it != '')
			key:      key
			keyless:  keyless
			single:   single
			merge:    merge
			ordered:  ordered
			max:      max
		}
	}
	return RuleSet{
		rules:        rules
		fold:         fold
		ignore_attrs: ignore
		local_ns:      local
		written_order: written
	}
}

// format_rules writes a rule set as parse_rules reads it: the settings, then a rule per line.
// Read back, it is the same set, but for three spellings that compile alike, each written as one:
// the parent '' as `*`, no child names or [''] as `*` (read back as [`*`]), and the key part ''
// as `.`. The classifier is not written (parse_rules never reads one): give it to the set read
// back. What text cannot say is refused: a key function; a name holding whitespace, `,` or `#`;
// an empty name among others; a parent starting with `!`; the key parts `+` and `.+`; a negative
// max.
pub fn format_rules(rs RuleSet) !string {
	mut lines := []string{}
	if rs.fold {
		lines << '!fold'
	}
	if rs.local_ns != '' {
		if rs.local_ns.fields() != [rs.local_ns] || rs.local_ns.starts_with('#') {
			return error('the local namespace `${rs.local_ns}` cannot be written as rule text')
		}
		lines << '!local ${rs.local_ns}'
	}
	if rs.written_order {
		lines << '!written'
	}
	if rs.ignore_attrs.len > 0 {
		for a in rs.ignore_attrs {
			if a == '' {
				return error('an empty ignored attribute name')
			}
			check_rule_word(a, 'an ignored attribute')!
		}
		lines << '!ignore ' + rs.ignore_attrs.join(' ')
	}
	for k, r in rs.rules {
		lines << format_rule(r) or { return error('rule ${k + 1}: ${err.msg()}') }
	}
	return lines.join('\n') + '\n'
}

// format_rule is one rule as a line of parse_rules' text.
fn format_rule(r Rule) !string {
	if r.key_fn != none {
		return error('a key function cannot be written')
	}
	if r.max < 0 {
		return error('max ${r.max}')
	}
	parent := if any_name(r.parent) { '*' } else { r.parent }
	check_rule_word(parent, 'the parent')!
	if parent.starts_with('!') {
		return error('a parent starting with `!` reads as a setting')
	}
	any_child := r.children.len == 0 || (r.children.len == 1 && r.children[0] == '')
	for c in r.children {
		if c == '' && !any_child {
			return error('an empty child name among others')
		}
		check_rule_word(c, 'a child')!
	}
	children := if any_child { '*' } else { r.children.join(',') }
	mut out := '${parent} ${children}'
	if r.key.len > 0 {
		mut parts := []string{}
		for p in r.key {
			if p == '+' {
				return error('key part `+`: `+` reads every element at a path, and names none')
			}
			if p == '.+' {
				return error('key part `.+`: the own text (`.`) is one text, and `+` reads every ' +
					'element at a path')
			}
			check_rule_word(p, 'a key part')!
			parts << if p == '' { '.' } else { p }
		}
		out += ' key=' + parts.join(',')
	}
	if r.keyless != .own {
		out += ' keyless=${r.keyless}'
	}
	if r.single {
		out += ' single'
	}
	if r.merge {
		out += ' merge'
	}
	if r.ordered {
		out += ' ordered'
	}
	if r.max > 0 {
		out += ' max=${r.max}'
	}
	return out
}

// check_rule_word fails unless w can be part of a word of parse_rules' text: without what ends a
// line or a word, or is trimmed from a line (space, tab, newline, carriage return, vertical tab,
// form feed), and without `,` or `#`.
fn check_rule_word(w string, what string) ! {
	// inside an expanded name's braces `,` and `#` are the URI's; whitespace ends a word anywhere
	if w.contains_any(' \t\n\r\v\f') || index_outside(w, `,`) >= 0 || index_outside(w, `#`) >= 0 {
		return error('${what} `${w}` cannot be written: whitespace, `,` and `#` end a word')
	}
}
