module diaghold

// dtc.v — the DTC tab's rules: when its auto-refresh reads the list again, what of an auto-refresh
// is said in the log, and which session a DTC-setting press has to establish first.

// autorefresh_ms is how often the DTC tab's auto-refresh reads the DTC list.
pub const autorefresh_ms = 2000

// autorefresh_due: the tab asks for its list again — the tick is on, the tab is on screen, no
// press is in flight (a refresh queued behind one would only repeat it), and the last read of
// this target is `autorefresh_ms` old. `last_ms` 0 means never read: due at once.
pub fn autorefresh_due(on bool, shown bool, busy bool, last_ms i64, now_ms i64) bool {
	if !on || !shown || busy {
		return false
	}
	return last_ms == 0 || now_ms - last_ms >= autorefresh_ms
}

// autorefresh_logged: an auto-refresh is said in the log only when it read something other than
// the last read did, or failed — a line every two seconds saying nothing changed would bury the
// presses. A press is always said.
pub fn autorefresh_logged(auto bool, failed bool, prev string, now string) bool {
	return !auto || failed || prev != now
}

// dtc_setting_session is the session a ControlDTCSetting (0x85) press switches to first: the
// extended one, for turning the setting OFF when the connection is in the default session or none
// is known — the service is served in the non-default sessions only (ISO 14229-1's default, and
// blobly_emb's). Turning it ON never switches: entering the default session turns it on already,
// so in the default session there is nothing to turn on, and the ECU's refusal says so. 0 = stay.
pub fn dtc_setting_session(session u8, on bool) u8 {
	if on {
		return 0
	}
	return if session == 0 || session == default_session { u8(0x03) } else { u8(0) }
}

// Deferred is what becomes of a DTC row clicked while a press was in flight.
pub enum Deferred {
	none // nothing deferred
	wait // still in flight: ask later
	send // ask for its records now
	drop // the target changed since the click: that row was another ECU's, never asked of this one
}

// deferred_selection decides a deferred row click: asked only of the target it was clicked on
// (`clicked_key`, captured at the click), once nothing is in flight, and dropped the moment the
// selected target is another.
pub fn deferred_selection(pending bool, busy bool, clicked_key string, selected_key string) Deferred {
	if !pending {
		return .none
	}
	if clicked_key != selected_key {
		return .drop
	}
	return if busy { Deferred.wait } else { Deferred.send }
}

// CounterBatch is one refresh's batch of per-DTC 0x19 06 reads behind the table's o/a/c column.
// Extended data is stored per DTC, so a DTC the ECU has none for (NRC 0x31, or an answer that
// cannot be read) leaves only its own row empty and the batch goes on. A refusal of the SERVICE
// (not supported, not in this session, conditions not correct…) would be the same for every DTC,
// so it ends the batch — sixteen identical refusals every two seconds would hold the connection
// and say nothing more — and so does the connection failing. The batch's time is the sum of its
// exchanges, the 0x78 waits included, so its one log line says what a single request's would.
pub struct CounterBatch {
pub mut:
	read    int    // answered with extended data
	refused int    // answered with a refusal
	note    string // the first refusal, for the line
	ended   string // a refusal of the service: the batch ended here
	failed  string // the connection failed: the batch ended here
	t       Timing // every exchange summed
}

// nrc_per_dtc: a 0x19 06 negative response about THIS DTC — requestOutOfRange (0x31), which ISO
// 14229-1 answers for a DTC or record number the server does not have. Every other code is about
// the request or the service, and would be answered for every DTC alike.
pub fn nrc_per_dtc(nrc u8) bool {
	return nrc == 0x31
}

// answered records a DTC whose counters were read.
pub fn (mut b CounterBatch) answered(t Timing) {
	b.read++
	b.add(t)
}

// refusal records a DTC the ECU answered without counters: about this DTC alone (`per_dtc`) the
// batch goes on, about the service it ends.
pub fn (mut b CounterBatch) refusal(t Timing, why string, per_dtc bool) {
	b.refused++
	if b.note == '' {
		b.note = why
	}
	if !per_dtc {
		b.ended = why
	}
	b.add(t)
}

// failure records the connection failing; the batch ends.
pub fn (mut b CounterBatch) failure(t Timing, why string) {
	b.failed = why
	b.add(t)
}

// going: the next DTC is asked.
pub fn (b CounterBatch) going() bool {
	return b.failed == '' && b.ended == ''
}

// asked is how many DTCs the ECU answered, with counters or without.
pub fn (b CounterBatch) asked() int {
	return b.read + b.refused
}

// summary is why counters are missing, in words — every refusal and a failure alike, so rows a
// refusal emptied are not read as casualties of a connection that failed after them; '' = none.
pub fn (b CounterBatch) summary() string {
	mut parts := []string{}
	match b.refused {
		0 {}
		1 { parts << b.note }
		else { parts << '${b.refused} refused, the first: ${b.note}' }
	}
	if b.ended != '' {
		// the refusal that ended the batch, when it is not the first one already said
		if b.ended != b.note {
			parts << 'ended by ${b.ended}; the rest not asked'
		} else {
			parts << 'the rest not asked'
		}
	}
	if b.failed != '' {
		parts << b.failed
	}
	return parts.join('; ')
}

fn (mut b CounterBatch) add(t Timing) {
	b.t = Timing{
		sent:       b.t.sent || t.sent
		rtt_us:     b.t.rtt_us + t.rtt_us
		pending:    b.t.pending + t.pending
		pending_us: b.t.pending_us + t.pending_us
	}
}

// dtc_sig_entry is one DTC's part of a list read's signature — what the auto-refresh compares to
// decide whether it read anything new. It is what the table SHOWS of the DTC: its code, status and
// counter cell (`counters`, '' when none were read), so a counter going from absent to a present 0
// — '—' to '0' — is news, where a signature of the values alone (absent reads 0) missed it, and a
// record the table does not show is not.
pub fn dtc_sig_entry(code u32, status u8, counters string) string {
	return '${code:06X}:${status:02X}:${if counters == '' { '-' } else { counters }}'
}

// shown_status is the status byte the detail section shows: the NEWER of the list's (0x19 02,
// read at `list_ms`) and the selected DTC's own answer's (0x19 04/06, read at `detail_ms`;
// `detail_ok` false when neither was answered). A status changes as the ECU tests, so the older
// answer is the stale one, whichever it is. The second value says it is the DTC's own answer's.
pub fn shown_status(list u8, list_ms i64, detail_ok bool, detail u8, detail_ms i64) (u8, bool) {
	if detail_ok && detail_ms >= list_ms {
		return detail, true
	}
	return list, false
}

// ReadTimes is when the tab's list was last READ and last ASKED. Two times because they answer
// two questions: the auto-refresh counts its interval from the last attempt (a failing target is
// not asked every frame), while "read N s ago" over retained rows must be the last success — a
// failed refresh does not make old rows fresh.
pub struct ReadTimes {
pub:
	read_ms  i64 // the last list read that succeeded; 0 = none
	tried_ms i64 // the last one asked, succeeded or not; 0 = none
}

// read_at is the times of a read that succeeded at `now`.
pub fn read_at(now i64) ReadTimes {
	return ReadTimes{
		read_ms:  now
		tried_ms: now
	}
}

// failed is these times after a read that failed at `now`: the rows kept are as old as they were.
pub fn (r ReadTimes) failed(now i64) ReadTimes {
	return ReadTimes{
		read_ms:  r.read_ms
		tried_ms: now
	}
}

// view_writable: a holder's DTC read may publish to the tab only if the tab is still the one it
// was asked from. `epoch` moves when a project is loaded, BEFORE the old run's holder has drained
// (the rebuild waits for it after), so a list request still in flight would otherwise put the old
// project's rows back under a target key the new project may well reuse — the same interface and
// ids. A generation, not the key: the key cannot tell two projects apart.
pub fn view_writable(req_epoch u64, epoch u64) bool {
	return req_epoch == epoch
}
