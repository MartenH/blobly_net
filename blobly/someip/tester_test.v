module someip

import net
import time
import blobly.testports

fn test_a_session_goes_out_once_per_run() {
	mut s := Sessions{}
	assert s.take(0)! == 1
	assert s.take(3)! == 3
	assert s.take(0)! == 2
	assert s.take(0)! == 4, 'an explicit session is skipped by the automatic ones'
	if _ := s.take(3) {
		assert false, 'a session sent twice'
	}
}

fn test_what_a_message_leaves_unstated_takes_its_default() {
	mut s := Sessions{}
	req := parse(s.encode_out(Outgoing{ service: 0x100, method: 0x1, payload: [u8(9)] })!)!
	assert req.header.msg_type == mt_request
	assert req.header.client == default_client && req.header.session == 1
	assert req.header.interface_version == 1 && req.payload == [u8(9)]
	ev := parse(s.encode_out(Outgoing{ service: 0x100, method: 0x8001 })!)!
	assert ev.header.msg_type == mt_notification && ev.header.request_id() == 0
	own := parse(s.encode_out(Outgoing{
		service:  0x100
		method:   0x1
		msg_type: mt_notification
		iface:    3
		client:   7
		session:  9
	})!)!
	assert own.header.client == 7 && own.header.session == 9 && own.header.interface_version == 3
	assert s.take(9)! == 9, 'a notification reserves no session'
	if _ := s.encode_out(Outgoing{ service: 1, method: 1, msg_type: mt_response }) {
		assert false, 'a response sent'
	}
}

fn test_a_destination_is_an_ipv4_host_and_port() {
	check_to('127.0.0.1:30490')!
	check_to('node.local:1')!
	for bad in ['127.0.0.1', '[::1]:30490', '::1:30490', ':30490', '127.0.0.1:', '127.0.0.1:x', 'h:70000'] {
		if _ := check_to(bad) {
			assert false, bad
		}
	}
}

fn test_a_call_refuses_what_no_request_can_be() {
	mut s := Sessions{}
	for m in [Outgoing{
		service: 1
		method:  0x8001
	}, Outgoing{
		service: 1
		method:  1
		client:  0
	}, Outgoing{
		service:  1
		method:   1
		msg_type: mt_notification
	}] {
		if _ := s.call_once(30491, '127.0.0.1:1', m, 10, 'a test') {
			assert false, '${m}'
		}
	}
	if _ := s.call_once(0, '127.0.0.1:1', Outgoing{ service: 1, method: 1 }, 10, 'a test') {
		assert false, 'port 0'
	}
}

// echo_once answers one request on `port` with a RESPONSE carrying its payload reversed.
fn echo_once(port int) {
	mut c := net.listen_udp('127.0.0.1:${port}') or { return }
	defer {
		c.close() or {}
	}
	c.set_read_timeout(2 * time.second)
	mut buf := []u8{len: 2048}
	n, from := c.read(mut buf) or { return }
	req := parse(buf[..n]) or { return }
	c.write_to(from, response_for(req.header, req.payload.reverse())) or {}
}

fn test_a_call_answers_with_the_mirrored_response_or_times_out() {
	local := testports.someip.slot(2, 0)
	peer := testports.someip.slot(2, 1)
	t := spawn echo_once(peer)
	time.sleep(100 * time.millisecond)
	mut s := Sessions{}
	a := s.call_once(local, '127.0.0.1:${peer}', Outgoing{
		service: 0x100
		method:  0x1
		payload: [u8(1), 2]
	}, 1000, 'a test')!
	t.wait()
	assert !a.timed_out
	assert a.header.msg_type == mt_response && a.header.session == 1
	assert a.header.client == default_client && a.payload == [u8(2), 1]
	none_ := s.call_once(local, '127.0.0.1:${peer}', Outgoing{ service: 0x100, method: 0x1 }, 50,
		'a test')!
	assert none_.timed_out && none_.header.session == 2
}
