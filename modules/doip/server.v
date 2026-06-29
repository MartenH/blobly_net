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

// ServerCfg is the entity's identity (for routing activation + announcements).
pub struct ServerCfg {
pub:
	logical_address u16 = 0x1000 // this entity's DoIP logical address
	vin             string = 'BLOBLYNETV0SUT001'
	eid             []u8 = [u8(0x02), 0x00, 0x00, 0x00, 0x00, 0x01] // entity id (≈ MAC)
	gid             []u8 = [u8(0x02), 0x00, 0x00, 0x00, 0x00, 0x01] // group id
}

// DiagHandler maps a UDS request PDU to a UDS response PDU (empty = no reply).
pub type DiagHandler = fn (req []u8) []u8

pub struct DoipServer {
	cfg     ServerCfg
	handler DiagHandler @[required]
mut:
	listener &net.TcpListener = unsafe { nil }
	udp      &net.UdpConn     = unsafe { nil }
	active   &net.TcpConn     = unsafe { nil } // the in-progress accepted connection (nil between)
	stopping bool // set by close(): stop accepting/serving and tear down the active conn
}

// new_server builds an entity with the given identity + UDS handler. Returns a
// heap pointer so it can be shared with serving threads (spawn needs a reference).
pub fn new_server(cfg ServerCfg, handler DiagHandler) &DoipServer {
	return &DoipServer{
		cfg:     cfg
		handler: handler
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
		ann := vehicle_announcement(s.cfg.vin, s.cfg.logical_address, s.cfg.eid, s.cfg.gid)
		s.udp.write_to(addr, ann) or {}
	}
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
