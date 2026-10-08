module project

import candb
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
// dialog shows. FD is decided by the frames: a declared CAN-FD baudrate alone is not enough — a
// classic bus may state one it never uses — and an FD channel carries classic frames too, so
// one FD frame decides it.
pub fn arxml_cluster_rates(c candb.ArxmlCluster) ClusterRates {
	mut fd := false
	for _, f in c.frames {
		if f.fd {
			fd = true
			break
		}
	}
	return ClusterRates{
		bitrate:      if c.baudrate > 0 { c.baudrate } else { default_bitrate }
		fd:           fd
		data_bitrate: if fd && c.fd_baudrate > 0 { c.fd_baudrate } else { 0 }
		no_baudrate:  c.baudrate <= 0
		no_fd_rate:   fd && c.fd_baudrate <= 0
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
