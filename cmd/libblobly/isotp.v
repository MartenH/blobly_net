// isotp.v — bb.h's raw ISO-TP calls: whole messages on a CAN row's request / response id pair
// through the engine's software ISO-TP, the channel a UDS handle rides, opened by blobly/udsconn's
// rule and with no UDS on top. Handles as uds.v's: a table under bb_mu, deleted on close, counted
// while a call is inside, a close ending the wait in progress (the channel's stop_requested).
module main

import sync.stdatomic
import time
import blobly.isotp
import blobly.transport
import blobly.udsconn

@[heap]
struct IsotpHandle {
mut:
	ch      &isotp.SoftChannel
	users   i64
	closing i64
	data    []u8 // the last message received, for bb_isotp_data
}

__global (
	bb_isotp      map[int]&IsotpHandle
	bb_isotp_next int
)

@[export: 'bb_isotp_open']
pub fn bb_isotp_open(r i32, tx i64, rx i64, out &C.bb_uds_target) i32 {
	if isnil(bb_run) {
		return fail(bb_err_state, 'not started: an ISO-TP channel opens on a row of the run')
	}
	ch := row(r) or { return fail(bb_err, 'no channel ${r}') }
	ask := udsconn.Ask{
		what:   'isotp'
		has_tx: true
		tx:     tx
		has_rx: true
		rx:     rx
	}
	t := udsconn.resolve_isotp(ask, ch.name, udsconn.carrier_of(ch)) or { return fail(bb_err, err.msg()) }
	mut c := udsconn.open_isotp(t, ch.name, ch.iface_with_bitrate(), fn (iface string, _ string) !transport.Bus {
		return transport.open(iface)
	}) or { return fail(bb_err, err.msg()) }
	mut hd := &IsotpHandle{
		ch: c
	}
	closing := &hd.closing
	c.stop_requested = fn [closing] () bool {
		return stdatomic.load_i64(closing) != 0
	}
	bb_mu.lock()
	h := bb_isotp_next
	bb_isotp_next++
	bb_isotp[h] = hd
	bb_mu.unlock()
	if !isnil(out) {
		unsafe {
			out.tx = t.tx
			out.rx = t.rx
			out.ext = u8(t.ext)
		}
	}
	ok()
	return i32(h)
}

// with_isotp runs `call` on the open handle `h`, counted in use.
fn with_isotp(h i32, call fn (mut hd IsotpHandle) i32) i32 {
	bb_mu.lock()
	mut hd := bb_isotp[int(h)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no open ISO-TP handle ${h}')
	}
	stdatomic.add_i64(&hd.users, 1)
	bb_mu.unlock()
	defer {
		stdatomic.add_i64(&hd.users, -1)
	}
	if stdatomic.load_i64(&hd.closing) != 0 {
		return fail(bb_err_handle, 'the ISO-TP handle was closed')
	}
	return call(mut hd)
}

// isotp_failed is bb.h's code for the way a send (`sending`) or receive on `hd` failed
// (isotp.SoftChannel.ending_of).
fn isotp_failed(hd &IsotpHandle, err IError, sending bool) i32 {
	return match hd.ch.ending_of(err, sending) {
		.waited_out {
			fail(bb_err_timeout, if sending {
				'ISO-TP send on 0x${hd.ch.tx_id:X}: no Flow Control from the receiver (${err.msg()})'
			} else {
				'ISO-TP receive on 0x${hd.ch.rx_id:X}: no whole message in time (${err.msg()})'
			})
		}
		.refused {
			fail(bb_err, err.msg())
		}
		.abandoned {
			fail(bb_err_handle, 'the ISO-TP handle was closed')
		}
		.failed {
			fail(bb_err_carrier, err.msg())
		}
	}
}

@[export: 'bb_isotp_send']
pub fn bb_isotp_send(h i32, data &u8, n i32) i32 {
	return with_isotp(h, fn [data, n] (mut hd IsotpHandle) i32 {
		msg := bytes_in('isotp send', data, n) or { return fail(bb_err, err.msg()) }
		hd.ch.send(msg) or { return isotp_failed(hd, err, true) }
		return ok()
	})
}

@[export: 'bb_isotp_recv']
pub fn bb_isotp_recv(h i32, timeout_ms i32, buf &u8, cap i32) i32 {
	return with_isotp(h, fn [timeout_ms, buf, cap] (mut hd IsotpHandle) i32 {
		if timeout_ms < 0 {
			return fail(bb_err, 'isotp recv: a wait of ${timeout_ms} ms; 0 looks, more waits')
		}
		out_buf(buf, cap) or { return fail(bb_err, 'isotp recv: ${err}') }
		hd.data = []u8{}
		msg := hd.ch.recv(int(timeout_ms)) or { return isotp_failed(hd, err, false) }
		hd.data = msg
		return put_bytes(msg, buf, cap)
	})
}

@[export: 'bb_isotp_data']
pub fn bb_isotp_data(h i32, buf &u8, cap i32) i32 {
	return with_isotp(h, fn [buf, cap] (mut hd IsotpHandle) i32 {
		return put_bytes(hd.data, buf, cap)
	})
}

// bb_isotp_close: out of the table at once; closed once the call inside it has left, which its
// `closing` ends within a stop poll (20 ms).
@[export: 'bb_isotp_close']
pub fn bb_isotp_close(h i32) i32 {
	bb_mu.lock()
	mut hd := bb_isotp[int(h)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no open ISO-TP handle ${h}')
	}
	bb_isotp.delete(int(h))
	bb_mu.unlock()
	stdatomic.store_i64(&hd.closing, 1)
	for stdatomic.load_i64(&hd.users) > 0 {
		time.sleep(time.millisecond)
	}
	hd.ch.close()
	return ok()
}
