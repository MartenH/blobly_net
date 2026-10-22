// uds.v — bb.h's UDS calls: a client on a CAN row, opened by the rule a Lua script's uds.open
// uses (blobly/udsconn), and each call one uds.Client helper, so a host reads decoded answers
// and typed failures and never a UDS payload of its own. Conventions as lib.v's: i32 at the
// boundary, handles in a table under bb_mu, deleted on close, counted while a call is inside.
module main

import sync.stdatomic
import time
import blobly.isotp
import blobly.transport
import blobly.uds
import blobly.udsconn

const bb_err_negative = i32(C.BB_ERR_NEGATIVE)
const bb_err_timeout = i32(C.BB_ERR_TIMEOUT)
const bb_err_pending = i32(C.BB_ERR_PENDING)
const bb_err_undecodable = i32(C.BB_ERR_UNDECODABLE)
const bb_err_carrier = i32(C.BB_ERR_CARRIER)
const bb_answered = i32(C.BB_ANSWERED)

// UdsHandle is one UDS client the host opened. Used outside bb_mu, counted (`users`), closed only
// once nobody is inside it; `closing` ends a call in progress — the client and its ISO-TP channel
// both ask it while they wait (uds.Client / isotp.SoftChannel stop_requested).
@[heap]
struct UdsHandle {
mut:
	conn     udsconn.Conn
	users    i64
	closing  i64
	last     uds.Exchange // the last exchange the client put through (on_exchange)
	has_last bool
	data     []u8 // the bytes the last call answered, for bb_uds_data
}

__global (
	bb_uds      map[int]&UdsHandle
	bb_uds_next int
)

@[export: 'bb_uds_open']
pub fn bb_uds_open(r i32, tx &i64, rx &i64, out &C.bb_uds_target) i32 {
	// the run publishes the wires' policy (listen-only, framing): a connection opened before it
	// would transmit on a listen-only row
	if isnil(bb_run) {
		return fail(bb_err_state, "not started: a UDS connection opens on a row of the run, whose wire policy (listen-only, framing) start publishes")
	}
	ch := row(r) or { return fail(bb_err, 'no channel ${r}') }
	if ch.is_doip() {
		return fail(bb_err, 'uds("${ch.name}"): a DoIP channel — UDS over DoIP is not in this library yet; only a CAN row opens')
	}
	ask := udsconn.Ask{
		what:   'uds'
		has_tx: !isnil(tx)
		tx:     if isnil(tx) { i64(0) } else { unsafe { *tx } }
		has_rx: !isnil(rx)
		rx:     if isnil(rx) { i64(0) } else { unsafe { *rx } }
	}
	car := udsconn.carrier_of(ch)
	t := udsconn.resolve(ask, ch.name, car) or { return fail(bb_err, err.msg()) }
	conn := udsconn.open(t, ch.name, ch.iface_with_bitrate(), car, fn (iface string, _ string) !transport.Bus {
		return transport.open(iface)
	}) or { return fail(bb_err, err.msg()) }
	mut hd := &UdsHandle{
		conn: conn
	}
	closing := &hd.closing
	stop := fn [closing] () bool {
		return stdatomic.load_i64(closing) != 0
	}
	hd.conn.cli.stop_requested = stop
	if mut hd.conn.ch is isotp.SoftChannel {
		hd.conn.ch.stop_requested = stop
	}
	last := &hd.last
	has := &hd.has_last
	hd.conn.cli.on_exchange = fn [last, has] (x uds.Exchange) {
		unsafe {
			*last = x
			*has = true
		}
	}
	bb_mu.lock()
	u := bb_uds_next
	bb_uds_next++
	bb_uds[u] = hd
	bb_mu.unlock()
	if !isnil(out) {
		unsafe {
			out.tx = t.tx
			out.rx = t.rx
			out.ext = u8(t.ext)
		}
	}
	ok()
	return i32(u)
}

// bb_uds_close: out of the table at once; closed once the call inside it has left, which its
// `closing` ends within a stop poll (20 ms).
@[export: 'bb_uds_close']
pub fn bb_uds_close(u i32) i32 {
	bb_mu.lock()
	mut hd := bb_uds[int(u)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no open UDS handle ${u}')
	}
	bb_uds.delete(int(u))
	bb_mu.unlock()
	stdatomic.store_i64(&hd.closing, 1)
	for stdatomic.load_i64(&hd.users) > 0 {
		time.sleep(time.millisecond)
	}
	hd.conn.ch.close()
	return ok()
}

fn uds_enter(u i32) ?&UdsHandle {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if mut hd := bb_uds[int(u)] {
		stdatomic.add_i64(&hd.users, 1)
		return hd
	}
	return none
}

// with_uds runs `call` on the open handle `u`, counted in use; a call that failed is answered by
// its kind (uds_failed).
fn with_uds(u i32, call fn (mut hd UdsHandle) !i32) i32 {
	mut hd := uds_enter(u) or { return fail(bb_err_handle, 'no open UDS handle ${u}') }
	defer {
		stdatomic.add_i64(&hd.users, -1)
	}
	if stdatomic.load_i64(&hd.closing) != 0 {
		return fail(bb_err_handle, 'the UDS handle was closed')
	}
	return call(mut hd) or { uds_failed(err) }
}

// exchange is with_uds for a call that asks the ECU: the bytes an earlier call answered are not
// this one's, whether or not it succeeds.
fn exchange(u i32, call fn (mut hd UdsHandle) !i32) i32 {
	return with_uds(u, fn [call] (mut hd UdsHandle) !i32 {
		hd.data = []u8{}
		return call(mut hd)
	})
}

// uds_failed is bb.h's code for the way a client call failed (uds.failure_of).
fn uds_failed(err IError) i32 {
	return match uds.failure_of(err) {
		.negative { negative(err) }
		.no_answer { fail(bb_err_timeout, if err is uds.NoAnswer { err.described() } else { err.msg() }) }
		.pending { fail(bb_err_pending, err.msg()) }
		.undecodable { fail(bb_err_undecodable, err.msg()) }
		.carrier { fail(bb_err_carrier, err.msg()) }
		.abandoned { fail(bb_err_handle, 'the UDS handle was closed') }
		.refused { fail(bb_err, err.msg()) }
	}
}

// negative is a negative response's failure, its NRC the thread's for bb_last_nrc.
fn negative(err IError) i32 {
	rc := fail(bb_err_negative, err.msg())
	if err is uds.NegativeResponse {
		C.bb_nrc_set(i32(err.nrc))
	}
	return rc
}

// bb_last_nrc: the NRC of the calling thread's last call, when it failed with BB_ERR_NEGATIVE. As
// bb_last_error, it changes nothing: a host reads it whatever became of the handle since.
@[export: 'bb_last_nrc']
pub fn bb_last_nrc(nrc &u8) i32 {
	v := C.bb_nrc_get()
	if v < 0 {
		return bb_none
	}
	if !isnil(nrc) {
		unsafe {
			*nrc = u8(v)
		}
	}
	return bb_ok
}

// put_bytes copies `b` into the host's buffer of `cap` bytes and answers its whole length: one
// past cap was cut.
fn put_bytes(b []u8, buf &u8, cap i32) i32 {
	if cap < 0 {
		return fail(bb_err, 'a buffer of ${cap} bytes')
	}
	if cap > 0 && b.len > 0 {
		if isnil(buf) {
			return fail(bb_err, 'no buffer for its ${cap} bytes')
		}
		n := if b.len < int(cap) { b.len } else { int(cap) }
		unsafe { vmemcpy(buf, b.data, n) }
	}
	ok()
	return i32(b.len)
}

// out_buf refuses a buffer bb.h does not allow, before anything is asked of the ECU: refused
// after, a request (a write, a reset) would have been carried out all the same.
fn out_buf(buf &u8, cap i32) ! {
	if cap < 0 || (cap > 0 && isnil(buf)) {
		return error('a buffer of ${cap} bytes${if isnil(buf) { ', and none given' } else { '' }}')
	}
}

// answer holds `b` for bb_uds_data and copies it out.
fn (mut hd UdsHandle) answer(b []u8, buf &u8, cap i32) i32 {
	hd.data = b.clone()
	return put_bytes(b, buf, cap)
}

// bytes_in is `n` bytes the host passed.
fn bytes_in(what string, p &u8, n i32) ![]u8 {
	if n < 0 || (n > 0 && isnil(p)) {
		return error('${what}: ${n} bytes, and no array of them')
	}
	mut out := []u8{len: int(n)}
	if n > 0 {
		unsafe { vmemcpy(out.data, p, int(n)) }
	}
	return out
}

fn byte_arg(what string, v i32) !u8 {
	if v < 0 || v > 0xFF {
		return error('${what} ${v} is not a byte')
	}
	return u8(v)
}

// sub_arg is a sub-function a helper awaits the answer to: one with suppress-positive-response
// (bit 7) set would be carried out and answered with silence, read as no answer at all.
fn sub_arg(what string, v i32) !u8 {
	b := byte_arg(what, v)!
	if b & uds.suppress_positive != 0 {
		return error('${what} 0x${b:02X} has suppress-positive-response set, so no answer would come; send it with raw_suppressed')
	}
	return b
}

// level_arg is a 0x27 sub-function of the parity its step needs: requestSeed odd, sendKey even.
fn level_arg(v i32, seed bool) !u8 {
	l := sub_arg('security level', v)!
	if (l & 1 == 1) != seed {
		return error('security level 0x${l:02X} is ${if seed { 'even: a seed is requested at an odd level' } else { 'odd: a key is sent at an even level (the seed\'s + 1)' }}')
	}
	return l
}

fn did_arg(v i32) !u16 {
	if v < 0 || v > 0xFFFF {
		return error('DID ${v} is not a 16-bit identifier')
	}
	return u16(v)
}

// bb_uds_last: the last exchange the handle put through, whichever call made it.
@[export: 'bb_uds_last']
pub fn bb_uds_last(u i32, out &C.bb_uds_exchange, req &u8, req_cap i32, ans &u8, ans_cap i32) i32 {
	if isnil(out) {
		return fail(bb_err, 'last: nowhere to put it')
	}
	return with_uds(u, fn [out, req, req_cap, ans, ans_cap] (mut hd UdsHandle) !i32 {
		if !hd.has_last {
			ok()
			return bb_none
		}
		x := hd.last
		if put_bytes(x.req, req, req_cap) < 0 || put_bytes(x.resp, ans, ans_cap) < 0 {
			return bb_err
		}
		unsafe {
			out.sent = u8(x.timing.sent)
			out.negative = u8(x.negative)
			out.nrc = if x.negative && x.resp.len == 3 { x.resp[2] } else { u8(0) }
			out.pending = i32(x.timing.pending)
			out.rtt_us = x.timing.rtt_us
			out.pending_us = x.timing.pending_us
			out.request_len = i32(x.req.len)
			out.answer_len = i32(x.resp.len)
		}
		return ok()
	})
}

// bb_uds_data: the bytes the handle's last call answered, again.
@[export: 'bb_uds_data']
pub fn bb_uds_data(u i32, buf &u8, cap i32) i32 {
	return with_uds(u, fn [buf, cap] (mut hd UdsHandle) !i32 {
		return put_bytes(hd.data, buf, cap)
	})
}

@[export: 'bb_uds_raw']
pub fn bb_uds_raw(u i32, req &u8, n i32, buf &u8, cap i32) i32 {
	return exchange(u, fn [req, n, buf, cap] (mut hd UdsHandle) !i32 {
		r := bytes_in('raw', req, n)!
		out_buf(buf, cap)!
		return hd.answer(hd.conn.cli.raw(r)!, buf, cap)
	})
}

@[export: 'bb_uds_raw_suppressed']
pub fn bb_uds_raw_suppressed(u i32, req &u8, n i32) i32 {
	return exchange(u, fn [req, n] (mut hd UdsHandle) !i32 {
		r := bytes_in('raw_suppressed', req, n)!
		answered := hd.conn.cli.raw_suppressed(r)!
		ok()
		return if answered { bb_answered } else { bb_ok }
	})
}

@[export: 'bb_uds_session']
pub fn bb_uds_session(u i32, sub i32, buf &u8, cap i32) i32 {
	return exchange(u, fn [sub, buf, cap] (mut hd UdsHandle) !i32 {
		s := sub_arg('session', sub)!
		out_buf(buf, cap)!
		return hd.answer(hd.conn.cli.diagnostic_session(s)!, buf, cap)
	})
}

@[export: 'bb_uds_tester_present']
pub fn bb_uds_tester_present(u i32) i32 {
	return exchange(u, fn (mut hd UdsHandle) !i32 {
		hd.conn.cli.tester_present()!
		return ok()
	})
}

@[export: 'bb_uds_read_did']
pub fn bb_uds_read_did(u i32, did i32, buf &u8, cap i32) i32 {
	return exchange(u, fn [did, buf, cap] (mut hd UdsHandle) !i32 {
		id := did_arg(did)!
		out_buf(buf, cap)!
		return hd.answer(hd.conn.cli.read_data_by_identifier(id)!, buf, cap)
	})
}

@[export: 'bb_uds_write_did']
pub fn bb_uds_write_did(u i32, did i32, data &u8, n i32) i32 {
	return exchange(u, fn [did, data, n] (mut hd UdsHandle) !i32 {
		id := did_arg(did)!
		value := bytes_in('write_did', data, n)!
		hd.conn.cli.write_data_by_identifier(id, value)!
		return ok()
	})
}

@[export: 'bb_uds_reset']
pub fn bb_uds_reset(u i32, kind i32, buf &u8, cap i32) i32 {
	return exchange(u, fn [kind, buf, cap] (mut hd UdsHandle) !i32 {
		k := sub_arg('reset kind', kind)!
		out_buf(buf, cap)!
		return hd.answer(hd.conn.cli.ecu_reset(k)!, buf, cap)
	})
}

@[export: 'bb_uds_comm_control']
pub fn bb_uds_comm_control(u i32, control i32, comm_type i32) i32 {
	return exchange(u, fn [control, comm_type] (mut hd UdsHandle) !i32 {
		c := sub_arg('control', control)!
		t := byte_arg('communication type', comm_type)!
		hd.conn.cli.communication_control(c, t)!
		return ok()
	})
}

@[export: 'bb_uds_dtc_setting']
pub fn bb_uds_dtc_setting(u i32, on i32) i32 {
	return exchange(u, fn [on] (mut hd UdsHandle) !i32 {
		hd.conn.cli.control_dtc_setting(on != 0)!
		return ok()
	})
}

@[export: 'bb_uds_clear_dtcs']
pub fn bb_uds_clear_dtcs(u i32, group i32) i32 {
	return exchange(u, fn [group] (mut hd UdsHandle) !i32 {
		if group < 0 || group > 0xFFFFFF {
			return error('DTC group ${group} is not a 24-bit value')
		}
		hd.conn.cli.clear_dtc(u32(group))!
		return ok()
	})
}

@[export: 'bb_uds_security_seed']
pub fn bb_uds_security_seed(u i32, level i32, unlocked &u8, buf &u8, cap i32) i32 {
	return exchange(u, fn [level, unlocked, buf, cap] (mut hd UdsHandle) !i32 {
		l := level_arg(level, true)!
		out_buf(buf, cap)!
		seed := hd.conn.cli.security_request_seed(l)!
		if !isnil(unlocked) {
			unsafe {
				*unlocked = u8(uds.already_unlocked(seed))
			}
		}
		return hd.answer(seed, buf, cap)
	})
}

@[export: 'bb_uds_security_key']
pub fn bb_uds_security_key(u i32, level i32, key &u8, n i32) i32 {
	return exchange(u, fn [level, key, n] (mut hd UdsHandle) !i32 {
		l := level_arg(level, false)!
		k := bytes_in('security_key', key, n)!
		hd.conn.cli.security_send_key(l, k)!
		return ok()
	})
}

// bb_reference_key: blobly_net's reference key for a seed (uds.security_key), the key the
// simulated ECUs accept.
@[export: 'bb_reference_key']
pub fn bb_reference_key(seed &u8, n i32, buf &u8, cap i32) i32 {
	s := bytes_in('reference_key', seed, n) or { return fail(bb_err, err.msg()) }
	return put_bytes(uds.security_key(s), buf, cap)
}

// bb_nrc_name: ISO 14229-1's name for a negative response code.
@[export: 'bb_nrc_name']
pub fn bb_nrc_name(nrc i32, buf &char, cap i32) i32 {
	code := byte_arg('NRC', nrc) or { return fail(bb_err, err.msg()) }
	return put(uds.nrc_name(code), buf, cap)
}
