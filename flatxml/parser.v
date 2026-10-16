module flatxml

// name_end marks the bytes that end a name: whitespace, controls, and the markup around names.
// Every other byte, UTF-8 included, is accepted as a name character (the parser does not
// validate names).
const name_end = name_end_table()

fn name_end_table() []bool {
	mut t := []bool{len: 256}
	for c in 0 .. 0x21 {
		t[c] = true
	}
	for c in [u8(`/`), `>`, `=`, `<`, `"`, `'`] {
		t[c] = true
	}
	return t
}

@[inline]
fn is_ws(c u8) bool {
	return c == ` ` || c == `\n` || c == `\t` || c == `\r`
}

@[inline]
fn find_byte(s &u8, from int, to int, c u8) int {
	q := unsafe { C.memchr(voidptr(s + from), c, usize(to - from)) }
	if isnil(q) {
		return -1
	}
	return unsafe { int(&u8(q) - s) }
}

fn (d &Doc) err_at(off int, msg string) IError {
	line, col := line_col_at(d.src, off)
	return error('${d.path}:${line}:${col}: ${msg}')
}

// reserve sizes the arrays for dense markup, about one element per 100 bytes (measured on real
// configuration files and on generated ones) with headroom, and an attribute per 256. Denser input
// regrows them.
fn (mut d Doc) reserve() {
	nodes := d.src_len / 80 + 16
	attrs := d.src_len / 256 + 16
	d.tag = []u32{cap: nodes}
	d.parent = []u32{cap: nodes}
	d.end = []u32{cap: nodes}
	d.src_off = []u32{cap: nodes}
	d.text_off = []u32{cap: nodes}
	d.text_len = []u32{cap: nodes}
	d.attr_lo = []u32{cap: nodes}
	d.attr_tag = []u32{cap: attrs}
	d.attr_off = []u32{cap: attrs}
	d.attr_len = []u32{cap: attrs}
}

@[inline]
fn (mut d Doc) push_node(tag u32, parent u32, off u32) u32 {
	i := u32(d.tag.len)
	d.tag << tag
	d.parent << parent
	d.end << 0
	d.src_off << off
	d.text_off << 0
	d.text_len << 0
	d.attr_lo << u32(d.attr_tag.len)
	return i
}

// parse fills the arrays from the source in one forward pass. The open elements are the chain
// cur, parent[cur], ...: the parent array is the parser's stack.
@[direct_array_access]
fn (mut d Doc) parse() ! {
	s := d.src
	n := d.src_len
	if isnil(d.tab) {
		d.tab = Names.new()
		d.own_tab = true
	}
	d.reserve()
	d.push_node(doc_tag, 0, 0)
	mut i := 0
	if n >= 3 && unsafe { s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF } {
		i = 3 // UTF-8 byte order mark
	}
	mut cur := u32(0) // innermost open element; 0 before and after the root
	mut seen_root := false
	for i < n {
		mut j := find_byte(s, i, n, `<`)
		if j < 0 {
			j = n
		}
		if j > i {
			d.add_text(cur, i, j, false)!
		}
		if j >= n {
			break
		}
		i = j + 1
		if i >= n {
			return d.err_at(j, 'unexpected end of input after `<`')
		}
		c := unsafe { s[i] }
		if c == `/` {
			if cur == 0 {
				return d.err_at(j, 'end tag </${d.name_at(i + 1)}> without a start tag')
			}
			open := d.tab.names[d.tag[cur]]
			i++
			if i + open.len > n || unsafe { C.memcmp(s + i, open.str, open.len) } != 0
				|| (i + open.len < n && !name_end[unsafe { s[i + open.len] }]) {
				return d.err_at(j, 'end tag </${d.name_at(i)}> does not match <${open}> at ${d.short_pos(cur)}')
			}
			i += open.len
			for i < n && is_ws(unsafe { s[i] }) {
				i++
			}
			if i >= n || unsafe { s[i] } != `>` {
				return d.err_at(j, 'expected `>` to close </${open}>')
			}
			i++
			d.end[cur] = u32(d.tag.len)
			cur = d.parent[cur]
		} else if c == `!` {
			i = d.markup_decl(j, cur, seen_root)!
		} else if c == `?` {
			i = d.skip_pi(j)!
		} else {
			if cur == 0 && seen_root {
				return d.err_at(j, 'more than one root element')
			}
			name_start := i
			for i < n && !name_end[unsafe { s[i] }] {
				i++
			}
			if i == name_start {
				return d.err_at(j, 'expected a name after `<`')
			}
			if i >= n {
				return d.err_at(j, 'start tag is not closed')
			}
			id := d.tab.intern(unsafe { s + name_start }, i - name_start)
			d.demote_text(cur)
			node := d.push_node(id, cur, u32(j))
			if cur == 0 {
				seen_root = true
			}
			// attributes, then `>` or `/>`; i is just past the name or the last value
			for {
				a := unsafe { s[i] }
				if a == `>` {
					i++
					cur = node
					break
				}
				if a == `/` {
					if i + 1 < n && unsafe { s[i + 1] } == `>` {
						i += 2
						d.end[node] = node + 1
						break
					}
					return d.err_at(i, 'expected `>` after `/`')
				}
				if !is_ws(a) {
					return d.err_at(i, 'expected whitespace, `>` or `/>` in <${d.tab.names[id]}>')
				}
				for i < n && is_ws(unsafe { s[i] }) {
					i++
				}
				if i >= n {
					return d.err_at(j, 'start tag <${d.tab.names[id]}> is not closed')
				}
				b := unsafe { s[i] }
				if b == `>` || b == `/` {
					continue
				}
				an := i
				for i < n && !name_end[unsafe { s[i] }] {
					i++
				}
				if i == an {
					return d.err_at(i, 'expected an attribute name in <${d.tab.names[id]}>')
				}
				aid := d.tab.intern(unsafe { s + an }, i - an)
				for i < n && is_ws(unsafe { s[i] }) {
					i++
				}
				if i >= n || unsafe { s[i] } != `=` {
					return d.err_at(an, 'expected `=` after attribute ${d.tab.names[aid]}')
				}
				i++
				for i < n && is_ws(unsafe { s[i] }) {
					i++
				}
				if i >= n {
					return d.err_at(an, 'attribute ${d.tab.names[aid]} has no value')
				}
				q := unsafe { s[i] }
				if q != `"` && q != `'` {
					return d.err_at(i, 'expected a quoted value for attribute ${d.tab.names[aid]}')
				}
				i++
				ve := find_byte(s, i, n, q)
				if ve < 0 {
					return d.err_at(an, 'value of attribute ${d.tab.names[aid]} is not closed')
				}
				if ve > i {
					lt := find_byte(s, i, ve, `<`)
					if lt >= 0 {
						return d.err_at(lt, '`<` in the value of attribute ${d.tab.names[aid]}')
					}
					if find_byte(s, i, ve, `&`) >= 0 {
						d.check_refs(i, ve)!
					}
				}
				d.attr_tag << aid
				d.attr_off << u32(i)
				d.attr_len << u32(ve - i)
				i = ve + 1
				if i >= n {
					return d.err_at(j, 'start tag <${d.tab.names[id]}> is not closed')
				}
			}
		}
	}
	if cur != 0 {
		return d.err_at(int(d.src_off[cur]), 'element <${d.tab.names[d.tag[cur]]}> is not closed')
	}
	if !seen_root {
		return d.err_at(n, 'no root element')
	}
	d.end[0] = u32(d.tag.len)
}

// add_text records the text a .. b inside the open element cur. Whitespace-only text is
// dropped unless it is CDATA. Text that is an element's only content stays on the element;
// any other text becomes a text node.
@[direct_array_access]
fn (mut d Doc) add_text(cur u32, a int, b int, cdata bool) ! {
	s := d.src
	if cdata {
		if a == b {
			return
		}
	} else {
		mut k := a
		for k < b && is_ws(unsafe { s[k] }) {
			k++
		}
		if k == b {
			return
		}
		if cur == 0 {
			return d.err_at(k, 'text outside the root element')
		}
		if find_byte(s, k, b, `&`) >= 0 {
			d.check_refs(k, b)!
		}
	}
	if u32(d.tag.len) == cur + 1 {
		// cur has no child nodes yet
		if d.text_len[cur] == 0 {
			d.text_off[cur] = u32(a)
			d.text_len[cur] = u32(b - a)
			return
		}
		d.demote_text(cur)
	}
	t := d.push_node(text_tag, cur, u32(a))
	d.end[t] = t + 1
	d.text_off[t] = u32(a)
	d.text_len[t] = u32(b - a)
}

// demote_text moves the text held on cur into a text node of its own, before cur gets a second
// piece of content. Only an element with no child nodes holds text, so the new node is cur's
// first child.
@[direct_array_access]
fn (mut d Doc) demote_text(cur u32) {
	if d.text_len[cur] == 0 {
		return
	}
	off := d.text_off[cur]
	len := d.text_len[cur]
	t := d.push_node(text_tag, cur, off)
	d.end[t] = t + 1
	d.text_off[t] = off
	d.text_len[t] = len
	d.text_off[cur] = 0
	d.text_len[cur] = 0
}

// markup_decl skips a comment or DOCTYPE, or records a CDATA section, at j (`<!`), and returns
// the offset just past it.
fn (mut d Doc) markup_decl(j int, cur u32, seen_root bool) !int {
	s := d.src
	n := d.src_len
	if d.starts_at(j, '<!--') {
		e := d.comment_end(j)
		if e < 0 {
			return d.err_at(j, 'comment is not closed')
		}
		return e
	}
	if d.starts_at(j, '<![CDATA[') {
		if cur == 0 {
			return d.err_at(j, 'CDATA section outside the root element')
		}
		e := d.cdata_end(j)
		if e < 0 {
			return d.err_at(j, 'CDATA section is not closed')
		}
		d.add_text(cur, j + 9, e - 3, true)!
		return e
	}
	if d.starts_at(j, '<!DOCTYPE') {
		if cur != 0 || seen_root {
			return d.err_at(j, 'DOCTYPE after the root element')
		}
		// skip it, internal subset included; entities it declares are not supported
		mut k := j + 9
		mut depth := 0
		for k < n {
			c := unsafe { s[k] }
			if c == `"` || c == `'` {
				q := find_byte(s, k + 1, n, c)
				if q < 0 {
					break
				}
				k = q + 1
				continue
			}
			// comments and PIs in the internal subset may hold brackets and quotes
			if c == `<` && depth > 0 && d.starts_at(k, '<!--') {
				k = d.markup_decl(k, cur, seen_root)!
				continue
			}
			if c == `<` && depth > 0 && d.starts_at(k, '<?') {
				k = d.skip_pi(k)!
				continue
			}
			if c == `[` {
				depth++
			} else if c == `]` {
				depth--
			} else if c == `>` && depth <= 0 {
				return k + 1
			}
			k++
		}
		return d.err_at(j, 'DOCTYPE is not closed')
	}
	return d.err_at(j, 'expected `<!--`, `<![CDATA[` or `<!DOCTYPE`')
}

// comment_end is the offset just past the comment that starts at j (`<!--`), or -1 if it is not
// closed. `<!-->` does not close it.
fn (d &Doc) comment_end(j int) int {
	mut k := j + 4
	for {
		p := find_byte(d.src, k, d.src_len, `>`)
		if p < 0 {
			return -1
		}
		if p >= j + 6 && unsafe { d.src[p - 1] == `-` && d.src[p - 2] == `-` } {
			return p + 1
		}
		k = p + 1
	}
	return -1
}

// cdata_end is the offset just past the CDATA section that starts at j (`<![CDATA[`), or -1 if it
// is not closed.
fn (d &Doc) cdata_end(j int) int {
	a := j + 9
	mut k := a
	for {
		p := find_byte(d.src, k, d.src_len, `>`)
		if p < 0 {
			return -1
		}
		if p >= a + 2 && unsafe { d.src[p - 1] == `]` && d.src[p - 2] == `]` } {
			return p + 1
		}
		k = p + 1
	}
	return -1
}

// skip_pi skips a processing instruction (or the XML declaration) at j and returns the offset
// just past it.
fn (d &Doc) skip_pi(j int) !int {
	mut k := j + 2
	for {
		p := find_byte(d.src, k, d.src_len, `>`)
		if p < 0 {
			return d.err_at(j, 'processing instruction is not closed')
		}
		if p - 1 >= j + 2 && unsafe { d.src[p - 1] } == `?` {
			return p + 1
		}
		k = p + 1
	}
	return 0
}

// check_refs fails on an `&` in a .. b that does not start a reference `decode` can expand.
fn (d &Doc) check_refs(a int, b int) ! {
	mut k := a
	for k < b {
		p := find_byte(d.src, k, b, `&`)
		if p < 0 {
			return
		}
		mut e := p + 1
		for e < b && e - p < 32 && unsafe { d.src[e] } != `;` {
			e++
		}
		if e >= b || unsafe { d.src[e] } != `;` {
			return d.err_at(p, '`&` does not start an entity reference (a literal one is `&amp;`)')
		}
		ref_value(d.src, p + 1, e) or {
			return d.err_at(p, 'unknown entity or invalid character reference `${unsafe {
				tos(d.src +
					p, e - p + 1)
			}}`')
		}
		k = e + 1
	}
}

@[inline]
fn (d &Doc) starts_at(j int, lit string) bool {
	return j + lit.len <= d.src_len && unsafe { C.memcmp(d.src + j, lit.str, lit.len) } == 0
}

// name_at is the name starting at i, for messages.
fn (d &Doc) name_at(i int) string {
	mut k := i
	for k < d.src_len && !name_end[unsafe { d.src[k] }] {
		k++
	}
	return unsafe { tos(d.src + i, k - i) }.clone()
}

fn (d &Doc) short_pos(i u32) string {
	line, col := line_col_at(d.src, int(d.src_off[i]))
	return '${line}:${col}'
}
