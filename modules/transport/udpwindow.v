// udpwindow — ONE listening window for every passive UDP observer: bind, optionally join a
// group, read until the deadline, hand back what arrived. doip's announcement collector and
// someip's listener both sit on this, so the policy of what ends a window lives in one place.
//
// Only the DEADLINE ends the window. This V reports a zero-byte read as an error (`error('none')`,
// code 0), and a legal empty datagram is exactly that — a loop that broke on any read error
// returned early with a partial, successful-looking result: heard nothing, reported nothing
// wrong. An empty datagram is returned as an empty Datagram (its sender is not available on
// that path); any other fault is waited out, since the window is the bound the caller asked for.
module transport

import net
import time

// Datagram is one UDP datagram as a listening window saw it: when (ms into the window), from
// whom (host:port; empty for a zero-byte datagram, which this V reports without its sender),
// and the bytes.
pub struct Datagram {
pub:
	at_ms i64
	from  string
	data  []u8
}

// udp_bind binds `addr` and, when `group` is given, joins it on `iface`. A failed join is
// RETURNED rather than swallowed: a listener that silently failed to join would wait out its
// window and report an empty success, indistinguishable from a peer that stayed quiet.
//
// NOTE what this canNOT promise. This V sets SO_REUSEADDR inside its private socket constructor,
// before the bind, so nothing reachable from the public net API turns it off — a second binder
// on a held UDP port SUCCEEDS, and the kernel then delivers each unicast datagram to exactly one
// of the sockets. So a successful bind here does NOT mean this process is the only reader; it
// means it is A reader. Callers that need "nobody else has this endpoint" have to arrange it
// themselves, and callers that document their behaviour must not promise a refusal.
pub fn udp_bind(addr string, group string, iface string) !&net.UdpConn {
	mut c := net.listen_udp(addr) or { return error('cannot listen on ${addr}: ${err}') }
	if group != '' {
		// THE SELECTOR'S FORM FOLLOWS THE GROUP'S FAMILY. V parses the IPv6 argument as a numeric
		// interface INDEX, not an address, so `0.0.0.0` fails there with "must be a numeric
		// interface index" — the DoIP collector already passes `0` for exactly this reason, and
		// a v6 group joined with the v4 spelling never receives anything. `iface` is honoured
		// when the caller names one; the default is chosen here.
		sel := if iface != '' {
			iface
		} else if group.contains(':') {
			'0' // any interface, IPv6 spelling
		} else {
			'0.0.0.0' // any interface, IPv4 spelling
		}
		c.join_multicast_group(group, sel) or {
			// close before returning, or the descriptor leaks and holds the port; these are
			// opened in a loop by suites that retry.
			c.close() or {}
			return error('cannot join ${group} on ${addr}: ${err}')
		}
	}
	return c
}

// udp_read returns the next datagram, or none when `timeout_ms` passes with nothing.
//
// ONLY A TIMEOUT IS none. This V reports a zero-byte read as an error (`error('none')`, code 0),
// and a legal empty datagram is exactly that — a caller that treated any read error as the end
// returned early with a partial, successful-looking result: heard nothing, reported nothing
// wrong. An empty datagram comes back as an empty Datagram; any other fault pauses briefly (so a
// persistent one cannot spin a caller's loop) and reports none, leaving the caller's own clock
// to decide when to stop.
pub fn udp_read(mut c net.UdpConn, timeout_ms int) ?Datagram {
	// One datagram. 64 KiB is the UDP maximum: `recvfrom` gives no MSG_TRUNC here, so a buffer
	// smaller than the largest datagram silently cuts it, and the cut then reads as a malformed
	// wire rather than as the reader's own limit. One allocation per call, at the caller's
	// cadence — the window below hoists it out of its loop.
	mut buf := []u8{len: 65535}
	return udp_read_into(mut c, timeout_ms, mut buf)
}

// udp_read_into is udp_read with the caller's buffer, for a loop that reads continuously.
pub fn udp_read_into(mut c net.UdpConn, timeout_ms int, mut buf []u8) ?Datagram {
	c.set_read_timeout(timeout_ms * time.millisecond)
	n, peer := c.read(mut buf) or {
		if err.code() == 0 {
			return Datagram{} // a legal empty datagram, not the end of anything
		}
		if err.code() != net.err_timed_out_code {
			time.sleep(1 * time.millisecond)
		}
		return none
	}
	return Datagram{
		from: peer.str()
		data: buf[..n].clone()
	}
}

// udp_window binds, reads for `window_ms`, and closes — the one-shot form.
pub fn udp_window(addr string, group string, iface string, window_ms int) ![]Datagram {
	mut c := udp_bind(addr, group, iface)!
	defer {
		c.close() or {}
	}
	return udp_window_on(mut c, window_ms)
}

// udp_window_on reads from an already-bound socket until the deadline.
fn udp_window_on(mut c net.UdpConn, window_ms int) []Datagram {
	mut out := []Datagram{}
	// MONOTONIC: a wall-clock deadline moves under NTP or a VM time correction, and either ends
	// the window early or stretches the next read timeout far past it.
	start := time.ticks()
	deadline := start + i64(window_ms)
	mut buf := []u8{len: 65535}
	for {
		left := deadline - time.ticks()
		if left <= 0 {
			break
		}
		d := udp_read_into(mut c, int(left), mut buf) or { continue }
		out << Datagram{
			...d
			at_ms: time.ticks() - start
		}
	}
	return out
}
