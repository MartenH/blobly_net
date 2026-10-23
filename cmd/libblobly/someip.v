// someip.v — bb.h's SOME/IP calls: messages sent from a local port and the answers heard, one
// request answered, and a port listened on — the Lua someip.send, someip.call and someip.listen,
// by blobly/someip's rules (someip.Sessions) and udsconn.someip_listener. What a call heard is a
// capture the host reads message by message and then frees.
module main

import blobly.someip
import blobly.udsconn

__global (
	bb_someip_sessions = someip.Sessions{}
	bb_captures        map[int]someip.Capture
	bb_capture_next    int
)

// field is a header field a host gave: -1 for its default, else a value up to max.
fn field(what string, v i32, max i64) !i64 {
	if v != -1 && (v < 0 || i64(v) > max) {
		return error('${what} ${v} does not fit')
	}
	return v
}

// outgoing is the host's message as blobly/someip sends it.
fn outgoing(m &C.bb_someip_out) !someip.Outgoing {
	o := unsafe { *m }
	payload := bytes_in('payload', o.payload, o.payload_len)!
	t := field('type', o.msg_type, 0xFF)!
	iface := field('iface', o.iface, 0xFF)!
	client := field('client', o.client, 0xFFFF)!
	session := field('session', o.session, 0xFFFF)!
	return someip.Outgoing{
		service:  o.service
		method:   o.method
		msg_type: if t < 0 { ?u8(none) } else { ?u8(u8(t)) }
		iface:    if iface < 0 { ?u8(none) } else { ?u8(u8(iface)) }
		client:   if client < 0 { ?u16(none) } else { ?u16(u16(client)) }
		session:  if session < 0 { ?u16(none) } else { ?u16(u16(session)) }
		payload:  payload
	}
}

// local_port is the port a tester sends from: `port`, or the default for 0.
fn local_port(port i32) int {
	return if port == 0 { someip.default_tester_port } else { int(port) }
}

// to_arg is a host's destination string.
fn to_arg(to &char) !string {
	if isnil(to) {
		return error('no destination')
	}
	return unsafe { cstring_to_vstring(to) }
}

// keep holds `cap` for the host and answers its handle.
fn keep(cap someip.Capture) i32 {
	bb_mu.lock()
	id := bb_capture_next
	bb_capture_next++
	bb_captures[id] = cap
	bb_mu.unlock()
	ok()
	return i32(id)
}

@[export: 'bb_someip_send']
pub fn bb_someip_send(port i32, to &char, msgs &C.bb_someip_out, n i32, window_ms i32) i32 {
	if n < 0 || (n > 0 && isnil(msgs)) {
		return fail(bb_err, 'someip send: ${n} messages, and no array of them')
	}
	if window_ms < 0 {
		return fail(bb_err, 'someip send: a window of ${window_ms} ms')
	}
	dest := to_arg(to) or { return fail(bb_err, 'someip send: ${err}') }
	mut out := []someip.Outgoing{}
	for i in 0 .. int(n) {
		out << outgoing(unsafe { &msgs[i] }) or {
			return fail(bb_err, 'someip send: message ${i}: ${err}')
		}
	}
	cap := bb_someip_sessions.send_messages(local_port(port), dest, out, int(window_ms)) or {
		return fail(bb_err, 'someip send(${dest}): ${err}')
	}
	return keep(cap)
}

@[export: 'bb_someip_call']
pub fn bb_someip_call(port i32, to &char, req &C.bb_someip_out, timeout_ms i32) i32 {
	if isnil(req) {
		return fail(bb_err, 'someip call: no request')
	}
	if timeout_ms < 0 {
		return fail(bb_err, 'someip call: a wait of ${timeout_ms} ms')
	}
	dest := to_arg(to) or { return fail(bb_err, 'someip call: ${err}') }
	m := outgoing(req) or { return fail(bb_err, 'someip call: ${err}') }
	a := bb_someip_sessions.call_once(local_port(port), dest, m, int(timeout_ms), 'a host') or {
		return fail(bb_err, 'someip call(${dest}): ${err}')
	}
	if a.timed_out {
		return fail(bb_err_timeout, 'someip call(${dest}): no answer to service 0x${a.header.service:04X} method 0x${a.header.method:04X} session ${a.header.session} within ${timeout_ms} ms')
	}
	return keep(someip.Capture{
		messages: [
			someip.Observed{
				at_ms:   a.at_ms
				from:    dest
				header:  a.header
				payload: a.payload
			},
		]
	})
}

@[export: 'bb_someip_listen']
pub fn bb_someip_listen(r i32, port i32, group &char, window_ms i32) i32 {
	if window_ms < 0 {
		return fail(bb_err, 'someip listen: a window of ${window_ms} ms')
	}
	if port < 0 || port > 0xFFFF {
		return fail(bb_err, 'someip listen: ${port} is not a port')
	}
	g := if isnil(group) { '' } else { unsafe { cstring_to_vstring(group) } }
	mut from := ''
	mut car := ?udsconn.Carrier(none)
	if r >= 0 {
		name, c := run_row('someip listen', r) or { return failed_with(err) }
		from = name
		car = ?udsconn.Carrier(c)
	}
	host, use_port, use_group := udsconn.someip_listener(int(port), g, from, car) or {
		return fail(bb_err, 'someip listen: ${err}')
	}
	cap := someip.collect(host, use_port, int(window_ms), use_group) or {
		return fail(bb_err, 'someip listen(${use_port}): ${err}')
	}
	return keep(cap)
}

@[export: 'bb_someip_count']
pub fn bb_someip_count(c i32, malformed &i32) i32 {
	bb_mu.lock()
	cap := bb_captures[int(c)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no SOME/IP capture ${c}')
	}
	bb_mu.unlock()
	if !isnil(malformed) {
		unsafe {
			*malformed = i32(cap.malformed)
		}
	}
	return ok_count(cap.messages.len)
}

@[export: 'bb_someip_message']
pub fn bb_someip_message(c i32, i i32, out &C.bb_someip_msg, buf &u8, cap i32) i32 {
	if isnil(out) {
		return fail(bb_err, 'someip message: nowhere to put it')
	}
	bb_mu.lock()
	got := bb_captures[int(c)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no SOME/IP capture ${c}')
	}
	bb_mu.unlock()
	k := held('message', i, got.messages.len) or { return fail(bb_err, 'someip ${err}') }
	m := got.messages[k]
	h := m.header
	unsafe {
		vmemset(out, 0, int(sizeof(C.bb_someip_msg)))
		out.service = h.service
		out.method = h.method
		out.client = h.client
		out.session = h.session
		out.iface = h.interface_version
		out.msg_type = h.msg_type
		out.return_code = h.return_code
		out.payload_len = i32(m.payload.len)
		out.at_ms = m.at_ms
		max := int(C.BB_SOMEIP_FROM_MAX) - 1
		vmemcpy(&out.from[0], m.from.str, if m.from.len < max { m.from.len } else { max })
	}
	return put_bytes(m.payload, buf, cap)
}

@[export: 'bb_someip_free']
pub fn bb_someip_free(c i32) i32 {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if int(c) !in bb_captures {
		return fail(bb_err_handle, 'no SOME/IP capture ${c}')
	}
	bb_captures.delete(int(c))
	return ok()
}
