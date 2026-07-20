// someip — SOME/IP wire framing (phase E3 codec/validation core): the standard
// 16-byte header, encode/decode plus the envelope validation an rx path applies
// before anything reaches routing. Pure-V, GUI-free, protocol-only — no sockets.
// This is the host-side oracle for the blobly_emb eth-bus design (its
// docs/someip.md): host encodes ↔ target decodes and vice versa, the same
// two-repo pincer the CAN stack used. See docs/ethernet_architecture.md.
//
// Scope: header codec + validation ONLY. SOME/IP-SD (offer/find/subscribe) and
// the sim service are NOT here — deferred; the blobly_emb design excludes SD on
// the target entirely (static endpoints, no discovery). The payload is opaque
// bytes: its layout is deployment-defined (blobly packs little-endian derived
// signal layouts), so payload/signal packing deliberately lives elsewhere.
//
// Every SOME/IP message is a 16-byte header followed by the payload; all header
// fields are big-endian on the wire:
//   message id(4)  = service(2) + method/event id(2); id bit 15 set = event/
//                    notification, clear = method (request/response)
//   length(4)      = 8 + payload bytes (everything after this field)
//   request id(4)  = client(2) + session(2); MUST be 0 for notifications,
//                    requests echo theirs into the response
//   protocol version(1) = 0x01
//   interface version(1) = deployment-managed
//   message type(1)     = REQUEST 0x00 / NOTIFICATION 0x02 / RESPONSE 0x80 /
//                         ERROR 0x81
//   return code(1)      = 0x00 ok; standard codes on error paths
// We use encoding.binary for every pack/unpack (same as modules/doip and
// modules/mf4) rather than hand-rolling byte shifts.
module someip

import encoding.binary

// header_len is the fixed SOME/IP header size.
pub const header_len = 16

// length_base is what the Length field counts beyond the payload: the
// request id + version/type/code bytes that follow the Length field.
pub const length_base = u32(8)

// Protocol version — the only value the standard defines.
pub const protocol_version = u8(0x01)

// Message types (the subset the blobly design uses; no TP flag 0x20+).
pub const mt_request = u8(0x00)
pub const mt_notification = u8(0x02)
pub const mt_response = u8(0x80)
pub const mt_error = u8(0x81)

// Return codes (the standard set, R19-11 PRS_SOMEIP_00191).
pub const rc_ok = u8(0x00)
pub const rc_not_ok = u8(0x01)
pub const rc_unknown_service = u8(0x02)
pub const rc_unknown_method = u8(0x03)
pub const rc_not_ready = u8(0x04)
pub const rc_not_reachable = u8(0x05)
pub const rc_timeout = u8(0x06)
pub const rc_wrong_protocol_version = u8(0x07)
pub const rc_wrong_interface_version = u8(0x08)
pub const rc_malformed_message = u8(0x09)
pub const rc_wrong_message_type = u8(0x0A)

// event_flag is bit 15 of the method/event id: set = event/notification id,
// clear = method (request/response) id. The bit classifies the id's ROLE, not
// its direction.
pub const event_flag = u16(0x8000)

// Header is the parsed 16-byte SOME/IP header. length is as read from the wire
// (validated against the datagram by parse); the builders compute it.
pub struct Header {
pub:
	service           u16
	method            u16 // method/event id; bit 15 set = event
	length            u32 // 8 + payload bytes
	client            u16
	session           u16
	protocol_version  u8
	interface_version u8
	msg_type          u8
	return_code       u8
}

// Message is a parsed SOME/IP message (header + raw payload bytes; the payload
// layout is deployment-defined and NOT interpreted here).
pub struct Message {
pub:
	header  Header
	payload []u8
}

// is_event reports whether a method/event id carries the event/notification
// class bit (bit 15).
pub fn is_event(id u16) bool {
	return id & event_flag != 0
}

// message_id returns the full 32-bit Message ID (service high, method low).
pub fn (h Header) message_id() u32 {
	return (u32(h.service) << 16) | u32(h.method)
}

// request_id returns the full 32-bit Request ID (client high, session low).
pub fn (h Header) request_id() u32 {
	return (u32(h.client) << 16) | u32(h.session)
}

// encode serializes a header + payload into one wire message. The Length field
// is computed from the payload (h.length is ignored) so an encoded message is
// always self-consistent.
pub fn encode(h Header, payload []u8) []u8 {
	mut out := []u8{len: header_len, cap: header_len + payload.len}
	binary.big_endian_put_u16_at(mut out, h.service, 0)
	binary.big_endian_put_u16_at(mut out, h.method, 2)
	binary.big_endian_put_u32_at(mut out, length_base + u32(payload.len), 4)
	binary.big_endian_put_u16_at(mut out, h.client, 8)
	binary.big_endian_put_u16_at(mut out, h.session, 10)
	out[12] = h.protocol_version
	out[13] = h.interface_version
	out[14] = h.msg_type
	out[15] = h.return_code
	out << payload
	return out
}

// parse_header decodes the fixed 16-byte header. It does not check the Length
// field against anything — that is parse()'s job, which knows the datagram size.
pub fn parse_header(buf []u8) !Header {
	if buf.len < header_len {
		return error('SOME/IP header too short: ${buf.len} < ${header_len}')
	}
	return Header{
		service:           binary.big_endian_u16_at(buf, 0)
		method:            binary.big_endian_u16_at(buf, 2)
		length:            binary.big_endian_u32_at(buf, 4)
		client:            binary.big_endian_u16_at(buf, 8)
		session:           binary.big_endian_u16_at(buf, 10)
		protocol_version:  buf[12]
		interface_version: buf[13]
		msg_type:          buf[14]
		return_code:       buf[15]
	}
}

// parse decodes one complete datagram: header + payload, with the Length field
// required to be EXACTLY consistent with the datagram size (one event = one
// datagram in the blobly design; a short OR trailing-garbage datagram is
// malformed, not tolerated — a self-consistent short datagram must never let a
// fixed-layout decoder read stale bytes). The comparison is done in u64 so a
// hostile Length near 2^32 cannot wrap any int math.
pub fn parse(buf []u8) !Message {
	h := parse_header(buf)!
	if h.length < length_base {
		return error('SOME/IP length too small: ${h.length} < ${length_base}')
	}
	if u64(buf.len) != 8 + u64(h.length) {
		return error('SOME/IP length inconsistent: datagram ${buf.len} bytes, header says ${8 +
			u64(h.length)}')
	}
	return Message{
		header:  h
		payload: buf[header_len..].clone()
	}
}

// --- envelope validation ----------------------------------------------------
// The rx-side checks the blobly design applies BEFORE routing (each is its own
// function so callers can pick; validate() runs the full set). Any failure is
// counted-and-dropped territory for the caller, never a crash.

// check_protocol_version rejects any protocol version other than 0x01.
pub fn check_protocol_version(h Header) ! {
	if h.protocol_version != protocol_version {
		return error('SOME/IP protocol version 0x${h.protocol_version:02X} != 0x${protocol_version:02X}')
	}
}

// check_service rejects a Message ID under a foreign service — the full 32-bit
// Message ID is validated, not just the low (method/event) half.
pub fn check_service(h Header, expected u16) ! {
	if h.service != expected {
		return error('SOME/IP service 0x${h.service:04X} != expected 0x${expected:04X}')
	}
}

// check_interface_version rejects a mismatched interface version (the
// deployment-managed version, bumped on breaking layout changes).
pub fn check_interface_version(h Header, expected u8) ! {
	if h.interface_version != expected {
		return error('SOME/IP interface version ${h.interface_version} != expected ${expected}')
	}
}

// check_message_type rejects unknown message-type values and a type that
// contradicts the id's bit-15 class: an event id (bit 15 set) only carries
// NOTIFICATION; a method id (bit 15 clear) only carries REQUEST/RESPONSE/ERROR.
pub fn check_message_type(h Header) ! {
	if h.msg_type !in [mt_request, mt_notification, mt_response, mt_error] {
		return error('SOME/IP unknown message type 0x${h.msg_type:02X}')
	}
	if is_event(h.method) != (h.msg_type == mt_notification) {
		return error('SOME/IP message type 0x${h.msg_type:02X} illegal for id 0x${h.method:04X} (bit-15 class mismatch)')
	}
}

// check_fixed_fields enforces the per-type fixed-field contract. Notifications:
// Request ID and Return Code MUST be zero — this is the BLOBLY deployment
// contract (emb docs/someip.md), which this oracle mirrors so it predicts the
// target's gate. (The standard permits session handling on notifications —
// client 0, session counting — but the blobly target deliberately emits and
// accepts only zero; leniency here would desync oracle and target. Revisit
// only with an SD/interop phase.) Requests: the standard fixes Return Code at
// ok. Responses/errors are unconstrained here (rcode is their payload).
pub fn check_fixed_fields(h Header) ! {
	if h.msg_type == mt_notification {
		if h.request_id() != 0 {
			return error('SOME/IP notification with nonzero request id 0x${h.request_id():08X}')
		}
		if h.return_code != rc_ok {
			return error('SOME/IP notification with nonzero return code 0x${h.return_code:02X}')
		}
	} else if h.msg_type == mt_request {
		if h.return_code != rc_ok {
			return error('SOME/IP request with nonzero return code 0x${h.return_code:02X}')
		}
		// the target's server gate requires a fully LIVE Request ID (both
		// halves nonzero; session wraps 1..): a dead session could not
		// correlate the response, and client 0 is the non-request reserve —
		// mirroring it back would hand strict peers an invalid correlation
		// id. Mirrored here so the oracle predicts the gate (net#49 rule).
		if h.session == 0 {
			return error('SOME/IP request with a dead session id (0) — the response could not be correlated')
		}
		if h.client == 0 {
			return error('SOME/IP request with the reserved client id 0 — not a valid correlation id')
		}
	}
}

// validate runs the full envelope check against the configured service +
// interface version: protocol version, service, interface version, message-type
// legality, and the per-type fixed-field rules.
pub fn validate(h Header, expected_service u16, expected_version u8) ! {
	check_protocol_version(h)!
	check_service(h, expected_service)!
	check_interface_version(h, expected_version)!
	check_message_type(h)!
	check_fixed_fields(h)!
}

// --- message builders -------------------------------------------------------

// notification builds an event message: Request ID and Return Code zero per the
// wire contract. event_id should carry bit 15 (event class); it is taken as-is.
pub fn notification(service u16, event_id u16, interface_version u8, payload []u8) []u8 {
	return encode(Header{
		service:           service
		method:            event_id
		protocol_version:  protocol_version
		interface_version: interface_version
		msg_type:          mt_notification
	}, payload)
}

// request builds a method call carrying the caller's client/session Request ID.
pub fn request(service u16, method_id u16, client u16, session u16, interface_version u8,
	payload []u8) []u8 {
	return encode(Header{
		service:           service
		method:            method_id
		client:            client
		session:           session
		protocol_version:  protocol_version
		interface_version: interface_version
		msg_type:          mt_request
	}, payload)
}

// response_for builds the RESPONSE to a parsed request: service, method,
// interface version and the full Request ID are echoed from the request header.
pub fn response_for(req Header, payload []u8) []u8 {
	return reply(req, mt_response, rc_ok, payload)
}

// error_for builds the ERROR reply to a parsed request with the given standard
// return code (rc_*), echoing the request's identity like response_for.
pub fn error_for(req Header, return_code u8, payload []u8) []u8 {
	return reply(req, mt_error, return_code, payload)
}

// reply builds the shared response/error layout echoing the request's identity.
fn reply(req Header, msg_type u8, return_code u8, payload []u8) []u8 {
	return encode(Header{
		service:           req.service
		method:            req.method
		client:            req.client
		session:           req.session
		protocol_version:  protocol_version
		interface_version: req.interface_version
		msg_type:          msg_type
		return_code:       return_code
	}, payload)
}
