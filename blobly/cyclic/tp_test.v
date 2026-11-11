module cyclic

import time
import blobly.j1939
import blobly.transport

// tp_test.v — a connection a Tp drives, stepped by hand against a j1939.Responder on another
// handle of the same inproc wire.

// conn_frame is a 1785-byte message from 0x23 to 0x33 (PGN 0xEF00), an RTS/CTS connection.
fn conn_frame() transport.CanFrame {
	return transport.CanFrame{
		id:       0x18EF3323
		extended: true
		data:     []u8{len: 1785, init: u8(index)}
	}
}

// answer feeds the responder what `peer` has queued and sends back what it answers.
fn answer(mut peer transport.Bus, mut rsp j1939.Responder) {
	for {
		f := peer.recv(0) or { break }
		for a in rsp.feed(f, f64(time.ticks())) {
			peer.send(a) or {}
		}
	}
}

// heard is the transport frames `peer` has queued.
fn heard(mut peer transport.Bus) []transport.CanFrame {
	mut out := []transport.CanFrame{}
	for {
		f := peer.recv(0) or { break }
		out << f
	}
	return out
}

@[heap]
struct Asks {
mut:
	n int
}

fn is_abort(f transport.CanFrame) bool {
	return j1939.pgn(f.id) == j1939.pgn_tp_cm && f.data[0] == j1939.cm_abort
}

fn test_a_stop_asked_inside_a_window_ends_the_connection_before_its_next_packet() {
	mut bus := transport.open('inproc:TPSTOP')!
	mut peer := transport.open('inproc:TPSTOP')!
	defer {
		bus.close()
		peer.close()
	}
	peer.recv(0) or {}
	mut rsp := j1939.Responder{
		addresses: [u8(0x33)]
	}
	mut asks := &Asks{}
	mut t := Tp{}
	t.stop_by(fn [mut asks] () bool {
		asks.n++
		return asks.n > 1
	})
	assert t.begin(mut bus, conn_frame(), true, now_ms()).going
	answer(mut peer, mut rsp) // the RTS, answered with a CTS
	time.sleep(5 * time.millisecond)
	st := t.pump(mut bus, now_ms())
	assert !st.going
	assert st.why.contains('stopped'), st.why
	got := heard(mut peer)
	dts := got.filter(j1939.pgn(it.id) == j1939.pgn_tp_dt)
	assert dts.len == 1, 'one packet before the stop: ${dts.len}'
	assert got.filter(is_abort(it)).len == 1
	assert !t.busy()
}

fn test_quit_sends_no_abort_once_another_sender_has_its_lane() {
	mut bus := transport.open('inproc:TPQUIT')!
	mut peer := transport.open('inproc:TPQUIT')!
	defer {
		bus.close()
		peer.close()
	}
	peer.recv(0) or {}
	mut t := Tp{}
	assert t.begin(mut bus, conn_frame(), true, now_ms()).going
	assert heard(mut peer).len == 1 // the RTS
	// another sender's connection between the same two addresses, once this one's claim lapsed
	mut other := j1939.connection_for(conn_frame(), 'inproc:TPQUIT', 0)!
	later := time.sys_mono_now() + u64(10 * time.second)
	assert other.take_lane(later)
	defer {
		other.free_lane(later)
	}
	t.quit(mut bus)
	assert !t.busy()
	assert heard(mut peer).filter(is_abort(it)).len == 0
}

fn test_quit_aborts_a_connection_that_still_has_its_lane() {
	mut bus := transport.open('inproc:TPQUIT2')!
	mut peer := transport.open('inproc:TPQUIT2')!
	defer {
		bus.close()
		peer.close()
	}
	peer.recv(0) or {}
	mut t := Tp{}
	assert t.begin(mut bus, conn_frame(), true, now_ms()).going
	assert heard(mut peer).len == 1
	t.quit(mut bus)
	assert heard(mut peer).filter(is_abort(it)).len == 1
}
