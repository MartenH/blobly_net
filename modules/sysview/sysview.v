// sysview — the read-only SYSTEM model behind the System panel
// (docs/dbc_editor.md roadmap: viewer, deliberately NOT an editor). Parses a
// blobly_emb system.toml (buses, once-declared cross-node signals with their
// producers, nodes with their identity blocks) plus each node's ecu.toml
// (whose FB handlers' reads/writes derive the consumers), and computes what
// text is bad at seeing: the communication matrix and the per-bus id
// allocation with collisions. Validation stays in blobly_emb (ecucheck/
// syscheck) — this module only renders the truth it finds, GUI-free and
// independently testable.
module sysview

import os
import toml
import candb

pub struct SysBus {
pub mut:
	name    string
	iface   string
	fd      bool
	bitrate int
	dbc     string // as written (relative to the system.toml dir)
	nm_lo   u32    // NM peers range (0 = none)
	nm_hi   u32
}

pub struct SysSignal {
pub mut:
	name      string
	producer  string // node name (from system.toml — the single writer)
	bus       string
	frame     string
	cycle_ms  int
	consumers []string // node names whose ecu.toml FBs read it (derived)
}

pub struct SysNode {
pub mut:
	name     string
	ecu      string // path as written
	buses    []string
	nm       u32 // NM node offset within the cluster (0 = none)
	diag_req u32
	diag_rsp u32
	trace    int
	reads    []string // signal names its FB handlers read (from its ecu.toml)
	writes   []string // signal names its FB handlers write
	ecu_err  string   // non-empty: its ecu.toml could not be read/parsed
}

// IdUse is one allocated identifier on a bus, for the allocation table.
pub struct IdUse {
pub mut:
	id    u32
	ext   bool   // frame kind is part of CAN identity (std/ext share numbers)
	kind  string // 'frame' | 'nm' | 'diag-req' | 'diag-rsp'
	owner string // frame name or node name
}

pub struct System {
pub mut:
	path    string
	buses   []SysBus
	signals []SysSignal
	nodes   []SysNode
	errs    []string // load-time problems worth showing (missing DBC etc.)
	// precomputed at load (id_allocation parses the bus DBC — a per-frame
	// GUI must never re-read files): bus -> sorted allocation / collisions
	alloc map[string][]IdUse
	cols  map[string][]u32
}

fn tstr(m map[string]toml.Any, key string) string {
	if v := m[key] {
		if v is string {
			return v
		}
	}
	return ''
}

fn tint(m map[string]toml.Any, key string) i64 {
	if v := m[key] {
		if v is i64 {
			return v
		}
	}
	return 0
}

fn tarr(doc toml.Doc, key string) []toml.Any {
	if v := doc.value_opt(key) {
		return v.array()
	}
	return []toml.Any{}
}

// load parses a system.toml and every reachable node ecu.toml, deriving the
// consumer sets. Missing/broken pieces degrade into errs/ecu_err — a viewer
// shows what it can, it never refuses the whole system for one bad file.
pub fn load(path string) !System {
	doc := toml.parse_file(path)!
	base := os.dir(path)
	mut sys := System{
		path: path
	}

	if bv := doc.value_opt('bus') {
		for bname, bcfg in bv.as_map() {
			bm := bcfg.as_map()
			mut b := SysBus{
				name:    bname
				iface:   tstr(bm, 'interface')
				bitrate: int(tint(bm, 'bitrate'))
				dbc:     tstr(bm, 'dbc')
			}
			if v := bm['fd'] {
				if v is bool {
					b.fd = v
				}
			}
			if nmv := bm['nm'] {
				nmm := nmv.as_map()
				if pv := nmm['peers'] {
					pa := pv.array()
					if pa.len == 2 {
						b.nm_lo = u32(pa[0].int())
						b.nm_hi = u32(pa[1].int())
					}
				}
			}
			sys.buses << b
		}
	}

	for sg in tarr(doc, 'signal') {
		sm := sg.as_map()
		sys.signals << SysSignal{
			name:     tstr(sm, 'name')
			producer: tstr(sm, 'producer')
			bus:      tstr(sm, 'bus')
			frame:    tstr(sm, 'frame')
			cycle_ms: int(tint(sm, 'cycle_ms'))
		}
	}

	for nd in tarr(doc, 'node') {
		nm := nd.as_map()
		mut n := SysNode{
			name:  tstr(nm, 'name')
			ecu:   tstr(nm, 'ecu')
			nm:    u32(tint(nm, 'nm'))
			trace: int(tint(nm, 'trace'))
		}
		if bv := nm['buses'] {
			for b in bv.array() {
				n.buses << b.string()
			}
		}
		if dv := nm['diag'] {
			dm := dv.as_map()
			n.diag_req = u32(tint(dm, 'req'))
			n.diag_rsp = u32(tint(dm, 'rsp'))
		}
		// the node's internals: reads/writes across every FB handler
		epath := os.join_path(base, n.ecu)
		if ndoc := toml.parse_file(epath) {
			for fb in tarr(ndoc, 'fb') {
				fm := fb.as_map()
				if hv := fm['handler'] {
					for h in hv.array() {
						hm := h.as_map()
						if rv := hm['reads'] {
							for r in rv.array() {
								if r.string() !in n.reads {
									n.reads << r.string()
								}
							}
						}
						if wv := hm['writes'] {
							for w in wv.array() {
								if w.string() !in n.writes {
									n.writes << w.string()
								}
							}
						}
					}
				}
			}
		} else {
			n.ecu_err = '${err}'
		}
		sys.nodes << n
	}

	// derive consumers: a node reading a cross-node signal consumes it
	for i, sg in sys.signals {
		for n in sys.nodes {
			if sg.name in n.reads && n.name != sg.producer {
				sys.signals[i].consumers << n.name
			}
		}
	}
	// precompute the id tables ONCE — the panel renders every frame
	for b in sys.buses {
		sys.alloc[b.name] = sys.compute_allocation(b.name)
		sys.cols[b.name] = compute_collisions(sys.alloc[b.name])
	}
	return sys
}

// id_allocation returns the precomputed allocation for `bus` (load-time —
// the panel calls this per rendered frame and must not touch the filesystem).
pub fn (sys System) id_allocation(bus string) []IdUse {
	return sys.alloc[bus] or { []IdUse{} }
}

// collisions returns the precomputed colliding ids for `bus`.
pub fn (sys System) collisions(bus string) []u32 {
	return sys.cols[bus] or { []u32{} }
}

fn (mut sys System) compute_allocation(bus string) []IdUse {
	mut out := []IdUse{}
	mut b := SysBus{}
	for sb in sys.buses {
		if sb.name == bus {
			b = sb
		}
	}
	if b.dbc != '' {
		dbp := os.join_path(os.dir(sys.path), b.dbc)
		if db := candb.load_dbc_file(dbp) {
			for m in db.messages {
				out << IdUse{
					id:    m.id
					ext:   m.ext
					kind:  'frame'
					owner: m.name
				}
			}
		} else {
			// an omitted DBC would make the table LOOK valid while missing
			// every frame id — surface it instead
			sys.errs << 'bus ${bus}: DBC ${b.dbc} not loaded (${err}) — frame ids missing from the allocation'
		}
	}
	for n in sys.nodes {
		if bus !in n.buses {
			continue
		}
		if b.nm_lo != 0 && n.nm != 0 {
			out << IdUse{
				id:    b.nm_lo + n.nm
				kind:  'nm'
				owner: n.name
			}
		}
		if n.diag_req != 0 {
			out << IdUse{
				id:    n.diag_req
				kind:  'diag-req'
				owner: n.name
			}
		}
		if n.diag_rsp != 0 {
			out << IdUse{
				id:    n.diag_rsp
				kind:  'diag-rsp'
				owner: n.name
			}
		}
	}
	out.sort_with_compare(fn (a &IdUse, x &IdUse) int {
		if a.id != x.id {
			return if a.id < x.id { -1 } else { 1 }
		}
		if a.ext != x.ext {
			return if !a.ext { -1 } else { 1 }
		}
		return a.owner.compare(x.owner)
	})
	return out
}

// compute_collisions: ids allocated more than once — per (id, KIND) pair, so
// a std and an ext frame sharing a number are NOT a false duplicate. NM/diag
// ids are standard-frame identifiers.
fn compute_collisions(alloc []IdUse) []u32 {
	mut seen := map[u64]int{}
	for a in alloc {
		key := u64(a.id) | (u64(if a.ext { 1 } else { 0 }) << 32)
		seen[key]++
	}
	mut out := []u32{}
	for key, c in seen {
		if c > 1 {
			id := u32(key & 0xFFFF_FFFF)
			if id !in out {
				out << id
			}
		}
	}
	out.sort()
	return out
}

// matrix_cell renders a signal×node cell: 'P' producer, 'C' consumer,
// 'W' local writer that is NOT the declared producer (suspicious), '' none.
pub fn (sys System) matrix_cell(sig SysSignal, node SysNode) string {
	if node.name == sig.producer {
		return 'P'
	}
	if sig.name in node.writes {
		return 'W' // writes it but is not the declared producer — suspicious
	}
	if node.name in sig.consumers {
		return 'C'
	}
	return ''
}
