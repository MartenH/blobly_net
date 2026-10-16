module xsd

// Pattern is an XML Schema regular expression (XSD 1.0, Part 2, appendix F), compiled into a
// program for a Pike VM: matching takes time linear in the input, whatever the pattern. A pattern
// is implicitly anchored at both ends; XSD has no anchors, back-references or lazy quantifiers.
// Unicode block escapes (\p{IsBasicLatin}) and the XML name classes (\i, \c) are refused, and so
// is a pattern whose repetitions compile to more than max_program steps.
pub struct Pattern {
pub:
	src string
mut:
	prog []Inst
	sets []CharSet
	work int // emit calls made while compiling, bounded like the program's size
}

enum Op as u8 {
	one   // a: the code point
	set   // a: the set's index
	split // a, b: the two ways on
	jmp   // a: where to
	done
}

struct Inst {
	op Op
	a  u32
	b  u32
}

// CharSet is a set of code points: ranges and whole general categories, negated or not, less
// another set.
struct CharSet {
mut:
	ranges  []u32 // lo, hi pairs, sorted and merged
	cats    u32   // a bit per general category (category_names)
	negated bool
	minus   int = -1 // a set taken away from this one, or -1
}

const max_program = 100_000

const all_categories = u32((1 << 30) - 1)

// --- compiling -----------------------------------------------------------------------------

enum NodeKind {
	empty
	one
	set
	concat
	alt
	repeat
}

struct RNode {
	kind NodeKind
	r    u32 // one: the code point; set: the set's index
	kids []int
	min  u32
	max  u32 // unbounded for no upper bound
}

struct RParser {
	src []u32
mut:
	pos   int
	nodes []RNode
	sets  []CharSet
}

// compile_pattern compiles an XSD pattern, or says what is wrong with it and where.
pub fn compile_pattern(pattern string) !Pattern {
	mut p := RParser{
		src: pattern.runes().map(u32(it))
	}
	root := p.regexp() or { return error('pattern "${pattern}": ${err}') }
	if p.pos < p.src.len {
		return error('pattern "${pattern}": unexpected `${rune_text(p.src[p.pos])}` at character ${
			p.pos + 1}')
	}
	mut c := Pattern{
		src:  pattern
		sets: p.sets
	}
	c.emit(p.nodes, root) or { return error('pattern "${pattern}": ${err}') }
	if c.prog.len > max_program {
		return error('pattern "${pattern}": it repeats too much: patterns of more than ${max_program} steps are not supported')
	}
	c.prog << Inst{
		op: .done
	}
	return c
}

fn (mut p RParser) peek() ?u32 {
	return if p.pos < p.src.len { p.src[p.pos] } else { none }
}

fn (mut p RParser) node(n RNode) int {
	p.nodes << n
	return p.nodes.len - 1
}

fn (mut p RParser) fail(msg string) IError {
	return error('${msg} at character ${p.pos + 1}')
}

// regexp is branch ( '|' branch )*.
fn (mut p RParser) regexp() !int {
	mut branches := [p.branch()!]
	for {
		c := p.peek() or { break }
		if c != `|` {
			break
		}
		p.pos++
		branches << p.branch()!
	}
	return if branches.len == 1 { branches[0] } else { p.node(kind: .alt, kids: branches) }
}

// branch is piece*, up to `|`, `)` or the end.
fn (mut p RParser) branch() !int {
	mut pieces := []int{}
	for {
		c := p.peek() or { break }
		if c == `|` || c == `)` {
			break
		}
		pieces << p.piece()!
	}
	return match pieces.len {
		0 { p.node(kind: .empty) }
		1 { pieces[0] }
		else { p.node(kind: .concat, kids: pieces) }
	}
}

// piece is an atom and at most one quantifier.
fn (mut p RParser) piece() !int {
	atom := p.atom()!
	c := p.peek() or { return atom }
	mut min, mut max := u32(0), u32(0)
	match c {
		`?` {
			min, max = 0, 1
		}
		`*` {
			min, max = 0, unbounded
		}
		`+` {
			min, max = 1, unbounded
		}
		`{` {
			min, max = p.quantity()!
			p.pos--
		}
		else {
			return atom
		}
	}
	p.pos++
	if q := p.peek() {
		if q in [u32(`?`), `*`, `+`, `{`] {
			return p.fail('a second quantifier')
		}
	}
	return p.node(kind: .repeat, kids: [atom], min: min, max: max)
}

// quantity reads `{n}`, `{n,}` or `{n,m}`, leaving pos at the closing brace.
fn (mut p RParser) quantity() !(u32, u32) {
	p.pos++
	min := p.number() or { return p.fail('`{` needs a number') }
	mut max := min
	c := p.peek() or { return p.fail('`{` is not closed') }
	if c == `,` {
		p.pos++
		d := p.peek() or { return p.fail('`{` is not closed') }
		max = if d == `}` { unbounded } else { p.number() or { return p.fail('`,` needs a number') } }
	}
	e := p.peek() or { return p.fail('`{` is not closed') }
	if e != `}` {
		return p.fail('`{` is not closed')
	}
	if max != unbounded && min > max {
		return p.fail('{${min},${max}} counts down')
	}
	p.pos++
	return min, max
}

fn (mut p RParser) number() ?u32 {
	start := p.pos
	mut n := u64(0)
	for p.pos < p.src.len && p.src[p.pos] >= `0` && p.src[p.pos] <= `9` {
		n = n * 10 + u64(p.src[p.pos] - `0`)
		if n > u64(max_program) {
			n = u64(max_program) + 1
		}
		p.pos++
	}
	return if p.pos == start { none } else { u32(n) }
}

fn (mut p RParser) atom() !int {
	c := p.peek() or { return p.fail('an atom is missing') }
	match c {
		`(` {
			p.pos++
			inner := p.regexp()!
			close := p.peek() or { return p.fail('`(` is not closed') }
			if close != `)` {
				return p.fail('`(` is not closed')
			}
			p.pos++
			return inner
		}
		`[` {
			p.pos++
			return p.node(kind: .set, r: u32(p.class_expr()!))
		}
		`.` {
			p.pos++
			return p.node(kind: .set, r: u32(p.add_set(ranges: [u32(0), 9, 0xB, 0xC, 0xE, 0x10FFFF])))
		}
		`\\` {
			p.pos++
			one := p.single_escape()!
			if one != not_single {
				return p.node(kind: .one, r: one)
			}
			return p.node(kind: .set, r: u32(p.add_set(p.multi_escape()!)))
		}
		`)`, `?`, `*`, `+`, `{`, `}`, `]`, `|` {
			return p.fail('`${rune_text(c)}` must be escaped')
		}
		else {
			p.pos++
			return p.node(kind: .one, r: c)
		}
	}
}

// class_expr reads a character class after its `[`, through its `]`, and returns the set.
fn (mut p RParser) class_expr() !int {
	mut set := CharSet{}
	if c := p.peek() {
		if c == `^` {
			set.negated = true
			p.pos++
		}
	}
	mut items := 0
	// Each item: a character, a range, or an escape; then perhaps `-[...]` to take a set away.
	for {
		c := p.peek() or { return p.fail('`[` is not closed') }
		if c == `]` {
			if items == 0 {
				return p.fail('an empty character class')
			}
			p.pos++
			break
		}
		if c == `-` && p.pos + 1 < p.src.len && p.src[p.pos + 1] == `[` {
			if items == 0 {
				return p.fail('a subtraction needs something to subtract from')
			}
			p.pos += 2
			set.minus = p.class_expr()!
			end := p.peek() or { return p.fail('`[` is not closed') }
			if end != `]` {
				return p.fail('a subtraction ends its class')
			}
			p.pos++
			break
		}
		if c == `[` {
			return p.fail('`[` must be escaped in a character class')
		}
		// a literal `-` stands first, or last: before `]`, or before the `-[` of a subtraction
		if c == `-` && items > 0 && !(p.pos + 1 < p.src.len && (p.src[p.pos + 1] == `]`
			|| (p.src[p.pos + 1] == `-` && p.pos + 2 < p.src.len && p.src[p.pos + 2] == `[`))) {
			return p.fail('`-` is a literal only first or last in a character class')
		}
		mut lo := u32(0)
		if c == `\\` {
			p.pos++
			lo = p.single_escape()!
			if lo == not_single {
				merge_into(mut set, p.multi_escape()!)
				items++
				continue
			}
		} else {
			lo = c
			p.pos++
		}
		mut hi := lo
		// a range, when `-` is followed by something other than `]` or `[`
		if p.pos + 1 < p.src.len && p.src[p.pos] == `-` && p.src[p.pos + 1] != `]`
			&& p.src[p.pos + 1] != `[` {
			p.pos++
			e := p.src[p.pos]
			if e == `\\` {
				p.pos++
				hi = p.single_escape()!
				if hi == not_single {
					return p.fail('a range ends in a single character')
				}
			} else if e == `[` || e == `]` || e == `-` {
				return p.fail('`${rune_text(e)}` must be escaped in a range')
			} else {
				hi = e
				p.pos++
			}
			if hi < lo {
				return p.fail('the range ${rune_text(lo)}-${rune_text(hi)} runs backwards')
			}
		}
		set.ranges << lo
		set.ranges << hi
		items++
	}
	set.ranges = normalised(set.ranges)
	return p.add_set(set)
}

// not_single is what single_escape answers for an escape that is not a single character.
const not_single = u32(0xFFFF_FFFF)

// single_escape reads a single-character escape after its backslash; not_single for a
// multi-character or category escape, left unread.
fn (mut p RParser) single_escape() !u32 {
	c := p.peek() or { return p.fail('a `\\` ends the pattern') }
	v := match c {
		`n` { u32(0xA) }
		`r` { u32(0xD) }
		`t` { u32(0x9) }
		`\\`, `|`, `.`, `?`, `*`, `+`, `(`, `)`, `{`, `}`, `-`, `[`, `]`, `^` { c }
		else { return not_single }
	}
	p.pos++
	return v
}

// multi_escape reads a multi-character or category escape after its backslash.
fn (mut p RParser) multi_escape() !CharSet {
	c := p.peek() or { return p.fail('a `\\` ends the pattern') }
	p.pos++
	return match c {
		`s` { CharSet{ranges: [u32(0x9), 0xA, 0xD, 0xD, 0x20, 0x20]} }
		`S` { CharSet{ranges: [u32(0), 0x8, 0xB, 0xC, 0xE, 0x1F, 0x21, 0x10FFFF]} }
		`d` { CharSet{cats: category_mask('Nd')} }
		`D` { CharSet{cats: all_categories & ~category_mask('Nd')} }
		`w` { CharSet{cats: category_mask('L') | category_mask('M') | category_mask('N') | category_mask('S')} }
		`W` { CharSet{cats: category_mask('P') | category_mask('Z') | category_mask('C')} }
		`p`, `P` { p.category_escape(c == `P`)! }
		`i`, `I`, `c`, `C` { error('\\${rune_text(c)} (XML name characters) is not supported') }
		else { p.fail('unknown escape \\${rune_text(c)}') }
	}
}

// category_escape reads `{Name}` after \p or \P.
fn (mut p RParser) category_escape(negated bool) !CharSet {
	open := p.peek() or { return p.fail('\\p needs `{`') }
	if open != `{` {
		return p.fail('\\p needs `{`')
	}
	start := p.pos + 1
	for p.pos < p.src.len && p.src[p.pos] != `}` {
		p.pos++
	}
	if p.pos >= p.src.len {
		return p.fail('`{` is not closed')
	}
	name := p.src[start..p.pos].map(rune(it)).string()
	p.pos++
	if name.starts_with('Is') {
		return error('\\p{${name}} (a Unicode block) is not supported')
	}
	mask := category_mask(name)
	if mask == 0 {
		return p.fail('unknown category ${name}')
	}
	return CharSet{
		cats:    mask
		negated: negated
	}
}

fn (mut p RParser) add_set(s CharSet) int {
	p.sets << s
	return p.sets.len - 1
}

// merge_into adds an escape's set to a class being built. A negated escape set (\P{..}) is
// turned positive first: its complement in categories.
fn merge_into(mut set CharSet, e CharSet) {
	if e.negated {
		set.cats |= all_categories & ~e.cats
		return
	}
	set.cats |= e.cats
	set.ranges << e.ranges
}

// normalised sorts lo, hi pairs and merges those that touch.
fn normalised(pairs []u32) []u32 {
	mut ps := [][]u32{}
	for k := 0; k + 1 < pairs.len; k += 2 {
		ps << [pairs[k], pairs[k + 1]]
	}
	ps.sort(a[0] < b[0])
	mut out := []u32{}
	for r in ps {
		if out.len > 0 && r[0] <= out[out.len - 1] + 1 {
			if r[1] > out[out.len - 1] {
				out[out.len - 1] = r[1]
			}
		} else {
			out << r[0]
			out << r[1]
		}
	}
	return out
}

// category_mask is the bits of a category name: one (`Lu`), or every one of a letter (`L`).
fn category_mask(name string) u32 {
	mut mask := u32(0)
	for i, c in category_names {
		if c == name || (name.len == 1 && c[0] == name[0]) {
			mask |= u32(1) << i
		}
	}
	return mask
}

// emit compiles node n of the tree, Thompson-style, into the program.
fn (mut c Pattern) emit(nodes []RNode, n int) ! {
	// a repeat of something empty grows no program, so the calls are bounded too
	c.work++
	if c.prog.len > max_program || c.work > 4 * max_program {
		return error('it repeats too much: patterns of more than ${max_program} steps are not supported')
	}
	node := nodes[n]
	match node.kind {
		.empty {}
		.one {
			c.prog << Inst{
				op: .one
				a:  node.r
			}
		}
		.set {
			c.prog << Inst{
				op: .set
				a:  node.r
			}
		}
		.concat {
			for k in node.kids {
				c.emit(nodes, k)!
			}
		}
		.alt {
			// split to each branch in turn; every branch jumps to the end
			mut to_end := []int{}
			for i, k in node.kids {
				if i < node.kids.len - 1 {
					split := c.prog.len
					c.prog << Inst{
						op: .split
						a:  u32(split + 1)
					}
					c.emit(nodes, k)!
					to_end << c.prog.len
					c.prog << Inst{
						op: .jmp
					}
					c.prog[split] = Inst{
						op: .split
						a:  u32(split + 1)
						b:  u32(c.prog.len)
					}
				} else {
					c.emit(nodes, k)!
				}
			}
			for j in to_end {
				c.prog[j] = Inst{
					op: .jmp
					a:  u32(c.prog.len)
				}
			}
		}
		.repeat {
			kid := node.kids[0]
			for _ in 0 .. node.min {
				c.emit(nodes, kid)!
			}
			if node.max == unbounded {
				loop := c.prog.len
				c.prog << Inst{
					op: .split
				}
				c.emit(nodes, kid)!
				c.prog << Inst{
					op: .jmp
					a:  u32(loop)
				}
				c.prog[loop] = Inst{
					op: .split
					a:  u32(loop + 1)
					b:  u32(c.prog.len)
				}
				return
			}
			// the optional copies all skip to the same end
			mut skips := []int{}
			for _ in node.min .. node.max {
				skips << c.prog.len
				c.prog << Inst{
					op: .split
				}
				c.emit(nodes, kid)!
			}
			for j in skips {
				c.prog[j] = Inst{
					op: .split
					a:  u32(j + 1)
					b:  u32(c.prog.len)
				}
			}
		}
	}
}

// --- matching ------------------------------------------------------------------------------

// Scratch is a matcher's working space, kept between matches so that a match allocates nothing.
// One Scratch serves any number of patterns, one match at a time.
pub struct Scratch {
mut:
	cur   []u32
	next  []u32
	mark  []u32 // per instruction: the step that last put it on a list
	stack []u32
	gen   u32
}

// matches reports whether the whole of s matches the pattern.
pub fn (pat &Pattern) matches(s string) bool {
	mut sc := Scratch{}
	return pat.matches_in(mut sc, s)
}

// matches_in is matches with the working space sc, reused from the last call.
pub fn (pat &Pattern) matches_in(mut sc Scratch, s string) bool {
	n := pat.prog.len
	if sc.mark.len < n || sc.gen > 0xFFFF_0000 {
		sc.mark = []u32{len: if n > sc.mark.len { n } else { sc.mark.len }}
		sc.gen = 0
	}
	sc.cur.clear()
	sc.next.clear()
	sc.gen++
	pat.add(mut sc.cur, mut sc.mark, sc.gen, mut sc.stack, 0)
	mut i := 0
	// Advance every live thread over one code point at a time.
	for i < s.len {
		ch, w := decode_rune(s, i)
		i += w
		// marks only tell one step from the next, so they may restart between steps
		if sc.gen >= 0xFFFF_FFF0 {
			sc.mark = []u32{len: sc.mark.len}
			sc.gen = 0
		}
		sc.gen++
		sc.next.clear()
		for pc in sc.cur {
			inst := pat.prog[pc]
			hit := match inst.op {
				.one { ch == inst.a }
				.set { pat.in_set(int(inst.a), ch) }
				else { false }
			}
			if hit {
				pat.add(mut sc.next, mut sc.mark, sc.gen, mut sc.stack, pc + 1)
			}
		}
		// the lists trade places: no copy
		unsafe {
			sc.cur, sc.next = sc.next, sc.cur
		}
		if sc.cur.len == 0 {
			return false
		}
	}
	return sc.cur.any(pat.prog[it].op == .done)
}

// add puts the thread at pc on the list, following jumps and splits; each step visits an
// instruction once.
fn (pat &Pattern) add(mut list []u32, mut mark []u32, gen u32, mut stack []u32, pc0 u32) {
	stack << pc0
	for stack.len > 0 {
		pc := stack.pop()
		if mark[pc] == gen {
			continue
		}
		mark[pc] = gen
		inst := pat.prog[pc]
		match inst.op {
			.jmp {
				stack << inst.a
			}
			.split {
				stack << inst.b
				stack << inst.a
			}
			else {
				list << pc
			}
		}
	}
}

fn (pat &Pattern) in_set(k int, ch u32) bool {
	set := pat.sets[k]
	mut hit := in_ranges(set.ranges, ch)
	if !hit && set.cats != 0 {
		hit = (set.cats >> category_of(ch)) & 1 == 1
	}
	if set.negated {
		hit = !hit
	}
	if hit && set.minus >= 0 {
		return !pat.in_set(set.minus, ch)
	}
	return hit
}

fn in_ranges(ranges []u32, ch u32) bool {
	for k := 0; k < ranges.len; k += 2 {
		if ch < ranges[k] {
			return false
		}
		if ch <= ranges[k + 1] {
			return true
		}
	}
	return false
}

// category_of is the general category of code point ch, by binary search over the runs.
fn category_of(ch u32) u8 {
	mut lo, mut hi := 0, category_starts.len - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if category_starts[mid] <= ch {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return category_of_run[lo]
}

// decode_rune reads the code point at byte i; a malformed sequence (a stray or invalid lead
// byte, a short or overlong sequence, a surrogate, a code point past U+10FFFF) reads as U+FFFD,
// one byte.
fn decode_rune(s string, i int) (u32, int) {
	b0 := s[i]
	if b0 < 0x80 {
		return b0, 1
	}
	n, lo, hi := match true {
		b0 >= 0xC2 && b0 <= 0xDF { 2, u8(0x80), u8(0xBF) }
		b0 == 0xE0 { 3, u8(0xA0), u8(0xBF) }
		b0 == 0xED { 3, u8(0x80), u8(0x9F) }
		b0 >= 0xE1 && b0 <= 0xEF { 3, u8(0x80), u8(0xBF) }
		b0 == 0xF0 { 4, u8(0x90), u8(0xBF) }
		b0 >= 0xF1 && b0 <= 0xF3 { 4, u8(0x80), u8(0xBF) }
		b0 == 0xF4 { 4, u8(0x80), u8(0x8F) }
		else { 1, u8(0), u8(0) }
	}
	if n == 1 || i + n > s.len || s[i + 1] < lo || s[i + 1] > hi {
		return 0xFFFD, 1
	}
	mut ch := u32(b0) & (u32(0x7F) >> n)
	for k in 1 .. n {
		b := s[i + k]
		if b & 0xC0 != 0x80 {
			return 0xFFFD, 1
		}
		ch = ch << 6 | u32(b & 0x3F)
	}
	return ch, n
}

fn rune_text(c u32) string {
	return rune(c).str()
}

// --- a lazily built DFA --------------------------------------------------------------------

// Dfa matches like its pattern, a table step per byte: each state is a set of the NFA's
// instructions, made the first time a match reaches it, with its transitions filled in as they
// are taken (bytes below 0x80 in a table, other code points in a map). Past dfa_max_states it
// stops building and matches with the Pike VM instead, so its memory stays bounded. A Dfa
// changes as it matches, so it belongs to one validation, not to the schema.
pub struct Dfa {
mut:
	pat     &Pattern = unsafe { nil }
	sets    [][]u32        // per state: the instructions on its list, sorted
	index   map[string]int // a set, as a key, to its state
	ascii   [][]i32        // per state and byte below 0x80: the next state, or dfa_unknown
	other   []map[u32]int  // per state: the next state for code points from 0x80 up
	accept  []bool
	full    bool
	scratch Scratch
}

const dfa_unknown = -1

const dfa_max_states = 2000

// new_dfa is an empty DFA for pattern pat, holding only its start state.
pub fn new_dfa(pat &Pattern) Dfa {
	mut d := Dfa{
		pat: unsafe { pat }
	}
	mut sc := Scratch{
		mark: []u32{len: pat.prog.len}
	}
	sc.gen++
	pat.add(mut sc.cur, mut sc.mark, sc.gen, mut sc.stack, 0)
	d.state_of(sc.cur) or {}
	d.scratch = sc
	return d
}

// matches reports whether the whole of s matches the pattern.
pub fn (mut d Dfa) matches(s string) bool {
	if d.full {
		return d.pat.matches_in(mut d.scratch, s)
	}
	mut st := 0
	mut i := 0
	// One transition per byte below 0x80, one per code point above.
	for i < s.len {
		b := s[i]
		mut next := 0
		if b < 0x80 {
			next = d.ascii[st][b]
			if next == dfa_unknown {
				next = d.step(st, u32(b)) or { return d.pat.matches_in(mut d.scratch, s) }
				d.ascii[st][b] = next
			}
			i++
		} else {
			ch, w := decode_rune(s, i)
			i += w
			next = d.other[st][ch] or {
				n := d.step(st, ch) or { return d.pat.matches_in(mut d.scratch, s) }
				d.other[st][ch] = n
				n
			}
		}
		if d.sets[next].len == 0 {
			return false
		}
		st = next
	}
	return d.accept[st]
}

// step is the state reached from state st over ch; none once the DFA is full.
fn (mut d Dfa) step(st int, ch u32) ?int {
	mut sc := &d.scratch
	if sc.mark.len < d.pat.prog.len || sc.gen > 0xFFFF_0000 {
		sc.mark = []u32{len: d.pat.prog.len}
		sc.gen = 0
	}
	sc.gen++
	sc.next.clear()
	for pc in d.sets[st] {
		inst := d.pat.prog[pc]
		hit := match inst.op {
			.one { ch == inst.a }
			.set { d.pat.in_set(int(inst.a), ch) }
			else { false }
		}
		if hit {
			d.pat.add(mut sc.next, mut sc.mark, sc.gen, mut sc.stack, pc + 1)
		}
	}
	return d.state_of(sc.next)
}

// state_of is the state for the instruction list pcs, made if it is new; none when it is new and
// the DFA is full, which then marks it full.
fn (mut d Dfa) state_of(pcs []u32) ?int {
	mut set := pcs.clone()
	set.sort()
	key := set.map(it.str()).join(',')
	if k := d.index[key] {
		return k
	}
	if d.sets.len >= dfa_max_states {
		d.full = true
		return none
	}
	k := d.sets.len
	d.sets << set
	d.index[key] = k
	d.ascii << []i32{len: 128, init: dfa_unknown}
	d.other << map[u32]int{}
	d.accept << set.any(d.pat.prog[it].op == .done)
	return k
}
