module sysview

import blobly.odx
import blobly.project
import blobly.transport
import blobly.uds

// odxnodes.v — the nodes a project names by an imported description (a CAN row's `diagnostics:`
// entry: a node, its ODX source and variant, its request and response ids), added to the system
// model beside system.toml's, so a tester names them, their DIDs and their DTCs as it names a
// blobly_emb node's. The DIDs are the variant's 0x22/0x2E data identifiers laid out for the DID
// codec (a scaled field read as a physical number or a label) and gated by the sessions and level
// their services' preconditions ask for, the faults its DTCs; what the codec cannot hold is read as
// bytes and said.

// with_odx_nodes is the model with a node added for every `diagnostics:` entry of the project's CAN
// rows (`proj_dir` resolves their ODX sources), and what reading them had to say. A node named on
// several rows with one description is one node on each; a name the model already has for another
// node is refused, since a tester could not tell which is meant — an enabled row's entry read
// before a disabled row's. A source that cannot be read
// still adds its node, its problem as `ecu_err`, so a tester is told why it has no names.
pub fn (sys System) with_odx_nodes(proj_dir string, chans []project.Channel) (System, []string) {
	mut out := System{
		...sys
		nodes:   sys.nodes.clone()
		sources: sys.sources.clone()
	}
	mut notes := []string{}
	mut dbs := map[string]odx.Db{}
	mut bad := map[string]string{}
	// enabled rows first, so a disabled row cannot take a name an enabled row describes otherwise
	mut ordered := chans.filter(it.enabled)
	ordered << chans.filter(!it.enabled)
	for ch in ordered {
		if ch.kind() != .can {
			continue
		}
		wire := transport.destination_key(ch.iface)
		for e in ch.diagnostics {
			label := '${ch.name}: diagnostics ${e.node}'
			src := '${e.odx}#${e.variant}'
			if i := out.nodes.index_of_name(e.node) {
				n := out.nodes[i]
				if n.odx == src && n.diag_req == e.tx && n.diag_rsp == e.rx {
					if ch.name !in n.buses {
						out.nodes[i].buses << ch.name
					}
					if wire !in n.wires {
						out.nodes[i].wires << wire
					}
				} else {
					notes << '${label}: a node of that name is already described (${if n.odx != '' {
						n.odx
					} else {
						n.ecu
					}}); not added'
				}
				continue
			}
			path := project.resolve_asset(proj_dir, e.odx)
			if path !in dbs && path !in bad {
				if db := odx.load(path) {
					dbs[path] = db
					for f in db.files {
						out.sources << stamp(f)
					}
					for nt in db.notes {
						notes << '${e.odx}: ${nt}'
					}
				} else {
					bad[path] = err.msg()
					out.sources << stamp(path) // its appearing, or being repaired, is a change
				}
			}
			mut node := SysNode{
				name:     e.node
				ecu:      e.odx
				odx:      src
				buses:    [ch.name]
				wires:    [wire]
				diag_req: e.tx
				diag_rsp: e.rx
				desc:     EcuDesc{
					server: true
				}
			}
			if why := bad[path] {
				node.ecu_err = why
				notes << '${label}: ${why}'
			} else {
				v := dbs[path].variant(e.variant) or {
					node.ecu_err = err.msg()
					notes << '${label}: ${err.msg()}'
					out.nodes << node
					continue
				}
				node.desc = odx_desc(v)
				for nt in v.notes {
					notes << '${label}: ${nt}'
				}
				for nt in node.desc.errs {
					notes << '${label}: ${nt}'
				}
				for nt in node.desc.warns {
					notes << '${label}: ${nt}'
				}
			}
			out.nodes << node
		}
	}
	return out, notes
}

// index_of_name is the first node called `name`.
fn (nodes []SysNode) index_of_name(name string) ?int {
	for i, n in nodes {
		if n.name == name {
			return i
		}
	}
	return none
}

// odx_desc is a variant as a node's description: its DTCs as faults, its DIDs laid out for the
// codec (`errs` says each it reads as bytes instead) with the gates their services ask for
// (`warns` says one that cannot be met).
fn odx_desc(v odx.Variant) EcuDesc {
	mut d := EcuDesc{
		server: true
	}
	for t in v.dtcs {
		d.faults << FaultDesc{
			name: t.name
			dtc:  t.code
		}
	}
	for x in v.dids {
		did, why := odx_did(x)
		if why != '' {
			d.errs << 'DID 0x${x.id:04X} (${x.name}): ${why}; read as bytes'
		}
		for key, g in {
			'read':  did.read_gate
			'write': did.write_gate
		} {
			if w := g.contradiction() {
				d.warns << 'DID 0x${x.id:04X} (${x.name}): ${key} ${w}'
			}
		}
		d.dids << did
	}
	return d
}

// odx_gate is a service's preconditions as a gate: its sessions by name, as an ecu.toml writes them.
fn odx_gate(g odx.Gate, declared bool) Gate {
	return Gate{
		declared:   declared
		sessions:   g.sessions.map(uds.session_name(it))
		level:      g.level
		unresolved: g.unresolved.join('; ')
	}
}

// odx_scaling is a part's compu method for the codec, none for an IDENTICAL one.
fn odx_scaling(c odx.Compu) ?Scaling {
	if c.segments.len == 0 && c.labels.len == 0 {
		return none
	}
	return Scaling{
		segments: c.segments.map(Linear{it.lo, it.hi, it.v0, it.v1, it.d})
		labels:   c.labels.map(TextEntry{it.lo, it.hi, it.text, it.write})
		fallback: c.fallback
		unit:     c.unit
	}
}

// odx_did is one DID for the codec: integer parts as fields, one text part as a text, else bytes —
// with the reason when the parts are laid out and the codec still cannot hold them.
fn odx_did(x odx.Did) (DidDesc, string) {
	mut kind := DidKind.data
	mut fields := []Field{}
	mut scaling := map[string]Scaling{}
	mut why := ''
	if x.parts.len == 1 && x.parts[0].kind == .text {
		kind = .text
	} else if x.parts.len > 0 && x.parts.all(it.kind in [.unsigned, .signed]) {
		for q in x.parts {
			typ := '${if q.kind == .signed { 'i' } else { 'u' }}${q.size * 8}'
			f := Field{q.name, typ}
			if f.width() != q.size {
				why = '${q.name} is ${q.size} bytes, which the codec holds no integer of'
				break
			}
			if fields.any(it.name == q.name) {
				why = 'two of its parts are called ${q.name}'
				break
			}
			fields << f
			if sc := odx_scaling(q.compu) {
				scaling[q.name] = sc
			}
		}
		if why == '' {
			kind = .fields
		} else {
			fields = []
			scaling = map[string]Scaling{}
		}
	} else if x.parts.len > 1 {
		why = 'its parts mix ${x.parts.map(it.kind.str()).join(', ')}, which the codec does not lay out together'
	}
	read_gate := odx_gate(x.read_gate, x.read_gate.declared)
	write_gate := odx_gate(x.write_gate, x.writable)
	return DidDesc{
		id:         x.id
		kind:       kind
		name:       if x.name != '' { x.name } else { uds.standard_did_name(x.id) }
		size:       x.size
		fields:     fields
		scaling:    scaling
		read:       if read_gate.declared { read_gate.words() } else { '' }
		write:      if write_gate.declared { write_gate.words() } else { '' }
		read_gate:  read_gate
		write_gate: write_gate
	}, why
}
