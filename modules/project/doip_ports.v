module project

import transport

// Moving a run's simulated DoIP entities off the project's ports (#411). The demo projects host
// their entities on 13400, the ISO port, which is right for interactive use and wrong for two
// test runs on one machine: the second cannot bind it. The headless runner picks free ports and
// rewrites the project through these two functions, so the hosted entity and every tester row
// dialing it still meet. What it must never touch is a row reaching somebody else's entity.

// DoipHosting is one port the run's simulated entities bind on loopback, and the hosts bound
// there — what a caller must be able to bind before it moves that port.
pub struct DoipHosting {
pub:
	port  int
	hosts []string // as the rows write them (what the entity binds), in project order
}

// is_loopback_host reports whether a normalised bind host is a loopback address. Only those are
// moved: an entity on a NIC or the wildcard may be dialed from another machine on the port the
// project states.
fn is_loopback_host(h string) bool {
	return h.starts_with('127.') || h == '::1'
}

// hosts_entity reports whether a row hosts a simulated DoIP entity in a run: enabled, DoIP, with
// a simulated node — what the runner and the GUI's Start bind.
fn hosts_entity(ch Channel) bool {
	return ch.enabled && ch.is_doip() && ch.all_nodes().len > 0
}

// doip_hosting lists the ports the enabled simulated DoIP entities bind on loopback, each with
// its hosts, in project order.
pub fn doip_hosting(chs []Channel) []DoipHosting {
	mut ports := []int{}
	mut hosts := map[int][]string{}
	for ch in chs {
		if !hosts_entity(ch) {
			continue
		}
		host, port := ch.doip_endpoint()
		h := normalised_bind_host(host)
		if !is_loopback_host(h) {
			continue
		}
		if port !in hosts {
			ports << port
			hosts[port] = []string{}
		}
		if !hosts[port].any(normalised_bind_host(it) == h) {
			hosts[port] << host
		}
	}
	return ports.map(DoipHosting{ port: it, hosts: hosts[it] })
}

// with_doip_ports returns `chs` with every DoIP row that addresses a moved entity's endpoint —
// its host and its port as `doip_hosting` reported them — rewritten to the new port, and one line
// per rewritten row saying so. A row whose endpoint no simulated entity binds is left as written,
// so a tester dialing a real entity, or a loopback one this run does not host, keeps its port.
pub fn with_doip_ports(chs []Channel, moved map[int]int) ([]Channel, []string) {
	mut hosted := map[string]bool{}
	for hs in doip_hosting(chs) {
		if hs.port in moved {
			for h in hs.hosts {
				hosted[transport.udp_bind_addr(normalised_bind_host(h), hs.port)] = true
			}
		}
	}
	mut out := chs.clone()
	mut notes := []string{}
	for mut ch in out {
		if !ch.is_doip() {
			continue
		}
		host, port := ch.doip_endpoint()
		if transport.udp_bind_addr(normalised_bind_host(host), port) !in hosted {
			continue
		}
		was := ch.doip_effective_address()
		ch.adapter = 'doip'
		ch.address = transport.udp_bind_addr(host, moved[port])
		ch.iface = compose_iface('doip', ch.address)
		notes << '${ch.name}: DoIP ${was} -> ${ch.address} for this run'
	}
	return out, notes
}
