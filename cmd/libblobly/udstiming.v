// udstiming.v — bb.h's UDS timing and DoIP retarget calls on a UDS handle (uds.v): the client's
// waits read and stated by blobly/uds's rule (Timing), and a DoIP connection's target moved to a
// node behind its gateway (doip.DoipClient.retarget).
module main

import blobly.uds

@[export: 'bb_uds_get_timing']
pub fn bb_uds_get_timing(u i32, out &C.bb_uds_timing) i32 {
	if isnil(out) {
		return fail(bb_err, 'timing: nowhere to put it')
	}
	return with_uds(u, fn [out] (mut hd UdsHandle) !i32 {
		t := hd.conn.cli.timing()
		unsafe {
			out.timeout_ms = i32(t.timeout_ms)
			out.p2_star_ms = i32(t.p2_star_ms)
			out.margin_ms = i32(t.margin_ms)
			out.pending_budget_ms = i32(t.pending_budget_ms)
		}
		return ok()
	})
}

@[export: 'bb_uds_set_timing']
pub fn bb_uds_set_timing(u i32, t &C.bb_uds_timing) i32 {
	if isnil(t) {
		return fail(bb_err, 'set_timing: no timing given')
	}
	stated := unsafe {
		uds.Timing{
			timeout_ms:        int(t.timeout_ms)
			p2_star_ms:        int(t.p2_star_ms)
			margin_ms:         int(t.margin_ms)
			pending_budget_ms: int(t.pending_budget_ms)
		}
	}
	return with_uds(u, fn [stated] (mut hd UdsHandle) !i32 {
		hd.conn.cli.set_timing(stated)!
		return ok()
	})
}

// bb_uds_retarget: a DoIP handle's requests, and the answers it takes, to logical address
// *address (NULL: the row's ecu_address), kept across a reopen of a lost connection.
@[export: 'bb_uds_retarget']
pub fn bb_uds_retarget(u i32, address &i64) i32 {
	given := !isnil(address)
	asked := if given { unsafe { *address } } else { i64(0) }
	return with_uds(u, fn [given, asked] (mut hd UdsHandle) !i32 {
		if !hd.doip {
			return error('retarget: a CAN handle reaches its ECU by its ids; retarget is a DoIP connection\'s')
		}
		if given && (asked < 0 || asked > 0xFFFF) {
			return error('retarget: ${asked} is not a logical address (0 .. 0xFFFF)')
		}
		target := if given { u16(asked) } else { hd.car.ecu }
		hd.target = target
		if mut hd.conn.ch is DoipLink {
			hd.conn.ch.retarget(target)
		}
		return ok()
	})
}
