module project

import transport

// What the Discover dialog does with a DoIP entity it found: the channel it would add, and
// whether the project already has it. Here rather than in the GUI because both are decisions
// about what a channel means — the endpoint grammar is eth_endpoint's.

// DoipFound is one entity as discovery saw it: where a tester dials it, its logical address
// and its VIN ('' when it reported none).
pub struct DoipFound {
pub:
	address string // host:port
	logical u16
	vin     string
}

// doip_found_channel is the channel that reaches `f`: adapter `doip` at its address, the
// entity's logical address as the ECU, the default tester address, named after the VIN — or
// the address when there is none. The VIN is kept only when it is a whole one.
pub fn doip_found_channel(f DoipFound) Channel {
	address := f.address.trim_space()
	return Channel{
		name:     if f.vin != '' { f.vin } else { address }
		adapter:  'doip'
		address:  address
		iface:    compose_iface('doip', address)
		typ:      'doip'
		ecu_addr: f.logical
		vin:      if f.vin.len == 17 { f.vin } else { '' }
	}
}

// doip_found_at reports whether DoIP channel `c` dials the entity `f` was found at: the
// endpoint as Start would dial it, so `192.168.0.50` and `192.168.0.50:13400` are one.
pub fn doip_found_at(c Channel, f DoipFound) bool {
	if !c.is_doip() {
		return false
	}
	want_host, want_port := doip_found_channel(f).doip_endpoint()
	host, port := c.doip_endpoint()
	return port == want_port && host.to_lower() == want_host.to_lower()
}

// doip_found_in reports whether a DoIP channel already reaches `f`: the same endpoint and the
// same ECU address.
pub fn doip_found_in(chs []Channel, f DoipFound) bool {
	return chs.any(it.ecu_addr == f.logical && doip_found_at(it, f))
}

// doip_effective_address is the host:port Start dials for a DoIP channel, the defaults filled
// in — what a row shows, so a port left out is not a port nobody can see.
pub fn (ch Channel) doip_effective_address() string {
	host, port := ch.doip_endpoint()
	return effective(host, port)
}

// effective joins an endpoint for display. A host still holding ONE colon is an address whose
// port the grammar refused (eth_endpoint keeps it whole): shown as typed, not bracketed into
// something that looks like an IPv6 literal on the default port.
fn effective(host string, port int) string {
	if host.count(':') == 1 {
		return host
	}
	return transport.udp_bind_addr(host, port)
}

// someip_effective_address is the same for a SOME/IP listener's bind endpoint.
pub fn (ch Channel) someip_effective_address() string {
	host, port := ch.someip_endpoint()
	return effective(host, port)
}
