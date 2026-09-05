// arxml — read an AUTOSAR 4.x system description (.arxml) into the candb model (#272).
//
// An ARXML is what an OEM hands an AUTOSAR ECU supplier, and often there is no DBC at all —
// or the DBC is a lossy export with the protection and timing stripped. So this is a SECOND
// database front end beside dbc.v: it produces the same `Database` the DBC parser does, one
// per CAN cluster, plus what a DBC has no home for (`ArxmlFrame`): the TX mode and timing of
// the PDU, its receivers, and the E2E and SecOC layout. It is an EXTRACTOR into the model
// that already exists, deliberately not a model of ARXML — the schema is enormous and a
// reader that mirrored it would be maintained forever.
//
// The split rule: `Message` carries what a DBC can say (ids, layout, senders, cycle time);
// `ArxmlFrame` carries the rest, keyed by the same identity the rest of candb uses — id and
// frame kind (`frame_key`), never the SHORT-NAME, which AUTOSAR scopes per package.
//
// The walk (System Template, 4.x element names — 3.x renamed half of them and is not shipped
// any more):
//
//   CAN-CLUSTER → CAN-PHYSICAL-CHANNEL → CAN-FRAME-TRIGGERING (id, addressing mode, FD)
//     → FRAME-REF → CAN-FRAME (length) → PDU-TO-FRAME-MAPPING (PDU offset)
//       → PDU-REF → I-SIGNAL-I-PDU (timing) → I-SIGNAL-TO-I-PDU-MAPPING (start, byte order)
//         → I-SIGNAL-REF → I-SIGNAL (length, base type) → SYSTEM-SIGNAL (scaling, description)
//           → COMPU-METHOD (factor/offset, enums), UNIT, DATA-CONSTR (range)
//     → FRAME-PORT-REF → ECU-INSTANCE (sender / receivers, by port direction)
//   ECU-INSTANCE → ASSOCIATED-COM-I-PDU-GROUP → I-SIGNAL-I-PDU-GROUP (the other sender answer)
//   END-TO-END-PROTECTION-SET → per protected I-SIGNAL-I-PDU: profile, data id, offsets
//   SECURED-I-PDU → freshness and MAC layout, then PAYLOAD-REF → the authentic I-SIGNAL-I-PDU
//
// Everything cross-references by package path (`/Pkg/Sub/Name`, in a `*-REF` element whose
// DEST names the target kind), so the reader first indexes every identifiable element (one
// with a SHORT-NAME) by its path and then follows references through that index.
//
// Read only; no schema validation. Two honesty rules instead, both in `ArxmlReport`:
//   1. a reference that does not resolve is REPORTED, by referrer and target — a dangling REF
//      is how an extract silently yields a frame with no signals;
//   2. what was ignored is COUNTED by element kind (container PDUs, LIN clusters, ...) — an
//      importer that quietly drops a PDU is worse than one that refuses.
// `load_arxml_file` caches the parse per file content: a real file is tens of MB and seconds
// to parse, and a project opens each channel's databases several times per Start.
//
// Bit numbering: an ARXML START-POSITION is the LSB for MOST-SIGNIFICANT-BYTE-LAST (Intel)
// and the MSB for MOST-SIGNIFICANT-BYTE-FIRST (Motorola), in byte-wise LSB-0 numbering —
// the same convention the DBC `@1` / `@0` start bit uses, and what `Signal.start_bit`
// holds, so the number is carried across as is (plus the PDU's own offset in the frame).
// cantools agrees (sut/arxml_oracle.py diffs the two against cmd/arxml2dbc --dump).
module candb

import crypto.sha256
import encoding.xml
import os
import sync
import time

// ArxmlE2e is the AUTOSAR end-to-end protection declared for one PDU. Offsets are in BITS as
// the file states them: `crc_offset`/`counter_offset` within the protected window (profiles
// 1 and 2), `offset` the window's header position (profiles 4 to 7, which declare ONE offset
// and a fixed header layout this reader does not model — `has_crc_counter` says which kind
// was declared). `pdu_offset` is where the PDU sits in its FRAME, so the byte positions below
// are frame-relative, which is what blobly_emb's `[[frame]].e2e` and #271's attributes take.
pub struct ArxmlE2e {
pub:
	profile         string // END-TO-END-PROFILE CATEGORY: PROFILE_01, PROFILE_02, PROFILE_05 …
	data_id         u32
	data_ids        []u32 // every declared DATA-ID (profile 1 may alternate between two)
	data_id_mode    string // DATA-ID-MODE (ALL-16-BIT, LOWER-12-BIT, LOWER-8-BIT, ALTERNATING-8-BIT) or ''
	has_crc_counter bool // CRC-OFFSET and COUNTER-OFFSET were declared (profiles 1/2/11/22)
	crc_offset      int // bits, within the data window
	counter_offset  int // bits, within the data window
	offset          int // bits, OFFSET of the fixed header (profiles 4/5/6/7), else 0
	data_offset     int // bits, where the protected window starts in the PDU
	data_length     int // bits
	pdu_offset      int // bits, where the PDU starts in the frame (PDU-TO-FRAME-MAPPING)
}

// crc_bit is the CRC's frame-relative bit position; crc_byte the byte it starts in.
pub fn (e ArxmlE2e) crc_bit() int {
	return e.pdu_offset + e.data_offset + e.crc_offset
}

pub fn (e ArxmlE2e) counter_bit() int {
	return e.pdu_offset + e.data_offset + e.counter_offset
}

pub fn (e ArxmlE2e) crc_byte() int {
	return e.crc_bit() / 8
}

pub fn (e ArxmlE2e) counter_byte() int {
	return e.counter_bit() / 8
}

// ArxmlSecOc is the SecOC layout of a SECURED-I-PDU: the authentic PDU, then the transmitted
// part of the freshness value, then the truncated MAC, packed BIT-contiguously and padded
// only at the end. `fresh_bit`/`mac_bit` are exact; the byte forms are what blobly_emb's
// `[[frame]].secoc` takes and are only meaningful when `byte_aligned` — a 4-bit freshness
// puts the MAC in the middle of a byte, and then no byte position is honest. The key is
// never in an ARXML.
pub struct ArxmlSecOc {
pub:
	data_id          u32
	freshness_len    int // FRESHNESS-VALUE-LENGTH, bits, the full counter
	freshness_tx_len int // FRESHNESS-VALUE-TX-LENGTH, bits actually on the wire
	auth_info_tx_len int // AUTH-INFO-TX-LENGTH, bits of MAC on the wire
	authentic_len    int // bytes of the authentic (payload) PDU
	pdu_offset       int // bits, where the secured PDU starts in the frame
	fresh_bit        int // FRAME-relative bit offset of the freshness value
	mac_bit          int // FRAME-relative bit offset of the MAC
	byte_aligned     bool // freshness and MAC both start on a byte boundary AND fill whole bytes
	fresh_byte       int
	mac_byte         int
	mac_len          int // bytes of MAC (exact when byte_aligned)
}

// ArxmlFrame is what the system description says about a message that a DBC has no field for.
pub struct ArxmlFrame {
pub mut:
	pdu           string // the I-SIGNAL-I-PDU short name behind the frame (or the secured PDU's)
	pdu_kind      string // DEST of the PDU behind the frame: I-SIGNAL-I-PDU, SECURED-I-PDU, N-PDU, NM-PDU …
	tx_mode       string // 'cyclic' | 'event' | 'mixed' | '' — from the transmission-mode timing
	cycle_ms      int
	min_delay_ms  int
	repetitions   int // event-controlled: a change is sent 1 + repetitions times …
	repetition_ms int // … this far apart. blobly_emb sends once; the fragment says so
	fd            bool // CAN-FRAME-TX-BEHAVIOR / RX-BEHAVIOR = CAN-FD
	receivers     []string // ECUs with an IN frame port, or an IN I-PDU group, for it
	e2e           ?ArxmlE2e
	secoc         ?ArxmlSecOc
}

// ArxmlCluster is one CAN cluster: the bus, its Database, and the per-message extras.
pub struct ArxmlCluster {
pub:
	name        string // the SHORT-NAME — package-scoped, so two clusters may share it
	path        string // the AUTOSAR path, unique
	bus         string // the collision-free identifier: the SHORT-NAME, or package-qualified when shared
	baudrate    int
	fd_baudrate int
	db          Database
	frames      map[string]ArxmlFrame // keyed by frame_key(id, ext)
}

// frame_key is the identity candb uses for a message everywhere else (merge.v, the trace):
// the id and the frame kind, never the name.
pub fn frame_key(id u32, ext bool) string {
	return '${id}|${ext}'
}

// frame_of returns the extras for a message of this cluster, if the file said anything.
pub fn (c ArxmlCluster) frame_of(m Message) ?ArxmlFrame {
	return c.frames[frame_key(m.id, m.ext)] or { return none }
}

// ArxmlReport carries the two honesty rules' output.
pub struct ArxmlReport {
pub mut:
	unresolved []string // "<referrer> <TAG> -> <target> (<DEST>)"
	ignored    map[string]int // element kind -> how many were seen and not extracted
	notes      []string // things extracted PARTIALLY, one line each
}

// lines renders the findings for a terminal or a log, one line each.
pub fn (r ArxmlReport) lines() []string {
	mut out := []string{}
	for u in r.unresolved {
		out << 'unresolved reference: ${u}'
	}
	mut kinds := r.ignored.keys()
	kinds.sort()
	for k in kinds {
		out << 'ignored: ${r.ignored[k]} × ${k}'
	}
	for n in r.notes {
		out << 'note: ${n}'
	}
	return out
}

// Arxml is a parsed system description.
pub struct Arxml {
pub:
	clusters []ArxmlCluster
	report   ArxmlReport
}

// cluster selects a CAN cluster by SHORT-NAME or by AUTOSAR path; '' means "the only one".
// Refused, naming the choices, when there are several and none is named, and when the name
// is one two packages share (a SHORT-NAME is package-scoped) — rather than picking the first,
// because a bus chosen silently is a database applied to the wrong wire.
pub fn (a Arxml) cluster(name string) !ArxmlCluster {
	if a.clusters.len == 0 {
		return error('no CAN cluster in the file')
	}
	if name == '' {
		if a.clusters.len > 1 {
			return error('${a.clusters.len} CAN clusters (${a.cluster_names().join(', ')}): name one')
		}
		return a.clusters[0]
	}
	mut hits := []ArxmlCluster{}
	for c in a.clusters {
		if c.path == name || c.bus == name {
			return c
		}
		if c.name == name {
			hits << c
		}
	}
	if hits.len == 1 {
		return hits[0]
	}
	if hits.len > 1 {
		return error('"${name}" names ${hits.len} CAN clusters: use ${hits.map(it.bus).join(' or ')}, or the path')
	}
	return error('no CAN cluster "${name}" (have ${a.cluster_names().join(', ')})')
}

// cluster_names lists the clusters by the identifier `cluster()` accepts and the export
// writes as the bus: the SHORT-NAME where unique, package-qualified where two packages
// share one (`A_Bus`, `B_Bus`) — an identifier, so it can be a `[bus.<name>]` in ecu.toml.
pub fn (a Arxml) cluster_names() []string {
	return a.clusters.map(it.bus)
}

// allocate_names gives every path in `paths` the name it goes by, in TWO passes: first every
// unique SHORT-NAME is reserved as itself, then every shared one is allocated its
// package-qualified form against that set. One pass in document order was not enough — with
// /A/Bus, /B/Bus and /C/A_Bus it handed `A_Bus` to /A/Bus and `A_Bus_2` to the cluster whose
// own name is A_Bus, so selecting the latter by its documented name loaded the former.
fn allocate_names(paths []string) map[string]string {
	mut count := map[string]int{}
	for p in paths {
		count[p.all_after_last('/')]++
	}
	mut taken := map[string]bool{}
	mut out := map[string]string{}
	for p in paths {
		short := p.all_after_last('/')
		if count[short] == 1 {
			out[p] = short
			taken[short] = true
		}
	}
	for p in paths {
		if p !in out {
			out[p] = claim_name(mut taken, package_qualified(p))
		}
	}
	return out
}

// allocate_names_first_keeps is allocate_names for frames and signals, whose rule since round 4
// is that the FIRST of a shared SHORT-NAME keeps it and the later ones are qualified — but, as
// for clusters and ECUs, every UNIQUE short name is reserved first, so a later frame whose own
// name is `B_F` is not renamed because an earlier duplicate took `B_F` as its qualified form
// (codex on #273 round 30). Document order decides only among the duplicates themselves.
fn allocate_names_first_keeps(paths []string) map[string]string {
	mut count := map[string]int{}
	for p in paths {
		count[p.all_after_last('/')]++
	}
	mut taken := map[string]bool{}
	mut out := map[string]string{}
	for p in paths {
		short := p.all_after_last('/')
		if count[short] == 1 {
			out[p] = short
			taken[short] = true
		}
	}
	mut first_seen := map[string]bool{}
	for p in paths {
		if p in out {
			continue
		}
		short := p.all_after_last('/')
		if short !in first_seen && short !in taken {
			first_seen[short] = true
			out[p] = claim_name(mut taken, short)
		} else {
			out[p] = claim_name(mut taken, package_qualified(p))
		}
	}
	return out
}

// name_clusters gives every cluster its `bus` identifier — see allocate_names.
fn (mut r ArxmlReader) name_clusters(clusters []ArxmlCluster) []ArxmlCluster {
	names := allocate_names(clusters.map(it.path))
	mut out := []ArxmlCluster{cap: clusters.len}
	for c in clusters {
		bus := names[c.path]
		if bus != c.name {
			r.report.notes << '${c.path}: cluster name ${c.name} is used by another package too; this one is ${bus}'
		}
		out << ArxmlCluster{
			...c
			bus: bus
		}
	}
	return out
}

// --- the per-file parse cache ---------------------------------------------------------------
struct ArxmlCached {
	sha string
	a   Arxml
	err string // a parse that FAILED for these bytes: remembered, so a broken file attached to a project is not reparsed on every rebuild (round 29)
}

__global (
	arxml_cache_mu       sync.Mutex
	arxml_cache          map[string]ArxmlCached
	arxml_cache_hits     int // parses answered from the cache — successes AND remembered failures
	// the keys a parse is RUNNING for: a second miss on one of them waits for that parse rather
	// than starting its own — a real file is seconds and hundreds of MB, and a project rebuild
	// overlapping a script reload would otherwise pay twice (codex on #273 round 28)
	arxml_cache_inflight map[string]bool
)

// load_arxml_file reads and parses a .arxml from disk, once per file CONTENT: the GUI and
// the headless runner open each channel's databases several times per Start, and a real
// system description costs seconds and hundreds of MB to parse, where reading and hashing it
// cost milliseconds. Keyed on the real path and the SHA-256 of the bytes — not size and
// mtime, which a same-length rewrite within one second defeats. Process-wide, never evicted:
// a bench holds one or two of these.
pub fn load_arxml_file(path string) !Arxml {
	text := os.read_file(path)!
	key := os.real_path(path)
	sha := sha256.hexhash(text)
	for {
		arxml_cache_mu.lock()
		if c := arxml_cache[key] {
			if c.sha == sha {
				arxml_cache_hits++
				arxml_cache_mu.unlock()
				if c.err != '' {
					return error(c.err)
				}
				return c.a
			}
		}
		if key !in arxml_cache_inflight {
			arxml_cache_inflight[key] = true
			arxml_cache_mu.unlock()
			break
		}
		// somebody is parsing this very file: wait for their answer instead of parsing it again
		arxml_cache_mu.unlock()
		time.sleep(10 * time.millisecond)
	}
	defer {
		arxml_cache_mu.lock()
		arxml_cache_inflight.delete(key)
		arxml_cache_mu.unlock()
	}
	a := parse_arxml(text) or {
		// remembered under the same path-and-content key, so repaired bytes retry and the
		// same broken bytes do not cost seconds and hundreds of MB per rebuild
		arxml_cache_mu.lock()
		arxml_cache[key] = ArxmlCached{
			sha: sha
			err: err.msg()
		}
		arxml_cache_mu.unlock()
		return err
	}
	arxml_cache_mu.lock()
	arxml_cache[key] = ArxmlCached{
		sha: sha
		a: a
	}
	arxml_cache_mu.unlock()
	return a
}

// arxml_cache_hit_count is how many loads the cache answered — for the test that pins it.
pub fn arxml_cache_hit_count() int {
	arxml_cache_mu.lock()
	defer {
		arxml_cache_mu.unlock()
	}
	return arxml_cache_hits
}

// parse_arxml parses ARXML text. Pure (no I/O) so it is directly unit-testable.
pub fn parse_arxml(text string) !Arxml {
	doc := xml.XMLDocument.from_string(text) or { return error('not XML: ${err}') }
	if lname(doc.root) != 'AUTOSAR' {
		return error('root element is <${doc.root.name}>, not <AUTOSAR>')
	}
	// the namespace the ROOT is in: the default one, or the one its prefix is bound to —
	// a 3.x file with a prefixed root must meet the same guard as one without
	prefix := if doc.root.name.contains(':') { doc.root.name.all_before(':') } else { '' }
	ns_attr := if prefix == '' { 'xmlns' } else { 'xmlns:${prefix}' }
	ns := doc.root.attributes[ns_attr] or { '' }
	if ns != '' && !ns.contains('autosar.org/schema/r4') {
		// 3.x (autosar.org/3.x.y) renames half the elements this walk names, so nothing
		// below would match — say so rather than returning an empty database
		return error('AUTOSAR schema ${ns} is not 4.x')
	}
	mut r := &ArxmlReader{}
	r.index_node(doc.root, '')
	r.count_ignored()
	r.name_ecus()
	r.load_e2e()
	r.load_pdu_groups()
	mut clusters := []ArxmlCluster{}
	for path in r.kinds['CAN-CLUSTER'] {
		clusters << r.load_cluster(path)
	}
	named := r.name_clusters(clusters)
	return Arxml{
		clusters: named
		report: r.report
	}
}

// --- the walk ----------------------------------------------------------------------------

// Element kinds seen in a file and deliberately not extracted. Counted whether or not a frame
// leads to them: the report is about the FILE, so a reader of it knows what the export lacks.
const arxml_ignored_kinds = [
	'LIN-UNCONDITIONAL-FRAME',
	'LIN-SPORADIC-FRAME',
	'LIN-EVENT-TRIGGERED-FRAME',
	'MULTIPLEXED-I-PDU',
	'CONTAINER-I-PDU',
	'N-PDU',
	'NM-PDU',
	'DCM-I-PDU',
	'USER-DEFINED-I-PDU',
	'GENERAL-PURPOSE-I-PDU',
	'GENERAL-PURPOSE-PDU',
	'I-SIGNAL-GROUP',
	'LIN-CLUSTER',
	'FLEXRAY-CLUSTER',
	'ETHERNET-CLUSTER',
	'J-1939-CLUSTER', // a whole bus, discarded; counted, or the file read as complete (round 28)
	'END-TO-END-PROTECTION-VARIABLE-PROTOTYPE',
	'SO-AD-ROUTING-GROUP',
	'SOCKET-CONNECTION-BUNDLE',
]

struct ArxmlReader {
mut:
	by_path map[string]xml.XMLNode // every identifiable element, by AUTOSAR path
	kinds   map[string][]string // element name -> paths, in document order
	e2e     map[string]ArxmlE2e // protected I-SIGNAL-I-PDU path -> its protection
	pdu_out map[string][]string // I-SIGNAL-I-PDU path -> ECUs whose OUT I-PDU group carries it
	pdu_in  map[string][]string // ... and whose IN group does
	compu   map[string]ArxmlScale // COMPU-METHOD path -> its scale, read once
	ecus    map[string]string // ECU-INSTANCE path -> the name it goes by (package-qualified when shared)
	report  ArxmlReport
}

// index_node registers every element that has a SHORT-NAME under the path its ancestors
// build. An element without one (a container such as ELEMENTS or FRAME-TRIGGERINGS) passes
// its parent's path down unchanged.
fn (mut r ArxmlReader) index_node(n xml.XMLNode, parent string) {
	mut path := parent
	if sn := child(n, 'SHORT-NAME') {
		path = '${parent}/${el_text(sn)}'
		r.by_path[path] = n
		r.kinds[lname(n)] << path
	}
	for c in n.children {
		if c is xml.XMLNode {
			r.index_node(c, path)
		}
	}
}

fn (mut r ArxmlReader) count_ignored() {
	for k in arxml_ignored_kinds {
		if paths := r.kinds[k] {
			if paths.len > 0 {
				r.report.ignored[k] = paths.len
			}
		}
	}
}

// deref follows a `*-REF` child of `n` named `tag`, returning the target and its path, and
// recording a dangling one against `from` (the referrer's path, for the report).
fn (mut r ArxmlReader) deref(n xml.XMLNode, tag string, from string) ?(xml.XMLNode, string) {
	ref := child(n, tag) or { return none }
	return r.deref_node(ref, from)
}

fn (mut r ArxmlReader) deref_node(ref xml.XMLNode, from string) ?(xml.XMLNode, string) {
	target := el_text(ref)
	if t := r.by_path[target] {
		return t, target
	}
	dest := ref.attributes['DEST'] or { '?' }
	r.report.unresolved << '${from} ${ref.name} -> ${target} (${dest})'
	return none
}

fn (r ArxmlReader) path_of(n xml.XMLNode, fallback string) string {
	// cheap identity for report lines: the SHORT-NAME, since a node does not know its path
	if sn := child(n, 'SHORT-NAME') {
		return '${fallback}/${el_text(sn)}'
	}
	return fallback
}

// ecu_of climbs a port path (/ECUs/ECU_A/Conn/PortOut) to the ECU-INSTANCE that owns it.
fn (r ArxmlReader) ecu_of(port_path string) ?string {
	mut p := port_path
	for p.len > 0 {
		if n := r.ecus[p] {
			return n
		}
		i := p.last_index('/') or { return none }
		p = p[..i]
	}
	return none
}

// package_qualified is the name a package-scoped SHORT-NAME goes by when another package
// uses the same one: the package path joined by `_`, then the name — `Other_F` for
// /Other/F. Identifier-safe, deterministic, and said in the report wherever it is applied.
fn package_qualified(path string) string {
	pkg := path.trim_left('/').all_before_last('/').replace('/', '_')
	return '${pkg}_${path.all_after_last('/')}'
}

// claim_name hands out `want` if nobody in this namespace has it, else `want_2`, `want_3`…
// — because package qualification alone is not injective (/A_B/F and /A/B_F both qualify to
// A_B_F, and a plain /C/A_Node is spelled like a qualified /A/Node), so every name is
// allocated against the set already given out. Deterministic in document order.
fn claim_name(mut taken map[string]bool, want string) string {
	mut name := want
	mut i := 2
	for (name in taken) {
		name = '${want}_${i}'
		i++
	}
	taken[name] = true
	return name
}

// name_ecus decides what every ECU-INSTANCE is called: its SHORT-NAME, unless another
// package has an ECU of the same SHORT-NAME — a legal AUTOSAR shape that, reduced to the
// last path component, would fold two ECUs into one sender and one `--ecu` selection.
fn (mut r ArxmlReader) name_ecus() {
	r.ecus = allocate_names(r.kinds['ECU-INSTANCE'])
	for p in r.kinds['ECU-INSTANCE'] {
		short := p.all_after_last('/')
		if r.ecus[p] == 'Vector__XXX' {
			// the DBC's placeholder for "no transmitter": an ECU that legitimately bears the
			// name would be normalised away by senders() and simulate nothing, and a DBC round
			// trip would lose it as the sender — so it gets a collision-free exported name and
			// a note (codex on #273 round 27)
			mut taken := map[string]bool{}
			for _, n in r.ecus {
				taken[n] = true
			}
			nn := claim_name(mut taken, package_qualified(p))
			r.ecus[p] = nn
			r.report.notes << '${p}: ECU name Vector__XXX is the DBC placeholder for "no transmitter"; this ECU is exported as ${nn}'
			continue
		}
		if r.ecus[p] != short {
			r.report.notes << '${p}: ECU name ${short} is used by another package too; this one is ${r.ecus[p]}'
		}
	}
}

// load_pdu_groups reads the SECOND way a system description says who sends and who listens:
// each ECU-INSTANCE's ASSOCIATED-COM-I-PDU-GROUP-REFS name I-SIGNAL-I-PDU-GROUPs with a
// COMMUNICATION-DIRECTION and the I-SIGNAL-I-PDUs in them (groups may contain groups). The
// first way is the FRAME-PORTs on the frame triggering; a file may carry either or both, and
// cantools reads only this one, so both are read and unioned.
fn (mut r ArxmlReader) load_pdu_groups() {
	for ecu_path in r.kinds['ECU-INSTANCE'] {
		ecu := r.by_path[ecu_path] or { continue }
		name := r.ecus[ecu_path] or { continue }
		for gref in descendants(ecu, 'ASSOCIATED-COM-I-PDU-GROUP-REF') {
			group, gpath := r.deref_node(gref, ecu_path) or { continue }
			r.collect_pdu_group(group, gpath, name, '', 0)
		}
	}
}

fn (mut r ArxmlReader) collect_pdu_group(group xml.XMLNode, group_path string, ecu string, dir_in string, depth int) {
	if depth > 8 {
		r.report.notes << '${group_path}: I-PDU groups nested deeper than 8, stopped'
		return
	}
	mut dir := child_text(group, 'COMMUNICATION-DIRECTION')
	if dir == '' {
		dir = dir_in
	}
	// DIRECT members only: a deep search would also visit a contained group's PDUs under
	// THIS group's direction, and the recursion below visits them again under their own —
	// an ECU that only receives a subgroup's PDU then transmitted it too
	if pdus := child(group, 'I-SIGNAL-I-PDUS') {
		for cond in children(pdus, 'I-SIGNAL-I-PDU-REF-CONDITIONAL') {
			pref := child(cond, 'I-SIGNAL-I-PDU-REF') or { continue }
			_, target := r.deref_node(pref, group_path) or { continue }
			if dir == 'OUT' {
				if ecu !in r.pdu_out[target] {
					r.pdu_out[target] << ecu
				}
			} else if dir == 'IN' {
				if ecu !in r.pdu_in[target] {
					r.pdu_in[target] << ecu
				}
			}
		}
	}
	if subs := child(group, 'CONTAINED-I-SIGNAL-I-PDU-GROUP-REFS') {
		for cref in children(subs, 'CONTAINED-I-SIGNAL-I-PDU-GROUP-REF') {
			sub, spath := r.deref_node(cref, group_path) or { continue }
			r.collect_pdu_group(sub, spath, ecu, dir, depth + 1)
		}
	}
}

// load_e2e collects every END-TO-END-PROTECTION into a map keyed by the protected PDU's path,
// so a frame can ask "is my PDU protected?" in one lookup.
fn (mut r ArxmlReader) load_e2e() {
	for set_path in r.kinds['END-TO-END-PROTECTION-SET'] {
		set := r.by_path[set_path] or { continue }
		for prot in descendants(set, 'END-TO-END-PROTECTION') {
			prot_path := r.path_of(prot, set_path)
			profile := child(prot, 'END-TO-END-PROFILE') or {
				r.report.notes << '${prot_path}: END-TO-END-PROTECTION without an END-TO-END-PROFILE, skipped'
				continue
			}
			mut ids := []u32{}
			for d in descendants(profile, 'DATA-ID') {
				ids << u32(parse_int(el_text(d)))
			}
			category := child_text(profile, 'CATEGORY')
			has_cc := child(profile, 'CRC-OFFSET') != none && child(profile, 'COUNTER-OFFSET') != none
			if !has_cc {
				r.report.notes << '${prot_path}: ${category} declares no CRC-OFFSET/COUNTER-OFFSET (a fixed-header profile); its layout is not modelled'
			}
			e := ArxmlE2e{
				profile: category
				data_id: if ids.len > 0 { ids[0] } else { 0 }
				data_ids: ids
				data_id_mode: child_text(profile, 'DATA-ID-MODE')
				has_crc_counter: has_cc
				crc_offset: parse_int(child_text(profile, 'CRC-OFFSET'))
				counter_offset: parse_int(child_text(profile, 'COUNTER-OFFSET'))
				offset: parse_int(child_text(profile, 'OFFSET'))
			}
			for tgt in descendants(prot, 'END-TO-END-PROTECTION-I-SIGNAL-I-PDU') {
				ref := child(tgt, 'I-SIGNAL-I-PDU-REF') or { continue }
				_, pdu_path := r.deref_node(ref, prot_path) or { continue }
				if pdu_path in r.e2e {
					r.report.notes << '${pdu_path}: protected by more than one END-TO-END-PROTECTION, the first is kept'
					continue
				}
				r.e2e[pdu_path] = ArxmlE2e{
					...e
					data_offset: parse_int(child_text(tgt, 'DATA-OFFSET'))
					data_length: parse_int(child_text(tgt, 'DATA-LENGTH'))
				}
			}
		}
	}
}

// ArxmlPorts accumulates who sends and who listens for one frame, from both sources (frame
// ports, I-PDU groups) through one rule: the first OUT ECU is the sender, later ones are
// additional transmitters, IN ECUs are receivers — each once.
struct ArxmlPorts {
mut:
	sender    string
	tx_nodes  []string
	receivers []string
}

fn (mut p ArxmlPorts) tx(ecu string) {
	if p.sender == '' {
		p.sender = ecu
	} else if ecu != p.sender && ecu !in p.tx_nodes {
		p.tx_nodes << ecu
	}
}

fn (mut p ArxmlPorts) rx(ecu string) {
	if ecu !in p.receivers {
		p.receivers << ecu
	}
}

fn note_node(mut nodes []string, ecu string) {
	if ecu !in nodes {
		nodes << ecu
	}
}

fn (mut r ArxmlReader) load_cluster(path string) ArxmlCluster {
	cl := r.by_path[path] or { return ArxmlCluster{} }
	name := path.all_after_last('/')
	// the bus parameters sit at CAN-CLUSTER-VARIANTS/CAN-CLUSTER-CONDITIONAL, and a
	// depth-first search from the cluster would walk every triggering to find them
	// A cluster may carry several CAN-CLUSTER-CONDITIONAL variants (a variant-rich system
	// description); the bus and the frames are read from the FIRST, because reading the bus
	// from one variant and the frames from all of them describes a bus that exists in no
	// variant. The others are reported, not merged.
	mut baud := 0
	mut fd_baud := 0
	mut scope := cl
	if variants := child(cl, 'CAN-CLUSTER-VARIANTS') {
		conds := descendants(variants, 'CAN-CLUSTER-CONDITIONAL')
		if conds.len > 0 {
			scope = conds[0]
			baud = parse_int(child_text(scope, 'BAUDRATE'))
			fd_baud = parse_int(child_text(scope, 'CAN-FD-BAUDRATE'))
		}
		if conds.len > 1 {
			r.report.notes << '${path}: ${conds.len} CAN-CLUSTER-CONDITIONAL variants; the first is read, the other ${conds.len - 1} are not'
		}
	}
	mut msgs := []Message{}
	mut frames := map[string]ArxmlFrame{}
	mut nodes := []string{}
	mut taken_names := map[string]bool{} // message names given out in this cluster
	mut fd_frames := 0
	mut classic_frames := 0
	// NAMES FIRST, over every frame this cluster triggers: a unique SHORT-NAME is reserved as
	// itself before any duplicate is qualified, as allocate_names does for clusters and ECUs.
	// One pass in document order handed `B_F` to the duplicate /B/F and then renamed the frame
	// whose own name is B_F to `C_B_F` (codex on #273 round 30). A second triggering of an id
	// already seen is skipped below and reserves nothing here.
	mut fpaths := []string{}
	mut seen_keys := map[string]bool{}
	for ft in descendants(scope, 'CAN-FRAME-TRIGGERING') {
		// a QUIET lookup: the loop below reports a dangling FRAME-REF once, and this pass must
		// not report it a second time
		fp := el_text(child(ft, 'FRAME-REF') or { continue })
		if fp !in r.by_path {
			continue
		}
		k := frame_key(u32(parse_int(child_text(ft, 'IDENTIFIER'))), child_text(ft, 'CAN-ADDRESSING-MODE') == 'EXTENDED')
		if k in seen_keys || fp in fpaths {
			continue
		}
		seen_keys[k] = true
		fpaths << fp
	}
	frame_names := allocate_names_first_keeps(fpaths)
	for ft in descendants(scope, 'CAN-FRAME-TRIGGERING') {
		ft_path := r.path_of(ft, path)
		frame, fpath := r.deref(ft, 'FRAME-REF', ft_path) or {
			if child(ft, 'FRAME-REF') == none {
				r.report.notes << '${ft_path}: CAN-FRAME-TRIGGERING without a FRAME-REF, skipped'
			}
			continue
		}
		mut fname := child_text(frame, 'SHORT-NAME')
		id := u32(parse_int(child_text(ft, 'IDENTIFIER')))
		ext := child_text(ft, 'CAN-ADDRESSING-MODE') == 'EXTENDED'
		key := frame_key(id, ext)
		if key in frames {
			r.report.notes << '${ft_path}: a second triggering for id 0x${id:X} (${fname}); the first is kept'
			continue
		}
		// a message NAME is an identity to everything downstream (the generator picker, the
		// protect: map), and AUTOSAR scopes a frame's SHORT-NAME per package — a second frame
		// of the same name at another id is qualified by its package, and said, rather than
		// shadowing the first
		want := frame_names[fpath] or { fname }
		claimed := claim_name(mut taken_names, want)
		if claimed != fname {
			r.report.notes << '${ft_path}: frame name ${fname} is already used by another id in this cluster; this one is ${claimed}'
			fname = claimed
		}
		dlc := parse_int(child_text(frame, 'FRAME-LENGTH'))
		mut info := ArxmlFrame{
			fd: child_text(ft, 'CAN-FRAME-TX-BEHAVIOR') == 'CAN-FD' || child_text(ft, 'CAN-FRAME-RX-BEHAVIOR') == 'CAN-FD'
		}

		// who sends, who listens: the frame ports on the triggering, by direction
		mut ports := ArxmlPorts{}
		for pref in descendants(ft, 'FRAME-PORT-REF') {
			port, port_path := r.deref_node(pref, ft_path) or { continue }
			ecu := r.ecu_of(port_path) or { continue }
			note_node(mut nodes, ecu)
			if child_text(port, 'COMMUNICATION-DIRECTION') == 'OUT' {
				ports.tx(ecu)
			} else {
				ports.rx(ecu)
			}
		}
		// and the I-PDU ports on the PDU triggerings this frame triggering references: a system
		// description may declare its endpoints there ALONE, with no frame ports at all, and a
		// frame with no sender simulates nothing (codex on #273 round 15). An OUT port sends the
		// frame; an IN port listens to ITS PDU only — so on a frame mapping several PDUs the IN
		// side is kept per PDU (by the triggering's I-PDU-REF) and reaches only that PDU's
		// signals, like an I-PDU group's receivers do, and the frame keeps the union (round 16)
		mut pdu_port_rx := map[string][]string{}
		for tref in descendants(ft, 'PDU-TRIGGERING-REF') {
			trig, trig_path := r.deref_node(tref, ft_path) or { continue }
			mut ipdu_path := ''
			if iref := child(trig, 'I-PDU-REF') {
				if _, ip := r.deref_node(iref, trig_path) {
					ipdu_path = ip
				}
			}
			for pref in descendants(trig, 'I-PDU-PORT-REF') {
				port, port_path := r.deref_node(pref, trig_path) or { continue }
				ecu := r.ecu_of(port_path) or { continue }
				note_node(mut nodes, ecu)
				if child_text(port, 'COMMUNICATION-DIRECTION') == 'OUT' {
					ports.tx(ecu)
				} else if ipdu_path == '' {
					ports.rx(ecu) // no PDU to scope it to: the frame's
				} else if ecu !in pdu_port_rx[ipdu_path] {
					pdu_port_rx[ipdu_path] << ecu
				}
			}
		}

		// the frame ports' receivers listen to the WHOLE frame; a PDU's I-PDU-group receivers
		// listen to that PDU's signals only, which is what the signals carry (a DBC states
		// receivers per signal) — the frame's receivers stay the union
		frame_rx := ports.receivers.clone()
		// the PDU behind the frame. A frame may map several; their signals all belong to the
		// message, but ArxmlFrame holds ONE timing and ONE protection, so the first PDU's are
		// kept and the rest are reported rather than letting document order decide silently.
		mut sigs := []Signal{}
		mut pdus := 0
		mut sig_paths := []string{} // one per entry of `sigs`: named LAST, over the whole message
		for pm in descendants(frame, 'PDU-TO-FRAME-MAPPING') {
			pref := child(pm, 'PDU-REF') or { continue }
			pdu, pdu_path := r.deref_node(pref, r.path_of(pm, '/' + fname)) or { continue }
			// A PDU is a byte array laid into the frame at a BYTE; its PACKING-BYTE-ORDER only
			// says how START-POSITION counts that byte — the LSB of it (MOST-SIGNIFICANT-
			// BYTE-LAST, bit 8k) or the MSB (MOST-SIGNIFICANT-BYTE-FIRST, bit 8k+7), and real
			// exports write 0 either way. Both land on byte k = position / 8, so the PDU's
			// bytes are never reversed by it. Verified on a SystemWeaver export whose only
			// CAN PDU is packed MSB-first: cantools reads it the same way. A position that
			// is neither is not byte-aligned, which no PDU layout is — said.
			pdu_pos := parse_int(child_text(pm, 'START-POSITION'))
			pdu_off := (pdu_pos / 8) * 8
			if pdu_pos % 8 != 0 && pdu_pos % 8 != 7 {
				r.report.notes << '${ft_path}: PDU ${child_text(pdu, 'SHORT-NAME')} starts at bit ${pdu_pos} of frame ${fname}, not on a byte; read from byte ${pdu_pos / 8}'
			}
			pdus++
			first_pdu := pdus == 1
			if !first_pdu {
				r.report.notes << "${ft_path}: frame ${fname} maps ${pdus} PDUs; the signals of ${child_text(pdu, 'SHORT-NAME')} are read, its timing and protection are not (the first PDU's are kept)"
			} else {
				info.pdu = child_text(pdu, 'SHORT-NAME')
				info.pdu_kind = pref.attributes['DEST'] or { lname(pdu) }
			}
			mut sig_pdu := pdu
			mut sig_pdu_path := pdu_path
			if (pref.attributes['DEST'] or { lname(pdu) }) == 'SECURED-I-PDU' {
				// the authentic PDU is behind PAYLOAD-REF -> PDU-TRIGGERING -> I-PDU-REF;
				// followed ONCE here, and handed to the layout reader
				trig, _ := r.deref(pdu, 'PAYLOAD-REF', pdu_path) or { continue }
				iref := child(trig, 'I-PDU-REF') or {
					r.report.notes << '${pdu_path}: PAYLOAD-REF target has no I-PDU-REF, no signals'
					continue
				}
				sig_pdu, sig_pdu_path = r.deref_node(iref, pdu_path) or { continue }
				if first_pdu {
					info.secoc = r.load_secoc(pdu, pdu_path, parse_int(child_text(sig_pdu, 'LENGTH')), pdu_off)
					if info.secoc != none {
						// CARRIED, NOT APPLIED, like E2E below — and with less behind it: the
						// native simulation has no SecOC stamping at all, so a simulated sender
						// of this frame puts its authentic bytes on the wire with freshness and
						// MAC as 0, which a conforming receiver rejects (round 18)
						r.report.notes << '${fname}: declares SecOC protection; carried to the fragment, but NOT applied by the native simulation, which has no SecOC stamping — freshness and MAC bytes go out as 0'
					}
				}
			}
			if lname(sig_pdu) != 'I-SIGNAL-I-PDU' {
				// N-PDU (ISO-TP), NM-PDU, container, multiplexed …: a real frame with a real
				// id, carried with no signals, exactly as a DBC would list it. Counted by
				// count_ignored, so nothing here is silent.
				continue
			}
			mut pdu_sigs, pdu_paths := r.load_signals(sig_pdu, sig_pdu_path, pdu_off)
			sig_paths << pdu_paths
			ubp := child_text(sig_pdu, 'UNUSED-BIT-PATTERN').trim_space()
			if ubp != '' && parse_int(ubp) != 0 {
				// the fill of every bit no signal maps; the simulated ECUs fill with 0, and a
				// checksum over the completed payload sees that 0 (codex on #273 round 15)
				r.report.notes << '${sig_pdu_path}: UNUSED-BIT-PATTERN ${ubp} is not modelled; the simulated ECUs fill unmapped bits with 0, which any checksum over the payload also sees'
			}
			mut pdu_rx := frame_rx.clone()
			for ecu in r.pdu_in[sig_pdu_path] {
				if ecu !in pdu_rx {
					pdu_rx << ecu
				}
			}
			// the I-PDU ports' IN side, scoped to this PDU: the triggering names the MAPPED PDU
			// (the secured one, for SecOC), the signals sit behind it — either key is this PDU
			for pk in [pdu_path, sig_pdu_path] {
				for ecu in pdu_port_rx[pk] {
					if ecu !in pdu_rx {
						pdu_rx << ecu
					}
				}
			}
			for mut s in pdu_sigs {
				s.receivers = pdu_rx.clone()
			}
			sigs << pdu_sigs
			if first_pdu {
				tm := r.load_timing(sig_pdu, sig_pdu_path)
				info.tx_mode = tm.tx_mode
				info.cycle_ms = tm.cycle_ms
				info.min_delay_ms = tm.min_delay_ms
				info.repetitions = tm.repetitions
				info.repetition_ms = tm.repetition_ms
				if tm.repetitions > 0 {
					// the bench simulates a change as one send; a receiver expecting the
					// declared burst sees fewer frames than the ECU would send
					r.report.notes << '${sig_pdu_path}: event-controlled timing repeats a change ${tm.repetitions} more times ${tm.repetition_ms} ms apart; the simulation sends once'
				}
				if tm.tx_mode == 'event' {
					// no cycle at all: the simulation sends on a cycle and so sends NOTHING for
					// this frame, where the ECU sends once per change (codex on #273 round 15)
					r.report.notes << '${sig_pdu_path}: event-controlled timing only, no cyclic timing; the simulation sends on a cycle and sends nothing for this frame'
				} else if tm.tx_mode == 'mixed' {
					// a cycle AND a send per change: the simulation keeps the cycle only, so a
					// change waits for the next cycle where the ECU sends at once (round 18)
					r.report.notes << '${sig_pdu_path}: cyclic and event-controlled timing; the simulation sends on the cycle only, never on a change'
				}
				if tm.offset_ms > 0 {
					// the phase between cyclic frames: the simulation starts every cyclic frame at
					// 0, and the fragment carries no phase either (round 18)
					r.report.notes << '${sig_pdu_path}: cyclic TIME-OFFSET ${tm.offset_ms} ms is not modelled; the simulation starts every cyclic frame at 0, and the fragment carries no phase'
				}
				if e := r.e2e[sig_pdu_path] {
					// CARRIED, NOT APPLIED: the contract reaches the DBC export's attributes and
					// the fragment, but the native simulation protects only what the project's
					// `protect:` entries name (dbc.v does not read the attributes back — #271), so
					// a simulated transmitter of this frame sends an unstamped counter and CRC
					// that the declared receiver rejects. Said, once per frame (round 17)
					r.report.notes << "${fname}: declares an E2E ${e.profile} contract; carried to the DBC export and the fragment, but NOT applied by the native simulation, which protects only what the project's protect: entries name"
					info.e2e = ArxmlE2e{
						...e
						pdu_offset: pdu_off
					}
				}
			}
			// the I-PDU-group answer to who sends and who listens, unioned with the ports'
			for ecu in r.pdu_out[sig_pdu_path] {
				note_node(mut nodes, ecu)
				ports.tx(ecu)
			}
			for ecu in r.pdu_in[sig_pdu_path] {
				note_node(mut nodes, ecu)
				ports.rx(ecu)
			}
			for pk in [pdu_path, sig_pdu_path] {
				for ecu in pdu_port_rx[pk] {
					ports.rx(ecu)
				}
			}
		}
		info.receivers = ports.receivers
		if info.fd {
			fd_frames++
		} else {
			classic_frames++
		}
		// NAMES LAST, over the whole message (round 30): a unique SHORT-NAME is reserved as itself
		// before any duplicate is qualified — one pass in mapping order gave the duplicate /B/V
		// the name `B_V` and renamed the signal whose own name is B_V. A signal name is how
		// everything downstream addresses it, and a DBC refuses a duplicate SG_, so what
		// allocate_names cannot separate (one signal mapped twice) claim_name still does
		// over the DISTINCT paths: one signal mapped twice is one allocation, and the claim
		// below is what tells the two mappings apart (`V`, `V_2`) — allocating per occurrence
		// let the second overwrite the first's name with a qualified one (round 31)
		mut distinct := []string{}
		for sp in sig_paths {
			if sp !in distinct {
				distinct << sp
			}
		}
		sig_names := allocate_names_first_keeps(distinct)
		mut taken_sigs := map[string]bool{}
		for i, mut s in sigs {
			wanted := sig_names[sig_paths[i]] or { s.name }
			given := claim_name(mut taken_sigs, wanted)
			if given != s.name {
				r.report.notes << '${sig_paths[i]}: signal name ${s.name} is already used in this message; this one is ${given}'
				s.name = given
			}
		}
		msg := Message{
			name: fname
			id: id
			ext: ext
			dlc: dlc
			sender: ports.sender
			tx_nodes: ports.tx_nodes
			cycle_ms: info.cycle_ms
			signals: sigs
		}
		if e := info.e2e {
			// what the DBC attributes cannot say, by the SAME predicate the export refuses with
			// (e2e_export_refusal): the fragment carries the contract, a DBC-only consumer never
			// sees the fragment, and the DBC would otherwise lose it without a word (rounds 26–27)
			why := e2e_export_refusal(msg, e)
			if why != '' {
				r.report.notes << '${fname}: the DBC export carries NO E2E attributes for it — ${why}; the fragment names the contract'
			}
		}
		msgs << msg
		frames[key] = info
	}
	if fd_frames > 0 && classic_frames > 0 {
		// Message carries no per-frame format, so on the bench the wire's policy decides
		// ONE format for every frame this cluster simulates; the export's VFrameFormat and
		// the fragment's per-frame comment are where the distinction survives
		r.report.notes << '${path}: ${fd_frames} CAN-FD and ${classic_frames} classic frames on one cluster; the simulation applies one format per bus, the export keeps the distinction'
	}
	return ArxmlCluster{
		name: name
		path: path
		baudrate: baud
		fd_baudrate: fd_baud
		db: Database{
			messages: msgs
			nodes: nodes
		}
		frames: frames
	}
}

struct ArxmlTiming {
	tx_mode       string
	cycle_ms      int
	offset_ms     int // CYCLIC-TIMING TIME-OFFSET: the phase, which nothing downstream carries
	min_delay_ms  int
	repetitions   int // EVENT-CONTROLLED-TIMING: how many repeats a change sends
	repetition_ms int // … and how far apart
}

// load_timing reads the TRUE transmission mode of an I-SIGNAL-I-PDU: cyclic if it has a
// CYCLIC-TIMING, event if an EVENT-CONTROLLED-TIMING, mixed if both. The FALSE mode (what
// the PDU does when its mode condition is off) is not read: COM's mode switching is ECU
// configuration, and a bench needs the cadence the bus is expected to carry.
fn (mut r ArxmlReader) load_timing(pdu xml.XMLNode, pdu_path string) ArxmlTiming {
	specs := descendants(pdu, 'I-PDU-TIMING')
	if specs.len > 1 {
		// timing per configuration variant: the first is read, like every other variant
		// container here, and the rest are said (codex on #273 round 28)
		r.report.notes << '${pdu_path}: ${specs.len} I-PDU-TIMING specifications; the first is read, the others are not'
	}
	spec := first(pdu, 'I-PDU-TIMING') or { return ArxmlTiming{} }
	if first(spec, 'TRANSMISSION-MODE-FALSE-TIMING') != none {
		// COM's mode switching is ECU configuration this reader does not evaluate, so the TRUE
		// mode's cadence is what the bus is expected to carry — said, since the false branch
		// may be the active one on a given ECU (codex on #273 round 29)
		r.report.notes << "${pdu_path}: declares a TRANSMISSION-MODE-FALSE-TIMING too; the TRUE mode's timing is read and the mode condition is not evaluated"
	}
	min_delay := r.timing_ms(first_text(spec, 'MINIMUM-DELAY'), pdu_path, 'MINIMUM-DELAY')
	tt := first(spec, 'TRANSMISSION-MODE-TRUE-TIMING') or {
		return ArxmlTiming{
			min_delay_ms: min_delay
		}
	}
	mut cycle := 0
	mut offset := 0
	mut mode := ''
	if ct := first(tt, 'CYCLIC-TIMING') {
		if tp := first(ct, 'TIME-PERIOD') {
			cycle = r.timing_ms(first_text(tp, 'VALUE'), pdu_path, 'TIME-PERIOD')
		}
		if to := first(ct, 'TIME-OFFSET') {
			offset = r.timing_ms(first_text(to, 'VALUE'), pdu_path, 'TIME-OFFSET')
		}
		mode = 'cyclic'
	}
	mut reps := 0
	mut rep_ms := 0
	if ev := first(tt, 'EVENT-CONTROLLED-TIMING') {
		mode = if mode == 'cyclic' { 'mixed' } else { 'event' }
		reps = parse_int(child_text(ev, 'NUMBER-OF-REPETITIONS'))
		if rp := first(ev, 'REPETITION-PERIOD') {
			rep_ms = r.timing_ms(first_text(rp, 'VALUE'), pdu_path, 'REPETITION-PERIOD')
		}
	}
	return ArxmlTiming{
		tx_mode: mode
		cycle_ms: cycle
		offset_ms: offset
		min_delay_ms: min_delay
		repetitions: reps
		repetition_ms: rep_ms
	}
}

// timing_ms converts a declared time to the model's whole milliseconds and SAYS when that
// loses something: a sub-millisecond period rounded to 0 would turn a cyclic frame into an
// event-driven one (period_ms <= 0 is "not cyclic" downstream), so a declared period is
// never less than 1 ms, and any value that is not a whole millisecond is noted.
fn (mut r ArxmlReader) timing_ms(s string, at string, what string) int {
	if s.trim_space() == '' {
		return 0
	}
	secs := parse_num(s)
	if secs <= 0 {
		return 0
	}
	ms := seconds_to_ms(s)
	exact := f64(ms) / 1000.0
	if ms == 0 {
		r.report.notes << '${at}: ${what} ${s} s is below a millisecond; read as 1 ms'
		return 1
	}
	if secs != exact {
		r.report.notes << '${at}: ${what} ${s} s is not a whole millisecond; read as ${ms} ms'
	}
	return ms
}

// load_secoc reads a SECURED-I-PDU's layout; `authentic` is the payload PDU's length in bytes
// (the caller has already followed PAYLOAD-REF, so a dangling one is reported once) and
// `pdu_off` where the secured PDU sits in its frame, so the positions are frame-relative.
fn (mut r ArxmlReader) load_secoc(pdu xml.XMLNode, pdu_path string, authentic int, pdu_off int) ?ArxmlSecOc {
	props := first(pdu, 'SECURE-COMMUNICATION-PROPS') or {
		r.report.notes << '${pdu_path}: SECURED-I-PDU without SECURE-COMMUNICATION-PROPS, layout unknown'
		return none
	}
	fresh_tx := parse_int(child_text(props, 'FRESHNESS-VALUE-TX-LENGTH'))
	auth_tx := parse_int(child_text(props, 'AUTH-INFO-TX-LENGTH'))
	payload_freshness := child(props, 'AUTH-DATA-FRESHNESS-START-POSITION') != none
	if payload_freshness {
		r.report.notes << '${pdu_path}: AUTH-DATA-FRESHNESS (freshness taken from the payload) is not modelled; no byte layout is given'
	}
	fresh_bit := pdu_off + authentic * 8
	mac_bit := fresh_bit + fresh_tx
	// a byte layout (blobly_emb's fresh_pos/mac_pos/mac_len) can state this only if the
	// freshness is the trailing one this model assumes, fills whole bytes, AND the MAC does:
	// a 28-bit MAC rounded up to 4 bytes would describe a 32-bit one
	aligned := !payload_freshness && fresh_tx % 8 == 0 && auth_tx % 8 == 0
	if fresh_tx % 8 != 0 {
		r.report.notes << '${pdu_path}: a ${fresh_tx}-bit freshness puts the MAC at bit ${mac_bit}, not on a byte boundary; no byte layout is given'
	} else if auth_tx % 8 != 0 {
		r.report.notes << '${pdu_path}: a ${auth_tx}-bit MAC does not fill whole bytes; no byte layout is given'
	}
	return ArxmlSecOc{
		data_id: u32(parse_int(child_text(props, 'DATA-ID')))
		freshness_len: parse_int(child_text(props, 'FRESHNESS-VALUE-LENGTH'))
		freshness_tx_len: fresh_tx
		auth_info_tx_len: auth_tx
		authentic_len: authentic
		pdu_offset: pdu_off
		fresh_bit: fresh_bit
		mac_bit: mac_bit
		byte_aligned: aligned
		fresh_byte: fresh_bit / 8
		mac_byte: mac_bit / 8
		mac_len: auth_tx / 8
	}
}

// load_signals reads every I-SIGNAL-TO-I-PDU-MAPPING of an I-SIGNAL-I-PDU. `pdu_off` is the
// PDU's bit offset inside the frame, added to each start position — it is byte-aligned in
// any real file, so it shifts an Intel and a Motorola start alike.
fn (mut r ArxmlReader) load_signals(pdu xml.XMLNode, pdu_path string, pdu_off int) ([]Signal, []string) {
	mut out := []Signal{}
	mut paths := []string{} // the I-SIGNAL path of each entry of `out`, for the naming pass
	for m in descendants(pdu, 'I-SIGNAL-TO-I-PDU-MAPPING') {
		// a signal-GROUP mapping has no I-SIGNAL-REF; its members are mapped individually
		isig, isig_path := r.deref(m, 'I-SIGNAL-REF', r.path_of(m, pdu_path)) or { continue }
		mut name := child_text(isig, 'SHORT-NAME')
		length := parse_int(child_text(isig, 'LENGTH'))
		if length > 64 {
			// the model decodes into a u64 and the DBC writer assumes a width-sized scalar:
			// a wider signal would lose its top bits in silence. Reported and left out — BEFORE
			// its name is claimed, or a supported signal of the same name behind it is renamed
			// for a collision with a signal the database does not contain (round 19)
			r.report.notes << '${isig_path}: ${length}-bit signal is wider than the 64-bit scalar model; not read'
			continue
		}
		paths << isig_path // named after the whole message is known — see the caller
		start := parse_int(child_text(m, 'START-POSITION')) + pdu_off
		if ub := child(m, 'UPDATE-BIT-POSITION') {
			// a receiver may treat the signal as not updated while the bit is clear, and a
			// simulated frame leaves every unlisted bit clear — said, since nothing sets it
			r.report.notes << '${isig_path}: declares an update bit at bit ${parse_int(el_text(ub)) + pdu_off}; not modelled, a simulated frame leaves it clear'
		}
		packing := child_text(m, 'PACKING-BYTE-ORDER')
		order := if packing == 'MOST-SIGNIFICANT-BYTE-FIRST' {
			ByteOrder.big_endian
		} else {
			ByteOrder.little_endian
		}
		opaque := packing == 'OPAQUE'
		if opaque {
			// a byte array, not a number: read as a little-endian integer the bytes round-trip
			// exactly, but the value has no numeric meaning and a factor or a range on it
			// would be fiction — said, so nobody scales it; and a COMPU-METHOD or DATA-CONSTR
			// the system signal carries is NOT applied either, or the bytes would be scaled on
			// the way out after all (round 20)
			r.report.notes << '${isig_path}: OPAQUE packing (a byte array) read as a little-endian integer; its value is not a quantity, and no compu method, unit or constraint is applied to it'
		}
		if iv := child(isig, 'INIT-VALUE') {
			// what the ECU transmits before the first write. The model has no place for it (a
			// DBC's GenSigStartValue is not read either), so the simulated ECUs start every
			// unconfigured signal at raw 0 — a nonzero declaration is a payload that differs
			// from the file, and is said. Judged by the DIRECT form: a deep search for a VALUE
			// would read a TEXT-VALUE's label as 0 and an ARRAY's first element as the whole.
			// Zero is what the frame does anyway. After the width guard, so nothing is said
			// about the simulated outcome of a signal the model does not carry
			if num := child(iv, 'NUMERICAL-VALUE-SPECIFICATION') {
				ivt := child_text(num, 'VALUE').trim_space()
				if parse_num(ivt) != 0 {
					r.report.notes << '${isig_path}: declares an initial value of ${ivt}; not modelled, the simulated ECUs start it at raw 0'
				}
			} else {
				r.report.notes << '${isig_path}: declares an initial value in a form not read (not a NUMERICAL-VALUE-SPECIFICATION); not modelled, the simulated ECUs start it at raw 0'
			}
		}

		// base type: signedness (and the one encoding this model cannot hold). The props
		// may come in several variants (a variation point); the first is read and the
		// rest are reported, since nothing here evaluates a variation condition
		mut is_signed := false
		props := first(isig, 'SW-DATA-DEF-PROPS-CONDITIONAL') or {
			xml.XMLNode{
				name: ''
			}
		}
		r.note_variants(isig, isig_path)
		if bt, _ := r.deref(props, 'BASE-TYPE-REF', isig_path) {
			enc := first_text(bt, 'BASE-TYPE-ENCODING')
			if enc == '2C' {
				is_signed = true
			} else if enc == '1C' || enc == 'SM' {
				// one's complement and sign-magnitude are signed, but the model decodes
				// two's complement only: negative values come out wrong by one (1C) or as
				// large negatives (SM). Said, since a raw value that decodes wrong in
				// silence is the worst kind
				is_signed = true
				r.report.notes << "${isig_path}: ${enc} encoding is not modelled; decoded as two's complement, so negative values are wrong"
			} else if enc.starts_with('IEEE754') {
				r.report.notes << '${isig_path}: IEEE754 (floating-point) signal read as an unsigned integer'
			} else if enc != '' && enc != 'NONE' && enc != 'BOOLEAN' {
				// BCD-P, BCD-UP, DSP-FRACTIONAL, the string encodings, VOID: none of them is a
				// binary integer, and 0x12 read as one is 18 where packed BCD means 12. Said,
				// like the three above, rather than silently binary (codex on #273 round 15)
				r.report.notes << '${isig_path}: BASE-TYPE-ENCODING ${enc} is not modelled; read as an unsigned binary integer'
			}
		}

		// scaling and enums: the compu method on the SYSTEM-SIGNAL's physical props (where the
		// standard puts the physical meaning, and the only place cantools looks), else the one
		// on the I-SIGNAL's network representation. Unit: the physical props' own, else the
		// compu method's, else the network representation's.
		mut factor := 1.0
		mut offset := 0.0
		mut values := map[u64]string{}
		mut unit := ''
		mut minimum := 0.0
		mut maximum := 0.0
		mut sys_path := ''
		mut phys := xml.XMLNode{
			name: ''
		}
		mut sys := xml.XMLNode{
			name: ''
		}
		if s, sp := r.deref(isig, 'SYSTEM-SIGNAL-REF', isig_path) {
			sys = s
			sys_path = sp
			if pp := first(s, 'PHYSICAL-PROPS') {
				phys = first(pp, 'SW-DATA-DEF-PROPS-CONDITIONAL') or { phys }
				r.note_variants(pp, sp)
			}
		}
		mut cm := xml.XMLNode{
			name: ''
		}
		mut cm_path := ''
		if opaque {
			// a byte array has no scale, no enum, no unit
		} else if c, cp := r.deref(phys, 'COMPU-METHOD-REF', sys_path) {
			cm = c
			cm_path = cp
		} else if c, cp := r.deref(props, 'COMPU-METHOD-REF', isig_path) {
			cm = c
			cm_path = cp
		}
		mut scale := ArxmlScale{}
		if cm_path != '' {
			scale = r.load_compu(cm, cm_path)
			factor = scale.factor
			offset = scale.offset
			// the table is cached UNMASKED (one method serves signals of several widths):
			// the width-sized raw pattern, which is what raw_value produces, is this signal's
			mask := if length >= 64 { ~u64(0) } else { (u64(1) << length) - 1 }
			for k, v in scale.values {
				// ONLY KEYS THIS WIDTH CAN HOLD: masking every key aliased 256 onto raw 0 of an
				// 8-bit signal and labelled a value the table never named (codex round 16). A
				// non-negative key fits below the mask; a signed signal also takes a negative
				// one — a sign-extended pattern with the width's top bit set
				// BY THE LITERAL'S SIGN, which the pattern alone cannot say at width 64 (-2^63
				// and +2^63 are one pattern): a negative literal fits a SIGNED width whose top
				// bit it sets and whose upper bits it sign-extends; a non-negative one fits a
				// signed width below its top bit (200 in an 8-bit signed signal is 0xC8, which
				// decodes as -56) and an unsigned one up to its mask (rounds 17–18)
				top := if length >= 64 { u64(1) << 63 } else { u64(1) << (length - 1) }
				fits := if is_signed { k < top } else { k <= mask }
				if !fits {
					sgn := if is_signed { 'signed' } else { 'unsigned' }
					r.report.notes << '${isig_path}: enum key ${k} ("${v}") of ${cm_path} does not fit a ${length}-bit ${sgn} signal; dropped'
					continue
				}
				values[k & mask] = v
			}
			for k, v in scale.neg_values {
				top := if length >= 64 { u64(1) << 63 } else { u64(1) << (length - 1) }
				if !(is_signed && (k | mask) == ~u64(0) && (k & top) != 0) {
					sgn := if is_signed { 'signed' } else { 'unsigned' }
					r.report.notes << '${isig_path}: enum key ${i64(k)} ("${v}") of ${cm_path} does not fit a ${length}-bit ${sgn} signal; dropped'
					continue
				}
				values[k & mask] = v
			}
		}
		if opaque {
		} else if u, _ := r.deref(phys, 'UNIT-REF', sys_path) {
			unit = first_text(u, 'DISPLAY-NAME')
		}
		if unit == '' && cm_path != '' {
			if u, _ := r.deref(cm, 'UNIT-REF', cm_path) {
				unit = first_text(u, 'DISPLAY-NAME')
			}
		}
		if unit == '' && !opaque {
			if u, _ := r.deref(props, 'UNIT-REF', isig_path) {
				unit = first_text(u, 'DISPLAY-NAME')
			}
		}

		// range: a data constraint's physical limits, else its internal ones scaled, else the
		// domain of the linear compu scale (raw) scaled — the last being cantools' answer
		mut dc := xml.XMLNode{
			name: ''
		}
		mut has_dc := false
		if opaque {
			// nor a range
		} else if d, _ := r.deref(phys, 'DATA-CONSTR-REF', sys_path) {
			dc = d
			has_dc = true
		} else if d, _ := r.deref(props, 'DATA-CONSTR-REF', isig_path) {
			dc = d
			has_dc = true
		}
		if has_dc {
			d := dc
			rules := descendants(d, 'DATA-CONSTR-RULE').len
			if rules > 1 {
				// several rules (per constraint level, typically): the first physical — else the
				// first internal — constraint found is read as THE range, and the rest are not
				// weighed (round 23)
				r.report.notes << '${isig_path}: the data constraint has ${rules} DATA-CONSTR-RULEs; the first physical (else internal) constraint is read as the range, the others are not'
			}
			if first(d, 'SCALE-CONSTRS') != none {
				// restricted or disjoint sub-intervals inside the bounds: the range model is one
				// interval, so the gaps between them are advertised as valid (round 19)
				r.report.notes << '${isig_path}: the data constraint has SCALE-CONSTRS (sub-intervals) which the single-interval range model cannot hold; only the outer bounds are read'
			}
			if pc := first(d, 'PHYS-CONSTRS') {
				minimum = parse_num(child_text(pc, 'LOWER-LIMIT'))
				maximum = parse_num(child_text(pc, 'UPPER-LIMIT'))
				r.note_open_bounds(pc, isig_path)
			} else if ic := first(d, 'INTERNAL-CONSTRS') {
				minimum, maximum = scaled_range(parse_num(child_text(ic, 'LOWER-LIMIT')), parse_num(child_text(ic, 'UPPER-LIMIT')), factor, offset)
				r.note_open_bounds(ic, isig_path)
			}
		} else if scale.has_domain {
			minimum, maximum = scaled_range(scale.lower, scale.upper, factor, offset)
			for f in scale.domain_open {
				r.report.notes << "${isig_path}: the compu scale's ${f}; read as a closed (inclusive) bound, which the range model is"
			}
		}

		// description: the system signal's, else the I-SIGNAL's own
		mut desc := r.desc_of(sys, sys_path)
		if desc == '' {
			desc = r.desc_of(isig, isig_path)
		}

		out << Signal{
			name: name
			start_bit: start
			length: length
			factor: factor
			offset: offset
			minimum: minimum
			maximum: maximum
			unit: unit
			desc: desc
			values: values
			is_signed: is_signed
			byte_order: order
		}
	}
	return out, paths
}

// note_variants reports a SW-DATA-DEF-PROPS-VARIANTS with more than one conditional: the
// reader takes the first and says so, rather than letting document order choose a signal's
// signedness or scaling without a word.
fn (mut r ArxmlReader) note_variants(n xml.XMLNode, at string) {
	if v := first(n, 'SW-DATA-DEF-PROPS-VARIANTS') {
		conds := children(v, 'SW-DATA-DEF-PROPS-CONDITIONAL')
		if conds.len > 1 {
			r.report.notes << '${at}: ${conds.len} SW-DATA-DEF-PROPS-CONDITIONAL variants; the first is read'
		}
	}
}

struct ArxmlScale {
	factor f64 = 1.0
	offset f64
	values map[u64]string // UNMASKED raw values: one method serves signals of several widths
	// the keys spelled with a minus sign, KEPT APART: -1 and 2^64-1 are one u64 pattern, and one
	// method shared by a signed and an unsigned 64-bit signal may name both (round 21)
	neg_values  map[u64]string
	has_domain  bool // the linear scale declared LOWER-LIMIT/UPPER-LIMIT (raw)
	domain_open []string // which of those bounds is OPEN/INFINITE: said by the signal that uses the domain
	lower       f64
	upper       f64
}

// scaled_range maps a raw interval to physical and ORDERS it: a negative factor turns the raw
// lower limit into the physical maximum.
fn scaled_range(lo f64, hi f64, factor f64, offset f64) (f64, f64) {
	a := lo * factor + offset
	b := hi * factor + offset
	if a <= b {
		return a, b
	}
	return b, a
}

// load_compu reads a COMPU-METHOD's internal-to-physical scales, once per method (OEM files
// share one enum table across thousands of signals): one LINEAR scale gives the factor and
// offset (numerator V0 = offset, V1 = factor, over denominator V0); TEXTTABLE scales with
// equal limits give the enum; SCALE_LINEAR_AND_TEXTTABLE gives both. A rational function
// with a non-constant denominator is not a factor/offset and is noted — once.
fn (mut r ArxmlReader) load_compu(cm xml.XMLNode, cm_path string) ArxmlScale {
	if s := r.compu[cm_path] {
		return s
	}
	mut factor := 1.0
	mut offset := 0.0
	mut values := map[u64]string{}
	mut neg_values := map[u64]string{}
	mut linear_seen := false
	mut has_domain := false
	mut lower := 0.0
	mut upper := 0.0
	mut domain_open := []string{}
	// a BITFIELD_TEXTTABLE labels raw values by MASK, so one label applies to every raw value
	// that matches under it — which a value table keyed by exact raw value cannot say. Said
	// once, and its labels are NOT filed as exact keys (codex on #273 round 15)
	masked := child_text(cm, 'CATEGORY') == 'BITFIELD_TEXTTABLE' || descendants(cm, 'MASK').len > 0
	if masked {
		r.report.notes << '${cm_path}: a masked bitfield text table (BITFIELD_TEXTTABLE / MASK) is not modelled; its labels are dropped'
	}
	if itp := first(cm, 'COMPU-INTERNAL-TO-PHYS') {
		for s in descendants(itp, 'COMPU-SCALE') {
			lo := child_text(s, 'LOWER-LIMIT')
			hi := child_text(s, 'UPPER-LIMIT')
			if k := first(s, 'COMPU-CONST') {
				if masked {
					continue
				}
				if child(k, 'VT') == none {
					// a NUMERIC constant (TAB-NOINTP: raw 0 means physical 10) is a lookup
					// this model has no home for — a label would be empty and the value
					// would decode as its raw self
					r.report.notes << '${cm_path}: a numeric lookup table (COMPU-CONST/V) is not modelled; read as factor 1 offset 0'
					continue
				}
				label := first_text(k, 'VT')
				// a singleton is two INTEGRAL bounds spelling one integer: `1.1`..`1.9` both
				// truncate to raw 1 and would file a label for a range that EXCLUDES raw 1
				singleton := lo != '' && hi != '' && integral_literal(lo) && integral_literal(hi)
				klo := key_of(lo)
				khi := key_of(hi)
				if klo == none || khi == none {
					// past what a 64-bit raw key holds: the 0 fallback filed the label on raw
					// zero, an out-of-domain label on a value the table never named (round 20)
					r.report.notes << '${cm_path}: the bounds ${lo}..${hi} of "${label}" do not fit a 64-bit raw key; dropped'
					continue
				}
				k_lo := klo or { 0 }
				k_hi := khi or { 0 }
				// the SIGN is part of the value: `-1` and `18446744073709551615` are one u64
				// pattern and two integers, so a range between them is not a singleton (round 22).
				// `-0` is zero: a sign with no sign bit
				neg_lo := lo.trim_space().starts_with('-') && k_lo != 0
				neg_hi := hi.trim_space().starts_with('-') && k_hi != 0
				if singleton && neg_lo == neg_hi && k_lo == k_hi {
					if neg_lo {
						neg_values[k_lo] = label
					} else {
						values[k_lo] = label
					}
				} else {
					r.report.notes << '${cm_path}: maps the range ${lo}..${hi} to "${label}", which a value table (one exact raw value per label) cannot express; dropped'
				}
				continue
			}
			if rc := first(s, 'COMPU-RATIONAL-COEFFS') {
				mut num := []f64{}
				mut den := []f64{}
				if nn := first(rc, 'COMPU-NUMERATOR') {
					for v in descendants(nn, 'V') {
						num << parse_num(el_text(v))
					}
				}
				if dd := first(rc, 'COMPU-DENOMINATOR') {
					for v in descendants(dd, 'V') {
						den << parse_num(el_text(v))
					}
				}
				d := if den.len > 0 { den[0] } else { 1.0 }
				// linear means: every denominator coefficient past the constant is zero, and
				// every numerator coefficient past the linear one is — any later nonzero term
				// is a curve, whatever the ones before it are
				if den.len > 1 && den[1..].any(it != 0) {
					r.report.notes << '${cm_path}: a rational function (non-constant denominator), read as factor 1 offset 0'
					continue
				}
				if num.len > 2 && num[2..].any(it != 0) {
					r.report.notes << '${cm_path}: a polynomial of degree ${num.len - 1}, read as factor 1 offset 0'
					continue
				}
				if linear_seen {
					r.report.notes << '${cm_path}: more than one linear scale, the first is kept'
					continue
				}
				linear_seen = true
				if d != 0 {
					offset = if num.len > 0 { num[0] / d } else { 0.0 }
					// a one-term numerator is a CONSTANT: every raw value maps to it, which no
					// factor/offset pair can say (factor 0 divides by zero on encode). Not
					// modelled: said, and the raw value is what decodes
					// … in either spelling: a one-term numerator, or a linear term of ZERO, which
					// is the same constant and would otherwise become factor 0 and a division
					// by zero on encode (round 21)
					if num.len == 1 || num[1] == 0 {
						r.report.notes << '${cm_path}: a constant conversion (every raw value is ${fmt_num(num[0])}) is not modelled; read as factor 1 offset 0'
						offset = 0.0
						factor = 1.0
					} else {
						factor = num[1] / d
					}
				}
				if lo != '' && hi != '' {
					has_domain = true
					lower = parse_num(lo)
					upper = parse_num(hi)
					// the scale's domain becomes the signal's range when no data constraint
					// overrides it, so an OPEN or INFINITE bound here is the same lost meaning
					// the constraint path reports — CARRIED, and said only by a signal that
					// selects this domain: a method whose every user has a constraint is not a
					// partial read (rounds 24–25)
					domain_open = open_bound_facts(s)
				}
			}
		}
	}
	if dv := first(cm, 'COMPU-DEFAULT-VALUE') {
		// the label for every raw value no scale names: a value table has no default entry, so
		// those values decode as their number in the editor and the export (round 19)
		r.report.notes << '${cm_path}: declares a COMPU-DEFAULT-VALUE ("${first_text(dv, 'VT')}${first_text(dv, 'V')}") for raw values no scale names; not modelled, those values decode as their number'
	}
	if first(cm, 'COMPU-INTERNAL-TO-PHYS') == none && first(cm, 'COMPU-PHYS-TO-INTERNAL') != none {
		// the inverse direction only: not inverted here (a linear inverse is invertible, but a
		// table or a curve is not, and one rule for the direction beats two), and the identity
		// it falls back to is said rather than silently applied to every signal on the method
		r.report.notes << '${cm_path}: gives only a physical-to-internal conversion (COMPU-PHYS-TO-INTERNAL); not inverted, read as factor 1 offset 0'
	}
	sc := ArxmlScale{
		factor: factor
		offset: offset
		values: values
		neg_values: neg_values
		has_domain: has_domain
		domain_open: domain_open
		lower: lower
		upper: upper
	}
	r.compu[cm_path] = sc
	return sc
}

// --- XML helpers ---------------------------------------------------------------------------

// lname is an element's LOCAL name: a document may bind the AUTOSAR namespace to a prefix
// (`<ar:AUTOSAR xmlns:ar=…>`), and a prefix is the author's choice, not part of the name.
// Every comparison of an element name in this file goes through it.
fn lname(n xml.XMLNode) string {
	return n.name.all_after_last(':')
}

// descendants returns every element named `name` below `n` (not `n` itself), document
// order, by LOCAL name — vlib's get_elements_by_tag compares the prefixed name, and a
// document that binds the namespace to a prefix would then have no frames at all.
fn descendants(n xml.XMLNode, name string) []xml.XMLNode {
	mut out := []xml.XMLNode{}
	for c in n.children {
		if c is xml.XMLNode {
			if lname(c) == name {
				out << c
			}
			out << descendants(c, name)
		}
	}
	return out
}

// child returns the first DIRECT child element named `name`.
fn child(n xml.XMLNode, name string) ?xml.XMLNode {
	for c in n.children {
		if c is xml.XMLNode {
			if lname(c) == name {
				return c
			}
		}
	}
	return none
}

// children returns the DIRECT child elements named `name`, document order.
fn children(n xml.XMLNode, name string) []xml.XMLNode {
	mut out := []xml.XMLNode{}
	for c in n.children {
		if c is xml.XMLNode {
			if lname(c) == name {
				out << c
			}
		}
	}
	return out
}

fn child_text(n xml.XMLNode, name string) string {
	c := child(n, name) or { return '' }
	return el_text(c)
}

// first returns the first element named `name` anywhere below `n`, document order.
fn first(n xml.XMLNode, name string) ?xml.XMLNode {
	for c in n.children {
		if c is xml.XMLNode {
			if lname(c) == name {
				return c
			}
			if f := first(c, name) {
				return f
			}
		}
	}
	return none
}

fn first_text(n xml.XMLNode, name string) string {
	c := first(n, name) or { return '' }
	return el_text(c)
}

// desc_text reads a DESC's first language entry.
// desc_of is desc_text with the report: a DESC in several languages keeps its first entry only
// — Signal.desc is one string — and says so, since the other translations do not reach the
// database or the export (codex on #273 round 27).
fn (mut r ArxmlReader) desc_of(n xml.XMLNode, path string) string {
	if d := child(n, 'DESC') {
		langs := descendants(d, 'L-2')
		if langs.len > 1 {
			first := langs[0].attributes['L'] or { '?' }
			r.report.notes << '${path}: the description has ${langs.len} languages; only the first (${first}) is kept'
		}
	}
	return desc_text(n)
}

fn desc_text(n xml.XMLNode) string {
	d := child(n, 'DESC') or { return '' }
	l := first(d, 'L-2') or { return '' }
	// a description may carry inline markup (<E>, <TT>, …): every descendant's text, in
	// document order, is the description — the leaf-only read dropped the marked-up words
	return xml_unescape(deep_text(l).trim_space())
}

// closing_punctuation: what the source cannot have had a space before, so no reconstructed
// boundary space goes there
const closing_punctuation = [u8(`.`), `,`, `;`, `:`, `!`, `?`, `)`, `]`]

fn deep_text(n xml.XMLNode) string {
	mut s := ''
	for c in n.children {
		chunk := match c {
			string { c }
			xml.XMLNode { deep_text(c) }
			else { '' }
		}
		if chunk == '' {
			continue
		}
		// the parser trims the text on either side of an inline element, so "over <E>all</E>
		// bytes" arrives as three chunks with no boundary space: put one back where both
		// sides lack it — except where the source cannot have had one, before closing
		// punctuation ("use <E>foo</E>." is "use foo.", not "use foo .") and after an opening
		// bracket. The trim took the boundary; this is the honest reconstruction of it
		opens := s.ends_with('(') || s.ends_with('[')
		closes := chunk[0] in closing_punctuation
		if s != '' && !s.ends_with(' ') && !chunk.starts_with(' ') && !opens && !closes {
			s += ' '
		}
		s += chunk
	}
	return s
}

// el_text is the element's own text, trimmed, with entities decoded — vlib's parser hands
// them through undecoded, and its own decoder is the one that undoes them. A reference it
// does not know (a numeric one, say) fails the whole decode, and the raw text is then the
// honest answer rather than nothing.
fn el_text(n xml.XMLNode) string {
	mut s := ''
	for c in n.children {
		if c is string {
			s += c
		}
	}
	return xml_unescape(s.trim_space())
}

fn xml_unescape(s string) string {
	if !s.contains('&') {
		return s
	}
	return xml.unescape_text(s) or { s }
}

// parse_int reads an ARXML integer: decimal, 0x hex, or a float that happens to be integral
// ("8.0"). Anything else is 0.
fn parse_int(s string) int {
	t := s.trim_space()
	if t == '' {
		return 0
	}
	if t.starts_with('0x') || t.starts_with('0X') {
		return int(t[2..].parse_uint(16, 64) or { 0 })
	}
	if t.contains('.') || t.contains('e') || t.contains('E') {
		return int(t.f64())
	}
	return int(t.i64())
}

// parse_key reads an enum key as the width-sized raw pattern candb keys value tables by: a
// non-negative literal as u64 (so the top half of a 64-bit domain survives), a negative one
// through i64 (its two's-complement pattern). Hex, decimal, or a float that is integral —
// never through f64 for an integer literal, which would lose the low bits above 2^53.
fn parse_key(s string) u64 {
	return key_of(s) or { 0 }
}

// key_of is parse_key that can SAY NO: a literal no 64-bit raw key can hold — `18446744073709551616`,
// a magnitude past 2^63 with a minus sign — is none, where the fallback to 0 filed its label on
// raw zero (codex on #273 round 20). The value-table filing asks this; parse_key keeps the 0
// fallback for the callers that only compare.
fn key_of(s string) ?u64 {
	t := s.trim_space().trim_left('+')
	if t.starts_with('-') {
		mag := key_of(t[1..])?
		if mag > u64(1) << 63 {
			return none
		}
		return (~mag) + 1 // two's-complement negate, valid for 2^63 itself
	}
	if t.starts_with('0x') || t.starts_with('0X') {
		return t[2..].parse_uint(16, 64) or { return none }
	}
	if whole := integral_decimal(t) {
		return whole.parse_uint(10, 64) or { return none }
	}
	if t.contains('.') || t.contains('e') || t.contains('E') {
		// a REAL fraction, non-negative here (the sign went above), so straight to u64: through
		// i64 a key at or above 2^63 saturates, and `1.8E19` and `1.9E19` become one entry at
		// INT64_MIN. Integral spellings never reach this line
		f := t.f64()
		if f < 0 || f >= 18446744073709551616.0 || f != f {
			return none
		}
		return u64(f)
	}
	return t.parse_uint(10, 64) or { return none }
}

// integral_literal is whether a numeric literal spells an INTEGER: a bare digit string, a hex
// one, or a decimal/exponent form integral_decimal accepts. `1.1` and `1.9` are not, and must
// not be compared as the raw keys they truncate to.
fn integral_literal(s string) bool {
	t := s.trim_space().trim_left('+-')
	if t.starts_with('0x') || t.starts_with('0X') {
		return t.len > 2
	}
	if t.len > 0 && t.bytes().all(it >= `0` && it <= `9`) {
		return true
	}
	return integral_decimal(t) != none
}

// integral_decimal is the integer a decimal literal spells when its value IS an integer, as a
// digit string: `9007199254740993.0`, `9.007199254740993E15` and `9007199254740993` are one
// key, and so is `-9007199254740993.0` — none of which may go through f64, where the low bits
// above 2^53 round away and the label lands on the neighbouring raw value. The point is moved by
// the exponent in DIGITS, not arithmetic: an exponent that leaves a non-zero fraction, a bare
// integer (nothing to normalise) and anything that is not a decimal literal answer none.
fn integral_decimal(t string) ?string {
	if !t.contains('.') && !t.contains_any('eE') {
		return none
	}
	mut body := t
	mut sign := ''
	if body.starts_with('-') {
		sign = '-'
		body = body[1..]
	}
	mut exp := 0
	if body.contains_any('eE') {
		e_at := body.index_any('eE')
		exp_s := body[e_at + 1..].trim_left('+')
		exp_digits := exp_s.trim_left('-')
		if exp_digits.len == 0 || !exp_digits.bytes().all(it >= `0` && it <= `9`) {
			return none // not an integer exponent
		}
		exp = exp_s.int() // `E015` is fifteen: an optionally signed digit string, not a canonical spelling
		body = body[..e_at]
	}
	whole := body.all_before('.')
	frac := if body.contains('.') { body.all_after('.') } else { '' }
	digits := whole + frac
	if digits.len == 0 || !digits.bytes().all(it >= `0` && it <= `9`) {
		return none
	}
	// the point sits after `whole`; the exponent moves it right (positive) or left (negative)
	point := whole.len + exp
	if point < 0 {
		return if digits.count('0') == digits.len { '0' } else { none }
	}
	if point > digits.len {
		return sign + digits + '0'.repeat(point - digits.len)
	}
	rest := digits[point..]
	if rest.len > 0 && rest.count('0') != rest.len {
		return none // a real fraction remains
	}
	int_part := digits[..point].trim_left('0')
	return if int_part == '' { '0' } else { sign + int_part }
}

// parse_i64 reads an integer literal as an integer — an enum key above 2^53 would lose its
// low bits through f64. Hex, decimal, or a float that is integral.
fn parse_i64(s string) i64 {
	t := s.trim_space().trim_left('+')
	if t == '' {
		return 0
	}
	if t.starts_with('-') {
		// THE SIGN IS ONE RULE for every form below: `-0x1E` tested as hex only without its sign
		// fell through to the float fallback (it contains an E) and read as -0.0
		return -parse_i64(t[1..])
	}
	if t.starts_with('0x') || t.starts_with('0X') {
		return i64(t[2..].parse_uint(16, 64) or { 0 })
	}
	if whole := integral_decimal(t) {
		return whole.i64()
	}
	if t.contains('.') || t.contains('e') || t.contains('E') {
		return i64(t.f64())
	}
	return t.i64()
}

fn parse_num(s string) f64 {
	t := s.trim_space().trim_left('+')
	if t.starts_with('-') {
		// the sign is one rule here too: `-0x1E` tested as hex only without it read as 0
		// through f64 (codex on #273 round 21)
		return -parse_num(t[1..])
	}
	if t.starts_with('0x') || t.starts_with('0X') {
		return f64(t[2..].parse_uint(16, 64) or { 0 })
	}
	return t.f64()
}

// note_open_bounds says when a constraint's bound is not the closed one the model keeps. A DBC
// range is inclusive on both ends, so an OPEN bound (the value itself excluded) or an INFINITE
// one (no bound; the value is meaningless) read as a closed bound advertise the excluded value
// as valid — in the editor, in the exported DBC, and to range-based fault handling. Said,
// since the constraint changed meaning on the way in.
fn (mut r ArxmlReader) note_open_bounds(c xml.XMLNode, path string) {
	for f in open_bound_facts(c) {
		r.report.notes << '${path}: ${f}; read as a closed (inclusive) bound, which the range model is'
	}
}

// open_bound_facts names each bound of `c` that is not CLOSED — `LOWER-LIMIT 0 is OPEN` — pure,
// so a scale can carry them until a signal actually USES its domain as the range (round 25).
fn open_bound_facts(c xml.XMLNode) []string {
	mut out := []string{}
	for lim in ['LOWER-LIMIT', 'UPPER-LIMIT'] {
		l := child(c, lim) or { continue }
		kind := l.attributes['INTERVAL-TYPE'] or { 'CLOSED' }
		if kind != 'CLOSED' {
			out << '${lim} ${el_text(l)} is ${kind}'
		}
	}
	return out
}

// seconds_to_ms converts an ARXML time (seconds, "0.1" or "1.0E-2") to whole milliseconds,
// rounded — a 100 ms period written as 0.1 must not come back as 99.
fn seconds_to_ms(s string) int {
	if s.trim_space() == '' {
		return 0
	}
	return int(parse_num(s) * 1000.0 + 0.5)
}
