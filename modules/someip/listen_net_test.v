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
	cap := collect('', port, 700, '')!
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
	cap := collect('', port, 800, group) or {
		eprintln('skip: no multicast here: ${err}')
		t.wait()
		return
	}
	t.wait()
	assert cap.malformed == 0
	assert cap.messages.len == 1, 'heard ${cap.messages.len} on ${group}:${port}'
	assert cap.messages[0].header.message_id() == 0x01008001
}

// respond_once answers the first request it hears on `port` from that same socket — the shape of
// a node with a static peer, which replies to the endpoint the request came from.
fn respond_once(port int, wait_ms int) {
	mut c := net.listen_udp('127.0.0.1:${port}') or { return }
	defer {
		c.close() or {}
	}
	c.set_read_timeout(wait_ms * time.millisecond)
	mut buf := []u8{len: 2048}
	n, from := c.read(mut buf) or { return }
	req := parse(buf[..n]) or { return }
	c.write_to(from, response_for(req.header, 'ok'.bytes())) or {}
}

fn test_exchange_sends_from_its_port_and_hears_the_answer_there() {
	local := uniq_port(0)
	peer := uniq_port(1)
	t := spawn respond_once(peer, 2000)
	time.sleep(100 * time.millisecond) // the responder binds first
	cap := exchange('', local, '127.0.0.1:${peer}', [rq()], 600)!
	t.wait()
	assert cap.messages.len == 1, 'heard ${cap.messages.len}'
	h := cap.messages[0].header
	assert h.msg_type == mt_response
	assert h.client == 0x00A5 && h.session == 0x0001, 'the answer mirrors the request id'
	assert cap.messages[0].from == '127.0.0.1:${peer}'
	assert cap.messages[0].payload == 'ok'.bytes()
}

// answer_with_noise answers the first request on `port` with, in order: a reply to an older
// session, an event, a correct reply from ANOTHER socket, and finally the correct reply itself.
fn answer_with_noise(port int, wait_ms int) {
	mut c := net.listen_udp('127.0.0.1:${port}') or { return }
	defer {
		c.close() or {}
	}
	mut o := net.listen_udp('127.0.0.1:0') or { return } // any port: it only has to differ
	defer {
		o.close() or {}
	}
	c.set_read_timeout(wait_ms * time.millisecond)
	mut buf := []u8{len: 2048}
	n, from := c.read(mut buf) or { return }
	req := parse(buf[..n]) or { return }
	stale := Header{
		...req.header
		session: req.header.session - 1
	}
	c.write_to(from, response_for(stale, 'stale'.bytes())) or {}
	c.write_to(from, notification(0x0100, 0x8001, 1, [u8(1)])) or {}
	o.write_to(from, response_for(req.header, 'forged'.bytes())) or {}
	c.write_to(from, response_for(req.header, 'real'.bytes())) or {}
}

fn test_call_takes_only_the_peers_answer_to_its_own_session() {
	local := uniq_port(0)
	peer := uniq_port(1)
	t := spawn answer_with_noise(peer, 2000)
	time.sleep(100 * time.millisecond)
	mut cli := RpcClient{
		service:    0x0100
		method:     0x0042
		iface:      1
		client_id:  0x00A5
		timeout_us: 1_000_000
		session:    4
	}
	call(local, '127.0.0.1:${peer}', mut cli, []u8{}, 'a test')!
	t.wait()
	assert cli.state == .done
	assert cli.result.payload == 'real'.bytes()
	assert cli.session == 5, 'the session it used stays burned'
}

// answer_packed answers the first request with ONE datagram packing an event and the response.
fn answer_packed(port int, wait_ms int) {
	mut c := net.listen_udp('127.0.0.1:${port}') or { return }
	defer {
		c.close() or {}
	}
	c.set_read_timeout(wait_ms * time.millisecond)
	mut buf := []u8{len: 2048}
	n, from := c.read(mut buf) or { return }
	req := parse(buf[..n]) or { return }
	mut packed := notification(0x0100, 0x8001, 1, [u8(1)])
	packed << error_for(req.header, rc_not_ok, 'why'.bytes())
	c.write_to(from, packed) or {}
}

fn test_call_finds_its_answer_in_a_packed_datagram_and_keeps_an_error_payload() {
	local := uniq_port(0)
	peer := uniq_port(1)
	t := spawn answer_packed(peer, 2000)
	time.sleep(100 * time.millisecond)
	mut cli := RpcClient{
		service:    0x0100
		method:     0x0042
		iface:      1
		client_id:  0x00A5
		timeout_us: 1_000_000
	}
	call(local, '127.0.0.1:${peer}', mut cli, []u8{}, 'a test')!
	t.wait()
	assert cli.state == .failed && !cli.result.timed_out, 'the packed answer was missed'
	assert cli.result.rc == rc_not_ok
	assert cli.result.payload == 'why'.bytes()
}

fn test_call_honours_a_deadline_shorter_than_one_read() {
	mut cli := RpcClient{
		service:    0x0100
		method:     0x0042
		iface:      1
		timeout_us: 10_000
	}
	sw := time.new_stopwatch()
	call(uniq_port(0), '127.0.0.1:${uniq_port(1)}', mut cli, []u8{}, 'a test')!
	assert cli.result.timed_out
	assert sw.elapsed().milliseconds() < 40, 'a 10 ms deadline took ${sw.elapsed().milliseconds()} ms'
}
