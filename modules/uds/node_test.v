module uds

import sync
import time
import transport

// ISO 14229-1: to a FUNCTIONAL request a server keeps quiet instead of refusing with these —
// every ECU on the bus would otherwise answer a broadcast it does not support
fn test_functional_suppression_is_exactly_isos_list() {
	for nrc in [u8(0x11), 0x12, 0x31, 0x7E, 0x7F] {
		assert functional_suppressed([u8(0x7F), 0x22, nrc]), 'NRC 0x${nrc:02X}'
	}
	for nrc in [u8(0x13), 0x22, 0x33, 0x35, 0x78] {
		assert !functional_suppressed([u8(0x7F), 0x22, nrc]), 'NRC 0x${nrc:02X} must still be answered'
	}
	assert !functional_suppressed([u8(0x62), 0xF1, 0x90])
}

fn inproc_opener(bus string) fn () !transport.Bus {
	return fn [bus] () !transport.Bus {
		return transport.open(bus)!
	}
}

fn test_one_functional_listener_serves_every_node_on_a_wire() {
	bus := 'inproc:funclisten_share'
	mut a := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	mut b := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	mut other := functional_join(bus, 0x18DB33F1, true, inproc_opener(bus))!
	assert functional_wires() == 1, 'three nodes on one wire share one subscription'
	mut tx := transport.open(bus)!
	tx.send(transport.CanFrame{ id: 0x7DF, data: [u8(0x02), 0x3E, 0x00, 0, 0, 0, 0, 0] })!
	tx.send(transport.CanFrame{ id: 0x7DF, data: [u8(0x10), 0x14, 0x62, 0, 0, 0, 0, 0] })! // not a Single Frame
	tx.send(transport.CanFrame{ id: 0x7E0, data: [u8(0x02), 0x10, 0x03, 0, 0, 0, 0, 0] })! // physical
	// whichever node polls first drains the wire for both
	assert (b.take() or { []u8{} }) == [u8(0x3E), 0x00]
	assert (a.take() or { []u8{} }) == [u8(0x3E), 0x00]
	assert a.take() == none
	assert other.take() == none, 'a node answering another functional id hears nothing'
	a.leave()
	b.leave()
	assert functional_wires() == 1, 'the wire stays open while a node remains'
	other.leave()
	assert functional_wires() == 0, 'the last node out closes it'
	assert other.take() == none
	tx.close()
}

fn test_a_busy_node_loses_its_oldest_backlog_not_the_wire() {
	bus := 'inproc:funclisten_cap'
	mut busy := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	mut idle := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	mut tx := transport.open(bus)!
	for i in 0 .. func_queue_cap + 3 {
		tx.send(transport.CanFrame{ id: 0x7DF, data: [u8(0x02), 0x22, u8(i), 0, 0, 0, 0, 0] })!
		idle.take() or {}
	}
	first := busy.take() or { []u8{} }
	assert first == [u8(0x22), 3], 'the newest ${func_queue_cap} are kept'
	d := busy.leave()
	assert d.queue_dropped == 3
	idle.leave()
	tx.close()
}

struct OpenCount {
mut:
	n int
}

fn join_in(bus string, mut c OpenCount, mut mu sync.Mutex, out chan string) {
	opener := fn [bus, mut c, mut mu] () !transport.Bus {
		mu.lock()
		c.n++
		mu.unlock()
		time.sleep(20 * time.millisecond) // a slow device: the other joiners arrive meanwhile
		return transport.open(bus)!
	}
	mut s := functional_join(bus, 0x7DF, false, opener) or {
		out <- 'err'
		return
	}
	out <- 'ok'
	time.sleep(50 * time.millisecond)
	s.leave()
}

fn test_joiners_arriving_together_share_one_open() {
	bus := 'inproc:funclisten_race'
	mut c := &OpenCount{}
	mut mu := sync.new_mutex()
	out := chan string{cap: 4}
	for _ in 0 .. 4 {
		spawn join_in(bus, mut c, mut mu, out)
	}
	for _ in 0 .. 4 {
		assert <-out == 'ok'
	}
	assert c.n == 1, 'four nodes starting together opened the wire ${c.n} times'
	time.sleep(150 * time.millisecond)
	assert functional_wires() == 0
}

fn test_a_failed_open_is_shared_and_the_next_join_tries_again() {
	bus := 'inproc:funclisten_fail'
	failing := fn () !transport.Bus {
		return error('adapter gone')
	}
	functional_join(bus, 0x7DF, false, failing) or { assert err.msg() == 'adapter gone' }
	assert functional_wires() == 0, 'a failed open leaves nothing to attach to'
	mut s := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	assert functional_wires() == 1
	s.leave()
}

fn test_a_node_joining_late_does_not_answer_what_came_before_it() {
	bus := 'inproc:funclisten_late'
	mut first := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	mut tx := transport.open(bus)!
	tx.send(transport.CanFrame{ id: 0x7DF, data: [u8(0x02), 0x3E, 0x00, 0, 0, 0, 0, 0] })!
	time.sleep(5 * time.millisecond)
	mut late := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	assert late.take() == none, 'a request sent before the node joined was handed to it'
	assert (first.take() or { []u8{} }) == [u8(0x3E), 0x00]
	late.leave()
	first.leave()
	// and after the last one out, a rejoin opens the wire afresh
	mut again := functional_join(bus, 0x7DF, false, inproc_opener(bus))!
	tx.send(transport.CanFrame{ id: 0x7DF, data: [u8(0x02), 0x3E, 0x80, 0, 0, 0, 0, 0] })!
	time.sleep(5 * time.millisecond)
	assert (again.take() or { []u8{} }) == [u8(0x3E), 0x80]
	again.leave()
	tx.close()
}

// FakeBus fails its receives once `dead` is set, as an unplugged adapter does.
@[heap]
struct FakeBus {
mut:
	q     []transport.CanFrame
	dead  bool
	drops u64
}

fn (mut b FakeBus) send(f transport.CanFrame) ! {}

fn (mut b FakeBus) recv(timeout_ms int) !transport.CanFrame {
	if b.dead {
		return error('adapter gone')
	}
	if b.q.len == 0 {
		return error('timeout')
	}
	f := b.q[0]
	b.q.delete(0)
	return f
}

fn (mut b FakeBus) close() {}

fn (mut b FakeBus) health() transport.BusHealth {
	return .unknown
}

fn (mut b FakeBus) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{
		dropped: b.drops
	}
}

fn (mut b FakeBus) reconcile_silence(want bool) ! {}

struct FakeOpens {
mut:
	buses []&FakeBus
}

fn test_a_failed_receive_reopens_the_wire_for_every_node_on_it() {
	mut opens := &FakeOpens{}
	opener := fn [mut opens] () !transport.Bus {
		mut b := &FakeBus{}
		opens.buses << b
		return b
	}
	mut a := functional_join('inproc:funclisten_reopen', 0x7DF, false, opener)!
	mut b := functional_join('inproc:funclisten_reopen', 0x7DF, false, opener)!
	opens.buses[0].drops = 5
	opens.buses[0].dead = true
	assert a.take() == none // the failure is seen
	assert b.take() == none // and the next poll, by any node, reopens
	assert opens.buses.len == 2, 'the wire was not reopened in place'
	assert functional_wires() == 1
	opens.buses[1].q << transport.CanFrame{
		id:   0x7DF
		data: [u8(0x02), 0x3E, 0x00]
	}
	assert (a.take() or { []u8{} }) == [u8(0x3E), 0x00]
	assert (b.take() or { []u8{} }) == [u8(0x3E), 0x00], 'a node that joined before the failure still hears the wire'
	opens.buses[1].drops = 2
	a.leave()
	last := b.leave()
	wd := last.wire or { panic('the last node out reports the wire') }
	assert wd.dropped == 7, 'the failed generation counted 5 of these'
	assert functional_wires() == 0
}
