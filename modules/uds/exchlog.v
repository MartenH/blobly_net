module uds

// exchlog.v — the exchange log: one ENTRY per request a tester put on the carrier (its bytes, the
// answer's, the NRC, the time it took and how much of that was responsePending), and entries of
// their own kind for what is not a request — a connection opened or let go, a line a front end
// had to say. The Diagnostics panel's response table is these entries; `line()` is the ONE text
// rendering of one, which its Copy all and any other text view share, and script.lua_from_log
// turns them back into a script.

// Exchange is what a Client reports of one request through `on_exchange`, answered or not.
pub struct Exchange {
pub:
	req       []u8 // as it went out (a suppressed request with its bit set)
	resp      []u8 // the positive answer; a negative one's 7F <sid> <nrc>; a malformed one as it came; empty = none
	err       string // '' = answered positively, or a suppressed request's quiet success
	negative  bool
	malformed bool
	timing    ExchangeTiming
}

// Outcome is what became of one entry.
pub enum Outcome {
	positive
	negative
	malformed  // an answer arrived that is not a response to read
	no_answer  // sent, and nothing (or no final answer) came
	not_sent   // it never reached the carrier
	connection // a connection opened, let go or failed — not a request
	note       // a line a front end said that is neither
}

// LogEntry is one row of the exchange log.
pub struct LogEntry {
pub mut:
	seq        u64    // given by ExchangeLog.push; 0 until then
	clock      string // HH:MM:SS.mmm when it ended, as the front end reads its clock
	target     string // the target's label, as shown
	key        string // the target's identity (what "this target only" compares)
	outcome    Outcome
	req        []u8
	resp       []u8
	nrc        u8
	rtt_us     i64
	pending    int
	pending_us i64
	did_name   string // a description's name for the DID the request names ('' = the standard one, if any)
	text       string // a connection event's or a note's line; why a request went unanswered or unsent
	failed     bool   // reports a failure: a connection event or note, or an answer the front end could not use
	note       string // what the front end made of the answer (a value decoded by a description)
}

// entry_of is the log entry of one exchange.
pub fn entry_of(x Exchange) LogEntry {
	outcome := if x.err == '' {
		Outcome.positive
	} else if x.negative {
		Outcome.negative
	} else if x.malformed {
		Outcome.malformed
	} else if x.timing.sent {
		Outcome.no_answer
	} else {
		Outcome.not_sent
	}
	return LogEntry{
		outcome:    outcome
		req:        x.req.clone()
		resp:       x.resp.clone()
		nrc:        if x.negative && x.resp.len == 3 { x.resp[2] } else { u8(0) }
		rtt_us:     if x.timing.sent { x.timing.rtt_us } else { 0 }
		pending:    x.timing.pending
		pending_us: x.timing.pending_us
		text:       if outcome in [.no_answer, .not_sent, .malformed] { x.err } else { '' }
	}
}

// is_request: the entry is a request (anything but a connection event or a note).
pub fn (e LogEntry) is_request() bool {
	return e.outcome !in [.connection, .note]
}

// is_error: what the "errors only" filter keeps — a request not answered positively, and a
// connection event or note reporting a failure.
pub fn (e LogEntry) is_error() bool {
	return match e.outcome {
		.positive, .connection, .note { e.failed }
		else { true }
	}
}

// service_name is a request's service, short.
pub fn service_name(sid u8) string {
	return match sid {
		0x10 { 'Session' }
		0x11 { 'ECUReset' }
		0x14 { 'ClearDTC' }
		0x19 { 'ReadDTC' }
		0x22 { 'ReadDID' }
		0x23 { 'ReadMemory' }
		0x24 { 'ReadScaling' }
		0x27 { 'SecurityAccess' }
		0x28 { 'CommControl' }
		0x29 { 'Authentication' }
		0x2A { 'ReadDIDPeriodic' }
		0x2C { 'DynamicDID' }
		0x2E { 'WriteDID' }
		0x2F { 'IOControl' }
		0x31 { 'Routine' }
		0x34 { 'RequestDownload' }
		0x35 { 'RequestUpload' }
		0x36 { 'TransferData' }
		0x37 { 'TransferExit' }
		0x38 { 'FileTransfer' }
		0x3D { 'WriteMemory' }
		0x3E { 'TesterPresent' }
		0x85 { 'DTCSetting' }
		0x86 { 'ResponseOnEvent' }
		0x87 { 'LinkControl' }
		else { '' }
	}
}

// session_short names a DiagnosticSessionControl session.
pub fn session_short(s u8) string {
	return match s {
		0x01 { 'default' }
		0x02 { 'programming' }
		0x03 { 'extended' }
		0x04 { 'safety' }
		else { '' }
	}
}

fn dtc_sub_name(sub u8) string {
	return match sub & 0x7F {
		0x01 { 'countByMask' }
		0x02 { 'byMask' }
		0x03 { 'snapshotIds' }
		0x04 { 'snapshot' }
		0x06 { 'extData' }
		0x0A { 'supported' }
		else { '' }
	}
}

// bytes_hex is bytes as spaced hex, at most `max` of them (0 = all), with what was left out counted.
pub fn bytes_hex(b []u8, max int) string {
	n := if max > 0 && b.len > max { max } else { b.len }
	mut p := []string{cap: n + 1}
	for x in b[..n] {
		p << '${x:02X}'
	}
	if n < b.len {
		p << '… (${b.len} B)'
	}
	return p.join(' ')
}

fn joined(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X}'
	}
	return s
}

// request_hex is a request's bytes with its identifiers kept whole: a DID (`22 F190`), a DTC group
// (`14 FFFFFF`), a 0x19 04 / 06's DTC (`19 04 123456 FF`). At most 16 bytes of data.
pub fn request_hex(req []u8) string {
	if req.len == 0 {
		return ''
	}
	sid := req[0]
	mut head := ['${sid:02X}']
	mut rest := req[1..].clone()
	if sid in [u8(0x22), 0x2E, 0x2F, 0x24] && rest.len >= 2 {
		head << joined(rest[..2])
		rest = rest[2..].clone()
	} else if sid == 0x14 && rest.len >= 3 {
		head << joined(rest[..3])
		rest = rest[3..].clone()
	} else if sid == 0x19 && rest.len >= 4 && (rest[0] & 0x7F == 0x04 || rest[0] & 0x7F == 0x06) {
		head << '${rest[0]:02X}'
		head << joined(rest[1..4])
		rest = rest[4..].clone()
	} else if sid == 0x31 && rest.len >= 3 {
		head << '${rest[0]:02X}'
		head << joined(rest[1..3])
		rest = rest[3..].clone()
	}
	if rest.len > 0 {
		head << bytes_hex(rest, 16)
	}
	return head.join(' ')
}

// request_text is a request as a row names it: its bytes and what it is —
// `22 F190 ReadDID VIN`, `10 03 Session extended`, `27 01 SecurityAccess seed 1`.
pub fn (e LogEntry) request_text() string {
	if !e.is_request() {
		return ''
	}
	if e.req.len == 0 {
		return '(empty)'
	}
	sid := e.req[0]
	mut words := [request_hex(e.req)]
	name := service_name(sid)
	if name != '' {
		words << name
	}
	sub := if e.req.len > 1 { e.req[1] } else { u8(0) }
	what := match sid {
		0x10 {
			session_short(sub)
		}
		0x11 {
			match sub & 0x7F {
				0x01 { 'hard' }
				0x02 { 'keyOffOn' }
				0x03 { 'soft' }
				else { '' }
			}
		}
		0x14 {
			if e.req.len >= 4 && e.req[1] == 0xFF && e.req[2] == 0xFF && e.req[3] == 0xFF {
				'all'
			} else {
				''
			}
		}
		0x19 {
			dtc_sub_name(sub)
		}
		0x22, 0x2E {
			if e.req.len >= 3 { e.did_label(u16(e.req[1]) << 8 | u16(e.req[2])) } else { '' }
		}
		0x27 {
			if sub & 0x7F == 0 {
				''
			} else if sub & 1 == 1 {
				'seed ${sub & 0x7F}'
			} else {
				'key ${(sub & 0x7F) - 1}'
			}
		}
		0x85 {
			match sub & 0x7F {
				0x01 { 'on' }
				0x02 { 'off' }
				else { '' }
			}
		}
		else {
			''
		}
	}
	if what != '' {
		words << what
	}
	if sid in [u8(0x10), 0x11, 0x19, 0x27, 0x28, 0x31, 0x3E, 0x85] && sub & suppress_positive != 0 {
		words << '(suppressed)'
	}
	return words.join(' ')
}

fn (e LogEntry) did_label(did u16) string {
	return if e.did_name != '' { e.did_name } else { standard_did_name(did) }
}

fn printable_or_hex(b []u8, max int) string {
	if b.len > 0 && b.all(it >= 0x20 && it < 0x7F) {
		return '"${b.bytestr()}"'
	}
	return bytes_hex(b, max)
}

// response_text is a row's answer, short: a positive one decoded where its service says how
// (`F190 = "WVW…"`, `3 DTC(s)`, `session 03 · P2 50 ms, P2* 5000 ms`), a negative one as its
// bytes and NRC name (`7F 22 31 requestOutOfRange`), and why there was none.
pub fn (e LogEntry) response_text() string {
	match e.outcome {
		.connection, .note {
			return e.text
		}
		.negative {
			return '${bytes_hex(e.resp, 0)} ${nrc_name(e.nrc)}'
		}
		.malformed {
			return 'malformed: ${bytes_hex(e.resp, 16)}'
		}
		.no_answer {
			return 'no answer: ${e.text}'
		}
		.not_sent {
			return 'not sent: ${e.text}'
		}
		.positive {}
	}
	r := e.resp
	if r.len == 0 {
		return 'no positive response (suppressed)'
	}
	match r[0] {
		0x50 {
			if r.len >= 2 {
				mut s := 'session ${r[1]:02X}'
				if st := session_timing(r) {
					s += ' · P2 ${st.p2_ms} ms, P2* ${st.p2_star_ms} ms'
				}
				return s
			}
		}
		0x62 {
			if r.len >= 3 && e.req.len == 3 {
				return '${joined(r[1..3])} = ${printable_or_hex(r[3..], 24)}'
			}
		}
		0x59 {
			if r.len >= 2 && r[1] == 0x02 {
				if rep := decode_dtc_list(r) {
					return '${rep.records.len} DTC(s)'
				}
			}
			if r.len >= 2 && r[1] == 0x01 {
				if c := decode_dtc_count(r) {
					return '${c.count} DTC(s) match'
				}
			}
		}
		0x54 {
			return 'cleared'
		}
		0x6E {
			return 'written'
		}
		0x67 {
			if r.len >= 2 && r[1] & 1 == 1 {
				return 'seed ${bytes_hex(r[2..], 16)}'
			}
			return 'unlocked'
		}
		0x7E, 0xC5, 0x51, 0x68 {
			return 'OK'
		}
		else {}
	}
	return bytes_hex(r, 24)
}

// latency_text is the row's time: the round trip in ms, '' where nothing was sent.
pub fn (e LogEntry) latency_text() string {
	if !e.is_request() || e.outcome == .not_sent {
		return ''
	}
	return '${f64(e.rtt_us) / 1000.0:.1f}'
}

// pending_text is the row's responsePending: how many, and how long from the first.
pub fn (e LogEntry) pending_text() string {
	if e.pending == 0 {
		return ''
	}
	return '${e.pending}× ${f64(e.pending_us) / 1000.0:.1f} ms'
}

// line is an entry as ONE line of text — the copy-all text and every other text view of the log.
pub fn (e LogEntry) line() string {
	mut s := '${e.clock}  ${e.target}  '
	if !e.is_request() {
		tag := if e.outcome == .connection { '[connection] ' } else { '' }
		return s + tag + e.text
	}
	lat := e.latency_text()
	time_col := if lat != '' { '[${lat:7} ms] ' } else { '[  not sent] ' }
	s += time_col + '${e.request_text()} → ${e.response_text()}'
	if e.pending > 0 {
		s += ' (0x78 ${e.pending_text()})'
	}
	if e.note != '' {
		s += ' — ${e.note}'
	}
	return s
}

// detail is an entry in full: every byte of the request and the answer, for the table's selection.
pub fn (e LogEntry) detail() string {
	if !e.is_request() {
		return e.line()
	}
	mut out := ['${e.clock}  ${e.target}  ${e.outcome}']
	out << 'request  (${e.req.len} B): ${bytes_hex(e.req, 0)}'
	if e.resp.len > 0 {
		out << 'response (${e.resp.len} B): ${bytes_hex(e.resp, 0)}'
	}
	out << 'answer: ${e.response_text()}'
	if e.outcome != .not_sent {
		out << 'latency: ${e.latency_text()} ms${if e.pending > 0 { ', 0x78 ' + e.pending_text() } else { '' }}'
	}
	if e.note != '' {
		out << 'note: ${e.note}'
	}
	return out.join('\n')
}

// ExchangeLog is the bounded log: the newest `cap` entries, each numbered as it is pushed.
pub struct ExchangeLog {
pub mut:
	cap     int = 500
	entries []LogEntry
	seq     u64 // the last number given
}

// push appends `e` (dropping the oldest past the cap) and returns its number.
pub fn (mut l ExchangeLog) push(e LogEntry) u64 {
	l.seq++
	l.entries << LogEntry{
		...e
		seq: l.seq
	}
	if l.cap > 0 && l.entries.len > l.cap {
		// trimmed in batches, so a full log does not copy itself on every push
		drop := l.entries.len - l.cap + l.cap / 10
		l.entries.delete_many(0, if drop > l.entries.len { l.entries.len } else { drop })
	}
	return l.seq
}

// annotate gives entry `seq` the note `note`, when it is still the NEWEST entry and has none:
// what a front end made of an answer belongs to it only while nothing has come between them. A
// `failed` note marks the entry an error (an answer the front end could not use). false = not
// annotated (the caller says the line as an entry of its own).
pub fn (mut l ExchangeLog) annotate(seq u64, note string, failed bool) bool {
	if seq == 0 || l.entries.len == 0 {
		return false
	}
	mut last := &l.entries[l.entries.len - 1]
	if last.seq != seq || last.note != '' || !last.is_request() {
		return false
	}
	last.note = note
	if failed {
		last.failed = true
	}
	return true
}

pub fn (mut l ExchangeLog) clear() {
	l.entries = []
}

// LogFilter is what the table shows.
pub struct LogFilter {
pub:
	errors_only bool
	key         string // '' = every target
}

// keeps: the filter shows `e`.
pub fn (f LogFilter) keeps(e LogEntry) bool {
	if f.errors_only && !e.is_error() {
		return false
	}
	return f.key == '' || e.key == f.key
}

// text is the entries as text, one line each.
pub fn log_text(entries []LogEntry) string {
	return entries.map(it.line()).join('\n')
}
