// client.v — DoipClient, a DoIP tester over TCP. It implements the SAME shape as
// isotp.Channel (iface/tx_id/rx_id + send/recv/close), so the existing uds.Client
// rides it unchanged: `uds.new_client(open_doip(...)!)` speaks UDS over Ethernet.
//
// open_doip() does the TCP connect + routing activation handshake; send() wraps a
// UDS request in a 0x8001 diagnostic message; recv() returns the UDS user-data of
// the response, transparently skipping the 0x8002 positive ack. GUI-free.
module doip

import transport
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
pub mut:
	// what opening it cost, on the monotonic clock: the TCP connect, then the routing activation
	// exchange — apart, because on a real entity they differ by orders of magnitude and only one
	// of them is the network
	connect_us  i64
	activate_us i64
	// stop_requested, when set, is asked while this client waits — for the TCP connect, the
	// routing activation answer and every recv — every `stop_poll_ms`; a true answer ends the
	// wait with `stopped_note`. For a worker that must leave when told (the GUI's panel holder);
	// unset, every wait is the plain blocking one.
	stop_requested fn () bool = unsafe { nil }
mut:
	conn   &net.TcpConn = unsafe { nil }
	source u16
	target u16
}

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
// receives IPv4 senders; an IPv4-only bind cannot see IPv6 announcements at all. And JOINS the
// group: binding the wildcard receives unicast, but an entity announcing to the derived ff02::1
// is multicast — without a join this socket never sees it and the window simply times out.
// "0" = any interface: V parses the IPv6 argument as a numeric INDEX, not an address, so '::'
// failed with "must be a numeric interface index". The window itself — what ends it, a failed
// join returned rather than waited out — is transport.udp_window, shared with someip's listener.
pub fn collect_announcements_af(port_ int, window_ms int, ip6 bool) ![]Announcement {
	addr := if ip6 { '[::]:${port_}' } else { '0.0.0.0:${port_}' }
	group := if ip6 { 'ff02::1' } else { '' }
	// CLAIMED AS A SHARER, not as an exclusive reader. ISO 13400 puts the entity and every
	// tester on one discovery port (13400), so several readers there is the protocol's design
	// rather than a mistake — this repo's own entity tests listen on the port an entity is bound
	// to. What the claim buys is the other direction: an EXCLUSIVE reader (a SOME/IP row) on
	// that port would split the announcements in silence, and it is now refused.
	owner := 'a DoIP announcement listener'
	canon := transport.claim_endpoint(if ip6 { '::' } else { '' }, port_, owner, .shared, doip_discovery_medium)!
	defer {
		transport.release_endpoint(canon, port_, owner)
	}
	got := transport.udp_window(addr, group, '0', window_ms) or {
		return error('cannot listen for announcements: ${err}')
	}
	return announcements_in(got, false)
}

// announcements_in keeps the datagrams that are well-formed vehicle announcements. With `once`,
// an entity is kept once — a broadcast request heard on two interfaces is answered twice — and
// without it every announcement is kept, since an entity repeating itself is what a passive
// listener is there to see.
fn announcements_in(got []transport.Datagram, once bool) []Announcement {
	mut out := []Announcement{}
	for d in got {
		if d.data.len < header_len {
			continue
		}
		msg := parse(d.data) or { continue }
		if msg.payload_type != pt_vehicle_announcement {
			continue
		}
		info := parse_vehicle_announcement(msg.payload) or { continue }
		if once && out.any(it.from == d.from && it.info.logical_address == info.logical_address
			&& it.info.vin == info.vin) {
			continue
		}
		out << Announcement{
			info: info
			from: d.from
		}
	}
	return out
}

// identify sends ONE vehicle identification request to `host:port` and returns every entity
// that answers within `window_ms`, each with the address it answered from. `host` is one
// entity's address (ask this host) or a broadcast address (find on the network: every entity on
// the segment that hears it answers). The whole window is waited out either way, since nothing
// says how many entities will answer.
//
// The answers come back to the socket the request left from, which is what lets a host that
// drops unsolicited UDP (WSL's mirrored networking) still hear a unicast answer — a broadcast
// request's answers come from addresses it never sent to, and such a host may drop them.
//
// The destination is RESOLVED first and the socket bound in the family it resolved to, so a
// hostname with only an AAAA record is asked over IPv6 — the family is not guessed from the
// spelling.
//
// EVERY address the name resolves to is asked, in the same window: a name with an A and an AAAA
// record, or several A records, reaches its entity through whichever one it listens on.
pub fn identify(host string, port int, window_ms int) ![]Announcement {
	h := bare_host(host)!
	addrs := net.resolve_addrs(join_host_port(h, port), .unspec, .udp) or {
		return error('cannot resolve ${h}: ${err}')
	}
	if addrs.len == 0 {
		return error('${h} resolves to nothing')
	}
	return identify_addrs(addrs, window_ms)
}

// bare_host is `host` without the brackets an IPv6 literal may carry — a MATCHING outer pair
// only. A bracket without its partner (`[::1`, `::1]`), or one inside the name, is refused:
// stripping it would ask some other spelling than the one typed.
pub fn bare_host(host string) !string {
	h := host.trim_space()
	if h.starts_with('[') && h.ends_with(']') {
		inner := h[1..h.len - 1]
		if !inner.contains('[') && !inner.contains(']') {
			return inner
		}
	} else if !h.contains('[') && !h.contains(']') {
		return h
	}
	return error('"${h}" is not a host: a bracket must enclose an IPv6 address')
}

// ExchangeOutcome is one family's exchange, carried out of its thread whole.
struct ExchangeOutcome {
	got []transport.Datagram
	err string
}

fn exchange_family(bind string, tos []net.Addr, window_ms int) ExchangeOutcome {
	got := transport.udp_exchange_many(bind, tos, [vehicle_id_request()], window_ms) or {
		return ExchangeOutcome{
			err: err.msg()
		}
	}
	return ExchangeOutcome{
		got: got
	}
}

// identify_addrs asks every one of `addrs` in ONE window: one socket per address family, the
// families concurrently, so two families do not take two windows. An error only when no
// family could be asked at all.
fn identify_addrs(addrs []net.Addr, window_ms int) ![]Announcement {
	v4 := addrs.filter(it.family() == .ip)
	v6 := addrs.filter(it.family() == .ip6)
	mut threads := []thread ExchangeOutcome{}
	if v4.len > 0 {
		threads << spawn exchange_family('0.0.0.0:0', v4, window_ms)
	}
	if v6.len > 0 {
		threads << spawn exchange_family('[::]:0', v6, window_ms)
	}
	mut got := []transport.Datagram{}
	mut errs := []string{}
	for t in threads {
		o := t.wait()
		if o.err != '' {
			errs << o.err
		}
		got << o.got
	}
	if errs.len == threads.len && errs.len > 0 {
		return error(errs.join('; '))
	}
	return announcements_in(got, true)
}

// dial_address is where a tester reaches this entity over TCP: the host it answered from, on
// `port` — the port the request was sent to, which ISO 13400 makes the TCP port as well. Not
// the answer's source port, which an entity may send from an ephemeral socket.
pub fn (a Announcement) dial_address(port int) string {
	mut host := a.from
	if host.starts_with('[') {
		host = host.all_before(']') + ']'
	} else if host.count(':') == 1 {
		host = host.all_before(':')
	}
	return '${host}:${port}'
}

// collect_announcements is the IPv4 form, kept for callers that do not care.
pub fn collect_announcements(port_ int, window_ms int) ![]Announcement {
	return collect_announcements_af(port_, window_ms, false)
}

pub fn open_doip(host string, port int, source u16, target u16) !&DoipClient {
	return open_doip_stoppable(host, port, source, target, unsafe { nil })
}

// stopped_note is the error a stoppable wait ends with when its stop was requested.
pub const stopped_note = 'DoIP: stopped — stop requested'

// stop_poll_ms is how often a stoppable wait asks its stop: the bound on how long it outlives one.
pub const stop_poll_ms = 20

fn asked_to_stop(stop fn () bool) bool {
	return stop != unsafe { nil } && stop()
}

// open_doip_stoppable is open_doip whose TCP connect and routing activation both end when `stop`
// answers true; the client keeps `stop` for its recvs.
pub fn open_doip_stoppable(host string, port int, source u16, target u16, stop fn () bool) !&DoipClient {
	addr := join_host_port(host, port) // brackets an IPv6 literal for dial_tcp
	t0 := time.sys_mono_now()
	conn := dial_stoppable(net.dial_tcp, addr, stop)!
	t1 := time.sys_mono_now()
	mut c := &DoipClient{
		stop_requested: stop
		iface:      addr
		tx_id:      source
		rx_id:      target
		conn:       conn
		source:     source
		target:     target
		connect_us: i64(t1 - t0) / 1000
	}
	c.activate_routing() or {
		why := err.str()
		c.close()
		return error(why)
	}
	c.activate_us = i64(time.sys_mono_now() - t1) / 1000
	return c
}

// Dialed is a dial's outcome, carried back from the thread that made it.
struct Dialed {
	conn &net.TcpConn = unsafe { nil }
	err  string
}

// dial_stoppable dials `addr` with `dial`. Unstoppable, it is the dial itself. Stoppable, the
// dial runs on its own thread — a TCP connect has no slice to ask a stop in, and runs up to the
// platform's connect timeout — and the wait for it asks `stop`; a dial left behind closes its
// connection when it lands, so nothing leaks.
fn dial_stoppable(dial fn (string) !&net.TcpConn, addr string, stop fn () bool) !&net.TcpConn {
	if stop == unsafe { nil } {
		return dial(addr)
	}
	done := chan Dialed{cap: 1}
	spawn fn [dial, addr, done] () {
		c := dial(addr) or {
			done <- Dialed{
				err: err.str() // a net error may carry only a code, and msg() is then empty
			}
			return
		}
		done <- Dialed{
			conn: c
		}
	}()
	for {
		if stop() {
			spawn fn [done] () {
				d := <-done
				if !isnil(d.conn) {
					mut c := d.conn
					c.close() or {}
				}
			}()
			return error(stopped_note)
		}
		select {
			d := <-done {
				if d.err != '' {
					return error(d.err)
				}
				return d.conn
			}
			stop_poll_ms * time.millisecond {}
		}
	}
	return error(stopped_note)
}

// await_readable waits up to `ms` for the connection to have something to read, in slices that
// ask the client's stop: true when it has, false when `ms` ran out.
fn (mut c DoipClient) await_readable(ms int) !bool {
	deadline := time.ticks() + i64(ms)
	for {
		if asked_to_stop(c.stop_requested) {
			return error(stopped_note)
		}
		left := deadline - time.ticks()
		if left <= 0 {
			return false
		}
		if readable_within(c.conn.sock.handle, if left < stop_poll_ms { int(left) } else { stop_poll_ms }) {
			return true
		}
	}
	return false
}

// activate_routing sends a routing activation request and validates the response. An alive
// check asked meanwhile is answered and the wait goes on.
fn (mut c DoipClient) activate_routing() ! {
	c.conn.write(routing_activation_request(c.source))!
	deadline := time.ticks() + i64(ra_timeout_ms)
	mut msg := Message{}
	for {
		left := int(deadline - time.ticks())
		if left <= 0
			|| (c.stop_requested != unsafe { nil } && !c.await_readable(left)!) {
			return error('DoIP: no routing activation response within ${ra_timeout_ms} ms')
		}
		msg = read_message_stoppable(mut c.conn, left, c.stop_requested)!
		if !c.serve_control(msg)! {
			break
		}
	}
	if msg.payload_type != pt_routing_activation_response {
		return error('DoIP: expected routing activation response, got 0x${msg.payload_type:04X}')
	}
	if msg.payload.len < 5 || msg.payload[4] != ra_success {
		code := if msg.payload.len >= 5 { msg.payload[4] } else { u8(0xFF) }
		return error('DoIP: routing activation denied (code 0x${code:02X})')
	}
}

const ra_timeout_ms = 2000

// send wraps `data` (a UDS request) in a 0x8001 diagnostic message and writes it.
pub fn (mut c DoipClient) send(data []u8) ! {
	c.conn.write(diagnostic_message(c.source, c.target, data))!
}

// send_to wraps `data` in a 0x8001 diagnostic message to `target` instead of the connection's own
// target — a functional logical address, which the entity acks from that address and answers from
// its own, so recv() takes the answer as usual. On one TCP connection that is one entity's answer.
pub fn (mut c DoipClient) send_to(target u32, data []u8) ! {
	if target > 0xFFFF {
		return error('DoIP: 0x${target:X} is not a logical address')
	}
	c.conn.write(diagnostic_message(c.source, u16(target), data))!
}

// recv returns the UDS user-data of the next diagnostic message (0x8001), skipping
// the positive ack (0x8002) the entity sends first. A negative ack (0x8003) errors.
pub fn (mut c DoipClient) recv(timeout_ms int) ![]u8 {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		mut rem := int(deadline - time.ticks())
		if timeout_ms <= 0 {
			// A POLL (#358): only what has already arrived — the UDS client's pre-send drain.
			// Asked before reading, never by reading with a zero deadline, which would stop
			// partway through a message and desynchronise the stream; once something is there,
			// the whole message is read with an ordinary deadline, since its rest is in flight.
			if !readable_now(c.conn.sock.handle) {
				return error('DoIP recv timeout')
			}
			// what is readable must be read whole; a failure here (the peer closed, or a message
			// stalled partway) leaves no stream to poll again, and must not read as one more
			// drained answer
			msg := read_message_stoppable(mut c.conn, poll_read_ms, c.stop_requested) or {
				if err.msg() == stopped_note {
					return err
				}
				return error('${doip_connection_lost}${err.msg()}')
			}
			data, mine := c.own_answer(msg)!
			if mine {
				return data
			}
			continue
		} else if rem <= 0 {
			return error('DoIP recv timeout')
		}
		// a stoppable client waits for the message to begin, and then for each piece of it, in
		// slices its stop can end — a peer that stalls partway cannot hold it past a stop
		if c.stop_requested != unsafe { nil } {
			if !c.await_readable(rem)! {
				return error('DoIP recv timeout')
			}
			rem = int(deadline - time.ticks())
			if rem < stop_poll_ms {
				rem = stop_poll_ms
			}
		}
		// the socket's own timeout is this carrier's silence, said the one way a caller reads it
		msg := read_message_stoppable(mut c.conn, rem, c.stop_requested) or {
			if err.code() == net.err_timed_out_code {
				return error('DoIP recv timeout')
			}
			return err
		}
		data, mine := c.own_answer(msg)!
		if mine {
			return data
		}
	}
	return error('DoIP recv timeout')
}

// own_answer is a received message's diagnostic payload and true when it is this connection's
// answer; false for what is skipped (another logical address's response, a positive ack, an
// alive check — answered on the way — anything else); an error for a negative ack.
fn (mut c DoipClient) own_answer(msg Message) !([]u8, bool) {
	if c.serve_control(msg)! {
		return []u8{}, false
	}
	match msg.payload_type {
		pt_diagnostic_message {
			dm := parse_diagnostic_message(msg.payload)!
			if dm.source != c.target || dm.target != c.source {
				return []u8{}, false // a response for another logical address — not ours
			}
			return dm.data, true
		}
		pt_diagnostic_message_ack {
			return []u8{}, false // positive ack — wait for the real response
		}
		pt_diagnostic_message_nack {
			nack := if msg.payload.len >= 5 { msg.payload[4] } else { u8(0xFF) }
			return error('DoIP: diagnostic message negative ack (0x${nack:02X})')
		}
		else {
			return []u8{}, false // ignore anything else on this connection
		}
	}
}

// serve_control answers what the entity asks of the connection itself rather than of the ECU —
// an Alive Check Request (0x0007), answered with an Alive Check Response (0x0008) carrying the
// tester's source address (ISO 13400-2). An entity that asks and hears nothing closes the
// connection, so it is answered wherever this client reads: inside an exchange, during routing
// activation, and on an idle connection (`idle`). True when `msg` was such a message.
fn (mut c DoipClient) serve_control(msg Message) !bool {
	if msg.payload_type != pt_alive_check_request {
		return false
	}
	c.conn.write(alive_check_response(c.source))!
	return true
}

// idle_max_messages bounds one `idle` call, so a peer that never stops sending cannot hold it.
const idle_max_messages = 16

// idle serves an IDLE connection: what has already arrived is read without waiting for more, an
// alive check is answered, and anything else is dropped — nothing is waiting for it, and a late
// answer would be dropped by the next exchange's pre-send drain anyway. For a holder that keeps
// the connection open between exchanges and polls it on its own rhythm (an entity's alive check
// timeout is 500 ms). An error when the connection cannot be read any further (`doip_connection_lost`,
// the peer closed or a message stalled), or `stopped_note` when the client's stop ended a read.
pub fn (mut c DoipClient) idle() ! {
	for _ in 0 .. idle_max_messages {
		if !readable_now(c.conn.sock.handle) {
			return
		}
		msg := read_message_stoppable(mut c.conn, poll_read_ms, c.stop_requested) or {
			if err.msg() == stopped_note {
				return err
			}
			return error('${doip_connection_lost}${err.msg()}')
		}
		c.serve_control(msg) or { return error('${doip_connection_lost}${err.msg()}') }
	}
}

// doip_connection_lost prefixes the error a poll returns when the connection cannot be read any
// further — a failure of the carrier, which a pre-send drain must pass on, not count as an answer.
pub const doip_connection_lost = 'DoIP connection lost: '

// poll_read_ms: how long a zero-timeout recv waits for the REST of a message whose first bytes
// have arrived — TCP delivers it promptly, so this bounds a peer that stalls mid-message.
const poll_read_ms = 1000

pub fn (mut c DoipClient) close() {
	if !isnil(c.conn) {
		c.conn.close() or {}
	}
}

// diagnostics: a TCP connection has no controller and drops nothing; nothing to say (#213).
pub fn (mut c DoipClient) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}
