module doip

import transport

fn test_header_roundtrip() {
	msg := encode(pt_diagnostic_message, [u8(0xDE), 0xAD, 0xBE, 0xEF])
	assert msg.len == header_len + 4
	assert msg[0] == protocol_version
	assert msg[1] == u8(~protocol_version)
	pt, plen := parse_header(msg)!
	assert pt == pt_diagnostic_message
	assert plen == 4
	m := parse(msg)!
	assert m.payload_type == pt_diagnostic_message
	assert m.payload == [u8(0xDE), 0xAD, 0xBE, 0xEF]
}

fn test_bad_inverse_version() {
	mut msg := encode(pt_vehicle_id_request, [])
	msg[1] = 0x00 // corrupt the inverse version
	if _, _ := parse_header(msg) {
		assert false, 'expected header validation to fail'
	}
}

fn test_parse_rejects_oversized_payload_len() {
	// A header advertising a huge payload (high bit set) must ERROR, not panic on
	// an int()-overflow slice. Regression for the remote serve_udp_once crash.
	huge := [protocol_version, u8(~protocol_version), 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]
	if _ := parse(huge) {
		assert false, 'expected oversized payload_len (0xFFFFFFFF) to be rejected'
	}
	// Just over the cap (max_payload_len = 64 KiB → 0x00010001 = 65537).
	over := [protocol_version, u8(~protocol_version), 0x00, 0x01, 0x00, 0x01, 0x00, 0x01]
	if _ := parse(over) {
		assert false, 'expected payload_len over max_payload_len to be rejected'
	}
}

fn test_truncated_payload() {
	msg := encode(pt_diagnostic_message, [u8(1), 2, 3, 4])
	if _ := parse(msg[..msg.len - 1]) {
		assert false, 'expected truncated payload to fail'
	}
}

fn test_routing_activation_roundtrip() {
	req := routing_activation_request(0x0E80)
	pt, _ := parse_header(req)!
	assert pt == pt_routing_activation_request
	m := parse(req)!
	ra := parse_routing_activation_request(m.payload)!
	assert ra.source == 0x0E80
	assert ra.activation_type == 0x00

	resp := routing_activation_response(0x0E80, 0x1000, ra_success)
	rm := parse(resp)!
	assert rm.payload_type == pt_routing_activation_response
	assert rm.payload[4] == ra_success
	// tester + entity addresses echo back
	assert (u16(rm.payload[0]) << 8) | u16(rm.payload[1]) == 0x0E80
	assert (u16(rm.payload[2]) << 8) | u16(rm.payload[3]) == 0x1000
}

fn test_diagnostic_message_roundtrip() {
	uds := [u8(0x22), 0xF1, 0x90] // RDBI VIN
	msg := diagnostic_message(0x0E80, 0x1000, uds)
	m := parse(msg)!
	assert m.payload_type == pt_diagnostic_message
	dm := parse_diagnostic_message(m.payload)!
	assert dm.source == 0x0E80
	assert dm.target == 0x1000
	assert dm.data == uds
}

fn test_diag_ack_roundtrip() {
	msg := diagnostic_message_ack(0x1000, 0x0E80, diag_ack_ok)
	m := parse(msg)!
	assert m.payload_type == pt_diagnostic_message_ack
	dm := parse_diagnostic_message(m.payload)!
	assert dm.source == 0x1000
	assert dm.target == 0x0E80
	assert dm.data == [u8(diag_ack_ok)]
}

fn test_vehicle_announcement_layout() {
	msg := vehicle_announcement('BLOBLYNETV0SUT001', 0x1000, [u8(1), 2, 3, 4, 5, 6], [u8(0xAA),
		0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
	m := parse(msg)!
	assert m.payload_type == pt_vehicle_announcement
	// VIN(17) + addr(2) + EID(6) + GID(6) + action(1) = 32
	assert m.payload.len == 32
	assert m.payload[..17] == 'BLOBLYNETV0SUT001'.bytes()
	assert (u16(m.payload[17]) << 8) | u16(m.payload[18]) == 0x1000
	assert m.payload[19..25] == [u8(1), 2, 3, 4, 5, 6]
}

fn test_vin_padding() {
	// Short VIN is zero-padded to 17 bytes.
	msg := vehicle_announcement('ABC', 0x1, [], [])
	m := parse(msg)!
	assert m.payload[..3] == 'ABC'.bytes()
	assert m.payload[3] == 0
	assert m.payload[16] == 0
}

fn test_parse_vehicle_announcement_requires_full() {
	// a truncated payload (VIN + logical only) must be rejected.
	if _ := parse_vehicle_announcement([]u8{len: 20}) {
		assert false, 'expected a short announcement to error'
	}
	// a full 32-byte payload parses with EID + GID present.
	full := []u8{len: announcement_len}
	info := parse_vehicle_announcement(full) or {
		assert false, 'full announcement should parse: ${err}'
		return
	}
	assert info.eid.len == 6
	assert info.gid.len == 6
}

// An unconfigured VIN (ISO 13400: all 0x00 or all 0xFF) is no name; a padded one is trimmed.
fn test_vin_text_drops_the_unconfigured_fill() {
	assert VehicleInfo{ vin: 'WVWZZZ1JZXW000001' }.vin_text() == 'WVWZZZ1JZXW000001'
	assert VehicleInfo{ vin: [u8(0)].repeat(17).bytestr() }.vin_text() == ''
	assert VehicleInfo{ vin: [u8(0xFF)].repeat(17).bytestr() }.vin_text() == ''
	assert VehicleInfo{ vin: 'SHORT' + [u8(0)].repeat(12).bytestr() }.vin_text() == 'SHORT'
}

// The address a tester dials is the answering host on the DISCOVERY port, IPv6 bracketed.
fn test_dial_address_keeps_the_host_and_takes_the_asked_port() {
	assert Announcement{ from: '192.168.0.50:51234' }.dial_address(13400) == '192.168.0.50:13400'
	assert Announcement{ from: '[fe80::1]:13400' }.dial_address(13401) == '[fe80::1]:13401'
}

// A passive listener keeps every announcement (an entity repeats itself, and that is what it is
// there to see); an identification request keeps one per entity.
fn test_only_identify_folds_repeated_answers() {
	ann := vehicle_announcement('TESTVIN0000000042', 0x07A0, default_eid, [])
	got := [
		transport.Datagram{
			from: '10.0.0.2:13400'
			data: ann
		},
		transport.Datagram{
			from: '10.0.0.2:13400'
			data: ann
		},
	]
	assert announcements_in(got, false).len == 2
	assert announcements_in(got, true).len == 1
}

// Brackets are an IPv6 literal's matching outer pair, or nothing.
fn test_bare_host_strips_only_a_matching_pair() {
	assert bare_host('[::1]')! == '::1'
	assert bare_host(' 192.168.0.50 ')! == '192.168.0.50'
	assert bare_host('::1')! == '::1'
	assert bare_host('ecu.local')! == 'ecu.local'
	for bad in ['[::1', '::1]', '[[::1]]', 'ecu[1]'] {
		if _ := bare_host(bad) {
			assert false, '${bad} accepted'
		}
	}
}

fn test_routing_activation_codes_by_name() {
	assert ra_code_name(0x00) == 'unknown source address'
	assert ra_code_name(0x01) == 'all sockets registered'
	assert ra_code_name(0x02) == 'SA differs from the active socket'
	assert ra_code_name(0x03) == 'SA already active on another socket'
	assert ra_code_name(0x04) == 'missing authentication'
	assert ra_code_name(0x05) == 'rejected confirmation'
	assert ra_code_name(0x06) == 'unsupported activation type'
	assert ra_code_name(0x07) == 'TLS required'
	assert ra_code_name(0x10) == 'success'
	assert ra_code_name(0x11) == 'confirmation required'
	assert ra_code_name(0x08) == 'reserved'
	assert ra_code_name(0xE5) == 'OEM-specific'
	assert ra_code_hint(0x00, 0x0E80) == 'this entity does not accept tester 0x0E80'
	assert ra_code_hint(0x06, 0x0E80) == ''
	assert RoutingDenied{
		code:   0x06
		tester: 0x0E00
	}.msg() == 'DoIP: routing activation denied: 0x06 unsupported activation type'
}
