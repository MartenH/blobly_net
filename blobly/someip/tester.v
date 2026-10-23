module someip

import sync

// tester — the rules a script's SOME/IP tester follows, for every binding (the Lua someip.send and
// someip.call, the C ABI's bb_someip_send and bb_someip_call): what a message left unstated goes
// out as, the Request IDs a run gives out, and one request answered.

// default_tester_port is the local port a tester sends from when none is named.
pub const default_tester_port = 30491

// default_client is the client id a request goes out with when none is named: a blobly_emb node
// refuses client 0.
pub const default_client = u16(0x1234)

// Sessions is the request sessions one run has used: a session goes out at most once per run,
// whether send or call sends it, so a late reply to one request can never complete another. Safe
// to share between threads.
pub struct Sessions {
mut:
	mu   &sync.Mutex = sync.new_mutex()
	last u16
	used map[u16]bool
}

// reset forgets every session: a new run.
pub fn (mut s Sessions) reset() {
	s.mu.lock()
	s.last = 0
	s.used = map[u16]bool{}
	s.mu.unlock()
}

// take reserves `want`, or the run's next unused session when it is 0.
pub fn (mut s Sessions) take(want u16) !u16 {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if want != 0 {
		if s.used[want] {
			return error('session ${want} was already used in this run — a late reply to it could complete this request')
		}
		s.used[want] = true
		return want
	}
	mut c := s.last
	for _ in 0 .. 0xFFFF {
		c = if c >= 0xFFFF { u16(1) } else { c + 1 }
		if !s.used[c] {
			s.used[c] = true
			s.last = c
			return c
		}
	}
	return error('every session of this run is used')
}

// Outgoing is one message a tester sends; a field left none takes its default (encode_out).
pub struct Outgoing {
pub:
	service  u16
	method   u16
	msg_type ?u8  // none: a notification for an event id, a request otherwise
	iface    ?u8  // none: 1
	client   ?u16 // none: default_client for a request, 0 for a notification
	session  ?u16 // none or 0: a request takes the run's next session
	payload  []u8
}

// check_to refuses a destination that is not an IPv4 "host:port": the local port is bound on the
// IPv4 wildcard, which is the claim every other listener here makes.
pub fn check_to(to string) ! {
	host, port := to.rsplit_once(':') or { return error('to must be an IPv4 "host:port", got "${to}"') }
	if host == '' || host.contains_any(':[]') || port == '' || !port.bytes().all(it.is_digit())
		|| port.len > 5 || port.int() > 65535 {
		return error('to must be an IPv4 "host:port", got "${to}"')
	}
}

// check_port refuses a local port a tester cannot send from.
pub fn check_port(port int) ! {
	if port <= 0 || port > 65535 {
		return error('port ${port} is not a UDP port')
	}
}

// encode_out is `m` on the wire, its defaults applied: only a request or a notification is sent,
// and a request goes out with a live Request ID — its session reserved for the run in `s`.
pub fn (mut s Sessions) encode_out(m Outgoing) ![]u8 {
	t := m.msg_type or { if is_event(m.method) { mt_notification } else { mt_request } }
	if t != mt_request && t != mt_notification {
		return error('type must be notification or request, got ${msg_type_name(t).to_lower()}')
	}
	req := t == mt_request
	cid := m.client or { if req { default_client } else { u16(0) } }
	mut session := m.session or { u16(0) }
	if req {
		session = s.take(session)!
	}
	return encode(Header{
		service:           m.service
		method:            m.method
		client:            cid
		session:           session
		protocol_version:  protocol_version
		interface_version: m.iface or { u8(1) }
		msg_type:          t
	}, m.payload)
}

// send_messages sends `msgs` (encode_out) to `to` from the local `port`, then hears that port for
// `window_ms` (exchange).
pub fn (mut s Sessions) send_messages(port int, to string, msgs []Outgoing, window_ms int) !Capture {
	check_port(port)!
	check_to(to)!
	mut out := [][]u8{}
	for m in msgs {
		out << s.encode_out(m)!
	}
	return exchange('', port, to, out, window_ms)
}

// Answer is what one call ended with: the RESPONSE or ERROR mirroring the request's Request ID
// (an ERROR is an answer, its return code in the header) from `from`, `at_ms` after the send; `timed_out`
// when nothing did within the deadline, the header then the request's own.
pub struct Answer {
pub:
	header    Header
	payload   []u8
	from      string // who answered, "host:port"
	at_ms     i64
	timed_out bool
}

// call_once is one request from the local `port` to `to` (call: RpcClient correlation, the drain,
// the version check, the peer filter, the deadline), its defaults applied as encode_out's and its
// session reserved for the run. An error is only for what kept the request from going out.
pub fn (mut s Sessions) call_once(port int, to string, m Outgoing, timeout_ms int, owner string) !Answer {
	check_port(port)!
	check_to(to)!
	if timeout_ms <= 0 {
		return error('a call waits for its answer: a timeout of ${timeout_ms} ms')
	}
	t := m.msg_type or { mt_request }
	if t != mt_request {
		return error('a call sends a request, not a ${msg_type_name(t).to_lower()}')
	}
	if is_event(m.method) {
		return error('method 0x${m.method:04X} is an event id (bit 15) — a request on it is malformed on the wire')
	}
	cid := m.client or { default_client }
	if cid == 0 {
		return error('client 0 is reserved (a blobly_emb node refuses it)')
	}
	want := s.take(m.session or { u16(0) })!
	// RpcClient sends the SUCCESSOR of `session`, so it starts one before
	mut cli := RpcClient{
		service:    m.service
		method:     m.method
		iface:      m.iface or { u8(1) }
		client_id:  cid
		timeout_us: u64(timeout_ms) * 1000
		session:    if want == 1 { u16(0xFFFF) } else { want - 1 }
	}
	call(port, to, mut cli, m.payload, owner)!
	if cli.state != .done && cli.result.timed_out {
		return Answer{
			header:    Header{
				service:           m.service
				method:            m.method
				client:            cid
				session:           cli.session
				protocol_version:  protocol_version
				interface_version: cli.iface
				msg_type:          mt_request
			}
			timed_out: true
		}
	}
	return Answer{
		header:  Header{
			service:           m.service
			method:            m.method
			client:            cid
			session:           cli.session
			protocol_version:  protocol_version
			interface_version: cli.iface
			msg_type:          if cli.state == .done { mt_response } else { mt_error }
			return_code:       cli.result.rc
		}
		payload: cli.result.payload
		from:    cli.result.from
		at_ms:   i64(cli.result.at_us / 1000)
	}
}
