// THE DIAGNOSTICS PANEL'S HELD CONNECTION: when it is let go, when it is kept alive, and how a
// request's time is told.
//
// The panel used to open a transport per button press and close it afterwards, because a DoIP
// entity serves ONE tester connection at a time and a leaked one blocked every later press until
// the entity's idle timeout. On a real entity the reopen is the cost: measured on the bench
// sysnode, every press after the first paid 0.5–0.9 s of TCP reconnect (the entity recycling its
// one socket), and a session switched to extended had no keep-alive behind it, so it lapsed at
// the ECU's S3 between presses. So the panel now HOLDS one connection, owned by one holder thread
// in cmd/blobly_net (diag_hold.v), and these are the rules that thread asks.
//
// WHICH CENSUS BUCKET. The holder is a RUN WORKER (App.run_workers), not a tool reader: it is
// ended by Stop, and a rebuild waits for it. A tool reader is the operator's own work that may
// outlive Stop and that the rebuild must not wait for; a held connection is the opposite — it
// talks to an entity the run may itself host, over a tap opened against the run's wires, and the
// next run (or project) must find the entity free rather than held by a connection nobody shows.
// Counted as a tool reader it would also outlive Stop as "1 background worker still using this
// project" for as long as it stayed open, refusing the DBC editor with nothing to stop.
//
// WHAT "HELD" MEANS PER CARRIER. On DoIP it is the TCP connection, routing activation done —
// the open is what costs. On CAN it is the target, its session and its keep-alive: the ISO-TP
// channel is opened on a tap for each exchange and closed after it, because an idle subscriber is
// not free (on a shared-hub wire — PCAN, CANsub — a cursor nobody reads falls behind the ring and
// is booked as the wire's own loss) and the open costs well under a millisecond.
//
// ANOTHER TOOL ON THE SAME ENTITY. In the GUI only a Lua script can open a DoIP entity
// (uds.open / flash.program), and which one is decided inside the script, so "the same entity"
// is unknowable before it runs. The rule is therefore the simple one that is correct whatever
// the script does: while an operator tool that speaks UDS is running (a script, a flash), the
// panel holds NOTHING — the tool's start releases the held connection and waits for it to close
// (and for a press already queued), and the panel's own presses meanwhile open and close per
// request, as they always did. A program OUTSIDE this process cannot be asked: while the panel
// holds a DoIP entity's one connection, another tester is refused until Disconnect — the strip
// says so.
//
// DEPENDENCY-FREE, like the other rule packages: CI runs `v test cmd/blobly_net/diaghold/` with
// no `-path modules`.
module diaghold

// keepalive_ms is the tester-present period while a non-default session is held: below ISO
// 14229-2's default S3server of 5000 ms with room for a carrier's latency.
pub const keepalive_ms = 2000

// keepalive_wait_ms is how long a keep-alive listens for a refusal before calling the quiet a
// success. Not the client's P2 (a second or more): a suppressed request has no positive answer to
// wait for, and the holder serves presses on the same thread, so a P2-long listen would put a
// press behind every keep-alive. A refusal later than this is taken off the connection by the
// next exchange's pre-send drain and is not seen: the stated limit, for a server slower than
// 200 ms to refuse a tester-present.
pub const keepalive_wait_ms = 200

// default_session is DiagnosticSessionControl's defaultSession, which needs no keep-alive.
pub const default_session = u8(0x01)

// Conn is the held connection's state, as the panel's strip shows it.
pub enum Conn {
	closed
	opening
	held
	failed
}

pub fn (c Conn) str() string {
	return match c {
		.closed { 'closed' }
		.opening { 'opening' }
		.held { 'held' }
		.failed { 'failed' }
	}
}

// Release is why the holder lets its connection go — `keep` when it does not.
pub enum Release {
	keep
	run_ended
	disconnect
	tool
	panel_closed
	deselected
}

// words is the reason as the strip and the log say it.
pub fn (r Release) words() string {
	return match r {
		.keep { '' }
		.run_ended { 'the measurement stopped' }
		.disconnect { 'disconnected' }
		.tool { 'released for a script or flash' }
		.panel_closed { 'the panel was closed' }
		.deselected { 'another target was selected' }
	}
}

// View is what the holder knows when it asks: the target it holds and what the panel and the run
// say now.
pub struct View {
pub:
	held_key     string // '' when nothing is held
	selected_key string
	panel_open   bool
	run_live     bool
	disconnect   bool // the operator pressed Disconnect
	tool_running bool // a script or flash is running
}

// release decides whether a held connection is let go, and why. Nothing held is `keep`: there
// is nothing to let go. The ORDER is the order of the reasons' reach — a run that has ended
// overrules everything, an explicit Disconnect is said as such even when the panel also closed.
pub fn release(v View) Release {
	if v.held_key == '' {
		return .keep
	}
	if !v.run_live {
		return .run_ended
	}
	if v.disconnect {
		return .disconnect
	}
	if v.tool_running {
		return .tool
	}
	if !v.panel_open {
		return .panel_closed
	}
	if v.selected_key != v.held_key {
		return .deselected
	}
	return .keep
}

// keepalive_due says whether the holder sends tester-present (3E 80) now. Only while a
// connection is held in a session a 0x10 answer established and that is not the default one —
// the default session has no S3 to lapse, and an unknown one (nothing answered 0x10 on this
// connection yet) is not ours to guess. `last_ms` is the last time anything went to the ECU,
// since any request restarts S3, not only a tester-present.
pub fn keepalive_due(held bool, session u8, last_ms i64, now_ms i64) bool {
	if !held || session == 0 || session == default_session {
		return false
	}
	return now_ms - last_ms >= keepalive_ms
}

// session_name is a DiagnosticSessionControl session as the strip names it; 0 is unknown (no
// 0x10 answered on this connection).
pub fn session_name(s u8) string {
	return match s {
		0 { '—' }
		0x01 { 'default' }
		0x02 { 'programming' }
		0x03 { 'extended' }
		0x04 { 'safety' }
		else { '0x${s:02X}' }
	}
}

// Timing is one request's time, as the uds and doip modules measured it.
pub struct Timing {
pub:
	sent       bool // false: it failed before the send, and there is no round trip to tell
	rtt_us     i64 // send to final answer
	pending    int // 0x78 responsePending answers waited through
	pending_us i64 // from the first 0x78 to the final answer
}

// prefix is the log line's leading column: the round trip, and the pending wait when there was
// one. Fixed width for the common case so a column of presses lines up.
pub fn (t Timing) prefix() string {
	if !t.sent {
		return '[not sent]'
	}
	ms := ms_text(t.rtt_us)
	if t.pending > 0 {
		return '[${ms:6} ms, 0x78 ×${t.pending} for ${ms_text(t.pending_us)} ms]'
	}
	return '[${ms:6} ms]'
}

// Open is what opening a connection cost. A DoIP open is a TCP connect and a routing activation,
// told apart; an ISO-TP open on a tap has neither, only its total.
pub struct Open {
pub:
	doip        bool
	total_us    i64
	connect_us  i64
	activate_us i64
}

// line is the log line an open writes, before the request it was made for.
pub fn (o Open) line(where string) string {
	ms := ms_text(o.total_us)
	if o.doip {
		return '[${ms:6} ms] opened ${where}: connect ${ms_text(o.connect_us)} ms, routing activation ${ms_text(o.activate_us)} ms'
	}
	return '[${ms:6} ms] opened ${where}'
}

// ms_text is microseconds as milliseconds to one decimal.
pub fn ms_text(us i64) string {
	return '${f64(us) / 1000.0:.1f}'
}

// retry_on_reopen says whether a failed request is repeated once on a fresh connection: only a
// DoIP connection (an entity closes an idle one; a CAN target holds no channel between exchanges
// to go stale), only one held from an earlier press (a fresh one that fails has nothing newer to
// offer), only when the request never went out (the pre-send drain found the connection gone),
// so the ECU is never asked twice — and never for a negative response, which is the ECU answering.
pub fn retry_on_reopen(doip bool, held_before bool, sent bool, negative bool) bool {
	return doip && held_before && !sent && !negative
}
