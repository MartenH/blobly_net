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

// arxml_cluster_fd says whether a cluster is run as CAN-FD: it carries an FD frame. A declared
// CAN-FD baudrate alone is not enough — a classic bus may state one it never uses — and an FD
// channel carries classic frames too, so one FD frame decides it.
pub fn arxml_cluster_fd(c candb.ArxmlCluster) bool {
	for _, f in c.frames {
		if f.fd {
			return true
		}
	}
	return false
}

// import_arxml builds the channel rows an import adds to `existing`, plus notes for what the
// operator should know about them. Refused, before anything is built, for a cluster the file
// does not have, a cluster mapped twice, two clusters on one wire (each is a bus), and an ECU
// under test the imported clusters do not name.
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
		iface := compose_iface(pl.adapter, pl.address)
		if pl.address.trim_space() == '' && pl.adapter !in ['virtual', 'udp'] {
			return error('${c.bus}: ${pl.adapter} needs an address')
		}
		w := transport.wire_key_for(pl.adapter, iface)
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
		for s in arxml_senders(c) {
			if s !in ecus {
				ecus << s
			}
		}
		for n in c.db.nodes {
			if n !in ecus {
				ecus << n
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
		iface := compose_iface(pl.adapter, pl.address)
		mut name := c.bus
		for n := 2; name in names; n++ {
			name = '${c.bus}_${n}'
		}
		names << name
		fd := arxml_cluster_fd(c)
		mut ch := Channel{
			name:         name
			adapter:      pl.adapter
			address:      pl.address.trim_space()
			iface:        iface
			typ:          if fd { 'canfd' } else { 'can' }
			fd:           fd
			bitrate:      if c.baudrate > 0 { c.baudrate } else { default_bitrate }
			data_bitrate: if fd { c.fd_baudrate } else { 0 }
			databases:    ['${imp.ref}#${c.bus}']
			listen_only:  adapter_starts_silent(pl.adapter)
		}
		if c.baudrate <= 0 {
			notes << '${name}: ${c.bus} states no baudrate; set to ${default_bitrate}'
		}
		if imp.restbus {
			ch.simulate = arxml_senders(c).filter(it !in imp.sut)
		}
		w := transport.wire_key_for(pl.adapter, iface)
		for e in existing {
			if transport.wire_key_for(e.adapter, e.iface) == w {
				notes << '${name} is on ${iface}, which ${e.name} already uses'
			}
		}
		out << ch
	}
	return out, notes
}
