module flatxml

import strings

// Writing nodes from the tree's parts: names as interned, values decoded and escaped again for
// the place they are written in. This is how a node is written when it is not copied from the
// source.

// escape_text is s written as character data: `&`, `<` and `>` as entity references, and a
// carriage return as `&#13;`, which would otherwise read back as a line break. Text that is only
// whitespace is written as character references, since whitespace-only text between tags is not
// read as text.
pub fn escape_text(s string) string {
	if !s.contains_any('&<>\r') && !is_blank(s) {
		return s
	}
	mut sb := strings.new_builder(s.len + 16)
	put_text(mut sb, s)
	return sb.str()
}

// escape_attr is s written as an attribute value between `quote` characters (`"` or `'`): `&`,
// `<`, `>` and the quote as references, and tab, newline and carriage return as character
// references, which would otherwise read back as spaces.
pub fn escape_attr(s string, quote u8) string {
	if !s.contains_any('&<>\t\n\r') && !s.contains_u8(quote) {
		return s
	}
	mut sb := strings.new_builder(s.len + 16)
	put_attr(mut sb, s, quote)
	return sb.str()
}

// attr_quote is the quote character to write the value s between: `prefer`, unless s holds it
// and not the other one.
pub fn attr_quote(s string, prefer u8) u8 {
	other := if prefer == `"` { `'` } else { `"` }
	if s.contains_u8(prefer) && !s.contains_u8(other) {
		return other
	}
	return prefer
}

// cdata_section is s written as CDATA: one section, split where s holds `]]>` (which would end
// it) or a carriage return (which a section cannot hold; it is written as `&#13;` between two).
pub fn cdata_section(s string) string {
	mut sb := strings.new_builder(s.len + 12)
	put_cdata(mut sb, s)
	return sb.str()
}

// is_blank reports whether s is whitespace and nothing else, and not empty.
fn is_blank(s string) bool {
	for c in s {
		if !is_ws(c) {
			return false
		}
	}
	return s.len > 0
}

fn put_text(mut sb strings.Builder, s string) {
	if is_blank(s) {
		for b in s {
			sb.write_string(match b {
				`\t` { '&#9;' }
				`\n` { '&#10;' }
				`\r` { '&#13;' }
				else { '&#32;' }
			})
		}
		return
	}
	for b in s {
		match b {
			`&` { sb.write_string('&amp;') }
			`<` { sb.write_string('&lt;') }
			`>` { sb.write_string('&gt;') }
			`\r` { sb.write_string('&#13;') }
			else { sb.write_u8(b) }
		}
	}
}

fn put_attr(mut sb strings.Builder, s string, quote u8) {
	for b in s {
		match b {
			`&` { sb.write_string('&amp;') }
			`<` { sb.write_string('&lt;') }
			`>` { sb.write_string('&gt;') }
			`"` { sb.write_string(if quote == `"` { '&quot;' } else { '"' }) }
			`'` { sb.write_string(if quote == `'` { '&apos;' } else { "'" }) }
			`\t` { sb.write_string('&#9;') }
			`\n` { sb.write_string('&#10;') }
			`\r` { sb.write_string('&#13;') }
			else { sb.write_u8(b) }
		}
	}
}

fn put_cdata(mut sb strings.Builder, s string) {
	sb.write_string('<![CDATA[')
	for k := 0; k < s.len; k++ {
		if s[k] == `\r` {
			sb.write_string(']]>&#13;<![CDATA[')
		} else if s[k] == `]` && k + 2 < s.len && s[k + 1] == `]` && s[k + 2] == `>` {
			sb.write_string(']]]]><![CDATA[>')
			k += 2
		} else {
			sb.write_u8(s[k])
		}
	}
	sb.write_string(']]>')
}

// outer_xml is node i written from the tree's parts: an element with its attributes and content,
// a text node's text, or for node 0 the whole document (the bytes before and after the root as
// they are). The namespace declarations in scope at an element that it does not make itself are
// written on it, so it reads the same wherever it is put; when no default namespace is in scope
// none is declared, so inside an element that declares one, its unprefixed names would take that
// one. Comments, processing instructions and whitespace between tags are not kept; a text read
// from CDATA is written as CDATA.
pub fn (d &Doc) outer_xml(i u32) string {
	mut e := emitter_in(d, ModePlan{ mode: .rewrite }, 256)
	if i == 0 {
		e.walk(0) or {}
	} else if d.tag[i] == text_tag {
		e.node_from_parts(i) or {}
	} else {
		e.element_from_parts(i, true) or {}
	}
	e.settle() or {}
	return e.buf.str()
}

// node_from_parts writes node i from the tree's parts, its child nodes as the plan says.
fn (mut e Emitter) node_from_parts(i u32) ! {
	d := e.d
	if d.tag[i] == text_tag {
		e.text(d.text(i), d.is_cdata(i))!
		return
	}
	e.element_from_parts(i, false)!
}

// element_from_parts writes element i: its start tag from its name and attributes (and, with
// carry_ns, the namespace declarations its ancestors make), its content, and an end tag, or
// `/>` when it has none.
fn (mut e Emitter) element_from_parts(i u32, carry_ns bool) ! {
	d := e.d
	e.settle()!
	e.buf.write_u8(`<`)
	e.buf.write_string(d.name(i))
	if carry_ns {
		for a in d.inherited_ns_decls(i) {
			e.attr(d.attr_name(a), d.attr_value(a), d.attr_source_quote(a))!
		}
	}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		e.attr(d.attr_name(a), d.attr_value(a), d.attr_source_quote(a))!
	}
	if d.first_child(i) == no_node && d.text_len[i] == 0 {
		e.put('/>')!
		return
	}
	e.put('>')!
	e.content_from_parts(i)!
	e.put('</')!
	e.put(d.name(i))!
	e.put('>')!
}

// content_from_parts writes element i's content: its text, or its child nodes as the plan says.
fn (mut e Emitter) content_from_parts(i u32) ! {
	d := e.d
	if d.text_len[i] != 0 {
		e.text(d.text(i), d.is_cdata(i))!
		return
	}
	mut c := d.first_child(i)
	for c != no_node {
		e.node(c)!
		c = d.next_sibling(c)
	}
}

// attr writes ` name="value"`, between the quote attr_quote chooses.
fn (mut e Emitter) attr(name string, value string, prefer u8) ! {
	q := attr_quote(value, prefer)
	e.settle()!
	e.buf.write_u8(` `)
	e.buf.write_string(name)
	e.buf.write_u8(`=`)
	e.buf.write_u8(q)
	put_attr(mut e.buf, value, q)
	e.buf.write_u8(q)
	e.spill()!
}

// text writes s as character data, or as CDATA.
fn (mut e Emitter) text(s string, cdata bool) ! {
	e.settle()!
	if cdata {
		put_cdata(mut e.buf, s)
	} else {
		put_text(mut e.buf, s)
	}
	e.spill()!
}

// attr_source_quote is the quote character attribute a is written between in the source.
@[inline]
fn (d &Doc) attr_source_quote(a u32) u8 {
	return unsafe { d.src[d.attr_off[a] - 1] }
}

// inherited_ns_decls is the namespace declarations (attribute indexes) made on the ancestors of
// i that are in scope at i: the nearest one of each prefix, unless i declares the prefix itself.
fn (d &Doc) inherited_ns_decls(i u32) []u32 {
	mut seen := []u32{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if is_ns_decl_name(d.attr_name(a)) {
			seen << d.attr_tag[a]
		}
	}
	mut out := []u32{}
	mut e := d.parent[i]
	// From the parent outwards: the first declaration of a prefix is the one in scope.
	for e != no_node {
		elo, ehi := d.attr_range(e)
		for a := elo; a < ehi; a++ {
			if is_ns_decl_name(d.attr_name(a)) && d.attr_tag[a] !in seen {
				seen << d.attr_tag[a]
				out << a
			}
		}
		e = d.parent[e]
	}
	return out
}

@[inline]
fn is_ns_decl_name(name string) bool {
	return name == 'xmlns' || name.starts_with('xmlns:')
}

// inner_xml is element i's content written from the tree's parts, as `outer_xml` writes it:
// child elements with their attributes, and text, escaped. Comments, processing instructions,
// entity spellings and whitespace between tags are not kept, and neither are namespace
// declarations made on ancestors of i.
pub fn (d &Doc) inner_xml(i u32) string {
	mut e := emitter_in(d, ModePlan{ mode: .rewrite }, 64)
	e.content_from_parts(i) or {}
	e.settle() or {}
	return e.buf.str()
}

// scope_decls are the namespace declarations an element read where the bindings src are in scope
// needs where dst are, so its names keep their namespaces: for each prefix bound differently,
// its binding in src (` xmlns:p="uri"`, or ` xmlns=""` for a default namespace src does not
// have), but for the prefixes in own, which the element declares itself.
fn scope_decls(src map[string]string, dst map[string]string, own map[string]string) []string {
	mut prefixes := src.keys()
	for p in dst.keys() {
		if p !in src {
			prefixes << p
		}
	}
	prefixes.sort()
	mut out := []string{}
	for p in prefixes {
		// `xml` is bound everywhere, and declaring it again changes nothing
		if p in own || p == 'xml' {
			continue
		}
		have := src[p] or { '' }
		there := dst[p] or { '' }
		if have == there {
			continue
		}
		if p == '' {
			out << ' xmlns="${escape_attr(have, `"`)}"'
		} else if have != '' {
			out << ' xmlns:${p}="${escape_attr(have, `"`)}"'
		}
	}
	return out
}

// bindings_above are the namespace bindings the elements above element i declare, in scope at i
// but for the prefixes i declares itself: prefix ('' for the default) -> URI.
fn (d &Doc) bindings_above(i u32) map[string]string {
	mut out := map[string]string{}
	for x in d.inherited_ns_decls(i) {
		out[decl_prefix(d.attr_name(x))] = d.attr_value(x)
	}
	return out
}

// own_bindings are the namespace declarations element i makes: prefix ('' for the default) ->
// URI.
fn (d &Doc) own_bindings(i u32) map[string]string {
	mut out := map[string]string{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if is_ns_decl_name(d.attr_name(a)) {
			out[decl_prefix(d.attr_name(a))] = d.attr_value(a)
		}
	}
	return out
}

// declares reports whether element i declares a namespace.
fn (d &Doc) declares(i u32) bool {
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if is_ns_decl_name(d.attr_name(a)) {
			return true
		}
	}
	return false
}
