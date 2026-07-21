module someip

// BoardLink — the socket-owning core of a "SOME/IP eth board" channel. Unlike
// someip.v/rpc_client.v (transport-free codec/state), this deliberately owns
// THE one UDP socket to the board so the GUI worker stays a thin loop and the
// whole rx path is testable on loopback without a board.
//
// Why one socket: the board's static source filter accepts exactly its
// configured peer endpoint (ip AND port), so everything — event notifications
// in, shell requests out, responses in — must ride the same local ip:port.
// The caller binds a SPECIFIC local ip: a wildcard 0.0.0.0 bind receives no
// unsolicited datagrams until the socket has sent once (verified under WSL
// mirrored networking), and events are exactly that.
//
// Threading: ONE worker thread drives poll() (recv + classify); a shell
// thread may concurrently send() (sendto on a UDP fd is atomic and safe
// against a concurrent recv — no queueing latency behind the read timeout)
// and take_response(). The response handoff is a small mutex-guarded FIFO
// (not a single slot: a late stale response arriving right after the real
// one must not clobber it between shell polls); the shell's RpcClient does
// the correlation and drains the stale ones.

import net
import sync
import time

// EventDef is one expected board->host event (from the manifest's `ethframe`
// tx rows): the event id names the frame and fixes its exact payload length.
pub struct EventDef {
pub:
	id   u16
	name string
	len  int
}

// EventFrame is one accepted event notification.
pub struct EventFrame {
pub:
	def     EventDef
	payload []u8
}

pub struct BoardLink {
pub:
	service u16
	version u8
pub mut:
	// counted-and-dropped datagrams: foreign source, malformed, foreign
	// service/version, unknown event id, wrong payload length. Worker-written,
	// GUI-read (a torn u64 read is cosmetic).
	drops     u64
	rx_events u64
mut:
	sock      &net.UdpConn
	board     net.Addr
	board_str string // the only accepted source (ip:port — the board's endpoint)
	events    map[u16]EventDef
	mu        sync.Mutex
	rsp       [][]u8 // response handoff FIFO to the waiting shell (cap rsp_cap)
	buf       []u8
	last_active i64 // last rx/prime, time.ticks ms (worker thread only) — re-prime clock
}

// rsp_cap bounds the response FIFO: the board answers one single-flight
// request at a time, so anything beyond a handful is stale flood — overflow
// drops the OLDEST and counts it.
const rsp_cap = 8

// prime_interval_ms: how much rx/tx silence before the link re-primes the
// firewall flow (see the prime comment in open_board_link — the flow state
// EXPIRES during silence, observed live as a rebooted board's events never
// arriving until our side transmitted).
const prime_interval_ms = i64(5000)

// open_board_link binds `local` (ip:port — the board's configured peer
// endpoint) and resolves `board` (ip:port) as the send target + source filter.
pub fn open_board_link(local string, board string, service u16, version u8, events []EventDef) !&BoardLink {
	mut sock := net.listen_udp(local)!
	sock.set_read_timeout(100 * time.millisecond)
	addrs := net.resolve_addrs(board, .ip, .udp) or {
		sock.close() or {}
		return error('resolve ${board}: ${err}')
	}
	mut ev := map[u16]EventDef{}
	for e in events {
		ev[e.id] = e
	}
	mut l := &BoardLink{
		service:     service
		version:     version
		sock:        sock
		board:       addrs[0]
		board_str:   addrs[0].str()
		events:      ev
		buf:         []u8{len: 65536} // one FULL UDP datagram (truncation would read as malformed)
		last_active: time.ticks()
	}
	// PRIME the firewall flow: under WSL mirrored networking the Windows
	// firewall only delivers unsolicited inbound UDP on a flow this socket has
	// SENT on (verified live: a correctly bound passive socket saw nothing
	// until our side transmitted once). One meaningless byte opens the flow;
	// the board counts it as one rx drop — accepted. Best-effort: never fail
	// the open on it.
	l.sock.write_to(l.board, [u8(0)]) or {}
	return l
}

// local_addr reports the socket's bound endpoint (useful when bound to :0).
pub fn (l &BoardLink) local_addr() !net.Addr {
	return l.sock.sock.address()
}

// poll runs one rx step: none on timeout or on anything that is not an
// accepted event. Responses/errors are routed to the shell slot; everything
// else that fails a check is counted and dropped, never surfaced.
pub fn (mut l BoardLink) poll() ?EventFrame {
	n, raddr := l.sock.read(mut l.buf) or {
		// timeout: nothing pending. The firewall's flow state EXPIRES during
		// silence (observed live: a rebooted board's cyclic events never
		// arrived until we transmitted again), so after prime_interval_ms of
		// no rx re-open the flow with the same one-byte prime as at open.
		now := time.ticks()
		if now - l.last_active > prime_interval_ms {
			l.sock.write_to(l.board, [u8(0)]) or {}
			l.last_active = now
		}
		return none
	}
	l.last_active = time.ticks()
	if raddr.str() != l.board_str {
		// only the dialed board may feed the channel — on a shared bench
		// another node could otherwise forge frames
		l.drops++
		return none
	}
	m := parse(l.buf[..n]) or {
		l.drops++
		return none
	}
	h := m.header
	if h.msg_type == mt_response || h.msg_type == mt_error {
		// the shell's answer: park the whole datagram (its RpcClient
		// correlates and drains stale ones)
		l.mu.lock()
		if l.rsp.len >= rsp_cap {
			l.rsp.delete(0) // stale flood: drop the oldest, count it
			l.drops++
		}
		l.rsp << l.buf[..n].clone()
		l.mu.unlock()
		return none
	}
	validate(h, l.service, l.version) or {
		l.drops++
		return none
	}
	if h.msg_type != mt_notification {
		l.drops++ // a REQUEST from the board is foreign traffic
		return none
	}
	def := l.events[h.method] or {
		l.drops++
		return none
	}
	if m.payload.len != def.len {
		l.drops++
		return none
	}
	l.rx_events++
	return EventFrame{def, m.payload}
}

// send transmits one request datagram to the board on the shared socket
// (called from the shell thread) and clears any responses parked before it
// (they can only be stale — answers to abandoned sessions).
pub fn (mut l BoardLink) send(req []u8) ! {
	l.mu.lock()
	l.rsp = [][]u8{}
	l.mu.unlock()
	l.sock.write_to(l.board, req)!
}

// take_response pops the oldest routed response datagram, in arrival order
// (none while still waiting).
pub fn (mut l BoardLink) take_response() ?[]u8 {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	if l.rsp.len == 0 {
		return none
	}
	r := l.rsp[0]
	l.rsp.delete(0)
	return r
}

pub fn (mut l BoardLink) close() {
	l.sock.close() or {}
}
