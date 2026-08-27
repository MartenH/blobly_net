module transport

import sync
import time

// Some drivers permit only one physical receive queue per process and wire. PCANBasic permits one
// initialized channel, and CANsub permits one WebSocket client per channel. `shared_open` is the
// deliberately narrow adapter for those backends: one raw reader writes a bounded sequence ring,
// while every logical handle owns an independent cursor into it.
//
// Backends that already provide one receive queue per open (SocketCAN, inproc, UDP, Vector and
// Kvaser) do not come through here. Their native fanout remains the less surprising and cheaper
// implementation.

const shared_ring_capacity = 4096
const shared_reader_poll_ms = 50
const shared_pending_capacity = 4096
const shared_pending_ttl_ms = 5000

// SharedIngress is private transport metadata retained by a backend whose raw receive stream can
// distinguish its own transmit acknowledgements. Ordinary Bus backends are adapted below and
// always return tx_ack=false.
struct SharedIngress {
	frame  CanFrame
	tx_ack bool
}

// SharedDriver is the private raw seam behind the hub. It intentionally is not the public Bus:
// callers still send and receive CanFrame, while CANsub can preserve its TX bit until origin
// filtering has happened.
interface SharedDriver {
mut:
	send(frame CanFrame) !
	recv_shared(timeout_ms int) !SharedIngress
	close()
	health() BusHealth
	reconcile_silence(want bool) !
	reports_tx_ack() bool
}

// SharedBusDriver adapts an ordinary Bus. PCAN uses this path; no public transport API changes.
struct SharedBusDriver {
mut:
	bus Bus
}

fn (mut d SharedBusDriver) send(frame CanFrame) ! {
	d.bus.send(frame)!
}

fn (mut d SharedBusDriver) recv_shared(timeout_ms int) !SharedIngress {
	return SharedIngress{
		frame: d.bus.recv(timeout_ms)!
	}
}

fn (mut d SharedBusDriver) close() {
	d.bus.close()
}

fn (mut d SharedBusDriver) health() BusHealth {
	return d.bus.health()
}

fn (mut d SharedBusDriver) reconcile_silence(want bool) ! {
	d.bus.reconcile_silence(want)!
}

fn (mut d SharedBusDriver) reports_tx_ack() bool {
	return false
}

struct SharedRingSlot {
	seq    u64
	frame  CanFrame
	origin u64 // zero for external ingress; otherwise the sending SharedHandle id
}

struct SharedSubscriber {
	id   u64
	wake chan bool
}

struct SharedPendingSend {
	token      u64
	origin     u64
	frame      CanFrame
	expires_at i64
}

enum SharedEntryState {
	running
	closing
	failed
	closed
}

// SharedEntry is one physical-open generation. `mu` protects its ring, subscribers and lifecycle;
// the process-wide registry lock protects key ownership and serializes first opens, never the
// per-frame path. `send_mu` preserves the raw-write order used to correlate CANsub's untagged TX
// acknowledgements.
struct SharedEntry {
	key     string
	spec    string
	done    chan bool
	mu      sync.Mutex
	send_mu sync.Mutex
	tx_acks bool
mut:
	driver            SharedDriver
	refs              int
	next_id           u64
	ring              []SharedRingSlot
	next_seq          u64
	subs              []SharedSubscriber
	state             SharedEntryState
	terminal          string
	pending           []SharedPendingSend
	next_send_token   u64
	unmatched_tx_acks u64
	expired_tx_acks   u64
	raw_closed        bool
}

struct SharedRegistry {
mut:
	entries map[string]&SharedEntry
}

__global (
	shared_reg shared SharedRegistry
)

// canonical_spec compares two requests for one physical wire. CANsub addresses have equivalent
// spellings; PCAN's spelling remains exact, as it was before the hub.
fn canonical_spec(iface string) string {
	if iface.trim_space().to_lower().starts_with('cansub:') {
		return cansub_canonical_spec(iface)
	}
	return iface
}

fn shared_clone_frame(frame CanFrame) CanFrame {
	return CanFrame{
		...frame
		data: frame.data.clone()
	}
}

// This is the same identity wiretap uses for an echo: ESI is received controller status, not a
// sender-controlled part of the frame. Matching the oldest equal pending send makes identical
// serialized writes deterministic.
fn shared_same_frame(a CanFrame, b CanFrame) bool {
	return a.id == b.id && a.extended == b.extended && a.rtr == b.rtr && a.fd == b.fd
		&& a.brs == b.brs && a.data == b.data
}

// Remove only this physical-open generation. A reader error can race the last close: the error
// path may finish closing and let a replacement open before the old close waiter resumes. An
// unconditional key delete there would detach that brand-new generation.
fn shared_remove_entry(e &SharedEntry) {
	lock shared_reg {
		if current := shared_reg.entries[e.key] {
			if voidptr(current) == voidptr(e) {
				shared_reg.entries.delete(e.key)
			}
		}
	}
}

// Called with e.mu held. Pending acknowledgements are evidence, not an unbounded history: a lost
// device record must not retain payloads forever or let a much later identical acknowledgement be
// attributed to a stale send.
fn (mut e SharedEntry) expire_pending(now i64) {
	mut cut := 0
	for cut < e.pending.len && e.pending[cut].expires_at > 0 && e.pending[cut].expires_at <= now {
		cut++
	}
	if cut > 0 {
		e.expired_tx_acks += u64(cut)
		e.pending = e.pending[cut..].clone()
	}
}

// shared_open is the existing PCAN/fake factory seam. The raw Bus is adapted to SharedDriver and
// therefore contributes only external ingress events.
fn shared_open(key string, spec string, make fn (string) !Bus) !Bus {
	factory := fn [make] (s string) !SharedDriver {
		bus := make(s)!
		return &SharedBusDriver{
			bus: bus
		}
	}
	return shared_open_events(key, spec, factory)
}

// shared_open_events is the CANsub seam: its raw driver retains tx_ack until the hub has mapped it
// to the logical handle that performed the serialized write.
fn shared_open_events(key string, spec string, make fn (string) !SharedDriver) !Bus {
	for {
		mut handle := ?&SharedHandle(none)
		mut start := ?&SharedEntry(none)
		mut conflict := ''
		mut failure := ''
		mut wait_for_close := false
		// Driver creation remains inside this lock for now, preserving the existing atomic-open
		// behaviour. The important close/reopen rule is stronger than before: a closing generation
		// remains reserved until its reader has exited and physical close has completed.
		lock shared_reg {
			if mut e := shared_reg.entries[key] {
				e.mu.lock()
				if e.state != .running {
					wait_for_close = true
				} else if canonical_spec(e.spec) != canonical_spec(spec) {
					conflict = e.spec
				} else {
					e.refs++
					e.next_id++
					handle = &SharedHandle{
						key:    key
						entry:  e
						id:     e.next_id
						cursor: e.next_seq
						wake:   chan bool{cap: 1}
					}
				}
				e.mu.unlock()
			} else if mut driver := make(spec) {
				mut e := &SharedEntry{
					key:      key
					spec:     spec
					done:     chan bool{cap: 1}
					tx_acks:  driver.reports_tx_ack()
					driver:   driver
					refs:     1
					next_id:  1
					ring:     []SharedRingSlot{len: shared_ring_capacity}
					next_seq: 1
					state:    .running
				}
				shared_reg.entries[key] = e
				handle = &SharedHandle{
					key:    key
					entry:  e
					id:     1
					cursor: 1
					wake:   chan bool{cap: 1}
				}
				start = e
			} else {
				failure = err.msg()
			}
		}
		if wait_for_close {
			// Never join a failed/closing generation and never overlap its physical close. The
			// reservation is normally held for at most one bounded reader poll.
			time.sleep(time.millisecond)
			continue
		}
		if conflict != '' {
			return error('${spec}: this wire is already open as `${conflict}` — one destination cannot be opened twice with different settings')
		}
		if failure != '' {
			return error(failure)
		}
		if mut e := start {
			spawn e.read_loop()
		}
		if mut h := handle {
			// A join still reconciles controller policy because its factory did not run.
			want := is_listen_only(spec)
			h.reconcile_silence(want) or {
				if want {
					h.close()
					return error('${spec}: joined an already-open wire but its controller would not be set listen-only — ${err.msg()}')
				}
			}
			return h
		}
		return error('${spec}: shared_open produced no handle')
	}
	return error('${spec}: shared_open produced no handle')
}

// read_loop is the sole raw receiver for this entry. Timeout is control flow; every other receive
// error is sticky and closes/detaches this generation after waking its logical readers.
fn (mut e SharedEntry) read_loop() {
	for {
		mut should_stop := false
		e.mu.lock()
		should_stop = e.state != .running
		e.mu.unlock()
		if should_stop {
			break
		}
		ingress := e.driver.recv_shared(shared_reader_poll_ms) or {
			mut closing := false
			e.mu.lock()
			closing = e.state != .running
			e.mu.unlock()
			if closing {
				break
			}
			if err.msg() == 'timeout' {
				// The reader poll is also the expiry clock. Without this, one lost final CANsub
				// acknowledgement would retain its payload and origin until another send arrived.
				if e.tx_acks {
					e.mu.lock()
					if e.state == .running {
						e.expire_pending(time.ticks())
					}
					e.mu.unlock()
				}
				continue
			}
			e.fail_and_close(err.msg())
			e.done <- true
			return
		}
		ingress_at := time.ticks()

		// THE READER NEVER WAITS ON A WRITER. It used to take send_mu before matching an
		// acknowledgement, so that an ack made visible by a write that then FAILED would find its
		// pending entry already deleted. The price was the sole reader parking behind every
		// in-flight socket write: a stalled TLS write (device wedged, cable pulled) stopped the
		// ingress loop, CansubBus.rx filled to 4096 and real ECU frames were dropped while sends
		// kept reporting success -- the defect codex round 10 on #204 was written to prevent,
		// re-entered one layer up (code-review high on #221, blocker 1).
		//
		// So an in-flight entry (expires_at == 0) is matchable. If the device acknowledged a frame,
		// the frame REACHED THE WIRE, whatever the write call went on to return -- and a frame that
		// reached the wire belongs in the trace and the recording, attributed to its origin. The
		// sender is told its write failed; the monitor is told the truth about the bus. Dropping
		// that ack hid a transmitted frame from both, which is the "vanishes from trace and
		// recording" class.
		mut origin := u64(0)
		mut publish := true
		e.mu.lock()
		if e.state != .running {
			publish = false
		} else {
			if e.tx_acks {
				// Attribute expiry at hub ingress, not after a TX record has waited behind a later
				// slow send's send_mu hold.
				e.expire_pending(ingress_at)
			}
			if ingress.tx_ack {
				mut found := -1
				for i, pending in e.pending {
					if shared_same_frame(pending.frame, ingress.frame) {
						found = i
						break
					}
				}
				if found < 0 {
					// A local record with no owner is not external traffic. Publishing it as RX can
					// feed a simulator or ISO-TP endpoint its own frame.
					e.unmatched_tx_acks++
					publish = false
				} else {
					origin = e.pending[found].origin
					e.pending.delete(found)
				}
			}
		}
		if publish {
			seq := e.next_seq
			e.ring[int((seq - 1) % u64(shared_ring_capacity))] = SharedRingSlot{
				seq:    seq
				frame:  shared_clone_frame(ingress.frame)
				origin: origin
			}
			e.next_seq++
			for sub in e.subs {
				select {
					sub.wake <- true {}
					else {}
				}
			}
		}
		e.mu.unlock()
	}
	e.done <- true
}

fn (mut e SharedEntry) fail_and_close(message string) {
	e.mu.lock()
	if e.state == .running {
		e.state = .failed
		e.terminal = message
		for sub in e.subs {
			select {
				sub.wake <- true {}
				else {}
			}
		}
	}
	e.mu.unlock()
	// NOT BEHIND send_mu. This used to wait for an in-flight write before releasing the driver,
	// which read as tidy and was the worst half of blocker 1: the reservation stays in the
	// registry for the whole wait, so with a sender stuck in a 30 s socket write every Start on
	// this wire spun in shared_open_events for 30 s -- on the GUI thread. A write racing this
	// close gets the vendor's error for a closed handle and returns it to its caller, which is
	// what happened before this PR and is the honest outcome: the wire is gone.
	e.finish_close()
}

// finish_close is the one teardown sequence, shared by the fatal path and the last close: release
// the driver once, mark the generation closed, forget its pending sends, leave the registry.
// Two copies of this drifted once already in review; there is one now.
fn (mut e SharedEntry) finish_close() {
	e.mu.lock()
	raw_open := !e.raw_closed
	e.raw_closed = true
	e.mu.unlock()
	if raw_open {
		e.driver.close()
	}
	e.mu.lock()
	e.state = .closed
	e.pending.clear()
	e.mu.unlock()
	shared_remove_entry(e)
}

// SharedHandle is one caller's public Bus. Its receive state is just a sequence cursor; a send-only
// handle never enters e.subs, so it adds no work to ingress fanout.
struct SharedHandle {
	key  string
	id   u64
	wake chan bool
	mu   sync.Mutex
mut:
	entry      &SharedEntry = unsafe { nil }
	cursor     u64
	subscribed bool
	dropped    u64
	closed     bool
}

fn (mut h SharedHandle) send(frame CanFrame) ! {
	h.mu.lock()
	closed := h.closed
	h.mu.unlock()
	if closed {
		return error('${h.key}: bus is closed')
	}
	mut e := h.entry
	// send_mu GUARDS ONE THING: that the order of `pending` is the order frames went down the
	// socket, which is what lets an untagged acknowledgement be matched to its origin. Senders on
	// one wire therefore serialise here -- as they must on one socket -- and NOTHING ELSE takes
	// this lock. It used to be a general "is the driver alive" guard for health(),
	// reconcile_silence(), close() and fail_and_close() too, so one sender stuck in a TLS write
	// (V's 30 s default write timeout) froze the Buses row, blocked every other sender BEFORE
	// SilentBus could refuse it, kept Stop from decrementing refs, and left Start spinning on the
	// GUI thread waiting for a close that could not complete. The comment this PR deleted from the
	// old shared.v -- "no lock across the driver call ... serialising here would only add a queue
	// in front of one that already exists" -- was that rule (code-review high on #221, blocker 1).
	e.send_mu.lock()
	defer {
		e.send_mu.unlock()
	}
	h.mu.lock()
	closed_after_wait := h.closed
	h.mu.unlock()
	if closed_after_wait {
		return error('${h.key}: bus is closed')
	}
	mut terminal := ''
	mut running := false
	mut token := u64(0)
	e.mu.lock()
	running = e.state == .running
	terminal = e.terminal
	if running && e.tx_acks {
		now := time.ticks()
		e.expire_pending(now)
		if e.pending.len >= shared_pending_capacity {
			e.pending.delete(0)
			e.expired_tx_acks++
		}
		e.next_send_token++
		token = e.next_send_token
		e.pending << SharedPendingSend{
			token:  token
			origin: h.id
			frame:  shared_clone_frame(frame)
			// Zero means the raw write is still in flight. It cannot expire or match until send()
			// records a deadline after success while still holding send_mu.
			expires_at: 0
		}
	}
	e.mu.unlock()
	if !running {
		if terminal != '' {
			return error(terminal)
		}
		return error('${h.key}: bus is closing')
	}
	e.driver.send(frame) or {
		if token != 0 {
			e.mu.lock()
			for i, pending in e.pending {
				if pending.token == token {
					e.pending.delete(i)
					break
				}
			}
			e.mu.unlock()
		}
		return err
	}
	if token != 0 {
		// The acknowledgement window begins when the write succeeds, not while a slow socket
		// write is still in flight; expiry skips the zero marker. Matching does NOT skip it --
		// see read_loop for why an in-flight entry may be claimed.
		e.mu.lock()
		for i, pending in e.pending {
			if pending.token == token {
				e.pending[i] = SharedPendingSend{
					...pending
					expires_at: time.ticks() + shared_pending_ttl_ms
				}
				break
			}
		}
		e.mu.unlock()
	}
}

fn (mut h SharedHandle) recv(timeout_ms int) !CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		mut got := ?CanFrame(none)
		mut terminal := ''
		h.mu.lock()
		if h.closed {
			h.mu.unlock()
			return error('${h.key}: bus is closed')
		}
		mut e := h.entry
		e.mu.lock()
		if !h.subscribed && e.state == .running {
			e.subs << SharedSubscriber{
				id:   h.id
				wake: h.wake
			}
			h.subscribed = true
		}
		oldest := if e.next_seq > u64(shared_ring_capacity) {
			e.next_seq - u64(shared_ring_capacity)
		} else {
			u64(1)
		}
		if h.cursor < oldest {
			h.dropped += oldest - h.cursor
			h.cursor = oldest
		}
		for h.cursor < e.next_seq {
			slot := e.ring[int((h.cursor - 1) % u64(shared_ring_capacity))]
			h.cursor++
			if slot.seq == h.cursor - 1 && slot.origin != h.id {
				got = shared_clone_frame(slot.frame)
				break
			}
		}
		if got == none && e.terminal != '' {
			terminal = e.terminal
		}
		e.mu.unlock()
		h.mu.unlock()
		if frame := got {
			return frame
		}
		if terminal != '' {
			return error(terminal)
		}
		if timeout_ms >= 0 {
			remaining := deadline - time.ticks()
			if remaining <= 0 {
				return error('timeout')
			}
			select {
				_ := <-h.wake {}
				remaining * time.millisecond {
					return error('timeout')
				}
			}
		} else {
			_ := <-h.wake
		}
	}
	return error('timeout')
}

fn (mut h SharedHandle) health() BusHealth {
	h.mu.lock()
	closed := h.closed
	h.mu.unlock()
	if closed {
		return .unknown
	}
	mut e := h.entry
	// NO LOCK ACROSS THE DRIVER CALL. The monitor polls this once a second per wire; taking
	// send_mu here made that poll wait behind any in-flight write, and a stalled one froze the
	// Buses row and the toolbar for its duration. The state check under e.mu is what decides
	// whether the driver is worth asking; a close racing the call itself gets the vendor's
	// answer for a closed handle, which every backend already reports as .unknown -- exactly
	// what the pre-PR handle did.
	mut running := false
	e.mu.lock()
	running = e.state == .running
	e.mu.unlock()
	if !running {
		return .unknown
	}
	return e.driver.health()
}

fn (mut h SharedHandle) reconcile_silence(want bool) ! {
	h.mu.lock()
	closed := h.closed
	h.mu.unlock()
	if closed {
		return error('${h.key}: bus is closed')
	}
	mut e := h.entry
	// NO LOCK ACROSS THE DRIVER CALL, for the reason health() gives -- and one more: SilentBus
	// calls this before EVERY send, so with send_mu here every sender on the wire queued behind
	// a stalled write before the wrapper could even refuse it, and a listen-only toggle waited out
	// that write before reaching the controller. The controller-side apply is already serialised
	// per wire by silence.v; it needs nothing from here.
	mut running := false
	mut terminal := ''
	e.mu.lock()
	running = e.state == .running
	terminal = e.terminal
	e.mu.unlock()
	if !running {
		if terminal != '' {
			return error(terminal)
		}
		return error('${h.key}: bus is closing')
	}
	e.driver.reconcile_silence(want)!
}

// close removes this cursor, and on the final reference retains the registry reservation until the
// bounded reader exits and the raw driver has physically closed. Idempotence is part of Bus.
fn (mut h SharedHandle) close() {
	h.mu.lock()
	if h.closed {
		h.mu.unlock()
		return
	}
	h.closed = true
	was_subscribed := h.subscribed
	h.subscribed = false
	h.mu.unlock()
	// Wake recv(-1) before waiting for an in-flight send. Its next loop observes closed under
	// h.mu and cannot consume another queued frame after close won the race.
	select {
		h.wake <- true {}
		else {}
	}
	mut e := h.entry
	// Not behind send_mu either -- Stop must be able to let go of a wire whose sender is stuck.
	mut last_healthy := false
	e.mu.lock()
	if was_subscribed {
		e.subs = e.subs.filter(it.id != h.id)
	}
	e.refs--
	if e.refs <= 0 && e.state == .running {
		e.state = .closing
		last_healthy = true
	}
	e.mu.unlock()
	if !last_healthy {
		return
	}
	_ := <-e.done
	e.finish_close()
}
