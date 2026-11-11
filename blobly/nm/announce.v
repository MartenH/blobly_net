module nm

import blobly.project

// Announce is a simulated node's NM PDU as its cluster gives it: the frame it announces on, its
// source node id, the cycle, and where the PDU lies in the frame. The simulation sends it while
// the network is requested (blobly/sim, nm_tx.v); this module only says what it is.
pub struct Announce {
pub:
	node     string
	id       u32
	ext      bool
	nid      u8
	cycle_ms int
	at       PduAt
}

// payload is the frame's bytes: the PDU at its byte — the NID, then a control bit vector of 0x00
// (the network requested, nothing else said) — zeros elsewhere. As long as the ARXML's PDU where
// it states one, else 8 bytes (the frame blobly_emb's comm/nm sends and the shortest it reads),
// or to the control bit vector's byte where the PDU starts too late for that.
pub fn (a Announce) payload() []u8 {
	n := if a.at.len > 0 {
		a.at.byte + a.at.len
	} else if a.at.byte + 2 > 8 {
		a.at.byte + 2
	} else {
		8
	}
	mut d := []u8{len: n}
	d[a.at.byte] = a.nid
	return d
}

// announcements is which of a row's simulated `nodes` announce on the wire's NM cluster `cfg`,
// and the notes saying why one that looks meant to announce does not. A node announces when the
// cluster states a cycle and gives it an id and a NID: the cluster's declaration of it (the
// system model, the ARXML) where there is one, else its own `nm:` entry, field by field. An id
// that is not one of the cluster's NM frames announces nothing, since nothing would read it.
pub fn announcements(cfg ?Config, nodes []project.NodeCfg) ([]Announce, []string) {
	mut out := []Announce{}
	mut notes := []string{}
	c := cfg or {
		for n in nodes {
			if _ := n.nm {
				notes << '${n.name}: its nm: entry is on a wire with no NM cluster; it announces nothing'
			}
		}
		return out, notes
	}
	mut uncycled := []string{}
	for n in nodes {
		mut decl := Declared{}
		mut declared := false
		for d in c.declared {
			if d.name == n.name {
				decl = d
				declared = true
				break
			}
		}
		own := n.nm or { project.NodeNm{} }
		if !declared && n.nm == none {
			continue // not a member of the cluster
		}
		if c.cycle_ms <= 0 {
			uncycled << n.name
			continue
		}
		id := if decl.id >= 0 { decl.id } else { own.id }
		ext := if decl.id >= 0 { decl.ext } else { own.ext }
		nid := if decl.nid >= 0 { decl.nid } else { own.nid }
		if id < 0 || nid < 0 {
			missing := if id < 0 { 'NM id' } else { 'NID' }
			notes << '${n.name}: ${c.origin} gives it no ${missing}, nor does its nm: entry; it announces nothing'
			continue
		}
		if declared && ((own.id >= 0 && decl.id >= 0 && (own.id != decl.id || own.ext != decl.ext))
			|| (own.nid >= 0 && decl.nid >= 0 && own.nid != decl.nid)) {
			notes << '${n.name}: its nm: entry differs from ${c.origin}; it announces as the cluster declares it'
		}
		if !c.covers(u32(id), ext) {
			notes << '${n.name}: NM id 0x${id:X} is not one of the cluster ${c.describe()}; it announces nothing'
			continue
		}
		out << Announce{
			node:     n.name
			id:       u32(id)
			ext:      ext
			nid:      u8(nid)
			cycle_ms: c.cycle_ms
			at:       c.pdu_at(u32(id), ext)
		}
	}
	if uncycled.len > 0 {
		notes << '${uncycled.join(', ')}: on the NM cluster (${c.origin}) with no cycle: give the row nm: cycle_ms for the simulated nodes to announce'
	}
	return out, notes
}
