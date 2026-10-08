module uds

import isotp
import transport

// node.v — serving one simulated ECU: its physical requests, and — when it answers one — the
// functional id's. A functional request is one Single Frame (ISO 15765-2); the answer goes out on
// the PHYSICAL channel, the only one whose Flow Control reaches this server, as a real ECU does
// (blobly_emb's comm/diag.Connection). The GUI's and the headless runner's node loops both run
// serve_step, so the two cannot answer a functional request differently.

// functional_suppressed: ISO 14229-1 has a server keep QUIET, rather than refuse, when a request
// that reached it functionally is one it does not support — NRC 0x11, 0x12, 0x31, 0x7E or 0x7F —
// or every ECU on the bus would answer a broadcast with a refusal.
pub fn functional_suppressed(resp []u8) bool {
	return resp.len == 3 && resp[0] == negative_response_sid
		&& resp[2] in [u8(0x11), 0x12, 0x31, 0x7E, 0x7F]
}

// NodeLink is what one served node listens on: its physical channel, and its place on the
// wire's functional listener when it answers a functional id (`func` empty when it does not).
pub struct NodeLink {
pub mut:
	phys isotp.Channel
	func []&FuncSub
}

// serve_step answers what is waiting: the functional Single Frames already queued, then a
// physical request (waiting up to `wait_ms`), handling any functional ones queued meanwhile
// first. Functional requests therefore go before a physical one that arrived after them —
// except one that arrives while a multi-frame physical request is being reassembled, which
// no ordering between two subscriptions can place. `wait_ms` is also that reassembly's whole
// deadline (the software channel gives a PDU one), so it is never shortened here.
//
// A physical receive that fails for any reason but silence is returned, so a loop whose bus has
// failed can back off (and reopen) instead of spinning on an error that comes back at once.
pub fn (mut s Server) serve_step(mut l NodeLink, wait_ms int) ! {
	s.serve_functional(mut l)
	req := l.phys.recv(wait_ms) or {
		if is_silence(err.msg()) {
			return
		}
		return err
	}
	s.serve_functional(mut l)
	resp := s.handle(req)
	if resp.len > 0 {
		l.phys.send(resp) or {}
	}
}

// serve_functional answers every functional Single Frame already queued, on the physical channel.
fn (mut s Server) serve_functional(mut l NodeLink) {
	for mut t in l.func {
		for {
			freq := t.take() or { break }
			if s.described && freq.len > 0 && freq[0] == 0x27 {
				continue // SecurityAccess is physical only: a described server ignores it (comm/uds)
			}
			resp := s.handle(freq)
			if resp.len > 0 && !functional_suppressed(resp) {
				l.phys.send(resp) or {}
			}
		}
	}
}

// close closes what the link listens on — the physical channel and its place on the functional
// listener — together, so a node switched off answers neither. Returns what the functional side
// has worth reporting (see FuncSub.leave).
pub fn (mut l NodeLink) close() []FuncLeave {
	l.phys.close()
	mut ds := []FuncLeave{}
	for mut t in l.func {
		ds << t.leave()
	}
	l.func = []
	return ds
}
