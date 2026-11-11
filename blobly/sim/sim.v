// sim — the simulation engine: simulated ECUs (nodes) that send/receive frames
// on a network per its database, driving signals from generators and answering
// requests. GUI-free and deterministic: the engine produces frames for a given
// logical time, so it can run live (real clock) or be unit-tested step-by-step.
//
// An ECU "owns" the messages whose DBC transmitter is its name
// (candb.Database.messages_from). Cyclic messages (GenMsgCycleTime) are sent on a
// period; request/response is expressed as rules. Behaviour is declarative —
// per-signal value generators (const/sine/sawtooth/counter/stepmod) — with a
// scripting layer left for later.
module sim

import math
import time
import blobly.candb
import blobly.j1939
import blobly.project
import blobly.transport

// Gen is a signal value generator. Fields are reused per kind (see constructors).
pub struct Gen {
pub:
	kind   string // 'const' | 'sine' | 'sawtooth' | 'counter' | 'stepmod'
	offset f64    // const value / sine bias / saw min / counter start / step base
	amp    f64    // sine amplitude / saw max / step count
	freq   f64    // sine ω (rad/s·t) / saw+step period (s)
	phase  f64    // sine phase (rad)
	step   f64 = 1.0 // counter increment per send
	modulo f64    // counter wrap (0 = none)
}

pub fn gen_const(v f64) Gen {
	return Gen{ kind: 'const', offset: v }
}

// gen_sine: offset + amp*sin(freq*t + phase).
pub fn gen_sine(offset f64, amp f64, freq f64, phase f64) Gen {
	return Gen{ kind: 'sine', offset: offset, amp: amp, freq: freq, phase: phase }
}

// gen_sawtooth: ramps min→max over `period` seconds, repeating.
pub fn gen_sawtooth(min f64, max f64, period f64) Gen {
	return Gen{ kind: 'sawtooth', offset: min, amp: max, freq: period }
}

// gen_counter: start + step*sendCount, optionally wrapped at modulo.
pub fn gen_counter(start f64, step f64, modulo f64) Gen {
	return Gen{ kind: 'counter', offset: start, step: step, modulo: modulo }
}

// gen_stepmod: base + (floor(t/period) mod count) — a staircase (gears, flags).
pub fn gen_stepmod(period f64, count f64, base f64) Gen {
	return Gen{ kind: 'stepmod', offset: base, amp: count, freq: period }
}

// follows_time is whether the generator's value moves with time on its own (sine, sawtooth,
// stepmod): what can start a change send. A const never changes, and a counter moves only with a
// send, so neither starts one.
pub fn (g Gen) follows_time() bool {
	return g.kind in ['sine', 'sawtooth', 'stepmod']
}

// value evaluates the generator at time t (seconds) for send index n.
pub fn (g Gen) value(t f64, n int) f64 {
	return match g.kind {
		'sine' { g.offset + g.amp * math.sin(g.freq * t + g.phase) }
		'sawtooth' {
			frac := t / g.freq - math.floor(t / g.freq)
			g.offset + (g.amp - g.offset) * frac
		}
		'counter' {
			v := g.offset + g.step * f64(n)
			if g.modulo > 0 { v - math.floor(v / g.modulo) * g.modulo } else { v }
		}
		'stepmod' {
			s := math.floor(t / g.freq)
			g.offset + (s - math.floor(s / g.amp) * g.amp)
		}
		else { g.offset } // 'const'
	}
}

// SimSignal binds a DBC signal name to a generator.
pub struct SimSignal {
pub:
	name string
	gen  Gen
}

// SimMessage is one message an ECU sends: the DBC definition + a generator per
// signal + a cyclic period (0 = event/response-driven, not auto-sent).
pub struct SimMessage {
pub mut:
	msg       candb.Message
	period_ms int
	signals   []SimSignal
	e2e       []E2e // alive counter + checksum per window, stamped after the generators (see e2e.v)
	fault     Fault // deliberate misbehaviour (see fault.v)
	set       []SetValue // signals a script holds at a value, over the generators (see setsignal.v)
	send_n    int   // times sent so far (drives signal generators)
	// The E2E alive counter's own index, separate from send_n. freeze_counter must stall the
	// PROTECTION counter without also stalling every `counter` generator in the message — a
	// message can carry both an alive counter and an unrelated application counter, and
	// freezing the second is behaviour nobody asked for.
	// `e2e_n` is the NEXT counter value to use; `last_e2e` is the one actually transmitted.
	//
	// Keeping both removes the freeze transition state entirely. A frozen frame simply re-sends
	// last_e2e and leaves e2e_n alone, so:
	//   - freezing repeats the last value IMMEDIATELY, instead of advancing once more first
	//     (a one-frame timed freeze used to change nothing at all);
	//   - recovery needs no flag, because e2e_n was never consumed during the freeze — which
	//     also means nothing to lose when the engine is rebuilt mid-fault.
	e2e_n    int
	last_e2e int
	has_tx   bool // whether last_e2e means anything yet
	// per window group, the frames a freeze naming that window held it back: the window carries
	// the shared counter less its lag, so it resumes one step past what it repeated
	lag map[string]int
	next_ms  f64  // next due time
	last_t   f64  // when due_frames last handed a frame of it out (s): what its generators read
	last_n   int = -1 // that frame's send index; -1 = none handed out (all dropped, or not due yet)
	last_set  []SetValue // the values set when that frame was built
	last_data []u8 // that frame's payload: which signals it carried (candb.Message.carried)
	ev       ChangeState // sending on a change (the send type event or mixed, Message.on_change)
}

// ChangeState is where a message sent on a change stands: the raw values its time-driven
// generators gave when last looked at, how many sends a change still owes, the earliest the next
// of them may go, and the earliest any send of it may go by its GenMsgDelayTime after the last (ms).
pub struct ChangeState {
pub mut:
	raws    []u64
	seen    bool
	left    int
	next_ms f64
	hold_ms f64
}

// e2e_value is the counter this frame should carry: the last transmitted one while every window is
// frozen, so the stall begins with the very first faulted frame rather than after one more advance.
pub fn (m SimMessage) e2e_value() int {
	if m.fault.kind == .freeze_ctr && m.fault.group == '' && m.has_tx {
		return m.last_e2e
	}
	return m.e2e_n
}

// e2e_value_for is the counter window `w` carries in this frame: e2e_value less the window's lag,
// or the value it carried last while a freeze naming it holds it.
pub fn (m SimMessage) e2e_value_for(w E2e) int {
	if m.fault.kind == .freeze_ctr && m.fault.group != '' && m.fault.holds(w) && m.has_tx {
		return m.last_e2e - m.lag[w.group]
	}
	return m.e2e_value() - m.lag[w.group]
}

// stamp_e2e stamps every window's counter and checksum onto `data`.
fn (m SimMessage) stamp_e2e(mut data []u8) {
	for w in m.e2e {
		w.apply(m.msg, mut data, m.e2e_value_for(w))
	}
}

// advance_e2e records what was just sent and moves the counter on — unless frozen, in which
// case e2e_n is left untouched so recovery resumes exactly one step later with no flag to keep.
// A freeze of one window moves the counter on and that window's lag with it, so it keeps its value.
pub fn (mut m SimMessage) advance_e2e() {
	if m.fault.kind == .freeze_ctr && m.fault.group != '' && m.has_tx {
		for w in m.e2e {
			if m.fault.holds(w) {
				m.lag[w.group] = m.lag[w.group] + 1
			}
		}
	}
	v := m.e2e_value()
	m.last_e2e = v
	m.has_tx = true
	// ALWAYS one past what was sent. The freeze lives in e2e_value (which re-sends last_e2e),
	// not here: leaving the pointer unadvanced meant the first recovered frame repeated the
	// frozen value all over again.
	m.e2e_n = v + 1
}

// sends is whether the node sends the message on its own: on its cycle, or where its send type
// sends on a change, on a change of a generator of it that moves with time (step_change).
pub fn (m SimMessage) sends() bool {
	return m.period_ms > 0 || (m.msg.on_change() && m.signals.any(it.gen.follows_time()))
}

// change_raws is the raw value each generator that moves with time (Gen.follows_time) gives its
// signal at time t (s): what a change is a change of.
fn (m SimMessage) change_raws(t f64) []u64 {
	mut out := []u64{cap: m.signals.len}
	for s in m.signals {
		if !s.gen.follows_time() {
			continue
		}
		mut raw := u64(0)
		for sig in m.msg.signals {
			if sig.name == s.name {
				raw = sig.raw_from_phys(s.gen.value(t, 0))
				break
			}
		}
		out << raw
	}
	return out
}

// build encodes the message's signals at time t into a CAN frame, over the payload the node starts
// from (candb.Message.initial: a signal no generator drives at its start value, else raw 0).
pub fn (mut m SimMessage) build(t f64) transport.CanFrame {
	mut switch_raw := ?u64(none)
	sw := m.msg.multiplexor_index()
	if sw >= 0 {
		for s in m.signals {
			if s.name == m.msg.signals[sw].name {
				switch_raw = m.msg.signals[sw].raw_from_phys(s.gen.value(t, m.send_n))
			}
		}
	}
	mut data := m.msg.initial(switch_raw)
	for s in m.signals {
		for sig in m.msg.signals {
			if sig.name == s.name {
				sig.encode(mut data, s.gen.value(t, m.send_n))
				break
			}
		}
	}
	// values set from a script, over the generators and under protection, so the checksum covers them
	apply_set(m.msg, m.set, mut data)
	// An out-of-range value goes in BEFORE protection, so the frame arrives with a valid
	// checksum and the receiver reaches its range handling instead of rejecting a CRC error.
	m.fault.apply_pre(m.msg, mut data)
	// End-to-end protection goes over the finished payload — the counter and checksum have to
	// reflect what is actually on the wire, including every generator's contribution.
	m.stamp_e2e(mut data)
	f := transport.CanFrame{
		id:       m.msg.id
		extended: m.msg.ext
		data:     data
	}
	// the format its database states for it (#607); none, or one the payload cannot take, leaves
	// it to the row
	return project.declared_format(m.msg).stamp(f) or { f }
}

// ResponseRule: when a frame with id `req_id` arrives, reply with `resp_id`
// carrying the request payload with `add` added to byte `byte_index` (mod 256).
pub struct ResponseRule {
pub:
	req_id     u32
	resp_id    u32
	resp_ext   bool
	byte_index int
	add        u8
}

// SimEcu is a simulated node: the messages it sends + its response rules.
pub struct SimEcu {
pub mut:
	name     string
	messages []SimMessage
	rules    []ResponseRule
	nm_tx    []NmTx // its NM announcement, when it announces (nm_tx.v)
}

// Engine drives a set of ECUs against a logical clock.
pub struct Engine {
pub mut:
	ecus []SimEcu
	// the wire and row its frames go out on (transmit sets them), which decide whether a J1939
	// message's frame goes out classic and so as a BAM
	iface string
	row   string
	// the BAMs in progress, a transfer at a time per source address (j1939.Pacer), each tagged
	// with the frame it carries (tp_sent), which becomes its message's last sent once whole
	tp j1939.Pacer
	// the RTS/CTS connections its nodes send (one per source and destination), and the ones it
	// answers for the addresses its nodes' J1939 messages are sent from
	conns   []j1939.Originator
	answers j1939.Responder
	// the clock of the last step, which on_frame reads
	now_ms f64
	// why a message is never sent, said once per message (take_notes), and which were said
	notes []string
	said  map[string]bool
mut:
	tp_sent map[int]LastSent
	tp_next int
}

// LastSent is a message's frame as step built it: whose, and when (s), its send index, the values
// set and its payload — what its message's `last_t`/`last_n`/`last_set`/`last_data` become once
// the frame is on the wire.
struct LastSent {
	ecu  string
	msg  string
	t    f64
	n    int
	set  []SetValue
	data []u8
}

// carried is a new engine, with no ECUs, carrying e's transfers in progress (its BAMs, the
// connections it sends and answers) and what it has said, so a rebuild neither cuts a transfer
// short on the wire nor says a note again.
pub fn (e Engine) carried() Engine {
	return Engine{
		tp:      e.tp
		tp_sent: e.tp_sent
		tp_next: e.tp_next
		conns:   e.conns
		answers: e.answers
		said:    e.said
	}
}

// take_notes is what the engine has to say since it was last asked: a message it never sends, a
// connection that did not complete (once per message and outcome).
pub fn (mut e Engine) take_notes() []string {
	out := e.notes
	e.notes = []
	return out
}

// Carry is what an engine rebuild carries over, kept by the caller for the whole run: each
// message's counters, and where a message sent on a change stands (a burst's remaining
// repetitions, its delay boundary).
pub struct Carry {
pub mut:
	counters map[string]int
	changes  map[string]ChangeState
}

// save_state / restore_state carry alive counters and change-send state across an engine
// rebuild, through a Carry the caller owns and keeps for the whole run.
//
// Toggling ONE ECU's checkbox rebuilds the WHOLE engine. Without this, every other protected
// message restarts its counter at zero at that moment, and a receiver checking the sequence
// rejects the next frame from an ECU nobody touched — a fault injected by using the panel.
//
// The cache has to outlive the engine, not just the previous one: disabling an ECU removes it
// from the engine entirely, so carrying state from `prev` alone lost it, and re-enabling
// restarted the counter at zero — a BACKWARD jump, which is exactly what a sequence check is
// looking for. A node switched off and on again resumes where it stopped.
//
// Keyed by ECU and message NAME, so it survives index shifts. A message with no cached entry
// keeps its zero, which is correct: it has genuinely not been sent.
pub fn (e Engine) save_state(mut c Carry) {
	// change-send state only of the ECUs in this engine: a node switched off and on again starts
	// from its values then, not from a burst it was in when it left
	c.changes = map[string]ChangeState{}
	for ecu in e.ecus {
		for m in ecu.messages {
			c.counters['${ecu.name}|${m.msg.name}'] = m.send_n
			c.counters['e2e|${ecu.name}|${m.msg.name}'] = m.e2e_n
			c.counters['e2elast|${ecu.name}|${m.msg.name}'] = if m.has_tx { m.last_e2e } else { -1 }
			if m.ev.seen {
				c.changes['${ecu.name}|${m.msg.name}'] = m.ev
			}
			for g, n in m.lag {
				c.counters['e2elag|${ecu.name}|${m.msg.name}|${g}'] = n
			}
		}
	}
}

pub fn (mut e Engine) restore_state(c Carry) {
	from := c.counters
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].messages.len; j++ {
			if ev := c.changes['${e.ecus[i].name}|${e.ecus[i].messages[j].msg.name}'] {
				e.ecus[i].messages[j].ev = ev
			}
			if n := from['${e.ecus[i].name}|${e.ecus[i].messages[j].msg.name}'] {
				e.ecus[i].messages[j].send_n = n
			}
			if n := from['e2e|${e.ecus[i].name}|${e.ecus[i].messages[j].msg.name}'] {
				e.ecus[i].messages[j].e2e_n = n
			}
			// the transmitted value too: a rebuild mid-freeze that kept only the NEXT counter
			// left the frozen value unknown, and the frame after recovery repeated it
			if n := from['e2elast|${e.ecus[i].name}|${e.ecus[i].messages[j].msg.name}'] {
				if n >= 0 {
					e.ecus[i].messages[j].last_e2e = n
					e.ecus[i].messages[j].has_tx = true
				}
			}
			for w in e.ecus[i].messages[j].e2e {
				if n := from['e2elag|${e.ecus[i].name}|${e.ecus[i].messages[j].msg.name}|${w.group}'] {
					e.ecus[i].messages[j].lag[w.group] = n
				}
			}
		}
	}
}

// all_due_by_ms is when every cyclic message of a freshly built engine has been due at least
// once: its latest first due time (GenMsgStartDelayTime), 0 with none.
pub fn (e Engine) all_due_by_ms() f64 {
	mut by := 0.0
	for ecu in e.ecus {
		for m in ecu.messages {
			if m.period_ms > 0 && m.next_ms > by {
				by = m.next_ms
			}
		}
	}
	return by
}

// due_frames advances every cyclic message whose period has elapsed by now_ms and
// returns the frames to transmit (also bumping send counters / next-due times). A frame returned
// is taken as sent; a caller whose transport can refuse uses step.
pub fn (mut e Engine) due_frames(now_ms f64) []transport.CanFrame {
	mut out := &FrameBox{}
	e.step(now_ms, fn [mut out] (f transport.CanFrame) bool {
		out.frames << f
		return true
	})
	return out.frames
}

// FrameBox collects frames from inside a closure, which captures by value.
@[heap]
struct FrameBox {
mut:
	frames []transport.CanFrame
}

// step advances every cyclic message whose period has elapsed by now_ms, handing each frame due to
// `send`, which says whether the transport took it (a message on the id its node announces NM on
// is that announcement's, nm_tx.v, and is not sent besides it): only a frame taken — for a BAM, its
// every frame — is the message's LAST SENT (`last_t`/`last_n`/`last_set`/`last_data`, what a
// described server's live DID reads), so a frame refused — a listen-only wire, a bus that is down —
// or dropped by a fault leaves it as it was.
pub fn (mut e Engine) step(now_ms f64, send fn (f transport.CanFrame) bool) {
	e.now_ms = now_ms
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].messages.len; j++ {
			mut m := &e.ecus[i].messages[j]
			if e.ecus[i].announces(m.msg.id, m.msg.ext) {
				continue
			}
			if m.period_ms > 0 && now_ms + 1e-6 >= m.next_ms && now_ms + 1e-6 >= m.ev.hold_ms {
				m.emit(now_ms, mut e, e.ecus[i].name, send)
				m.next_ms += f64(m.period_ms)
				if m.next_ms <= now_ms {
					m.next_ms = now_ms + f64(m.period_ms)
				}
			}
			m.step_change(now_ms, mut e, e.ecus[i].name, send)
		}
	}
	e.step_nm(now_ms, send)
	t0 := time.sys_mono_now()
	for d in e.tp.take(now_ms) {
		sent := send(d.frame)
		if e.tp.settle(d, sent, j1939.returned_ms(now_ms, t0)) {
			if last := e.tp_sent[d.tag] {
				e.record_sent(last)
			}
		}
		if !e.tp.has(d.tag) {
			e.tp_sent.delete(d.tag)
		}
	}
	// a transfer replaced while waiting, or dropped, carries no frame any more
	if e.tp_sent.len > e.tp.pending() {
		for tag in e.tp_sent.keys() {
			if !e.tp.has(tag) {
				e.tp_sent.delete(tag)
			}
		}
	}
	// connections past their wait are aborted, and so are the ones it answers whose packets stopped
	for k := 0; k < e.conns.len; k++ {
		out := e.conns[k].poll(now_ms)
		for f in out.frames {
			send(f)
		}
		if out.end != .open {
			e.conn_ended(e.conns[k], out)
			e.conns.delete(k)
			k--
		} else {
			e.conns[k].take_lane(time.sys_mono_now())
		}
	}
	for f in e.answers.poll(now_ms) {
		send(f)
	}
}

// record_sent makes `last` its message's last sent, unless a later frame of it already is.
fn (mut e Engine) record_sent(last LastSent) {
	for mut ecu in e.ecus {
		if ecu.name != last.ecu {
			continue
		}
		for mut m in ecu.messages {
			if m.msg.name == last.msg && last.n > m.last_n {
				m.last_t = last.t
				m.last_n = last.n
				m.last_set = last.set
				m.last_data = last.data
				return
			}
		}
	}
}

// emit builds the message's frame at now_ms and hands it to `send` through the engine `e` it
// belongs to, as ECU `ecu`'s (Engine.emit: one frame, or a J1939 message's BAM on the engine's
// pacer, which makes it the last sent once whole).
fn (mut m SimMessage) emit(now_ms f64, mut e Engine, ecu string, send fn (f transport.CanFrame) bool) {
	mut f := m.build(now_ms / 1000.0)
	if m.fault.apply_post(m.msg, m.e2e, mut f.data) && e.emit(f, m.msg, send, LastSent{
		ecu:  ecu
		msg:  m.msg.name
		t:    now_ms / 1000.0
		n:    m.send_n
		set:  m.set
		data: f.data
	}) {
		m.last_t = now_ms / 1000.0
		m.last_n = m.send_n
		m.last_set = m.set
		m.last_data = f.data
	}
	m.send_n++ // generators keep running: a drop is a lost frame, not a stopped ECU
	// The PROTECTION counter is what freezes. A dropped frame still advances it, so
	// recovery shows a gap rather than a stall — the difference a receiver uses to
	// tell a lost frame from a stuck sender.
	m.advance_e2e()
	if m.msg.on_change() {
		m.ev.hold_ms = now_ms + f64(m.msg.delay_ms)
	}
}

// change_gap_ms is the least time between two change sends of a message whose file states
// neither GenMsgCycleTimeFast nor GenMsgDelayTime: the rate a changing generator is sent at,
// rather than the simulation loop's.
pub const change_gap_ms = 10

// step_change sends a message whose send type is event or mixed when a generator that moves with
// time changes the raw value of one of its signals (a counter moving with a send is no change): 1 + its repetitions times, the repetitions a fast cycle apart, no
// send of it (a cyclic one of a mixed message included) closer than the delay to the one before,
// change_gap_ms apart where the file states neither, none before its start delay. The values when
// first looked at are where it starts, not a change.
fn (mut m SimMessage) step_change(now_ms f64, mut e Engine, ecu string, send fn (f transport.CanFrame) bool) {
	if !m.msg.on_change() || !m.signals.any(it.gen.follows_time())
		|| now_ms + 1e-6 < f64(m.msg.start_delay_ms) {
		return
	}
	raws := m.change_raws(now_ms / 1000.0)
	if !m.ev.seen {
		m.ev.seen = true
		m.ev.raws = raws
	} else if raws != m.ev.raws {
		m.ev.raws = raws
		m.ev.left = 1 + m.msg.repetitions
	}
	if m.ev.left <= 0 || now_ms + 1e-6 < m.ev.next_ms || now_ms + 1e-6 < m.ev.hold_ms {
		return
	}
	m.emit(now_ms, mut e, ecu, send)
	m.ev.left--
	mut gap := if m.ev.left > 0 { m.msg.cycle_fast_ms } else { 0 }
	if gap <= 0 && m.msg.delay_ms <= 0 {
		gap = change_gap_ms
	}
	m.ev.next_ms = now_ms + f64(gap)
}

// loop_wait_ms is the longest a simulation loop's receive waits when nothing is due sooner: how
// late it sees a stop or an injected fault.
pub const loop_wait_ms = 5

// since_ms is the time since `t0_ns` on the monotonic clock (time.sys_mono_now), in ms — the
// clock a simulation loop runs its engine on, since time.ticks() is the 15.6 ms tick on Windows.
pub fn since_ms(t0_ns u64) f64 {
	return f64(time.sys_mono_now() - t0_ns) / 1e6
}

// next_due_ms is when the engine's next cyclic message, a change send's next repetition or NM
// announcement is due on its clock, or none. A released announcement is not due: it sends nothing
// until a request.
pub fn (e &Engine) next_due_ms() ?f64 {
	mut next := 0.0
	mut any := false
	for ecu in e.ecus {
		for m in ecu.messages {
			// a send is held back to its delay after the one before (ChangeState.hold_ms)
			if m.period_ms > 0 {
				due := math.max(m.next_ms, m.ev.hold_ms)
				if !any || due < next {
					next = due
					any = true
				}
			}
			if m.ev.left > 0 {
				due := math.max(m.ev.next_ms, m.ev.hold_ms)
				if !any || due < next {
					next = due
					any = true
				}
			}
		}
		for t in ecu.nm_tx {
			if !t.released && (!any || t.next_ms < next) {
				next = t.next_ms
				any = true
			}
		}
	}
	if !any {
		return none
	}
	return next
}

// recv_wait_ms is how long a simulation loop's receive may wait at now_ms: until the next due
// message (rounded up, so the pass after it finds the message due), at most loop_wait_ms.
pub fn (e &Engine) recv_wait_ms(now_ms f64) int {
	next := e.next_due_ms() or { return loop_wait_ms }
	if next <= now_ms {
		return 0
	}
	wait := math.ceil(next - now_ms)
	return if wait < loop_wait_ms { int(wait) } else { loop_wait_ms }
}

// serve_pass is one turn of the simulation loop of project row `row`, started at `t0_ns`
// (time.sys_mono_now): the injected faults, what is due sent, then a receive bounded by the next
// due message, answering the request it brings — the one body the GUI's and the headless
// runner's loops run each pass.
pub fn serve_pass(mut e Engine, mut bus transport.Bus, t0_ns u64, iface string, row int, chan_name string) {
	// re-stamped every pass, so a fault a script injects mid-run takes effect on the next frame
	apply_injected(iface, mut e)
	transmit(mut e, mut bus, since_ms(t0_ns), iface, row, chan_name)
	if frame := bus.recv(e.recv_wait_ms(since_ms(t0_ns))) {
		for resp in e.on_frame(frame) {
			bus.send(resp) or {}
		}
	}
}

// emit hands message `msg`'s frame `f` to `send` as one frame, or — j1939.message_frames: a
// message declared J1939 of more than 8 bytes going out classic — queues its BAM on the engine's
// pacer, whose frames `step` hands on bam_gap_ms apart, `last` becoming the message's last sent
// once the whole BAM is out (record_sent), or — to one node — opens its RTS/CTS connection
// (connect). True for the one frame sent or a connection opened; false for a frame refused, a BAM
// queued, or a message neither one frame nor the transport protocol carries, which is said once
// (take_notes).
fn (mut e Engine) emit(f transport.CanFrame, msg candb.Message, send fn (f transport.CanFrame) bool, last LastSent) bool {
	out := transport.framed_for_wire(e.iface, transport.CanFrame{ ...f, row: e.row })
	if j1939.needs_connection(f, msg.j1939, out.fd) {
		return e.connect(f, msg, send)
	}
	frames := j1939.message_frames(f, msg.j1939, out.fd) or {
		e.say_once('${msg.name}/${msg.id}', '${msg.name} is never sent: ${err.msg()}')
		return false
	}
	if frames.len == 1 {
		return send(frames[0])
	}
	e.tp_next++
	e.tp_sent[e.tp_next] = last
	e.tp.add(e.iface, frames, e.tp_next)
	return false
}

// connect opens message `msg`'s RTS/CTS connection for frame `f`: its RTS handed to `send`, the
// rest driven by the frames on_frame reads and timed by step — or, aimed at an address another of
// its own nodes answers for, carried through at once (with_local), every frame still handed to
// `send`. False — the period's message not sent — while a connection between the same two
// addresses is still going on, here or by another sender in this process (its lane).
fn (mut e Engine) connect(f transport.CanFrame, msg candb.Message, send fn (f transport.CanFrame) bool) bool {
	id := j1939.decompose(f.id)
	if e.conns.any(it.sa == id.sa && it.da == id.da()) {
		return false
	}
	mut o := j1939.connection_for(f, e.iface, 0) or {
		e.say_once('${msg.name}/${msg.id}', '${msg.name} is never sent: ${err.msg()}')
		return false
	}
	o.tag = msg.name
	if !o.take_lane(time.sys_mono_now()) {
		return false
	}
	rts := o.start(e.now_ms).frames
	if !send(rts[0]) {
		o.free_lane(time.sys_mono_now())
		return false
	}
	e.conns << o
	for fr in e.with_local(rts)[1..] {
		send(fr)
	}
	return true
}

// with_local is `frames`, which the engine sends, each followed in turn by what its own
// connections make of it (j1939_frame): its own frames never come back to it off the wire, so a
// connection between two of its nodes is carried here, frame by frame in wire order.
fn (mut e Engine) with_local(frames []transport.CanFrame) []transport.CanFrame {
	mut q := frames.clone()
	for i := 0; i < q.len; i++ {
		q << e.j1939_frame(q[i])
	}
	return q
}

// conn_ended lets a finished connection's lane go and says, once per message and outcome, one
// that did not complete.
fn (mut e Engine) conn_ended(o j1939.Originator, out j1939.ConnOut) {
	o.free_lane(time.sys_mono_now())
	if out.end != .done {
		e.say_once('${o.tag}/${o.pgn}/${out.end}', '${o.tag}: ${out.detail}')
	}
}

// end_connections aborts (reason 250) every RTS/CTS connection the engine sends or answers, each
// abort handed to `send`, and lets their lanes go: for a loop that is ending with the engine.
pub fn (mut e Engine) end_connections(send fn (f transport.CanFrame) bool) {
	for mut o in e.conns {
		for f in o.stop().frames {
			send(f)
		}
		o.free_lane(time.sys_mono_now())
	}
	e.conns = []
	for f in e.answers.stop() {
		send(f)
	}
}

// say_once notes `text` the first time `key` is said.
fn (mut e Engine) say_once(key string, text string) {
	if !e.said[key] {
		e.said[key] = true
		e.notes << text
	}
}

// j1939_frame is what the RTS/CTS connections make of a received frame: the packets a CTS clears
// for one this engine sends, and the answers to one aimed at an address its nodes send from.
fn (mut e Engine) j1939_frame(f transport.CanFrame) []transport.CanFrame {
	if !f.extended || f.rtr {
		return []
	}
	p := j1939.pgn(f.id)
	if p != j1939.pgn_tp_cm && p != j1939.pgn_tp_dt {
		return []
	}
	mut out := []transport.CanFrame{}
	for k := 0; k < e.conns.len; k++ {
		step := e.conns[k].feed(f, e.now_ms)
		out << step.frames
		if step.end != .open {
			e.conn_ended(e.conns[k], step)
			e.conns.delete(k)
			k--
		}
	}
	e.answers.addresses = e.j1939_addresses()
	out << e.answers.feed(f, e.now_ms)
	return out
}

// j1939_addresses is every source address its nodes send a J1939 message from.
fn (e &Engine) j1939_addresses() []u8 {
	mut out := []u8{}
	for ecu in e.ecus {
		for m in ecu.messages {
			if m.msg.j1939 && m.msg.ext && u8(m.msg.id & 0xFF) !in out {
				out << u8(m.msg.id & 0xFF)
			}
		}
	}
	return out
}

// transmit sends what is due on `bus` from the engine of project row `row` and publishes what a
// described server's live DIDs read, each pass of serve_pass.
pub fn transmit(mut e Engine, mut bus transport.Bus, now_ms f64, iface string, row int, chan_name string) {
	e.iface = iface
	e.row = chan_name
	apply_nm_requests(iface, row, mut e)
	e.step(now_ms, fn [mut bus] (f transport.CanFrame) bool {
		bus.send(f) or { return false }
		return true
	})
	publish_live(iface, chan_name, e)
}

// run_for drives the engine live on a bus for duration_ms: it transmits due
// cyclic frames against the wall clock and answers received requests. Used by
// the smoke tool and (later) the GUI's measurement thread. The bus should be a
// dedicated instance for this node (so it doesn't hear its own sends).
pub fn (mut e Engine) run_for(mut bus transport.Bus, duration_ms int) {
	t0 := time.sys_mono_now()
	for since_ms(t0) < f64(duration_ms) {
		for f in e.due_frames(since_ms(t0)) {
			bus.send(f) or {}
		}
		if frame := bus.recv(e.recv_wait_ms(since_ms(t0))) {
			for resp in e.on_frame(frame) {
				bus.send(resp) or {}
			}
		}
	}
}

// on_frame returns the response frames triggered by a received frame: a response rule's, and the
// transport protocol's (j1939_frame) — a CTS's packets, an answer to an RTS — in that order of
// making, the J1939 ones first.
//
// Takes `mut` because a protected response has to advance its own counter: a request-driven
// message has period 0, so due_frames never touches it and its send count would otherwise
// stay at zero forever — a receiver checking the counter would reject every single response.
pub fn (mut e Engine) on_frame(f transport.CanFrame) []transport.CanFrame {
	mut out := e.with_local(e.j1939_frame(f))
	for i := 0; i < e.ecus.len; i++ {
		for r in e.ecus[i].rules {
			if f.id != r.req_id {
				continue
			}
			mut data := f.data.clone()
			mut drop_response := false
			if r.byte_index < data.len {
				data[r.byte_index] = data[r.byte_index] + r.add
			}
			// The response is built here rather than through build(), because its payload
			// comes from the REQUEST, not from generators. Protection still has to be
			// applied, and it lives on the SimMessage that carries this id.
			for j := 0; j < e.ecus[i].messages.len; j++ {
				mut m := &e.ecus[i].messages[j]
				// `ext` as well as the numeric id: a standard and an extended message may share
				// a number, and matching on the id alone could take the other one's DLC,
				// protection layout and counter while the frame goes out in this one's format.
				// Match the response MESSAGE regardless of whether it is protected: faults
				// apply to any response, and requiring protection here meant `drop` and
				// `out_of_range` silently did nothing on an ordinary response rule.
				if m.msg.id != r.resp_id || m.msg.ext != r.resp_ext {
					continue
				}
				if !any_active(m.e2e) && !m.fault.active() && m.set.len == 0 {
					continue // nothing to stamp, set or break
				}
				// Size the payload to the RESPONSE message's DLC first. `data` is the REQUEST
				// cloned, and the two need not be the same length: a shorter request leaves the
				// buffer too small, so set_raw silently skips every counter/CRC bit past its
				// end — the frame goes out unprotected while send_n advances, which is the
				// worst of both. A longer one makes the checksum cover bytes the receiver never
				// sees. Only the protected path resizes; an unprotected rule stays the plain
				// echo of the request that it is documented to be.
				// Resized when protection OR a fault needs the message's real layout: an
				// out_of_range target can sit beyond the echoed request's length, and set_raw
				// silently skips out-of-bounds bits — so the response went out unchanged while
				// the fault reported itself armed. An unfaulted, unprotected rule stays the
				// plain echo of the request it is documented to be.
				needs_layout := any_active(m.e2e) || m.fault.active() || m.set.len > 0
				mut buf := []u8{len: if needs_layout { m.msg.dlc } else { data.len }}
				for k in 0 .. buf.len {
					if k < data.len {
						buf[k] = data[k]
					}
				}
				apply_set(m.msg, m.set, mut buf)
				m.fault.apply_pre(m.msg, mut buf)
				m.stamp_e2e(mut buf)
				m.send_n++
				m.advance_e2e()
				if !m.fault.apply_post(m.msg, m.e2e, mut buf) {
					drop_response = true
				}
				data = buf.clone()
				break
			}
			if drop_response {
				continue // a fault on this response message: it simply does not answer
			}
			out << transport.CanFrame{
				id:       r.resp_id
				extended: r.resp_ext
				data:     data
			}
		}
	}
	return out
}
