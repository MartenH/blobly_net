// The UDS handler a hosted DoIP entity serves behind. Shared by the GUI and the headless
// runner: both had their own copy of the wire policy for a write to DID 0xF190, so a
// correction to accepted lengths or announcement handling in one would have made the same
// project behave differently depending on which side ran it.
module sim

import blobly.uds
import blobly.doip

// DoipHost is a hosted entity's mutable serving state.
//
// `entity` is filled in AFTER doip.new_server(), which needs the handler that needs this — the
// two are circular by construction, so the link is made once both exist rather than captured.
pub struct DoipHost {
pub mut:
	server uds.Server
	entity &doip.DoipServer = unsafe { nil }
mut:
	// how many entities were bound to this host (bind_close): a close handler acts for the entity
	// bound last only
	bound u64
}

// handle serves one physically addressed request (serve).
pub fn (mut h DoipHost) handle(req []u8) []u8 {
	return h.serve(req, false)
}

// handle_functional serves a request that arrived on the functional address (serve), through the
// server's own functional entry (uds.Server.handle_functional): one rule on CAN and DoIP for what
// a broadcast may not do, S3 kept either way.
pub fn (mut h DoipHost) handle_functional(req []u8) []u8 {
	return h.serve(req, true)
}

// serve answers a request either way it was addressed, keeping the entity's two identity surfaces
// in step. A functional 0x2E is served like a physical one (ISO 14229-1 does not restrict it, and
// blobly_emb's comm/uds dispatches it), so the F190 rule is applied here, on both paths.
//
// A write to DID 0xF190 changes the SERVED identity, so the ANNOUNCED one has to move with it
// or the entity spends the rest of the run advertising a VIN it no longer reports. A VIN of
// any other length than 17 is refused rather than accepted: vehicle_announcement zero-pads or
// truncates to 17 while the server would return it whole, which is the same split created at
// runtime instead of from configuration. A described server judges the write itself (its
// gates, then the declared size), and the announcement follows only a 17-byte VIN it accepted.
fn (mut h DoipHost) serve(req []u8, functional bool) []u8 {
	w := uds.written_did(req) or { return h.answer(req, functional) }
	if w.did != 0xF190 {
		return h.answer(req, functional)
	}
	if w.data.len != 17 && !h.server.described {
		return [u8(0x7F), uds.sid_write_data_by_identifier, 0x31] // requestOutOfRange
	}
	resp := h.answer(req, functional)
	if resp.len > 0 && resp[0] == 0x6E && w.data.len == 17 && h.entity != unsafe { nil } {
		h.entity.set_vin(w.data.bytestr())
	}
	return resp
}

fn (mut h DoipHost) answer(req []u8, functional bool) []u8 {
	return if functional { h.server.handle_functional(req) } else { h.server.handle(req) }
}

// dropped: the entity's tester connection ended — what the server kept for it (a seed or 0x29
// challenge, an unlock, the session it opened) ends with it, as on the board (comm/diag
// remote_dropped). The next connection authenticates for itself.
pub fn (mut h DoipHost) dropped() {
	h.server.connection_dropped()
}

// bind_close tells the host when the entity's tester connection ends (dropped) — for the entity
// bound LAST: a host bound to a new entity (the GUI's watcher re-binds one host when its node is
// ticked off and on, and does not join the old entity's serving thread) ignores a late close from
// the one before, which would otherwise reset the new connection's session, challenge and unlock.
pub fn (mut h DoipHost) bind_close(mut s doip.DoipServer) {
	s.set_close_handler(h.closer())
}

// closer: the close handler of the entity being bound now (bind_close)
fn (mut h DoipHost) closer() fn () {
	h.bound++
	gen := h.bound
	return fn [mut h, gen] () {
		if gen == h.bound {
			h.dropped()
		}
	}
}

// bind_functional hands an entity's functional requests to its host.
pub fn (mut h DoipHost) bind_functional(mut s doip.DoipServer) {
	s.set_functional_handler(fn [mut h] (req []u8) []u8 {
		return h.handle_functional(req)
	})
}
