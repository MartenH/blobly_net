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
	// asks `closing`: the client's and its channel's stop_requested, put back after a functional
	// request has them ask every target's
	stop     fn () bool = unsafe { nil }
	last     uds.Exchange // the last exchange the client put through (on_exchange)
	has_last bool
	data     []u8 // the bytes the last call answered, for bb_uds_data
	// where the handle reaches its ECU, for a functional request on the same row of the same run
	run      u64
	row      i32
	row_name string
	rx       u32
	ext      bool
	// the last DTC call's decoded answer, for its accessors
	dtcs     []uds.DtcRecord
	avail    u8
	snap_ids []uds.SnapshotId
	snapshot uds.DtcSnapshot
	extended uds.DtcExtended
	// why the handle's last functional reply failed, for bb_uds_reply_error
	reply_err string
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
	bb_mu.lock()
	run := bb_run_gen
	bb_mu.unlock()
	mut hd := &UdsHandle{
		conn:     conn
		run:      run
		row:      r
		row_name: ch.name
		rx:       t.rx
		ext:      t.ext
	}
	closing := &hd.closing
	stop := fn [closing] () bool {
		return stdatomic.load_i64(closing) != 0
	}
	hd.stop = stop
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
		hd.forget()
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

// forget drops what earlier calls answered: a call that asks the ECU replaces it, whether or not it
// succeeds, so no accessor reads an older call's answer as this one's.
fn (mut hd UdsHandle) forget() {
	hd.data = []u8{}
	hd.dtcs = []uds.DtcRecord{}
	hd.avail = 0
	hd.snap_ids = []uds.SnapshotId{}
	hd.snapshot = uds.DtcSnapshot{}
	hd.extended = uds.DtcExtended{}
	hd.reply_err = ''
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
	if seed && l == 0x7F {
		return error('security level 0x7F has no key level to answer it (0x80 is the suppress bit)')
	}
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

// dtc_out fills a bb_dtc.
fn dtc_out(out &C.bb_dtc, rec uds.DtcRecord, avail u8) {
	if isnil(out) {
		return
	}
	unsafe {
		out.code = rec.code
		out.status = rec.status
		out.availability = avail
	}
}

fn dtc_arg(code i32) !u32 {
	if code < 0 || code > 0xFFFFFF {
		return error('DTC ${code} is not a 24-bit code')
	}
	return u32(code)
}

// held is index `i` of a held answer of `n` entries, refused by name past it.
fn held(what string, i i32, n int) !int {
	if i < 0 || int(i) >= n {
		return error('${what} ${i}: the last answer has ${n}')
	}
	return int(i)
}

@[export: 'bb_uds_dtcs']
pub fn bb_uds_dtcs(u i32, mask i32) i32 {
	return exchange(u, fn [mask] (mut hd UdsHandle) !i32 {
		m := byte_arg('status mask', mask)!
		r := hd.conn.cli.dtcs(m)!
		hd.dtcs, hd.avail = r.records, r.availability
		return ok_count(r.records.len)
	})
}

@[export: 'bb_uds_supported_dtcs']
pub fn bb_uds_supported_dtcs(u i32) i32 {
	return exchange(u, fn (mut hd UdsHandle) !i32 {
		r := hd.conn.cli.supported_dtcs()!
		hd.dtcs, hd.avail = r.records, r.availability
		return ok_count(r.records.len)
	})
}

@[export: 'bb_uds_dtc']
pub fn bb_uds_dtc(u i32, i i32, out &C.bb_dtc) i32 {
	return with_uds(u, fn [i, out] (mut hd UdsHandle) !i32 {
		k := held('DTC', i, hd.dtcs.len)!
		dtc_out(out, hd.dtcs[k], hd.avail)
		return ok()
	})
}

@[export: 'bb_uds_dtc_count']
pub fn bb_uds_dtc_count(u i32, mask i32, availability &u8) i32 {
	return exchange(u, fn [mask, availability] (mut hd UdsHandle) !i32 {
		m := byte_arg('status mask', mask)!
		n := hd.conn.cli.dtc_count(m)!
		if !isnil(availability) {
			unsafe {
				*availability = n.availability
			}
		}
		return ok_count(n.count)
	})
}

@[export: 'bb_uds_snapshot_ids']
pub fn bb_uds_snapshot_ids(u i32) i32 {
	return exchange(u, fn (mut hd UdsHandle) !i32 {
		hd.snap_ids = hd.conn.cli.snapshot_ids()!
		return ok_count(hd.snap_ids.len)
	})
}

@[export: 'bb_uds_snapshot_id']
pub fn bb_uds_snapshot_id(u i32, i i32, code &u32, record &u8) i32 {
	return with_uds(u, fn [i, code, record] (mut hd UdsHandle) !i32 {
		k := held('snapshot id', i, hd.snap_ids.len)!
		unsafe {
			if !isnil(code) {
				*code = hd.snap_ids[k].code
			}
			if !isnil(record) {
				*record = hd.snap_ids[k].record
			}
		}
		return ok()
	})
}

@[export: 'bb_uds_snapshot']
pub fn bb_uds_snapshot(u i32, code i32, record i32, dtc &C.bb_dtc) i32 {
	return exchange(u, fn [code, record, dtc] (mut hd UdsHandle) !i32 {
		c := dtc_arg(code)!
		r := byte_arg('snapshot record', record)!
		hd.snapshot = hd.conn.cli.snapshot(c, r)!
		dtc_out(dtc, hd.snapshot.dtc, 0xFF)
		return ok_count(hd.snapshot.records.len)
	})
}

@[export: 'bb_uds_snapshot_record']
pub fn bb_uds_snapshot_record(u i32, r i32, number &u8) i32 {
	return with_uds(u, fn [r, number] (mut hd UdsHandle) !i32 {
		k := held('snapshot record', r, hd.snapshot.records.len)!
		if !isnil(number) {
			unsafe {
				*number = hd.snapshot.records[k].number
			}
		}
		return ok_count(hd.snapshot.records[k].dids.len)
	})
}

@[export: 'bb_uds_snapshot_did']
pub fn bb_uds_snapshot_did(u i32, r i32, d i32, id &u16, buf &u8, cap i32) i32 {
	return with_uds(u, fn [r, d, id, buf, cap] (mut hd UdsHandle) !i32 {
		k := held('snapshot record', r, hd.snapshot.records.len)!
		rec := hd.snapshot.records[k]
		j := held('snapshot DID', d, rec.dids.len)!
		if !isnil(id) {
			unsafe {
				*id = rec.dids[j].id
			}
		}
		return put_bytes(rec.dids[j].data, buf, cap)
	})
}

@[export: 'bb_uds_extended']
pub fn bb_uds_extended(u i32, code i32, record i32, dtc &C.bb_dtc, counters &C.bb_counters) i32 {
	return exchange(u, fn [code, record, dtc, counters] (mut hd UdsHandle) !i32 {
		c := dtc_arg(code)!
		r := byte_arg('extended data record', record)!
		hd.extended = hd.conn.cli.extended(c, r)!
		dtc_out(dtc, hd.extended.dtc, 0xFF)
		if !isnil(counters) {
			b := hd.extended.blobly_counters()
			mut has := u8(0)
			for i, number in [u8(0x01), 0x02, 0x03] {
				if number in b.has {
					has |= u8(1) << i
				}
			}
			unsafe {
				counters.occurrences = b.occurrences
				counters.aging = b.aging
				counters.failed_cycles = b.failed_cycles
				counters.has = has
			}
		}
		return ok_count(hd.extended.records.len)
	})
}

@[export: 'bb_uds_extended_record']
pub fn bb_uds_extended_record(u i32, k i32, number &u8, buf &u8, cap i32) i32 {
	return with_uds(u, fn [k, number, buf, cap] (mut hd UdsHandle) !i32 {
		j := held('extended data record', k, hd.extended.records.len)!
		if !isnil(number) {
			unsafe {
				*number = hd.extended.records[j].number
			}
		}
		return put_bytes(hd.extended.records[j].data, buf, cap)
	})
}

// bb_uds_did_size states a snapshot DID's size, for one the client cannot learn by reading it.
@[export: 'bb_uds_did_size']
pub fn bb_uds_did_size(u i32, did i32, n i32) i32 {
	return with_uds(u, fn [did, n] (mut hd UdsHandle) !i32 {
		id := did_arg(did)!
		if n < 0 || n > isotp.max_pdu {
			return error('did_size: ${n} bytes is not a DID size')
		}
		hd.conn.cli.set_did_size(id, int(n))
		return ok()
	})
}

// bb_uds_ext_record_size states an extended data record's size (blobly_emb's otherwise).
@[export: 'bb_uds_ext_record_size']
pub fn bb_uds_ext_record_size(u i32, record i32, n i32) i32 {
	return with_uds(u, fn [record, n] (mut hd UdsHandle) !i32 {
		r := byte_arg('extended data record', record)!
		if n < 0 || n > isotp.max_pdu {
			return error('ext_record_size: ${n} bytes is not a record size')
		}
		hd.conn.cli.set_ext_record_size(r, int(n))
		return ok()
	})
}

// ok_count is a count as a call's answer.
fn ok_count(n int) i32 {
	ok()
	return i32(n)
}

// bb_dtc_name: a DTC's SAE J2012 display name (U0121-00).
@[export: 'bb_dtc_name']
pub fn bb_dtc_name(code i32, buf &char, cap i32) i32 {
	c := dtc_arg(code) or { return fail(bb_err, err.msg()) }
	return put(uds.dtc_name(c), buf, cap)
}

// bb_dtc_code: a display name ("U0121-00", or "U0121" for failure type 00, either case) as its
// 24-bit code; BB_NONE for a text that is not one.
@[export: 'bb_dtc_code']
pub fn bb_dtc_code(name &char, code &i32) i32 {
	if isnil(name) || isnil(code) {
		return fail(bb_err, 'dtc_code: no name, or nowhere to put its code')
	}
	c := uds.dtc_code(unsafe { cstring_to_vstring(name) }) or {
		ok()
		return bb_none
	}
	unsafe {
		*code = i32(c)
	}
	return ok()
}

// bb_dtc_status_bit: ISO 14229-1's status bit k of the status byte (0 = testFailed .. 7), its
// mask and its name.
@[export: 'bb_dtc_status_bit']
pub fn bb_dtc_status_bit(k i32, mask &u8, buf &char, cap i32) i32 {
	if k < 0 || int(k) >= uds.dtc_status_bits.len {
		return fail(bb_err, 'status bit ${k}: the status byte has bits 0 .. ${uds.dtc_status_bits.len - 1}')
	}
	bit := uds.dtc_status_bits[int(k)]
	if !isnil(mask) {
		unsafe {
			*mask = bit.mask
		}
	}
	return put(bit.name, buf, cap)
}

// outcome_code is bb.h's enum bb_functional_outcome for an outcome, by name.
fn outcome_code(o uds.FunctionalOutcome) i32 {
	return match o {
		.positive { i32(C.BB_FUNCTIONAL_POSITIVE) }
		.negative { i32(C.BB_FUNCTIONAL_NEGATIVE) }
		.silent { i32(C.BB_FUNCTIONAL_SILENT) }
		.pending { i32(C.BB_FUNCTIONAL_PENDING) }
		.failed { i32(C.BB_FUNCTIONAL_FAILED) }
	}
}

// bb_uds_functional: `req` once on row `r`'s functional id `id`, each of the n handles answering
// on its own response id (uds.functional, the Lua uds.functional's): out[i] is handles[i]'s
// reply, its answer that handle's bb_uds_data, a failed reply's reason its bb_uds_reply_error.
@[export: 'bb_uds_functional']
pub fn bb_uds_functional(r i32, id i64, handles &i32, n i32, req &u8, len i32, window_ms i32, out &C.bb_functional_reply) i32 {
	// the run publishes the wires' policy (listen-only, framing): nothing goes out before it
	if isnil(bb_run) {
		return fail(bb_err_state, "not started: a functional request goes out on a row of the run, whose wire policy (listen-only, framing) start publishes")
	}
	ch := row(r) or { return fail(bb_err, 'no channel ${r}') }
	if ch.is_eth() {
		return fail(bb_err, 'functional("${ch.name}"): a DoIP or SOME/IP channel — functional addressing here is CAN only')
	}
	if id < 0 || id > 0x1FFF_FFFF {
		return fail(bb_err, 'functional("${ch.name}"): ${id} is not a CAN identifier')
	}
	// one target at least: its handle is what ties the request to this run's row
	if n < 1 || isnil(handles) || isnil(out) {
		return fail(bb_err, 'functional: ${n} handles, or no arrays of them; a functional request needs a UDS handle to answer it')
	}
	bb_mu.lock()
	run := bb_run_gen
	bb_mu.unlock()
	request := bytes_in('functional', req, len) or { return fail(bb_err, err.msg()) }
	// every target entered, so a close waits for this call; left whatever happens
	mut hds := []&UdsHandle{}
	defer {
		for mut h in hds {
			stdatomic.add_i64(&h.users, -1)
		}
	}
	mut targets := []uds.FunctionalTarget{}
	for i in 0 .. int(n) {
		u := unsafe { handles[i] }
		mut hd := uds_enter(u) or { return fail(bb_err_handle, 'no open UDS handle ${u}') }
		hds << hd
		hd.forget()
		if stdatomic.load_i64(&hd.closing) != 0 {
			return fail(bb_err_handle, 'the UDS handle ${u} was closed')
		}
		if hd.run != run {
			return fail(bb_err_state, 'functional("${ch.name}"): handle ${u} was opened in an earlier run')
		}
		if hd.row != r {
			return fail(bb_err, 'functional("${ch.name}"): handle ${u} was opened on "${hd.row_name}"')
		}
		targets << uds.FunctionalTarget{
			client: &hd.conn.cli
			rsp_id: hd.rx
			ext:    hd.ext
		}
	}
	// a close of any target ends the request, whichever target's transfer is in progress then: each
	// client and its channel ask every target's closing for the call, their own again after
	mut flags := []&i64{}
	for h in hds {
		flags << &h.closing
	}
	any_closing := fn [flags] () bool {
		return flags.any(stdatomic.load_i64(it) != 0)
	}
	for mut h in hds {
		h.conn.cli.stop_requested = any_closing
		if mut h.conn.ch is isotp.SoftChannel {
			h.conn.ch.stop_requested = any_closing
		}
	}
	defer {
		for mut h in hds {
			h.conn.cli.stop_requested = h.stop
			if mut h.conn.ch is isotp.SoftChannel {
				h.conn.ch.stop_requested = h.stop
			}
		}
	}
	iface := ch.iface_with_bitrate()
	mut tap := transport.open(iface) or { return fail(bb_err, 'functional: ${err.msg()}') }
	defer {
		tap.close()
	}
	mut fch := isotp.Channel(isotp.on_bus(transport.open(iface) or {
		return fail(bb_err, 'functional: ${err.msg()}')
	}, iface, u32(id), u32(id), u32(id) > 0x7FF) or { return fail(bb_err, 'functional: ${err.msg()}') })
	defer {
		fch.close()
	}
	replies := uds.functional(mut fch, mut tap, targets, request, if window_ms > 0 {
		int(window_ms)
	} else {
		1000
	}) or { return uds_failed(err) }
	for i, rep in replies {
		mut hd := hds[i]
		hd.data = rep.resp.clone()
		hd.reply_err = rep.err
		unsafe {
			out[i].outcome = outcome_code(rep.outcome)
			out[i].nrc = rep.nrc
			out[i].pended = u8(rep.pended)
			out[i].answer_len = i32(rep.resp.len)
		}
	}
	return ok()
}

// bb_uds_reply_error: why the handle's reply to the last functional request failed ('' when it
// did not).
@[export: 'bb_uds_reply_error']
pub fn bb_uds_reply_error(u i32, buf &char, cap i32) i32 {
	return with_uds(u, fn [buf, cap] (mut hd UdsHandle) !i32 {
		return put(hd.reply_err, buf, cap)
	})
}
