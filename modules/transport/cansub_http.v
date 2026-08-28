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
	mut conn := ssl.new_ssl_conn(
		validate:     false // the device signs its own certificate; see the note at the top
		read_timeout: timeout
	)!
	// THE CONNECT IS BOUNDED, AND BY THIS CODE. SSLConn.dial connects through mbedtls_net_connect,
	// a blocking OS connect with no budget of ours — on Windows around 21 s to a host that
	// resolves and then blackholes — and `read_timeout`, the one budget the SSL client offers,
	// starts AFTER the connection is up. So the TCP connection is made here, through net.dial_tcp
	// (five seconds, vlib's own select), and handed to the SSL layer. What that bounds is every
	// REST call this backend makes, including the PUT a sender's reconcile can run under the wire
	// lock while every other sender and close() wait on it (codex round 3 on #223).
	// THE CONNECT BOUND IS vlib's FIVE SECONDS, not `timeout`: net.dial_tcp has no per-call knob
	// (its connect_timeout is a module constant), so the 700 ms and 2 s budgets below cap the
	// request AFTER the connection is up. A tighter bound means a hand-rolled non-blocking
	// connect against the raw socket; not done here (codex round 11 on #223).
	// RESOLVED ONCE, DIALLED BY ADDRESS. A cold mDNS lookup of `<id>-usb.local` costs ~2.7 s on
	// Windows and the answer is not kept for a minute (measured 2026-08-28: 2.681 s cold, 8 ms
	// warm, cold again after 60 s idle), while the request itself takes 0.11 s. Every REST call
	// here made its own connection and paid that lookup on the first call after any pause — the
	// open (three connections, so Start stalled ~3 s behind the CANsub row), every reconnect,
	// and the health poll after any stall (#240). The name is looked up once per process and the
	// address kept; a connect that fails forgets it and looks up again, which is what the name
	// was for — the device changes subnet across firmware updates, and the name follows it.
	mut tcp := cansub_dial(host)!
	defer {
		conn.shutdown() or {}
		tcp.close() or {}
	}
	conn.connect(mut tcp, host)!
	mut req := '${method} ${path} HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n'
	if body != '' {
		req += 'Content-Type: application/json\r\nContent-Length: ${body.len}\r\n'
	}
	req += '\r\n' + body
	conn.write_string(req)!

	mut raw := []u8{}
	mut buf := []u8{len: 4096}
	for {
		n := conn.read(mut buf) or { break } // the close is how the device says it is done
		if n <= 0 {
			break
		}
		raw << buf[..n]
		if raw.len > 1 << 20 {
			return error('response from ${path} exceeded 1 MiB')
		}
	}
	if raw.len == 0 {
		return error('${method} ${path}: no response')
	}
	return cansub_parse_response(raw.bytestr())
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
}

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
	addrs := net.resolve_ipaddrs(host, .ip, .tcp) or {
		cansub_note_failed_lookup(host)
		return none
	}
	if addrs.len == 0 {
		cansub_note_failed_lookup(host)
		return none
	}
	// The address without a port: resolve_ipaddrs answers for host:port pairs too, and the
	// dialler adds its own port.
	ip := addrs[0].str().all_before_last(':')
	if ip == '' {
		return none
	}
	lock cansub_addrs {
		cansub_addrs.by_host[host] = ip
		cansub_addrs.failed_at.delete(host)
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

// cansub_forget_addr drops a remembered address: the next cansub_addr resolves the name again.
pub fn cansub_forget_addr(host string) {
	lock cansub_addrs {
		cansub_addrs.by_host.delete(host)
		cansub_addrs.failed_at.delete(host)
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
	cansub_forget_addr(host)
	fresh := cansub_addr(host) or { return error('cannot resolve ${host}') }
	return net.dial_tcp('${fresh}:443')!
}

// cansub_resolves reports whether a device id can be found on this machine at all, so a caller can
// tell "not plugged in" from "plugged in and refusing".
pub fn cansub_resolves(id string) bool {
	net.resolve_addrs(cansub_host(id) + ':443', .ip, .tcp) or { return false }
	return true
}
