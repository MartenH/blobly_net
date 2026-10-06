module sysview

import toml
import uds

// ecudesc.v — a blobly_emb node's DIAGNOSTIC description, read from its ecu.toml: what a tester
// needs to show names instead of codes. Each `[[fault]]` names a DTC, each `[[did]]` is a data
// identifier with a size and a layout where the file determines one, each `[[param]]` is a coded
// value with its fields. blobly_emb's ecucheck validates the file; this reads what it finds and
// says (`errs`) what it could not use, so a tester never refuses a node for one odd entry.
// (The format has no RoutineControl: ISO 0x31 routines are out of blobly_emb's scope.)

// Field is one typed field of a signal or a parameter: `u8`/`u16`/`u32`, `i8`/`i16`/`i32`, `bool`.
pub struct Field {
pub:
	name string
	typ  string
}

// width is the field's size in a DID's value, or 0 for a type a DID does not carry.
pub fn (f Field) width() int {
	return match f.typ {
		'bool', 'u8', 'i8' { 1 }
		'u16', 'i16' { 2 }
		'u32', 'i32' { 4 }
		'u64', 'i64' { 8 }
		else { 0 }
	}
}

// FaultDesc is one `[[fault]]`: a DTC and what tests it.
pub struct FaultDesc {
pub:
	name    string
	dtc     u32
	source  string // `Fb.handler` that tests it, or `signal (on)` for a signal-status fault
	freeze  []u16  // the snapshot's DIDs (0x19 04)
	confirm int
	aging   int
}

// DidKind is where a `[[did]]`'s value comes from.
pub enum DidKind {
	ascii        // a fixed text
	bytes        // fixed bytes
	signal       // a live signal's value
	param        // a coded parameter
	param_status // one status byte per parameter
	unknown      // none of the above: its size is not known here
}

// DidDesc is one `[[did]]`.
pub struct DidDesc {
pub:
	id   u16
	kind DidKind
	name string // the signal's or parameter's name, the ISO name of a standard identifier, or ''
	// the value's size in bytes; -1 when the file does not determine it
	size int = -1
	// the value's layout, big-endian, back to back (a signal's value field, a parameter's fields,
	// one byte per parameter for a status DID); empty for text and fixed bytes
	fields   []Field
	text     string // ascii: the text
	read     string // the read gate (`extended, level 1`), '' = open
	write    string // the write gate; '' = not writable
	// the same gates as data: what a tester has to establish before the request
	read_gate  Gate
	write_gate Gate
	// a parameter's per-field range (`range = { deg = { min, max } }`), by field name
	ranges map[string]Range
}

// Gate is a `read`/`write` table: the sessions the service is served in (none listed = any) and
// the security level it needs (the 0x27 requestSeed sub-function; 0 = none). `declared` false is
// no gate at all — for `write`, not writable.
pub struct Gate {
pub:
	declared bool
	sessions []string // `default`, `programming`, `extended`, as the ecu.toml writes them
	level    int
}

// Range is an inclusive range a field's value must lie in.
pub struct Range {
pub:
	min i64
	max i64
}

// session_id is a gate's session name as a DiagnosticSessionControl (0x10) sub-function.
pub fn session_id(name string) ?u8 {
	return match name {
		'default' { u8(0x01) }
		'programming' { u8(0x02) }
		'extended' { u8(0x03) }
		'safety' { u8(0x04) }
		else { none }
	}
}

// ParamDesc is one `[[param]]`.
pub struct ParamDesc {
pub:
	name     string
	fields   []Field
	apply    string
	defaults map[string]i64   // `default = { field = value }`: the value uncoded
	ranges   map[string]Range // `range = { field = { min, max } }`
}

// EcuDesc is a node's diagnostic description.
pub struct EcuDesc {
pub mut:
	faults []FaultDesc
	dids   []DidDesc
	params []ParamDesc
	// the node's own ISO-TP ids ([isotp] rx_id / tx_id): its request and response
	isotp_req u32
	isotp_rsp u32
	// whether the node runs a diagnostic server at all ([uds], [isotp] or [doip] declared)
	server bool
	// `[uds] security_key`: "reference" is blobly_net's public bench key (uds.security_key), the
	// one key a tester here can compute; '' = the OEM's, which it cannot
	security_key string
	errs   []string
}

// fault is the `[[fault]]` declaring `dtc`.
pub fn (d &EcuDesc) fault(dtc u32) ?FaultDesc {
	for f in d.faults {
		if f.dtc == dtc {
			return f
		}
	}
	return none
}

// did is the `[[did]]` with `id`.
pub fn (d &EcuDesc) did(id u16) ?DidDesc {
	for x in d.dids {
		if x.id == id {
			return x
		}
	}
	return none
}

// iso_dids: the standard identification DIDs (uds.standard_dids) the description does not declare
// itself, each as ISO names it — what a tester lists for a node beside its own DIDs, and all it
// lists without a description.
pub fn (d &EcuDesc) iso_dids() []DidDesc {
	mut out := []DidDesc{}
	for id in uds.standard_dids() {
		if _ := d.did(id) {
			continue
		}
		out << DidDesc{
			id:   id
			name: uds.standard_did_name(id)
		}
	}
	return out
}

// param_did is the DID a parameter is coded through, if the description declares one.
pub fn (d &EcuDesc) param_did(name string) ?DidDesc {
	for x in d.dids {
		if x.kind == .param && x.name == name {
			return x
		}
	}
	return none
}

// param_status_did is the DID holding every parameter's status byte, if the description declares one.
pub fn (d &EcuDesc) param_status_did() ?DidDesc {
	for x in d.dids {
		if x.kind == .param_status {
			return x
		}
	}
	return none
}

// did_sizes: every DID whose size the description determines — what a snapshot (0x19 04) decoder
// needs, since a snapshot record carries no lengths.
pub fn (d &EcuDesc) did_sizes() map[u16]int {
	mut out := map[u16]int{}
	for x in d.dids {
		if x.size >= 0 {
			out[x.id] = x.size
		}
	}
	return out
}

// did_name is what to call `id`: the description's name, else the ISO one, else ''.
pub fn (d &EcuDesc) did_name(id u16) string {
	if x := d.did(id) {
		if x.name != '' {
			return x.name
		}
	}
	return uds.standard_did_name(id)
}

// decode_did renders a DID's value through its description: text for an ascii DID, each field by
// name for a laid-out one (`deg=100`), a parameter status by word. '' when the description cannot
// read it — no entry, no layout, or a length other than the declared one — and the caller shows
// the bytes.
pub fn (d &EcuDesc) decode_did(id u16, data []u8) string {
	x := d.did(id) or { return '' }
	if x.size >= 0 && data.len != x.size {
		return ''
	}
	match x.kind {
		.ascii {
			return '"${data.bytestr()}"'
		}
		.param_status {
			mut parts := []string{}
			for i, f in x.fields {
				word := match data[i] {
					0 { 'default' }
					1 { 'coded' }
					2 { 'reverted' }
					else { '0x${data[i]:02X}' }
				}
				parts << '${f.name} ${word}'
			}
			return parts.join(', ')
		}
		.signal, .param {
			if x.fields.len == 0 {
				return ''
			}
			mut parts := []string{}
			mut at := 0
			for f in x.fields {
				w := f.width()
				v := field_value(f, data[at..at + w])
				// a one-field value needs no label beyond the DID's own name
				parts << if x.fields.len == 1 { v } else { '${f.name}=${v}' }
				at += w
			}
			return parts.join(' ')
		}
		else {
			return ''
		}
	}
}

// field_value reads one big-endian field, sign-extending a signed one.
fn field_value(f Field, b []u8) string {
	mut v := u64(0)
	for x in b {
		v = v << 8 | u64(x)
	}
	if f.typ == 'bool' {
		return if v != 0 { 'true' } else { 'false' }
	}
	if f.typ.starts_with('i') && b.len > 0 && b.len < 8 && v & (u64(1) << (8 * b.len - 1)) != 0 {
		return '${i64(v) - i64(u64(1) << (8 * b.len))}'
	}
	if f.typ.starts_with('i') {
		return '${i64(v)}'
	}
	return '${v}'
}

// fields_of reads a `fields = { name = "type", ... }` table in the file's order.
fn fields_of(m map[string]toml.Any) []Field {
	mut out := []Field{}
	if fv := m['fields'] {
		for k, t in fv.as_map() {
			out << Field{k, t.string()}
		}
	}
	return out
}

// access_words renders a `{ session = [...], security = N }` gate.
fn access_words(m map[string]toml.Any, key string) string {
	v := m[key] or { return '' }
	am := v.as_map()
	mut parts := []string{}
	if s := am['session'] {
		parts << s.array().map(it.string()).join('/')
	}
	lvl := tint(am, 'security')
	if lvl != 0 {
		parts << 'level ${lvl}'
	}
	return if parts.len == 0 { 'open' } else { parts.join(', ') }
}

// gate_of reads a `{ session = [...], security = N }` gate.
fn gate_of(m map[string]toml.Any, key string) Gate {
	v := m[key] or { return Gate{} }
	am := v.as_map()
	return Gate{
		declared: true
		sessions: if s := am['session'] { s.array().map(it.string()) } else { []string{} }
		level:    int(tint(am, 'security'))
	}
}

// field_ints reads a `{ field = integer }` table.
fn field_ints(m map[string]toml.Any, key string) map[string]i64 {
	mut out := map[string]i64{}
	if v := m[key] {
		for k, x in v.as_map() {
			if x is i64 {
				out[k] = x
			}
		}
	}
	return out
}

// field_ranges reads a `{ field = { min, max } }` table; a range missing either end is not one.
fn field_ranges(m map[string]toml.Any, key string) map[string]Range {
	mut out := map[string]Range{}
	if v := m[key] {
		for k, x in v.as_map() {
			rm := x.as_map()
			lo := rm['min'] or { continue }
			hi := rm['max'] or { continue }
			if lo is i64 && hi is i64 {
				out[k] = Range{lo, hi}
			}
		}
	}
	return out
}

// parse_ecu_desc reads the diagnostic part of an ecu.toml document. `signals` are the cross-node
// signals' fields (system.toml's `[[signal]]`s), which a live DID may read beside the node's own.
pub fn parse_ecu_desc(doc toml.Doc, signals map[string][]Field) EcuDesc {
	mut d := EcuDesc{}
	// the node's own signals, for a live DID that reads one
	mut sigs := signals.clone()
	for s in tarr(doc, 'signal') {
		sm := s.as_map()
		sigs[tstr(sm, 'name')] = fields_of(sm)
	}
	d.server = ['uds', 'isotp', 'doip'].any(doc.value_opt(it) or { toml.Any(toml.Null{}) } !is toml.Null)
	if uv := doc.value_opt('uds') {
		d.security_key = tstr(uv.as_map(), 'security_key')
	}
	if iv := doc.value_opt('isotp') {
		im := iv.as_map()
		d.isotp_req = u32(tint(im, 'rx_id'))
		d.isotp_rsp = u32(tint(im, 'tx_id'))
	}
	for p in tarr(doc, 'param') {
		pm := p.as_map()
		d.params << ParamDesc{
			name:   tstr(pm, 'name')
			fields: fields_of(pm)
			apply:    if tstr(pm, 'apply') == '' { 'next_dispatch' } else { tstr(pm, 'apply') }
			defaults: field_ints(pm, 'default')
			ranges:   field_ranges(pm, 'range')
		}
	}
	for f in tarr(doc, 'fault') {
		fm := f.as_map()
		name := tstr(fm, 'name')
		mut source := tstr(fm, 'from')
		if sig := fm['signal'] {
			source = '${sig.string()} (${tstr(fm, 'on')})'
		}
		mut freeze := []u16{}
		if fz := fm['freeze'] {
			for x in fz.array() {
				freeze << u16(x.i64())
			}
		}
		dtc := tint(fm, 'dtc')
		if dtc <= 0 || dtc > 0xFFFFFF {
			d.errs << 'fault ${name}: dtc ${dtc} is not a 3-byte DTC; not read'
			continue
		}
		d.faults << FaultDesc{
			name:    name
			dtc:     u32(dtc)
			source:  source
			freeze:  freeze
			confirm: int(if c := fm['confirm'] { c.i64() } else { 1 })
			aging:   int(tint(fm, 'aging'))
		}
	}
	for x in tarr(doc, 'did') {
		xm := x.as_map()
		id := tint(xm, 'id')
		if id < 0 || id > 0xFFFF {
			d.errs << 'did ${id}: not a 16-bit identifier; not read'
			continue
		}
		read := access_words(xm, 'read')
		mut write := access_words(xm, 'write')
		mut write_gate := gate_of(xm, 'write')
		if write == '' {
			if w := xm['writable'] {
				if w.bool() {
					write = 'open'
					write_gate = Gate{
						declared: true
					}
				}
			}
		}
		mut ranges := map[string]Range{}
		mut kind := DidKind.unknown
		mut name := ''
		mut size := -1
		mut fields := []Field{}
		mut text := ''
		if a := xm['ascii'] {
			kind = .ascii
			text = a.string()
			size = text.len
		} else if b := xm['bytes'] {
			kind = .bytes
			size = b.string().fields().len
		} else if s := xm['signal'] {
			kind = .signal
			name = s.string()
			sf := sigs[name] or { []Field{} }
			// a live DID carries the signal's one value field (blobly_emb's loom2v refuses others)
			if sf.len == 1 && sf[0].width() > 0 {
				fields = sf.clone()
				size = sf[0].width()
			} else {
				d.errs << 'did 0x${id:04X}: signal ${name} has no single integer field here; its size is not known'
			}
		} else if p := xm['param'] {
			kind = .param
			name = p.string()
			if pd := d.params.filter(it.name == name)[0] {
				fields = pd.fields.clone()
				ranges = pd.ranges.clone()
				mut n := 0
				for f in fields {
					n += f.width()
				}
				if fields.len > 0 && fields.all(it.width() > 0) {
					size = n
				} else {
					fields = []
				}
			} else {
				d.errs << 'did 0x${id:04X}: no [[param]] ${name}'
			}
		} else if ps := xm['param_status'] {
			if ps.bool() {
				kind = .param_status
				name = 'parameter status'
				fields = d.params.map(Field{it.name, 'u8'})
				size = fields.len
			}
		}
		if name == '' {
			name = uds.standard_did_name(u16(id))
		}
		d.dids << DidDesc{
			id:     u16(id)
			kind:   kind
			name:   name
			size:   size
			fields: fields
			text:   text
			read:       read
			write:      write
			read_gate:  gate_of(xm, 'read')
			write_gate: write_gate
			ranges:     ranges
		}
	}
	return d
}

// load_ecu_desc reads one ecu.toml file's diagnostic description.
pub fn load_ecu_desc(path string, signals map[string][]Field) !EcuDesc {
	doc := toml.parse_file(path)!
	return parse_ecu_desc(doc, signals)
}
