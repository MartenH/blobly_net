module someip

// Golden vector, hand-computed big-endian: NOTIFICATION from service 0x0100,
// event 0x8001 (bit 15 set), interface version 1, 3-byte payload.
//   message id 0x0100_8001 | length 8+3=0x0000000B | request id 0x0000_0000 |
//   proto 0x01 iface 0x01 type 0x02 (NOTIFICATION) code 0x00
const golden_notification = [u8(0x01), 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00,
	0x00, 0x01, 0x01, 0x02, 0x00, 0x11, 0x22, 0x33]

// Golden vector: REQUEST to service 0x0100, method 0x0042 (bit 15 clear),
// client 0x00A5 session 0x0001, interface version 1, 2-byte payload.
//   message id 0x0100_0042 | length 8+2=0x0000000A | request id 0x00A5_0001 |
//   proto 0x01 iface 0x01 type 0x00 (REQUEST) code 0x00
const golden_request = [u8(0x01), 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x0A, 0x00, 0xA5, 0x00, 0x01,
	0x01, 0x01, 0x00, 0x00, 0xCA, 0xFE]

fn test_notification_golden_bytes() {
	msg := notification(0x0100, 0x8001, 1, [u8(0x11), 0x22, 0x33])
	assert msg == golden_notification
}

fn test_request_golden_bytes() {
	msg := request(0x0100, 0x0042, 0x00A5, 0x0001, 1, [u8(0xCA), 0xFE])
	assert msg == golden_request
}

fn test_notification_roundtrip() {
	m := parse(golden_notification)!
	assert m.header.service == 0x0100
	assert m.header.method == 0x8001
	assert is_event(m.header.method)
	assert m.header.message_id() == 0x01008001
	assert m.header.length == 11
	assert m.header.request_id() == 0
	assert m.header.protocol_version == protocol_version
	assert m.header.interface_version == 1
	assert m.header.msg_type == mt_notification
	assert m.header.return_code == rc_ok
	assert m.payload == [u8(0x11), 0x22, 0x33]
	validate(m.header, 0x0100, 1)!
	// re-encode reproduces the golden bytes exactly
	assert encode(m.header, m.payload) == golden_notification
}

fn test_empty_payload_roundtrip() {
	msg := notification(0x0100, 0x8002, 1, [])
	assert msg.len == header_len
	m := parse(msg)!
	assert m.header.length == length_base
	assert m.payload.len == 0
	validate(m.header, 0x0100, 1)!
}

fn test_request_response_echoes_request_id() {
	req := parse(golden_request)!
	validate(req.header, 0x0100, 1)!
	resp := response_for(req.header, [u8(0x07)])
	// golden response, hand-computed: same message id, length 8+1=9, echoed
	// request id 0x00A5_0001, type 0x80 (RESPONSE), return code 0x00.
	assert resp == [u8(0x01), 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x09, 0x00, 0xA5, 0x00, 0x01,
		0x01, 0x01, 0x80, 0x00, 0x07]
	rm := parse(resp)!
	assert rm.header.request_id() == req.header.request_id()
	assert rm.header.msg_type == mt_response
	assert rm.header.return_code == rc_ok
	validate(rm.header, 0x0100, 1)!
}

fn test_error_reply() {
	req := parse(golden_request)!
	er := parse(error_for(req.header, rc_not_ready, []))!
	assert er.header.msg_type == mt_error
	assert er.header.return_code == rc_not_ready
	assert er.header.request_id() == req.header.request_id()
	assert er.header.message_id() == req.header.message_id()
	validate(er.header, 0x0100, 1) or { assert false, 'an ERROR reply is a legal envelope: ${err}' }
}

fn test_short_header_rejected() {
	if _ := parse_header(golden_notification[..header_len - 1]) {
		assert false, 'expected a 15-byte header to be rejected'
	}
}

fn test_length_too_small_rejected() {
	mut msg := []u8{len: header_len}
	copy(mut msg, golden_notification[..header_len])
	msg[7] = 0x07 // length 7 < 8: cannot even cover the header tail
	if _ := parse(msg) {
		assert false, 'expected length < 8 to be rejected'
	}
}

fn test_truncated_datagram_rejected() {
	if _ := parse(golden_notification[..golden_notification.len - 1]) {
		assert false, 'expected a truncated datagram to be rejected'
	}
}

fn test_trailing_bytes_rejected() {
	mut msg := golden_notification.clone()
	msg << u8(0x00)
	if _ := parse(msg) {
		assert false, 'expected trailing bytes past the Length to be rejected'
	}
}

fn test_huge_length_no_overflow() {
	// A hostile Length near 2^32 must ERROR, not wrap any int math (the doip
	// oversized-payload lesson).
	mut msg := golden_notification.clone()
	msg[4] = 0xFF
	msg[5] = 0xFF
	msg[6] = 0xFF
	msg[7] = 0xFF
	if _ := parse(msg) {
		assert false, 'expected length 0xFFFFFFFF to be rejected'
	}
}

fn test_wrong_protocol_version_rejected() {
	mut msg := golden_notification.clone()
	msg[12] = 0x02
	h := parse_header(msg)!
	if _ := check_protocol_version(h) {
		assert false, 'expected protocol version 0x02 to be rejected'
	}
}

fn test_foreign_service_rejected() {
	h := parse_header(golden_notification)!
	if _ := check_service(h, 0x0200) {
		assert false, 'expected a foreign service id to be rejected'
	}
}

fn test_wrong_interface_version_rejected() {
	h := parse_header(golden_notification)!
	if _ := check_interface_version(h, 2) {
		assert false, 'expected interface version mismatch to be rejected'
	}
}

fn test_unknown_message_type_rejected() {
	mut msg := golden_notification.clone()
	msg[14] = 0x40 // not REQUEST/NOTIFICATION/RESPONSE/ERROR
	h := parse_header(msg)!
	if _ := check_message_type(h) {
		assert false, 'expected unknown message type 0x40 to be rejected'
	}
}

fn test_type_id_class_mismatch_rejected() {
	// NOTIFICATION under a method id (bit 15 clear) is illegal...
	mut msg := golden_notification.clone()
	msg[2] = 0x00 // method 0x0001: method class
	if _ := check_message_type(parse_header(msg)!) {
		assert false, 'expected NOTIFICATION with a method-class id to be rejected'
	}
	// ...and REQUEST under an event id (bit 15 set) is illegal too.
	mut req := golden_request.clone()
	req[2] = 0x80 // method 0x8042: event class
	if _ := check_message_type(parse_header(req)!) {
		assert false, 'expected REQUEST with an event-class id to be rejected'
	}
}

fn test_notification_nonzero_request_id_rejected() {
	mut msg := golden_notification.clone()
	msg[11] = 0x01 // session 0x0001
	h := parse_header(msg)!
	if _ := check_fixed_fields(h) {
		assert false, 'expected a notification with nonzero request id to be rejected'
	}
}

fn test_notification_nonzero_return_code_rejected() {
	mut msg := golden_notification.clone()
	msg[15] = rc_not_ok
	h := parse_header(msg)!
	if _ := check_fixed_fields(h) {
		assert false, 'expected a notification with nonzero return code to be rejected'
	}
}

fn test_check_fixed_fields_ignores_responses() {
	// The zero-field rule binds notifications only: a response's nonzero
	// request id must pass untouched.
	resp := parse(response_for(parse(golden_request)!.header, []))!
	check_fixed_fields(resp.header) or {
		assert false, 'check_fixed_fields must not constrain responses: ${err}'
	}
}

fn test_request_with_nonzero_return_code_rejected() {
	buf := request(0x0100, 0x0042, 0x00A5, 0x0001, 1, [u8(0xCA)])
	mut msg := parse(buf) or {
		assert false, '${err}'
		return
	}
	h := Header{
		...msg.header
		return_code: rc_not_ok
	}
	if _ := check_fixed_fields(h) {
		assert false, 'a REQUEST must carry return code ok'
	}
	validate(h, 0x0100, 1) or { return }
	assert false, 'validate must reject it too'
}
