// A small HTTP/1.1 client, for one reason: V's own cannot talk to a CANsub.
//
// The device answers with a status line carrying NO reason phrase —
//
//     HTTP/1.1 200\r\nTransfer-Encoding: chunked\r\n\r\n
//
// — where `net.http` splits that line and requires three tokens, so every request fails with
// "expected at least 3 tokens, but found: 2" after reading until the connection closes. Captured
// off the wire, not deduced: the bytes above are what a raw TLS socket sees.
//
// Neither side is being unreasonable. RFC 7230's grammar puts a space before the reason phrase
// even when the phrase itself is empty, so the device is a byte short of the letter of it; the
// same RFC tells clients to ignore the phrase entirely, which is why browsers, PowerShell and the
// vendor's own python-can backend all read this device without noticing. V is strict where
// everything else is lenient, and the device is on the other side of a USB cable, so the client
// is the part we can change.
//
// The WebSocket path does NOT need this — `net.websocket` checks its handshake with
// `starts_with('HTTP/1.1 101')` rather than by splitting, so it reads the same device happily.
// Frames were never affected; only configuration was.
//
// The parsing lives in pure functions so it is testable with no device attached, and the socket
// work is the thin part on top. `validate` is left at its default: the CANsub presents its own
// certificate, no public CA signed it, and the link is point to point over USB. Pinning the
// vendor's published root belongs here later, as an option, not as a hard requirement that would
// stop a bench working.
module transport

import net
import sync
import net.ssl
import time

// CansubResponse is a parsed reply: the status code and the body, already de-chunked.
pub struct CansubResponse {
pub:
	status int
	body   string
}

// cansub_status_code reads the status line, tolerating a missing reason phrase — the whole point
// of this file. Anything that starts `HTTP/1.x ` and continues with three digits is a status.
pub fn cansub_status_code(line string) !int {
	l := line.trim_space()
	if !l.starts_with('HTTP/1.') || l.len < 12 {
		return error('not an HTTP status line: ${l}')
	}
	code := l[9..12]
	for c in code {
		if c < `0` || c > `9` {
			return error('not a status code: ${l}')
		}
	}
	return code.int()
}

// cansub_max_body is the largest body this client accepts, and therefore the largest chunk size
// that can mean anything. It exists so hex_int can refuse an oversized declaration before the
// arithmetic wraps rather than after.
const cansub_max_body = 8 * 1024 * 1024

// cansub_dechunk decodes a chunked body. The device uses chunked for everything, including the
// one-word replies, so this is not an edge case here — it is the normal path.
pub fn cansub_dechunk(body string) !string {
	mut out := []u8{}
	mut i := 0
	// A CHUNKED BODY IS ONLY COMPLETE WHEN THE ZERO CHUNK ARRIVES. Running off the end of the
	// buffer instead is what a dropped connection looks like — and `cansub_request` treats every
	// read error as EOF, so a socket that died between two chunks handed back the bytes collected
	// so far as a successful response. Partial JSON parses to a device answer with fields missing,
	// which is worse than an error (codex round 3 on #204).
	mut terminated := false
	for i < body.len {
		mut eol := body.index_after('\r\n', i) or {
			return error('chunk header without a line end')
		}
		mut header := body[i..eol]
		if ext := header.index(';') { // chunk extensions are allowed and ignored
			header = header[..ext]
		}
		size := hex_int(header.trim_space()) or { return error('bad chunk size "${header}"') }
		i = eol + 2
		if size == 0 {
			terminated = true
			break // the terminating chunk; any trailer after it is not ours to care about
		}
		// COMPARED AGAINST WHAT REMAINS, not by adding to the index: `i + size` is int arithmetic
		// too, and the whole point of the check is to be safe against a size that is not sane.
		if size > body.len - i {
			return error('chunk claims ${size} bytes, ${body.len - i} remain')
		}
		out << body[i..i + size].bytes()
		i += size + 2 // step over the CRLF that follows every chunk
	}
	if !terminated {
		return error('chunked body ended after ${out.len} bytes without its terminating chunk')
	}
	return out.bytestr()
}

fn hex_int(s string) ?int {
	if s == '' {
		return none
	}
	// BOUNDED WHILE PARSING. `v = v * 16 + d` is int arithmetic, so a token like `80000000` wraps
	// NEGATIVE — and a negative size walks straight past `i + size > body.len`, after which the
	// slice endpoint is invalid and the process dies. The response cap does not help: the
	// oversized declaration is only a few bytes (codex round 7 on #204).
	//
	// The limit is the largest body this client will ever accept, so anything above it is refused
	// as a size rather than arithmetic that has stopped meaning anything.
	mut v := 0
	for c in s {
		d := match true {
			c >= `0` && c <= `9` { int(c - `0`) }
			c >= `a` && c <= `f` { int(c - `a`) + 10 }
			c >= `A` && c <= `F` { int(c - `A`) + 10 }
			else { return none }
		}

		if v > (cansub_max_body - d) / 16 {
			return none
		}
		v = v * 16 + d
	}
	return v
}

// cansub_parse_response splits a whole reply into its status and body, de-chunking when the
// headers say to. Content-Length is honoured too, so this does not depend on the device's current
// choice of framing.
pub fn cansub_parse_response(raw string) !CansubResponse {
	head_end := raw.index('\r\n\r\n') or { return error('response has no header terminator') }
	head := raw[..head_end]
	body := raw[head_end + 4..]
	lines := head.split('\r\n')
	status := cansub_status_code(lines[0])!
	mut chunked := false
	mut length := -1
	for i in 1 .. lines.len {
		colon := lines[i].index(':') or { continue }
		name := lines[i][..colon].trim_space().to_lower()
		value := lines[i][colon + 1..].trim_space()
		match name {
			'transfer-encoding' { chunked = value.to_lower().contains('chunked') }
			'content-length' { length = value.int() }
			else {}
		}
	}
	if chunked {
		return CansubResponse{
			status: status
			body:   cansub_dechunk(body)!
		}
	}
	if length >= 0 {
		// A DECLARED LENGTH IS A PROMISE, and fewer bytes than that is a dropped connection —
		// `cansub_request` treats every read error as EOF, so nothing else is going to notice.
		// The chunked path refuses its own version of this; leaving the Content-Length path to
		// fall through meant partial JSON still reached configuration and health code, parsed,
		// and answered with fields quietly missing (codex round 4 on #204).
		if length > body.len {
			return error('response declared ${length} bytes and ${body.len} arrived — the connection ended mid-body')
		}
		return CansubResponse{
			status: status
			body:   body[..length]
		}
	}
	return CansubResponse{
		status: status
		body:   body
	}
}

// cansub_request performs one request and returns the parsed reply.
//
// A new connection per request, closed by `Connection: close`. The REST API is for configuration —
// a handful of calls when a channel opens — so pooling would buy nothing and cost a class of
// staleness bugs. Frames never come this way; they are on the WebSocket.
pub fn cansub_request(host string, method string, path string, body string, timeout time.Duration) !CansubResponse {
	// ONE TLS CONNECTION PER DEVICE, KEPT OPEN. Every request used to make its own connection and
	// send `Connection: close`, reading until the device hung up — and the device answers a second
	// request on a kept-alive connection in under a millisecond against ~110 ms for a fresh one
	// (curl, 2026-08-28: total 0.0008 s, num_connects 0). The earlier finding that keep-alive was
	// 2.8 s SLOWER was this reader waiting for a close that never came. So the connection stays,
	// the reader stops when the body is complete (cansub_response_complete), and a connection
	// that fails is dropped and dialled again — once, for the request in hand, because an idle
	// connection the device has closed fails on the first byte and the second attempt is the real
	// one. What it buys: an open's three REST calls at ~120 ms instead of ~470, and a health
	// poll at ~1 ms instead of a TLS handshake twice a second (#240).
	// ONE DEADLINE FOR THE WHOLE CALL — the wait for the connection, the exchange, the redial and
	// the retry all spend from it. Given a fresh budget each, a 700 ms health poll whose first
	// exchange timed out went on to dial (seconds, to a device that has gone) and try again with
	// 700 ms more (codex round 2 on #248). What is not on the clock is the dial itself: V's
	// dial_tcp takes no timeout, so a retry is only STARTED while budget remains.
	// THE BUDGET STARTS ONCE THERE IS A CONNECTION. The first dial is a name lookup plus a TLS
	// handshake that nothing here can interrupt — 2.7 s cold on Windows — and charged against a
	// two-second open budget it left the identity request with nothing, so the open forgot the
	// address it had just found and repeated the same cold failure (codex round 4 on #248). The
	// redial on retry stays inside the deadline, as before: by then the name is known.
	mut c, reused := cansub_conn(host)!
	deadline := time.now().add(timeout)
	r := c.exchange(method, path, body, deadline) or {
		// EVICTION IS EXCHANGE'S, not ours: a connection whose socket failed is already dead and
		// out of the pool by the time the error reaches here, retired under its own turn so no
		// waiter could take it in between; and a caller that merely ran out of budget in the
		// queue leaves a healthy connection alone — a drop() here waited for the turn it had
		// just failed to get, and then closed a connection that was fine (codex round 3 on #248).
		if !reused || !c.dead || deadline - time.now() <= 0 {
			return err
		}
		// The connection was one the device may have closed while idle: dial and try once more.
		mut fresh, _ := cansub_conn(host)!
		return fresh.exchange(method, path, body, deadline)!
	}
	return r
}

// CansubConn is one device's kept-alive TLS connection. Requests on it are serialised by
// `turn`: the poll thread and a reconcile can want the device at the same time, and the answer
// to one request must not be read as the answer to another. A binary SEMAPHORE and not a mutex,
// because the wait for it is on the caller's clock (exchange) and a semaphore's timed_wait is
// the one timed acquisition V offers on every platform — Mutex.try_lock is `false` on Windows
// unless the build says `-d windows_7`, which a test found the hard way.
struct CansubConn {
	host string
mut:
	tcp  &net.TcpConn
	ssl  &ssl.SSLConn
	turn &sync.Semaphore
	dead bool
}

struct CansubPool {
mut:
	conns map[string]&CansubConn
}

__global (
	cansub_pool shared CansubPool
)

// cansub_conn is the device's connection, dialled on first use. `reused` reports whether the
// caller got an existing one, which is what decides whether a failure deserves a second try.
// CansubDialed is one dial that got through its handshake: what cansub_connect_attempts hands
// back to cansub_conn, which then admits it to the pool.
struct CansubDialed {
	tcp &net.TcpConn
	ssl &ssl.SSLConn
}

fn cansub_conn(host string) !(&CansubConn, bool) {
	existing := rlock cansub_pool {
		cansub_pool.conns[host] or { unsafe { nil } }
	}
	if existing != unsafe { nil } {
		return existing, true
	}
	// THE ADDRESS GENERATION THIS DIAL BELONGS TO. A forget (an identity mismatch) bumps it;
	// a dial that started before the forget may still come back holding the old device, and
	// pooled it would hand the retry the very connection the forget was meant to end (codex
	// round 4 on #248). So it is checked at admission, and a connection from an earlier
	// generation is closed and refused — the caller's retry dials against the new address.
	gen := cansub_addr_generation(host)
	// A handshake a signal interrupted is dialled again at once, socket closed first — the same
	// allowance the stream's open makes (cansub_connect_attempts, cansub.v), and this dial is
	// the identity read that comes BEFORE it, so an interruption here failed the open one step
	// earlier. Bounded by the read ceiling, which is what a caller of this dial can wait anyway.
	d := cansub_connect_attempts[CansubDialed](time.now().add(cansub_conn_read_ceiling), fn [host] () !CansubDialed {
		mut t := cansub_dial(host)!
		mut c := ssl.new_ssl_conn(
			validate:     false // the device signs its own certificate; see the note at the top
			read_timeout: cansub_conn_read_ceiling
		)!
		c.connect(mut t, host) or {
			t.close() or {}
			return err
		}
		return CansubDialed{t, c}
	})!
	mut tcp := d.tcp
	mut conn := d.ssl
	mut c := &CansubConn{
		host: host
		tcp:  tcp
		ssl:  conn
		turn: sync.new_semaphore_init(1)
	}
	// CHECKED UNDER THE ADMISSION LOCK. A forget bumps the generation first and drops from the
	// pool second, so a check made here, with the pool held, sees either the new generation
	// (refused) or the old one — in which case the forget's drop, queued behind this lock,
	// finds the connection just admitted and removes it. Checked before taking the lock, a
	// forget landing in the gap saw nothing to drop and the wrong device was pooled (codex
	// round 7 on #248).
	lock cansub_pool {
		if cansub_addr_generation(host) != gen {
			c.close_socket()
			return error('the address of ${host} was forgotten while connecting to it')
		}
		if mut prior := cansub_pool.conns[host] {
			// Two callers dialled at once; theirs is in the pool, ours is surplus.
			c.close_socket()
			return prior, true
		}
		cansub_pool.conns[host] = c
	}
	return c, false
}

// cansub_conn_read_ceiling is the SSL layer's read timeout, fixed at construction: the widest any
// request asks for. The per-request budget is set on the socket underneath (exchange).
const cansub_conn_read_ceiling = 5 * time.second

// exchange sends one request and reads its complete reply on this connection.
fn (mut c CansubConn) exchange(method string, path string, body string, deadline time.Time) !CansubResponse {
	// THE BUDGET IS THE CALLER'S and the wait for the connection is INSIDE it. Two channels on
	// one device share the connection, so a 700 ms health poll can queue behind an open's
	// two-second PUT; a plain lock() would hold the poll for the whole PUT and only then look at
	// the clock (codex rounds 1 and 2 on #248). So the turn is waited for with a timed wait to
	// the deadline, and a caller whose budget runs out in the queue leaves it. What remains
	// reaches the socket the TLS layer reads through; the SSL object's own timeout is only the
	// ceiling above both.
	if !c.acquire(deadline) {
		return error('${method} ${path}: the connection to ${c.host} was busy for the whole budget')
	}
	defer {
		c.turn.post()
	}
	if c.dead {
		return error('connection to ${c.host} is closed')
	}
	if deadline - time.now() <= 0 {
		return error('${method} ${path}: no budget left after waiting for the connection')
	}
	// FROM HERE THE SOCKET IS USED, and a failure of any kind retires the connection BEFORE the
	// turn is posted: a waiter woken by the post would otherwise take a stream with a late or
	// half-read reply still in it and read that as its own answer (codex round 3 on #248).
	return c.converse(method, path, body, deadline) or {
		c.retire()
		return err
	}
}

// converse is one request and its complete reply on a connection whose turn is held.
fn (mut c CansubConn) converse(method string, path string, body string, deadline time.Time) !CansubResponse {
	c.tcp.set_read_timeout(deadline - time.now())
	mut req := '${method} ${path} HTTP/1.1\r\nHost: ${c.host}\r\n'
	if body != '' {
		req += 'Content-Type: application/json\r\nContent-Length: ${body.len}\r\n'
	}
	req += '\r\n' + body
	c.ssl.write_string(req)!
	mut raw := []u8{}
	mut buf := []u8{len: 4096}
	for {
		// THE DEADLINE IS ABSOLUTE, so what each read may wait is what is LEFT of it — set once,
		// a reply trickled in just under the budget per read ran on for as long as the device
		// cared to, holding the turn (codex round 4 on #248).
		left := deadline - time.now()
		if left <= 0 {
			return error('${method} ${path}: the reply did not complete within the budget')
		}
		c.tcp.set_read_timeout(left)
		n := c.ssl.read(mut buf) or {
			// A peer close is reported by the TLS layer through its error path as often as by
			// a zero read. With bytes already in hand and the failure not a timeout, this is
			// the END of a close-delimited reply, not a failed one (codex round 6 on #248); the
			// connection is retired below, as an EOF is. With nothing in hand it is a failure.
			if raw.len > 0 && !cansub_is_timeout(err) {
				break
			}
			return err
		}
		if n <= 0 {
			break
		}
		raw << buf[..n]
		if raw.len > 1 << 20 {
			return error('response from ${path} exceeded 1 MiB')
		}
		if cansub_response_complete(raw) {
			break
		}
	}
	if raw.len == 0 {
		return error('${method} ${path}: no response')
	}
	if !cansub_response_complete(raw) {
		// The reply ended with the connection — a close-delimited body, or a close in the
		// middle of one. Either way this connection has nothing more to say: retire it, and let
		// the parser decide whether what arrived is a reply.
		c.retire()
	}
	return cansub_parse_response(raw.bytestr())
}

// cansub_is_timeout is whether a socket error is the read timeout — the one error that says
// nothing about the connection.
fn cansub_is_timeout(err IError) bool {
	m := err.msg().to_lower()
	return m.contains('timed out') || m.contains('timeout')
}

// retire closes this connection and takes it out of the pool, with the turn HELD by the caller:
// the next waiter finds `dead` and the next request dials afresh.
fn (mut c CansubConn) retire() {
	c.close_socket()
	lock cansub_pool {
		if mut cur := cansub_pool.conns[c.host] {
			if voidptr(cur) == voidptr(c) {
				cansub_pool.conns.delete(c.host)
			}
		}
	}
}

// acquire takes the connection's turn, or gives up at the deadline. True means the turn is
// held and must be posted back.
fn (mut c CansubConn) acquire(deadline time.Time) bool {
	remaining := deadline - time.now()
	if remaining <= 0 {
		return c.turn.try_wait()
	}
	return c.turn.timed_wait(remaining)
}

// drop takes a failed connection out of service: the next request dials a new one.
fn (mut c CansubConn) drop() {
	c.turn.wait()
	c.retire()
	c.turn.post()
}

fn (mut c CansubConn) close_socket() {
	if c.dead {
		return
	}
	c.dead = true
	c.ssl.shutdown() or {}
	c.tcp.close() or {}
}

// cansub_response_complete is whether `raw` holds a whole HTTP reply, so a kept-alive reader can
// stop without waiting for a close that will not come: headers ended, and then either the
// chunked body's terminating chunk has arrived (the device uses chunked for everything) or
// Content-Length bytes have, or the reply declares no body at all.
pub fn cansub_response_complete(raw []u8) bool {
	text := raw.bytestr()
	head_end := text.index('\r\n\r\n') or { return false }
	head := text[..head_end]
	body := text[head_end + 4..]
	// BY HEADER NAME, exactly, the way cansub_parse_response reads them: `X-Content-Length: 0`
	// or `Access-Control-Expose-Headers: Content-Length` contains the token and is not the
	// framing (codex round 6 on #248).
	mut chunked := false
	mut length := -1
	for line in head.split('\r\n') {
		name := line.all_before(':').trim_space().to_lower()
		value := line.all_after(':').trim_space().to_lower()
		if name == 'transfer-encoding' && value.contains('chunked') {
			chunked = true
		} else if name == 'content-length' {
			length = value.int()
		}
	}
	if chunked {
		return cansub_chunks_complete(body)
	}
	if length >= 0 {
		return body.len >= length
	}
	// Neither: the body, if there is one, runs to the connection's close, and no prefix of it
	// can be called complete — only a status that cannot carry a body ends at the headers
	// (codex round 3 on #248). The reader then runs to EOF and retires the connection.
	status := head.all_before('\r\n').split(' ')
	code := if status.len >= 2 { status[1].int() } else { 0 }
	return code < 200 || code == 204 || code == 304
}

// cansub_chunks_complete walks the chunks the way cansub_dechunk does — the SAME reading of a
// size line, extension and all — and answers whether the terminating chunk has arrived AND the
// empty line that ends its trailer section. A bare `0\r\n\r\n` is the common shape, but
// `0;ext\r\n` and `0\r\nTrailer: x\r\n\r\n` are legal too, and a completeness test that
// recognised only the first would leave a kept-alive reader waiting on the others until its
// timeout — for a reply cansub_dechunk would then accept (codex round 1 on #248). Walking the
// chunks is also what keeps a `0` INSIDE a chunk's data from reading as the end.
fn cansub_chunks_complete(body string) bool {
	mut i := 0
	for i < body.len {
		eol := body.index_after('\r\n', i) or { return false }
		mut header := body[i..eol]
		if ext := header.index(';') {
			header = header[..ext]
		}
		size := hex_int(header.trim_space()) or { return false }
		i = eol + 2
		if size == 0 {
			// Trailers, if any, then the empty line: from here the rest is header lines and ends
			// with the first empty one.
			rest := body[i..]
			return rest.starts_with('\r\n') || rest.contains('\r\n\r\n')
		}
		if size > body.len - i {
			return false
		}
		i += size + 2
	}
	return false
}

// cansub_get is the read half, and the one used most: identity, channel list, channel state.
pub fn cansub_get(host string, path string) !string {
	return cansub_get_within(host, path, 5 * time.second)
}

// cansub_get_within is the same request with the caller's own patience.
//
// HEALTH POLLING USES A SHORT ONE. It runs on a thread `close()` joins, so a device that has
// become unreachable mid-run parked that thread inside a five-second request and Stop waited it
// out -- undoing the 500 ms bound the reader timeout exists to give (codex round 5 on #204). A
// health poll is a question asked twice a second whose answer is only ever displayed; there is
// nothing to gain by waiting five seconds for it, and a Stop that hangs is what it costs.
pub fn cansub_get_within(host string, path string, timeout time.Duration) !string {
	r := cansub_request(host, 'GET', path, '', timeout)!
	if r.status != 200 {
		return error('GET ${path} -> HTTP ${r.status}')
	}
	return r.body.trim_space()
}

// cansub_host is the address of a device, from its id. Always the mDNS name, never an IP: a
// firmware update clears persistent data and the device returns on a different subnet — observed
// moving from 10.63.38.1 to 10.215.129.1 across 02.03.00 -> 02.04.00 — so an address written down
// is one reboot from being wrong, while the name follows it. It is also the identity the wire key
// should derive from, for the same reason.
pub fn cansub_host(id string) string {
	return '${id}${cansub_host_suffix}.local'
}

// cansub_host_suffix is what the device appends to its id in the name it registers -- the one
// place the rule lives; cansub_mdns.v strips it, cansub_host adds it.
pub const cansub_host_suffix = '-usb'

// cansub_addrs is the process-wide name -> address memory behind cansub_addr.
__global (
	cansub_addrs shared CansubAddrs
)

struct CansubAddrs {
mut:
	by_host map[string]string
	// One lock per name, held while that name is being resolved: a second caller for the same
	// name waits for the answer in flight instead of starting a lookup of its own. See
	// cansub_addr.
	resolving map[string]&sync.Mutex
	// When a lookup of the name last FAILED, in time.ticks(): for a short while after, a caller
	// gets that answer instead of repeating the lookup. See cansub_addr.
	failed_at map[string]i64
	// How many warm-up workers have been started, ever: what a test counts to hold the
	// one-per-device rule (cansub_warm_all).
	warmups int
	// Bumped by every forget of the name: what a dial in flight is checked against when it
	// comes back (cansub_conn).
	generation map[string]int
	// How the name was last resolved — "10.98.13.1 by mDNS in 24 ms" — for the Log: the next
	// "why is the CANsub row late" is answered by a line, not a probe (bench, 2026-08-29).
	how map[string]string
}

// cansub_lookup_note is how the name in `iface` was last resolved, for the Log line that
// announces the row; none before the first lookup or for a literal address.
pub fn cansub_lookup_note(iface string) ?string {
	spec := parse_cansub_iface(iface) or { return none }
	host := cansub_host(spec.id)
	note := rlock cansub_addrs {
		cansub_addrs.how[host] or { '' }
	}
	if note == '' {
		return none
	}
	return '${host} -> ${note}'
}

// cansub_addr_generation is how many times the name has been forgotten.
fn cansub_addr_generation(host string) int {
	return rlock cansub_addrs {
		cansub_addrs.generation[host] or { 0 }
	}
}

// cansub_mdns_resolve_window is how long the device gets to answer an A question before the
// OS resolver is asked instead: a device on the wire answers in tens of milliseconds, and a
// window this short costs the fallback path almost nothing.
const cansub_mdns_resolve_window = time.Duration(300 * time.millisecond)

// cansub_failed_lookup_memory is how long a failed lookup answers for the next caller. Long
// enough that the rows of one project, queued behind one failed lookup, share it; short
// enough that a device plugged in after is found on the next poll.
const cansub_failed_lookup_memory = 5000

// cansub_resolving is the lock a lookup of `host` holds — created on first use, one per name for
// the life of the process.
fn cansub_resolving(host string) &sync.Mutex {
	return lock cansub_addrs {
		if m := cansub_addrs.resolving[host] {
			m
		} else {
			m := sync.new_mutex()
			cansub_addrs.resolving[host] = m
			m
		}
	}
}

// cansub_addr is the resolved address of a device name, looked up once per process — see
// cansub_dial for why. none when it cannot be resolved right now.
pub fn cansub_addr(host string) ?string {
	return cansub_lookup(host, false)
}

// cansub_lookup is cansub_addr with the choice of whether a RECENT FAILURE is an answer. It is
// for the warm-up (background, speculative: a device not there a moment ago is not asked for
// again for a few seconds) and NOT for an open — an operator who plugs the device in and
// presses Start has told us it is there now, and an open that answered "not found" from a
// memory five seconds old would turn a transient failure into a failed run (codex round 3 on
// #249).
fn cansub_lookup(host string, recent_failure_answers bool) ?string {
	cached := rlock cansub_addrs {
		cansub_addrs.by_host[host] or { '' }
	}
	if cached != '' {
		return cached
	}
	// ONE LOOKUP IN FLIGHT PER NAME. The warm-up at project load (cansub_warm) runs this in the
	// background; an open that arrives while it is still running would otherwise see an empty
	// memory and start a second 2.7 s lookup of its own — the pause the warm-up exists to remove,
	// paid anyway, plus a duplicate query (codex round 1 on #249). So a lookup holds the name's
	// lock, and a caller that finds it held waits for that answer and reads it from the memory.
	mut resolving := cansub_resolving(host)
	resolving.lock()
	defer {
		resolving.unlock()
	}
	meanwhile, failed := rlock cansub_addrs {
		cansub_addrs.by_host[host] or { '' }, cansub_addrs.failed_at[host] or { 0 }
	}
	if meanwhile != '' {
		return meanwhile
	}
	// A FAILURE IS SHARED TOO. Three rows of one unplugged device queue on the lock above; if
	// the first lookup's failure were kept by nobody, the second and third would each spend
	// their own 2.7 s finding the same thing out, and a Start pressed behind them waits for all
	// of it (codex round 2 on #249).
	if recent_failure_answers && failed > 0 && time.ticks() - failed < cansub_failed_lookup_memory {
		return none
	}
	// THE DEVICE FIRST, THE OS SECOND. A raw mDNS A-query answers in tens of milliseconds;
	// Windows' resolver takes ~2.7 s cold for the same name, which put a CANsub row two seconds
	// behind the rows beside it on every Start (bench, 2026-08-29). A literal address skips
	// both. The resolver stays as the fallback for a host whose mDNS is blocked or filtered.
	mut ip := ''
	mut how := ''
	t0 := time.ticks()
	if host.split('.').all(it.len > 0 && it.bytes().all(it.is_digit())) {
		ip = host
	} else if mdns := cansub_mdns_resolve(host, cansub_mdns_resolve_window) {
		ip = mdns
		how = '${ip} by mDNS in ${time.ticks() - t0} ms'
	} else {
		addrs := net.resolve_ipaddrs(host, .ip, .tcp) or {
			cansub_note_failed_lookup(host)
			lock cansub_addrs {
				cansub_addrs.how[host] = 'not resolved (no mDNS answer in ${cansub_mdns_resolve_window.milliseconds()} ms, OS resolver failed after ${time.ticks() - t0} ms)'
			}
			return none
		}
		if addrs.len == 0 {
			cansub_note_failed_lookup(host)
			return none
		}
		ip = addrs[0].str().all_before_last(':')
		if ip == '' {
			return none
		}
		how = '${ip} by the OS resolver in ${time.ticks() - t0} ms (no mDNS answer in ${cansub_mdns_resolve_window.milliseconds()} ms)'
	}
	lock cansub_addrs {
		cansub_addrs.by_host[host] = ip
		cansub_addrs.failed_at.delete(host)
		if how != '' {
			cansub_addrs.how[host] = how
		}
	}
	return ip
}

fn cansub_note_failed_lookup(host string) {
	lock cansub_addrs {
		cansub_addrs.failed_at[host] = time.ticks()
	}
}

// cansub_warm resolves a CANsub address's device name in the background, so the one cold mDNS
// lookup (2.7 s on Windows, forgotten within a minute) is paid when a project is loaded and not
// when Start is pressed (#240). Best effort: a name that does not resolve now is tried again by
// the open, which reports it. Nothing else touches the device.
pub fn cansub_warm(iface string) {
	spec := parse_cansub_iface(iface) or { return }
	cansub_warm_host(cansub_host(spec.id))
}

// cansub_warm_all warms each DEVICE among `ifaces` once: three channels of one CANsub are three
// rows and one name, and one worker per row was three lookups queued on one lock (codex round 2
// on #249). Non-CANsub interfaces are ignored, so a caller can hand it the whole project.
pub fn cansub_warm_all(ifaces []string) {
	mut seen := map[string]bool{}
	for iface in ifaces {
		spec := parse_cansub_iface(iface) or { continue }
		host := cansub_host(spec.id)
		if host in seen {
			continue
		}
		seen[host] = true
		cansub_warm_host(host)
	}
}

// cansub_warm_host is the warm-up by name, and hands back its worker so a caller that needs the
// answer — a test — can wait for it; cansub_warm itself never does.
pub fn cansub_warm_host(host string) thread {
	lock cansub_addrs {
		cansub_addrs.warmups++
	}
	return spawn fn (h string) {
		_ = cansub_lookup(h, true) or { '' }
	}(host)
}

// cansub_refresh_addr drops the remembered address and nothing else: the next lookup resolves
// the name again, and connections in flight are not disowned. See cansub_dial.
fn cansub_refresh_addr(host string) {
	lock cansub_addrs {
		cansub_addrs.by_host.delete(host)
		cansub_addrs.failed_at.delete(host)
	}
}

// cansub_forget_addr drops a remembered address: the next cansub_addr resolves the name again.
pub fn cansub_forget_addr(host string) {
	lock cansub_addrs {
		cansub_addrs.by_host.delete(host)
		cansub_addrs.failed_at.delete(host)
		cansub_addrs.generation[host]++
	}
	// AND THE CONNECTION DIALLED TO IT. An address is forgotten because the device behind it is
	// not the one the name means any more — a firmware update moved it and another CANsub now
	// answers there (open_cansub_bus's identity check). A kept-alive connection to that address
	// is the same wrong device; left in the pool, the retry after the forget would ask it again
	// and never re-resolve (codex round 1 on #248).
	stale := lock cansub_pool {
		cansub_pool.conns[host] or { unsafe { nil } }
	}
	if stale != unsafe { nil } {
		mut s := unsafe { stale }
		s.drop()
	}
}

// cansub_dial connects to the device by its remembered address, resolving the name on the first
// call and again after a connect that fails. See cansub_request for the measurement behind it.
fn cansub_dial(host string) !&net.TcpConn {
	addr := cansub_addr(host) or { return error('cannot resolve ${host}') }
	if tcp := net.dial_tcp('${addr}:443') {
		return tcp
	}
	// The remembered address did not answer: the device may have moved. Look it up again, once.
	// A REFRESH, not a forget: nothing here has learned the device is the wrong one, only that
	// the address is stale, so the generation — which a dial in flight is checked against — is
	// left alone. Bumped here, this very dial came back to a changed generation and refused
	// the connection it had just made (codex round 6 on #248).
	cansub_refresh_addr(host)
	fresh := cansub_addr(host) or { return error('cannot resolve ${host}') }
	return net.dial_tcp('${fresh}:443')!
}

// cansub_resolves reports whether a device id can be found on this machine at all, so a caller can
// tell "not plugged in" from "plugged in and refusing".
pub fn cansub_resolves(id string) bool {
	net.resolve_addrs(cansub_host(id) + ':443', .ip, .tcp) or { return false }
	return true
}
