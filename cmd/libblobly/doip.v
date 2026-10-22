// doip.v — bb.h's DoIP calls beside UDS: a row's entity asked who it is, announcements heard for a
// window, and the words for a denied routing activation. The rules are blobly/udsconn's and
// blobly/doip's, the ones the Lua doip.discover and doip.listen use.
module main

import net
import blobly.doip
import blobly.udsconn

// bb_last_routing: the routing activation code and tester address of the calling thread's last
// call, when it failed with BB_ERR_ROUTING.
@[export: 'bb_last_routing']
pub fn bb_last_routing(code &u8, tester &u16) i32 {
	v := C.bb_routing_get()
	if v < 0 {
		return bb_none
	}
	unsafe {
		if !isnil(code) {
			*code = u8(v)
		}
		if !isnil(tester) {
			*tester = u16(C.bb_routing_tester_get())
		}
	}
	return bb_ok
}

@[export: 'bb_doip_routing_name']
pub fn bb_doip_routing_name(code i32, buf &char, cap i32) i32 {
	c := byte_arg('routing activation code', code) or { return fail(bb_err, err.msg()) }
	return put(doip.ra_code_name(c), buf, cap)
}

@[export: 'bb_doip_routing_hint']
pub fn bb_doip_routing_hint(code i32, tester i32, buf &char, cap i32) i32 {
	c := byte_arg('routing activation code', code) or { return fail(bb_err, err.msg()) }
	if tester < 0 || tester > 0xFFFF {
		return fail(bb_err, 'tester ${tester} is not a DoIP logical address')
	}
	return put(doip.ra_code_hint(c, u16(tester)), buf, cap)
}

// run_row is row `r`'s name and carrier as the run has it; BB_ERR_STATE before bb_start, since
// before it a hosted entity's row names the project's port and not the run's (under bb_mu: these
// calls may come from any thread).
fn run_row(what string, r i32) !(string, udsconn.Carrier) {
	bb_mu.lock()
	live := bb_dbs_live
	rows := bb_run_rows
	bb_mu.unlock()
	if !live {
		return error_with_code('${what}: not started — a row\'s endpoint is the run\'s, from bb_start until bb_stop',
			int(bb_err_state))
	}
	if r < 0 || int(r) >= rows.len {
		return error('${what}: no channel ${r}')
	}
	return rows[int(r)].name, udsconn.carrier_of(rows[int(r)])
}

// failed_with is a call's failure by the code its error carries (BB_ERR when none).
fn failed_with(err IError) i32 {
	return fail(if err.code() < 0 { i32(err.code()) } else { bb_err }, err.msg())
}

// announcement_out fills a bb_doip_announcement.
fn announcement_out(out &C.bb_doip_announcement, v doip.VehicleInfo, source string) {
	unsafe {
		vmemset(out, 0, int(sizeof(C.bb_doip_announcement)))
		vin := v.vin_text()
		vmemcpy(&out.vin[0], vin.str, if vin.len < 17 { vin.len } else { 17 })
		out.logical_address = v.logical_address
		for i in 0 .. 6 {
			out.eid[i] = if i < v.eid.len { v.eid[i] } else { u8(0) }
			out.gid[i] = if i < v.gid.len { v.gid[i] } else { u8(0) }
		}
		max := int(C.BB_DOIP_SOURCE_MAX) - 1
		vmemcpy(&out.source[0], source.str, if source.len < max { source.len } else { max })
	}
}

// bb_doip_endpoint: DoIP row `r`'s endpoint as the run has it — host into the buffer (put's
// convention), port into *port.
@[export: 'bb_doip_endpoint']
pub fn bb_doip_endpoint(r i32, host &char, cap i32, port &i32) i32 {
	name, car := run_row('endpoint', r) or { return failed_with(err) }
	if !car.doip {
		return fail(bb_err, 'endpoint: "${name}" is not a DoIP channel')
	}
	if !isnil(port) {
		unsafe {
			*port = i32(car.port)
		}
	}
	return put(car.host, host, cap)
}

// bb_doip_discover: the entity at host:port asked who it is (doip.discover_from, the Lua
// doip.discover's exchange).
@[export: 'bb_doip_discover']
pub fn bb_doip_discover(host &char, port i32, timeout_ms i32, out &C.bb_doip_announcement) i32 {
	if isnil(host) || isnil(out) {
		return fail(bb_err, 'discover: no host, or nowhere to put the answer')
	}
	if port < 0 || port > 0xFFFF {
		return fail(bb_err, 'discover: ${port} is not a port')
	}
	if timeout_ms < 0 {
		return fail(bb_err, 'discover: a wait of ${timeout_ms} ms')
	}
	h := unsafe { cstring_to_vstring(host) }
	where := if h.contains(':') && !h.starts_with('[') { '[${h}]:${port}' } else { '${h}:${port}' }
	a := doip.discover_from(h, int(port), int(timeout_ms)) or {
		if err.code() == net.err_timed_out_code {
			return fail(bb_err_timeout, 'discover: no answer from ${where} within ${timeout_ms} ms')
		}
		return fail(bb_err, 'discover on ${where}: ${err}')
	}
	announcement_out(out, a.info, a.from)
	return ok()
}

// bb_doip_listener: where to listen for DoIP row `r`'s announcements, the port asked for (0: the
// row's) and the family (udsconn.doip_listener, the Lua doip.listen's rule).
@[export: 'bb_doip_listener']
pub fn bb_doip_listener(r i32, port i32, ip6 i32, use_port &i32, use_ip6 &i32) i32 {
	if isnil(use_port) || isnil(use_ip6) {
		return fail(bb_err, 'listener: nowhere to put the answer')
	}
	name, car := run_row('listener', r) or { return failed_with(err) }
	p, v6 := udsconn.doip_listener(int(port), ip6 != 0, name, ?udsconn.Carrier(car)) or {
		return fail(bb_err, 'listen: ${err}')
	}
	unsafe {
		*use_port = i32(p)
		*use_ip6 = i32(v6)
	}
	return ok()
}

// bb_doip_listen: the announcements heard for window_ms on `port` (0: 13400), over IPv6 when ip6
// (doip.collect_announcements_af).
@[export: 'bb_doip_listen']
pub fn bb_doip_listen(port i32, window_ms i32, ip6 i32, out &C.bb_doip_announcement, cap i32) i32 {
	if port < 0 || port > 0xFFFF {
		return fail(bb_err, 'listen: ${port} is not a port')
	}
	if window_ms < 0 {
		return fail(bb_err, 'listen: a window of ${window_ms} ms')
	}
	if cap < 0 || (cap > 0 && isnil(out)) {
		return fail(bb_err, 'listen: an array of ${cap} announcements${if isnil(out) { ', and none given' } else { '' }}')
	}
	use_port, use_ip6 := udsconn.doip_listener(int(port), ip6 != 0, '', none) or {
		return fail(bb_err, 'listen: ${err}')
	}
	found := doip.collect_announcements_af(use_port, int(window_ms), use_ip6) or {
		return fail(bb_err, 'listen(${use_port}): ${err}')
	}
	for i, f in found {
		if i >= int(cap) {
			break
		}
		announcement_out(unsafe { &out[i] }, f.info, f.from)
	}
	ok()
	return i32(found.len)
}
