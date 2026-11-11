module transport

import sync
import time

// how long a send's note waits for its echo before it stops claiming one: a backend that does not
// echo to the wire's other handles leaves its notes to expire
pub const newest_echo_ns = i64(time.second)

// how many sends' notes wait at most; past it the oldest stops claiming its echo
pub const newest_notes_max = 256

// how long one read of the view's own handle waits before it asks whether to stop, and so how
// long `settle` waits at most on a quiet wire
pub const newest_slice_ms = 2

// how long `settle` waits at most for the reader, which a slow backend's read may hold
pub const newest_settle_ms = 50

// how many queued frames one catch-up reads at most before it waits again
const newest_drain_max = 4096

// NewestFrame is the newest frame of one id and kind, and when it arrived (received_now's ns).
pub struct NewestFrame {
pub:
	frame CanFrame
	t_ns  i64
}

struct EchoNote {
	tok u64
	// the frame as sent, and as the wire carries it where the backend changes it (wire_frame)
	forms []CanFrame
	at_ns i64
}

// NewestView is the newest frame per (id, kind) on a wire, kept current by a reader of its own: a
// handle opened for it alone and read on its own thread, so a script blocked in a UDS exchange, a
// flash or a sleep still finds the newest frame at its next ask. A script's handle tells it what
// it sends (`sending`), so the echo the view's handle hears of it is not kept: the view holds what
// the script's handle would have read. A remote frame is not kept; it carries no data.
@[heap]
pub struct NewestView {
mut:
	mu     sync.Mutex
	frames map[u64]NewestFrame
	notes  []EchoNote
	next   u64
	failed string
	stop   bool
	// the wire, as the view's handle was opened on it: what a send becomes on it (wire_frame)
	iface string
	// whether the view's handle hears the script handle's sends (echoes_own_sends): where it does
	// not, a send is not noted, since a note would claim a peer's frame in its place
	hears_sends bool
	// settles asked for (`settle`) and the newest one the reader has answered: every frame queued
	// on its handle when that one was asked has been kept
	asked    u64
	answered u64
	bus    ?Bus // the handle a reader was started on: `close` joins it and closes the handle
	reader thread
}

// new_newest is a view of `iface` no reader feeds: the table and its echo rule, for
// `watch_newest` and tests.
pub fn new_newest(iface string) &NewestView {
	return &NewestView{
		iface:       iface
		hears_sends: true
	}
}

// watch_newest starts a view read from `bus`, a handle opened for it alone on `iface`, which it
// closes at `close`. One look is taken first, so a shared-hub handle is subscribed before this
// returns.
pub fn watch_newest(bus Bus, iface string) &NewestView {
	mut b := bus
	mut v := &NewestView{
		bus:         b
		iface:       iface
		hears_sends: echoes_own_sends(iface)
	}
	if f := b.recv(0) {
		v.keep(f, received_now(f), i64(time.sys_mono_now()))
	}
	v.reader = spawn v.read()
	return v
}

fn (mut v NewestView) stopping() bool {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	return v.stop
}

// read keeps every frame the view's handle reads until `close`; a handle that fails ends it, and
// `failure` then says why. A settle asked for is answered once the handle has nothing queued.
fn (mut v NewestView) read() {
	stop := fn [mut v] () bool {
		return v.stopping()
	}
	mut b := v.bus or { return }
	for {
		if f := recv_sliced(mut b, newest_slice_ms, newest_slice_ms, stop) {
			v.keep(f, received_now(f), i64(time.sys_mono_now()))
		} else {
			if err.code() == sliced_stop_code {
				return
			}
			if err.msg() != 'timeout' {
				v.fail(err.msg())
				return
			}
		}
		asked := v.asked_now()
		if asked == v.answered_now() {
			continue
		}
		// a settle is waiting: what is queued now read by zero looks before it is answered, since a
		// receive that timed out may have spent its budget with a frame still queued
		mut drained := false
		for _ in 0 .. newest_drain_max {
			g := b.recv(0) or {
				if look_was_spent(err) {
					continue
				}
				if err.msg() == 'timeout' {
					drained = true
					break
				}
				v.fail(err.msg())
				return
			}
			v.keep(g, received_now(g), i64(time.sys_mono_now()))
		}
		if drained {
			v.answer(asked)
		}
	}
}

fn (mut v NewestView) fail(why string) {
	v.mu.lock()
	v.failed = why
	v.mu.unlock()
}

fn (mut v NewestView) asked_now() u64 {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	return v.asked
}

fn (mut v NewestView) answered_now() u64 {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	return v.answered
}

fn (mut v NewestView) answer(asked u64) {
	v.mu.lock()
	if asked > v.answered {
		v.answered = asked
	}
	v.mu.unlock()
}

// settle waits until the reader has kept every frame queued on its handle now — at most
// newest_slice_ms on a quiet wire, newest_settle_ms in all — so the next `get` answers as of the
// call. Nothing for a view no reader feeds, or one whose reader ended.
pub fn (mut v NewestView) settle() {
	v.mu.lock()
	if v.bus == none || v.failed != '' || v.stop {
		v.mu.unlock()
		return
	}
	v.asked++
	my := v.asked
	v.mu.unlock()
	deadline := time.sys_mono_now() + u64(newest_settle_ms) * u64(time.millisecond)
	for v.answered_now() < my && v.failure() == '' && time.sys_mono_now() < deadline {
		time.sleep(50 * time.microsecond)
	}
}

fn newest_key(id u32, ext bool) u64 {
	return u64(id) | (u64(ext) << 32)
}

// keep files a frame read at `t_ns`, unless it is the echo of a send noted within newest_echo_ns
// before `now_ns`, whose note it then takes.
pub fn (mut v NewestView) keep(f CanFrame, t_ns i64, now_ns i64) {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	for v.notes.len > 0 && now_ns - v.notes[0].at_ns > newest_echo_ns {
		v.notes.delete(0)
	}
	for i, n in v.notes {
		if n.echoed_by(f) {
			v.notes.delete(i)
			return
		}
	}
	if !f.rtr {
		v.frames[newest_key(f.id, f.extended)] = NewestFrame{
			frame: f
			t_ns:  t_ns
		}
	}
}

// echoed_by: the echo carries one of the note's forms.
fn (n EchoNote) echoed_by(f CanFrame) bool {
	return n.forms.any(echo_of(it, f))
}

// echo_of: `f` carries the id, kind, remote bit and payload of `sent`, an FD one zero-padded up to
// the length a DLC expresses.
fn echo_of(sent CanFrame, f CanFrame) bool {
	if f.id != sent.id || f.extended != sent.extended || f.rtr != sent.rtr
		|| f.data.len < sent.data.len {
		return false
	}
	if f.data.len != sent.data.len && !(f.fd && f.data.len == fd_padded_len(sent.data.len)) {
		return false
	}
	if f.data[..sent.data.len] != sent.data {
		return false
	}
	return f.data[sent.data.len..].all(it == 0)
}

// sending notes a frame the script's handle is about to send, at `now_ns`, so its echo is not
// kept; the token undoes it (`unsent`) when the send fails. 0, and no note, where the view's
// handle does not hear the send.
pub fn (mut v NewestView) sending(f CanFrame, now_ns i64) u64 {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	if !v.hears_sends {
		return 0
	}
	v.next++
	if v.notes.len >= newest_notes_max {
		v.notes.delete(0)
	}
	given := CanFrame{
		id:       f.id
		extended: f.extended
		rtr:      f.rtr
		data:     f.data.clone()
	}
	mut forms := [given]
	w := wire_frame(v.iface, f)
	if w.id != f.id || w.data != f.data {
		forms << CanFrame{
			...given
			id:   w.id
			data: w.data.clone()
		}
	}
	v.notes << EchoNote{
		tok:   v.next
		forms: forms
		at_ns: now_ns
	}
	return v.next
}

// unsent takes back the note of a send that did not go out.
pub fn (mut v NewestView) unsent(tok u64) {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	for i, n in v.notes {
		if n.tok == tok {
			v.notes.delete(i)
			return
		}
	}
}

// get is the newest frame of `id` and kind `ext` (none: the newer of either kind), none before
// the first.
pub fn (mut v NewestView) get(id u32, ext ?bool) ?NewestFrame {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	kinds := if e := ext { [e] } else { [false, true] }
	mut best := ?NewestFrame(none)
	for k in kinds {
		if f := v.frames[newest_key(id, k)] {
			if b := best {
				if f.t_ns > b.t_ns {
					best = f
				}
			} else {
				best = f
			}
		}
	}
	return best
}

// failure is why the view's handle stopped reading, '' while it reads: its table no longer moves.
pub fn (mut v NewestView) failure() string {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	return v.failed
}

// clear forgets every frame kept so far; the reader goes on.
pub fn (mut v NewestView) clear() {
	v.mu.lock()
	defer {
		v.mu.unlock()
	}
	v.frames = map[u64]NewestFrame{}
}

// close ends the reader within a slice and closes its handle. Twice is nothing.
pub fn (mut v NewestView) close() {
	v.mu.lock()
	was := v.stop
	v.stop = true
	v.mu.unlock()
	mut b := v.bus or { return }
	if was {
		return
	}
	v.reader.wait()
	b.close()
}
