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

// NodeLink is what one served node listens on: its physical channel, and a raw subscription to
// the bus for the functional id when it answers one (`func` empty when it does not).
pub struct NodeLink {
pub mut:
	phys isotp.Channel
	func []transport.Bus
	fid  u32
	fext bool
}

// serve_step answers what is waiting: a physical request (waiting up to `wait_ms`, less when a
// functional listener shares the loop), then every functional Single Frame already queued.
pub fn (mut s Server) serve_step(mut l NodeLink, wait_ms int) {
	wait := if l.func.len > 0 && wait_ms > 10 { 10 } else { wait_ms }
	req := l.phys.recv(wait) or { []u8{} }
	if req.len > 0 {
		resp := s.handle(req)
		if resp.len > 0 {
			l.phys.send(resp) or {}
		}
	}
	for mut t in l.func {
		for {
			f := t.recv(0) or { break }
			if f.id != l.fid || f.extended != l.fext || f.rtr {
				continue
			}
			freq := isotp.single_frame(f.data) or { continue } // functional: one Single Frame
			resp := s.handle(freq)
			if resp.len > 0 && !functional_suppressed(resp) {
				l.phys.send(resp) or {}
			}
		}
	}
}
