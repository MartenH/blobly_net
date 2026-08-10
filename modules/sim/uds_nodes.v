// Building per-ECU diagnostic servers from a project. Shared by the GUI and the headless
// runner, because a scripted diagnostic test must reach the same servers the interactive one
// does — the class of divergence that produced three copies of build_node and two database
// merges before it.
module sim

import project
import uds

// UdsNode is one simulated ECU's diagnostic server, with the addresses it answers on.
pub struct UdsNode {
pub:
	name string
	rx   u32  // request id  (tester -> ECU)
	tx   u32  // response id (ECU -> tester)
	ext  bool // 29-bit addressing, inferred from the ids
pub mut:
	server uds.Server
}

// uds_nodes builds a server for every node on the channel that configures one.
//
// Returns EMPTY when no node does, and the caller then runs the single built-in server on the
// channel's default addresses as before. That rule — configure one and you own diagnostics on
// this channel — is what keeps the two from fighting over 0x7E0: a default that kept running
// alongside would answer requests meant for a configured ECU whenever the ids overlapped, and
// which reply the tester saw would depend on scheduling.
pub fn uds_nodes(nodes []project.NodeCfg) []UdsNode {
	mut out := []UdsNode{}
	// Two passes. `claimed` may only ever hold ids belonging to servers that are actually
	// going to START: reserving them from a config that is itself rejected poisoned the id for
	// a valid node, which was then skipped too and the channel default started in its place.
	mut claimed := map[u64]bool{}
	for n in nodes {
		cfg := n.uds or { continue }
		if !structurally_ok(cfg) {
			continue // reported by validate_uds
		}
		if cfg.rx in claimed || cfg.tx in claimed {
			continue // collides with an earlier accepted server, either direction
		}
		claimed[cfg.rx] = true
		claimed[cfg.tx] = true
		mut srv := uds.Server{
			session: u8(cfg.session)
		}
		for d in cfg.dids {
			if d.id > 0xFFFF || d.value_len() > max_did_bytes {
				continue // reported by validate_uds
			}
			if u16(d.id) in srv.dids {
				continue // duplicate: FIRST wins, so the served value cannot depend on order
			}
			srv.dids[u16(d.id)] = if d.bytes.len > 0 { d.bytes.clone() } else { d.text.bytes() }
		}
		for t in cfg.dtcs {
			if t.code > 0xFFFFFF || t.status > 0xFF {
				continue // reported by validate_uds
			}
			if srv.dtcs.len >= max_dtcs {
				break // reported by validate_uds; a longer table cannot be transmitted at all
			}
			srv.dtcs << uds.Dtc{
				code:   t.code
				status: u8(t.status)
			}
		}
		out << UdsNode{
			name: n.name
			rx:   u32(cfg.rx)
			tx:   u32(cfg.tx)
			// 29-bit addressing is inferred, because an id above 0x7FF cannot be anything
			// else. Opened as standard, SocketCAN masks it to 11 bits and 0x18DAF110 goes out
			// as 0x110 — a different, probably occupied, address.
			ext:    cfg.rx > 0x7FF || cfg.tx > 0x7FF
			server: srv
		}
	}
	return out
}

// max_dtcs is how many faults a 0x19 sub 0x02 response can carry: the header is 3 bytes and
// each record 4, against ISO-TP's 4095-byte maximum. Past it `send` refuses the transfer and
// the error is discarded, so the tester sees only a timeout.
pub const max_dtcs = (4095 - 3) / 4

// max_did_bytes is the largest DID value that fits one ISO-TP transfer: 4095 bytes minus the
// three-byte positive-response header (0x62 + the two identifier bytes).
pub const max_did_bytes = 4092

// can_id_max is the widest identifier CAN has. Above it SocketCAN masks on transmit while the
// software channel still matches on the unmasked value, so the ECU talks on a DIFFERENT valid
// id and hears nothing.
const can_id_max = u32(0x1FFFFFFF)

// structurally_ok is the single definition of "this pair can be opened at all", used both to
// decide what starts and to keep rejected configurations from reserving ids.
fn structurally_ok(cfg project.UdsCfg) bool {
	if cfg.malformed.len > 0 || cfg.session > 0xFF {
		return false // an id that was silently repaired, or a session that is not a byte
	}
	if cfg.rx == 0 || cfg.tx == 0 || cfg.rx == cfg.tx {
		return false
	}
	if cfg.rx > can_id_max || cfg.tx > can_id_max {
		return false
	}
	if (cfg.rx > 0x7FF) != (cfg.tx > 0x7FF) {
		return false // ISO-TP opens ONE format for the pair
	}
	return true
}

// UdsAddr is a target's identity without its content — names and addresses only.
pub struct UdsAddr {
pub:
	name string
	rx   u32
	tx   u32
	ext  bool
}

// uds_addrs is uds_nodes without the servers.
//
// The Diagnostics panel needs only names and addresses, and it asks every rendered frame.
// Going through uds_nodes there cloned every DID value and rebuilt every DTC table at frame
// rate — with 4092-byte values accepted, that is continuous allocation for data the panel
// never looks at.
pub fn uds_addrs(nodes []project.NodeCfg) []UdsAddr {
	mut out := []UdsAddr{}
	mut claimed := map[u64]bool{}
	for n in nodes {
		cfg := n.uds or { continue }
		if !structurally_ok(cfg) || cfg.rx in claimed || cfg.tx in claimed {
			continue
		}
		claimed[cfg.rx] = true
		claimed[cfg.tx] = true
		out << UdsAddr{
			name: n.name
			rx:   u32(cfg.rx)
			tx:   u32(cfg.tx)
			ext:  cfg.rx > 0x7FF || cfg.tx > 0x7FF
		}
	}
	return out
}

// validate_uds reports diagnostic configurations that cannot work as written.
pub fn validate_uds(nodes []project.NodeCfg) []string {
	mut warns := []string{}
	mut by_rx := map[u64]string{}
	mut by_tx := map[u64]string{}
	mut by_tx_dup := map[u64]string{}
	for n in nodes {
		if c := n.uds {
			if c.tx != 0 {
				by_tx[c.tx] = n.name
			}
		}
	}
	for n in nodes {
		cfg := n.uds or { continue }
		if cfg.rx == 0 || cfg.tx == 0 {
			warns << 'uds on "${n.name}": rx and tx must both be set'
			continue
		}
		if cfg.rx == cfg.tx {
			// one ISO-TP channel cannot both listen and answer on a single id: the server
			// would receive its own responses and answer them
			warns << 'uds on "${n.name}": rx and tx are both 0x${cfg.rx:X}'
		}
		if cfg.rx > can_id_max || cfg.tx > can_id_max {
			// SocketCAN masks on send while the software channel matches unmasked, so the ECU
			// would transmit on a different valid id and never hear its tester
			warns << 'uds on "${n.name}": 0x${cfg.rx:X}/0x${cfg.tx:X} exceeds the 29-bit CAN id range'
		}
		if (cfg.rx > 0x7FF) != (cfg.tx > 0x7FF) {
			// ISO-TP uses one frame format for the pair; a mixed pair cannot be honoured
			warns << 'uds on "${n.name}": rx 0x${cfg.rx:X} and tx 0x${cfg.tx:X} mix 11-bit and 29-bit addressing'
		}
		for d in cfg.dids {
			if d.id > 0xFFFF {
				warns << 'uds on "${n.name}": DID 0x${d.id:X} is above the 16-bit range — ignored'
			}
		}
		for m in cfg.malformed {
			// a stripped character yields a different VALID id, so no range check can see it
			warns << 'uds on "${n.name}": ${m} is not a valid identifier'
		}
		if cfg.session > 0xFF {
			warns << 'uds on "${n.name}": session ${cfg.session} is not a byte'
		}
		mut seen_did := map[u32]bool{}
		for d in cfg.dids {
			if d.id in seen_did {
				// the map keeps the last, the panel and the file show both: which value the
				// wire serves would depend on YAML order
				warns << 'uds on "${n.name}": DID 0x${d.id:X} is defined more than once'
			}
			seen_did[d.id] = true
			if d.value_len() > max_did_bytes {
				// handle() prepends a 3-byte header; past 4095 the transfer cannot be sent and
				// the send error is discarded, so the tester sees only a timeout
				warns << 'uds on "${n.name}": DID 0x${d.id:X} is ${d.value_len()} bytes — over the ${max_did_bytes}-byte ISO-TP limit'
			}
		}
		for t in cfg.dtcs {
			if t.status > 0xFF {
				warns << 'uds on "${n.name}": DTC 0x${t.code:X} status ${t.status} is not a byte — ignored'
			}
			if t.code > 0xFFFFFF {
				// handle() writes the low three bytes, so 0x1123456 goes out as 0x123456 —
				// a different, possibly real, fault code
				warns << 'uds on "${n.name}": DTC 0x${t.code:X} is above the 24-bit range — ignored'
			}
		}
		mut usable_dtcs := 0
		for t in cfg.dtcs {
			if t.code <= 0xFFFFFF && t.status <= 0xFF {
				usable_dtcs++
			}
		}
		if usable_dtcs > max_dtcs {
			warns << 'uds on "${n.name}": ${usable_dtcs} DTCs exceed what one 0x19 response can carry (max ${max_dtcs}) — the extra are ignored'
		}
		if owner := by_tx[cfg.rx] {
			if owner != n.name { // rx == its OWN tx is the separate, already-reported case
				warns << 'uds on "${n.name}": request id 0x${cfg.rx:X} is "${owner}"\'s response id — it would consume that ECU\'s replies'
			}
		}
		if prev := by_tx_dup[cfg.tx] {
			if prev != n.name {
				// both ECUs answer on one id: a tester holding handles to both receives every
				// reply on both, and one ECU's response can be consumed as the other's result
				warns << 'uds on "${n.name}": response id 0x${cfg.tx:X} is also used by "${prev}"'
			}
		}
		by_tx_dup[cfg.tx] = n.name
		if prev := by_rx[cfg.rx] {
			// two servers listening on one id both answer, and the tester sees whichever
			// arrives first — a coin toss, not a configuration
			warns << 'uds on "${n.name}": request id 0x${cfg.rx:X} is already answered by "${prev}" — this server is not started'
		}
		by_rx[cfg.rx] = n.name
	}
	return warns
}
