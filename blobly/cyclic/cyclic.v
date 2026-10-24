// cyclic.v — a frame sent on a period in the background, while the script that started it does
// something else (blocks in a UDS request, waits in an expect).
//
// A sender OWNS ITS BUS: a handle opened for it alone, used by its own thread alone, which sends
// and never reads — so on a shared-hub wire it is no subscriber, and no script handle is ever
// touched from a second thread (canlib forbids two threads on a Kvaser handle; SocketCAN's and
// Vector's ladder state is written by recv). Listen-only and CAN-FD framing are the bus's own, per
// send (transport.SilentBus); a DBC message's declared E2E is stamped here, per frame, its counter
// the sender's own from 0. The script's handle on the channel hears these frames as it hears any
// other handle's.
module cyclic

import sync
import time
import blobly.candb
import blobly.sim
import blobly.transport

// max_period_ms is the longest period a sender may be given: an hour, as a generator's cycle.
pub const max_period_ms = sim.gen_cycle_max_ms

// stop_bound_ms is how long a stop waits for a sender's loop to end: a send in a driver's budget.
pub const stop_bound_ms = 2000

// poll_ms is how often a waiting loop asks whether it is to stop.
const poll_ms = 20

// Spec is what a sender sends: a raw frame (`id`, `ext`, `data`, its `format`), or — `by_message`
// — a DBC message encoded from `values` (physical, by signal name; the rest at raw 0), its declared
// E2E stamped unless `e2e` is false.
pub struct Spec {
pub:
	id         u32
	ext        bool
	data       []u8
	format     transport.FrameFormat
	by_message bool
	message    candb.Message
	values     map[string]f64
	e2e        bool = true
	period_ms  int
}

// check refuses a spec no sender could send: a period outside 1 ms .. an hour, a payload past 64
// bytes or past its stated format, a signal its message does not have, a declared E2E that cannot
// be applied.
pub fn (s Spec) check() ! {
	check_period(s.period_ms)!
	if s.by_message {
		check_values(s.message, s.values)!
		if s.message.payload_len() > 64 {
			return error('${s.message.name}: a payload of ${s.message.payload_len()} bytes is past what a CAN frame carries (64)')
		}
		if s.e2e {
			mut st := sim.E2eStamper{}
			mut data := s.message.template()
			st.stamp(s.message, mut data) or {
				return error('${s.message.name}: ${err.msg()} (send it with e2e off)')
			}
		}
		return
	}
	check_data(s.format, s.id, s.ext, s.data)!
}

// check_period refuses a period outside 1 ms .. max_period_ms.
pub fn check_period(ms int) ! {
	if ms < 1 || ms > max_period_ms {
		return error('a period of ${ms} ms: give 1 .. ${max_period_ms}')
	}
}

fn check_values(m candb.Message, values map[string]f64) ! {
	for name, _ in values {
		m.signal_named(name) or { return error('unknown signal "${name}" in ${m.name}') }
	}
}

fn check_data(ff transport.FrameFormat, id u32, ext bool, data []u8) ! {
	if data.len > 64 {
		return error('a payload is at most 64 bytes, not ${data.len}')
	}
	ff.stamp(transport.CanFrame{ id: id, extended: ext, data: data })!
}

// Life ties a sender to whatever owns it: `running` false ends it as a stop does (a run's stop),
// and `ended` is called once when its loop is out.
pub struct Life {
pub:
	running fn () bool = unsafe { nil }
	ended   fn ()      = unsafe { nil }
}

// Info is a sender as it is now: frames the bus took and refused, the last refusal ('' none),
// its period, and whether its loop still runs.
pub struct Info {
pub:
	sent      u64
	failed    u64
	error     string
	period_ms int
	running   bool
}

@[heap]
pub struct Sender {
mut:
	mu      sync.Mutex
	spec    Spec
	bus     transport.Bus
	life    Life
	stamper sim.E2eStamper // the loop's alone
	asked   bool           // stop was asked
	out     bool           // the loop runs
	sent    u64
	failed  u64
	error   string
	wake    chan bool = chan bool{cap: 1}
}

// start sends `spec` on `bus`, which the sender owns from here (closed when its loop ends, and on
// a refusal): its first frame at once, then one per period on that grid. A stall never bursts
// catch-up frames: a sender a whole period late starts its grid again from now.
pub fn start(bus transport.Bus, spec Spec, life Life) !&Sender {
	spec.check() or {
		mut b := bus
		b.close()
		return err
	}
	mut s := &Sender{
		spec: Spec{
			...spec
			data:   spec.data.clone()
			values: spec.values.clone()
		}
		bus:  bus
		life: life
		out:  true
	}
	spawn s.run()
	return s
}

fn (mut s Sender) run() {
	defer {
		s.bus.close()
		s.mu.lock()
		s.out = false
		s.mu.unlock()
		if s.life.ended != unsafe { nil } {
			s.life.ended()
		}
	}
	mut first := true
	mut last := u64(0) // when the grid last sent, ms on the monotonic clock
	for {
		s.mu.lock()
		asked := s.asked
		period := u64(s.spec.period_ms)
		s.mu.unlock()
		if asked || (s.life.running != unsafe { nil } && !s.life.running()) {
			return
		}
		now := time.sys_mono_now() / 1_000_000
		// due by the period as it is now, so a changed one applies from the next frame
		if first || now >= last + period {
			last = if first || now >= last + 2 * period { now } else { last + period }
			first = false
			s.send_once()
		}
		after := time.sys_mono_now() / 1_000_000
		due := last + period
		wait := if due <= after { u64(0) } else if due - after < poll_ms { due - after } else { u64(poll_ms) }
		select {
			_ := <-s.wake {}
			i64(wait) * time.millisecond {}
		}
	}
}

// send_once puts the frame on the bus as the spec has it now, counting what became of it.
fn (mut s Sender) send_once() {
	s.mu.lock()
	sp := Spec{
		...s.spec
		data:   s.spec.data.clone()
		values: s.spec.values.clone()
	}
	s.mu.unlock()
	frame := s.frame(sp) or {
		s.note_failure(err.msg())
		return
	}
	s.bus.send(frame) or {
		s.note_failure(err.msg())
		return
	}
	s.mu.lock()
	s.sent++
	s.mu.unlock()
}

// frame is the frame `sp` sends now: a message's E2E counter moves on each one.
fn (mut s Sender) frame(sp Spec) !transport.CanFrame {
	if !sp.by_message {
		return sp.format.stamp(transport.CanFrame{
			id:       sp.id
			extended: sp.ext
			data:     sp.data
		})
	}
	mut data := sp.message.template()
	for name, v in sp.values {
		if sig := sp.message.signal_named(name) {
			sig.encode(mut data, v)
		}
	}
	if sp.e2e {
		s.stamper.stamp(sp.message, mut data)!
	}
	return transport.CanFrame{
		id:       sp.message.id
		extended: sp.message.ext
		data:     data
	}
}

fn (mut s Sender) note_failure(why string) {
	s.mu.lock()
	s.failed++
	s.error = why
	s.mu.unlock()
}

// set_period gives the sender a period from its next frame.
pub fn (mut s Sender) set_period(ms int) ! {
	check_period(ms)!
	s.mu.lock()
	s.spec = Spec{
		...s.spec
		period_ms: ms
	}
	s.mu.unlock()
	s.wake.try_push(true)
}

// set_data replaces a raw sender's payload from its next frame.
pub fn (mut s Sender) set_data(data []u8) ! {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if s.spec.by_message {
		return error('${s.spec.message.name}: a message sender takes signal values, not bytes')
	}
	check_data(s.spec.format, s.spec.id, s.spec.ext, data)!
	s.spec = Spec{
		...s.spec
		data: data.clone()
	}
}

// set_values sets a message sender's signals from its next frame; the others keep theirs.
pub fn (mut s Sender) set_values(values map[string]f64) ! {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.spec.by_message {
		return error('a raw sender takes bytes, not signal values')
	}
	check_values(s.spec.message, values)!
	mut vs := s.spec.values.clone()
	for k, v in values {
		vs[k] = v
	}
	s.spec = Spec{
		...s.spec
		values: vs
	}
}

// info is the sender as it is now.
pub fn (mut s Sender) info() Info {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return Info{
		sent:      s.sent
		failed:    s.failed
		error:     s.error
		period_ms: s.spec.period_ms
		running:   s.out && !s.asked
	}
}

// ask_stop asks the loop to end, without waiting.
pub fn (mut s Sender) ask_stop() {
	s.mu.lock()
	s.asked = true
	s.mu.unlock()
	s.wake.try_push(true)
}

// stop ends the sender: true once its loop is out (its bus closed), false when it is still inside
// a send after stop_bound_ms — it ends when that send returns, and sends nothing more.
pub fn (mut s Sender) stop() bool {
	s.ask_stop()
	return s.wait_out(time.sys_mono_now() + u64(stop_bound_ms) * 1_000_000)
}

// wait_out waits until the loop is out or `until` (the monotonic clock, ns) has passed.
pub fn (mut s Sender) wait_out(until u64) bool {
	for {
		s.mu.lock()
		out := s.out
		s.mu.unlock()
		if !out {
			return true
		}
		if time.sys_mono_now() >= until {
			return false
		}
		time.sleep(2 * time.millisecond)
	}
	return false
}

// stop_all stops every sender in `senders` within one stop_bound_ms; how many are still out.
pub fn stop_all(mut senders []&Sender) int {
	for mut s in senders {
		s.ask_stop()
	}
	until := time.sys_mono_now() + u64(stop_bound_ms) * 1_000_000
	mut left := 0
	for mut s in senders {
		if !s.wait_out(until) {
			left++
		}
	}
	return left
}

// Host is who a script's sender belongs to: a run, whose stop ends it (headless.Run), or nobody
// (Free) — the script itself then stops it, at the latest when it closes.
pub interface Host {
mut:
	start_cyclic(bus transport.Bus, spec Spec) !&Sender
}

// Free starts senders bound to no run.
pub struct Free {}

pub fn (mut f Free) start_cyclic(bus transport.Bus, spec Spec) !&Sender {
	return start(bus, spec, Life{})
}
