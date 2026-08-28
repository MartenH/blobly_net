module transport

import sync
import time

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

// A KEPT-ALIVE READER STOPS WHEN THE REPLY IS COMPLETE, not when the device hangs up — which on a
// kept-alive connection it never does. Chunked (what the device sends), Content-Length, and a
// bodiless reply; and every partial prefix of each is NOT complete.
fn test_a_reply_is_complete_at_its_terminating_chunk_or_content_length() {
	chunked := 'HTTP/1.1 200\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n18\r\n{"state":"error_active"}\r\n0\r\n\r\n'
	assert cansub_response_complete(chunked.bytes())
	for cut in 1 .. chunked.len {
		assert !cansub_response_complete(chunked[..cut].bytes()), 'a prefix of ${cut} bytes read as complete'
	}
	with_length := 'HTTP/1.1 200\r\nContent-Length: 5\r\n\r\nhello'
	assert cansub_response_complete(with_length.bytes())
	assert !cansub_response_complete(with_length[..with_length.len - 1].bytes())
	bodiless := 'HTTP/1.1 204\r\n\r\n'
	assert cansub_response_complete(bodiless.bytes())
	assert !cansub_response_complete('HTTP/1.1 204\r\n'.bytes())
	// A 200 with neither framing header is close-delimited: never complete from the bytes alone.
	assert !cansub_response_complete('HTTP/1.1 200\r\n\r\n'.bytes())
	assert !cansub_response_complete('HTTP/1.1 200\r\n\r\n{"a":1}'.bytes())
	assert cansub_response_complete('HTTP/1.1 304\r\n\r\n'.bytes())
	// The chunked check is about the terminator, not about an accidental "0" chunk in the body.
	assert !cansub_response_complete('HTTP/1.1 200\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n0\r\n'.bytes())
}

// THE TERMINATING CHUNK IS RECOGNISED IN EVERY SHAPE cansub_dechunk ACCEPTS: bare, with a chunk
// extension, and followed by trailers — and a `0` inside a chunk's data is not it (codex round 1
// on #248).
fn test_a_terminating_chunk_with_an_extension_or_trailers_completes_the_reply() {
	head := 'HTTP/1.1 200\r\nTransfer-Encoding: chunked\r\n\r\n'
	with_ext := head + '5\r\nhello\r\n0;done=1\r\n\r\n'
	assert cansub_response_complete(with_ext.bytes())
	assert !cansub_response_complete(with_ext[..with_ext.len - 2].bytes())
	with_trailer := head + '5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n'
	assert cansub_response_complete(with_trailer.bytes())
	assert !cansub_response_complete(with_trailer[..with_trailer.len - 2].bytes()), 'a trailer without its empty line is not the end'
	// What the completeness test says complete, the dechunker accepts.
	assert cansub_dechunk(with_ext[head.len..])! == 'hello'
	assert cansub_dechunk(with_trailer[head.len..])! == 'hello'
	// A zero in the data is data.
	assert !cansub_response_complete((head + '3\r\n0\r\n\r\n').bytes())
	assert cansub_response_complete((head + '3\r\n0\r\n\r\n0\r\n\r\n').bytes())
}

// FORGETTING AN ADDRESS ALSO FORGETS THE CONNECTION TO IT — there is no device here, so the
// pool is exercised with no connection: the forget must simply be safe with nothing pooled, and
// leave nothing pooled.
fn test_forgetting_an_address_leaves_no_connection_pooled() {
	cansub_forget_addr('192.0.2.1')
	pooled := rlock cansub_pool {
		'192.0.2.1' in cansub_pool.conns
	}
	assert !pooled
}

// A CALLER WHOSE BUDGET RUNS OUT IN THE QUEUE LEAVES IT: with the connection held by another
// request, a 100 ms exchange fails at about 100 ms — not after the holder is done (codex round 2
// on #248). No device: the connection is never dialled, only its lock is contended.
fn test_a_request_gives_up_on_a_busy_connection_at_its_deadline() {
	mut c := &CansubConn{
		host: 'nobody.invalid'
		tcp:  unsafe { nil }
		ssl:  unsafe { nil }
		turn: sync.new_semaphore_init(1)
	}
	c.turn.wait() // another request, taking its time
	t0 := time.ticks()
	deadline := time.now().add(100 * time.millisecond)
	assert !c.acquire(deadline), 'acquired a lock somebody else holds'
	waited := time.ticks() - t0
	assert waited >= 90 && waited < 1000, 'gave up after ${waited} ms, not at the deadline'
	c.turn.post()
	later := time.now().add(100 * time.millisecond)
	assert c.acquire(later)
	c.turn.post()
}

// A FORGET IS A NEW GENERATION: what a dial that started before it is checked against when it
// comes back, so a connection to the device the forget was about is never pooled (codex round
// 4 on #248).
fn test_forgetting_an_address_starts_a_new_generation() {
	before := cansub_addr_generation('192.0.2.9')
	cansub_forget_addr('192.0.2.9')
	assert cansub_addr_generation('192.0.2.9') == before + 1
	cansub_forget_addr('192.0.2.9')
	assert cansub_addr_generation('192.0.2.9') == before + 2
}
