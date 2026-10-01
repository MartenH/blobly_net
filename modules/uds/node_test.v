module uds

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
	assert d.dropped == 3
	idle.leave()
	tx.close()
}
