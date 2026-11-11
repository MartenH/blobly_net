module j1939

import time
import blobly.transport

// prop_cfg is a 16-byte PDU1 group 0xEF00 from 0x21 to 0x00, as dbc/j1939_demo.dbc's PropA_Cfg.
fn prop_cfg() transport.CanFrame {
	return transport.CanFrame{
		id:       compose(6, 0xEF00, 0x00, 0x21)
		extended: true
		data:     []u8{len: 16, init: u8(index + 1)}
	}
}

// exchange runs an originator and a responder against each other at `t`, a frame each way per
// step, a listener beside them rejoining what goes past; what the originator ended with.
fn exchange(mut o Originator, mut r Responder, mut lis Reassembler, mut done []Assembled) ConnOut {
	mut t := 0.0
	mut out := o.start(t)
	for _ in 0 .. 100 {
		t += 1
		mut answers := []transport.CanFrame{}
		for f in out.frames {
			done << lis.feed(f, t).done
			answers << r.feed(f, t)
		}
		if out.end != .open {
			return out
		}
		out = ConnOut{}
		for a in answers {
			lis.feed(a, t)
			step := o.feed(a, t)
			out.frames << step.frames
			if step.end != .open {
				out.end = step.end
				out.detail = step.detail
			}
		}
	}
	return out
}

fn test_an_originator_and_a_responder_carry_a_message_whole() {
	mut o := connection_for(prop_cfg(), '', 0)!
	assert o.packets() == 3 && o.answer_ms == conn_t3_ms
	mut r := Responder{
		addresses: [u8(0x00)]
	}
	mut lis := Reassembler{}
	mut done := []Assembled{}
	out := exchange(mut o, mut r, mut lis, mut done)
	assert out.end == .done, out.detail
	assert done.len == 1 && !done[0].bam && done[0].pgn == 0xEF00 && done[0].sa == 0x21
	assert done[0].da == 0x00 && done[0].data == prop_cfg().data
	assert r.open() == 0 && !o.open()
}

// The RTS, every packet and the answers are classic eight-byte frames at priority 7 between the
// two addresses.
fn test_the_frames_of_a_connection() {
	mut o := connection_for(prop_cfg(), '', 0)!
	rts := o.start(0).frames
	assert rts.len == 1 && rts[0].data == [cm_rts, 16, 0, 3, conn_per_cts, 0x00, 0xEF, 0x00]
	assert rts[0].id == compose(7, pgn_tp_cm, 0x00, 0x21) && rts[0].format_stated
	mut r := Responder{
		addresses: [u8(0x00)]
	}
	cts := r.feed(rts[0], 0)
	assert cts.len == 1 && cts[0].data == [cm_cts, 3, 1, 0xFF, 0xFF, 0x00, 0xEF, 0x00]
	assert cts[0].id == compose(7, pgn_tp_cm, 0x21, 0x00)
	packets := o.feed(cts[0], 1).frames
	assert packets.len == 3 && packets[2].data == [u8(3), 15, 16, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
	assert r.feed(packets[0], 2).len == 0 && r.feed(packets[1], 2).len == 0
	ack := r.feed(packets[2], 2)
	assert ack.len == 1 && ack[0].data == [cm_eom_ack, 16, 0, 3, 0xFF, 0x00, 0xEF, 0x00]
	assert o.feed(ack[0], 3).end == .done
}

// A receiver that clears two packets at a time and holds in between: each CTS sends what it
// clears, a hold sends nothing and waits T4 for the next.
fn test_windows_and_a_hold() {
	mut o := connection_for(prop_cfg(), '', 0)!
	o.start(0)
	cts := fn (count u8, next u8) transport.CanFrame {
		return control_frame(0x00, 0x21, [cm_cts, count, next, 0xFF, 0xFF, 0x00, 0xEF, 0x00])
	}
	first := o.feed(cts(2, 1), 10)
	assert first.frames.map(it.data[0]) == [u8(1), 2]
	assert o.feed(cts(0, 0xFF), 20).frames.len == 0
	assert o.poll(20 + conn_t4_ms).end == .open
	// a CTS asking again for a packet already sent sends it again
	assert o.feed(cts(1, 2), 25).frames.map(it.data[0]) == [u8(2)]
	rest := o.feed(cts(2, 3), 30)
	assert rest.frames.map(it.data[0]) == [u8(3)]
	gone := o.poll(30 + conn_t3_ms + 1)
	assert gone.end == .timeout && gone.detail.contains('acknowledgement')
	assert gone.frames.len == 1 && gone.frames[0].data[..3] == [cm_abort, 3, 0xFC]
}

fn test_a_hold_not_renewed_times_out_after_t4() {
	mut o := connection_for(prop_cfg(), '', 0)!
	o.start(0)
	o.feed(control_frame(0x00, 0x21, [cm_cts, 0, 0xFF, 0xFF, 0xFF, 0x00, 0xEF, 0x00]), 100)
	out := o.poll(100 + conn_t4_ms + 1)
	assert out.end == .timeout && out.detail.contains('no CTS from 0x00')
}

fn test_no_cts_times_out_and_aborts() {
	mut o := connection_for(prop_cfg(), '', 300)!
	o.start(0)
	assert o.poll(300).end == .open
	out := o.poll(301)
	assert out.end == .timeout
	assert out.frames.len == 1 && out.frames[0].data == [cm_abort, 3, 0xFC, 0xFF, 0xFF, 0x00, 0xEF,
		0x00]
	assert out.frames[0].id == compose(7, pgn_tp_cm, 0x00, 0x21)
	assert o.poll(1000).frames.len == 0, 'once'
}

// An abort from the destination ends the connection with its reason; frames of other pairs,
// groups or roles change nothing.
fn test_an_abort_from_the_peer_is_reported() {
	mut o := connection_for(prop_cfg(), '', 0)!
	o.start(0)
	assert o.feed(control_frame(0x05, 0x21, [cm_abort, 1, 0xFD, 0xFF, 0xFF, 0x00, 0xEF, 0x00]), 1).end == .open
	assert o.feed(control_frame(0x00, 0x21, [cm_abort, 1, 0xFD, 0xFF, 0xFF, 0x00, 0xEE, 0x00]), 1).end == .open
	assert o.feed(control_frame(0x00, 0x21, [cm_abort, 1, 0xFC, 0xFF, 0xFF, 0x00, 0xEF, 0x00]), 1).end == .open
	out := o.feed(control_frame(0x00, 0x21, [cm_abort, 1, 0xFD, 0xFF, 0xFF, 0x00, 0xEF, 0x00]), 2)
	assert out.end == .aborted && out.detail.contains('aborted by 0x00') && out.detail.contains('reason 1')
	assert out.frames.len == 0
}

fn test_what_cannot_be_a_connection_is_refused() {
	mut f := prop_cfg()
	assert needs_connection(f, true, false)
	assert !needs_connection(f, false, false) && !needs_connection(f, true, true)
	assert !needs_connection(transport.CanFrame{ ...f, data: []u8{len: 8} }, true, false)
	bam := transport.CanFrame{
		...f
		id: compose(6, 0xEF00, 0xFF, 0x21)
	}
	assert !needs_connection(bam, true, false)
	connection_for(bam, '', 0) or { assert err.msg().contains('broadcast') }
	connection_for(transport.CanFrame{ ...f, id: compose(6, 0xEF00, 0xFE, 0x21) }, '', 0) or {
		assert err.msg().contains('two node addresses')
		return
	}
	assert false
}

// A responder answers only an RTS to its address; a gap aborts (reason 7), a repeat (reason 8),
// a mis-sized packet or an announcement it does not answer (reason 250), a stall (reason 3); a window the RTS limits takes one CTS per window.
fn test_a_responder_answers_its_address_and_gives_up_on_a_stall() {
	mut o := connection_for(prop_cfg(), '', 0)!
	rts := o.start(0).frames[0]
	mut other := Responder{
		addresses: [u8(0x05)]
	}
	assert other.feed(rts, 0).len == 0
	mut r := Responder{
		addresses: [u8(0x00)]
	}
	packets := o.feed(r.feed(rts, 0)[0], 1).frames
	gap := r.feed(packets[1], 2)
	assert gap.len == 1 && gap[0].data[..3] == [cm_abort, 7, 0xFD] && r.open() == 0
	// a packet already in aborts too (reason 8), as the listener beside it drops the transfer
	r.feed(rts, 5)
	r.feed(packets[0], 6)
	dup := r.feed(packets[0], 7)
	assert dup.len == 1 && dup[0].data[..3] == [cm_abort, 8, 0xFD] && r.open() == 0
	// so does a classic packet of another length (reason 250)
	r.feed(rts, 8)
	short := r.feed(transport.CanFrame{ ...packets[0], data: packets[0].data[..5].clone() }, 9)
	assert short.len == 1 && short[0].data[..3] == [cm_abort, 250, 0xFD] && r.open() == 0
	// and an announcement it does not answer: an RTS whose sizes disagree, a BAM to it
	for bad in [[cm_rts, 16, 0, 9, 0xFF, 0x00, 0xEF, 0x00], [cm_bam, 16, 0, 3, 0xFF, 0x00, 0xEF,
		0x00]] {
		r.feed(rts, 9)
		gone := r.feed(transport.CanFrame{ ...rts, data: bad.map(u8(it)) }, 9)
		assert gone.len == 1 && gone[0].data[..3] == [cm_abort, 250, 0xFD] && r.open() == 0
	}
	r.feed(rts, 10)
	r.feed(packets[0], 11)
	assert r.poll(11 + conn_t1_ms).len == 0
	stall := r.poll(11 + conn_t1_ms + 1)
	assert stall.len == 1 && stall[0].data[..3] == [cm_abort, 3, 0xFD]
	assert stall[0].id == compose(7, pgn_tp_cm, 0x21, 0x00)
	// two packets per CTS
	limited := transport.CanFrame{
		...rts
		data: [cm_rts, 16, 0, 3, 2, 0x00, 0xEF, 0x00]
	}
	first := r.feed(limited, 20)
	assert first[0].data[1..3] == [u8(2), 1]
	r.feed(packets[0], 21)
	second := r.feed(packets[1], 21)
	assert second.len == 1 && second[0].data[1..3] == [u8(1), 3]
	assert r.feed(packets[2], 22)[0].data[0] == cm_eom_ack
}

// A connection the listener answers whose transfer its reassembler drops (here, evicted by as many
// broadcasts as it holds sessions) is aborted, not acknowledged.
fn test_a_listener_aborts_a_connection_its_reassembler_dropped() {
	mut l := Listener{}
	l.answer(0x00)!
	mut o := connection_for(prop_cfg(), '', 0)!
	l.feed(o.start(0).frames[0], 0)
	assert l.take_outgoing().map(it.data[0]) == [cm_cts]
	for sa in 0 .. l.tp.max_sessions {
		l.feed(control_frame(u8(0x30 + sa), addr_global, [cm_bam, 16, 0, 3, 0xFF, 0xCA, 0xFE, 0x00]),
			1)
	}
	out := l.take_outgoing()
	assert out.len == 1 && out[0].data[..3] == [cm_abort, 250, 0xFD], out.str()
	assert l.answers.open() == 0
}

// The listener answers for the address it is told, and rejoins the message as ever.
fn test_a_listener_answers_for_its_address() {
	mut l := Listener{}
	l.answer(0x00)!
	l.answer(0xFE) or { assert err.msg().contains('0x00..0xFD') }
	mut o := connection_for(prop_cfg(), '', 0)!
	mut out := o.start(0)
	for t in 1 .. 10 {
		for f in out.frames {
			l.feed(f, t)
		}
		out = ConnOut{}
		for a in l.take_outgoing() {
			s := o.feed(a, t)
			out.frames << s.frames
			out.end = s.end
		}
		if out.end == .done {
			break
		}
	}
	assert out.end == .done
	m := l.next_message() or { panic('no message') }
	assert m.data == prop_cfg().data && !m.bam
	l.answer(-1)!
	assert l.answering() == -1
}

// send_connection carries a message on a bus and returns once it is acknowledged; with nobody
// answering, it ends in a ConnError after its wait.
fn test_send_connection_on_a_bus() {
	mut tx := transport.open('inproc:J1939_CONN')!
	mut peer := transport.open('inproc:J1939_CONN')!
	defer {
		tx.close()
		peer.close()
	}
	ch := chan bool{cap: 1}
	spawn fn (mut peer transport.Bus, ch chan bool) {
		mut l := Listener{}
		l.answer(0x00) or {}
		t0 := time.ticks()
		for time.ticks() - t0 < 2000 {
			f := peer.recv(10) or { continue }
			l.feed(f, f64(time.ticks()))
			for a in l.take_outgoing() {
				peer.send(a) or {}
			}
			if l.queued() > 0 {
				ch <- true
				return
			}
		}
		ch <- false
	}(mut peer, ch)
	send_connection(mut tx, prop_cfg(), 0, unsafe { nil })!
	assert <-ch
	t0 := time.ticks()
	send_connection(mut tx, prop_cfg(), 100, unsafe { nil }) or {
		assert err is ConnError && (err as ConnError).end == .timeout, err.msg()
		assert time.ticks() - t0 >= 100
		return
	}
	assert false, 'nobody answers'
}

// A CTS asking again for a packet that is not the last leaves the originator waiting for a CTS;
// the acknowledgement that follows, once every packet has gone out, still ends it done.
fn test_an_acknowledgement_after_a_retransmission_is_taken() {
	mut o := connection_for(prop_cfg(), '', 0)!
	o.start(0)
	cts := fn (count u8, next u8) transport.CanFrame {
		return control_frame(0x00, 0x21, [cm_cts, count, next, 0xFF, 0xFF, 0x00, 0xEF, 0x00])
	}
	assert o.feed(cts(3, 1), 1).frames.len == 3
	assert o.feed(cts(1, 2), 2).frames.map(it.data[0]) == [u8(2)]
	ack := control_frame(0x00, 0x21, [cm_eom_ack, 16, 0, 3, 0xFF, 0x00, 0xEF, 0x00])
	assert o.feed(ack, 3).end == .done
}

// A CTS asking for a packet past the next unsent is not answered, so the acknowledgement that
// follows it is not taken either.
fn test_a_cts_past_the_next_unsent_packet_is_not_answered() {
	mut o := connection_for(prop_cfg(), '', 0)!
	o.start(0)
	assert o.feed(control_frame(0x00, 0x21, [cm_cts, 1, 3, 0xFF, 0xFF, 0x00, 0xEF, 0x00]), 1).frames.len == 0
	ack := control_frame(0x00, 0x21, [cm_eom_ack, 16, 0, 3, 0xFF, 0x00, 0xEF, 0x00])
	assert o.feed(ack, 2).end == .open
}

// An acknowledgement before every packet has gone out is not this message's.
fn test_an_early_acknowledgement_is_not_taken() {
	mut o := connection_for(prop_cfg(), '', 0)!
	o.start(0)
	o.feed(control_frame(0x00, 0x21, [cm_cts, 2, 1, 0xFF, 0xFF, 0x00, 0xEF, 0x00]), 1)
	ack := control_frame(0x00, 0x21, [cm_eom_ack, 16, 0, 3, 0xFF, 0x00, 0xEF, 0x00])
	assert o.feed(ack, 2).end == .open
}

// The RTS lets a CTS clear conn_per_cts packets, so a responder clears a long message a window
// of that many at a time, and the originator writes no wider one.
fn test_a_window_is_at_most_conn_per_cts() {
	mut o := connection_for(transport.CanFrame{ ...prop_cfg(), data: []u8{len: 100} }, '', 0)!
	mut r := Responder{
		addresses: [u8(0x00)]
	}
	cts := r.feed(o.start(0).frames[0], 0)
	assert cts[0].data[1..3] == [conn_per_cts, 1]
	assert o.feed(cts[0], 1).frames.len == int(conn_per_cts)
	// a CTS asking for more than that is not answered
	mut wide := connection_for(transport.CanFrame{ ...prop_cfg(), data: []u8{len: 100} }, '', 0)!
	wide.start(0)
	assert wide.feed(control_frame(0x00, 0x21, [cm_cts, conn_per_cts + 1, 1, 0xFF, 0xFF, 0x00, 0xEF,
		0x00]), 1).frames.len == 0
}

// A responder whose owner goes away aborts what it answers (reason 250).
fn test_a_responder_stopped_aborts_what_it_answers() {
	mut o := connection_for(prop_cfg(), '', 0)!
	mut r := Responder{
		addresses: [u8(0x00)]
	}
	r.feed(o.start(0).frames[0], 0)
	gone := r.stop()
	assert gone.len == 1 && gone[0].data[..3] == [cm_abort, 250, 0xFD] && r.open() == 0
	assert gone[0].id == compose(7, pgn_tp_cm, 0x21, 0x00)
}

// Answers to the connection that held the lane, sent while this one waited for it, are not
// taken as answers to this one's RTS.
fn test_send_connection_reads_no_answer_meant_for_the_lane_holder() {
	wire := 'inproc:J1939_CONN_LANE'
	mut tx := transport.row_framed(transport.open(wire)!, wire, 'row')
	mut peer := transport.open(wire)!
	defer {
		tx.close()
		peer.close()
	}
	holder := connection_for(prop_cfg(), wire, 0)!
	assert holder.take_lane(time.sys_mono_now())
	ch := chan string{cap: 1}
	spawn fn (mut tx transport.Bus, ch chan string) {
		send_connection(mut tx, prop_cfg(), 100, unsafe { nil }) or {
			ch <- err.msg()
			return
		}
		ch <- 'done'
	}(mut tx, ch)
	time.sleep(20 * time.millisecond)
	// the holder's RTS, the destination's CTS and acknowledgement
	peer.send(control_frame(0x21, 0x00, [cm_rts, 16, 0, 3, 0xFF, 0x00, 0xEF, 0x00]))!
	peer.send(control_frame(0x00, 0x21, [cm_cts, 3, 1, 0xFF, 0xFF, 0x00, 0xEF, 0x00]))!
	peer.send(control_frame(0x00, 0x21, [cm_eom_ack, 16, 0, 3, 0xFF, 0x00, 0xEF, 0x00]))!
	time.sleep(20 * time.millisecond)
	holder.free_lane(time.sys_mono_now())
	got := <-ch
	assert got.contains('no CTS'), got
}

// Spy reads what a handle of its own sees on the wire, for a stop that asks it.
@[heap]
struct Spy {
mut:
	bus    transport.Bus
	frames []transport.CanFrame
}

fn (mut s Spy) drain() {
	for {
		f := s.bus.recv(0) or { return }
		s.frames << f
	}
}

fn (s &Spy) packets() int {
	return s.frames.filter(pgn(it.id) == pgn_tp_dt).len
}

// A stop asked between the packets of a window ends the connection there: no packet after it,
// and the abort (reason 250).
fn test_send_connection_stops_between_packets() {
	wire := 'inproc:J1939_CONN_STOP'
	mut tx := transport.open(wire)!
	mut peer := transport.open(wire)!
	mut spy := &Spy{
		bus: transport.open(wire)!
	}
	defer {
		tx.close()
		peer.close()
		spy.bus.close()
	}
	spawn fn (mut peer transport.Bus) {
		mut r := Responder{
			addresses: [u8(0x00)]
		}
		t0 := time.ticks()
		for time.ticks() - t0 < 2000 {
			f := peer.recv(10) or { continue }
			for a in r.feed(f, f64(time.ticks())) {
				peer.send(a) or {}
			}
			if f.data[0] == cm_abort {
				return
			}
		}
	}(mut peer)
	send_connection(mut tx, prop_cfg(), 0, fn [mut spy] () bool {
		spy.drain()
		return spy.packets() >= 1
	}) or {
		assert err is ConnError && (err as ConnError).end == .stopped, err.msg()
		spy.drain()
		assert spy.packets() == 1
		assert spy.frames.last().data[..3] == [cm_abort, 250, 0xFC]
		return
	}
	assert false, 'stopped'
}

// SlowBus writes each packet `delay_ms` late.
struct SlowBus {
mut:
	inner    transport.Bus
	delay_ms int
}

fn (mut b SlowBus) send(f transport.CanFrame) ! {
	if pgn(f.id) == pgn_tp_dt {
		time.sleep(b.delay_ms * time.millisecond)
	}
	b.inner.send(f)!
}

fn (mut b SlowBus) recv(timeout_ms int) !transport.CanFrame {
	return b.inner.recv(timeout_ms)!
}

fn (mut b SlowBus) close() {
	b.inner.close()
}

fn (mut b SlowBus) health() transport.BusHealth {
	return .unknown
}

fn (mut b SlowBus) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut b SlowBus) reconcile_silence(_ bool) ! {}

fn (mut b SlowBus) error_counters() transport.ErrorCounters {
	return transport.ErrorCounters{}
}

// The wait for the acknowledgement runs from the last packet written, not from the CTS: a window
// written slowly is not timed out.
fn test_send_connection_waits_from_the_last_packet_written() {
	wire := 'inproc:J1939_CONN_SLOW'
	mut tx := transport.Bus(SlowBus{
		inner:    transport.open(wire)!
		delay_ms: 60
	})
	mut peer := transport.open(wire)!
	defer {
		tx.close()
		peer.close()
	}
	spawn fn (mut peer transport.Bus) {
		mut r := Responder{
			addresses: [u8(0x00)]
		}
		t0 := time.ticks()
		for time.ticks() - t0 < 2000 {
			f := peer.recv(10) or { continue }
			for a in r.feed(f, f64(time.ticks())) {
				peer.send(a) or {}
				if a.data[0] == cm_eom_ack {
					return
				}
			}
		}
	}(mut peer)
	send_connection(mut tx, prop_cfg(), 100, unsafe { nil })!
}

// ThiefBus hands the lane of the connection from 0x21 to 0x00 to another sender as it writes the
// first packet.
struct ThiefBus {
mut:
	inner transport.Bus
	wire  string
}

fn (mut b ThiefBus) send(f transport.CanFrame) ! {
	b.inner.send(f)!
	if pgn(f.id) == pgn_tp_dt && f.data[0] == 1 {
		lock tp_lanes {
			tp_lanes.by[conn_lane(b.wire, 0x21, 0x00)] = Lane{
				owner: 0
				until: time.sys_mono_now() + u64(time.second)
			}
		}
	}
}

fn (mut b ThiefBus) recv(timeout_ms int) !transport.CanFrame {
	return b.inner.recv(timeout_ms)!
}

fn (mut b ThiefBus) close() {
	b.inner.close()
}

fn (mut b ThiefBus) health() transport.BusHealth {
	return .unknown
}

fn (mut b ThiefBus) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut b ThiefBus) reconcile_silence(_ bool) ! {}

fn (mut b ThiefBus) error_counters() transport.ErrorCounters {
	return transport.ErrorCounters{}
}

// A connection whose lane another sender takes between its packets sends nothing more.
fn test_send_connection_stops_when_its_lane_is_taken() {
	wire := 'inproc:J1939_CONN_THIEF'
	// row-framed, so the connection knows its wire and so its lane
	mut tx := transport.row_framed(transport.Bus(ThiefBus{
		inner: transport.open(wire)!
		wire:  wire
	}), wire, 'row')
	mut peer := transport.open(wire)!
	mut spy := &Spy{
		bus: transport.open(wire)!
	}
	defer {
		tx.close()
		peer.close()
		spy.bus.close()
	}
	spawn fn (mut peer transport.Bus) {
		mut r := Responder{
			addresses: [u8(0x00)]
		}
		t0 := time.ticks()
		for time.ticks() - t0 < 1000 {
			f := peer.recv(10) or { continue }
			for a in r.feed(f, f64(time.ticks())) {
				peer.send(a) or {}
			}
			if pgn(f.id) == pgn_tp_dt {
				return
			}
		}
	}(mut peer)
	send_connection(mut tx, prop_cfg(), 300, unsafe { nil }) or {
		assert err is ConnError && (err as ConnError).end == .lost, err.msg()
		spy.drain()
		assert spy.packets() == 1 && spy.frames.last().data[0] == 1
		return
	}
	assert false, 'lane taken'
}
