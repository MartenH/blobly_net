module uds

import transport

// The exchange log: what a client reports of each request, and how an entry is shown.

// Canned answers, one per receive; nothing queued before a send.
struct Canned {
pub:
	iface string = 'canned'
	tx_id u32
	rx_id u32
mut:
	responses [][]u8
	idx       int
}

fn (mut m Canned) send(data []u8) ! {}

fn (mut m Canned) recv(timeout_ms int) ![]u8 {
	if timeout_ms == 0 || m.idx >= m.responses.len {
		return error('timeout')
	}
	m.idx++
	return m.responses[m.idx - 1]
}

fn (mut m Canned) close() {}

fn (mut m Canned) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

@[heap]
struct Seen {
mut:
	xs []Exchange
}

fn recording(responses [][]u8) (Client, &Seen) {
	mut c := new_client(&Canned{
		responses: responses
	})
	c.timeout_ms = 20
	mut seen := &Seen{}
	c.on_exchange = fn [mut seen] (x Exchange) {
		seen.xs << x
	}
	return c, seen
}

fn test_every_outcome_is_reported_with_its_bytes() {
	mut c, seen := recording([[u8(0x7F), 0x22, 0x78], [u8(0x62), 0xF1, 0x90, 0x41],
		[u8(0x7F), 0x22, 0x31], [u8(0x62)]])
	c.read_data_by_identifier(0xF190) or { panic(err) }
	c.read_data_by_identifier(0xABCD) or {}
	c.raw([u8(0x22), 0x01, 0x02]) or {} // a malformed answer: 62 alone, too short for its echo
	c.raw([u8(0x3E), 0x00]) or {} // nothing more queued: no answer
	assert seen.xs.len == 4
	ok := entry_of(seen.xs[0])
	assert ok.outcome == .positive
	assert ok.req == [u8(0x22), 0xF1, 0x90]
	assert ok.resp == [u8(0x62), 0xF1, 0x90, 0x41]
	assert ok.pending == 1
	neg := entry_of(seen.xs[1])
	assert neg.outcome == .negative
	assert neg.resp == [u8(0x7F), 0x22, 0x31]
	assert neg.nrc == 0x31
	bad := entry_of(seen.xs[2])
	assert bad.outcome == .malformed
	assert bad.resp == [u8(0x62)]
	none_ := entry_of(seen.xs[3])
	assert none_.outcome == .no_answer
	assert none_.text.contains('timeout')
}

fn test_an_empty_request_is_not_sent_whatever_went_before() {
	mut c, seen := recording([[u8(0x7E), 0x00]])
	c.raw([u8(0x3E), 0x00]) or { panic(err) }
	c.raw([]u8{}) or {}
	e := entry_of(seen.xs[1])
	assert e.outcome == .not_sent, 'not the previous request timing'
	assert e.rtt_us == 0
}

fn test_suppressed_request_reports_its_bit_and_quiet_success() {
	mut c, seen := recording([])
	c.raw_suppressed([u8(0x3E), 0x00]) or { panic(err) }
	e := entry_of(seen.xs[0])
	assert e.outcome == .positive
	assert e.req == [u8(0x3E), 0x80]
	assert e.request_text() == '3E 80 TesterPresent (suppressed)'
	assert e.response_text() == 'no positive response (suppressed)'
}

fn test_request_and_response_text() {
	vin := LogEntry{
		outcome: .positive
		req:     [u8(0x22), 0xF1, 0x90]
		resp:    [u8(0x62), 0xF1, 0x90]
	}
	assert vin.request_text() == '22 F190 ReadDID VIN'
	mut named := vin
	named.did_name = 'odometer'
	assert named.request_text() == '22 F190 ReadDID odometer'
	assert LogEntry{
		outcome: .negative
		req:     [u8(0x22), 0xAB, 0xCD]
		resp:    [u8(0x7F), 0x22, 0x31]
		nrc:     0x31
	}.response_text() == '7F 22 31 requestOutOfRange'
	sess := LogEntry{
		outcome: .positive
		req:     [u8(0x10), 0x03]
		resp:    [u8(0x50), 0x03, 0x00, 0x32, 0x01, 0xF4]
	}
	assert sess.request_text() == '10 03 Session extended'
	assert sess.response_text() == 'session 03 · P2 50 ms, P2* 5000 ms'
	assert LogEntry{
		outcome: .positive
		req:     [u8(0x22), 0xF1, 0x90]
		resp:    '\x62\xF1\x90ABC'.bytes()
	}.response_text() == 'F190 = "ABC"'
	assert LogEntry{
		outcome: .positive
		req:     [u8(0x19), 0x02, 0xFF]
		resp:    [u8(0x59), 0x02, 0xFF, 0x12, 0x34, 0x56, 0x2F]
	}.response_text() == '1 DTC(s)'
	assert LogEntry{
		outcome: .positive
		req:     [u8(0x14), 0xFF, 0xFF, 0xFF]
		resp:    [u8(0x54)]
	}.request_text() == '14 FFFFFF ClearDTC all'
	assert LogEntry{
		outcome: .positive
		req:     [u8(0x19), 0x04, 0x12, 0x34, 0x56, 0xFF]
	}.request_text() == '19 04 123456 FF ReadDTC snapshot'
	assert LogEntry{
		outcome: .positive
		req:     [u8(0x27), 0x02, 0xAA]
		resp:    [u8(0x67), 0x02]
	}.request_text() == '27 02 AA SecurityAccess key 1'
	assert LogEntry{
		outcome: .positive
		req:     [u8(0x27), 0x01]
		resp:    [u8(0x67), 0x01, 0x12, 0x34]
	}.response_text() == 'seed 12 34'
}

fn test_line_is_the_one_text_rendering() {
	e := LogEntry{
		clock:      '12:00:01.250'
		target:     'SUT'
		outcome:    .negative
		req:        [u8(0x22), 0xAB, 0xCD]
		resp:       [u8(0x7F), 0x22, 0x31]
		nrc:        0x31
		rtt_us:     4200
		pending:    2
		pending_us: 1500
	}
	assert e.line() == '12:00:01.250  SUT  [    4.2 ms] 22 ABCD ReadDID → 7F 22 31 requestOutOfRange (0x78 2× 1.5 ms)'
	c := LogEntry{
		clock:   '12:00:00.000'
		target:  'SUT'
		outcome: .connection
		text:    'opened doip 127.0.0.1:13400: connect 1.0 ms'
	}
	assert c.line() == '12:00:00.000  SUT  [connection] opened doip 127.0.0.1:13400: connect 1.0 ms'
	assert !c.is_error()
	assert LogEntry{
		outcome: .connection
		failed:  true
	}.is_error()
	ns := LogEntry{
		clock:   't'
		target:  'X'
		outcome: .not_sent
		req:     [u8(0x3E), 0x00]
		text:    'no running CAN channel'
	}
	assert ns.line() == 't  X  [  not sent] 3E 00 TesterPresent → not sent: no running CAN channel'
	assert log_text([c, ns]) == '${c.line()}\n${ns.line()}'
}

fn test_log_is_bounded_numbered_and_annotates_only_its_newest() {
	mut l := ExchangeLog{
		cap: 10
	}
	mut last := u64(0)
	for i in 0 .. 25 {
		last = l.push(LogEntry{
			outcome: .positive
			req:     [u8(0x3E), u8(i)]
		})
	}
	assert l.entries.len <= 10
	assert l.entries.last().seq == last
	assert l.entries.last().req[1] == 24
	// numbers keep rising past a trim
	assert last == 25
	assert l.annotate(last, 'decoded', false)
	assert l.entries.last().note == 'decoded'
	assert !l.annotate(last, 'again', false), 'one note per entry'
	n := l.push(LogEntry{
		outcome: .positive
		req:     [u8(0x3E), 0]
	})
	l.push(LogEntry{
		outcome: .note
		text:    'between'
	})
	assert !l.annotate(n, 'late', false), 'something came between'
	m := l.push(LogEntry{
		outcome: .positive
		req:     [u8(0x19), 0x02, 0xFF]
	})
	assert !l.entries.last().is_error()
	assert l.annotate(m, 'not a whole number of DTC records', true)
	assert l.entries.last().is_error(), 'an answer the front end could not use is an error'
}

fn test_held_entries_are_pushed_or_dropped_together() {
	mut l := ExchangeLog{}
	l.push(LogEntry{
		outcome: .positive
		req:     [u8(0x22), 0xF1, 0x90]
	})
	for sub in [u8(0x02), 0x06, 0x06] {
		l.hold(LogEntry{
			outcome: .positive
			req:     [u8(0x19), sub]
		})
	}
	assert l.entries.len == 1, 'held back, not shown'
	assert l.settle(false) == 0
	assert l.entries.len == 1 && l.held.len == 0, 'an unchanged refresh leaves no rows'
	for sub in [u8(0x02), 0x06] {
		l.hold(LogEntry{
			outcome: .positive
			req:     [u8(0x19), sub]
		})
	}
	last := l.settle(true)
	assert l.entries.len == 3
	assert l.entries.map(it.req[1]) == [u8(0xF1), 0x02, 0x06]
	assert last == l.entries.last().seq
}

fn test_filter() {
	ok := LogEntry{
		outcome: .positive
		key:     'a'
	}
	bad := LogEntry{
		outcome: .negative
		key:     'b'
	}
	assert LogFilter{}.keeps(ok)
	assert !LogFilter{
		errors_only: true
	}.keeps(ok)
	assert LogFilter{
		errors_only: true
	}.keeps(bad)
	assert !LogFilter{
		key: 'a'
	}.keeps(bad)
}
