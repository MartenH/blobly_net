// uds.v — bb.h's UDS calls: a client on a CAN or DoIP row, opened by the rule a Lua script's
// uds.open uses (blobly/udsconn), and each call one uds.Client helper, so a host reads decoded
// answers and typed failures and never a UDS payload of its own. Conventions as lib.v's: i32 at
// the boundary, handles in a table under bb_mu, deleted on close, counted while a call is inside.
module main

import sync
import sync.stdatomic
import time
import blobly.doip
import blobly.flash
import blobly.isotp
import blobly.transport
import blobly.uds
import blobly.udsconn

const bb_err_negative = i32(C.BB_ERR_NEGATIVE)
const bb_err_timeout = i32(C.BB_ERR_TIMEOUT)
const bb_err_pending = i32(C.BB_ERR_PENDING)
const bb_err_undecodable = i32(C.BB_ERR_UNDECODABLE)
const bb_err_carrier = i32(C.BB_ERR_CARRIER)
const bb_err_routing = i32(C.BB_ERR_ROUTING)
const bb_err_lost = i32(C.BB_ERR_LOST)
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
	// a flash in progress on the handle (bb_flash_program), and its cancellation (bb_flash_cancel),
	// which ends its waits as `closing` does; both under `fmu`
	flashing bool
	cancel   i64
	fmu      &sync.Mutex = sync.new_mutex()
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
	doip     bool // over the row's DoIP connection; else ISO-TP on CAN ids rx (and ext)
	rx       u32
	ext      bool
		// a DoIP handle's connection (a DoipLink, which keeps the 0x27 rule): where it reconnects
	// (`car`), the logical address its requests go to (`target`: the entity's, or a node behind it
	// that bb_uds_retarget named, kept across a reconnect), whether it is gone (`lost`: the next call
	// that asks the ECU opens another), and what the idle service found (`idle_lost`, said by the
	// next call); `mu` serialises the calls with that service (serve_idle)
	car       udsconn.Carrier
	target    u16
	lost      bool
	idle_lost string
	mu        &sync.Mutex = sync.new_mutex()
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
	return uds_open(r, tx, rx, out, udsconn.Ask{
		what: 'uds'
	})
}

// uds_open opens a UDS handle on row `r`, an omitted id `dflt`'s.
fn uds_open(r i32, tx &i64, rx &i64, out &C.bb_uds_target, dflt udsconn.Ask) i32 {
	// a row's carrier is the run's (a hosted DoIP row listens on the port the run moved it to), and
	// a handle is its run's, which a functional request takes this run's of (bb_run_gen)
	if isnil(bb_run) {
		return fail(bb_err_state, "not started: a UDS connection opens on a row of the run")
	}
	ch := row(r) or { return fail(bb_err, 'no channel ${r}') }
	ask := udsconn.Ask{
		...dflt
		has_tx: !isnil(tx)
		tx:     if isnil(tx) { i64(0) } else { unsafe { *tx } }
		has_rx: !isnil(rx)
		rx:     if isnil(rx) { i64(0) } else { unsafe { *rx } }
	}
	car := udsconn.carrier_of(ch)
	t := udsconn.resolve(ask, ch.name, car) or { return fail(bb_err, err.msg()) }
	bb_mu.lock()
	run := bb_run_gen
	holder := if t.doip { doip_held(run, r) } else { -1 }
	bb_mu.unlock()
	if holder >= 0 {
		return fail(bb_err, 'uds("${ch.name}"): UDS handle ${holder} holds this DoIP channel\'s connection; one tester address holds one connection to its entity (ISO 13400-2) — use that handle, or close it first')
	}
	mut conn := udsconn.open(t, ch.name, ch.iface_with_bitrate(), car, fn (iface string, _ string) !transport.Bus {
		return transport.open(iface)
	}) or { return open_failed(err, t.doip) }
	if mut conn.ch is doip.DoipClient {
		link := link_of(conn.ch, false)
		conn = udsconn.Conn{
			ch:  link
			cli: uds.new_client(link)
		}
	}
	mut hd := &UdsHandle{
		conn:     conn
		run:      run
		row:      r
		row_name: ch.name
		doip:     t.doip
		rx:       t.rx
		ext:      t.ext
		car:      car
		target:   car.ecu
	}
	closing := &hd.closing
	cancel := &hd.cancel
	stop := fn [closing, cancel] () bool {
		return stdatomic.load_i64(closing) != 0 || stdatomic.load_i64(cancel) != 0
	}
	hd.stop = stop
	hd.conn.cli.stop_requested = stop
	if mut hd.conn.ch is isotp.SoftChannel {
		hd.conn.ch.stop_requested = stop
	} else if mut hd.conn.ch is DoipLink {
		hd.conn.ch.c.stop_requested = stop
	}
	last := &hd.last
	has := &hd.has_last
	h := hd
	hd.conn.cli.on_exchange = fn [last, has, h] (x uds.Exchange) {
		unsafe {
			*last = x
			*has = true
		}
		mut hh := unsafe { h }
		hh.seed_heard(x.req, if x.err == '' && !x.negative && !x.malformed { x.resp } else { []u8{} })
	}
	bb_mu.lock()
	u := bb_uds_next
	bb_uds_next++
	bb_uds[u] = hd
	bb_mu.unlock()
	if hd.doip {
		spawn serve_idle(mut hd)
	}
	if !isnil(out) {
		unsafe {
			// a DoIP row's are its logical addresses, as its channel names them
			out.tx = if t.doip { u32(car.tester) } else { t.tx }
			out.rx = if t.doip { u32(car.ecu) } else { t.rx }
			out.ext = u8(t.ext)
		}
	}
	ok()
	return i32(u)
}

// doip_held is the open handle on DoIP row `r` of run `run`, or -1 (under bb_mu).
fn doip_held(run u64, r i32) int {
	for u, hd in bb_uds {
		if hd.doip && hd.run == run && hd.row == r && stdatomic.load_i64(&hd.closing) == 0 {
			return u
		}
	}
	return -1
}

// open_failed answers an open that failed: a routing activation the entity denied with its code;
// any other failure of a DoIP connection the carrier's; a CAN row's (no such bus) a refusal.
fn open_failed(err IError, is_doip bool) i32 {
	cause := if err is uds.ContextError { err.cause } else { err }
	if cause is doip.RoutingDenied {
		rc := fail(bb_err_routing, err.msg())
		C.bb_routing_set(i32(cause.code), i32(cause.tester))
		return rc
	}
	return fail(if is_doip { bb_err_carrier } else { bb_err }, err.msg())
}

// seed_heard marks a security level's seed on a DoIP handle's link when `answer` is the accepted
// positive answer to the seed request `req` (an exchange the client matched, never a stray frame).
fn (mut hd UdsHandle) seed_heard(req []u8, answer []u8) {
	if req.len < 2 || req[0] != 0x27 || req[1] & 1 == 0 || answer.len < 2 || answer[0] != 0x67 {
		return
	}
	if mut hd.conn.ch is DoipLink {
		hd.conn.ch.seeds[seed_key(hd.conn.ch.rx_id, req[1] & 0x7F)] = true
	}
}

// bb_uds_replaces: handle u's connection replaces an earlier one of the host's (a client reopened
// after a stop): a 0x27 key goes only once its level's seed is answered on this one (DoipLink).
// Nothing on a CAN handle.
@[export: 'bb_uds_replaces']
pub fn bb_uds_replaces(u i32) i32 {
	return with_uds(u, fn (mut hd UdsHandle) !i32 {
		if mut hd.conn.ch is DoipLink {
			hd.conn.ch.inherits = true
		}
		return ok()
	})
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
	hd.mu.lock() // the idle service out of the connection; it sees `closing` and ends
	if !hd.lost {
		hd.conn.ch.close()
	}
	hd.mu.unlock()
	return ok()
}

// idle_poll_ms: how often a DoIP handle's idle connection is served — well inside the 500 ms an
// entity gives an alive check (ISO 13400-2).
const idle_poll_ms = 50

// serve_idle answers what a DoIP entity asks of an idle connection (an alive check, which unanswered
// closes it) between the host's calls, until the handle closes: doip.DoipClient.idle, under the
// handle's lock so it never reads inside a call.
fn serve_idle(mut hd UdsHandle) {
	for stdatomic.load_i64(&hd.closing) == 0 {
		time.sleep(idle_poll_ms * time.millisecond)
		// waits out a call in progress, which answers what arrives meanwhile (a blocking lock:
		// V's try_lock is always false on Windows unless built -d windows_7)
		hd.mu.lock()
		if stdatomic.load_i64(&hd.closing) == 0 && !hd.lost && hd.idle_lost == '' {
			if mut hd.conn.ch is DoipLink {
				hd.conn.ch.c.idle() or {
					if err.msg() != doip.stopped_note {
						hd.idle_lost = err.msg()
					}
				}
			}
		}
		hd.mu.unlock()
	}
}

// reconnect opens a lost DoIP handle's connection again, on the same client (its stated sizes,
// its hooks), ended by a close of the handle as its calls are; a connection the idle service found
// gone is said first, as the call's ConnectionLost.
fn (mut hd UdsHandle) reconnect() ! {
	if !hd.doip {
		return
	}
	if hd.idle_lost != '' {
		why := hd.idle_lost
		hd.idle_lost = ''
		hd.mark_lost()
		hd.has_last = false // this call's request never went out
		return uds.CarrierFailed{
			text: why
		}
	}
	if !hd.lost {
		return
	}
	hd.has_last = false // the exchange of the call that lost it is not this call's
	stop := hd.stop
	deadline := time.ticks() + udsconn.doip_open_ms
	car := hd.car
	mut c := doip.open_doip_stoppable(car.host, car.port, car.tester, car.ecu, fn [stop, deadline] () bool {
		return stop() || time.ticks() >= deadline
	}) or {
		if err.msg() == doip.stopped_note && !stop() {
			return uds.CarrierFailed{
				text: 'doip reconnect failed on ${hd.row_name} (${car.host}:${car.port}): no connection with routing activated within ${udsconn.doip_open_ms} ms'
			}
		}
		if err is doip.RoutingDenied {
			return err
		}
		if err.msg() == doip.stopped_note {
			return err
		}
		return uds.CarrierFailed{
			text: 'doip reconnect failed on ${hd.row_name} (${car.host}:${car.port}): ${err}'
		}
	}
	c.stop_requested = stop
	mut link := link_of(c, true)
	link.retarget(hd.target) // the target the host named; a gateway's unlock went with the old connection
	mut cli := uds.new_client(link)
	cli.did_lens = hd.conn.cli.did_lens.clone()
	cli.ext_lens = hd.conn.cli.ext_lens.clone()
	cli.stop_requested = hd.conn.cli.stop_requested
	cli.on_exchange = hd.conn.cli.on_exchange
	cli.carry_timing(hd.conn.cli)
	hd.conn = udsconn.Conn{
		ch:  link
		cli: cli
	}
	hd.lost = false
}

// refuse_before_reopen refuses a request no client would send, when sending it would first open a
// lost connection again; otherwise the client refuses it, and its exchange records the refusal.
fn (hd &UdsHandle) refuse_before_reopen(req []u8, suppressed bool) ! {
	if hd.lost || hd.idle_lost != '' {
		if why := uds.request_refusal(req, suppressed) {
			return error(why)
		}
	}
}

// mark_lost lets a DoIP handle's connection go once it is gone, so the next call opens another.
fn (mut hd UdsHandle) mark_lost() {
	if hd.doip && !hd.lost {
		hd.conn.ch.close()
		hd.lost = true
	}
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
	hd.mu.lock()
	defer {
		hd.mu.unlock()
	}
	// a close while this call waited for the idle service ends it before it starts
	if stdatomic.load_i64(&hd.closing) != 0 {
		return fail(bb_err_handle, 'the UDS handle was closed')
	}
	return call(mut hd) or {
		if uds.failure_of(err) == .lost {
			hd.mark_lost()
		}
		uds_failed(err)
	}
}

// exchange is with_uds for a call that asks the ECU: the bytes an earlier call answered are not
// this one's, whether or not it succeeds; a lost DoIP connection is opened again first.
fn exchange(u i32, call fn (mut hd UdsHandle) !i32) i32 {
	return with_uds(u, fn [call] (mut hd UdsHandle) !i32 {
		hd.forget()
		return call(mut hd)
	})
}

// cli is the handle's client for a call that asks the ECU, its arguments checked: a lost DoIP
// connection opened again first (reconnect).
fn (mut hd UdsHandle) cli() !&uds.Client {
	hd.reconnect()!
	return &hd.conn.cli
}

// uds_failed is bb.h's code for the way a client call failed (uds.failure_of).
fn uds_failed(err IError) i32 {
	if err is flash.Failed {
		return fail(bb_err_flash, err.msg())
	}
	if err is doip.RoutingDenied {
		rc := fail(bb_err_routing, err.msg())
		C.bb_routing_set(i32(err.code), i32(err.tester))
		return rc
	}
	return match uds.failure_of(err) {
		.negative { negative(err) }
		.no_answer { fail(bb_err_timeout, if err is uds.NoAnswer { err.described() } else { err.msg() }) }
		.pending { fail(bb_err_pending, err.msg()) }
		.undecodable { fail(bb_err_undecodable, err.msg()) }
		.carrier { fail(bb_err_carrier, err.msg()) }
		.lost { fail(bb_err_lost, err.msg()) }
		.abandoned { fail(bb_err_handle, 'the UDS handle was closed') }
		// a state refusal of this library's own keeps its code (bb_uds_functional_doip's run check)
		.refused { fail(if err.code() == int(bb_err_state) { bb_err_state } else { bb_err }, err.msg()) }
	}
}

// negative is a negative response's failure, its NRC the thread's for bb_last_nrc.
fn negative(err IError) i32 {
	rc := fail(bb_err_negative, err.msg())
	cause := if err is uds.ContextError { err.cause } else { err }
	if cause is uds.NegativeResponse {
		C.bb_nrc_set(i32(cause.nrc))
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
		hd.refuse_before_reopen(r, false)!
		mut cl := hd.cli()!
		answer := cl.raw(r)!
		return hd.answer(answer, buf, cap)
	})
}

@[export: 'bb_uds_raw_suppressed']
pub fn bb_uds_raw_suppressed(u i32, req &u8, n i32) i32 {
	return exchange(u, fn [req, n] (mut hd UdsHandle) !i32 {
		r := bytes_in('raw_suppressed', req, n)!
		hd.refuse_before_reopen(r, true)!
		mut cl := hd.cli()!
		answered := cl.raw_suppressed(r)!
		ok()
		return if answered { bb_answered } else { bb_ok }
	})
}

@[export: 'bb_uds_session']
pub fn bb_uds_session(u i32, sub i32, buf &u8, cap i32) i32 {
	return exchange(u, fn [sub, buf, cap] (mut hd UdsHandle) !i32 {
		s := sub_arg('session', sub)!
		out_buf(buf, cap)!
		mut cl := hd.cli()!
		return hd.answer(cl.diagnostic_session(s)!, buf, cap)
	})
}

@[export: 'bb_uds_tester_present']
pub fn bb_uds_tester_present(u i32) i32 {
	return exchange(u, fn (mut hd UdsHandle) !i32 {
		mut cl := hd.cli()!
		cl.tester_present()!
		return ok()
	})
}

@[export: 'bb_uds_read_did']
pub fn bb_uds_read_did(u i32, did i32, buf &u8, cap i32) i32 {
	return exchange(u, fn [did, buf, cap] (mut hd UdsHandle) !i32 {
		id := did_arg(did)!
		out_buf(buf, cap)!
		mut cl := hd.cli()!
		return hd.answer(cl.read_data_by_identifier(id)!, buf, cap)
	})
}

@[export: 'bb_uds_write_did']
pub fn bb_uds_write_did(u i32, did i32, data &u8, n i32) i32 {
	return exchange(u, fn [did, data, n] (mut hd UdsHandle) !i32 {
		id := did_arg(did)!
		value := bytes_in('write_did', data, n)!
		mut cl := hd.cli()!
		cl.write_data_by_identifier(id, value)!
		return ok()
	})
}

@[export: 'bb_uds_reset']
pub fn bb_uds_reset(u i32, kind i32, buf &u8, cap i32) i32 {
	return exchange(u, fn [kind, buf, cap] (mut hd UdsHandle) !i32 {
		k := sub_arg('reset kind', kind)!
		out_buf(buf, cap)!
		mut cl := hd.cli()!
		return hd.answer(cl.ecu_reset(k)!, buf, cap)
	})
}

@[export: 'bb_uds_comm_control']
pub fn bb_uds_comm_control(u i32, control i32, comm_type i32) i32 {
	return exchange(u, fn [control, comm_type] (mut hd UdsHandle) !i32 {
		c := sub_arg('control', control)!
		t := byte_arg('communication type', comm_type)!
		mut cl := hd.cli()!
		cl.communication_control(c, t)!
		return ok()
	})
}

@[export: 'bb_uds_dtc_setting']
pub fn bb_uds_dtc_setting(u i32, on i32) i32 {
	return exchange(u, fn [on] (mut hd UdsHandle) !i32 {
		mut cl := hd.cli()!
		cl.control_dtc_setting(on != 0)!
		return ok()
	})
}

@[export: 'bb_uds_clear_dtcs']
pub fn bb_uds_clear_dtcs(u i32, group i32) i32 {
	return exchange(u, fn [group] (mut hd UdsHandle) !i32 {
		if group < 0 || group > 0xFFFFFF {
			return error('DTC group ${group} is not a 24-bit value')
		}
		mut cl := hd.cli()!
		cl.clear_dtc(u32(group))!
		return ok()
	})
}

@[export: 'bb_uds_security_seed']
pub fn bb_uds_security_seed(u i32, level i32, unlocked &u8, buf &u8, cap i32) i32 {
	return exchange(u, fn [level, unlocked, buf, cap] (mut hd UdsHandle) !i32 {
		l := level_arg(level, true)!
		out_buf(buf, cap)!
		mut cl := hd.cli()!
		seed := cl.security_request_seed(l)!
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
		mut cl := hd.cli()! // a key on a reopened connection: the link refuses it
		cl.security_send_key(l, k)!
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
		mut cl := hd.cli()!
		r := cl.dtcs(m)!
		hd.dtcs, hd.avail = r.records, r.availability
		return ok_count(r.records.len)
	})
}

@[export: 'bb_uds_supported_dtcs']
pub fn bb_uds_supported_dtcs(u i32) i32 {
	return exchange(u, fn (mut hd UdsHandle) !i32 {
		mut cl := hd.cli()!
		r := cl.supported_dtcs()!
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
		mut cl := hd.cli()!
		n := cl.dtc_count(m)!
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
		mut cl := hd.cli()!
		hd.snap_ids = cl.snapshot_ids()!
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
		mut cl := hd.cli()!
		hd.snapshot = cl.snapshot(c, r)!
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
		mut cl := hd.cli()!
		hd.extended = cl.extended(c, r)!
		dtc_out(dtc, hd.extended.dtc, 0xFF)
		if !isnil(counters) {
			b := hd.extended.blobly_counters()
			mut has := u8(0)
			for i, number in [u8(0x01), 0x02, 0x03] {
				// a record wider than a u64 has no counter value: its bytes are the record's alone
				rec := hd.extended.find(number) or { continue }
				if rec.data.len <= 8 {
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

// max_answer is the longest answer the handle's carrier brings: an ISO-TP PDU, or a DoIP diagnostic
// message's user data (its payload less the two logical addresses)
fn (hd &UdsHandle) max_answer() int {
	return if hd.doip { int(doip.max_payload_len) - 4 } else { isotp.max_pdu }
}

// the largest a snapshot DID's value and an extended record can be in one answer: the header (59
// sub DTC status, 6 bytes), then a record's number and DID count and the DID (4 more), or the
// record's number (1)
const snapshot_did_overhead = 10
const ext_record_overhead = 7

// bb_uds_did_size states a snapshot DID's size, for one the client cannot learn by reading it.
@[export: 'bb_uds_did_size']
pub fn bb_uds_did_size(u i32, did i32, n i32) i32 {
	return with_uds(u, fn [did, n] (mut hd UdsHandle) !i32 {
		id := did_arg(did)!
		if n < 0 || n > hd.max_answer() - snapshot_did_overhead {
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
		if n < 0 || n > hd.max_answer() - ext_record_overhead {
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
	// its targets are UDS handles of this run's row
	if isnil(bb_run) {
		return fail(bb_err_state, "not started: a functional request goes out on a row of the run")
	}
	ch := row(r) or { return fail(bb_err, 'no channel ${r}') }
	if ch.is_doip() {
		return fail(bb_err, 'functional("${ch.name}"): a DoIP channel — its functional request is bb_uds_functional_doip, on its one handle')
	}
	if ch.is_eth() {
		return fail(bb_err, 'functional("${ch.name}"): a SOME/IP channel — functional addressing is CAN or DoIP only')
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
		if stdatomic.load_i64(&hd.closing) != 0 {
			return fail(bb_err_handle, 'the UDS handle ${u} was closed')
		}
		if hd.run != run {
			return fail(bb_err_state, 'functional("${ch.name}"): handle ${u} was opened in an earlier run')
		}
		if hd.row != r || hd.doip {
			return fail(bb_err, 'functional("${ch.name}"): handle ${u} was opened on "${hd.row_name}"')
		}
		targets << uds.FunctionalTarget{
			client: &hd.conn.cli
			rsp_id: hd.rx
			ext:    hd.ext
		}
	}
	if why := uds.functional_refusal(targets, request) {
		return fail(bb_err, why)
	}
	// what the targets held is an earlier call's from here; and their last exchange is not this
	// request's (uds.functional reports none): the reply says
	for mut h in hds {
		h.forget()
		h.has_last = false
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
	// the request's own taps, opened so a close of a target ends a slow open too
	iface := ch.iface_with_bitrate()
	opener := fn [iface] () !transport.Bus {
		return transport.open(iface)
	}
	mut tap := transport.open_stoppable(opener, any_closing) or { return functional_open_failed(err) }
	defer {
		tap.close()
	}
	mut fch := isotp.Channel(isotp.on_bus(transport.open_stoppable(opener, any_closing) or {
		return functional_open_failed(err)
	}, iface, u32(id), u32(id), u32(id) > 0x7FF) or { return fail(bb_err, 'functional: ${err.msg()}') })
	defer {
		fch.close()
	}
	replies := uds.functional(mut fch, mut tap, targets, request, window_or_default(window_ms)) or {
		return uds_failed(err)
	}
	for i, rep in replies {
		mut hd := hds[i]
		reply_out(mut hd, rep, unsafe { &out[i] })
	}
	return ok()
}

fn window_or_default(window_ms i32) int {
	return if window_ms > 0 { int(window_ms) } else { 1000 }
}

// reply_out is a functional reply into the host's struct, its answer and failure the handle's.
fn reply_out(mut hd UdsHandle, rep uds.FunctionalReply, out &C.bb_functional_reply) {
	hd.data = rep.resp.clone()
	hd.reply_err = rep.err
	unsafe {
		out.outcome = outcome_code(rep.outcome)
		out.nrc = rep.nrc
		out.pended = u8(rep.pended)
		out.answer_len = i32(rep.resp.len)
	}
}

// bb_uds_functional_doip: `req` on handle u's DoIP connection to the functional logical address
// *address (NULL: doip's default, 0xE400), answered by the entity that connection reaches
// (uds.functional_addressed, the Lua uds.functional's on a DoIP channel).
@[export: 'bb_uds_functional_doip']
pub fn bb_uds_functional_doip(u i32, address &i64, req &u8, len i32, window_ms i32, out &C.bb_functional_reply) i32 {
	if isnil(out) {
		return fail(bb_err, 'functional: nowhere to put the reply')
	}
	fa := if isnil(address) { i64(doip.default_functional_address) } else { unsafe { *address } }
	return with_uds(u, fn [fa, req, len, window_ms, out] (mut hd UdsHandle) !i32 {
		if !hd.doip {
			return error('functional("${hd.row_name}"): a CAN channel — its functional request is bb_uds_functional, on a functional CAN id')
		}
		bb_mu.lock()
		live, run := bb_dbs_live, bb_run_gen
		bb_mu.unlock()
		if !live || hd.run != run {
			return error_with_code('functional("${hd.row_name}"): the handle was opened in an earlier run',
				int(bb_err_state))
		}
		if fa < 0 || fa > 0xFFFF {
			return error('functional("${hd.row_name}"): ${fa} is not a DoIP logical address')
		}
		request := bytes_in('functional', req, len)!
		if request.len == 0 {
			return error('empty UDS request') // refused before what the handle holds is let go
		}
		hd.forget()
		hd.reconnect()!
		hd.has_last = false // the reply says, as on CAN
		mut via := uds.AddressedSend(hd.conn.ch as DoipLink)
		rep := uds.functional_addressed(mut hd.conn.cli, mut via, u32(fa), request, window_or_default(window_ms))!
		hd.seed_heard(request, if rep.outcome == .positive { rep.resp } else { []u8{} })
		reply_out(mut hd, rep, out)
		return ok()
	})
}

// functional_open_failed answers an open of a functional request's taps that failed: a close of a
// target that ended it is the handle's.
fn functional_open_failed(err IError) i32 {
	if err.msg() == transport.open_stopped_note {
		return fail(bb_err_handle, 'the UDS handle was closed')
	}
	return fail(bb_err, 'functional: ${err.msg()}')
}

// bb_uds_reply_error: why the handle's reply to the last functional request failed ('' when it
// did not).
@[export: 'bb_uds_reply_error']
pub fn bb_uds_reply_error(u i32, buf &char, cap i32) i32 {
	return with_uds(u, fn [buf, cap] (mut hd UdsHandle) !i32 {
		return put(hd.reply_err, buf, cap)
	})
}
