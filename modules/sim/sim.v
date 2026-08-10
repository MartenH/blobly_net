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
import candb
import transport

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
	e2e       E2e   // alive counter + checksum, stamped after the generators (see e2e.v)
	fault     Fault // deliberate misbehaviour (see fault.v)
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
	next_ms   f64 // next due time
}

// e2e_value is the counter this frame should carry: the last transmitted one while frozen, so
// the stall begins with the very first faulted frame rather than after one more advance.
pub fn (m SimMessage) e2e_value() int {
	if m.fault.kind == .freeze_ctr && m.has_tx {
		return m.last_e2e
	}
	return m.e2e_n
}

// advance_e2e records what was just sent and moves the counter on — unless frozen, in which
// case e2e_n is left untouched so recovery resumes exactly one step later with no flag to keep.
pub fn (mut m SimMessage) advance_e2e() {
	v := m.e2e_value()
	m.last_e2e = v
	m.has_tx = true
	// ALWAYS one past what was sent. The freeze lives in e2e_value (which re-sends last_e2e),
	// not here: leaving the pointer unadvanced meant the first recovered frame repeated the
	// frozen value all over again.
	m.e2e_n = v + 1
}

// build encodes the message's signals at time t into a CAN frame.
pub fn (mut m SimMessage) build(t f64) transport.CanFrame {
	mut data := []u8{len: m.msg.dlc}
	for s in m.signals {
		for sig in m.msg.signals {
			if sig.name == s.name {
				sig.encode(mut data, s.gen.value(t, m.send_n))
				break
			}
		}
	}
	// An out-of-range value goes in BEFORE protection, so the frame arrives with a valid
	// checksum and the receiver reaches its range handling instead of rejecting a CRC error.
	m.fault.apply_pre(m.msg, mut data)
	// End-to-end protection goes over the finished payload — the counter and checksum have to
	// reflect what is actually on the wire, including every generator's contribution.
	m.e2e.apply(m.msg, mut data, m.e2e_value())
	return transport.CanFrame{
		id:       m.msg.id
		extended: m.msg.ext
		data:     data
	}
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
}

// Engine drives a set of ECUs against a logical clock.
pub struct Engine {
pub mut:
	ecus []SimEcu
}

// save_counters / restore_counters carry alive counters across an engine rebuild, through a
// cache the caller owns and keeps for the whole run.
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
pub fn (e Engine) save_counters(mut into map[string]int) {
	for ecu in e.ecus {
		for m in ecu.messages {
			into['${ecu.name}|${m.msg.name}'] = m.send_n
			into['e2e|${ecu.name}|${m.msg.name}'] = m.e2e_n
			into['e2elast|${ecu.name}|${m.msg.name}'] = if m.has_tx { m.last_e2e } else { -1 }
		}
	}
}

pub fn (mut e Engine) restore_counters(from map[string]int) {
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].messages.len; j++ {
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
		}
	}
}

// due_frames advances every cyclic message whose period has elapsed by now_ms and
// returns the frames to transmit (also bumping send counters / next-due times).
pub fn (mut e Engine) due_frames(now_ms f64) []transport.CanFrame {
	mut out := []transport.CanFrame{}
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].messages.len; j++ {
			mut m := &e.ecus[i].messages[j]
			if m.period_ms <= 0 {
				continue
			}
			if now_ms + 1e-6 >= m.next_ms {
				mut f := m.build(now_ms / 1000.0)
				if m.fault.apply_post(m.msg, m.e2e, mut f.data) {
					out << f
				}
				m.send_n++ // generators keep running: a drop is a lost frame, not a stopped ECU
				// The PROTECTION counter is what freezes. A dropped frame still advances it, so
				// recovery shows a gap rather than a stall — the difference a receiver uses to
				// tell a lost frame from a stuck sender.
				m.advance_e2e()
				m.next_ms += f64(m.period_ms)
				if m.next_ms <= now_ms {
					m.next_ms = now_ms + f64(m.period_ms)
				}
			}
		}
	}
	return out
}

// run_for drives the engine live on a bus for duration_ms: it transmits due
// cyclic frames against the wall clock and answers received requests. Used by
// the smoke tool and (later) the GUI's measurement thread. The bus should be a
// dedicated instance for this node (so it doesn't hear its own sends).
pub fn (mut e Engine) run_for(mut bus transport.Bus, duration_ms int) {
	t0 := time.ticks()
	deadline := t0 + i64(duration_ms)
	for time.ticks() < deadline {
		now_ms := f64(time.ticks() - t0)
		for f in e.due_frames(now_ms) {
			bus.send(f) or {}
		}
		if frame := bus.recv(5) {
			for resp in e.on_frame(frame) {
				bus.send(resp) or {}
			}
		}
	}
}

// on_frame returns the response frames triggered by a received frame.
//
// Takes `mut` because a protected response has to advance its own counter: a request-driven
// message has period 0, so due_frames never touches it and its send count would otherwise
// stay at zero forever — a receiver checking the counter would reject every single response.
pub fn (mut e Engine) on_frame(f transport.CanFrame) []transport.CanFrame {
	mut out := []transport.CanFrame{}
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
				if !m.e2e.active() && !m.fault.active() {
					continue // nothing to stamp and nothing to break
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
				needs_layout := m.e2e.active() || m.fault.active()
				mut buf := []u8{len: if needs_layout { m.msg.dlc } else { data.len }}
				for k in 0 .. buf.len {
					if k < data.len {
						buf[k] = data[k]
					}
				}
				m.fault.apply_pre(m.msg, mut buf)
				if m.e2e.active() {
					m.e2e.apply(m.msg, mut buf, m.e2e_value())
				}
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
