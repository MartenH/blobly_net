module someip

import transport

// listen — the PASSIVE half of a SOME/IP tester: sit on a port (and, for events a service
// publishes to a group, join it) and report every message that arrives, decoded to its header
// and raw payload. Nothing is sent, nothing is subscribed to, nothing is interpreted: the
// payload layout is deployment-defined (blobly derives it from config; a vsomeip-style SUT
// describes it elsewhere) and stays opaque here. The DoIP twin is doip.collect_announcements,
// on the same transport.udp_window; the design boundary is docs/ethernet_architecture.md.
//
// What this listener can hear without asking is what the network already carries: a
// blobly_emb node's events to its static peer (bind the peer port), a service's events on a
// multicast group (join it), and the SD offers a discovering SUT multicasts (join the SD group
// on 30490 — a plain bind on that port receives none of them, multicast needs the join). What
// it cannot hear is an event a service delivers only to subscribers, because subscribing is
// SOME/IP-SD's find/subscribe exchange and that is the middleware line this tester does not
// cross.

// The port SD and, by convention, most deployments use. A default, not a rule: a caller
// listening for a blobly_emb node names that node's configured port.
pub const default_port = 30490

// Observed is one message as it arrived: where from, when (ms into the window), and what.
pub struct Observed {
pub:
	at_ms   i64
	from    string // sender host:port
	header  Header
	payload []u8
}

// Capture is what a listening window returned. `malformed` counts DATAGRAMS that were not
// SOME/IP to the end — empty, a truncated message, a Length under the minimum, a trailing
// fragment — each a fact about the wire, reported rather than dropped in silence; the messages
// that parsed before the fault are kept.
pub struct Capture {
pub mut:
	messages  []Observed
	malformed int
}

// split reads every message in one datagram. SOME/IP allows a datagram to carry several
// messages back to back, each announcing its own Length, and vsomeip packs them that way
// under load — so a datagram is not a message. Returns the messages found and whether the
// datagram was consumed exactly; on `false` the returned messages are those before the fault.
pub fn split(buf []u8) ([]Message, bool) {
	mut out := []Message{}
	mut off := 0
	for off < buf.len {
		rest := buf[off..]
		h := parse_header(rest) or { return out, false }
		if h.length < length_base {
			return out, false
		}
		// u64: a hostile Length near 2^32 must not wrap the arithmetic (parse's own rule)
		total := 8 + u64(h.length)
		if total > u64(rest.len) {
			return out, false
		}
		m := parse(rest[..int(total)]) or { return out, false }
		out << m
		off += int(total)
	}
	return out, true
}

// ingest reads ONE datagram into the capture — the malformed rule, in one place, for every
// caller (the one-shot window below and the GUI channel's continuous reader). A datagram that
// is not SOME/IP to its end counts once: empty, truncated, a Length under the minimum, or a
// trailing fragment. The messages that parsed before the fault are kept.
pub fn (mut cap Capture) ingest(d transport.Datagram) {
	if d.data.len == 0 {
		cap.malformed++ // an empty datagram is on the wire and is not a message
		return
	}
	msgs, whole := split(d.data)
	if !whole {
		cap.malformed++
	}
	for m in msgs {
		cap.messages << Observed{
			at_ms:   d.at_ms
			from:    d.from
			header:  m.header
			payload: m.payload
		}
	}
}

// bind_addr is transport.udp_bind_addr under this module's name: the address a listener binds.
pub fn bind_addr(host string, port int) string {
	return transport.udp_bind_addr(host, port)
}

// check_group_bind refuses a multicast group on a UNICAST bind address. A socket bound to one
// address receives only what is addressed to it, so the kernel drops group-addressed datagrams
// after a perfectly successful IP_ADD_MEMBERSHIP: the listener would sit green and silent. The
// refusal names the fix rather than quietly rewriting the address the operator configured.
// KNOWN LIMITATION, stated where the rule is made: the join itself goes to the default-route
// interface (udp_bind is passed the wildcard), and this refusal closes the only other lever a
// project had — selecting a NIC through the bind address — without opening a replacement. On a
// multi-homed host (a bench NIC beside a WSL or VPN interface) a group offered on the other NIC
// is therefore not heard, and the row sits green. It is a limitation rather than a regression,
// since neither lever ever worked: a socket bound to a unicast address receives no multicast at
// all. A per-channel multicast-interface setting is the fix, tracked separately.
pub fn check_group_bind(host string, group string) ! {
	if group == '' || host == '' || host == '0.0.0.0' || host == '::' || host == '[::]' {
		return
	}
	return error('cannot join ${group} while bound to ${host}: a multicast join needs the wildcard address (leave the host empty, or use 0.0.0.0)')
}

// collect listens on `host`:`port` for `window_ms` and returns what arrived. `group` non-empty
// joins that IPv4 multicast group on the bound socket; a join that fails is an error, not a
// quiet empty window (transport.udp_bind's rule).
pub fn collect(host string, port int, window_ms int, group string) !Capture {
	check_group_bind(host, group)!
	// Claimed for the life of the window, so a GUI row cannot be started onto this endpoint
	// underneath it and split the stream — and so this window is refused if a row already holds
	// it. See transport/udpclaims.v for why a successful bind cannot answer that question.
	canon := transport.claim_endpoint(host, port, 'a script', .tool)!
	defer {
		transport.release_endpoint(canon, port, 'a script')
	}
	// BOUND ON WHAT WAS CLAIMED, not on the spelling: the registry resolved once, and binding the
	// name again could land on a different address than the one it is holding.
	// EMPTY SELECTOR, so udp_bind chooses it from the GROUP's family. Passing '0.0.0.0' here
	// took the explicit-interface branch and handed an IPv4 spelling to an IPv6 join, which is
	// the very failure the family default was added for — the fix was unreachable from its own
	// caller. A caller that genuinely wants one interface names it; these do not.
	got := transport.udp_window(bind_addr(canon, port), group, '', window_ms)!
	mut cap := Capture{}
	for d in got {
		cap.ingest(d)
	}
	return cap
}
