module transport

// The parsing half of the CANsub's REST client, checked against what the device actually sends.
// The bytes in `test_the_status_line_the_device_really_sends` were captured off a TLS socket to a
// CANsub.4 on firmware 02.04.00; everything else here is the general case around them.

// The reason this file exists. V's own client splits the status line and demands three tokens, so
// this exact line — no reason phrase, not even the space before it — fails every request against
// the device with "expected at least 3 tokens, but found: 2".
fn test_the_status_line_the_device_really_sends() {
	raw := 'HTTP/1.1 200\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n"04.00"\r\n0\r\n\r\n'
	r := cansub_parse_response(raw) or {
		assert false, 'the device\'s own reply did not parse: ${err}'
		return
	}
	assert r.status == 200
	assert r.body == '"04.00"'
}

fn test_a_status_line_with_a_reason_phrase_still_works() {
	assert cansub_status_code('HTTP/1.1 200 OK')! == 200
	assert cansub_status_code('HTTP/1.0 404 Not Found')! == 404
	assert cansub_status_code('HTTP/1.1 500')! == 500
	assert cansub_status_code('HTTP/1.1 204 ')! == 204
}

fn test_a_line_that_is_not_a_status_is_refused() {
	for bad in ['', 'HTTP/1.1', 'HTTP/1.1 2O0 OK', 'GET / HTTP/1.1', 'HTTP/2 200'] {
		cansub_status_code(bad) or { continue }
		assert false, 'accepted "${bad}" as a status line'
	}
}

fn test_dechunk_reassembles_several_chunks() {
	assert cansub_dechunk('4\r\nWiki\r\n7\r\npedia i\r\n0\r\n\r\n')! == 'Wikipedia i'
}

fn test_dechunk_handles_an_empty_body() {
	assert cansub_dechunk('0\r\n\r\n')! == ''
}

// Chunk extensions are legal after a semicolon and carry no meaning for us.
fn test_dechunk_ignores_chunk_extensions() {
	assert cansub_dechunk('4;foo=bar\r\nWiki\r\n0\r\n\r\n')! == 'Wiki'
}

// A chunk header that promises more than arrived is a truncated response, not a body to guess at.
fn test_dechunk_refuses_a_truncated_chunk() {
	cansub_dechunk('10\r\nshort\r\n0\r\n\r\n') or { return }
	assert false, 'accepted a chunk shorter than its header claimed'
}

fn test_dechunk_refuses_a_bad_size() {
	cansub_dechunk('zz\r\nWiki\r\n0\r\n\r\n') or { return }
	assert false, 'accepted a non-hex chunk size'
}

// Content-Length is honoured as well, so this does not depend on the device continuing to prefer
// chunked — and a body longer than the header claims is trimmed, not passed on.
fn test_content_length_bodies() {
	r := cansub_parse_response('HTTP/1.1 200\r\nContent-Length: 5\r\n\r\nhello, and then some')!
	assert r.status == 200
	assert r.body == 'hello'
}

fn test_a_response_without_a_header_terminator_is_refused() {
	cansub_parse_response('HTTP/1.1 200\r\nContent-Length: 5\r\n') or { return }
	assert false, 'accepted a response with no header terminator'
}

// Header names are case-insensitive, and the device is not obliged to match anyone's preference.
fn test_header_names_are_case_insensitive() {
	r := cansub_parse_response('HTTP/1.1 200\r\ntRaNsFeR-eNcOdInG: Chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n')!
	assert r.body == 'abc'
}

// A non-200 still parses; the caller decides what to do with it. `cansub_get` turns it into an
// error, but a PUT that answers 204 is a success and must not be read as a failure here.
fn test_a_non_200_status_parses_rather_than_erroring() {
	r := cansub_parse_response('HTTP/1.1 404\r\nContent-Length: 0\r\n\r\n')!
	assert r.status == 404
	assert r.body == ''
}

// The device is addressed by name, always. An IP is one firmware update from being wrong: the
// 02.03.00 -> 02.04.00 update cleared persistent data and moved the device from 10.63.38.1 to
// 10.215.129.1, while the name followed it.
fn test_a_device_is_addressed_by_name() {
	assert cansub_host('e5a16adf') == 'e5a16adf-usb.local'
}
