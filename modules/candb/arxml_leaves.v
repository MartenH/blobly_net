// arxml_leaves — the poor man's schema behind the ARXML reader (#280).
//
// Every malformed-input finding on #273 after round 40 was one LEAF element read with a lenient
// parser: an integer out of its range or overflowing, a number that was not one, an enumeration
// with a value nobody defined, an element present and empty. Each was fixed where it was read,
// and the next round found the next site. This file is the class fix: ONE table of the leaf
// elements the reader depends on, with what each may hold, checked ONCE over the whole tree
// before extraction starts — every element the table names, whether or not a frame leads to it.
//
// The table is also the ONE source of bounds for the extractor: `int_in`/`int_of`/`num_of`
// look their field up here rather than carrying limits at the call site, so a bound stated
// twice cannot drift, and a field the extractor reads without a row is reported as such.
//
// It is hand-written against the AUTOSAR 4.x meta-model, the same coupling the extractor has,
// made explicit: an element the table does not name passes untouched (a newer schema adds
// elements freely); a VALUE the table does not know is reported by element and value and the
// signal or frame is not read, which is a one-row fix rather than a silent default. Bounds that
// are CAN facts (a 29-bit id, a 64-byte frame) do not move with a schema release; the ones that
// are this model's (a 64-bit scalar) are named as such. The declared schema is recorded in the
// report so a drift is a line in the export, not a puzzle.
module candb

import encoding.xml

enum LeafKind {
	integer
	number
	choice
}

// Leaf is one rule: what the element `tag` may hold when its parent is `at` ('*' for any).
struct Leaf {
	at      string
	tag     string
	kind    LeafKind
	lo      i64
	hi      i64
	allowed []string
}

const leaf_any = '*'

// The table. A row per leaf the extractor reads; the parent narrows a tag that means different
// things in different places (LENGTH of a signal is bits and may be wide, LENGTH of a PDU is
// bytes and at most a frame). Bounds are inclusive.
const arxml_leaves = [
	// widths, positions, counts — integers
	Leaf{'I-SIGNAL', 'LENGTH', .integer, 1, 1 << 20, []}, // bits; the 64-bit scalar limit is the extractor's, said there
	Leaf{'I-SIGNAL-I-PDU', 'LENGTH', .integer, 0, 64, []}, // bytes, at most a CAN-FD frame
	Leaf{'SECURED-I-PDU', 'LENGTH', .integer, 0, 64, []},
	Leaf{'CAN-FRAME', 'FRAME-LENGTH', .integer, 0, 64, []},
	Leaf{'CAN-FRAME-TRIGGERING', 'IDENTIFIER', .integer, 0, 0x1FFFFFFF, []}, // 29 bits; the 11-bit STANDARD bound is relational, in frame_admission
	Leaf{'PDU-TO-FRAME-MAPPING', 'START-POSITION', .integer, 0, 512, []},
	Leaf{'I-SIGNAL-TO-I-PDU-MAPPING', 'START-POSITION', .integer, 0, 512, []},
	Leaf{'I-SIGNAL-TO-I-PDU-MAPPING', 'UPDATE-BIT-POSITION', .integer, 0, 512, []},
	Leaf{leaf_any, 'CRC-OFFSET', .integer, 0, 512, []},
	Leaf{leaf_any, 'COUNTER-OFFSET', .integer, 0, 512, []},
	Leaf{'END-TO-END-PROFILE', 'OFFSET', .integer, 0, 512, []},
	Leaf{leaf_any, 'DATA-OFFSET', .integer, 0, 512, []},
	Leaf{leaf_any, 'DATA-LENGTH', .integer, 1, 512, []}, // a zero-length protected window disabled the in-window check (#280)
	Leaf{leaf_any, 'DATA-ID', .integer, 0, 0xFFFFFFFF, []},
	Leaf{'SECURE-COMMUNICATION-PROPS', 'FRESHNESS-VALUE-TX-LENGTH', .integer, 0, 512, []},
	Leaf{'SECURE-COMMUNICATION-PROPS', 'AUTH-INFO-TX-LENGTH', .integer, 0, 512, []},
	Leaf{'SECURE-COMMUNICATION-PROPS', 'FRESHNESS-VALUE-LENGTH', .integer, 0, 512, []},
	Leaf{leaf_any, 'BAUDRATE', .integer, 0, 100000000, []},
	Leaf{leaf_any, 'CAN-FD-BAUDRATE', .integer, 0, 100000000, []},
	Leaf{leaf_any, 'NUMBER-OF-REPETITIONS', .integer, 0, 1000, []},
	Leaf{'I-SIGNAL-I-PDU', 'UNUSED-BIT-PATTERN', .integer, 0, max_i64, []},
	// scalings, bounds, times, initial values — numbers (finite; hex allowed, one sign)
	Leaf{'COMPU-NUMERATOR', 'V', .number, 0, 0, []},
	Leaf{'COMPU-DENOMINATOR', 'V', .number, 0, 0, []},
	Leaf{'COMPU-CONST', 'V', .number, 0, 0, []},
	Leaf{leaf_any, 'LOWER-LIMIT', .number, 0, 0, []},
	Leaf{leaf_any, 'UPPER-LIMIT', .number, 0, 0, []},
	Leaf{'TIME-PERIOD', 'VALUE', .number, 0, 0, []},
	Leaf{'TIME-OFFSET', 'VALUE', .number, 0, 0, []},
	Leaf{'REPETITION-PERIOD', 'VALUE', .number, 0, 0, []},
	Leaf{leaf_any, 'MINIMUM-DELAY', .number, 0, 0, []},
	Leaf{'NUMERICAL-VALUE-SPECIFICATION', 'VALUE', .number, 0, 0, []},
	// enumerations — one of the listed spellings, nothing else, never empty
	Leaf{leaf_any, 'PACKING-BYTE-ORDER', .choice, 0, 0, [
		'MOST-SIGNIFICANT-BYTE-FIRST',
		'MOST-SIGNIFICANT-BYTE-LAST',
		'OPAQUE',
	]},
	Leaf{leaf_any, 'COMMUNICATION-DIRECTION', .choice, 0, 0, [
		'IN',
		'OUT',
	]},
	Leaf{leaf_any, 'CAN-ADDRESSING-MODE', .choice, 0, 0, [
		'STANDARD',
		'EXTENDED',
	]},
	Leaf{leaf_any, 'CAN-FRAME-TX-BEHAVIOR', .choice, 0, 0, [
		'CAN-20',
		'CAN-FD',
	]},
	Leaf{leaf_any, 'CAN-FRAME-RX-BEHAVIOR', .choice, 0, 0, [
		'CAN-20',
		'CAN-FD',
	]},
	Leaf{leaf_any, 'DATA-ID-MODE', .choice, 0, 0, [
		'ALL-16-BIT',
		'ALTERNATING-8-BIT',
		'LOWER-12-BIT',
		'LOWER-8-BIT',
	]},
]

// leaf_rule finds the row for `tag` under `parent`: the parent-specific row first, then the
// any-parent one. None means the reader has no opinion about that element.
fn leaf_rule(parent string, tag string) ?Leaf {
	for l in arxml_leaves {
		if l.tag == tag && l.at == parent {
			return l
		}
	}
	for l in arxml_leaves {
		if l.tag == tag && l.at == leaf_any {
			return l
		}
	}
	return none
}

// leaf_reason is why `text` is not a value the rule accepts, or none when it is. One wording per
// kind, so the same defect reads the same wherever it sits.
fn leaf_reason(l Leaf, text string) ?string {
	s := text.trim_space()
	match l.kind {
		.integer {
			int_text(l.tag, s, l.lo, l.hi) or { return err.msg() }
		}
		.number {
			if num_text(s) == none {
				return '${l.tag} "${s}" is not a number'
			}
		}
		.choice {
			if s !in l.allowed {
				return '${l.tag} "${s}" is not one of ${l.allowed.join(', ')}'
			}
		}
	}
	return none
}

// leaf_int reads `text` by an integer rule, or says why not — `int_text` with the bounds looked
// up rather than passed, for the sites that read a field without a node (a list of DATA-IDs).
fn leaf_int(parent string, tag string, text string) !i64 {
	l := leaf_rule(parent, tag) or { return error('reader has no rule for ${parent}/${tag}') }
	if l.kind != .integer {
		return error('reader has no integer rule for ${parent}/${tag}')
	}
	return int_text(tag, text, l.lo, l.hi)
}

// check_leaves walks the whole document once and files a note for every leaf the table names
// whose text is not a value it accepts, at the path of the nearest identifiable ancestor. The
// extractor's own readers skip such a field silently afterwards: the note is here, once.
fn (mut r ArxmlReader) check_leaves(n xml.XMLNode, parent_tag string, parent_path string) {
	mut path := parent_path
	if sn := child(n, 'SHORT-NAME') {
		path = '${parent_path}/${el_text(sn)}'
	}
	tag := lname(n)
	if l := leaf_rule(parent_tag, tag) {
		if !n.children.any(it is xml.XMLNode) {
			text := el_text(n)
			// an INFINITE or OPEN interval bound may carry no number: the attribute is the value
			infinite := (n.attributes['INTERVAL-TYPE'] or { '' }) == 'INFINITE'
			if !(infinite && text == '') {
				if why := leaf_reason(l, text) {
					r.report.notes << '${path}: ${parent_tag}/${why}; not read'
				}
			}
		}
	}
	for c in n.children {
		if c is xml.XMLNode {
			r.check_leaves(c, tag, path)
		}
	}
}

// note_schema records which AUTOSAR schema the file declares (`xsi:schemaLocation`'s XSD name,
// `AUTOSAR_4-2-2` or the `AUTOSAR_00046` of R19-11 and later) and says when it is not one of the
// 4.x family this table was written against. The namespace guard in parse_arxml already refuses
// 3.x; this is finer, and it puts the version into the provenance.
fn (mut r ArxmlReader) note_schema(root xml.XMLNode) {
	mut loc := ''
	for k, v in root.attributes {
		if k.all_after_last(':') == 'schemaLocation' {
			loc = v
		}
	}
	if loc.trim_space() == '' {
		r.report.schema = 'unstated'
		return
	}
	xsd := loc.trim_space().fields().last().all_after_last('/')
	name := if xsd.ends_with('.xsd') { xsd[..xsd.len - 4] } else { xsd }
	r.report.schema = name
	if !schema_is_4x(name) {
		r.report.notes << 'declares schema ${name}, which is not one of the AUTOSAR 4.x releases this reader was written against (AUTOSAR_4-x-y, AUTOSAR_000nn); read as 4.x'
	}
}

// schema_is_4x: AUTOSAR_4-<d>-<d>, or the release-numbered AUTOSAR_000<dd> of R19-11 onwards.
fn schema_is_4x(name string) bool {
	if name.starts_with('AUTOSAR_4-') {
		rest := name['AUTOSAR_4-'.len..]
		return rest.len == 3 && rest[0].is_digit() && rest[1] == `-` && rest[2].is_digit()
	}
	if name.starts_with('AUTOSAR_000') {
		rest := name['AUTOSAR_000'.len..]
		return rest.len == 2 && rest.bytes().all(it.is_digit())
	}
	return false
}
