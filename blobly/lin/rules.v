module lin

// The trace's rules for a LIN frame, stated once so a GUI, a recording and a script read a
// frame alike.

// origin_of is the trace's origin column: 'TX-S' published by our simulation, 'TX' by our
// tester, 'RX' by a node outside this app.
pub fn origin_of(f Frame) string {
	return match f.src {
		.sim { 'TX-S' }
		.tester { 'TX' }
		.remote { 'RX' }
	}
}

// is_bus_traffic is whether a frame shows another node alive: only an error-free response a
// remote node published, so the master's own unanswered headers never make a dead slave look
// alive.
pub fn is_bus_traffic(f Frame) bool {
	return f.event == .frame && f.src == .remote && !f.ours && f.errs == Errs.zero()
		&& f.raw.len > 0
}

// key_suffix sets a record apart from its id's good frames when grouping: an errored frame, a
// wakeup and a sleep each get their own key.
pub fn key_suffix(f Frame) string {
	return match f.event {
		.wakeup {
			'/wakeup'
		}
		.sleep {
			'/sleep'
		}
		.frame {
			if f.errs == Errs.zero() { '' } else { '/' + f.errs.names().join('+') }
		}
	}
}

// has_id is whether a record names a frame id: not a wakeup pulse, and not a header that went
// wrong before its id could be trusted (no PID read, or a PID with bad parity).
pub fn has_id(f Frame) bool {
	if f.event == .wakeup {
		return false
	}
	return f.errs.has(.no_response) || f.raw.len > 0 || f.errs == Errs.zero()
}

// reading is the one text rendering: `0x21 [4] 01 02 03 04 cs 0xA5 enhanced`, then each error
// as `!name`; a header nobody answered is `0x21 no response`, one that went wrong before its
// response `header !sync` or `pid 0x61 !parity`.
pub fn reading(f Frame) string {
	if f.event == .wakeup {
		return 'wakeup'
	}
	mut s := '0x${f.id:02X}'
	if f.errs.has(.no_response) {
		s += ' no response'
	} else if f.raw.len == 0 && f.errs != Errs.zero() {
		// A header that went wrong: no PID read (no valid PID is 0x00), or a PID not to be trusted.
		s = if f.pid == 0 { 'header' } else { 'pid 0x${f.pid:02X}' }
	} else {
		s += ' [${f.data.len}]'
		for d in f.data {
			s += ' ${d:02X}'
		}
		if !f.errs.has(.short) {
			s += ' cs 0x${f.checksum:02X} ${f.model}'
		}
	}
	if f.event == .sleep {
		s += ' sleep'
	}
	for name in f.errs.names() {
		if name != 'no_response' {
			s += ' !${name}'
		}
	}
	return s
}

// flags_text is a frame's flags as a trace's one column: its checksum model when it has a
// response, the event when it is one (`wakeup`, `sleep`), `no response`, and each error as
// `!name` — the parts of `reading` that are not the id and the bytes.
pub fn flags_text(f Frame) string {
	if f.event == .wakeup {
		return 'wakeup'
	}
	mut parts := []string{}
	if f.errs.has(.no_response) {
		parts << 'no response'
	} else if f.raw.len > 0 && !f.errs.has(.short) {
		parts << f.model.str()
	}
	if f.event == .sleep {
		parts << 'sleep'
	}
	for name in f.errs.names() {
		if name != 'no_response' {
			parts << '!${name}'
		}
	}
	return parts.join(' ')
}

// clone is the frame with its own copies of `data` and `raw`, for a reader that may keep or
// change it while another reads the same frame.
pub fn (f Frame) clone() Frame {
	return Frame{
		...f
		data: f.data.clone()
		raw:  f.raw.clone()
	}
}
