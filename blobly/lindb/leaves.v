// leaves — every bounded field of an LDF and what it may hold, stated ONCE.
//
// The reader asks this table for every value it takes from the file (`Reader.uint`,
// `Reader.num`, `Reader.version`), so a limit is written in one place and a field read without
// a row is reported as the reader's defect. A value the table refuses is said once, as
// `<section> <name>: <field> "<text>" <why>; not read`, and the element it belongs to is not
// read — never read as 0. Relations the table cannot state (a signal past its frame, an init
// value wider than its signal, MasterReq at any id but 0x3C) are rules beside the readers.
module lindb

import math
import strconv

enum LeafKind {
	integer // unsigned, decimal or 0x hex
	number  // finite, decimal (point and exponent allowed) or 0x hex
	version // a LIN version string, see version_reading
}

// Leaf is one rule: what `field` of an element of `section` may hold. Integer bounds are `lo`
// and `hi`, inclusive, and the value a multiple of `step`; number bounds are `flo` and `fhi`,
// `flo` exclusive when `open_lo`.
struct Leaf {
	section string
	field   string
	kind    LeafKind
	lo      u64
	hi      u64
	step    u64 = 1
	hex     bool // say the bounds in hex
	flo     f64 = -math.max_f64
	fhi     f64 = math.max_f64
	open_lo bool
}

// The table. LIN facts, from LIN 2.2A §2 and §9: ids 0..59 carry signals, 0x3C/0x3D are the
// diagnostic frames and 0x3E/0x3F are reserved; a frame is 1..8 bytes; a NAD of a slave is
// 1..125 (0 is go-to-sleep, 126 functional, 127 broadcast); 0x7FFF and 0xFFFF are the product
// id wildcards, which no node is; the bit rate is 1..20 kbit/s. A scalar signal is 1..64 bits
// here (the spec says 16; a wider one is carried, since it fits a u64 and real files have them).
const ldf_leaves = [
	Leaf{
		section: 'header'
		field:   'LIN_speed'
		kind:    .number
		flo:     1
		fhi:     20
	},
	Leaf{
		section: 'header'
		field:   'LIN_protocol_version'
		kind:    .version
	},
	Leaf{
		section: 'header'
		field:   'LIN_language_version'
		kind:    .version
	},
	Leaf{
		section: 'Nodes'
		field:   'time_base'
		kind:    .number
		flo:     0
		open_lo: true
	},
	Leaf{
		section: 'Nodes'
		field:   'jitter'
		kind:    .number
		flo:     0
	},
	Leaf{
		section: 'Signals'
		field:   'width'
		kind:    .integer
		lo:      1
		hi:      64
	},
	Leaf{
		section: 'Signals'
		field:   'array width'
		kind:    .integer
		lo:      8
		hi:      64
		step:    8
	},
	Leaf{
		section: 'Signals'
		field:   'init'
		kind:    .integer
		hi:      max_u64
	},
	Leaf{
		section: 'Signals'
		field:   'init byte'
		kind:    .integer
		hi:      255
		hex:     true
	},
	Leaf{
		section: 'Diagnostic_signals'
		field:   'width'
		kind:    .integer
		lo:      1
		hi:      64
	},
	Leaf{
		section: 'Diagnostic_signals'
		field:   'init'
		kind:    .integer
		hi:      max_u64
	},
	Leaf{
		section: 'Frames'
		field:   'id'
		kind:    .integer
		hi:      59
		hex:     true
	},
	Leaf{
		section: 'Frames'
		field:   'length'
		kind:    .integer
		lo:      1
		hi:      8
	},
	Leaf{
		section: 'Frames'
		field:   'offset'
		kind:    .integer
		hi:      63
	},
	Leaf{
		section: 'Diagnostic_frames'
		field:   'id'
		kind:    .integer
		lo:      0x3C
		hi:      0x3D
		hex:     true
	},
	Leaf{
		section: 'Diagnostic_frames'
		field:   'offset'
		kind:    .integer
		hi:      63
	},
	Leaf{
		section: 'Event_triggered_frames'
		field:   'id'
		kind:    .integer
		hi:      59
		hex:     true
	},
	Leaf{
		section: 'Node_attributes'
		field:   'LIN_protocol'
		kind:    .version
	},
	Leaf{
		section: 'Node_attributes'
		field:   'configured_NAD'
		kind:    .integer
		lo:      1
		hi:      0x7D
		hex:     true
	},
	Leaf{
		section: 'Node_attributes'
		field:   'initial_NAD'
		kind:    .integer
		lo:      1
		hi:      0x7D
		hex:     true
	},
	Leaf{
		section: 'Node_attributes'
		field:   'supplier_id'
		kind:    .integer
		hi:      0x7FFE
		hex:     true
	},
	Leaf{
		section: 'Node_attributes'
		field:   'function_id'
		kind:    .integer
		hi:      0xFFFE
		hex:     true
	},
	Leaf{
		section: 'Node_attributes'
		field:   'variant'
		kind:    .integer
		hi:      0xFF
		hex:     true
	},
	Leaf{
		section: 'Node_attributes'
		field:   'P2_min'
		kind:    .number
		flo:     0
	},
	Leaf{
		section: 'Node_attributes'
		field:   'ST_min'
		kind:    .number
		flo:     0
	},
	Leaf{
		section: 'Node_attributes'
		field:   'N_As_timeout'
		kind:    .number
		flo:     0
	},
	Leaf{
		section: 'Node_attributes'
		field:   'N_Cr_timeout'
		kind:    .number
		flo:     0
	},
	Leaf{
		section: 'Node_attributes'
		field:   'message_id'
		kind:    .integer
		hi:      0xFFFF
		hex:     true
	},
	Leaf{
		section: 'Schedule_tables'
		field:   'delay'
		kind:    .number
		flo:     0
		open_lo: true
	},
	Leaf{
		section: 'Signal_encoding_types'
		field:   'logical_value'
		kind:    .integer
		hi:      max_u64
	},
	Leaf{
		section: 'Signal_encoding_types'
		field:   'min'
		kind:    .integer
		hi:      max_u64
	},
	Leaf{
		section: 'Signal_encoding_types'
		field:   'max'
		kind:    .integer
		hi:      max_u64
	},
	Leaf{
		section: 'Signal_encoding_types'
		field:   'scale'
		kind:    .number
	},
	Leaf{
		section: 'Signal_encoding_types'
		field:   'offset'
		kind:    .number
	},
]

fn leaf_rule(section string, field string) ?Leaf {
	for l in ldf_leaves {
		if l.section == section && l.field == field {
			return l
		}
	}
	return none
}

fn (l Leaf) bound(v u64) string {
	return if l.hex { '0x${v:X}' } else { '${v}' }
}

// leaf_reason is why `text` is not a value the rule accepts, or none when it is.
fn leaf_reason(l Leaf, text string) ?string {
	match l.kind {
		.integer {
			v := parse_uint(text) or { return 'is not an unsigned integer' }
			if v < l.lo || v > l.hi {
				return 'is out of range ${l.bound(l.lo)}..${l.bound(l.hi)}'
			}
			if v % l.step != 0 {
				return 'is not a multiple of ${l.step}'
			}
		}
		.number {
			v := parse_number(text) or { return 'is not a number' }
			if l.open_lo && v <= l.flo {
				return 'must be greater than ${fmt_num(l.flo)}'
			}
			if v < l.flo {
				return 'must be at least ${fmt_num(l.flo)}'
			}
			if v > l.fhi {
				return 'must be at most ${fmt_num(l.fhi)}'
			}
		}
		.version {
			version_reading(text) or {
				return 'is not a LIN version (1.x, 2.x, ISO17987:yyyy or J2602_x_y.z)'
			}
		}
	}
	return none
}

// parse_uint reads an unsigned decimal or 0x-hex integer, all of it, or nothing.
fn parse_uint(s string) ?u64 {
	if s.len > 2 && (s.starts_with('0x') || s.starts_with('0X')) {
		h := s[2..]
		if !h.bytes().all(it.is_hex_digit()) {
			return none
		}
		return strconv.parse_uint(h, 16, 64) or { return none }
	}
	if s == '' || !s.bytes().all(it.is_digit()) {
		return none
	}
	return strconv.parse_uint(s, 10, 64) or { return none }
}

// parse_number reads a finite number: an optional minus, digits, an optional fraction and
// exponent — or a 0x-hex integer.
fn parse_number(s string) ?f64 {
	if v := parse_uint(s) {
		return f64(v)
	}
	mut i := 0
	if i < s.len && s[i] == `-` {
		i++
	}
	start := i
	for i < s.len && s[i].is_digit() {
		i++
	}
	if i == start {
		return none
	}
	if i < s.len && s[i] == `.` {
		i++
		fs := i
		for i < s.len && s[i].is_digit() {
			i++
		}
		if i == fs {
			return none
		}
	}
	if i < s.len && (s[i] == `e` || s[i] == `E`) {
		i++
		if i < s.len && (s[i] == `+` || s[i] == `-`) {
			i++
		}
		es := i
		for i < s.len && s[i].is_digit() {
			i++
		}
		if i == es {
			return none
		}
	}
	if i != s.len {
		return none
	}
	v := strconv.atof64(s) or { return none }
	if math.is_inf(v, 0) || math.is_nan(v) {
		return none
	}
	return v
}

// version_reading is the LIN major version a version string is read as, and a note when the
// string is not a LIN one proper: "1.3", "2.2" (major 1 or 2), "ISO17987:2015" (read as LIN
// 2.2), "J2602_1_1.0" (SAE J2602, read as LIN 2.0).
fn version_reading(s string) ?(int, string) {
	if s.starts_with('ISO17987:') {
		rev := s['ISO17987:'.len..]
		if rev != '' && rev.bytes().all(it.is_digit()) {
			return 2, 'is ISO 17987; read as LIN 2.2'
		}
		return none
	}
	if s.starts_with('J2602_') {
		parts := s['J2602_'.len..].split('_')
		if parts.len == 2 && parts[0] != '' && parts[0].bytes().all(it.is_digit())
			&& is_dotted(parts[1]) {
			return 2, 'is SAE J2602; read as LIN 2.0'
		}
		return none
	}
	if !is_dotted(s) {
		return none
	}
	major := s.all_before('.').int()
	if major != 1 && major != 2 {
		return none
	}
	return major, ''
}

// is_dotted: digits, one point, digits
fn is_dotted(s string) bool {
	if s.count('.') != 1 {
		return false
	}
	a := s.all_before('.')
	b := s.all_after('.')
	return a != '' && b != '' && a.bytes().all(it.is_digit()) && b.bytes().all(it.is_digit())
}

// fmt_num is a number as the dump and the notes print it: an integer without a point, else at
// most six decimals with the trailing zeros dropped.
pub fn fmt_num(x f64) string {
	if x == math.trunc(x) && math.abs(x) < 1e15 {
		return '${i64(x)}'
	}
	mut s := '${x:.6f}'
	s = s.trim_right('0')
	if s.ends_with('.') {
		s = s[..s.len - 1]
	}
	return s
}
