module project

import transport

// Moving a run's simulated DoIP entities off the project's ports (#411). The demo projects host
// their entities on 13400, the ISO port, which is right for interactive use and wrong for two
// test runs on one machine: the second cannot bind it. The headless runner picks free ports and
// rewrites the project through these two functions, so the hosted entity and every tester row
// dialing it still meet. What it must never touch is a row reaching somebody else's entity.

// Resolve is how a bind host becomes the address the bind uses — `transport.bind_address` in the
// runner, the resolution the entity's own listen makes — so `localhost` is compared as whichever
// of 127.0.0.1 and ::1 it is on this machine. A parameter so the rules test without DNS.
pub type Resolve = fn (host string) string

// DoipHosts is every DoIP row's host resolved ONCE (#416). The move asks what a host is when it
// lists the hosted endpoints, when it probes, when it matches a tester to an entity, and the
// runner asks again when it binds — and a name with several answers (round-robin DNS, or
// `localhost` where the two families race) could answer each of those differently, so a probe
// would hold one address while the entity bound another. One answer per host, carried to the
// bind, is what makes them the same address.
pub struct DoipHosts {
	addr map[string]string // configured host -> resolved address
}

// resolve_doip_hosts resolves the host of every DoIP row, once per distinct spelling.
pub fn resolve_doip_hosts(chs []Channel, resolve Resolve) DoipHosts {
	mut addr := map[string]string{}
	for ch in chs {
		if !ch.is_doip() {
			continue
		}
		host, _ := ch.doip_endpoint()
		if host !in addr {
			addr[host] = resolve(host)
		}
	}
	return DoipHosts{
		addr: addr
	}
}

// of is the address `host` resolved to. Every DoIP row's host is in the table; anything else is
// returned as written, never resolved again.
pub fn (t DoipHosts) of(host string) string {
	return t.addr[host] or { host }
}

// DoipHosting is one port the run's simulated entities bind on loopback IN ONE FAMILY, and the
// hosts bound there — what a caller must be able to bind before it moves that port. The families
// are separate entries, each given its own port (#416): a probe is released when the first entity
// on its port binds, and an entity bound on ::1 does not keep another run off 127.0.0.1, so one
// port shared across families could be taken by a concurrent IPv4 run between the two binds.
pub struct DoipHosting {
pub:
	port  int
	v6    bool
	hosts []string // as the rows write them (what the entity binds), in project order
}

// DoipMove is one hosting entry moved to port `to`.
pub struct DoipMove {
pub:
	hosting DoipHosting
	to      int
}

// is_loopback_host reports whether a resolved bind address is a loopback address. Only those are
// moved: an entity on a NIC or the wildcard may be dialed from another machine on the port the
// project states.
fn is_loopback_host(h string) bool {
	return h.starts_with('127.') || h == '::1'
}

// is_v6 reports whether a resolved address is an IPv6 one.
fn is_v6(addr string) bool {
	return addr.contains(':')
}

// hosts_entity reports whether a row hosts a simulated DoIP entity in a run: enabled, DoIP, with
// a simulated node — what the runner and the GUI's Start bind.
fn hosts_entity(ch Channel) bool {
	return ch.enabled && ch.hosts_doip_entity()
}

// doip_hosting lists the ports the enabled simulated DoIP entities bind on loopback, one entry
// per port and family, each with its hosts, in project order.
pub fn doip_hosting(chs []Channel, hosts DoipHosts) []DoipHosting {
	mut keys := []DoipHosting{} // port and family, in first-seen order
	mut listed := map[string][]string{}
	for ch in chs {
		if !hosts_entity(ch) {
			continue
		}
		host, port := ch.doip_endpoint()
		h := hosts.of(host)
		if !is_loopback_host(h) {
			continue
		}
		k := '${port}/${is_v6(h)}'
		if k !in listed {
			keys << DoipHosting{
				port: port
				v6:   is_v6(h)
			}
			listed[k] = []string{}
		}
		if !listed[k].any(hosts.of(it) == h) {
			listed[k] << host
		}
	}
	return keys.map(DoipHosting{ ...it, hosts: listed['${it.port}/${it.v6}'] })
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
// family asked (the IPv6 one is dual-stack), over TCP and UDP both since the entity binds both,
// and keeps it, answering false when either bind fails.
pub interface PortProber {
mut:
	hold(port int, v6 bool) bool
}

// choose_doip_ports picks a port for every entry of `hosting`: the first of `candidates` that is
// neither reserved, nor already given out, nor refused by `prober`, probed in the entry's family.
pub fn choose_doip_ports(hosting []DoipHosting, reserved []int, candidates []int, mut prober PortProber) ![]DoipMove {
	mut moves := []DoipMove{}
	mut given := map[int]bool{}
	for hs in hosting {
		mut to := 0
		for cand in candidates {
			if cand in reserved || cand in given {
				continue
			}
			if prober.hold(cand, hs.v6) {
				to = cand
				given[cand] = true
				break
			}
		}
		if to == 0 {
			return error('no free candidate port for ${hs.hosts.join(', ')} (from ${hs.port})')
		}
		moves << DoipMove{
			hosting: hs
			to:      to
		}
	}
	return moves
}

// with_doip_ports returns `chs` with every DoIP row that addresses a moved entity's endpoint —
// its host and its port as `doip_hosting` reported them — rewritten to the new port, and one line
// per rewritten row saying so. A row whose endpoint no simulated entity binds is left as written,
// so a tester dialing a real entity, or a loopback one this run does not host, keeps its port.
// A rewritten row names the ADDRESS its host resolved to, not the name: the family split leaves
// the other family's loopback free on the new port for a concurrent run, so a tester dialing
// `localhost` that resolved differently at dial time could reach that run's entity.
pub fn with_doip_ports(chs []Channel, moves []DoipMove, hosts DoipHosts) ([]Channel, []string) {
	mut hosted := map[string]int{} // resolved entity endpoint -> its new port
	for m in moves {
		for h in m.hosting.hosts {
			hosted[transport.udp_bind_addr(hosts.of(h), m.hosting.port)] = m.to
		}
	}
	mut out := chs.clone()
	mut notes := []string{}
	for mut ch in out {
		if !ch.is_doip() {
			continue
		}
		host, port := ch.doip_endpoint()
		to := hosted[transport.udp_bind_addr(hosts.of(host), port)] or { continue }
		was := ch.doip_effective_address()
		ch.adapter = 'doip'
		ch.address = transport.udp_bind_addr(hosts.of(host), to)
		ch.iface = compose_iface('doip', ch.address)
		ch.announce_to = with_moved_port(ch.announce_to, port, to)
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
