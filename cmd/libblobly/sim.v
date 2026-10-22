// Fault injection on the run's simulated ECUs and AUTOSAR E2E Profile 1 for frames a host builds
// (bb.h's "Faults and E2E" block): sim.FaultTarget.arm, sim.p01_frame_crc and sim.p01_protect, the
// rules Lua's sim.fault and e2e.* ask.
module main

import blobly.headless
import blobly.sim

__global (
	// the run's rows as sim.FaultTarget.arm judges a fault on them, aligned with bb_dbs and under
	// bb_mu with it: a fault may be armed from any thread
	bb_fault_rows []sim.FaultTarget
)

// fault_rows_publish / fault_rows_retire keep bb_fault_rows the run's; the caller holds bb_mu.
fn fault_rows_publish(chans []headless.Channel) {
	bb_fault_rows = chans.map(it.fault_target())
}

fn fault_rows_retire() {
	bb_fault_rows = []sim.FaultTarget{}
}

fn vstr(p &char) string {
	return if isnil(p) { '' } else { unsafe { cstring_to_vstring(p) } }
}

@[export: 'bb_sim_fault']
pub fn bb_sim_fault(row i32, node &char, message &char, kind &char, ms i32, signal &char) i32 {
	if isnil(node) || isnil(message) || isnil(kind) {
		return fail(bb_err, 'sim_fault: no node, message or kind')
	}
	bb_mu.lock()
	live := bb_dbs_live
	rows := bb_fault_rows
	bb_mu.unlock()
	if !live {
		return fail(bb_err_state, 'not started: a fault is armed on the run, from bb_start until bb_stop')
	}
	if row < 0 || int(row) >= rows.len {
		return fail(bb_err, 'no channel ${row}')
	}
	rows[int(row)].arm(vstr(node), vstr(message), vstr(kind), int(ms), vstr(signal)) or {
		return fail(bb_err, err.msg())
	}
	return ok()
}

@[export: 'bb_sim_clear_faults']
pub fn bb_sim_clear_faults() i32 {
	sim.clear_all()
	return ok()
}

// frame_bytes is the host's n bytes at data.
fn frame_bytes(data &u8, n i32) ![]u8 {
	if n < 0 || (n > 0 && isnil(data)) {
		return error('a frame of ${n} bytes, and no bytes')
	}
	if n == 0 {
		return []u8{}
	}
	return unsafe { data.vbytes(int(n)) }.clone()
}

@[export: 'bb_e2e_p01_crc']
pub fn bb_e2e_p01_crc(data &u8, n i32, data_id i32, crc_pos i32, counter_pos i32, mode &char) i32 {
	d := frame_bytes(data, n) or { return fail(bb_err, 'e2e_p01_crc: ${err.msg()}') }
	crc := sim.p01_frame_crc(d, data_id, crc_pos, counter_pos, vstr(mode)) or {
		return fail(bb_err, err.msg())
	}
	ok()
	return i32(crc)
}

@[export: 'bb_e2e_p01_protect']
pub fn bb_e2e_p01_protect(data &u8, n i32, data_id i32, crc_pos i32, counter_pos i32, counter i32, mode &char) i32 {
	d := frame_bytes(data, n) or { return fail(bb_err, 'e2e_p01_protect: ${err.msg()}') }
	out := sim.p01_protect(d, data_id, crc_pos, counter_pos, counter, vstr(mode)) or {
		return fail(bb_err, err.msg())
	}
	unsafe { vmemcpy(data, out.data, out.len) }
	return ok()
}
