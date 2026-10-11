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

// A multicast group on a unicast bind is refused by name. The kernel drops group-addressed
// datagrams on a socket bound to one address however well the join succeeded, so the listener
// would sit there green and silent — the one outcome this whole module exists to prevent.
fn test_a_group_on_a_unicast_bind_is_refused() {
	check_group_bind('0.0.0.0', '239.1.2.3')!
	check_group_bind('', '239.1.2.3')!
	check_group_bind('192.168.0.5', '')! // no group, no rule
	if _ := check_group_bind('192.168.0.5', '239.1.2.3') {
		assert false, 'a group on a unicast bind was accepted'
	} else {
		assert err.msg().contains('wildcard'), err.msg()
	}
}

fn test_bind_addr_brackets_an_ipv6_literal() {
	assert bind_addr('', 30490) == '0.0.0.0:30490'
	assert bind_addr('127.0.0.1', 30491) == '127.0.0.1:30491'
	assert bind_addr('::1', 30491) == '[::1]:30491'
	assert bind_addr('[::1]', 30491) == '[::1]:30491'
}

// A wildcard's FAMILY follows the group, because an interface selector cannot change a socket's
// family: an IPv4 socket cannot join an IPv6 group however that argument is spelled. Both
// listeners reach the wildcard differently — a script passes no host, a channel's endpoint has
// already materialised `0.0.0.0` — so the rule has to cover both spellings of it.
fn test_the_wildcard_family_follows_the_group() {
	assert bind_host_for('', 'ff02::1') == '::'
	assert bind_host_for('0.0.0.0', 'ff02::1') == '::'
	assert bind_host_for('', '239.1.2.3') == ''
	assert bind_host_for('0.0.0.0', '239.1.2.3') == '0.0.0.0'
	assert bind_host_for('', '') == ''
	// a host the caller PINNED is never rewritten — that is a decision, and check_group_bind
	// refuses it with a group rather than quietly moving it
	assert bind_host_for('192.168.0.5', 'ff02::1') == '192.168.0.5'
	assert bind_host_for('::1', 'ff02::1') == '::1'
}
