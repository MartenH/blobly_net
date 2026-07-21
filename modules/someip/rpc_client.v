module someip

// RpcClient — the CLIENT half of the RPC design (blobly_emb docs/someip.md
// P3): ONE in-flight request per client, a deadline instead of an unbounded
// wait, and a DRAIN state that eats stale datagrams (late responses to a
// timed-out session, interleaved event notifications) so correlation can
// never attach a stale answer to a fresh request. Transport-free: the caller
// owns the socket and pumps received datagrams + the clock into poll()/
// on_datagram(); this module owns only the protocol state. Poll-based so a
// GUI loop can drive it without blocking.
//
// Session ids are live (nonzero, wrapping 1..0xFFFF) — the server refuses a
// dead session (the emb gate), and WE refuse to reuse one across requests so
// a late response can never match a newer session.

pub enum RpcState {
	idle    // no request in flight; send() is legal
	waiting // sent, correlating; feed on_datagram() + poll() the clock
	done    // response landed: result/payload valid until the next send()
	failed  // error response (rc in result) or timeout (timed_out set)
}

pub struct RpcResult {
pub mut:
	rc        u8   // return code (0 = ok; the server's rc on an error reply)
	timed_out bool // deadline passed with no correlated answer
	payload   []u8 // response payload (empty on error/timeout)
}

pub struct RpcClient {
pub mut:
	service    u16
	method     u16
	iface      u8
	client_id  u16      = 1 // nonzero: the reserved 0 is refused by the server gate
	timeout_us u64      = 1_000_000
	state      RpcState = .idle
	result     RpcResult
mut:
	session u16 // last USED session id (next send uses the successor)
	sent_at u64
}

// next_session advances the wrapping live-session counter (1..0xFFFF, never 0).
fn (mut c RpcClient) next_session() u16 {
	c.session = if c.session >= 0xFFFF { u16(1) } else { c.session + 1 }
	return c.session
}

// send builds the request datagram for one command payload and arms the
// deadline. Returns the bytes to put on the wire, or none while a request is
// already in flight (ONE in flight per client — queueing belongs to the
// caller, which knows what its UI wants to do with a busy port).
pub fn (mut c RpcClient) send(payload []u8, now u64) ?[]u8 {
	if c.state == .waiting {
		return none
	}
	s := c.next_session()
	c.state = .waiting
	c.sent_at = now
	c.result = RpcResult{}
	return request(c.service, c.method, c.client_id, s, c.iface, payload)
}

// on_datagram feeds one received datagram. Anything that is not the response
// or error correlated to the CURRENT session is DRAINED silently: event
// notifications share the socket, and a late reply to an abandoned session
// must never complete a newer request. Returns true when the datagram
// completed the in-flight request.
pub fn (mut c RpcClient) on_datagram(buf []u8) bool {
	if c.state != .waiting {
		return false // drain: nothing in flight
	}
	m := parse(buf) or { return false } // drain: not even a SOME/IP message
	h := m.header
	if h.msg_type != mt_response && h.msg_type != mt_error {
		return false // drain: an event or foreign traffic
	}
	if h.service != c.service || h.method != c.method || h.client != c.client_id
		|| h.session != c.session {
		return false // drain: stale/foreign correlation
	}
	if h.msg_type == mt_error {
		c.state = .failed
		c.result = RpcResult{
			rc: h.return_code
		}
		return true
	}
	c.state = .done
	c.result = RpcResult{
		rc:      h.return_code
		payload: m.payload.clone()
	}
	return true
}

// poll advances the clock: past the deadline a waiting request FAILS with
// timed_out (the session id is burned — a later reply to it drains).
pub fn (mut c RpcClient) poll(now u64) {
	if c.state == .waiting && now - c.sent_at >= c.timeout_us {
		c.state = .failed
		c.result = RpcResult{
			timed_out: true
		}
	}
}
