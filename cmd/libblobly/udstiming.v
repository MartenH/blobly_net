// udstiming.v — bb.h's UDS timing and DoIP retarget calls on a UDS handle (uds.v): the client's
// waits read and stated by blobly/uds's rule (Timing, Waits), and a DoIP connection's target moved
// to a node behind its gateway (doip.DoipClient.retarget).
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

// waits_of is wait `which` (an enum bb_uds_wait) at `ms`, as uds.Waits.
fn waits_of(which i32, ms i32) !uds.Waits {
	return match which {
		i32(C.BB_WAIT_TIMEOUT) { uds.Waits{
				timeout_ms: int(ms)
			} }
		i32(C.BB_WAIT_P2_STAR) { uds.Waits{
				p2_star_ms: int(ms)
			} }
		i32(C.BB_WAIT_MARGIN) { uds.Waits{
				margin_ms: int(ms)
			} }
		i32(C.BB_WAIT_PENDING_BUDGET) { uds.Waits{
				pending_budget_ms: int(ms)
			} }
		else { error('set_wait: ${which} is not an enum bb_uds_wait') }
	}
}

// bb_uds_set_wait: one of the handle's waits stated (uds.Client.state).
@[export: 'bb_uds_set_wait']
pub fn bb_uds_set_wait(u i32, which i32, ms i32) i32 {
	w := waits_of(which, ms) or { return fail(bb_err, err.msg()) }
	return with_uds(u, fn [w] (mut hd UdsHandle) !i32 {
		hd.conn.cli.state(w)!
		return ok()
	})
}

// bb_uds_check_wait: whether bb_uds_set_wait would take the wait, asked of no handle, so a host
// refuses a wait before it opens a connection to state it on.
@[export: 'bb_uds_check_wait']
pub fn bb_uds_check_wait(which i32, ms i32) i32 {
	w := waits_of(which, ms) or { return fail(bb_err, err.msg()) }
	mut probe := uds.Client{}
	probe.state(w) or { return fail(bb_err, err.msg()) }
	return ok()
}

// bb_uds_retarget: a DoIP handle's requests, and the answers it takes, to logical address
// *address (NULL: the row's ecu_address), kept across a reopen of a lost connection; another
// target is another ECU, so the client starts again from what the host stated (another_ecu).
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
		if target != hd.target {
			hd.conn.cli.another_ecu()
		}
		hd.target = target
		if mut hd.conn.ch is DoipLink {
			hd.conn.ch.retarget(target)
		}
		return ok()
	})
}
