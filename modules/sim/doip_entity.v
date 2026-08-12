// Deciding what a DoIP channel hosts. Shared by the headless runner and the GUI, because an
// entity that comes up differently depending on which started it is worse than one that does
// not come up at all: a bench result would depend on how the tool was launched.
module sim

import project
import uds
import doip

// DoipEntity is one channel's entity: the server to serve, and the VIN discovery announces.
//
// `announce` is always the SAME string the server returns for DID 0xF190. An entity has two
// identity surfaces and they must not be able to disagree — a tester that finds one ECU on the
// network and reads another out of it has no way to tell which is the lie.
pub struct DoipEntity {
pub:
	// The server config to bind with, built HERE so the GUI and the runner cannot announce
	// differently — the same reason the identity decision lives here.
	cfg      doip.ServerCfg
	node     string // the UDS node being served; '' = the built-in default server
	announce string // the announced VIN, always == the served DID 0xF190
	extra    int    // configured UDS nodes beyond the one served
pub mut:
	server uds.Server
}

// node_label names the served node for a UI list; the built-in default has no node name.
pub fn (e DoipEntity) node_label() string {
	return if e.node != '' { e.node } else { 'default entity' }
}

// doip_entity decides what `ch` should host, or refuses.
//
// It refuses rather than improvises in three cases, all of which would otherwise produce an
// entity that answers confidently with the wrong identity:
//
//   - every configured UDS node was rejected. Serving the built-in default in their place
//     turns a broken configuration into a passing test.
//   - `vin:` and the served DID 0xF190 disagree. Picking either silently makes the other a lie.
//   - the resolved VIN is not exactly 17 bytes. vehicle_announcement zero-pads or truncates to
//     17 while the server returns it whole, so the two surfaces would differ by construction.
pub fn doip_entity(ch project.Channel, nodes []project.NodeCfg) !DoipEntity {
	mut declared := 0
	for n in nodes {
		if _ := n.uds {
			declared++
		}
	}
	mut built := uds_nodes_doip(nodes)
	if built.len == 0 && declared > 0 {
		return error('all ${declared} configured UDS node(s) rejected — refusing to serve the built-in default in their place')
	}
	mut srv := if built.len > 0 { built[0].server } else { uds.default_server() }
	name := if built.len > 0 { built[0].name } else { '' }

	// A CONFIGURED node's DID is the identity. The fallback server's 0xF190 is a module
	// default rather than a configuration, so it must not win the same way.
	mut announce := ch.vin
	if built.len > 0 {
		if v := srv.dids[u16(0xF190)] {
			node_vin := v.bytestr()
			if node_vin == '' {
				// PRESENT and empty is not the same as absent. Falling through to the default
				// below would overwrite a configured DID with the stock VIN and skip the
				// 17-byte check entirely, so a broken project would come up as a plausible
				// entity and let tests pass against data it never configured.
				return error('node "${name}" defines DID 0xF190 with no value — an entity cannot announce an empty VIN')
			}
			if ch.vin != '' && node_vin != ch.vin {
				return error('vin "${ch.vin}" and node "${name}" DID 0xF190 "${node_vin}" are two identities for one entity')
			}
			announce = node_vin
		} else if ch.vin != '' {
			// Announced but not served: reading 0xF190 would answer NRC while discovery
			// advertised a VIN. Serve what is announced.
			srv.dids[0xF190] = ch.vin.bytes()
		}
	} else if ch.vin != '' {
		srv.dids[0xF190] = ch.vin.bytes()
	}
	if announce == '' {
		// Nothing configured either way: server_cfg advertises its built-in default, so serve
		// that same string rather than answering NRC 0x31 for the DID it just advertised.
		announce = doip.default_vin
		srv.dids[0xF190] = announce.bytes()
	}
	if announce.len != 17 {
		return error('VIN "${announce}" is ${announce.len} bytes, not 17 — discovery would advertise a padded or truncated string while 0xF190 serves this one')
	}
	return DoipEntity{
		// server_cfg() fills the module defaults for an absent eid; passing ch.eid straight
		// into the struct suppressed them, so a channel without `eid:` advertised
		// 00:00:00:00:00:01 as all zeros in every announcement and discovery reply.
		cfg:      doip.ServerCfg{
			...doip.server_cfg(ch.ecu_addr, announce, ch.eid)
			announce_count:    ch.announce_count
			announce_interval: ch.announce_interval
			announce_to:       ch.announce_to
		}
		node:     name
		announce: announce
		extra:    if built.len > 1 { built.len - 1 } else { 0 }
		server:   srv
	}
}
