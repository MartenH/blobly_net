// cyclic.v — a frame sent on a period in the background, while the script that started it does
// something else (blocks in a UDS request, waits in an expect).
//
// A sender is an Entry of a Wire (wire.v): the wire's loop sends it on a handle that sends and
// never reads — so on a shared-hub wire it is no subscriber, and no script handle is ever touched
// from a second thread (canlib forbids two threads on a Kvaser handle; SocketCAN's and Vector's
// ladder state is written by recv). Started alone (`start`), it has a wire of its own on the bus
// it is given; in a run, the run's wire to its channel, which serves the run's generators too.
// Listen-only and CAN-FD framing are the bus's own, per send (transport.SilentBus); the row a
// frame is sent as is the sender's (transport.row_framed over the wire's handle); a DBC message's
// declared E2E is stamped here, per frame, its counter the sender's own from 0. The script's
// handle on the channel hears these frames as it hears any other handle's.
module cyclic

import sync
import time
import blobly.candb
import blobly.project
import blobly.sim
import blobly.transport

// max_period_ms is the longest period a sender may be given: an hour, as a generator's cycle.
pub const max_period_ms = sim.gen_cycle_max_ms

// stop_bound_ms is how long a stop waits for a sender's wire to let it go: a send in a driver's
// budget.
pub const stop_bound_ms = 2000

// stopped_note is what a change to a stopped sender is refused with.
pub const stopped_note = 'the sender is stopped: it sends nothing more'

// poll_ms is how often a waiting loop asks whether it is to stop.
const poll_ms = 20

// Spec is what a sender sends: a raw frame (`id`, `ext`, `data`; `fd`/`brs` as a C host's flags,
// unstated, which the wire's declaration may raise; `format` a stated one), or — `by_message` — a
// DBC message encoded from `values` (physical, by signal name; the rest at raw 0), its declared
// E2E stamped unless `e2e` is false, in `format` where stated, else its declared format
// (project.message_format).
pub struct Spec {
pub:
	id         u32
	ext        bool
	data       []u8
	fd         bool
	brs        bool
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
		if why := transport.frame_send_refusal(transport.CanFrame{
			id:       s.message.id
			extended: s.message.ext
		}) {
			return error('${s.message.name}: ${why}')
		}
		project.message_format(s.message, s.format).stamp(transport.CanFrame{
			data: s.message.template()
		}) or { return error('${s.message.name}: ${err.msg()}') }
		if s.e2e {
			mut st := sim.E2eStamper{}
			mut data := s.message.template()
			st.stamp(s.message, mut data) or {
				return error('${s.message.name}: ${err.msg()} (send it with e2e off)')
			}
		}
		return
	}
	raw_frame(s, s.data)!
}

// check_period refuses a period outside 1 ms .. max_period_ms.
pub fn check_period(ms int) ! {
	if ms < 1 || ms > max_period_ms {
		return error('a period of ${ms} ms: give 1 .. ${max_period_ms}')
	}
}

// check_values refuses a value for a signal the message does not have or that carries no number.
fn check_values(m candb.Message, values map[string]f64) ! {
	for name, _ in values {
		sig := m.signal_named(name) or { return error('unknown signal "${name}" in ${m.name}') }
		why := sig.scalar_refusal()
		if why != '' {
			return error(why)
		}
	}
}

// raw_frame is a raw spec's frame with payload `data`, or why no controller could send it.
fn raw_frame(s Spec, data []u8) !transport.CanFrame {
	if data.len > 64 {
		return error('a payload is at most 64 bytes, not ${data.len}')
	}
	f := s.format.stamp(transport.CanFrame{
		id:       s.id
		extended: s.ext
		fd:       s.fd
		brs:      s.brs
		data:     data
	})!
	// unstated flags are judged as a CAN-FD wire's declaration would raise them: brs alone is
	// what such a wire sends as FD with the rate switch
	judged := if f.format_stated { f } else { transport.CanFrame{
			...f
			fd: f.fd || f.brs
		} }
	if why := transport.frame_send_refusal(judged) {
		return error(why)
	}
	return f
}

// Life ties a sender started alone to whatever owns it: `running` false ends it as a stop does,
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
	iface string // the wire it is sent on, and the row it is sent as ('' none)
	row   string
mut:
	mu      sync.Mutex
	spec    Spec
	wire    &Wire = unsafe { nil }
	stamper sim.E2eStamper     // the loop's alone
	frame   transport.CanFrame // what the spec sends now, encoded when it changes
	asked   bool               // stop was asked
	out     bool               // its wire still serves it
	sent    u64
	failed  u64
	error   string
	// the loop's alone: the grid slot last sent in and when that send returned (ms on the
	// monotonic clock), whether nothing was sent yet, and the wire's handle as its row
	first  bool = true
	slot   u64
	done   u64
	framed ?transport.Bus
}

// new_sender is a sender of `spec` on `iface`, sent as row `row`, on no wire yet.
pub fn new_sender(spec Spec, iface string, row string) !&Sender {
	spec.check()!
	mut s := &Sender{
		iface: iface
		row:   row
		spec:  Spec{
			...spec
			data:   spec.data.clone()
			values: spec.values.clone()
		}
		out:   true
	}
	s.frame = encoded(s.spec)!
	return s
}

// join puts s on wire `w`, which sends it from its next pass.
pub fn (mut s Sender) join(mut w Wire) ! {
	s.mu.lock()
	s.wire = w
	s.mu.unlock()
	w.add(s)!
}

// start sends `spec` on `bus`, which the sender owns from here (closed when its loop ends, and on
// a refusal): its first frame at once, then one per period on that grid. A stall never bursts
// catch-up frames: the slots it covered are skipped (sim.next_due).
pub fn start(bus transport.Bus, spec Spec, life Life) !&Sender {
	mut s := new_sender(spec, '', '') or {
		mut b := bus
		b.close()
		return err
	}
	mut w := &Wire{
		solo: true
		life: life
	}
	s.join(mut w)!
	spawn fn [mut w, bus] () {
		w.run(fn [bus] (_ string) !transport.Bus {
			return bus
		}) or {}
	}()
	return s
}

fn (mut s Sender) leaving() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.asked
}

fn (mut s Sender) due(now u64) ?u64 {
	s.mu.lock()
	period := u64(s.spec.period_ms)
	s.mu.unlock()
	// due by the period as it is now, so a changed one applies from the next frame
	return if s.first { now } else { sim.next_due(s.slot, period, s.done) }
}

fn (mut s Sender) serve(mut bus transport.Bus, now u64) string {
	due := s.due(now) or { return '' }
	if now < due {
		return ''
	}
	s.slot = if s.first { now } else { due }
	s.first = false
	mut b := s.framed or {
		f := transport.row_framed(bus, s.iface, s.row)
		s.framed = f
		f
	}
	s.send_once(mut b)
	s.done = time.sys_mono_now() / 1_000_000
	return ''
}

fn (mut s Sender) let_go(failure string) {
	s.mu.lock()
	s.out = false
	if failure != '' {
		s.error = failure
	}
	s.mu.unlock()
}

// poke wakes its wire: its period changed or it was asked to stop.
fn (mut s Sender) poke() {
	s.mu.lock()
	mut w := s.wire
	s.mu.unlock()
	if !isnil(w) {
		w.poke()
	}
}

// send_once puts the frame on the bus as the spec has it now, counting what became of it.
fn (mut s Sender) send_once(mut bus transport.Bus) {
	s.mu.lock()
	sp := s.spec
	mut frame := transport.CanFrame{
		...s.frame
		data: s.frame.data.clone()
	}
	s.mu.unlock()
	// a message's E2E counter moves on each frame
	if sp.by_message && sp.e2e {
		s.stamper.stamp(sp.message, mut frame.data) or {
			s.note_failure(err.msg())
			return
		}
	}
	bus.send(frame) or {
		s.note_failure(err.msg())
		return
	}
	s.mu.lock()
	s.sent++
	s.mu.unlock()
}

// encoded is the frame `sp` sends, its E2E not stamped yet.
fn encoded(sp Spec) !transport.CanFrame {
	if !sp.by_message {
		return raw_frame(sp, sp.data.clone())
	}
	mut data := sp.message.template()
	// the switch and the plain signals first, then only the branch they select: a value kept for
	// another branch shares its bits and would overwrite the selected one (two passes reach a
	// switch that is itself multiplexed)
	for sig in sp.message.signals {
		if !sig.is_multiplexed {
			if v := sp.values[sig.name] {
				sig.encode(mut data, v)
			}
		}
	}
	for _ in 0 .. 2 {
		carried := sp.message.carried(data)
		for i, sig in sp.message.signals {
			if sig.is_multiplexed && carried[i] {
				if v := sp.values[sig.name] {
					sig.encode(mut data, v)
				}
			}
		}
	}
	return project.message_format(sp.message, sp.format).stamp(transport.CanFrame{
		id:       sp.message.id
		extended: sp.message.ext
		data:     data
	})!
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
	if s.asked || !s.out {
		s.mu.unlock()
		return error(stopped_note)
	}
	s.spec = Spec{
		...s.spec
		period_ms: ms
	}
	s.mu.unlock()
	s.poke()
}

// set_data replaces a raw sender's payload from its next frame.
pub fn (mut s Sender) set_data(data []u8) ! {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if s.asked || !s.out {
		return error(stopped_note)
	}
	if s.spec.by_message {
		return error('${s.spec.message.name}: a message sender takes signal values, not bytes')
	}
	sp := Spec{
		...s.spec
		data: data.clone()
	}
	s.frame = raw_frame(sp, sp.data)!
	s.spec = sp
}

// set_values sets a message sender's signals from its next frame; the others keep theirs.
pub fn (mut s Sender) set_values(values map[string]f64) ! {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if s.asked || !s.out {
		return error(stopped_note)
	}
	if !s.spec.by_message {
		return error('a raw sender takes bytes, not signal values')
	}
	check_values(s.spec.message, values)!
	mut vs := s.spec.values.clone()
	for k, v in values {
		vs[k] = v
	}
	sp := Spec{
		...s.spec
		values: vs
	}
	s.frame = encoded(sp)!
	s.spec = sp
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

// is_out is whether its wire has let it go.
pub fn (mut s Sender) is_out() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return !s.out
}

// ask_stop asks its wire to let it go, without waiting.
pub fn (mut s Sender) ask_stop() {
	s.mu.lock()
	s.asked = true
	s.mu.unlock()
	s.poke()
}

// stop ends the sender: true once its wire has let it go (started alone: its bus closed), false
// when the wire is still inside a send after stop_bound_ms — it lets the sender go when that send
// returns, and sends nothing more of it.
pub fn (mut s Sender) stop() bool {
	s.ask_stop()
	return s.wait_out(time.sys_mono_now() + u64(stop_bound_ms) * 1_000_000)
}

// wait_out waits until its wire let it go or `until` (the monotonic clock, ns) has passed.
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

// Target is where a script's sender goes: the address it is sent on (with its bitrate) and the
// row it is sent as ('' none: transport.row_framed), and how a sender with a bus of its own opens
// it, framed as that row.
pub struct Target {
pub:
	iface string
	row   string
	open  fn () !transport.Bus @[required]
}

// Host is who a script's sender belongs to: a run, whose wire to the target sends it and whose
// stop ends it (headless.Run), or nobody (Free) — the script itself then stops it, at the latest
// when it closes.
pub interface Host {
mut:
	start_cyclic(to Target, spec Spec) !&Sender
}

// Free starts senders bound to no run, each on a bus of its own.
pub struct Free {}

pub fn (mut f Free) start_cyclic(to Target, spec Spec) !&Sender {
	spec.check()!
	return start(to.open()!, spec, Life{})
}
