// ldf — the LDF reader: a hand-written lexer and a recursive-descent parser into a raw form
// that keeps every value as the token it was written as, then `resolve` (resolve.v) checks the
// values against the leaf table and builds the model. The two passes are what let sections come
// in any order: a frame may be read before the signals it maps and the header last.
//
// A file the parser cannot follow — a missing `;`, an unclosed brace, a character no LDF uses —
// is an error naming the line and column. A value in the wrong shape (`id = x`) is not a parse
// error: the parser takes any value token where a value goes and the leaf table refuses it.
module lindb

import os

enum TokKind {
	ident
	number
	str
	punct
	eof
}

struct Tok {
	kind TokKind
	text string
	line int
	col  int
}

fn (t Tok) show() string {
	return match t.kind {
		.eof { 'end of file' }
		.str { '"${t.text}"' }
		else { "'${t.text}'" }
	}
}

fn is_ident_start(c u8) bool {
	return c.is_letter() || c == `_`
}

fn is_ident_char(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

// lex splits an LDF into tokens, dropping `//` and `/* */` comments.
fn lex(src string) ![]Tok {
	mut toks := []Tok{cap: src.len / 4}
	mut i := 0
	mut line := 1
	mut lstart := 0
	if src.starts_with('\xef\xbb\xbf') {
		i = 3
		lstart = 3
	}
	for i < src.len {
		c := src[i]
		if c == `\n` {
			line++
			i++
			lstart = i
			continue
		}
		if c == ` ` || c == `\t` || c == `\r` || c == `\f` || c == `\v` {
			i++
			continue
		}
		col := i - lstart + 1
		if c == `/` && i + 1 < src.len && src[i + 1] == `/` {
			for i < src.len && src[i] != `\n` {
				i++
			}
			continue
		}
		if c == `/` && i + 1 < src.len && src[i + 1] == `*` {
			oline := line
			i += 2
			mut closed := false
			for i < src.len {
				if src[i] == `*` && i + 1 < src.len && src[i + 1] == `/` {
					i += 2
					closed = true
					break
				}
				if src[i] == `\n` {
					line++
					lstart = i + 1
				}
				i++
			}
			if !closed {
				return error('${oline}:${col}: comment opened here is never closed')
			}
			continue
		}
		if c == `"` {
			start := i + 1
			sline := line
			i++
			// a backslash escapes the next character, so `\"` does not close the string
			for i < src.len && src[i] != `"` {
				if src[i] == `\\` && i + 1 < src.len {
					i++
				}
				if src[i] == `\n` {
					line++
					lstart = i + 1
				}
				i++
			}
			if i >= src.len {
				return error('${sline}:${col}: string is never closed')
			}
			toks << Tok{.str, unescape(src[start..i]), sline, col}
			i++
			continue
		}
		if c.is_digit() || (c == `-` && i + 1 < src.len && src[i + 1].is_digit()) {
			start := i
			i++
			// a number token runs over every character a number or a malformed one could hold,
			// so `0x3G` or `1.5.2` reaches the leaf table whole rather than splitting
			for i < src.len {
				d := src[i]
				if is_ident_char(d) || d == `.` {
					i++
				} else if (d == `+` || d == `-`) && (src[i - 1] == `e` || src[i - 1] == `E`) {
					i++
				} else {
					break
				}
			}
			mut text := src[start..i]
			// "5ms": the unit is a word of its own
			for _, unit in ['ms', 'kbps'] {
				if text.ends_with(unit) && text.len > unit.len && text[text.len - unit.len - 1].is_digit() {
					text = text[..text.len - unit.len]
					toks << Tok{.number, text, line, col}
					toks << Tok{.ident, unit, line, col + text.len}
					text = ''
					break
				}
			}
			if text != '' {
				toks << Tok{.number, text, line, col}
			}
			continue
		}
		if is_ident_start(c) {
			start := i
			for i < src.len && is_ident_char(src[i]) {
				i++
			}
			toks << Tok{.ident, src[start..i], line, col}
			continue
		}
		if c in [`{`, `}`, `:`, `;`, `,`, `=`, `%`] {
			toks << Tok{.punct, c.ascii_str(), line, col}
			i++
			continue
		}
		return error('${line}:${col}: unexpected character ${c.ascii_str()}')
	}
	toks << Tok{.eof, '', line, i - lstart + 1}
	return toks
}

// unescape is a string's text with each `\x` read as `x` (`\"` a quote, `\\` a backslash).
fn unescape(s string) string {
	if !s.contains('\\') {
		return s
	}
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		if s[i] == `\\` && i + 1 < s.len {
			i++
		}
		out << s[i]
		i++
	}
	return out.bytestr()
}

// --- the raw form: every value as its token --------------------------------------------------

struct RawSignal {
	name        Tok
	width       Tok
	init        []Tok
	array       bool
	publisher   Tok
	subscribers []Tok
	diag        bool
}

struct RawMap {
	signal Tok
	offset Tok
}

struct RawFrame {
	name      Tok
	id        Tok
	publisher Tok
	length    ?Tok
	maps      []RawMap
	diag      bool
}

struct RawEvent {
	name   Tok
	table  ?Tok
	id     Tok
	frames []Tok
}

struct RawSporadic {
	name   Tok
	frames []Tok
}

// RawAttr is one `name = values;` of a node, the values with their unit words.
struct RawAttr {
	name   Tok
	values [][]Tok
}

struct RawConfFrame {
	name Tok
	id   ?Tok
}

struct RawNode {
mut:
	name   Tok
	attrs  []RawAttr
	frames []RawConfFrame
	blocks int // configurable_frames blocks given
}

struct RawSlot {
	cmd    Tok
	args   []Tok // a command's braced arguments
	braced bool
	delay  []Tok
}

struct RawSchedule {
mut:
	name  Tok
	slots []RawSlot
}

struct RawRule {
	kind Tok
	args []Tok
}

struct RawEncoding {
mut:
	name  Tok
	rules []RawRule
}

struct RawRep {
	encoding Tok
	signals  []Tok
}

struct Raw {
mut:
	header     map[string][]Tok // LIN_speed etc.: the value tokens
	described  bool             // LIN_description_file was stated
	master     ?[][]Tok
	slaves     []Tok
	nodes_seen bool
	signals    []RawSignal
	frames     []RawFrame
	events     []RawEvent
	sporadics  []RawSporadic
	nodes      []RawNode
	schedules  []RawSchedule
	encodings  []RawEncoding
	reps       []RawRep
	notes      []string // what the parser skipped
	big_endian bool
}

struct Parser {
	toks []Tok
mut:
	pos int
	raw Raw
}

fn (p &Parser) peek() Tok {
	return p.toks[p.pos]
}

fn (mut p Parser) next() Tok {
	t := p.toks[p.pos]
	if t.kind != .eof {
		p.pos++
	}
	return t
}

fn (p &Parser) is_punct(s string) bool {
	t := p.peek()
	return t.kind == .punct && t.text == s
}

fn (p &Parser) is_word(s string) bool {
	t := p.peek()
	return t.kind == .ident && t.text == s
}

fn (p &Parser) fail(what string) IError {
	t := p.peek()
	return error('${t.line}:${t.col}: expected ${what}, found ${t.show()}')
}

fn (mut p Parser) expect(s string) !Tok {
	if !p.is_punct(s) {
		return p.fail("'${s}'")
	}
	return p.next()
}

fn (mut p Parser) eat(s string) bool {
	if p.is_punct(s) {
		p.pos++
		return true
	}
	return false
}

fn (mut p Parser) ident(what string) !Tok {
	if p.peek().kind != .ident {
		return p.fail(what)
	}
	return p.next()
}

// value takes one value token: a number, a word or a string — the leaf table judges it.
fn (mut p Parser) value(what string) !Tok {
	k := p.peek().kind
	if k != .number && k != .ident && k != .str {
		return p.fail(what)
	}
	return p.next()
}

// item is the value tokens up to the next `,` or `;` (a value and its unit word, say).
fn (mut p Parser) item(what string) ![]Tok {
	mut out := []Tok{}
	for !p.is_punct(',') && !p.is_punct(';') && !p.is_punct('%') && !p.is_punct('}') {
		out << p.value(what)!
	}
	if p.eat('%') {
		out << Tok{.ident, '%', 0, 0}
	}
	if out.len == 0 {
		return p.fail(what)
	}
	return out
}

// items is `item (, item)* ;`
fn (mut p Parser) items(what string) ![][]Tok {
	mut out := [][]Tok{}
	out << p.item(what)!
	for p.eat(',') {
		out << p.item(what)!
	}
	p.expect(';')!
	return out
}

// skip_block skips a balanced `{ ... }` and returns how many statements were at its top level.
fn (mut p Parser) skip_block() !int {
	p.expect('{')!
	mut depth := 1
	mut count := 0
	for depth > 0 {
		t := p.next()
		if t.kind == .eof {
			return p.fail("'}'")
		}
		if t.kind == .punct {
			match t.text {
				'{' {
					if depth == 1 {
						count++
					}
					depth++
				}
				'}' {
					depth--
				}
				';' {
					if depth == 1 {
						count++
					}
				}
				else {}
			}
		}
	}
	return count
}

// skip_statement skips to the `;` ending the statement, over any braces inside it.
fn (mut p Parser) skip_statement() ! {
	for !p.is_punct(';') {
		if p.is_punct('{') {
			p.skip_block()!
			continue
		}
		if p.peek().kind == .eof || p.is_punct('}') {
			return p.fail("';'")
		}
		p.pos++
	}
	p.pos++
}

fn parse_raw(src string) !Raw {
	mut p := Parser{
		toks: lex(src)!
	}
	for p.peek().kind != .eof {
		p.top()!
	}
	return p.raw
}

fn (mut p Parser) top() ! {
	t := p.ident('a section or a header statement')!
	match t.text {
		'LIN_description_file' {
			p.expect(';')!
			if p.raw.described {
				p.raw.notes << 'header: LIN_description_file stated twice; the second is not read'
			}
			p.raw.described = true
		}
		'LIN_protocol_version', 'LIN_language_version', 'LIN_speed', 'Channel_name' {
			p.expect('=')!
			item := p.item('a value')!
			p.expect(';')!
			// a repeated statement is said and the first one kept, as for every other repeat
			if t.text in p.raw.header {
				p.raw.notes << 'header: ${t.text} stated twice; the second is not read'
			} else {
				p.raw.header[t.text] = item
			}
		}
		'LIN_sig_byte_order_little_endian' {
			p.expect(';')!
		}
		'LIN_sig_byte_order_big_endian' {
			p.expect(';')!
			p.raw.big_endian = true
		}
		'Nodes' {
			if p.raw.nodes_seen {
				p.skip_block()!
				p.raw.notes << 'Nodes: section given twice; the second is not read'
			} else {
				p.nodes()!
			}
		}
		'Signals' {
			p.signals(false)!
		}
		'Diagnostic_signals' {
			p.signals(true)!
		}
		'Frames' {
			p.frames()!
		}
		'Diagnostic_frames' {
			p.diag_frames()!
		}
		'Event_triggered_frames' {
			p.events()!
		}
		'Sporadic_frames' {
			p.sporadics()!
		}
		'Node_attributes' {
			p.node_attributes()!
		}
		'Schedule_tables' {
			p.schedules()!
		}
		'Signal_encoding_types' {
			p.encodings()!
		}
		'Signal_representation' {
			p.representations()!
		}
		'composite' {
			n := p.configurations()!
			p.raw.notes << 'Node_composition: ${plural(n, 'configuration')} parsed and not modelled'
		}
		'Signal_groups' {
			n := p.skip_block()!
			p.raw.notes << 'Signal_groups: ${plural(n, 'group')} parsed and not modelled'
		}
		else {
			if p.is_punct('{') {
				n := p.skip_block()!
				p.raw.notes << '${t.text}: section of ${plural(n, 'entry')} not read'
			} else {
				p.skip_statement()!
				p.raw.notes << '${t.text}: header statement not read'
			}
		}
	}
}

fn plural(n int, what string) string {
	if n == 1 {
		return '1 ${what}'
	}
	if what.ends_with('y') {
		return '${n} ${what[..what.len - 1]}ies'
	}
	return '${n} ${what}s'
}

// configurations counts the `configuration` entries of a Node_composition section.
fn (mut p Parser) configurations() !int {
	p.expect('{')!
	mut n := 0
	for !p.is_punct('}') {
		p.ident('configuration')!
		p.ident('a configuration name')!
		p.skip_block()!
		n++
	}
	p.expect('}')!
	return n
}

fn (mut p Parser) nodes() ! {
	p.expect('{')!
	p.raw.nodes_seen = true
	for !p.is_punct('}') {
		t := p.ident('Master or Slaves')!
		p.expect(':')!
		match t.text {
			'Master' {
				items := p.items('the master')!
				if p.raw.master != none {
					p.raw.notes << 'Nodes Master: stated twice; the second is not read'
				} else {
					p.raw.master = items
				}
			}
			'Slaves' {
				p.raw.slaves << p.ident('a slave name')!
				for p.eat(',') {
					p.raw.slaves << p.ident('a slave name')!
				}
				p.expect(';')!
			}
			else {
				p.skip_statement()!
				p.raw.notes << 'Nodes: ${t.text} not read'
			}
		}
	}
	p.expect('}')!
}

fn (mut p Parser) signals(diag bool) ! {
	p.expect('{')!
	for !p.is_punct('}') {
		name := p.ident('a signal name')!
		p.expect(':')!
		width := p.value('a signal width')!
		p.expect(',')!
		mut init := []Tok{}
		mut array := false
		if p.eat('{') {
			array = true
			init << p.value('an init byte')!
			for p.eat(',') {
				init << p.value('an init byte')!
			}
			p.expect('}')!
		} else {
			init << p.value('an init value')!
		}
		mut publisher := Tok{}
		mut subs := []Tok{}
		if !diag {
			p.expect(',')!
			publisher = p.ident('a publisher')!
			for p.eat(',') {
				subs << p.ident('a subscriber')!
			}
		}
		p.expect(';')!
		p.raw.signals << RawSignal{name, width, init, array, publisher, subs, diag}
	}
	p.expect('}')!
}

// maps is `{ signal, offset; ... }`
fn (mut p Parser) maps() ![]RawMap {
	p.expect('{')!
	mut out := []RawMap{}
	for !p.is_punct('}') {
		s := p.ident('a signal name')!
		p.expect(',')!
		o := p.value('a signal offset')!
		p.expect(';')!
		out << RawMap{s, o}
	}
	p.expect('}')!
	return out
}

fn (mut p Parser) frames() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		name := p.ident('a frame name')!
		p.expect(':')!
		id := p.value('a frame id')!
		p.expect(',')!
		publisher := p.ident('a publisher')!
		mut length := ?Tok(none)
		if p.eat(',') {
			length = p.value('a frame length')!
		}
		maps := p.maps()!
		p.raw.frames << RawFrame{name, id, publisher, length, maps, false}
	}
	p.expect('}')!
}

fn (mut p Parser) diag_frames() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		name := p.ident('a frame name')!
		p.expect(':')!
		id := p.value('a frame id')!
		maps := p.maps()!
		p.raw.frames << RawFrame{name, id, Tok{}, none, maps, true}
	}
	p.expect('}')!
}

fn (mut p Parser) events() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		name := p.ident('a frame name')!
		p.expect(':')!
		mut vals := []Tok{}
		vals << p.value('a frame id')!
		for p.eat(',') {
			vals << p.value('a frame name')!
		}
		p.expect(';')!
		if vals.len < 2 {
			return p.fail('the frames of event-triggered frame ${name.text}')
		}
		// LIN 2.1 names a collision-resolving table first; LIN 2.0 starts with the id
		if vals[0].kind != .number && vals.len >= 3 {
			p.raw.events << RawEvent{name, vals[0], vals[1], vals[2..].clone()}
		} else {
			p.raw.events << RawEvent{name, none, vals[0], vals[1..].clone()}
		}
	}
	p.expect('}')!
}

fn (mut p Parser) sporadics() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		name := p.ident('a frame name')!
		p.expect(':')!
		mut frames := []Tok{}
		frames << p.ident('a frame name')!
		for p.eat(',') {
			frames << p.ident('a frame name')!
		}
		p.expect(';')!
		p.raw.sporadics << RawSporadic{name, frames}
	}
	p.expect('}')!
}

fn (mut p Parser) node_attributes() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		mut n := RawNode{
			name: p.ident('a node name')!
		}
		p.expect('{')!
		for !p.is_punct('}') {
			a := p.ident('a node attribute')!
			if a.text == 'configurable_frames' {
				n.blocks++
				if n.blocks == 2 {
					p.raw.notes << 'Node_attributes ${n.name.text}: configurable_frames stated twice; the second is not read'
				}
				p.expect('{')!
				for !p.is_punct('}') {
					f := p.ident('a frame name')!
					mut id := ?Tok(none)
					if p.eat('=') {
						id = p.value('a message id')!
					}
					p.expect(';')!
					if n.blocks == 1 {
						n.frames << RawConfFrame{f, id}
					}
				}
				p.expect('}')!
				continue
			}
			p.expect('=')!
			n.attrs << RawAttr{a, p.items('a value of ${a.text}')!}
		}
		p.expect('}')!
		p.raw.nodes << n
	}
	p.expect('}')!
}

fn (mut p Parser) schedules() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		mut s := RawSchedule{
			name: p.ident('a schedule table name')!
		}
		p.expect('{')!
		for !p.is_punct('}') {
			cmd := p.ident('a frame or a command')!
			mut args := []Tok{}
			mut braced := false
			if p.eat('{') {
				braced = true
				for !p.is_punct('}') {
					args << p.value('a command argument')!
					if !p.eat(',') {
						break
					}
				}
				p.expect('}')!
			}
			if !p.is_word('delay') {
				return p.fail("'delay'")
			}
			p.pos++
			delay := p.item('a delay')!
			p.expect(';')!
			s.slots << RawSlot{cmd, args, braced, delay}
		}
		p.expect('}')!
		p.raw.schedules << s
	}
	p.expect('}')!
}

fn (mut p Parser) encodings() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		mut e := RawEncoding{
			name: p.ident('an encoding name')!
		}
		p.expect('{')!
		for !p.is_punct('}') {
			kind := p.ident('an encoding rule')!
			mut args := []Tok{}
			for p.eat(',') {
				args << p.value('an encoding value')!
			}
			p.expect(';')!
			e.rules << RawRule{kind, args}
		}
		p.expect('}')!
		p.raw.encodings << e
	}
	p.expect('}')!
}

fn (mut p Parser) representations() ! {
	p.expect('{')!
	for !p.is_punct('}') {
		enc := p.ident('an encoding name')!
		p.expect(':')!
		mut sigs := []Tok{}
		sigs << p.ident('a signal name')!
		for p.eat(',') {
			sigs << p.ident('a signal name')!
		}
		p.expect(';')!
		p.raw.reps << RawRep{enc, sigs}
	}
	p.expect('}')!
}

// parse_ldf reads an LDF's text. A file the parser cannot follow is an error at a line and
// column; everything else is read, with `notes` saying what was refused or not modelled.
pub fn parse_ldf(src string) !Ldf {
	raw := parse_raw(src)!
	return resolve(raw)
}

// load_ldf reads an LDF file.
pub fn load_ldf(path string) !Ldf {
	src := os.read_file(path)!
	return parse_ldf(src) or { return error('${path}:${err.msg()}') }
}
