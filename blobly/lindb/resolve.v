// resolve — the raw form checked against the leaf table and its references, into the model.
// Every refusal is one note; a reference to an element that was refused says so rather than
// calling it undefined, so one bad value reads as one defect.
module lindb

import math

// the node configuration commands a schedule table may hold (LIN 2.2A §9.2.5, LIN 2.0's
// AssignFrameId and UnassignFrameId included)
const config_commands = ['AssignNAD', 'ConditionalChangeNAD', 'DataDump', 'SaveConfiguration',
	'AssignFrameIdRange', 'FreeFormat', 'AssignFrameId', 'UnassignFrameId']

struct Reader {
mut:
	l              Ldf
	refused        map[string]bool // 'signal X', 'frame X', 'encoding X': present in the file, not read
	commands       int
	master_refused bool // the Nodes Master entry was present and not read
}

fn (mut r Reader) note(section string, name string, what string) {
	at := if name == '' { section } else { '${section} ${name}' }
	r.l.notes << '${at}: ${what}'
}

// check is the leaf rule for (section, field) asked of `t`: true when it accepts the value,
// else the refusal is noted. A field with no row is the reader's defect and says so.
fn (mut r Reader) check(section string, name string, field string, t Tok) bool {
	rule := leaf_rule(section, field) or {
		r.note(section, name, 'reader has no rule for ${field}')
		return false
	}
	if why := leaf_reason(rule, t.text) {
		r.note(section, name, '${field} "${t.text}" ${why}; not read')
		return false
	}
	return true
}

fn (mut r Reader) uint(section string, name string, field string, t Tok) ?u64 {
	if !r.check(section, name, field, t) {
		return none
	}
	return parse_uint(t.text)
}

fn (mut r Reader) num(section string, name string, field string, t Tok) ?f64 {
	if !r.check(section, name, field, t) {
		return none
	}
	return parse_number(t.text)
}

// ms is a `<number> ms` item.
fn (mut r Reader) ms(section string, name string, field string, item []Tok) ?f64 {
	if item.len != 2 || item[1].text != 'ms' {
		r.note(section, name, '${field} "${item.map(it.text).join(' ')}" is not a time in ms; not read')
		return none
	}
	return r.num(section, name, field, item[0])
}

// one is the single token an item must be.
fn (mut r Reader) one(section string, name string, field string, item []Tok) ?Tok {
	if item.len != 1 {
		r.note(section, name, '${field} "${item.map(it.text).join(' ')}" is not one value; not read')
		return none
	}
	return item[0]
}

// single is the one value token of a `name = value;` attribute.
fn (mut r Reader) single(section string, name string, a RawAttr) ?Tok {
	if a.values.len != 1 {
		r.note(section, name, '${a.name.text} takes one value; not read')
		return none
	}
	return r.one(section, name, a.name.text, a.values[0])
}

// missing is how a reference to `name` of `kind` that resolves to nothing reads.
fn (r &Reader) missing(kind string, defined_in string, name string) string {
	return if r.refused['${kind} ${name}'] {
		'${kind} ${name}, which was not read'
	} else {
		'${kind} ${name}, which ${defined_in} does not define'
	}
}

// is_node: the name is the master or a slave of Nodes. Where the Master entry was refused, a
// name that is no slave may be it, and that refusal is already the note for it.
fn (r &Reader) is_node(name string) bool {
	return name == r.l.master.name || name in r.l.slaves || r.master_refused
}

fn resolve(raw Raw) Ldf {
	mut r := Reader{}
	r.l.notes << raw.notes
	r.header(raw)
	r.nodes(raw)
	r.signals(raw)
	r.encodings(raw)
	r.representations(raw)
	r.frames(raw)
	r.events(raw)
	r.node_attributes(raw)
	r.schedules(raw)
	r.event_tables()
	return r.l
}

fn (mut r Reader) header(raw Raw) {
	if !raw.described {
		r.note('header', '', 'LIN_description_file is missing')
	}
	for key in ['LIN_protocol_version', 'LIN_language_version'] {
		item := raw.header[key] or {
			r.note('header', '', '${key} is missing')
			continue
		}
		t := r.one('header', '', key, item) or { continue }
		if !r.check('header', '', key, t) {
			continue
		}
		_, said := version_reading(t.text) or { 0, '' }
		if said != '' {
			r.note('header', '', '${key} "${t.text}" ${said}')
		}
		if key == 'LIN_protocol_version' {
			r.l.protocol_version = t.text
		} else {
			r.l.language_version = t.text
		}
	}
	if item := raw.header['LIN_speed'] {
		if item.len != 2 || item[1].text != 'kbps' {
			r.note('header', '', 'LIN_speed "${item.map(it.text).join(' ')}" is not a rate in kbps; not read')
		} else if v := r.num('header', '', 'LIN_speed', item[0]) {
			r.l.speed_bps = int(math.round(v * 1000))
		}
	} else {
		r.note('header', '', 'LIN_speed is missing')
	}
	if item := raw.header['Channel_name'] {
		if t := r.one('header', '', 'Channel_name', item) {
			r.l.channel = t.text
		}
	}
}

fn (mut r Reader) nodes(raw Raw) {
	if !raw.nodes_seen {
		r.note('Nodes', '', 'section is missing')
		return
	}
	if items := raw.master {
		if name := r.one('Nodes', 'Master', 'name', items[0]) {
			r.l.master.name = name.text
			if items.len < 3 {
				r.note('Nodes', 'Master', 'needs a name, a time base and a jitter; the timings are not read')
			} else {
				r.l.master.time_base_ms = r.ms('Nodes', 'Master', 'time_base', items[1])
				r.l.master.jitter_ms = r.ms('Nodes', 'Master', 'jitter', items[2])
			}
		} else {
			r.master_refused = true
		}
		if items.len > 3 {
			r.note('Nodes', 'Master', '${items.len - 3} further values (J2602 header length, response tolerance) not read')
		}
	} else {
		r.note('Nodes', '', 'Master is missing')
	}
	for s in raw.slaves {
		if s.text in r.l.slaves || s.text == r.l.master.name {
			r.note('Nodes', 'Slaves', '${s.text} is listed twice; the second is not read')
			continue
		}
		r.l.slaves << s.text
	}
}

fn (mut r Reader) signals(raw Raw) {
	for s in raw.signals {
		section := if s.diag { 'Diagnostic_signals' } else { 'Signals' }
		name := s.name.text
		if r.l.signals.any(it.name == name) {
			r.note(section, name, 'defined twice; the second is not read')
			continue
		}
		mut sig := Signal{
			name:       name
			is_array:   s.array
			publisher:  s.publisher.text
			diagnostic: s.diag
		}
		if s.array {
			if s.diag {
				r.note(section, name, 'a diagnostic signal is a scalar, not a byte array; not read')
				r.refused['signal ${name}'] = true
				continue
			}
			w := r.uint(section, name, 'array width', s.width) or {
				r.refused['signal ${name}'] = true
				continue
			}
			sig.width = int(w)
			if s.init.len != sig.width / 8 {
				r.note(section, name, 'init has ${s.init.len} bytes, a ${sig.width}-bit array ${sig.width / 8}; not read')
				r.refused['signal ${name}'] = true
				continue
			}
			mut ok := true
			for t in s.init {
				b := r.uint(section, name, 'init byte', t) or {
					ok = false
					break
				}
				sig.init_bytes << u8(b)
			}
			if !ok {
				r.refused['signal ${name}'] = true
				continue
			}
		} else {
			w := r.uint(section, name, 'width', s.width) or {
				r.refused['signal ${name}'] = true
				continue
			}
			sig.width = int(w)
			init := r.uint(section, name, 'init', s.init[0]) or {
				r.refused['signal ${name}'] = true
				continue
			}
			if sig.width < 64 && init >> u64(sig.width) != 0 {
				r.note(section, name, 'init "${s.init[0].text}" does not fit ${sig.width} bits; not read')
				r.refused['signal ${name}'] = true
				continue
			}
			sig.init = init
		}
		if !s.diag {
			if !r.is_node(sig.publisher) {
				r.note(section, name, 'publisher ${sig.publisher} is not a node of Nodes')
			}
			for t in s.subscribers {
				if !r.is_node(t.text) {
					r.note(section, name, 'subscriber ${t.text} is not a node of Nodes')
				}
				sig.subscribers << t.text
			}
		}
		r.l.signals << sig
	}
}

fn (mut r Reader) encodings(raw Raw) {
	section := 'Signal_encoding_types'
	for e in raw.encodings {
		name := e.name.text
		if r.l.encodings.any(it.name == name) {
			r.note(section, name, 'defined twice; the second is not read')
			continue
		}
		mut enc := Encoding{
			name: name
		}
		for rule in e.rules {
			a := rule.args
			match rule.kind.text {
				'logical_value' {
					if a.len !in [1, 2] || (a.len == 2 && a[1].kind != .str) {
						r.note(section, name, 'logical_value needs a value and an optional text; not read')
						continue
					}
					v := r.uint(section, name, 'logical_value', a[0]) or { continue }
					enc.rules << EncRule{
						kind: .logical
						lo:   v
						hi:   v
						text: if a.len == 2 { a[1].text } else { '' }
					}
				}
				'physical_value' {
					if a.len !in [4, 5] || (a.len == 5 && a[4].kind != .str) {
						r.note(section, name, 'physical_value needs min, max, scale, offset and an optional unit; not read')
						continue
					}
					lo := r.uint(section, name, 'min', a[0]) or { continue }
					hi := r.uint(section, name, 'max', a[1]) or { continue }
					scale := r.num(section, name, 'scale', a[2]) or { continue }
					offset := r.num(section, name, 'offset', a[3]) or { continue }
					if lo > hi {
						r.note(section, name, 'physical_value min ${lo} is above max ${hi}; not read')
						continue
					}
					enc.rules << EncRule{
						kind:   .physical
						lo:     lo
						hi:     hi
						scale:  scale
						offset: offset
						text:   if a.len == 5 { a[4].text } else { '' }
					}
				}
				'bcd_value', 'ascii_value' {
					if a.len != 0 {
						r.note(section, name, '${rule.kind.text} takes no values; not read')
						continue
					}
					enc.rules << EncRule{
						kind: if rule.kind.text == 'bcd_value' {
							EncKind.bcd
						} else {
							EncKind.ascii
						}
					}
				}
				else {
					r.note(section, name, '${rule.kind.text} is not an encoding rule; not read')
				}
			}
		}
		r.l.encodings << enc
	}
}

fn (mut r Reader) representations(raw Raw) {
	section := 'Signal_representation'
	for rep in raw.reps {
		ename := rep.encoding.text
		enc := r.l.encoding(ename) or {
			r.note(section, ename, 'no Signal_encoding_types entry of this name; not applied')
			continue
		}
		for t in rep.signals {
			mut found := false
			for mut s in r.l.signals {
				if s.name != t.text {
					continue
				}
				found = true
				if s.encoding != '' {
					r.note(section, ename, 'signal ${s.name} already has encoding ${s.encoding}; not applied')
				} else {
					s.encoding = ename
					if !s.is_array && enc.rules.any(it.kind in [.bcd, .ascii]) {
						r.note(section, ename, 'signal ${s.name} is a scalar; the bcd and ascii rules apply to byte arrays only and are not used for it')
					}
				}
			}
			if !found {
				r.note(section, ename, 'names ${r.missing('signal', 'Signals', t.text)}; not applied')
			}
		}
	}
}

// length_by_id is LIN 1.3's frame length, which the id states when the file does not.
fn length_by_id(id u8) int {
	return if id < 32 {
		2
	} else if id < 48 {
		4
	} else {
		8
	}
}

fn (r &Reader) has_frame_name(name string) bool {
	return r.l.frames.any(it.name == name) || r.l.event_frames.any(it.name == name)
		|| r.l.sporadic_frames.any(it.name == name)
}

fn (mut r Reader) frames(raw Raw) {
	if raw.big_endian {
		r.note('header', '', 'LIN_sig_byte_order_big_endian is not supported; no signal is mapped into a frame')
	}
	lang_major, _ := version_reading(r.l.language_version) or { 0, '' }
	for f in raw.frames {
		section := if f.diag { 'Diagnostic_frames' } else { 'Frames' }
		name := f.name.text
		if r.has_frame_name(name) {
			r.note(section, name, 'defined twice; the second is not read')
			continue
		}
		v := r.uint(section, name, 'id', f.id) or {
			r.refused['frame ${name}'] = true
			continue
		}
		id := u8(v)
		mut fr := Frame{
			name:      name
			id:        id
			publisher: f.publisher.text
			kind:      if f.diag { FrameKind.diagnostic } else { FrameKind.unconditional }
		}
		if f.diag {
			if name != 'MasterReq' && name != 'SlaveResp' {
				r.note(section, name, 'a diagnostic frame is MasterReq or SlaveResp; not read')
				r.refused['frame ${name}'] = true
				continue
			}
			want := if name == 'MasterReq' { u8(0x3C) } else { u8(0x3D) }
			if id != want {
				r.note(section, name, 'id "${f.id.text}" is not 0x${want:02X}; not read')
				r.refused['frame ${name}'] = true
				continue
			}
			fr.length = 8
			fr.publisher = if name == 'MasterReq' { r.l.master.name } else { '' }
		} else {
			// LIN 1.3 leaves the length to the id; LIN 2.0 and J2602 (read as 2.0) may too
			if lt := f.length {
				fr.length = int(r.uint(section, name, 'length', lt) or {
					r.refused['frame ${name}'] = true
					continue
				})
			} else if lang_major == 1 || r.l.language_version == '2.0'
				|| r.l.language_version.starts_with('J2602_') {
				fr.length = length_by_id(id)
			} else {
				why := if r.l.language_version == '' {
					'length is missing and LIN_language_version was not read, so it cannot be taken from the id; not read'
				} else {
					'length is missing, which LIN 2.1 and later require; not read'
				}
				r.note(section, name, why)
				r.refused['frame ${name}'] = true
				continue
			}
			if !r.is_node(fr.publisher) {
				r.note(section, name, 'publisher ${fr.publisher} is not a node of Nodes')
			}
		}
		if other := r.l.frame_by_id(id) {
			r.note(section, name, 'id "${f.id.text}" is frame ${other.name}\'s too; not read')
			r.refused['frame ${name}'] = true
			continue
		}
		if !raw.big_endian {
			r.map_signals(section, mut fr, f.maps)
		}
		r.l.frames << fr
	}
}

// map_signals places a frame's signals, refusing one mapped twice, one that leaves the frame,
// a byte array off a byte boundary (each of its bytes is one frame byte) and one overlapping
// another.
fn (mut r Reader) map_signals(section string, mut fr Frame, maps []RawMap) {
	mut used := []string{len: fr.length * 8}
	for m in maps {
		s := r.l.signal(m.signal.text) or {
			r.note(section, fr.name, 'maps ${r.missing('signal', 'Signals', m.signal.text)}; not mapped')
			continue
		}
		off := int(r.uint(section, fr.name, 'offset', m.offset) or { continue })
		if fr.signals.any(it.name == s.name) {
			r.note(section, fr.name, 'signal ${s.name} is mapped twice; the second at offset ${off} is not mapped')
			continue
		}
		if s.is_array && off % 8 != 0 {
			r.note(section, fr.name, 'byte array ${s.name} at offset ${off} is not on a byte boundary; not mapped')
			continue
		}
		if off + s.width > fr.length * 8 {
			r.note(section, fr.name, 'signal ${s.name} at offset ${off}, ${s.width} bits wide, does not fit ${fr.length} bytes; not mapped')
			continue
		}
		mut clash := ''
		for b in off .. off + s.width {
			if used[b] != '' {
				clash = used[b]
				break
			}
		}
		if clash != '' {
			r.note(section, fr.name, 'signal ${s.name} at offset ${off} overlaps signal ${clash}; not mapped')
			continue
		}
		for b in off .. off + s.width {
			used[b] = s.name
		}
		if fr.kind == .unconditional && s.publisher != fr.publisher {
			r.note(section, fr.name, 'signal ${s.name} is published by ${s.publisher}, the frame by ${fr.publisher}')
		}
		fr.signals << Mapped{s.name, off}
	}
}

fn (mut r Reader) events(raw Raw) {
	for e in raw.events {
		section := 'Event_triggered_frames'
		name := e.name.text
		if r.has_frame_name(name) {
			r.note(section, name, 'defined twice; the second is not read')
			continue
		}
		v := r.uint(section, name, 'id', e.id) or {
			r.refused['frame ${name}'] = true
			continue
		}
		id := u8(v)
		if other := r.l.frame_by_id(id) {
			r.note(section, name, 'id "${e.id.text}" is frame ${other.name}\'s too; not read')
			r.refused['frame ${name}'] = true
			continue
		}
		if other := r.l.event_frame_by_id(id) {
			r.note(section, name, 'id "${e.id.text}" is frame ${other.name}\'s too; not read')
			r.refused['frame ${name}'] = true
			continue
		}
		mut ev := EventFrame{
			name:  name
			id:    id
			table: if t := e.table { t.text } else { '' }
		}
		for t in e.frames {
			if f := r.l.frame(t.text) {
				if f.kind == .unconditional {
					ev.frames << t.text
					continue
				}
			}
			r.note(section, name, 'carries ${r.missing('frame', 'Frames', t.text)}')
		}
		r.l.event_frames << ev
	}
	for s in raw.sporadics {
		section := 'Sporadic_frames'
		name := s.name.text
		if r.has_frame_name(name) {
			r.note(section, name, 'defined twice; the second is not read')
			continue
		}
		mut sp := SporadicFrame{
			name: name
		}
		for t in s.frames {
			if f := r.l.frame(t.text) {
				if f.kind == .unconditional {
					sp.frames << t.text
					continue
				}
			}
			r.note(section, name, 'carries ${r.missing('frame', 'Frames', t.text)}')
		}
		r.l.sporadic_frames << sp
	}
	r.tied_frames()
	if raw.events.len > 0 {
		r.note('Event_triggered_frames', '', '${plural(raw.events.len, 'frame')} parsed; v1 does not run event-triggered frames')
	}
	if raw.sporadics.len > 0 {
		r.note('Sporadic_frames', '', '${plural(raw.sporadics.len, 'frame')} parsed; v1 does not run sporadic frames')
	}
}

// tied_frames: a frame an event-triggered frame carries keeps byte 0 for its own protected id,
// so a signal there is not mapped; and the frames of one event-triggered frame have one length
// and are published by different slaves (LIN 2.2A §2.3.3.2).
fn (mut r Reader) tied_frames() {
	section := 'Event_triggered_frames'
	for mut f in r.l.frames {
		if !r.l.is_tied(f.name) {
			continue
		}
		mut kept := []Mapped{}
		for m in f.signals {
			if m.offset < 8 {
				r.note('Frames', f.name, "signal ${m.name} at offset ${m.offset} is in byte 0, which carries the frame's protected id for an event-triggered frame; not mapped")
				continue
			}
			kept << m
		}
		f.signals = kept
	}
	for e in r.l.event_frames {
		mut lengths := []string{}
		mut publishers := map[string]string{}
		for name in e.frames {
			f := r.l.frame(name) or { continue }
			lengths << '${f.name} ${f.length}'
			if other := publishers[f.publisher] {
				r.note(section, e.name, 'carries ${other} and ${f.name}, both published by ${f.publisher}')
			} else {
				publishers[f.publisher] = f.name
			}
		}
		if lengths.map(it.all_after(' ')).any(it != lengths[0].all_after(' ')) {
			r.note(section, e.name, 'carries frames of unequal length (${lengths.join(', ')} bytes)')
		}
	}
}

fn (mut r Reader) node_attributes(raw Raw) {
	section := 'Node_attributes'
	for rn in raw.nodes {
		name := rn.name.text
		if r.l.nodes.any(it.name == name) {
			r.note(section, name, 'defined twice; the second is not read')
			continue
		}
		if name !in r.l.slaves {
			r.note(section, name, 'is not a slave of Nodes')
		}
		mut n := Node{
			name: name
		}
		mut stated := map[string]bool{}
		for a in rn.attrs {
			field := a.name.text
			if stated[field] {
				r.note(section, name, '${field} stated twice; the second is not read')
				continue
			}
			stated[field] = true
			match field {
				'LIN_protocol' {
					t := r.single(section, name, a) or { continue }
					if r.check(section, name, field, t) {
						_, said := version_reading(t.text) or { 0, '' }
						if said != '' {
							r.note(section, name, '${field} "${t.text}" ${said}')
						}
						n.protocol = t.text
					}
				}
				'configured_NAD', 'initial_NAD' {
					t := r.single(section, name, a) or { continue }
					v := r.uint(section, name, field, t) or { continue }
					if field == 'configured_NAD' {
						n.configured_nad = u8(v)
					} else {
						n.initial_nad = u8(v)
					}
				}
				'product_id' {
					if a.values.len !in [2, 3] {
						r.note(section, name, 'product_id needs a supplier id, a function id and an optional variant; not read')
						continue
					}
					mut parts := []u64{}
					for i, f in ['supplier_id', 'function_id', 'variant'] {
						if i >= a.values.len {
							break
						}
						t := r.one(section, name, f, a.values[i]) or { break }
						parts << r.uint(section, name, f, t) or { break }
					}
					if parts.len == a.values.len {
						n.product = ProductId{
							supplier: u16(parts[0])
							function: u16(parts[1])
							variant:  if parts.len == 3 { ?u8(u8(parts[2])) } else { none }
						}
					}
				}
				'response_error' {
					t := r.single(section, name, a) or { continue }
					if !r.l.signals.any(it.name == t.text) {
						r.note(section, name, 'response_error names ${r.missing('signal', 'Signals', t.text)}')
					}
					n.response_error = t.text
				}
				'fault_state_signals' {
					for item in a.values {
						t := r.one(section, name, field, item) or { continue }
						if !r.l.signals.any(it.name == t.text) {
							r.note(section, name, 'fault_state_signals names ${r.missing('signal', 'Signals', t.text)}')
						}
						n.fault_state_signals << t.text
					}
				}
				'P2_min', 'ST_min', 'N_As_timeout', 'N_Cr_timeout' {
					if a.values.len != 1 {
						r.note(section, name, '${field} takes one time; not read')
						continue
					}
					v := r.ms(section, name, field, a.values[0]) or { continue }
					match field {
						'P2_min' { n.p2_min_ms = v }
						'ST_min' { n.st_min_ms = v }
						'N_As_timeout' { n.n_as_timeout_ms = v }
						else { n.n_cr_timeout_ms = v }
					}
				}
				else {
					r.note(section, name, '${field} not read')
				}
			}
		}
		for cf in rn.frames {
			if !r.has_frame_name(cf.name.text) {
				r.note(section, name, 'configurable_frames names ${r.missing('frame', 'Frames', cf.name.text)}')
			}
			if t := cf.id {
				v := r.uint(section, name, 'message_id', t) or { continue }
				n.configurable_frames << ConfigurableFrame{cf.name.text, u16(v)}
			} else {
				n.configurable_frames << ConfigurableFrame{cf.name.text, none}
			}
		}
		if !rn.attrs.any(it.name.text == 'LIN_protocol') {
			r.note(section, name, "LIN_protocol is missing; its frames take the file's checksum model")
		}
		if !rn.attrs.any(it.name.text == 'configured_NAD') {
			r.note(section, name, 'configured_NAD is missing')
		}
		r.l.nodes << n
	}
	// LIN 2.x describes every slave in Node_attributes; LIN 1.x has no such section
	lang_major, _ := version_reading(r.l.language_version) or { 0, '' }
	if lang_major >= 2 {
		for slave in r.l.slaves {
			if !r.l.nodes.any(it.name == slave) && !raw.nodes.any(it.name.text == slave) {
				r.note(section, slave, "no attributes; its frames take the file's checksum model and it has no NAD")
			}
		}
	}
}

fn (mut r Reader) schedules(raw Raw) {
	section := 'Schedule_tables'
	for s in raw.schedules {
		name := s.name.text
		if r.l.schedules.any(it.name == name) {
			r.note(section, name, 'defined twice; the second is not read')
			continue
		}
		mut sch := Schedule{
			name: name
		}
		mut ok := true
		mut commands := 0
		for slot in s.slots {
			delay := r.ms(section, name, 'delay', slot.delay) or {
				ok = false
				continue
			}
			cmd := slot.cmd.text
			if slot.braced || cmd in config_commands {
				if cmd !in config_commands {
					r.note(section, name, '${cmd} is not a LIN configuration command; not read')
					ok = false
					continue
				}
				commands++
				sch.slots << Slot{.command, '', cmd, delay}
			} else if cmd == 'MasterReq' || cmd == 'SlaveResp' {
				sch.slots << Slot{.diagnostic, cmd, '', delay}
			} else if f := r.l.frame(cmd) {
				sch.slots << Slot{.frame, f.name, '', delay}
			} else if r.l.event_frames.any(it.name == cmd) {
				sch.slots << Slot{.event_triggered, cmd, '', delay}
			} else if r.l.sporadic_frames.any(it.name == cmd) {
				sch.slots << Slot{.sporadic, cmd, '', delay}
			} else {
				r.note(section, name, 'names ${r.missing('frame', 'Frames', cmd)}; not read')
				ok = false
			}
		}
		if ok {
			r.l.schedules << sch
			r.commands += commands
		} else {
			r.refused['table ${name}'] = true
		}
	}
	if r.commands > 0 {
		r.note(section, '', '${plural(r.commands, 'configuration command')} kept for their slot time; v1 does not send them')
	}
}

// event_tables: the collision-resolving table an event-triggered frame names must exist.
fn (mut r Reader) event_tables() {
	for e in r.l.event_frames {
		if e.table != '' && !r.l.schedules.any(it.name == e.table) {
			r.note('Event_triggered_frames', e.name, 'names collision-resolving ${r.missing('table', 'Schedule_tables', e.table)}')
		}
	}
}
