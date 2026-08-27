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
	r :=
		cansub_parse_response('HTTP/1.1 200\r\ntRaNsFeR-eNcOdInG: Chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n')!
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

// A BODY THAT SIMPLY STOPS is not a complete one. The chunk sequence ends with a zero-size chunk;
// without it the connection died mid-response, and `cansub_request` treats every read error as
// EOF — so the bytes collected so far used to come back as a successful answer. Partial JSON
// parses to a device reply with fields quietly missing, which is worse than an error (codex round
// 3 on #204).
fn test_dechunk_refuses_a_body_that_never_terminates() {
	// Two complete chunks and then nothing: exactly what a socket dropped between chunks leaves.
	cansub_dechunk('4\r\nWiki\r\n7\r\npedia i\r\n') or { return }
	assert false, 'accepted an unterminated chunk sequence as a complete body'
}

fn test_dechunk_refuses_a_single_complete_chunk_with_no_terminator() {
	cansub_dechunk('4\r\nWiki\r\n') or { return }
	assert false, 'one chunk is not a body until the zero chunk says so'
}

// An empty string is not a chunked body at all — it has no terminating chunk either.
fn test_dechunk_refuses_nothing_at_all() {
	cansub_dechunk('') or { return }
	assert false, 'an empty response is not a terminated chunked body'
}

// A DECLARED LENGTH IS A PROMISE. Fewer bytes than Content-Length says is a connection that ended
// mid-body, and `cansub_request` treats every read error as EOF — so nothing else is going to
// notice. The chunked path refuses its own version of this; this one used to fall through and hand
// back partial JSON as a successful reply (codex round 4 on #204).
fn test_a_short_content_length_body_is_refused() {
	raw := 'HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n{"state":"error_act'
	cansub_parse_response(raw) or { return }
	assert false, 'accepted 19 bytes against a declared 40'
}

fn test_a_complete_content_length_body_is_accepted() {
	body := '{"state":"error_active"}'
	raw := 'HTTP/1.1 200 OK\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	r := cansub_parse_response(raw) or {
		assert false, 'a complete body must parse: ${err}'
		return
	}
	assert r.status == 200
	assert r.body == body
}

// More bytes than declared is not a truncation — a keep-alive connection can leave the next
// response in the buffer — so the body is still cut to the declared length.
fn test_extra_bytes_after_a_content_length_body_are_ignored() {
	raw := 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokTRAILING'
	r := cansub_parse_response(raw) or {
		assert false, '${err}'
		return
	}
	assert r.body == 'ok'
}

// A CHUNK SIZE THAT OVERFLOWS AN INT. `v = v * 16 + d` is int arithmetic, so `80000000` wraps
// NEGATIVE — and a negative size walks straight past a `i + size > body.len` guard, after which the
// slice endpoint is invalid and the process dies. The response cap does not help, because the
// oversized declaration is only a few bytes (codex round 7 on #204).
fn test_an_oversized_chunk_size_is_refused_rather_than_wrapped() {
	for tok in ['80000000', 'FFFFFFFF', '100000000', 'FFFFFFFFFFFFFFFF'] {
		if v := hex_int(tok) {
			assert false, '${tok} parsed as ${v}, which is not a size this client could ever honour'
		}
	}
}

fn test_ordinary_chunk_sizes_still_parse() {
	assert hex_int('0')? == 0
	assert hex_int('4')? == 4
	assert hex_int('ff')? == 255
	assert hex_int('FF')? == 255
	assert hex_int('1000')? == 4096
}

// And the whole path, not just the parser: a body declaring an absurd chunk must produce an error
// rather than an invalid slice.
fn test_dechunk_refuses_an_overflowing_chunk_header() {
	cansub_dechunk('80000000\r\nWiki\r\n0\r\n\r\n') or { return }
	assert false, 'accepted a chunk size that cannot be honoured'
}

// A size larger than what remains is refused by comparing against the REMAINDER, never by adding
// to the index — the addition is the arithmetic the check exists to be safe from.
fn test_dechunk_refuses_a_chunk_longer_than_the_remainder() {
	cansub_dechunk('7FFFFF\r\nWiki\r\n0\r\n\r\n') or { return }
	assert false, 'accepted a chunk longer than the body'
}
