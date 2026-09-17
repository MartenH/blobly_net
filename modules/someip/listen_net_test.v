module someip

import net
import testports
import time

// The two golden messages, built by the module's own builders (each _test.v compiles alone,
// so someip_test.v's byte literals are not visible here; the builders are pinned there).
fn ev() []u8 {
	return notification(0x0100, 0x8001, 1, [u8(0x11), 0x22, 0x33])
}

fn rq() []u8 {
	return request(0x0100, 0x0042, 0x00A5, 0x0001, 1, [u8(0xCA), 0xFE])
}

// collect over REAL sockets: unicast to the bound port, and a multicast group joined on it —
// the two ways a service's events reach a listener that never asked.

// This process's block in the someip band (see rpc_client_net_test.v for why it is predicted,
// not verified: a UDP bind proves nothing under SO_REUSEADDR).
fn uniq_port(slot int) int {
	return testports.someip.slot(2, slot)
}

// send_after writes the datagrams to `to` once the listener has had time to bind. The
// listener blocks the calling thread for its window, so the sender is the other thread.
fn send_after(to string, delay time.Duration, datagrams [][]u8) {
	time.sleep(delay)
	mut s := net.dial_udp(to) or { return }
	defer {
		s.close() or {}
	}
	if to.starts_with('239.') {
		// same host: we must hear our own send
		s.set_multicast_loop(true) or { return }
	}
	for d in datagrams {
		s.write(d) or { return }
	}
}

fn test_collect_hears_unicast_and_counts_the_malformed() {
	port := uniq_port(0)
	mut packed := ev().clone()
	packed << rq()
	t := 

	// a header fragment: a malformed datagram, counted
	spawn send_after('127.0.0.1:${port}', 150 * time.millisecond, [
		ev(),
		packed,
		ev()[..10],
	])
	cap := collect(port, 700, '')!
	t.wait()
	assert cap.malformed == 1
	assert cap.messages.len == 3, 'heard ${cap.messages.len}'
	assert cap.messages[0].header.msg_type == mt_notification
	assert cap.messages[1].header.msg_type == mt_notification
	assert cap.messages[2].header.msg_type == mt_request
	assert cap.messages[2].payload == [u8(0xCA), 0xFE]
	for m in cap.messages {
		assert m.from.starts_with('127.0.0.1:'), m.from
		assert m.at_ms >= 0 && m.at_ms <= 700
	}
}

fn test_collect_hears_a_multicast_group_it_joined() {
	port := uniq_port(1)
	group := testports.group()
	t := spawn send_after('${group}:${port}', 200 * time.millisecond, [ev()])
	cap := collect(port, 800, group) or {
		eprintln('skip: no multicast here: ${err}')
		t.wait()
		return
	}
	t.wait()
	assert cap.malformed == 0
	assert cap.messages.len == 1, 'heard ${cap.messages.len} on ${group}:${port}'
	assert cap.messages[0].header.message_id() == 0x01008001
}
