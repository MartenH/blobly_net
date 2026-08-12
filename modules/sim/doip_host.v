// The UDS handler a hosted DoIP entity serves behind. Shared by the GUI and the headless
// runner: both had their own copy of the wire policy for a write to DID 0xF190, so a
// correction to accepted lengths or announcement handling in one would have made the same
// project behave differently depending on which side ran it.
module sim

import uds
import doip

// DoipHost is a hosted entity's mutable serving state.
//
// `entity` is filled in AFTER doip.new_server(), which needs the handler that needs this — the
// two are circular by construction, so the link is made once both exist rather than captured.
pub struct DoipHost {
pub mut:
	server uds.Server
	entity &doip.DoipServer = unsafe { nil }
}

// handle serves one request, keeping the entity's two identity surfaces in step.
//
// A write to DID 0xF190 changes the SERVED identity, so the ANNOUNCED one has to move with it
// or the entity spends the rest of the run advertising a VIN it no longer reports. A VIN of
// any other length than 17 is refused rather than accepted: vehicle_announcement zero-pads or
// truncates to 17 while the server would return it whole, which is the same split created at
// runtime instead of from configuration.
pub fn (mut h DoipHost) handle(req []u8) []u8 {
	if w := uds.written_did(req) {
		if w.did == 0xF190 {
			if w.data.len != 17 {
				return [u8(0x7F), uds.sid_write_data_by_identifier, 0x31] // requestOutOfRange
			}
			resp := h.server.handle(req)
			if resp.len > 0 && resp[0] == 0x6E && h.entity != unsafe { nil } {
				h.entity.set_vin(w.data.bytestr())
			}
			return resp
		}
	}
	return h.server.handle(req)
}
