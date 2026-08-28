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
	mut tcp := net.dial_tcp('${host}:443')!
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

// cansub_resolves reports whether a device id can be found on this machine at all, so a caller can
// tell "not plugged in" from "plugged in and refusing".
pub fn cansub_resolves(id string) bool {
	net.resolve_addrs(cansub_host(id) + ':443', .ip, .tcp) or { return false }
	return true
}
