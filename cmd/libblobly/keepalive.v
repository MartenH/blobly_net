// A UDS session kept alive (bb.h's "A UDS session kept alive" block): uds.KeepAlive on a handle's
// client, each keep-alive under the handle's `mu`, which every call on the handle holds.
module main

import sync.stdatomic
import blobly.uds

// stop_keep_alive ends the handle's keep-alive, if one runs; never with `mu` held.
fn (mut hd UdsHandle) stop_keep_alive() {
	hd.kset.lock()
	defer {
		hd.kset.unlock()
	}
	hd.stop_keep_alive_held()
}

// stop_keep_alive_held is stop_keep_alive with `kset` held.
fn (mut hd UdsHandle) stop_keep_alive_held() {
	hd.kmu.lock()
	ka := hd.ka
	hd.ka = unsafe { nil }
	hd.kmu.unlock()
	if !isnil(ka) {
		mut k := unsafe { ka }
		k.stop()
	}
}

// keep_alive_host is how a keep-alive reaches handle hd's client: under its `mu`, while it is open
// and its connection is there.
fn keep_alive_host(hd &UdsHandle) uds.KeepAliveHost {
	return uds.KeepAliveHost{
		acquire: fn [hd] () ?&uds.Client {
			mut h := unsafe { hd }
			if stdatomic.load_i64(&h.closing) != 0 {
				return none
			}
			h.mu.lock()
			if stdatomic.load_i64(&h.closing) != 0 || h.lost || h.idle_lost != '' {
				h.mu.unlock()
				return none
			}
			return &h.conn.cli
		}
		release: fn [hd] () {
			mut h := unsafe { hd }
			h.mu.unlock()
		}
		failed:  fn [hd] (err IError) {
			mut h := unsafe { hd }
			if uds.failure_of(err) == .lost {
				h.mark_lost() // the next call opens the connection again
			}
		}
	}
}

@[export: 'bb_uds_keep_alive']
pub fn bb_uds_keep_alive(u i32, period_ms i32) i32 {
	if period_ms != 0 && (period_ms < uds.keepalive_min_ms || period_ms > uds.keepalive_max_ms) {
		return fail(bb_err, 'keep_alive: a period of ${period_ms} ms: give ${uds.keepalive_min_ms} .. ${uds.keepalive_max_ms}, or 0 to stop')
	}
	mut hd := uds_enter(u) or { return fail(bb_err_handle, 'no open UDS handle ${u}') }
	defer {
		stdatomic.add_i64(&hd.users, -1)
	}
	if stdatomic.load_i64(&hd.closing) != 0 {
		return fail(bb_err_handle, 'the UDS handle was closed')
	}
	// the stop and the start one step: two calls at once leave one keep-alive, never an orphan
	hd.kset.lock()
	defer {
		hd.kset.unlock()
	}
	hd.stop_keep_alive_held()
	if period_ms == 0 {
		return ok()
	}
	ka := uds.keep_alive(int(period_ms), keep_alive_host(hd)) or { return fail(bb_err, err.msg()) }
	hd.kmu.lock()
	hd.ka = ka
	hd.kmu.unlock()
	return ok()
}

// keep_alive_of is the handle's keep-alive, nil when none runs.
fn keep_alive_of(u i32) !&uds.KeepAlive {
	mut hd := uds_enter(u) or { return error_with_code('no open UDS handle ${u}', int(bb_err_handle)) }
	defer {
		stdatomic.add_i64(&hd.users, -1)
	}
	hd.kmu.lock()
	defer {
		hd.kmu.unlock()
	}
	return hd.ka
}

@[export: 'bb_uds_keep_alive_status']
pub fn bb_uds_keep_alive_status(u i32, out &C.bb_keep_alive) i32 {
	if isnil(out) {
		return fail(bb_err, 'keep_alive_status: no bb_keep_alive to fill')
	}
	ka := keep_alive_of(u) or { return refused(err) }
	mut st := uds.KeepAliveStatus{}
	if !isnil(ka) {
		mut k := unsafe { ka }
		st = k.status()
	}
	unsafe {
		out.period_ms = i32(st.period_ms)
		out.sent = st.sent
		out.failures = st.failures
		out.running = u8(st.running)
	}
	return ok()
}

// bb_uds_keep_alive_failure: a failure taken is kept until a call copies it out whole, so a host
// that asks again with room for a cut one gets it.
@[export: 'bb_uds_keep_alive_failure']
pub fn bb_uds_keep_alive_failure(u i32, buf &char, cap i32) i32 {
	mut hd := uds_enter(u) or { return fail(bb_err_handle, 'no open UDS handle ${u}') }
	defer {
		stdatomic.add_i64(&hd.users, -1)
	}
	hd.kmu.lock()
	defer {
		hd.kmu.unlock()
	}
	if hd.ka_said == '' && !isnil(hd.ka) {
		mut k := hd.ka
		hd.ka_said = k.take_failure() or { '' }
	}
	n := put(hd.ka_said, buf, cap)
	if n >= 0 && n < cap {
		hd.ka_said = ''
	}
	return n
}
