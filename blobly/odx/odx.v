// odx — an ECU's diagnostic description read from ODX (ISO 22901-1): a PDX (the ZIP it is
// packaged in), one ODX file, or a folder of them. The reader is an EXTRACTOR, not a model of ODX:
// for one base or ECU variant (its parents' services and DTCs inherited, a NOT-INHERITED service
// left out) it finds the ReadDataByIdentifier (0x22) and WriteDataByIdentifier (0x2E) services,
// lays out each DID's value from its parameters' data object properties and structures (a LINEAR,
// SCALE-LINEAR or TEXTTABLE compu method carried for the codec), reads the sessions and security
// level each service asks for from its state-chart preconditions, and lists the DTCs of its
// DTC-DOPs. What it does not read is SAID, never read as 0: every service of
// another kind, every job and every layer element it does not use is counted (`Variant.notes`), a
// DID whose value it cannot lay out is kept as bytes of its size with the reason, and a value it
// cannot read at all (a malformed number) is refused by element and value.
module odx

import os
import math
import strconv
import flatxml

// PartKind is what one part of a DID's value holds, as its coded type says: an unsigned or signed
// integer (big-endian), an ASCII text, or bytes.
pub enum PartKind {
	unsigned
	signed
	text
	bytes
}

// Part is one VALUE parameter of a DID: its coded type, and how its physical value is computed from
// it (`compu`, empty for IDENTICAL).
pub struct Part {
pub:
	name   string
	kind   PartKind
	offset int // its first byte in the DID's value
	size   int // bytes
	compu  Compu
}

// Compu is an integer part's COMPU-METHOD where it is not IDENTICAL: linear segments to a physical
// number (LINEAR, SCALE-LINEAR), or labels (TEXTTABLE) — never both.
pub struct Compu {
pub:
	segments []Segment
	labels   []Label
	fallback string // a TEXTTABLE's COMPU-DEFAULT-VALUE: the label of a raw value no entry names
	unit     string // the physical unit's display name
}

// Segment is one linear COMPU-SCALE: physical = (v0 + v1 * raw) / d, for a raw value in lo..hi.
pub struct Segment {
pub:
	lo i64 = min_i64
	hi i64 = max_i64
	v0 f64
	v1 f64
	d  f64 = 1
}

// Label is one TEXTTABLE COMPU-SCALE: a raw value in lo..hi reads as `text`, which is written as
// `write` (its COMPU-INVERSE-VALUE, else its lower limit).
pub struct Label {
pub:
	lo    i64
	hi    i64
	text  string
	write i64
}

// Gate is what a service's PRE-CONDITION-STATE-REFS ask for: the sessions it is served in, as 0x10
// sub-functions (none = any), and the security level it needs (0 = none). `declared` false: the
// service names no precondition.
pub struct Gate {
pub:
	declared bool
	sessions []u8
	level    int
}

// Did is one data identifier the variant's 0x22 and 0x2E services name.
pub struct Did {
pub:
	id       u16
	name     string // the value parameter's SHORT-NAME where there is one, else the service's
	readable bool   // a 0x22 service reads it
	writable bool   // a 0x2E service writes it
	// the preconditions of the service that reads it and of the one that writes it
	read_gate  Gate
	write_gate Gate
	// the value's size in bytes; -1 when the description does not fix it
	size int = -1
	// the value's parts, back to back from byte 0, when the reader lays out every one; empty when
	// it does not, and the value is bytes of `size`
	parts []Part
}

// Dtc is one DTC of a DTC-DOP: its SHORT-NAME, its 24-bit TROUBLE-CODE, its display form and text.
pub struct Dtc {
pub:
	name    string
	code    u32
	display string
	text    string
}

// Variant is what one base or ECU variant describes.
pub struct Variant {
pub:
	name  string
	layer string // BASE-VARIANT or ECU-VARIANT
	dids  []Did
	dtcs  []Dtc
	// what the reader did not read, or read only in part: each said once
	notes []string
}

// Db is the documents of one ODX source, indexed.
pub struct Db {
pub:
	path  string
	files []string // every ODX file read (the PDX itself for a PDX)
	notes []string // what reading the documents had to say
mut:
	docs   []&flatxml.Doc
	// every element with an ID, by its document's path and the ID ('<path>\n<id>'): an ID is
	// unique within its document only
	ids map[string]flatxml.Node
	// each document's path by its container's SHORT-NAME, which a reference's DOCREF names
	doc_names map[string]string
	layers map[string]flatxml.Node // every base and ECU variant, by SHORT-NAME
}

// variant_layers are the layers a project names: a variant to describe an ECU by.
const variant_layers = ['BASE-VARIANT', 'ECU-VARIANT']

// load reads `path`: a .pdx (every ODX document inside it), one ODX file, or a folder of ODX files.
pub fn load(path string) !Db {
	mut db := Db{
		path: path
	}
	mut notes := []string{}
	mut files := []string{}
	if os.is_dir(path) {
		mut names := os.ls(path) or { return error('cannot list ${path}: ${err}') }
		names.sort()
		for n in names {
			p := os.join_path(path, n)
			if os.is_file(p) && is_odx_name(n) {
				db.add_doc(os.read_bytes(p) or { return error('cannot read ${p}: ${err}') }, p)!
				files << p
			}
		}
		if files.len == 0 {
			return error('${path}: no ODX file (.odx, .odx-d, ...) in it')
		}
	} else {
		data := os.read_bytes(path) or { return error('cannot read ${path}: ${err}') }
		files << path
		if path.to_lower().ends_with('.pdx') {
			zip := read_zip(data, is_odx_name) or { return error('${path}: ${err}') }
			for e in zip.entries {
				db.add_doc(e.data, '${path}#${e.name}')!
			}
			if zip.skipped.len > 0 {
				notes << '${path}: ${zip.skipped.len} file(s) of the PDX are not ODX (its index, attachments); not read'
			}
		} else {
			db.add_doc(data, path)!
		}
	}
	notes << db.index()
	return Db{
		...db
		files: files
		notes: notes
	}
}

// is_odx_name: a file name an ODX document is stored under (.odx, .odx-d, .odx-c, .odx-cs, ...).
fn is_odx_name(name string) bool {
	n := name.to_lower()
	return n.ends_with('.odx') || n.contains('.odx-')
}

fn (mut db Db) add_doc(data []u8, where string) ! {
	mut doc := flatxml.parse_bytes(data, where) or { return error('${where}: ${err}') }
	doc.resolve_namespaces() or { return error('${where}: ${err}') }
	if doc.root_node().name() != 'ODX' {
		return error('${where}: the root element is <${doc.root_node().name()}>, not <ODX>')
	}
	db.docs << doc
}

// index finds every element with an ID, every document's container name and every variant layer,
// saying an ID given twice in one document, or a container or variant name given twice (the first is
// kept).
fn (mut db Db) index() []string {
	mut notes := []string{}
	for doc in db.docs {
		for c in doc.root_node().children() {
			cn := short_name(c)
			if cn == '' {
				continue
			}
			if cn in db.doc_names {
				notes << '${doc.path}: a document named "${cn}" is read already; a DOCREF to it names the first'
			} else {
				db.doc_names[cn] = doc.path
			}
		}
		for i in 0 .. doc.len() {
			if !doc.is_element(u32(i)) {
				continue
			}
			n := doc.node(u32(i))
			id := n.attr('ID')
			if id != '' {
				key := '${doc.path}\n${id}'
				if key in db.ids {
					notes << '${doc.path}: ID "${id}" is given twice; the first is read'
				} else {
					db.ids[key] = n
				}
			}
			if n.name() in variant_layers {
				sn := short_name(n)
				if sn in db.layers {
					notes << '${doc.path}: two variants are named "${sn}"; the first is read'
				} else {
					db.layers[sn] = n
				}
			}
		}
	}
	return notes
}

// variants are the base and ECU variants' names, sorted.
pub fn (db &Db) variants() []string {
	mut out := db.layers.keys()
	out.sort()
	return out
}

// kids are `n`'s child elements named `name`, in order.
fn kids(n flatxml.Node, name string) []flatxml.Node {
	mut out := []flatxml.Node{}
	for c in n.children_named(name) {
		out << c
	}
	return out
}

const xsi_uri = 'http://www.w3.org/2001/XMLSchema-instance'

// xsi_type is an element's XML Schema instance type, by namespace and local name whatever prefix
// spells it; '' for none.
fn xsi_type(n flatxml.Node) string {
	if !n.ok() {
		return ''
	}
	ns := n.doc.ns_id(xsi_uri) or { return '' }
	lo, hi := n.doc.attr_range(n.i)
	for a := lo; a < hi; a++ {
		if n.doc.attr_ns_of(a) == ns && n.doc.attr_local_name(a) == 'type' {
			return n.doc.attr_value(a)
		}
	}
	return ''
}

fn short_name(n flatxml.Node) string {
	return n.child('SHORT-NAME').text().trim_space()
}

// ref is the element an `ID-REF` attribute of `n` names: in the document its DOCREF names, else in
// `n`'s own.
fn (db &Db) ref(n flatxml.Node) ?flatxml.Node {
	if !n.ok() {
		return none
	}
	docref := n.attr('DOCREF')
	path := if docref != '' { db.doc_names[docref] or { return none } } else { n.doc.path }
	return db.ids['${path}\n${n.attr('ID-REF')}'] or { none }
}

// Resolve is one variant's resolution in progress: its layers in inheritance precedence (`order`),
// and what it found.
struct Resolve {
mut:
	chain []flatxml.Node
	depth []int // per layer of the chain, the fewest PARENT-REFs it is reached by
	// per layer of the chain, the services and the DOPs it does not pass on to the variant
	comms   []map[string]bool
	dops    []map[string]bool
	notes   []string
	ignored map[string]int // element kinds not read, counted
}

// variant resolves the variant called `name`: refused for a name no variant has, naming those there are.
pub fn (db &Db) variant(name string) !Variant {
	top := db.layers[name] or {
		return error('no variant "${name}" in ${db.path}; there are: ${db.variants().join(', ')}')
	}
	mut r := Resolve{}
	db.walk_layers(top, map[string]bool{}, map[string]bool{}, mut r, 0)
	r.order()
	// the services, nearest layer first: a SHORT-NAME seen is overridden further up
	mut seen := map[string]bool{}
	mut svcs := []flatxml.Node{}
	for li, layer in r.chain {
		ex := r.comms[li]
		for c in layer.child('DIAG-COMMS').children() {
			mut svc := c
			if c.name() == 'DIAG-COMM-REF' {
				svc = db.ref(c) or {
					r.notes << 'DIAG-COMM-REF "${c.attr('ID-REF')}" names nothing; not read'
					continue
				}
			}
			sn := short_name(svc)
			if sn in seen || sn in ex {
				continue
			}
			seen[sn] = true
			if svc.name() != 'DIAG-SERVICE' {
				r.ignored[svc.name()]++
				continue
			}
			svcs << svc
		}
		for c in layer.children() {
			if c.name() !in read_layer_children {
				r.ignored[c.name()]++
			}
		}
		for c in layer.child('DIAG-DATA-DICTIONARY-SPEC').children() {
			if c.name() !in read_dds_children {
				r.ignored['DIAG-DATA-DICTIONARY-SPEC/${c.name()}']++
			}
		}
		for p in layer.child('PARENT-REFS').children_named('PARENT-REF') {
			for c in p.children() {
				if c.name() !in read_parent_ref_children {
					r.ignored['PARENT-REF/${c.name()}']++
				}
			}
		}
	}
	states := db.state_meanings(svcs, mut r)
	mut found := map[u16]Did{}
	mut clash := map[u16]bool{} // DIDs two services lay out differently: never written
	for svc in svcs {
		db.service(svc, states, mut r, mut found, mut clash)
	}
	mut dids := found.values()
	dids.sort(a.id < b.id)
	mut notes := r.notes.clone()
	mut keys := r.ignored.keys()
	keys.sort()
	if keys.len > 0 {
		notes << 'not read: ' + keys.map('${r.ignored[it]} x ${it}').join(', ')
	}
	return Variant{
		name:  name
		layer: top.name()
		dids:  dids
		dtcs:  db.dtcs(r, mut notes)
		notes: notes
	}
}

// the layer children the reader uses, or that describe and carry no behaviour
const read_layer_children = ['SHORT-NAME', 'LONG-NAME', 'DESC', 'ADMIN-DATA', 'COMPANY-DATAS',
	'SDGS', 'DIAG-DATA-DICTIONARY-SPEC', 'DIAG-COMMS', 'REQUESTS', 'POS-RESPONSES', 'NEG-RESPONSES',
	'GLOBAL-NEG-RESPONSES', 'PARENT-REFS', 'STATE-CHARTS']

// what of a PARENT-REF the reader applies
const read_parent_ref_children = ['NOT-INHERITED-DIAG-COMMS', 'NOT-INHERITED-DOPS']

// the data dictionary sections the reader uses (UNIT-SPEC describes and changes no byte)
const read_dds_children = ['DATA-OBJECT-PROPS', 'STRUCTURES', 'DTC-DOPS', 'UNIT-SPEC', 'ADMIN-DATA',
	'SDGS']

// walk_layers appends `layer` and then its parents (PARENT-REFS), depth first, each once, with the
// fewest PARENT-REFs it is reached by and the services and DOPs it does not pass on: those a
// PARENT-REF on the way to it leaves out, and for a layer reached on several ways only those every
// way leaves out (it is walked again when one more way narrows them or reaches it nearer).
fn (db &Db) walk_layers(layer flatxml.Node, comms map[string]bool, dops map[string]bool, mut r Resolve, depth int) {
	if depth > 16 {
		return
	}
	mut k := -1
	for i, c in r.chain {
		if c.i == layer.i && c.doc == layer.doc {
			k = i
			break
		}
	}
	mut here_comms := comms.clone()
	mut here_dops := dops.clone()
	if k < 0 {
		r.chain << layer
		r.depth << depth
		r.comms << comms.clone()
		r.dops << dops.clone()
	} else {
		nearer := depth < r.depth[k]
		if nearer {
			r.depth[k] = depth
		}
		here_comms = common(r.comms[k], comms)
		here_dops = common(r.dops[k], dops)
		if !nearer && here_comms.len == r.comms[k].len && here_dops.len == r.dops[k].len {
			return
		}
		r.comms[k] = here_comms.clone()
		r.dops[k] = here_dops.clone()
	}
	for p in layer.child('PARENT-REFS').children_named('PARENT-REF') {
		parent := db.ref(p) or {
			if k < 0 {
				r.notes << '${short_name(layer)}: PARENT-REF "${p.attr('ID-REF')}" names nothing; its services are not inherited'
			}
			continue
		}
		mut pc := here_comms.clone()
		for ni in p.child('NOT-INHERITED-DIAG-COMMS').children_named('NOT-INHERITED-DIAG-COMM') {
			pc[snref_of(ni)] = true
		}
		mut pd := here_dops.clone()
		for ni in p.child('NOT-INHERITED-DOPS').children_named('NOT-INHERITED-DOP') {
			pd[snref_of(ni)] = true
		}
		db.walk_layers(parent, pc, pd, mut r, depth + 1)
	}
}

// layer_rank is a layer kind's place in ODX's inheritance precedence: an ECU variant before a base
// variant, a functional group, a protocol and ECU shared data.
fn layer_rank(tag string) int {
	return match tag {
		'ECU-VARIANT' { 0 }
		'BASE-VARIANT' { 1 }
		'FUNCTIONAL-GROUP' { 2 }
		'PROTOCOL' { 3 }
		'ECU-SHARED-DATA' { 4 }
		else { 5 }
	}
}

// order puts the chain in inheritance precedence: by layer kind, then nearer before farther, then
// in the order the PARENT-REFS name them; what a layer passes on travels with it.
fn (mut r Resolve) order() {
	ranks := r.chain.map(layer_rank(it.name()))
	depths := r.depth.clone()
	mut idx := []int{len: r.chain.len, init: index}
	idx.sort_with_compare(fn [ranks, depths] (a &int, b &int) int {
		if ranks[*a] != ranks[*b] {
			return ranks[*a] - ranks[*b]
		}
		if depths[*a] != depths[*b] {
			return depths[*a] - depths[*b]
		}
		return *a - *b
	})
	r.chain = idx.map(r.chain[it])
	r.depth = idx.map(r.depth[it])
	r.comms = idx.map(r.comms[it])
	r.dops = idx.map(r.dops[it])
}

// common is the names in both `a` and `b`.
fn common(a map[string]bool, b map[string]bool) map[string]bool {
	mut out := map[string]bool{}
	for name, _ in a {
		if name in b {
			out[name] = true
		}
	}
	return out
}

// snref_of is the SHORT-NAME a NOT-INHERITED entry's reference (DIAG-COMM-SNREF, DOP-BASE-SNREF) names.
fn snref_of(n flatxml.Node) string {
	for c in n.children() {
		return c.attr('SHORT-NAME')
	}
	return ''
}

// service reads one DIAG-SERVICE: a 0x22 or 0x2E of one DID is a DID read or written, any other
// service is counted by its service id. A DID two services lay out differently is in `clash` and
// stays unwritten whatever service follows.
fn (db &Db) service(svc flatxml.Node, states map[string]StateMeaning, mut r Resolve, mut found map[u16]Did, mut clash map[u16]bool) {
	sn := short_name(svc)
	req := db.ref(svc.child('REQUEST-REF')) or {
		r.notes << 'service ${sn}: no REQUEST; not read'
		return
	}
	params := kids(req.child('PARAMS'), 'PARAM')
	sid := const_at(params, 0, 8, mut r, sn) or {
		r.notes << 'service ${sn}: no service id at byte 0; not read'
		return
	}
	if sid != 0x22 && sid != 0x2E {
		r.ignored['DIAG-SERVICE 0x${sid:02X}']++
		return
	}
	// what of a DID's service could state a gate beside its state-chart preconditions
	for c in ['AUDIENCE', 'SDGS'] {
		if svc.child(c).ok() {
			r.ignored['DIAG-SERVICE/${c}']++
		}
	}
	id := const_at(params, 1, 16, mut r, sn) or {
		r.notes << 'service ${sn} (0x${sid:02X}): no single 16-bit DID at byte 1 (a TABLE-KEY, or several DIDs); not read'
		return
	}
	if sid == 0x22 && params.len != 2 {
		r.notes << 'service ${sn} (0x22 0x${id:04X}): its request carries ${params.len - 2} parameter(s) past the DID (several DIDs, or more than a DID); not read'
		return
	}
	mut values := []flatxml.Node{}
	if sid == 0x22 {
		resp := db.ref(svc.child('POS-RESPONSE-REFS').child('POS-RESPONSE-REF')) or {
			r.notes << 'service ${sn} (0x22 0x${id:04X}): no POS-RESPONSE, so its value is not known; not read'
			return
		}
		values = kids(resp.child('PARAMS'), 'PARAM')
	} else {
		values = params.clone()
	}
	mut lay := Layout{}
	db.lay_out(values, 3, 0, mut lay, r, 0)
	lay.finish()
	for w in lay.said {
		r.notes << 'DID 0x${id:04X} (${sn}): ${w}'
	}
	gate := db.gate_of(svc, states, mut r, 'service ${sn} (0x${sid:02X} 0x${id:04X})')
	vname := lay.name(sn)
	if lay.why.len > 0 {
		r.notes << 'DID 0x${id:04X} (${sn}): ${lay.why.join('; ')} — read as ${if lay.size >= 0 {
			'${lay.size} bytes'
		} else {
			'bytes of no fixed size'
		}}'
	}
	parts := if lay.why.len == 0 { lay.parts.clone() } else { []Part{} }
	if prev := found[u16(id)] {
		// the value is laid out as the first 0x22 service read reads it, whichever came first; a
		// write is kept only where every service lays it out alike
		same := prev.size == lay.size && shapes(prev.parts) == shapes(parts)
		mut d := if sid == 0x22 && !prev.readable {
			Did{
				...prev
				name:      vname
				readable:  true
				size:      lay.size
				parts:     parts
				read_gate: gate
			}
		} else {
			Did{
				...prev
				name:       if prev.name == '' { vname } else { prev.name }
				readable:   prev.readable || sid == 0x22
				writable:   prev.writable || sid == 0x2E
				write_gate: if sid == 0x2E && !prev.writable { gate } else { prev.write_gate }
			}
		}
		if !same {
			r.notes << 'DID 0x${id:04X}: ${sn} lays its value out unlike the service read before it; not written'
			clash[u16(id)] = true
		}
		if clash[u16(id)] {
			d = Did{
				...d
				writable: false
			}
		}
		found[u16(id)] = d
		return
	}
	found[u16(id)] = Did{
		id:         u16(id)
		name:       vname
		readable:   sid == 0x22
		writable:   sid == 0x2E
		size:       lay.size
		parts:      parts
		read_gate:  if sid == 0x22 { gate } else { Gate{} }
		write_gate: if sid == 0x2E { gate } else { Gate{} }
	}
}

// StateMeaning is what the variant's services make of a state: the 0x10 sub-functions whose
// transitions enter it, and the security levels whose 0x27 sendKey transitions do.
struct StateMeaning {
mut:
	sessions []u8
	levels   []int
}

// node_key is an element's identity across documents.
fn node_key(n flatxml.Node) string {
	return '${n.doc.path}#${n.i}'
}

// state_meanings reads every 0x10 and 0x27 service's STATE-TRANSITION-REFS: the state each
// transition enters, by the session or security level the service establishes.
fn (db &Db) state_meanings(svcs []flatxml.Node, mut r Resolve) map[string]StateMeaning {
	mut out := map[string]StateMeaning{}
	mut quiet := Resolve{} // service() says what is malformed in a request
	for svc in svcs {
		sn := short_name(svc)
		req := db.ref(svc.child('REQUEST-REF')) or { continue }
		params := kids(req.child('PARAMS'), 'PARAM')
		sid := const_at(params, 0, 8, mut quiet, sn) or { continue }
		if sid != 0x10 && sid != 0x27 {
			continue
		}
		trefs := kids(svc.child('STATE-TRANSITION-REFS'), 'STATE-TRANSITION-REF')
		if trefs.len == 0 {
			continue
		}
		raw := const_at(params, 1, 8, mut quiet, sn) or {
			r.notes << 'service ${sn} (0x${sid:02X}): no sub-function at byte 1; its state transitions are not read'
			continue
		}
		sub := u8(raw) & 0x7F // the suppress-positive-response bit apart
		for tref in trefs {
			tr := db.ref(tref) or {
				r.notes << 'service ${sn}: STATE-TRANSITION-REF "${tref.attr('ID-REF')}" names nothing; not read'
				continue
			}
			want := tr.child('TARGET-SNREF').attr('SHORT-NAME')
			target := state_named(tr.parent().parent(), want) or {
				r.notes << 'state transition ${short_name(tr)}: its target "${want}" is no state of its chart; not read'
				continue
			}
			mut m := out[node_key(target)] or { StateMeaning{} }
			if sid == 0x10 {
				m.sessions << sub
			} else if sub > 0 && sub % 2 == 0 {
				m.levels << int(sub / 2)
			}
			out[node_key(target)] = m
		}
	}
	return out
}

// state_named is the STATE of `chart` called `name`.
fn state_named(chart flatxml.Node, name string) ?flatxml.Node {
	for st in chart.child('STATES').children_named('STATE') {
		if short_name(st) == name {
			return st
		}
	}
	return none
}

// gate_of is what a service's PRE-CONDITION-STATE-REFS ask for. A state of a SESSION chart is the
// session a 0x10 transition enters it by (its chart's start state: the default session); one of a
// SECURITY chart the level a 0x27 sendKey transition enters it by (its start state: locked, no
// level). States of one chart are alternatives: the sessions are each listed, the lowest level is
// needed. A state it cannot give a meaning, or a precondition on a parameter's value, is said and
// left out of the gate.
fn (db &Db) gate_of(svc flatxml.Node, states map[string]StateMeaning, mut r Resolve, what string) Gate {
	refs := kids(svc.child('PRE-CONDITION-STATE-REFS'), 'PRE-CONDITION-STATE-REF')
	if refs.len == 0 {
		return Gate{}
	}
	mut sessions := []u8{}
	mut levels := []int{}
	for ref in refs {
		if ref.child('VALUE').ok() || ref.child('IN-PARAM-IF-SNREF').ok()
			|| ref.child('IN-PARAM-PATH-SNREF').ok() {
			r.notes << '${what}: a precondition on a parameter value (state "${ref.attr('ID-REF')}"); not read'
			continue
		}
		st := db.ref(ref) or {
			r.notes << '${what}: PRE-CONDITION-STATE-REF "${ref.attr('ID-REF')}" names nothing; not read'
			continue
		}
		chart := st.parent().parent()
		sem := chart.child('SEMANTIC').text().trim_space().to_upper()
		m := states[node_key(st)] or { StateMeaning{} }
		start := chart.child('START-STATE-SNREF').attr('SHORT-NAME') == short_name(st)
		if sem.contains('SESSION') {
			s := if m.sessions.len > 0 {
				m.sessions[0]
			} else if start {
				u8(0x01)
			} else {
				r.notes << '${what}: session state ${short_name(st)} is entered by no 0x10 service; not read'
				continue
			}
			if s !in sessions {
				sessions << s
			}
		} else if sem.contains('SECURITY') {
			l := if m.levels.len > 0 {
				m.levels[0]
			} else if start {
				0
			} else {
				r.notes << '${what}: security state ${short_name(st)} is entered by no 0x27 sendKey; not read'
				continue
			}
			levels << l
		} else {
			r.notes << '${what}: state ${short_name(st)} of chart ${short_name(chart)} (SEMANTIC "${sem}") is no session or security state; not read'
		}
	}
	mut level := 0
	if levels.len > 0 && 0 !in levels {
		level = levels[0]
		for l in levels {
			if l < level {
				level = l
			}
		}
	}
	return Gate{
		declared: true
		sessions: sessions
		level:    level
	}
}

// shapes are parts as the bytes lay them out, their names left out.
fn shapes(parts []Part) []Part {
	return parts.map(Part{
		...it
		name: ''
	})
}

// const_at is the CODED-CONST parameter's value at `at_byte` of `bits` width, none when there is none.
// A parameter with no BYTE-POSITION is after the one before it.
fn const_at(params []flatxml.Node, at_byte int, bits int, mut r Resolve, sn string) ?u64 {
	mut next := 0 // where a parameter with no BYTE-POSITION goes; -1 after one of no fixed size
	for p in params {
		posv := p.child('BYTE-POSITION')
		pos := if posv.ok() { int(int_of(posv.text()) or { -1 }) } else { next }
		end := const_end(p)
		next = if pos >= 0 && end >= 0 { pos + end } else { -1 }
		if xsi_type(p) != 'CODED-CONST' || pos < 0 || pos != at_byte {
			continue
		}
		width := int_of(p.child('DIAG-CODED-TYPE').child('BIT-LENGTH').text()) or { -1 }
		if width != bits {
			return none
		}
		raw := p.child('CODED-VALUE').text()
		v := int_of(raw) or {
			r.notes << 'service ${sn}: CODED-VALUE "${raw}" is not an integer; not read'
			return none
		}
		if v < 0 || v >= i64(1) << bits {
			r.notes << 'service ${sn}: CODED-VALUE ${v} does not fit ${bits} bits; not read'
			return none
		}
		return u64(v)
	}
	return none
}

// int_of reads a decimal or `0x` hex integer, none for anything else (never 0).
fn int_of(t string) ?i64 {
	s := t.trim_space()
	if s.len == 0 {
		return none
	}
	if s.starts_with('0x') || s.starts_with('0X') {
		if s.len == 2 || !s[2..].bytes().all(it.is_hex_digit()) || s.len > 18 {
			return none
		}
		return i64(s[2..].parse_uint(16, 63) or { return none })
	}
	body := if s[0] == `-` { s[1..] } else { s }
	if body.len == 0 || body.len > 18 || !body.bytes().all(it.is_digit()) {
		return none
	}
	return s.parse_int(10, 64) or { none }
}

// max_struct_depth bounds structures inside structures: a description naming itself is refused.
const max_struct_depth = 8

// Layout is a DID's value as its parameters lay it out.
struct Layout {
mut:
	parts  []Part
	values []string // the SHORT-NAMEs of the value parameters at the top level
	size   int      // bytes; -1 once a part's size is unknown
	sized  bool = true
	why    []string // why the value is not laid out part by part
	said   []string // what of a part it lays out is not read
}

// lay_out reads `params` from byte `base` of their message (3 for a DID's response or write
// request, 0 inside a structure), each part placed at `at` plus its position.
fn (db &Db) lay_out(params []flatxml.Node, base int, at int, mut lay Layout, r &Resolve, depth int) {
	if depth > max_struct_depth {
		lay.why << 'structures nested past ${max_struct_depth}'
		lay.sized = false
		return
	}
	mut next := 0 // where a parameter with no BYTE-POSITION goes: after the one before it
	for p in params {
		typ := xsi_type(p)
		pname := short_name(p)
		posv := p.child('BYTE-POSITION')
		mut pos := if typ == 'VALUE' && next >= 0 && next < base { base } else { next }
		if posv.ok() {
			pos = int(int_of(posv.text()) or { -1 })
			if pos < 0 {
				lay.why << '${pname}: BYTE-POSITION "${posv.text()}" is not an integer'
				lay.sized = false
				return
			}
		} else if next < 0 {
			lay.why << '${pname}: no BYTE-POSITION after a parameter of no fixed size'
			lay.sized = false
			return
		}
		if pos < base {
			// the service id and the DID, before the value; one of no fixed size ends at `base`
			end := const_end(p)
			next = if end >= 0 { pos + end } else { base }
			continue
		}
		if typ != 'VALUE' {
			lay.why << '${pname}: a ${typ} parameter inside the value'
			end := const_end(p)
			next = if end >= 0 { pos + end } else { -1 }
			lay.extend(at + pos - base, end)
			continue
		}
		bpv := p.child('BIT-POSITION')
		mut bitpos := 0 // the value's first bit in its first byte; -1 when not an integer
		if bpv.ok() {
			bitpos = int(int_of(bpv.text()) or { -1 })
			if bitpos < 0 {
				bitpos = -1
			}
			if bitpos != 0 {
				lay.why << '${pname}: BIT-POSITION "${bpv.text()}"'
			}
		}
		if base > 0 {
			lay.values << pname
		}
		dop := db.dop_of(p, r) or {
			lay.why << '${pname}: ${err.msg()}'
			lay.sized = false
			next = -1
			continue
		}
		start := at + pos - base
		mut size := -1
		match dop.name() {
			'DATA-OBJECT-PROP' {
				size = lay.coded(pname, dop, start, db.unit_of(dop))
			}
			'STRUCTURE' {
				mut inner := Layout{}
				db.lay_out(kids(dop.child('PARAMS'), 'PARAM'), 0, start, mut inner, r, depth + 1)
				for w in inner.said {
					lay.said << '${pname}: ${w}'
				}
				inner.finish_from(start)
				size = if inner.sized { inner.size } else { -1 }
				bsv := dop.child('BYTE-SIZE')
				if bsv.ok() {
					bs := int_of(bsv.text()) or { -1 }
					if bs < 0 {
						inner.why << 'its STRUCTURE ${short_name(dop)}: BYTE-SIZE "${bsv.text()}" is not an integer'
					} else if size >= 0 && int(bs) > size {
						inner.why << 'its STRUCTURE ${short_name(dop)} is ${bs} bytes, its parameters ${size}'
						size = int(bs)
					}
				}
				for w in inner.why {
					lay.why << '${pname}: ${w}'
				}
				for q in inner.parts {
					lay.parts << q
				}
			}
			else {
				lay.why << '${pname}: its DOP is a ${dop.name()}'
			}
		}
		size = occupied(size, bitpos, dop.name())
		lay.extend(start, size)
		next = if size >= 0 { pos + size } else { -1 }
	}
}

// occupied is the bytes a value of `size` bytes starting `bitpos` bits into its first byte spans:
// ceil((bitpos + bits) / 8) for a DATA-OBJECT-PROP, unknown (-1) for a bit position past that.
fn occupied(size int, bitpos int, dop_kind string) int {
	if bitpos == 0 || size < 0 {
		return size
	}
	if bitpos < 0 || dop_kind != 'DATA-OBJECT-PROP' {
		return -1
	}
	return (bitpos + size * 8 + 7) / 8
}

// extend counts a part of `size` bytes at `start` (-1: no fixed size) into the value's size.
fn (mut lay Layout) extend(start int, size int) {
	if size < 0 {
		lay.sized = false
		return
	}
	if start + size > lay.size {
		lay.size = start + size
	}
}

// const_end is the size in bytes of a non-VALUE parameter by its coded type; -1 when not fixed.
fn const_end(p flatxml.Node) int {
	if bl := int_of(p.child('DIAG-CODED-TYPE').child('BIT-LENGTH').text()) {
		if bl > 0 && bl % 8 == 0 {
			return int(bl / 8)
		}
	}
	if bl := int_of(p.child('BYTE-LENGTH').text()) {
		return int(bl)
	}
	return -1
}

// coded lays out one parameter of a DATA-OBJECT-PROP at `start`, returning its size in bytes (-1
// when not fixed); a coding this reader does not hold is said, the part's bytes still counted.
fn (mut lay Layout) coded(pname string, dop flatxml.Node, start int, unit string) int {
	dct := dop.child('DIAG-CODED-TYPE')
	if xsi_type(dct) != 'STANDARD-LENGTH-TYPE' {
		lay.why << '${pname}: a ${xsi_type(dct)} (no fixed length)'
		return -1
	}
	bits := int(int_of(dct.child('BIT-LENGTH').text()) or {
		lay.why << '${pname}: BIT-LENGTH "${dct.child('BIT-LENGTH').text()}" is not an integer'
		return -1
	})
	if bits <= 0 || bits % 8 != 0 {
		lay.why << '${pname}: ${bits} bits, not whole bytes'
		return -1
	}
	size := bits / 8
	base := dct.attr('BASE-DATA-TYPE')
	mut ok := true
	if dct.child('BIT-MASK').ok() {
		lay.why << '${pname}: a BIT-MASK'
		ok = false
	}
	if !dct.attr_bool('IS-HIGHLOW-BYTE-ORDER', true) && base in ['A_UINT32', 'A_INT32'] {
		lay.why << '${pname}: low byte first'
		ok = false
	}
	kind := match base {
		'A_UINT32' { PartKind.unsigned }
		'A_INT32' { PartKind.signed }
		'A_ASCIISTRING' { PartKind.text }
		'A_BYTEFIELD' { PartKind.bytes }
		else {
			lay.why << '${pname}: BASE-DATA-TYPE ${base}'
			ok = false
			PartKind.bytes
		}
	}
	if kind in [.unsigned, .signed] && size > 4 {
		lay.why << '${pname}: ${bits} bits, past the 32 an ${base} holds'
		ok = false
	}
	cm := dop.child('COMPU-METHOD')
	cat := cm.child('CATEGORY').text().trim_space()
	mut compu := Compu{}
	if cat in scaled_categories && kind in [.unsigned, .signed] {
		compu = compu_of(cat, cm, unit, mut lay.said) or {
			lay.why << '${pname}: ${err.msg()}'
			ok = false
			Compu{}
		}
	} else if cat != 'IDENTICAL' {
		lay.why << '${pname}: COMPU-METHOD ${if cat == '' { '(none)' } else { cat }}${if cat in scaled_categories {
			' of a ${base}'
		} else {
			''
		}}'
		ok = false
	}
	for c in ['INTERNAL-CONSTR', 'PHYS-CONSTR'] {
		if ok && dop.child(c).ok() {
			lay.said << '${pname}: its ${c} is not read; the codec holds the value to its coded type'
		}
	}
	if ok {
		lay.parts << Part{
			name:   pname
			kind:   kind
			offset: start
			size:   size
			compu:  compu
		}
	}
	return size
}

// the compu methods read beside IDENTICAL, on an integer part
const scaled_categories = ['LINEAR', 'SCALE-LINEAR', 'TEXTTABLE']

// compu_of reads a LINEAR, SCALE-LINEAR or TEXTTABLE method's COMPU-INTERNAL-TO-PHYS: refused, with
// the reason, for anything it does not hold; what it reads around is put in `said`.
fn compu_of(cat string, cm flatxml.Node, unit string, mut said []string) !Compu {
	itp := cm.child('COMPU-INTERNAL-TO-PHYS')
	scales := kids(itp.child('COMPU-SCALES'), 'COMPU-SCALE')
	if scales.len == 0 {
		return error('a ${cat} COMPU-METHOD with no COMPU-SCALE')
	}
	if cat == 'LINEAR' && scales.len != 1 {
		return error('a LINEAR COMPU-METHOD of ${scales.len} COMPU-SCALEs (it has one)')
	}
	mut segments := []Segment{}
	mut labels := []Label{}
	for s in scales {
		lo, hi := limits_of(s, cat == 'TEXTTABLE')!
		if cat == 'TEXTTABLE' {
			vt := s.child('COMPU-CONST').child('VT')
			if !vt.ok() {
				return error('a TEXTTABLE COMPU-SCALE with no COMPU-CONST/VT')
			}
			mut write := lo
			iv := s.child('COMPU-INVERSE-VALUE').child('V')
			if iv.ok() {
				w := int_of(iv.text()) or {
					return error('COMPU-INVERSE-VALUE "${iv.text()}" is not an integer')
				}
				write = w
			} else if lo == min_i64 {
				return error('the TEXTTABLE label "${vt.text().trim_space()}" has no lower limit to write')
			}
			labels << Label{lo, hi, vt.text().trim_space(), write}
			continue
		}
		coeffs := s.child('COMPU-RATIONAL-COEFFS')
		num := kids(coeffs.child('COMPU-NUMERATOR'), 'V')
		den := kids(coeffs.child('COMPU-DENOMINATOR'), 'V')
		if num.len != 2 {
			return error('a COMPU-NUMERATOR of ${num.len} term(s) (a linear scale has 2)')
		}
		if den.len > 1 {
			return error('a COMPU-DENOMINATOR of ${den.len} terms (a linear scale has 1)')
		}
		v0 := num_of(num[0].text())!
		v1 := num_of(num[1].text())!
		d := if den.len == 1 { num_of(den[0].text())! } else { 1.0 }
		if v1 == 0 {
			return error('a constant scale (V1 = 0), through which no value can be written')
		}
		if d == 0 {
			return error('a COMPU-DENOMINATOR of 0')
		}
		segments << Segment{lo, hi, v0, v1, d}
	}
	mut fallback := ''
	dv := itp.child('COMPU-DEFAULT-VALUE')
	if dv.ok() {
		if cat == 'TEXTTABLE' && dv.child('VT').ok() {
			fallback = dv.child('VT').text().trim_space()
		} else {
			said << 'its COMPU-DEFAULT-VALUE is not read: a raw value in no scale is refused'
		}
	}
	if cm.child('COMPU-PHYS-TO-INTERNAL').ok() {
		said << 'its COMPU-PHYS-TO-INTERNAL is not read: a value is written through the inverse of COMPU-INTERNAL-TO-PHYS'
	}
	return Compu{
		segments: segments
		labels:   labels
		fallback: fallback
		unit:     unit
	}
}

// limits_of is a COMPU-SCALE's raw range as integers (an OPEN limit excluded, an INFINITE or missing
// one unbounded); a TEXTTABLE scale with no UPPER-LIMIT is its LOWER-LIMIT alone.
fn limits_of(s flatxml.Node, table bool) !(i64, i64) {
	ln := s.child('LOWER-LIMIT')
	un := s.child('UPPER-LIMIT')
	lo := limit_of(ln, false)!
	hi := if !un.ok() && table && ln.ok() { limit_of(ln, true)! } else { limit_of(un, true)! }
	if lo > hi {
		return error('a COMPU-SCALE of no integer (${ln.text().trim_space()}..${un.text().trim_space()})')
	}
	return lo, hi
}

// limit_of is one limit as the integer bound it puts on a raw value: `upper` rounds down, a lower
// one up; missing or INFINITE is unbounded.
fn limit_of(n flatxml.Node, upper bool) !i64 {
	if !n.ok() || n.attr('INTERVAL-TYPE') == 'INFINITE' {
		return if upper { max_i64 } else { min_i64 }
	}
	v := num_of(n.text())!
	open := n.attr('INTERVAL-TYPE') == 'OPEN'
	b := if upper {
		if open { math.ceil(v) - 1 } else { math.floor(v) }
	} else {
		if open { math.floor(v) + 1 } else { math.ceil(v) }
	}
	if b >= 9.2e18 {
		return max_i64
	}
	if b <= -9.2e18 {
		return min_i64
	}
	return i64(b)
}

// num_of reads a finite decimal number, refused (naming its text) for anything else.
fn num_of(t string) !f64 {
	s := t.trim_space()
	v := strconv.atof64(s) or { return error('"${t}" is not a number') }
	if s == '' || math.is_nan(v) || math.is_inf(v, 0) {
		return error('"${t}" is not a number')
	}
	return v
}

// unit_of is the display name of a DATA-OBJECT-PROP's unit, '' for none.
fn (db &Db) unit_of(dop flatxml.Node) string {
	u := db.ref(dop.child('UNIT-REF')) or { return '' }
	dn := u.child('DISPLAY-NAME').text().trim_space()
	return if dn != '' { dn } else { short_name(u) }
}

// dop_of is the DOP a VALUE parameter names, by DOP-REF or by DOP-SNREF in the variant's layers
// (one a layer does not pass on left out).
fn (db &Db) dop_of(p flatxml.Node, res &Resolve) !flatxml.Node {
	r := p.child('DOP-REF')
	if r.ok() {
		return db.ref(r) or { error('DOP-REF "${r.attr('ID-REF')}" names nothing') }
	}
	s := p.child('DOP-SNREF')
	if s.ok() {
		want := s.attr('SHORT-NAME')
		for li, layer in res.chain {
			if want in res.dops[li] {
				continue
			}
			for section in layer.child('DIAG-DATA-DICTIONARY-SPEC').children() {
				for d in section.children() {
					if short_name(d) == want {
						return d
					}
				}
			}
		}
		return error('DOP-SNREF "${want}" names nothing in the variant')
	}
	return error('no DOP-REF')
}

// finish settles the value: its size, and whether its parts are back to back from byte 0.
fn (mut lay Layout) finish() {
	lay.finish_from(0)
}

fn (mut lay Layout) finish_from(start int) {
	if !lay.sized {
		lay.size = -1
	} else if lay.size < start {
		lay.size = start
	}
	if lay.size >= 0 {
		lay.size -= start
	}
	if lay.why.len > 0 {
		return
	}
	lay.parts.sort(a.offset < b.offset)
	mut end := start
	for q in lay.parts {
		if q.offset != end {
			lay.why << 'byte ${end - start} is in no parameter'
			return
		}
		end += q.size
	}
	if lay.size >= 0 && end - start != lay.size {
		lay.why << 'bytes ${end - start}..${lay.size - 1} are in no parameter'
	}
}

// name is what to call the value: its one value parameter's SHORT-NAME, else the service's.
fn (lay &Layout) name(service string) string {
	return if lay.values.len == 1 { lay.values[0] } else { service }
}

// dtcs are the DTCs of the variant's DTC-DOPs, nearest layer first: a DTC-DOP is overridden by a
// nearer one of its SHORT-NAME and left out where a layer does not pass it on, and a code given
// twice is read once.
fn (db &Db) dtcs(r &Resolve, mut notes []string) []Dtc {
	mut out := []Dtc{}
	mut seen := map[u32]bool{}
	mut seen_dops := map[string]bool{}
	for li, layer in r.chain {
		for dop in layer.child('DIAG-DATA-DICTIONARY-SPEC').child('DTC-DOPS').children_named('DTC-DOP') {
			dn := short_name(dop)
			if dn in seen_dops || dn in r.dops[li] {
				continue
			}
			seen_dops[dn] = true
			for c in dop.child('DTCS').children() {
				mut d := c
				if c.name() == 'DTC-REF' {
					d = db.ref(c) or {
						notes << 'DTC-REF "${c.attr('ID-REF')}" names nothing; not read'
						continue
					}
				}
				if d.name() != 'DTC' {
					continue
				}
				raw := d.child('TROUBLE-CODE').text()
				code := int_of(raw) or {
					notes << 'DTC ${short_name(d)}: TROUBLE-CODE "${raw}" is not an integer; not read'
					continue
				}
				if code <= 0 || code > 0xFFFFFF {
					notes << 'DTC ${short_name(d)}: TROUBLE-CODE ${code} is not a 3-byte DTC; not read'
					continue
				}
				if u32(code) in seen {
					continue
				}
				seen[u32(code)] = true
				out << Dtc{
					name:    short_name(d)
					code:    u32(code)
					display: d.child('DISPLAY-TROUBLE-CODE').text().trim_space()
					text:    d.child('TEXT').text().trim_space()
				}
			}
		}
	}
	return out
}
