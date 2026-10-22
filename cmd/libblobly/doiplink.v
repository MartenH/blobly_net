// doiplink.v — a DoIP handle's connection as its client sees it: the one place every request goes
// out and every answer comes in, so the 0x27 rule holds whichever call carries a seed or a key.
module main

import blobly.doip
import blobly.transport

// SeedState is where the last 0x27 seed answered on a handle came from.
enum SeedState {
	none_   // no seed answered yet: the ECU judges a key
	current // answered on this connection
	stale   // answered on a connection since lost
}

// DoipLink is a DoipClient that remembers its seeds, per security level: a seed answer (67, an odd
// sub-function L) makes level L's current, and a key (27, L + 1) is refused, never written, when
// level L's seed came from a connection since lost — a key answers the seed of ONE connection.
@[heap]
struct DoipLink {
pub:
	iface string
	tx_id u32
	rx_id u32
mut:
	c     &doip.DoipClient
	seeds map[u8]SeedState // by level (the seed's sub-function); absent is .none_
}

// link_of wraps `c`; `before` is the link it replaces (nil for a first connection), whose seeds
// are all stale on this one.
fn link_of(c &doip.DoipClient, before &DoipLink) &DoipLink {
	mut seeds := map[u8]SeedState{}
	if !isnil(before) {
		for level, _ in before.seeds {
			seeds[level] = .stale
		}
	}
	return &DoipLink{
		iface: c.iface
		tx_id: c.tx_id
		rx_id: c.rx_id
		c:     unsafe { c }
		seeds: seeds
	}
}

fn (l &DoipLink) guard(data []u8) ! {
	if data.len < 2 || data[0] != 0x27 {
		return
	}
	sub := data[1] & 0x7F
	if sub != 0 && sub & 1 == 0 && l.seeds[sub - 1] or { SeedState.none_ } == .stale {
		return transport.not_written('security key: the connection that gave the level ${sub - 1} seed is gone; request a new seed')
	}
}

fn (mut l DoipLink) send(data []u8) ! {
	l.guard(data)!
	l.c.send(data)!
}

fn (mut l DoipLink) send_to(target u32, data []u8) ! {
	l.guard(data)!
	l.c.send_to(target, data)!
}

fn (mut l DoipLink) recv(timeout_ms int) ![]u8 {
	d := l.c.recv(timeout_ms)!
	if d.len >= 2 && d[0] == 0x67 && d[1] & 1 == 1 {
		l.seeds[d[1] & 0x7F] = .current
	}
	return d
}

fn (mut l DoipLink) close() {
	l.c.close()
}

fn (mut l DoipLink) diagnostics() transport.BusDiagnostics {
	return l.c.diagnostics()
}
