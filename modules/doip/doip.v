// doip — DoIP (Diagnostics over IP, ISO 13400-2) wire framing: the generic header
// plus the handful of message types we need to carry UDS over Ethernet. Pure-V,
// GUI-free, protocol-only (no imports of uds/isotp) — the client/server in this
// module build on these. See docs/ethernet_architecture.md.
//
// Every DoIP message is an 8-byte generic header followed by a payload:
//   version(1) inverse_version(1) payload_type(2, BE) payload_length(4, BE) payload(N)
// Multi-byte fields are big-endian; we use encoding.binary for every pack/unpack
// (the same helper modules/mf4 uses) rather than hand-rolling byte shifts.
module doip

import encoding.binary

// Default DoIP port (same for TCP diagnostics and UDP discovery).
pub const port = 13400

// Protocol version (0x02 = ISO 13400-2:2012). inverse = ~version.
pub const protocol_version = u8(0x02)

// Payload types (the subset we implement).
pub const pt_vehicle_id_request = u16(0x0001)
pub const pt_vehicle_announcement = u16(0x0004) // a.k.a. vehicle identification response
pub const pt_routing_activation_request = u16(0x0005)
pub const pt_routing_activation_response = u16(0x0006)
pub const pt_diagnostic_message = u16(0x8001)
pub const pt_diagnostic_message_ack = u16(0x8002) // positive ack
pub const pt_diagnostic_message_nack = u16(0x8003) // negative ack

// Routing activation response codes.
pub const ra_success = u8(0x10)

// Diagnostic message ack code (positive).
pub const diag_ack_ok = u8(0x00)

// Diagnostic message negative-ack codes (ISO 13400-2, 0x8003 payload).
pub const diag_nack_invalid_source = u8(0x02)
pub const diag_nack_unknown_target = u8(0x03)

// header_len is the fixed generic-header size.
pub const header_len = 8

// max_payload_len caps the advertised payload length we will accept before
// allocating a receive buffer. A malformed/hostile peer can otherwise advertise a
// multi-GB length and force the reader to allocate it (and block forever waiting
// for a body that never comes). 64 KiB comfortably covers UDS-over-DoIP diagnostic
// messages (UDS block transfers are chunked well below this) while bounding the
// worst-case allocation.
pub const max_payload_len = u32(64 * 1024)

// Message is a parsed DoIP message (header fields + raw payload).
pub struct Message {
pub:
	payload_type u16
	payload      []u8
}

// encode builds a full DoIP message: generic header + payload.
pub fn encode(payload_type u16, payload []u8) []u8 {
	mut out := []u8{len: header_len, cap: header_len + payload.len}
	out[0] = protocol_version
	out[1] = u8(~protocol_version)
	binary.big_endian_put_u16_at(mut out, payload_type, 2)
	binary.big_endian_put_u32_at(mut out, u32(payload.len), 4)
	out << payload
	return out
}

// parse_header validates the generic header and returns (payload_type, payload_length).
// It does NOT require the payload bytes to be present yet (callers stream the body
// after reading the length).
pub fn parse_header(buf []u8) !(u16, u32) {
	if buf.len < header_len {
		return error('DoIP header too short: ${buf.len} < ${header_len}')
	}
	ver := buf[0]
	inv := buf[1]
	if inv != u8(~ver) {
		return error('DoIP header: inverse version 0x${inv:02X} != ~0x${ver:02X}')
	}
	payload_type := binary.big_endian_u16_at(buf, 2)
	payload_len := binary.big_endian_u32_at(buf, 4)
	return payload_type, payload_len
}

// parse decodes a complete in-memory message (header + full payload). It rejects
// an advertised payload length above max_payload_len BEFORE any int() cast or
// slice — payload_len is u32, and a hostile/buggy peer advertising >= 2^31 would
// otherwise wrap int() negative, defeat the truncation guard, and panic on the
// slice. This guard makes parse() safe for every caller (e.g. serve_udp_once,
// which has no separate cap), not just the ones that pre-check.
pub fn parse(buf []u8) !Message {
	payload_type, payload_len := parse_header(buf)!
	if payload_len > max_payload_len {
		return error('DoIP payload too large: ${payload_len} > ${max_payload_len}')
	}
	// payload_len <= max_payload_len (64 KiB) now, so int() math cannot overflow.
	if buf.len < header_len + int(payload_len) {
		return error('DoIP message truncated: have ${buf.len}, need ${header_len + int(payload_len)}')
	}
	return Message{
		payload_type: payload_type
		payload:      buf[header_len..header_len + int(payload_len)].clone()
	}
}

// --- message builders -------------------------------------------------------

// routing_activation_request: source(2) activation-type(1=0x00 default) reserved-ISO(4=0).
pub fn routing_activation_request(source u16) []u8 {
	mut payload := []u8{len: 7} // zero-filled: activation type + reserved-ISO stay 0
	binary.big_endian_put_u16_at(mut payload, source, 0)
	return encode(pt_routing_activation_request, payload)
}

// routing_activation_response: tester-addr(2) entity-addr(2) code(1) reserved-ISO(4=0).
pub fn routing_activation_response(tester u16, entity u16, code u8) []u8 {
	mut payload := []u8{len: 9} // reserved-ISO (bytes 5..9) stays 0
	binary.big_endian_put_u16_at(mut payload, tester, 0)
	binary.big_endian_put_u16_at(mut payload, entity, 2)
	payload[4] = code
	return encode(pt_routing_activation_response, payload)
}

// diagnostic_message: source(2) target(2) user-data(N).
pub fn diagnostic_message(source u16, target u16, user_data []u8) []u8 {
	mut payload := []u8{len: 4, cap: 4 + user_data.len}
	binary.big_endian_put_u16_at(mut payload, source, 0)
	binary.big_endian_put_u16_at(mut payload, target, 2)
	payload << user_data
	return encode(pt_diagnostic_message, payload)
}

// diagnostic_message_ack: source(2) target(2) ack-code(1).
pub fn diagnostic_message_ack(source u16, target u16, code u8) []u8 {
	return diag_status(pt_diagnostic_message_ack, source, target, code)
}

// diagnostic_message_nack: source(2) target(2) nack-code(1) — sent when a
// diagnostic message can't be accepted (e.g. unknown target address).
pub fn diagnostic_message_nack(source u16, target u16, code u8) []u8 {
	return diag_status(pt_diagnostic_message_nack, source, target, code)
}

// diag_status builds the shared 0x8002/0x8003 layout: source(2) target(2) code(1).
fn diag_status(payload_type u16, source u16, target u16, code u8) []u8 {
	mut payload := []u8{len: 5}
	binary.big_endian_put_u16_at(mut payload, source, 0)
	binary.big_endian_put_u16_at(mut payload, target, 2)
	payload[4] = code
	return encode(payload_type, payload)
}

// vehicle_id_request: empty payload (UDP broadcast for discovery).
pub fn vehicle_id_request() []u8 {
	return encode(pt_vehicle_id_request, [])
}

// vehicle_announcement: VIN(17) logical-addr(2) EID(6) GID(6) further-action(1).
// vin is padded/truncated to 17 bytes; eid/gid to 6.
pub fn vehicle_announcement(vin string, logical_addr u16, eid []u8, gid []u8) []u8 {
	mut payload := fixed_bytes(vin.bytes(), 17)
	payload << binary.big_endian_get_u16(logical_addr)
	payload << fixed_bytes(eid, 6)
	payload << fixed_bytes(gid, 6)
	payload << u8(0x00) // further action required: none
	return encode(pt_vehicle_announcement, payload)
}

// --- payload parsers --------------------------------------------------------

// DiagMessage is the parsed body of a 0x8001 diagnostic message.
pub struct DiagMessage {
pub:
	source u16
	target u16
	data   []u8 // UDS user data
}

// parse_diagnostic_message extracts source/target/user-data from a 0x8001 payload.
pub fn parse_diagnostic_message(payload []u8) !DiagMessage {
	if payload.len < 4 {
		return error('DoIP diagnostic message too short: ${payload.len} < 4')
	}
	return DiagMessage{
		source: binary.big_endian_u16_at(payload, 0)
		target: binary.big_endian_u16_at(payload, 2)
		data:   payload[4..].clone()
	}
}

// RoutingActivation is the parsed body of a 0x0005 request.
pub struct RoutingActivation {
pub:
	source          u16
	activation_type u8
}

// parse_routing_activation_request extracts source + activation type from a 0x0005 payload.
pub fn parse_routing_activation_request(payload []u8) !RoutingActivation {
	if payload.len < 3 {
		return error('DoIP routing activation request too short: ${payload.len} < 3')
	}
	return RoutingActivation{
		source:          binary.big_endian_u16_at(payload, 0)
		activation_type: payload[2]
	}
}

// fixed_bytes returns src truncated or zero-padded to exactly n bytes.
fn fixed_bytes(src []u8, n int) []u8 {
	mut out := []u8{len: n} // zero-filled; copy fills the prefix, the tail stays 0
	copy(mut out, src[..if src.len < n { src.len } else { n }])
	return out
}
