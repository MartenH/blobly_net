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
	e2e       E2e // alive counter + checksum, stamped after the generators (see e2e.v)
	send_n    int // times sent so far (drives counters)
	next_ms   f64 // next due time
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
	// End-to-end protection goes LAST, over the finished payload — the counter and checksum
	// have to reflect what is actually on the wire, including every generator's contribution.
	m.e2e.apply(m.msg, mut data, m.send_n)
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

// adopt_counters carries send counts over from a previous engine, matched by ECU and message
// name.
//
// Toggling ONE ECU's checkbox rebuilds the whole engine. Without this, every other protected
// message restarts its alive counter at zero at that moment, and a receiver that is checking
// the sequence rejects the next frame from an ECU the user did not touch — a fault injected
// by the act of looking at the panel. Messages that are new in this engine keep their fresh
// zero, which is correct: they have genuinely not been sent yet.
pub fn (mut e Engine) adopt_counters(prev Engine) {
	for i := 0; i < e.ecus.len; i++ {
		for p in prev.ecus {
			if p.name != e.ecus[i].name {
				continue
			}
			for j := 0; j < e.ecus[i].messages.len; j++ {
				for pm in p.messages {
					if pm.msg.name == e.ecus[i].messages[j].msg.name {
						e.ecus[i].messages[j].send_n = pm.send_n
						break
					}
				}
			}
			break
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
				out << m.build(now_ms / 1000.0)
				m.send_n++
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
			if r.byte_index < data.len {
				data[r.byte_index] = data[r.byte_index] + r.add
			}
			// The response is built here rather than through build(), because its payload
			// comes from the REQUEST, not from generators. Protection still has to be
			// applied, and it lives on the SimMessage that carries this id.
			for j := 0; j < e.ecus[i].messages.len; j++ {
				mut m := &e.ecus[i].messages[j]
				if m.msg.id != r.resp_id || !m.e2e.active() {
					continue
				}
				// Size the payload to the RESPONSE message's DLC first. `data` is the REQUEST
				// cloned, and the two need not be the same length: a shorter request leaves the
				// buffer too small, so set_raw silently skips every counter/CRC bit past its
				// end — the frame goes out unprotected while send_n advances, which is the
				// worst of both. A longer one makes the checksum cover bytes the receiver never
				// sees. Only the protected path resizes; an unprotected rule stays the plain
				// echo of the request that it is documented to be.
				mut buf := []u8{len: m.msg.dlc}
				for k in 0 .. buf.len {
					if k < data.len {
						buf[k] = data[k]
					}
				}
				m.e2e.apply(m.msg, mut buf, m.send_n)
				m.send_n++
				data = buf.clone()
				break
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
