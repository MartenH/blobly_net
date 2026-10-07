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

// Resolve is how a bind host becomes the address the bind uses — `transport.bind_address` in the
// runner, the resolution the entity's own listen makes — so `localhost` is compared as whichever
// of 127.0.0.1 and ::1 it is on this machine. A parameter so the rules test without DNS.
pub type Resolve = fn (host string) string

// is_loopback_host reports whether a resolved bind address is a loopback address. Only those are
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
pub fn doip_hosting(chs []Channel, resolve Resolve) []DoipHosting {
	mut ports := []int{}
	mut hosts := map[int][]string{}
	for ch in chs {
		if !hosts_entity(ch) {
			continue
		}
		host, port := ch.doip_endpoint()
		h := resolve(host)
		if !is_loopback_host(h) {
			continue
		}
		if port !in hosts {
			ports << port
			hosts[port] = []string{}
		}
		if !hosts[port].any(resolve(it) == h) {
			hosts[port] << host
		}
	}
	return ports.map(DoipHosting{ port: it, hosts: hosts[it] })
}

// reserved_ports lists every port the project's Ethernet rows name — DoIP entities and the
// endpoints tester rows dial, SOME/IP listeners — enabled or not. A moved entity is never given
// one: an unmoved entity's bind (on `0.0.0.0`, say) would cover it, and a row dialing that port
// meant something else there.
pub fn reserved_ports(chs []Channel) []int {
	mut out := []int{}
	for ch in chs {
		port := if ch.is_doip() {
			_, p := ch.doip_endpoint()
			p
		} else if ch.is_someip() {
			_, p := ch.someip_endpoint()
			p
		} else {
			continue
		}
		if port !in out {
			out << port
		}
	}
	return out
}

// PortProber holds a port for the caller once it binds it: `hold` binds the wildcard of the
// family asked (the IPv6 one is dual-stack) and keeps it, answering false when the bind fails.
pub interface PortProber {
mut:
	hold(port int, v6 bool) bool
}

// choose_doip_ports picks a port for every entry of `hosting`: the first of `candidates` that is
// neither reserved, nor already given out, nor refused by `prober`. The family probed is the one `resolve` gives a host, as
// the entity's bind resolves it, so a name that resolves to ::1 is probed on IPv6.
pub fn choose_doip_ports(hosting []DoipHosting, reserved []int, candidates []int, resolve Resolve, mut prober PortProber) !map[int]int {
	mut moved := map[int]int{}
	mut given := map[int]bool{}
	for hs in hosting {
		v6 := hs.hosts.any(resolve(it).contains(':'))
		for cand in candidates {
			if cand in reserved || cand in given {
				continue
			}
			if prober.hold(cand, v6) {
				moved[hs.port] = cand
				given[cand] = true
				break
			}
		}
		if hs.port !in moved {
			return error('no free candidate port for ${hs.hosts.join(', ')} (from ${hs.port})')
		}
	}
	return moved
}

// with_doip_ports returns `chs` with every DoIP row that addresses a moved entity's endpoint —
// its host and its port as `doip_hosting` reported them — rewritten to the new port, and one line
// per rewritten row saying so. A row whose endpoint no simulated entity binds is left as written,
// so a tester dialing a real entity, or a loopback one this run does not host, keeps its port.
pub fn with_doip_ports(chs []Channel, moved map[int]int, resolve Resolve) ([]Channel, []string) {
	mut hosted := map[string]bool{}
	for hs in doip_hosting(chs, resolve) {
		if hs.port in moved {
			for h in hs.hosts {
				hosted[transport.udp_bind_addr(resolve(h), hs.port)] = true
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
		if transport.udp_bind_addr(resolve(host), port) !in hosted {
			continue
		}
		was := ch.doip_effective_address()
		ch.adapter = 'doip'
		ch.address = transport.udp_bind_addr(host, moved[port])
		ch.iface = compose_iface('doip', ch.address)
		ch.announce_to = with_moved_port(ch.announce_to, port, moved[port])
		notes << '${ch.name}: DoIP ${was} -> ${ch.address} for this run'
	}
	return out, notes
}

// with_moved_port is an announce_to destination with its port moved from `from` to `to` when it
// names `from` explicitly; a host-only destination already follows the entity's bound port.
fn with_moved_port(dest string, from int, to int) string {
	d := dest.trim_space()
	suffix := ':${from}'
	if !d.ends_with(suffix) {
		return dest
	}
	host := d[..d.len - suffix.len]
	// `host:port` or `[v6]:port`; an unbracketed IPv6 literal ending in those digits is a host
	if host == '' || (host.contains(':') && !(host.starts_with('[') && host.ends_with(']'))) {
		return dest
	}
	return '${host}:${to}'
}
