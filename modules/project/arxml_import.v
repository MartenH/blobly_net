module project

import candb
import os
import transport

// An ARXML describes a system: its CAN clusters, their rates, the ECUs on each. A project adds
// what the file cannot know — which interface carries each cluster, which ECU is under test,
// what is simulated. So an import is a MAPPING that writes references (`net.arxml#Body`), never
// a copy of frames, signals, timing or E2E: those stay in the ARXML and a reissued extract is
// read on the next load. The rates are the one thing copied, because the interface address is
// where they live (#439).

// ClusterPlan maps one cluster onto a wire. An empty adapter leaves the cluster out.
pub struct ClusterPlan {
pub mut:
	bus     string // the cluster, by the identifier candb.Arxml.cluster accepts
	adapter string
	address string
}

// ArxmlImport is what the operator decided.
pub struct ArxmlImport {
pub mut:
	ref      string // the file as the project should name it (relative to the project, or absolute)
	clusters []ClusterPlan
	sut      []string // the ECUs under test: never simulated
	restbus  bool     // simulate every other ECU that sends on an imported cluster
}

// arxml_senders lists the ECUs that send on a cluster, in the order the file first names them.
pub fn arxml_senders(c candb.ArxmlCluster) []string {
	mut out := []string{}
	for m in c.db.messages {
		for s in m.senders() {
			if s !in out {
				out << s
			}
		}
	}
	return out
}

// arxml_ecus lists the ECUs a cluster names — its senders, then the rest of its nodes — which is
// what may be marked under test.
pub fn arxml_ecus(c candb.ArxmlCluster) []string {
	mut out := arxml_senders(c)
	for n in c.db.nodes {
		if n !in out {
			out << n
		}
	}
	return out
}

// ClusterRates is how a channel reading a cluster is opened, and what the file left unsaid.
pub struct ClusterRates {
pub:
	bitrate      int
	fd           bool
	data_bitrate int  // 0: classic, or FD with no data rate stated (it runs at the arbitration rate)
	no_baudrate  bool // the cluster states no baudrate; `bitrate` is the default
	no_fd_rate   bool // it carries an FD frame and states no CAN-FD baudrate
}

// arxml_cluster_rates is the ONE rule for a cluster's rates, which the import writes and the
// dialog shows: arxml_bus_rates over what the cluster states.
pub fn arxml_cluster_rates(c candb.ArxmlCluster) ClusterRates {
	return arxml_bus_rates(c.bus_facts(''))
}

// arxml_bus_rates reads a cluster's statement about its bus — FD decided by the frames
// (candb.ArxmlCluster.carries_fd), an unstated nominal rate the default, an unstated FD data rate
// none (it runs at the arbitration rate).
pub fn arxml_bus_rates(b candb.ArxmlBus) ClusterRates {
	return ClusterRates{
		bitrate:      if b.baudrate > 0 { b.baudrate } else { default_bitrate }
		fd:           b.fd
		data_bitrate: if b.fd && b.fd_baudrate > 0 { b.fd_baudrate } else { 0 }
		no_baudrate:  b.baudrate <= 0
		no_fd_rate:   b.fd && b.fd_baudrate <= 0
	}
}

// import_address is a plan's address as the row keeps it: trimmed, and for Vector without a
// `,silent` / `,normal` suffix, which the loader and the editor lift into listen_only too
// (split_vector_mode) — left in the address, the port opens silent while the row is called
// transmit-capable.
fn import_address(pl ClusterPlan) !string {
	a := pl.address.trim_space()
	if pl.adapter != 'vector' {
		return a
	}
	body, _, ok := split_vector_mode(a)
	if !ok {
		return error('${pl.bus}: unrecognised mode in ${a} (,silent or ,normal)')
	}
	return body
}

// import_wire is a wire's identity for the one-cluster-per-wire rule: without the rate where the
// adapter carries one (two rates on one channel are still one wire), and the whole name
// elsewhere — `@` is a literal in a software bus's name, and `bench@A` is not `bench@B`.
fn import_wire(adapter string, iface string) string {
	if transport.adapter_configures_bitrate(adapter) {
		return transport.wire_key_for(adapter, iface)
	}
	return transport.destination_key_for(adapter, iface)
}

// import_arxml builds the channel rows an import adds to `existing`, plus notes for what the
// operator should know about them. Refused, before anything is built, for a cluster the file
// does not have, a cluster mapped twice, an adapter that does not carry CAN, two clusters on
// one wire (each is a bus), and an ECU under test the imported clusters do not name.
pub fn import_arxml(a candb.Arxml, imp ArxmlImport, existing []Channel) !([]Channel, []string) {
	mut chosen := []candb.ArxmlCluster{}
	mut plans := []ClusterPlan{}
	mut wires := map[string]string{} // wire -> cluster
	for pl in imp.clusters {
		if pl.adapter == '' {
			continue
		}
		c := a.cluster(pl.bus)!
		if chosen.any(it.path == c.path) {
			return error('${c.bus} is mapped twice')
		}
		addr := import_address(pl)!
		iface := compose_iface(pl.adapter, addr)
		if pl.adapter !in adapters || iface_is_eth(iface) {
			return error('${c.bus}: ${pl.adapter} is not a CAN adapter')
		}
		if addr == '' && pl.adapter !in ['virtual', 'udp'] {
			return error('${c.bus}: ${pl.adapter} needs an address')
		}
		if transport.adapter_configures_bitrate(pl.adapter) && addr.contains('@') {
			return error('${c.bus}: the address holds a rate (${addr}); the rate is the cluster\'s')
		}
		w := import_wire(pl.adapter, iface)
		if other := wires[w] {
			return error('${other} and ${c.bus} are both on ${iface}: a cluster is a bus, and a wire carries one')
		}
		wires[w] = c.bus
		chosen << c
		plans << pl
	}
	if chosen.len == 0 {
		return error('no cluster is mapped to an interface')
	}
	mut ecus := []string{}
	for c in chosen {
		for e in arxml_ecus(c) {
			if e !in ecus {
				ecus << e
			}
		}
	}
	for s in imp.sut {
		if s !in ecus {
			return error('${s} is on none of the imported clusters (${ecus.join(', ')})')
		}
	}
	mut names := existing.map(it.name)
	mut out := []Channel{}
	mut notes := []string{}
	for k, c in chosen {
		pl := plans[k]
		addr := import_address(pl)!
		_, silent, _ := split_vector_mode(if pl.adapter == 'vector' { pl.address.trim_space() } else { '' })
		iface := compose_iface(pl.adapter, addr)
		mut name := c.bus
		for n := 2; name in names; n++ {
			name = '${c.bus}_${n}'
		}
		names << name
		r := arxml_cluster_rates(c)
		mut ch := Channel{
			name:         name
			adapter:      pl.adapter
			address:      addr
			iface:        iface
			typ:          if r.fd { 'canfd' } else { 'can' }
			fd:           r.fd
			bitrate:      r.bitrate
			data_bitrate: r.data_bitrate
			databases:    ['${imp.ref}#${c.bus}']
			listen_only:  silent || adapter_starts_silent(pl.adapter)
		}
		// what the backend could not open is refused here, while another adapter can be picked
		if why := ch.address_config_error() {
			return error('${c.bus} on ${pl.adapter} ${addr}: ${why}')
		}
		if r.no_baudrate {
			notes << '${name}: ${c.bus} states no baudrate; set to ${default_bitrate}'
		}
		if r.no_fd_rate {
			notes << '${name}: ${c.bus} carries CAN-FD frames and states no CAN-FD baudrate; the data phase runs at the arbitration rate'
		}
		if imp.restbus {
			ch.simulate = arxml_senders(c).filter(it !in imp.sut)
		}
		w := import_wire(pl.adapter, iface)
		for e in existing {
			if import_wire(e.adapter, e.iface) == w {
				notes << '${name} is on ${iface}, which ${e.name} already uses'
			}
		}
		out << ch
	}
	return out, notes
}

// DatabaseLoad finds the database a resolved reference loads: the GUI's from what its rebuild
// LOADED (app.dbs, by canonical reference — so the check compares a row with exactly the parse
// the run uses, never a later parse of the same path), the headless runner's through
// candb.open_database. none means skip: the database loader reports a reference that fails.
pub type DatabaseLoad = fn (resolved_ref string) ?candb.Database

// arxml_rate_warnings names every enabled row whose rate or CAN-FD setting disagrees with the
// ARXML cluster it reads (#439). An import copies the rates into the row, because the interface
// is where they live, so a reissued extract that changes a bus's rate leaves the row behind —
// and a wire at the wrong rate is no traffic at all on hardware. Said at Start, by both front
// ends, rather than refused: a bench may run a bus at another rate on purpose. A rate is
// compared only where this app SETS it (transport.adapter_configures_bitrate / _data_phase): on
// SocketCAN it is `ip link`'s and on a software bus nobody's. The FORMAT is compared on every
// adapter — classic against FD, and whether the data phase switches rate (BRS), which
// origination_framing derives from the row's rates even where nothing applies them — and said
// as the mismatch it is: what it costs depends on the backend and on the wire's other rows
// (wire_framings), which this does not try to predict. `dir` is the project's directory, which
// references resolve against; each file is looked up once.
pub fn arxml_rate_warnings(chs []Channel, dir string, find DatabaseLoad) []string {
	// disabled rows filtered BEFORE anything is looked up: a file only they name is not read
	return arxml_rate_findings(chs.filter(it.enabled), dir, find).map(it.text)
}

// RowWarning is one warning about the row at index `row`.
pub struct RowWarning {
pub:
	row  int
	text string
}

// arxml_rate_findings is arxml_rate_warnings for EVERY row, enabled or not, each tagged with its
// index: what the GUI keeps from a rebuild, because a row ticked on or off while stopped changes
// no rate and causes no rebuild, so Start filters by the enabled state it finds then.
pub fn arxml_rate_findings(chs []Channel, dir string, find DatabaseLoad) []RowWarning {
	mut seen := map[string]bool{}
	mut dbs := map[string]candb.Database{}
	mut out := []RowWarning{}
	for i, ch in chs {
		if ch.is_eth() {
			continue
		}
		for ref in ch.databases {
			if !candb.is_arxml_ref(ref) {
				continue
			}
			resolved := resolve_asset(dir, ref)
			// by canonical reference (real path + #Cluster): two spellings of one cluster of one
			// file are looked up once
			key := candb.canonical_database_ref(resolved)
			if key !in seen {
				seen[key] = true
				if db := find(resolved) {
					dbs[key] = db
				}
			}
			db := dbs[key] or { continue }
			if db.arxml.name == '' {
				continue
			}
			r := arxml_bus_rates(db.arxml)
			what := '${db.arxml.name} (${db.arxml.file})'
			if transport.adapter_configures_bitrate(ch.adapter) && !r.no_baudrate
				&& ch.nominal_bitrate() != r.bitrate {
				out << RowWarning{i, '${ch.name} runs at ${ch.nominal_bitrate()} bit/s but ${what} is ${r.bitrate} bit/s'}
			}
			if r.fd && !ch.fd {
				out << RowWarning{i, '${ch.name} is configured classic but ${what} carries CAN-FD frames'}
			} else if !r.fd && ch.fd {
				out << RowWarning{i, '${ch.name} is configured CAN-FD but ${what} carries no CAN-FD frame'}
			} else if r.fd && r.data_bitrate > 0 {
				if transport.adapter_configures_data_phase(ch.adapter) {
					if ch.data_rate() != r.data_bitrate {
						out << RowWarning{i, '${ch.name} runs its data phase at ${ch.data_rate()} bit/s but ${what} states ${r.data_bitrate} bit/s'}
					}
				} else if !r.no_baudrate && ch.origination_framing().brs != (r.data_bitrate != r.bitrate) {
					// (with no nominal rate stated, the file cannot say whether its phases differ)
					// the rates are not this app's to set here, but they still decide BRS
					sw := if ch.origination_framing().brs { 'switches' } else { 'does not switch' }
					cs := if r.data_bitrate != r.bitrate { 'does' } else { 'does not' }
					out << RowWarning{i, '${ch.name}\'s data phase ${sw} rate but ${what}\'s ${cs}'}
				}
			}
		}
	}
	return out
}
