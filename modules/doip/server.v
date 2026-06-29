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
}

// new_server builds an entity with the given identity + UDS handler. Returns a
// heap pointer so it can be shared with serving threads (spawn needs a reference).
pub fn new_server(cfg ServerCfg, handler DiagHandler) &DoipServer {
	return &DoipServer{
		cfg:     cfg
		handler: handler
	}
}

// listen opens the TCP listener and UDP discovery socket on host:port.
pub fn (mut s DoipServer) listen(host string, port int) ! {
	s.listener = net.listen_tcp(.ip, '${host}:${port}')!
	s.udp = net.listen_udp('${host}:${port}')!
}

// accept_and_serve waits up to timeout_ms for a TCP connection, then serves its
// request/response loop until the peer disconnects. Returns an error on accept
// timeout (so callers can poll a shutdown flag between attempts).
pub fn (mut s DoipServer) accept_and_serve(timeout_ms int) ! {
	s.listener.set_accept_timeout(timeout_ms * time.millisecond)
	mut conn := s.listener.accept()!
	s.serve_connection(mut conn)
	conn.close() or {}
}

// serve_connection handles one client: routing activation, then diagnostic
// messages (ack + handler reply) until the peer closes the connection. Per
// ISO 13400, diagnostics are only dispatched after a successful routing
// activation on this connection.
fn (mut s DoipServer) serve_connection(mut conn net.TcpConn) {
	mut activated := false
	for {
		msg := read_message(mut conn, 60000) or { return } // peer closed / timeout
		match msg.payload_type {
			pt_routing_activation_request {
				ra := parse_routing_activation_request(msg.payload) or { continue }
				conn.write(routing_activation_response(ra.source, s.cfg.logical_address,
					ra_success)) or { return }
				activated = true
			}
			pt_diagnostic_message {
				if !activated {
					continue // routing activation is mandatory before diagnostics
				}
				dm := parse_diagnostic_message(msg.payload) or { continue }
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

pub fn (mut s DoipServer) close() {
	if !isnil(s.listener) {
		s.listener.close() or {}
	}
	if !isnil(s.udp) {
		s.udp.close() or {}
	}
}

// read_message reads one full DoIP message from a TCP stream (shared by client).
fn read_message(mut conn net.TcpConn, timeout_ms int) !Message {
	conn.set_read_timeout(timeout_ms * time.millisecond)
	header := read_exact(mut conn, header_len)!
	_, payload_len := parse_header(header)!
	if payload_len > max_payload_len {
		return error('DoIP payload too large: ${payload_len} > ${max_payload_len}')
	}
	payload := if payload_len > 0 { read_exact(mut conn, int(payload_len))! } else { []u8{} }
	mut full := header.clone()
	full << payload
	return parse(full)!
}

fn read_exact(mut conn net.TcpConn, n int) ![]u8 {
	mut out := []u8{len: n}
	mut got := 0
	for got < n {
		mut chunk := []u8{len: n - got}
		r := conn.read(mut chunk)!
		if r <= 0 {
			return error('DoIP: connection closed mid-message')
		}
		for i in 0 .. r {
			out[got + i] = chunk[i]
		}
		got += r
	}
	return out
}
