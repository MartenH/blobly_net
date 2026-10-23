// doiplink.v — a DoIP handle's connection as its client sees it: the one place every request goes
// out and every answer comes in, so the 0x27 rule holds whichever call carries a seed or a key.
module main

import blobly.doip
import blobly.transport

// DoipLink is a DoipClient that remembers which security levels' seeds it answered, and of which
// target: a seed request (27, an odd sub-function L) whose exchange accepted its answer marks level
// L of the target it went to (UdsHandle.seed_heard, never a stray 67 on the stream), and on a link
// that `inherits` — opened in place of a connection that may have given seeds (a reconnect, or a
// host reopening its client) — a key (27, L + 1) is refused, never written, until level L's seed is
// answered on this one by the target the key goes to: a key answers the seed of ONE connection, and
// a gateway's seed is not a node's behind it. On a first connection the ECU judges every key.
@[heap]
struct DoipLink {
pub:
	iface string
	tx_id u32
pub mut:
	rx_id u32 // the target: the entity, or a node behind it (retarget)
mut:
	c        &doip.DoipClient
	seeds    map[u32]bool // seed_key(target, level) of the seeds this connection answered
	inherits bool
}

// seed_key is level `level`'s seed of target `target`.
fn seed_key(target u32, level u8) u32 {
	return target << 8 | u32(level)
}

// retarget moves the link's requests and the answers it takes to logical address `target`
// (doip.DoipClient.retarget).
fn (mut l DoipLink) retarget(target u16) {
	l.c.retarget(target)
	l.rx_id = target
}

// link_of wraps `c`; `inherits` when it replaces a connection.
fn link_of(c &doip.DoipClient, inherits bool) &DoipLink {
	return &DoipLink{
		iface:    c.iface
		tx_id:    c.tx_id
		rx_id:    c.rx_id
		c:        unsafe { c }
		inherits: inherits
	}
}

fn (l &DoipLink) guard(data []u8) ! {
	if !l.inherits || data.len < 2 || data[0] != 0x27 {
		return
	}
	sub := data[1] & 0x7F
	if sub != 0 && sub & 1 == 0 && !l.seeds[seed_key(l.rx_id, sub - 1)] {
		return transport.not_written('security key: the level ${sub - 1} seed was not answered on this connection, which replaces the one that may have given it; request a new seed')
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
	return l.c.recv(timeout_ms)!
}

fn (mut l DoipLink) close() {
	l.c.close()
}

fn (mut l DoipLink) diagnostics() transport.BusDiagnostics {
	return l.c.diagnostics()
}
