// server.v — DoipServer, a DoIP entity (simulated ECU / gateway) over TCP+UDP.
// It is protocol-AGNOSTIC: it speaks DoIP framing + routing activation + the diag
// message ack, and hands each diagnostic message's UDS user-data to a `handler`
// callback, sending whatever the handler returns back as a 0x8001 response. The
// caller wires uds.Server.handle as the handler, so doip imports neither uds nor
// isotp and stays a leaf transport module. UDP answers discovery (0x0001 → 0x0004).
//
// Threading is left to the caller (like isotp/sim): listen(), then drive
// accept_and_serve()/serve_udp_once() in loops/threads. GUI-free.
module doip

import net
import time
import sync

// Default entity identity (used by ServerCfg defaults and server_cfg()).
pub const default_vin = 'BLOBLYNETV0SUT001'
pub const default_eid = [u8(0x02), 0x00, 0x00, 0x00, 0x00, 0x01] // entity id (≈ MAC)

// ServerCfg is the entity's identity (for routing activation + announcements).
pub struct ServerCfg {
pub:
	logical_address u16 = 0x1000 // this entity's DoIP logical address
	vin             string = default_vin
	eid             []u8 = default_eid // entity id (≈ MAC)
	gid             []u8 = default_eid // group id
	// Power-on announcement (ISO 13400 A_DoIP_Announce_Num / A_DoIP_Announce_Interval). A real
	// entity announces itself when it gets its IP, three times, 500ms apart — that is how a
	// tester discovers ECUs it was never told about, by listening rather than asking. 0 = say
	// nothing, which is a legitimate ECU to simulate and a useful fault to inject.
	announce_count    int = announce_num_default
	announce_interval int = announce_interval_default // ms
	// Where announcements go. Empty derives it from the entity's own address: a loopback entity
	// broadcasts to 127.255.255.255 and never leaves the machine; anything else uses the
	// limited broadcast, which DOES go on the wire, exactly like a real ECU would.
	announce_to string
}

// ISO 13400 defaults: three announcements, 500ms apart.
pub const announce_num_default = 3
pub const announce_interval_default = 500

// server_cfg builds a ServerCfg from a logical address + optional VIN/EID, filling
// in the module defaults for any empty field. Lets callers in other modules set a
// per-entity identity without reaching the (read-only) struct fields directly.
pub fn server_cfg(logical_address u16, vin string, eid []u8) ServerCfg {
	id := if eid.len > 0 { eid } else { default_eid }
	return ServerCfg{
		logical_address: logical_address
		vin:             if vin != '' { vin } else { default_vin }
		eid:             id
		gid:             id
	}
}

// DiagHandler maps a UDS request PDU to a UDS response PDU (empty = no reply).
pub type DiagHandler = fn (req []u8) []u8

pub struct DoipServer {
	cfg     ServerCfg
	handler DiagHandler @[required]
mut:
	// The ANNOUNCED VIN, which has to be able to follow the SERVED one: a UDS write to DID
	// 0xF190 changes what the entity reports over TCP, and a fixed announcement would go on
	// advertising the VIN it had at startup. Guarded because the write arrives on the TCP
	// thread while the UDP loop reads it to answer discovery — replacing a string header
	// unsynchronised lets an announcement observe a torn value. Only this field is mutable;
	// the logical address, EID and GID never change, so they stay lock-free in cfg.
	vin_mu sync.Mutex
	vin    string
	listener &net.TcpListener = unsafe { nil }
	udp      &net.UdpConn     = unsafe { nil }
	// The host this entity bound to. announce() needs it to choose a destination, and asking
	// the socket back for it is more indirection than storing the one string.
	bound_host string
	bound_port int
	active   &net.TcpConn     = unsafe { nil } // the in-progress accepted connection (nil between)
	stopping bool // set by close(): stop accepting/serving and tear down the active conn
}

// new_server builds an entity with the given identity + UDS handler. Returns a
// heap pointer so it can be shared with serving threads (spawn needs a reference).
// announced_vin returns the VIN discovery should advertise right now.
fn (mut s DoipServer) announced_vin() string {
	s.vin_mu.lock()
	v := s.vin
	s.vin_mu.unlock()
	return v
}

pub fn new_server(cfg ServerCfg, handler DiagHandler) &DoipServer {
	// the announced VIN starts as the configured one and only moves if set_vin is called
	return &DoipServer{
		cfg:     cfg
		handler: handler
		vin:     cfg.vin
	}
}

// is_stopping reports whether close() has been called. Serve loops driven as
// `for { srv.accept_and_serve(t) or { continue } }` should break on it, otherwise
// they hot-spin after close() (the listener is shut so every call errors at once).
pub fn (s &DoipServer) is_stopping() bool {
	return s.stopping
}

// listen opens the TCP listener and UDP discovery socket on host:port. Atomic: if
// the UDP bind fails after the TCP listener is already open, the TCP listener is
// closed before returning, so a failed listen() never leaves a socket bound. An
// IPv6 host literal (one containing ':') is bracketed and bound on the IPv6 family.
pub fn (mut s DoipServer) listen(host string, port int) ! {
	s.bound_host = host
	s.bound_port = port
	addr := join_host_port(host, port)
	s.listener = net.listen_tcp(addr_family(host), addr)!
	s.udp = net.listen_udp(addr) or {
		s.listener.close() or {}
		s.listener = unsafe { nil }
		return err
	}
}

// join_host_port formats host:port for net dial/listen, bracketing an IPv6 literal
// (a host containing ':', e.g. ::1) as [host]:port. IPv4/hostnames are host:port.
fn join_host_port(host string, port int) string {
	if host.contains(':') && !host.starts_with('[') {
		return '[${host}]:${port}'
	}
	return '${host}:${port}'
}

// addr_family picks the socket family for a host: ip6 for an IPv6 literal, else ip.
fn addr_family(host string) net.AddrFamily {
	return if host.contains(':') { net.AddrFamily.ip6 } else { net.AddrFamily.ip }
}

// accept_and_serve waits up to timeout_ms for a TCP connection, then serves its
// request/response loop until the peer disconnects. Returns an error on accept
// timeout (so callers can poll a shutdown flag between attempts).
//
// NOTE: one connection is served to completion before the next is accepted, so a
// stale peer can delay others (see docs/ethernet_architecture.md "Known
// limitations"). Intentional for the single-tester virtual-first scope; a
// thread-per-connection model would need handler synchronisation (uds.Server is
// not thread-safe).
pub fn (mut s DoipServer) accept_and_serve(timeout_ms int) ! {
	if s.stopping {
		return error('DoIP server stopping')
	}
	s.listener.set_accept_timeout(timeout_ms * time.millisecond)
	mut conn := s.listener.accept()!
	// Publish the accepted connection so close() can tear it down from another
	// thread (Stop), interrupting an otherwise-blocking per-connection read.
	s.active = conn
	s.serve_connection(mut conn)
	s.active = unsafe { nil }
	conn.close() or {}
}

// serve_connection handles one client: routing activation, then diagnostic
// messages (ack + handler reply) until the peer closes the connection. Per
// ISO 13400, diagnostics are only dispatched after a successful routing
// activation on this connection.
fn (mut s DoipServer) serve_connection(mut conn net.TcpConn) {
	mut activated := false
	mut tester_source := u16(0) // the source address activated on this connection
	for {
		if s.stopping {
			return // Stop requested — drop the connection without serving further
		}
		msg := read_message(mut conn, 60000) or { return } // peer closed / timeout / closed by Stop
		match msg.payload_type {
			pt_routing_activation_request {
				ra := parse_routing_activation_request(msg.payload) or { continue }
				if activated && ra.source != tester_source {
					// already activated with a different source — deny and keep the
					// first source, so re-activation can't bypass the source guard.
					conn.write(routing_activation_response(ra.source, s.cfg.logical_address,
						ra_denied_source_mismatch)) or { return }
					continue
				}
				conn.write(routing_activation_response(ra.source, s.cfg.logical_address,
					ra_success)) or { return }
				activated = true
				tester_source = ra.source
			}
			pt_diagnostic_message {
				if !activated {
					continue // routing activation is mandatory before diagnostics
				}
				dm := parse_diagnostic_message(msg.payload) or { continue }
				if dm.source != tester_source {
					// spoofed source (≠ the activated tester) — NACK, don't dispatch.
					conn.write(diagnostic_message_nack(s.cfg.logical_address, dm.source,
						diag_nack_invalid_source)) or { return }
					continue
				}
				if dm.target != s.cfg.logical_address {
					// not addressed to this entity — NACK, don't ack/dispatch.
					conn.write(diagnostic_message_nack(s.cfg.logical_address, dm.source,
						diag_nack_unknown_target)) or { return }
					continue
				}
				// positive ack first (entity → tester), then the UDS response.
				conn.write(diagnostic_message_ack(s.cfg.logical_address, dm.source, diag_ack_ok)) or {
					return
				}
				resp := s.handler(dm.data)
				if resp.len > 0 {
					conn.write(diagnostic_message(s.cfg.logical_address, dm.source, resp)) or {
						return
					}
				}
			}
			else {} // ignore (alive-check, etc.)
		}
	}
}

// serve_udp_once waits up to timeout_ms for a UDP datagram; if it's a vehicle
// identification request (0x0001) it replies to the sender with an announcement
// (0x0004). Returns an error on timeout.
pub fn (mut s DoipServer) serve_udp_once(timeout_ms int) ! {
	s.udp.set_read_timeout(timeout_ms * time.millisecond)
	mut buf := []u8{len: 64}
	n, addr := s.udp.read(mut buf)!
	if n < header_len {
		return
	}
	msg := parse(buf[..n]) or { return }
	if msg.payload_type == pt_vehicle_id_request {
		ann := vehicle_announcement(s.announced_vin(), s.cfg.logical_address, s.cfg.eid,
			s.cfg.gid)
		s.udp.write_to(addr, ann) or {}
	}
}

// announce sends the power-on vehicle announcements. Blocking: count × interval.
//
// Sent from the entity's OWN socket, so the source address is the one a tester will dial back.
// SO_BROADCAST has to be set explicitly or the send fails with EACCES.
pub fn (mut s DoipServer) announce() ! {
	if s.cfg.announce_count <= 0 {
		return // deliberately silent
	}
	if isnil(s.udp) {
		return error('announce before listen')
	}
	dest := if s.cfg.announce_to != '' {
		// the bound port here as well: fixing only the derived branch left an explicit
		// host-only announce_to (e.g. "127.255.255.255") going to 13400 on a custom-port entity
		with_port(s.cfg.announce_to, s.bound_port)
	} else {
		// The port this entity BOUND, not the module default: an entity on a custom port
		// announced to 13400, so a listener on the configured port heard nothing while direct
		// discovery and TCP both worked — a mismatch only an explicit announce_to could avoid.
		broadcast_for_port(s.bound_host, s.bound_port)
	}
	s.udp.sock.set_option_bool(.broadcast, true) or {
		return error('cannot enable broadcast: ${err}')
	}
	// The family of the SOCKET, unless the destination is an explicit literal of the other
	// kind. Choosing by punctuation alone classified every hostname as IPv4, so an IPv6 entity
	// with `announce_to: localhost` (or an AAAA-only alias) resolved to a sockaddr its socket
	// cannot send to.
	bound_v6 := s.bound_host.contains(':')
	literal_v6 := dest.starts_with('[') || dest.trim('[]').count(':') > 1
	fam := if literal_v6 || bound_v6 { net.AddrFamily.ip6 } else { net.AddrFamily.ip }
	addrs := net.resolve_addrs(dest, fam, .udp) or { return error('announce_to ${dest}: ${err}') }
	if addrs.len == 0 {
		return error('announce_to ${dest}: resolved to nothing') // indexing [0] would panic
	}
	for i in 0 .. s.cfg.announce_count {
		if s.stopping {
			return // Stop, a toggle, or a script run ending; the fd may already be gone
		}
		ann := vehicle_announcement(s.announced_vin(), s.cfg.logical_address, s.cfg.eid,
			s.cfg.gid)
		s.udp.write_to(addrs[0], ann) or { return error('announce to ${dest}: ${err}') }
		if i + 1 < s.cfg.announce_count {
			// SLICED, so a cancel lands within ~50ms instead of at the end of the interval.
			// One sleep(60s) meant teardown still waited a full minute for a 100 × 60s
			// sequence — better than the 100 minutes before it, and still a hung suite.
			mut left := s.cfg.announce_interval
			for left > 0 {
				if s.stopping {
					return
				}
				step := if left > 50 { 50 } else { left }
				time.sleep(step * time.millisecond)
				left -= step
			}
		}
	}
}

// broadcast_for picks the destination for an entity bound to `host`. A loopback entity stays on
// the machine (127.255.255.255); anything else uses the limited broadcast and reaches the
// network the bench is on.
pub fn broadcast_for(host string) string {
	return broadcast_for_port(host, port)
}

// broadcast_for_port is broadcast_for with the port the entity is actually on.
pub fn broadcast_for_port(host string, port_ int) string {
	h := host.trim_space().trim('[]')
	if h.contains(':') {
		// IPv6 has no broadcast; the equivalent reach is the link-local all-nodes multicast.
		// Sending 255.255.255.255 from an IPv6 socket fails ENETUNREACH, so every IPv6 entity
		// logged "announce failed" at each Start and never announced.
		//
		// KEEP THE ZONE. Link-local multicast needs an interface scope, so an entity bound to
		// fe80::1%eth0 must announce to ff02::1%eth0 — dropping it leaves a multihomed host to
		// guess the outgoing interface, which is how an announcement goes out the wrong one.
		if zone := h.split('%')[1] or { '' } {
			if zone != '' {
				return '[ff02::1%${zone}]:${port_}'
			}
		}
		return '[ff02::1]:${port_}'
	}
	if h.starts_with('127.') || h == 'localhost' {
		return '127.255.255.255:${port_}'
	}
	return '255.255.255.255:${port_}'
}

// with_port appends the DoIP port when a destination carries none. resolve_addrs needs
// host:port and silently resolves a bare address to port 0, which then fails EINVAL.
fn with_port(dest string, port_ int) string {
	d := dest.trim_space()
	if d.starts_with('[') {
		return if d.contains(']:') { d } else { '${d}:${port_}' }
	}
	return if d.count(':') == 1 { d } else if d.contains(':') { '[${d}]:${port_}' } else { '${d}:${port_}' }
}

// set_vin updates the VIN this entity ANNOUNCES, so discovery keeps naming the same ECU the
// UDS server serves. Callers are responsible for the two agreeing; see cmd/script/run.v.
pub fn (mut s DoipServer) set_vin(vin string) {
	s.vin_mu.lock()
	s.vin = vin
	s.vin_mu.unlock()
}

// close stops the entity and releases its sockets. It is safe to call from a
// different thread than the serving loop (e.g. a GUI Stop): it sets `stopping`
// and closes the currently-active accepted connection, so a serve loop blocked in
// a per-connection read is interrupted rather than waiting out the read timeout.
pub fn (mut s DoipServer) close() {
	s.stopping = true
	if !isnil(s.active) {
		s.active.close() or {}
	}
	if !isnil(s.listener) {
		s.listener.close() or {}
	}
	if !isnil(s.udp) {
		s.udp.close() or {}
	}
}

// read_message reads one full DoIP message from a TCP stream (shared by client).
// The payload buffer comes straight from read_exact (already a fresh allocation),
// so we build the Message directly rather than reassembling the wire bytes and
// re-parsing them.
fn read_message(mut conn net.TcpConn, timeout_ms int) !Message {
	conn.set_read_timeout(timeout_ms * time.millisecond)
	header := read_exact(mut conn, header_len)!
	payload_type, payload_len := parse_header(header)!
	if payload_len > max_payload_len {
		return error('DoIP payload too large: ${payload_len} > ${max_payload_len}')
	}
	payload := if payload_len > 0 { read_exact(mut conn, int(payload_len))! } else { []u8{} }
	return Message{
		payload_type: payload_type
		payload:      payload
	}
}

// read_exact reads exactly n bytes (TCP may deliver them in pieces), filling the
// output buffer in place via read_ptr — each read targets the unfilled tail at
// &out[got], so there's no temp buffer and no copy.
fn read_exact(mut conn net.TcpConn, n int) ![]u8 {
	mut out := []u8{len: n}
	mut got := 0
	for got < n {
		r := conn.read_ptr(unsafe { &out[got] }, n - got)!
		if r <= 0 {
			return error('DoIP: connection closed mid-message')
		}
		got += r
	}
	return out
}
