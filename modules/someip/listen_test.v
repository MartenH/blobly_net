module someip

// The two golden messages, built by the module's own builders (each _test.v compiles alone,
// so someip_test.v's byte literals are not visible here; the builders are pinned there).
fn ev() []u8 {
	return notification(0x0100, 0x8001, 1, [u8(0x11), 0x22, 0x33])
}

fn rq() []u8 {
	return request(0x0100, 0x0042, 0x00A5, 0x0001, 1, [u8(0xCA), 0xFE])
}

// split, hermetically: the rule that a datagram is not a message.
fn test_split_one_message_is_itself() {
	msgs, whole := split(ev())
	assert whole
	assert msgs.len == 1
	assert msgs[0].header.message_id() == 0x01008001
	assert msgs[0].payload == [u8(0x11), 0x22, 0x33]
}

fn test_split_two_messages_back_to_back() {
	mut buf := ev().clone()
	buf << rq()
	msgs, whole := split(buf)
	assert whole
	assert msgs.len == 2
	assert msgs[0].header.msg_type == mt_notification
	assert msgs[1].header.msg_type == mt_request
	assert msgs[1].header.request_id() == 0x00A50001
	assert msgs[1].payload == [u8(0xCA), 0xFE]
}

fn test_split_keeps_what_parsed_before_a_truncated_tail() {
	mut buf := ev().clone()
	buf << rq()[..rq().len - 1] // the last payload byte never arrived
	msgs, whole := split(buf)
	assert !whole
	assert msgs.len == 1
	assert msgs[0].header.msg_type == mt_notification
}

fn test_split_refuses_a_length_under_the_minimum() {
	mut buf := ev().clone()
	buf[7] = 0x07 // Length 7 < 8: cannot even cover the request id + version bytes
	msgs, whole := split(buf)
	assert !whole
	assert msgs.len == 0
}

fn test_split_refuses_a_header_fragment() {
	msgs, whole := split(ev()[..10])
	assert !whole
	assert msgs.len == 0
}

fn test_split_empty_datagram_is_whole_and_empty() {
	msgs, whole := split([]u8{})
	assert whole
	assert msgs.len == 0
}
