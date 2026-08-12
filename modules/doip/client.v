// client.v — DoipClient, a DoIP tester over TCP. It implements the SAME shape as
// isotp.Channel (iface/tx_id/rx_id + send/recv/close), so the existing uds.Client
// rides it unchanged: `uds.new_client(open_doip(...)!)` speaks UDS over Ethernet.
//
// open_doip() does the TCP connect + routing activation handshake; send() wraps a
// UDS request in a 0x8001 diagnostic message; recv() returns the UDS user-data of
// the response, transparently skipping the 0x8002 positive ack. GUI-free.
module doip

import net
import time

// discover sends a UDP vehicle-identification request to host:port and returns the
// entity's announcement, or an error on timeout / wrong reply. Unicast — works on
// loopback and against a known gateway IP; a subnet broadcast scan can layer on
// later. Driver-free; no TCP connection / routing activation needed.
pub fn discover(host string, port int, timeout_ms int) !VehicleInfo {
	addr := join_host_port(host, port) // brackets an IPv6 literal
	mut u := net.dial_udp(addr)!
	defer {
		u.close() or {}
	}
	u.write(vehicle_id_request())!
	u.set_read_timeout(timeout_ms * time.millisecond)
	mut buf := []u8{len: 64}
	n, _ := u.read(mut buf)!
	msg := parse(buf[..n])!
	if msg.payload_type != pt_vehicle_announcement {
		return error('expected vehicle announcement, got 0x${msg.payload_type:04X}')
	}
	return parse_vehicle_announcement(msg.payload)!
}

// DoipClient is a connected DoIP tester. The isotp.Channel fields map as:
//   tx_id = our (tester) source logical address, rx_id = the ECU target address.
pub struct DoipClient {
pub:
	iface string // "host:port" for logging/identification
	tx_id u32    // source (tester) logical address
	rx_id u32    // target (ECU) logical address
mut:
	conn   &net.TcpConn = unsafe { nil }
	source u16
	target u16
}

// open_doip connects to a DoIP entity, performs routing activation, and returns a
// ready tester channel. `source` is our logical address, `target` the ECU's.
// collect_announcements listens for unsolicited vehicle announcements for `window_ms`.
//
// The counterpart to DoipServer.announce(): a tester that discovers ECUs by LISTENING rather
// than asking. Binds the wildcard address so it hears broadcasts — which coexists with entities
// bound to specific addresses on the same port (verified; they do not conflict).
// Announcement is one heard announcement AND where it came from.
//
// VIN and logical address are not routable: a tester that discovers an ECU passively still has
// to dial it, and `doip:<host>:<port>` needs the peer. Dropping it made passive discovery
// unable to reach what it had just found.
pub struct Announcement {
pub:
	info VehicleInfo
	from string // the sender's host:port, ready for open_doip / a channel interface
}

// collect_announcements listens for unsolicited announcements for `window_ms`.
//
// Binds the IPv6 wildcard when asked for v6 (`ip6: true`), which on a dual-stack host also
// receives IPv4 senders; an IPv4-only bind cannot see IPv6 announcements at all.
pub fn collect_announcements_af(port_ int, window_ms int, ip6 bool) ![]Announcement {
	addr := if ip6 { '[::]:${port_}' } else { '0.0.0.0:${port_}' }
	mut c := net.listen_udp(addr) or {
		return error('cannot listen for announcements on ${addr}: ${err}')
	}
	defer {
		c.close() or {}
	}
	return collect_on(mut c, window_ms)
}

// collect_on reads announcements from an already-bound socket for window_ms.
fn collect_on(mut c net.UdpConn, window_ms int) ![]Announcement {
	mut out := []Announcement{}
	// MONOTONIC. A wall-clock deadline moves under NTP or a VM time correction, which either
	// ends the window early and loses announcements or stretches the next socket timeout far
	// past window_ms. The rest of this module uses ticks() for the same reason.
	deadline := time.ticks() + i64(window_ms)
	for {
		left := deadline - time.ticks()
		if left <= 0 {
			break
		}
		c.set_read_timeout(left * time.millisecond)
		mut buf := []u8{len: 128}
		n, peer := c.read(mut buf) or { break } // timeout ends the window
		if n < header_len {
			continue
		}
		msg := parse(buf[..n]) or { continue }
		if msg.payload_type != pt_vehicle_announcement {
			continue
		}
		info := parse_vehicle_announcement(msg.payload) or { continue }
		out << Announcement{
			info: info
			from: peer.str()
		}
	}
	return out
}

// collect_announcements_triggered binds the listener, THEN fires `trigger`, then collects.
//
// A caller that triggers and then listens has a race it cannot close: with announce_count 1, or
// interval 0, the whole sequence can be sent before the socket is bound and the result is a
// false empty discovery. Doing both here removes the ordering from the caller entirely.
pub fn collect_announcements_triggered(port_ int, window_ms int, ip6 bool, trigger fn () !) ![]Announcement {
	addr := if ip6 { '[::]:${port_}' } else { '0.0.0.0:${port_}' }
	mut c := net.listen_udp(addr) or {
		return error('cannot listen for announcements on ${addr}: ${err}')
	}
	defer {
		c.close() or {}
	}
	// bound now — safe to let the sequence go. The failure is CAPTURED, not dropped: a send
	// that fails (unresolvable announce_to, no IPv6 route, socket closed) would otherwise wait
	// out the window and return an empty success, indistinguishable from an ECU that
	// legitimately said nothing — which is exactly what a negative discovery test asserts.
	mut cell := &TriggerErr{}
	spawn fn (g fn () !, mut e TriggerErr) {
		g() or { e.msg = err.msg() }
	}(trigger, mut cell)
	out := collect_on(mut c, window_ms)!
	if cell.msg != '' {
		return error('announcement trigger failed: ${cell.msg}')
	}
	return out
}

// TriggerErr carries a spawned trigger's failure back to the collector.
struct TriggerErr {
mut:
	msg string
}

// collect_announcements is the IPv4 form, kept for callers that do not care.
pub fn collect_announcements(port_ int, window_ms int) ![]Announcement {
	return collect_announcements_af(port_, window_ms, false)
}

pub fn open_doip(host string, port int, source u16, target u16) !&DoipClient {
	addr := join_host_port(host, port) // brackets an IPv6 literal for dial_tcp
	conn := net.dial_tcp(addr)!
	mut c := &DoipClient{
		iface:  addr
		tx_id:  source
		rx_id:  target
		conn:   conn
		source: source
		target: target
	}
	c.activate_routing() or {
		c.close()
		return err
	}
	return c
}

// activate_routing sends a routing activation request and validates the response.
fn (mut c DoipClient) activate_routing() ! {
	c.conn.write(routing_activation_request(c.source))!
	msg := read_message(mut c.conn, 2000)!
	if msg.payload_type != pt_routing_activation_response {
		return error('DoIP: expected routing activation response, got 0x${msg.payload_type:04X}')
	}
	if msg.payload.len < 5 || msg.payload[4] != ra_success {
		code := if msg.payload.len >= 5 { msg.payload[4] } else { u8(0xFF) }
		return error('DoIP: routing activation denied (code 0x${code:02X})')
	}
}

// send wraps `data` (a UDS request) in a 0x8001 diagnostic message and writes it.
pub fn (mut c DoipClient) send(data []u8) ! {
	c.conn.write(diagnostic_message(c.source, c.target, data))!
}

// recv returns the UDS user-data of the next diagnostic message (0x8001), skipping
// the positive ack (0x8002) the entity sends first. A negative ack (0x8003) errors.
pub fn (mut c DoipClient) recv(timeout_ms int) ![]u8 {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		rem := int(deadline - time.ticks())
		if rem <= 0 {
			return error('DoIP recv timeout')
		}
		msg := read_message(mut c.conn, rem)!
		match msg.payload_type {
			pt_diagnostic_message {
				dm := parse_diagnostic_message(msg.payload)!
				if dm.source != c.target || dm.target != c.source {
					continue // a response for another logical address — not ours
				}
				return dm.data
			}
			pt_diagnostic_message_ack {
				continue // positive ack — wait for the real response
			}
			pt_diagnostic_message_nack {
				nack := if msg.payload.len >= 5 { msg.payload[4] } else { u8(0xFF) }
				return error('DoIP: diagnostic message negative ack (0x${nack:02X})')
			}
			else {
				continue // ignore anything else on this connection
			}
		}
	}
	return error('DoIP recv timeout')
}

pub fn (mut c DoipClient) close() {
	if !isnil(c.conn) {
		c.conn.close() or {}
	}
}
