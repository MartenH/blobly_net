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

// udp_window binds `addr`, joins `group` on `iface` when a group is given, and returns every
// datagram that arrives in `window_ms`. A failed join is RETURNED: silently waiting out the
// window would report an empty success, indistinguishable from a peer that stayed quiet.
pub fn udp_window(addr string, group string, iface string, window_ms int) ![]Datagram {
	mut c := net.listen_udp(addr) or { return error('cannot listen on ${addr}: ${err}') }
	// BEFORE the join: an early return past this point would leak the descriptor and hold the
	// port, and these windows are opened in a loop by suites that retry.
	defer {
		c.close() or {}
	}
	if group != '' {
		c.join_multicast_group(group, iface) or {
			return error('cannot join ${group} on ${addr}: ${err}')
		}
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
	mut buf := []u8{len: 4096} // one datagram; anything on these protocols fits the MTU
	for {
		left := deadline - time.ticks()
		if left <= 0 {
			break
		}
		c.set_read_timeout(left * time.millisecond)
		n, peer := c.read(mut buf) or {
			if err.code() == net.err_timed_out_code {
				break
			}
			at := time.ticks() - start
			if err.code() == 0 {
				out << Datagram{
					at_ms: at
				}
				continue
			}
			// a transient fault (an ICMP unreachable surfacing, a signal): the window is still
			// open; a short pause keeps a persistent one from spinning the rest of it
			time.sleep(1 * time.millisecond)
			continue
		}
		out << Datagram{
			at_ms: time.ticks() - start
			from:  peer.str()
			data:  buf[..n].clone()
		}
	}
	return out
}
