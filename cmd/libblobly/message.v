// A message of a row's databases encoded, stamped and sent whole (#619): a bb_payload carries a
// message of any length its database gives it up to a J1939 transport-protocol message, and
// bb_message_send puts it on the wire as one frame or, for a J1939 message past eight bytes going
// out classic, as its BAM (j1939.send_message, the rule every send path asks).
module main

import sync.stdatomic
import blobly.j1939
import blobly.project
import blobly.transport

// payload_data is p's bytes, or why p holds none it could carry.
fn payload_data(p &C.bb_payload) ![]u8 {
	n := int(p.len)
	if n > j1939.tp_max_size {
		return error('a payload is at most ${j1939.tp_max_size} bytes, not ${n}')
	}
	mut data := []u8{len: n}
	for i in 0 .. n {
		data[i] = p.data[i]
	}
	return data
}

// put_payload writes `data` into p.
fn put_payload(p &C.bb_payload, data []u8) {
	unsafe {
		p.len = u16(data.len)
		for i in 0 .. j1939.tp_max_size {
			p.data[i] = if i < data.len { data[i] } else { u8(0) }
		}
	}
}

// bb_encode_payload is bb_encode for a message of any length up to BB_J1939_MAX.
@[export: 'bb_encode_payload']
pub fn bb_encode_payload(row i32, m i32, n i32, signals &&char, values &f64, out &C.bb_payload) i32 {
	if isnil(out) {
		return fail(bb_err, 'encode: nowhere to put the payload')
	}
	if n < 0 || (n > 0 && (isnil(signals) || isnil(values))) {
		return fail(bb_err, 'encode: ${n} signals, and no arrays of them')
	}
	msg := message(row, m) or { return refused(err) }
	if msg.payload_len() > j1939.tp_max_size {
		return fail(bb_err, 'encode: ${msg.name} has a DLC of ${msg.dlc}, past what bb_payload carries (${j1939.tp_max_size})')
	}
	data := encode_values(msg, n, signals, values) or { return fail(bb_err, err.msg()) }
	unsafe {
		out.id = msg.id
		out.ext = u8(msg.ext)
		out.format = format_code(project.declared_format(msg)) // what bb_message_send sends it in
	}
	put_payload(out, data)
	return ok()
}

// bb_e2e_stamp_payload is bb_e2e_stamp on a bb_payload.
@[export: 'bb_e2e_stamp_payload']
pub fn bb_e2e_stamp_payload(row i32, m i32, p &C.bb_payload) i32 {
	if isnil(p) {
		return fail(bb_err, 'e2e_stamp: no payload')
	}
	mut data := payload_data(p) or { return fail(bb_err, 'e2e_stamp: ${err.msg()}') }
	stamped := e2e_stamp_data(row, m, mut data) or { return refused(err) }
	if !stamped {
		ok()
		return bb_none
	}
	put_payload(p, data)
	return ok()
}

// bb_message_send sends message m of row `row` (its declaration read from the run's databases) as
// payload p on handle h, the format p states: one frame, or its BAM paced 50 ms apart.
@[export: 'bb_message_send']
pub fn bb_message_send(h i32, row i32, m i32, p &C.bb_payload) i32 {
	if isnil(p) {
		return fail(bb_err, 'send: no payload')
	}
	data := payload_data(p) or { return fail(bb_err, 'send: ${err.msg()}') }
	ff := format_of(int(p.format)) or { return fail(bb_err, 'send: ${err.msg()}') }
	msg := message(row, m) or { return refused(err) }
	frame := j1939.stated(ff, transport.CanFrame{
		id:       p.id
		extended: p.ext != 0
		data:     data
	}, msg.j1939) or { return fail(bb_err, 'send: ${err.msg()}') }
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	// a cancel asked before this send is not this send's
	stdatomic.store_i64(&hd.cancel, 0)
	closing := &hd.closing
	cancel := &hd.cancel
	stop := fn [closing, cancel] () bool {
		return stdatomic.load_i64(closing) != 0 || stdatomic.load_i64(cancel) != 0
	}
	// as the row it is attached to, framed for that row and the wire in one policy read (framing.v)
	mut bus := transport.Bus(hd.bus)
	j1939.send_message(mut bus, transport.CanFrame{ ...frame, row: hd.row }, msg.j1939, stop) or {
		if stdatomic.load_i64(cancel) != 0 {
			return fail(bb_err_cancelled, 'send: cancelled: ${err.msg()}')
		}
		return fail(bb_err, 'send: ${err.msg()}')
	}
	return ok()
}

// bb_message_cancel ends the bb_message_send in progress on handle h between its frames, the rest
// unsent, which then answers BB_ERR_CANCELLED; nothing when none is. From any thread.
@[export: 'bb_message_cancel']
pub fn bb_message_cancel(h i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	stdatomic.store_i64(&hd.cancel, 1)
	hd.leave()
	return ok()
}
