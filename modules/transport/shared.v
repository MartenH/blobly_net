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

// shared_parked_drain_ms is how often a PARKED reader (nobody subscribes) empties the driver's
// receive queue. Long on purpose: each drain is a driver call, which is the cost the park exists
// to avoid, and a queue that fills between drains costs the driver an overrun count on a frame
// nobody wanted. PCAN's receive queue holds 32768 frames -- an arbitration-saturated classic bus
// delivers ~8000 a second at 500 kbit/s, so a second of queue is never lost. The first subscriber
// does not wait for this: subscribing kicks the reader, and the kick drains too.
const shared_parked_drain_ms = 1000

// shared_attentive_ms is how long a handle that has not yet received still counts as a reader.
// A handle's boundary is its OPEN (its cursor is taken there), and the pattern that depends on
// it is the ordinary one: open, send a request, then receive the reply — which has often arrived
// before the first receive is called. So for this long after open the reader stays awake on a
// handle's behalf whether or not it has received; a handle that has received once counts for the
// rest of its life; and a handle that has done neither in a second is a transmit tap, which is
// what the park is for. What such a tap loses if it receives after all is stated in
// docs/one_reader_per_wire.md.
const shared_attentive_ms = i64(1000)

// shared_boundary_drain_frames bounds the drain a handle runs to establish its own boundary on
// a parked wire (admit, and a late first receive) — by COUNT, sized past the driver's queue. A
// time budget was wrong: on a bus that outruns zero-timeout reads the queue can still BEGIN with
// pre-open frames when the clock runs out, and they would then be published to the handle as
// new (codex round 3 on #224). A count cannot be: PCANBasic's receive queue holds 32768 frames,
// so after this many reads every frame still queued arrived after the drain began — that is,
// after the handle's open — whatever the bus is doing. Worst case is a few hundred milliseconds
// of reads, and only on a saturated bus with a deep backlog.
const shared_boundary_drain_frames = u64(65536)
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
	key  string
	spec string
	done chan bool
	// kick wakes a reader that is PARKED because nobody subscribes — see read_loop. Capacity one, so
	// a kick with nobody parked is remembered exactly once and never blocks the kicker.
	kick    chan bool
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
	// parked_discards counts frames the reader read and threw away while nobody subscribed.
	parked_discards   u64
	// parked is true while the reader waits in its park (under mu) — a test hook, so a test can
	// observe the state rather than sleep and hope.
	parked            bool
	// unread maps each handle that has NOT yet received to the tick it opened at. With subs, it
	// is what decides whether anybody is listening — see attentive_locked.
	unread            map[u64]i64
	// drain_mu is held by the reader across a whole parked drain, and taken by a handle's FIRST
	// receive before it registers as a subscriber. So a subscription cannot land in the middle of
	// a drain: either it registers first and the drain, finding a subscriber, reads nothing — or
	// the drain finishes first and every frame the subscriber is owed is still in the driver's
	// queue (codex round 1 on #224). Never held with mu already held; the reader takes mu only
	// after releasing it.
	drain_mu          sync.Mutex
	// waiting counts handles queued for drain_mu (under mu). The reader holds that lock for a
	// whole poll period per read and re-takes it at once; a mutex is not fair, so a joiner could
	// lose the race for it read after read. The reader yields when somebody is waiting.
	waiting           int
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
					kick:     chan bool{cap: 1}
					tx_acks:  driver.reports_tx_ack()
					driver:   driver
					refs:     1
					next_id:  1
					ring:     []SharedRingSlot{len: shared_ring_capacity}
					next_seq: 1
					state:    .running
				}
				shared_reg.entries[key] = e
				e.unread[1] = time.ticks()
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
			if start == none {
				h.entry.admit(h.id) or {
					// The generation is failed and removed; this handle's close releases its
					// reference and the loop opens a fresh one through the factory.
					h.close()
					continue
				}
			}
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
		mut idle := false
		e.mu.lock()
		should_stop = e.state != .running
		idle = !e.attentive_locked(time.ticks())
		e.mu.unlock()
		if should_stop {
			break
		}
		// PARKED WHILE NOBODY LISTENS, on a driver with nothing to acknowledge. A wire held only by
		// transmit taps — a disabled row keeps its taps open on purpose (#165) — used to make no
		// driver calls at all; with this loop always running, PCAN's recv_shared(50) was a 1 ms
		// CAN_Read loop plus a silence lookup, ~1000 driver reads a second per idle wire, feeding
		// a ring nobody drained, for the life of the entry (code-review high on #221, #222 item 2).
		// The first subscriber kicks the loop awake, and close kicks it so it can notice the state
		// change. The bounded wait is a belt for the braces: a lost kick costs at most one drain
		// period of latency on the first receive, never a hang.
		//
		// PARKED IS NOT STOPPED. A parked reader that made no driver calls at all left the
		// driver's own receive queue filling — on PCAN, every frame on the wire, for as long as
		// nobody subscribed — so the first subscriber was served a queue of frames from before it
		// opened (a late handle starts at the tail; that is the hub's rule, and the driver's
		// queue was breaking it underneath), a fatal read error (a device unplugged) went
		// unnoticed until somebody listened, and a queue that overflowed cost overrun counts on
		// frames nobody wanted (self-review of the first cut). So a parked reader DRAINS AND
		// DISCARDS: once per shared_parked_drain_ms, and on every kick — which is what makes a
		// subscriber's first frame the first frame after it subscribed.
		//
		// WHO COUNTS AS LISTENING is attentive_locked: any handle that has received, and any
		// handle younger than shared_attentive_ms that has not. The first cut parked whenever no
		// handle had received yet, and the repository's own fan-out test — open two handles,
		// inject, receive — failed on it: a frame arriving between open and the first receive
		// was drained away, which is the request/response pattern every diagnostic client uses
		// (codex round 1 on #224, proven by the test). A handle's boundary is its open; the
		// park honours it for as long as a receive can plausibly follow, and a handle silent for
		// a second is a transmit tap.
		//
		// NOT on a tx_ack driver. A CANsub acknowledges every send over the same socket whether or
		// not anybody reads, so its raw reader still needs draining — and its recv_shared is a
		// channel wait, not a driver call, so there is nothing to save by parking it.
		if idle && !e.tx_acks {
			e.mu.lock()
			e.parked = true
			e.mu.unlock()
			select {
				_ := <-e.kick {}
				shared_parked_drain_ms * time.millisecond {}
			}
			e.mu.lock()
			e.parked = false
			woke_failed := e.state != .running
			e.mu.unlock()
			if woke_failed {
				// Failed or closed while parked (a join's boundary drain found the adapter
				// gone): nothing to drain on a generation that is no longer ours.
				break
			}
			// IN BATCHES, RELEASING drain_mu BETWEEN THEM. A drain that ran until it saw an empty
			// queue never released the lock on a bus that delivers at least as fast as the driver
			// reads — and a handle opening onto the wire waited in admit for as long as that
			// lasted, with the last close waiting on the reader behind it (codex round 2 on #224).
			// Between batches a joiner can take the lock and establish its boundary; the loop
			// stops as soon as the wire is attentive or closing.
			for {
				e.drain_mu.lock()
				more := e.drain_parked() or {
					e.drain_mu.unlock()
					e.fail_and_close(err.msg())
					e.done <- true
					return
				}
				e.drain_mu.unlock()
				if !more {
					break
				}
				e.mu.lock()
				stop := e.state != .running || e.attentive_locked(time.ticks())
				e.mu.unlock()
				if stop {
					break
				}
			}
			continue
		}
		// UNDER drain_mu, LIKE A DRAIN. A handle establishing its boundary while this read was
		// in flight — the attentive second expired between the check above and here — could
		// otherwise register before this read's frame was committed, and be handed a frame from
		// before its boundary as new (codex round 3 on #224). The cost is that a joiner waits out
		// one poll period at most.
		e.drain_mu.lock()
		ingress := e.driver.recv_shared(shared_reader_poll_ms) or {
			e.drain_mu.unlock()
			e.yield_to_joiners()
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
		// drain_mu STAYS HELD UNTIL THE FRAME IS COMMITTED below. Released here, a handle could
		// establish its boundary against an empty driver queue and register while this frame —
		// read before its boundary — was still on its way into the ring, and receive it as new
		// (codex round 4 on #224). The publish takes mu inside drain_mu, which is the order every
		// joiner uses.
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
		e.drain_mu.unlock()
		e.yield_to_joiners()
	}
	e.done <- true
}

// admit makes a handle joining an existing wire count as a reader from now on, and — if the wire
// was parked — drains the driver's queue FIRST, under drain_mu, so the handle's boundary is its
// open: everything queued before this moment is from before it, everything after is its own,
// because the reader wakes on the kick and finds the wire attentive. Done here rather than in
// the registry lock because a drain is driver I/O.
//
// A FATAL READ HERE FAILS THE GENERATION, AND THE JOIN. This drain is the first driver call on
// a parked wire since the last one, so it is where an adapter unplugged meanwhile is found —
// and swallowing that handed the caller a handle on a dead generation whose first receive then
// failed and took every alias on the wire down, instead of the open going through the factory
// to the reconnected adapter (codex rounds 1 and 2 on #224). fail_and_close is the same call the
// reader makes: it is idempotent, and a reader parked or mid-read finds the state changed.
// take_drain_lock is drain_mu.lock() with the reader told to yield — see `waiting`.
fn (mut e SharedEntry) take_drain_lock() {
	e.mu.lock()
	e.waiting++
	e.mu.unlock()
	e.drain_mu.lock()
	e.mu.lock()
	e.waiting--
	e.mu.unlock()
}

// yield_to_joiners is what the reader does between reads while a handle waits for drain_mu: a
// millisecond off the lock, so the waiter gets it. Nothing is lost — the driver queues meanwhile.
fn (mut e SharedEntry) yield_to_joiners() {
	e.mu.lock()
	waiting := e.waiting > 0
	e.mu.unlock()
	if waiting {
		time.sleep(time.millisecond)
	}
}

fn (mut e SharedEntry) admit(id u64) ! {
	e.take_drain_lock()
	e.mu.lock()
	parked := !e.attentive_locked(time.ticks())
	e.mu.unlock()
	if parked && !e.tx_acks {
		_ := e.drain_boundary(0) or {
			e.drain_mu.unlock()
			e.fail_and_close(err.msg())
			// AND THE FAILED READER IS RETIRED BEFORE THE CALLER REOPENS. It is parked; woken,
			// it finds the state changed and exits, sending done — which nothing else consumes
			// on a failed generation (close waits only on a healthy last close). Without this
			// the replacement generation could be opened while the old reader still had one
			// post-park batch to run on the same PCAN channel constant, stealing the
			// replacement's frames (codex round 3 on #224).
			select {
				e.kick <- true {}
				else {}
			}
			_ := <-e.done
			return err
		}
	}
	e.mu.lock()
	e.unread[id] = time.ticks()
	e.mu.unlock()
	e.drain_mu.unlock()
	select {
		e.kick <- true {}
		else {}
	}
}

// drain_boundary runs drain_parked in batches until the queue is empty or
// shared_boundary_drain_frames have been read — a handle establishing its own boundary, under
// drain_mu. `until` is a caller's deadline in ticks (0 for none): a receive with a budget of its
// own stops when that budget is spent, and accepts an approximate boundary rather than blocking
// past what it asked for (codex round 3 on #224).
// Returns whether the boundary was ESTABLISHED — the queue empty, or the count reached — as
// opposed to the caller's deadline stopping it first. A deadline is checked BEFORE every batch,
// so a receive with no budget left reads nothing at all (codex round 4 on #224).
fn (mut e SharedEntry) drain_boundary(until i64) !bool {
	mut read := u64(0)
	for read < shared_boundary_drain_frames {
		if until > 0 && time.ticks() >= until {
			return false
		}
		before := e.discards()
		more := e.drain_parked()!
		read += e.discards() - before
		if !more {
			return true
		}
	}
	return true
}

fn (mut e SharedEntry) discards() u64 {
	e.mu.lock()
	n := e.parked_discards
	e.mu.unlock()
	return n
}

// attentive_locked is whether anybody is listening on this wire: a handle that has received,
// or one that opened less than shared_attentive_ms ago and may still. Caller holds mu.
fn (e &SharedEntry) attentive_locked(now i64) bool {
	if e.subs.len > 0 {
		return true
	}
	for _, opened in e.unread {
		if now - opened < shared_attentive_ms {
			return true
		}
	}
	return false
}

// drain_parked empties the driver's receive queue while nobody subscribes, DISCARDING what it
// finds — see read_loop, shared_open_events (a handle opening onto a parked wire) and the first
// receive in SharedHandle.recv (an old transmit tap that receives after all).
// Called with drain_mu held, so no subscription can land while it runs; it checks for one first
// and reads nothing if there is, because everything in the queue then belongs to that
// subscriber, who drained before registering. Zero-timeout reads, so an empty queue costs one
// driver call, and it runs until the queue IS empty: a bound below one park's worth of traffic
// (a saturated classic bus queues ~8000 frames a second; the first cut stopped at 4096) left the
// remainder to be published as current ingress to the subscriber that woke the reader (codex
// round 1 on #224). One BATCH per call — up to the ring capacity — and the answer is whether the queue
// may hold more; the callers decide how to loop (the reader releases drain_mu between batches,
// a joiner keeps it and stops on a time budget). A fatal read error is returned as the error,
// and it is the caller's to act on.
fn (mut e SharedEntry) drain_parked() !bool {
	e.mu.lock()
	claimed := e.attentive_locked(time.ticks())
	e.mu.unlock()
	if claimed {
		return false
	}
	mut n := u64(0)
	mut more := true
	mut fatal := ''
	for n < u64(shared_ring_capacity) {
		e.driver.recv_shared(0) or {
			if err.msg() != 'timeout' {
				fatal = err.msg()
			}
			more = false
			break
		}
		n++
	}
	e.mu.lock()
	e.parked_discards += n
	e.mu.unlock()
	if fatal != '' {
		return error(fatal)
	}
	return more
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
	subscribed := h.subscribed
	h.mu.unlock()
	if closed {
		return error('${h.key}: bus is closed')
	}
	mut e := h.entry
	// A SEND KEEPS A HANDLE ATTENTIVE. Attentiveness tracked opens and receives only, so a
	// diagnostic channel that sat idle for a second and then sent a request was an expired tap
	// by the time the reply arrived — and the reply was drained away, by the next parked drain
	// or by the handle's own boundary drain on its first receive (codex round 4 on #224).
	// Delayed send-then-receive is the request/response path, not a transmit-only tap; the
	// attentive second starts again at every send, and a parked reader is woken for it.
	if !subscribed {
		e.mu.lock()
		e.unread[h.id] = time.ticks()
		e.mu.unlock()
		select {
			e.kick <- true {}
			else {}
		}
	}
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
		// THE FIRST RECEIVE ON AN UNREAD WIRE DRAINS THE DRIVER ITSELF, under drain_mu, BEFORE it
		// registers. Everything queued at that moment is from before this handle listened; a
		// frame arriving after the drain is this handle's, because registration follows under
		// the same lock and the reader — which reads the driver only inside drain_mu while
		// nobody subscribes — cannot drain it away meanwhile. Leaving the drain to the reader's
		// wake-up was wrong in both orders: draining after registration discarded frames the
		// subscriber was owed, and reading nothing once a subscriber existed served it the
		// pre-registration queue as new (codex round 1 on #224, and the test that caught the
		// second). A fatal read error found here is left for the reader's next poll, which is
		// the path that knows how to take a generation down.
		joining := !h.subscribed
		if joining {
			e.take_drain_lock()
			e.mu.lock()
			unread := !e.attentive_locked(time.ticks())
			e.mu.unlock()
			if unread {
				// AN EXPIRED TAP'S HISTORY BEGINS HERE — on a wire NOBODY was reading, which is what
				// `unread` means: the wire as a whole, not this handle. Where another subscriber kept
				// the reader awake, the ring holds this handle's history since its open and its cursor
				// stands (codex round 5 on #224 read the doc the other way; the doc now says this).
				// As docs/one_reader_per_wire.md says: the
				// ring may still hold what was committed on its behalf in its attentive second,
				// and its open-time cursor would have served that as new (codex round 3 on
				// #224). The tail is its boundary now, and the driver's queue is drained to it —
				// within the caller's own budget: a receive that asked for 0 ms is not made to
				// wait out a backlog, and takes an approximate boundary instead.
				e.mu.lock()
				h.cursor = e.next_seq
				e.mu.unlock()
				if !e.tx_acks {
					// AND A DRAIN THE DEADLINE CUT SHORT DOES NOT SUBSCRIBE. Registered after a
					// partial drain, the handle would be served the rest of the backlog as new;
					// instead this receive reports a timeout with the boundary NOT established,
					// and the next receive with a budget continues from where the queue is now
					// (codex round 4 on #224). A handle that only ever polls with 0 ms after a
					// second of silence therefore never subscribes on a backlogged wire — the
					// GUI and the Lua runner receive with a budget, and a send would have kept
					// the handle attentive in the first place.
					established := e.drain_boundary(if timeout_ms < 0 { i64(0) } else { deadline }) or {
						// The adapter is gone, and this receive is the one that found out: the
						// generation fails here, as it would under the reader, and the error is
						// this caller's answer (codex round 3 on #224).
						e.drain_mu.unlock()
						e.fail_and_close(err.msg())
						select {
							e.kick <- true {}
							else {}
						}
						_ := <-e.done
						h.mu.unlock()
						return err
					}
					if !established {
						e.drain_mu.unlock()
						h.mu.unlock()
						return error('timeout')
					}
				}
			}
		}
		e.mu.lock()
		if !h.subscribed && e.state == .running {
			e.subs << SharedSubscriber{
				id:   h.id
				wake: h.wake
			}
			h.subscribed = true
			e.unread.delete(h.id)
			// Wake a parked reader: this handle is the first to listen, or the first since the last
			// listener left. Non-blocking; a kick already queued is the same kick.
			select {
				e.kick <- true {}
				else {}
			}
		}
		if joining {
			e.drain_mu.unlock()
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
	e.unread.delete(h.id)
	e.refs--
	if e.refs <= 0 && e.state == .running {
		e.state = .closing
		last_healthy = true
	}
	e.mu.unlock()
	if last_healthy {
		// The reader may be parked with nobody subscribed — which on a closing wire is the common
		// case. Kick it so `<-e.done` below does not wait out the park's full second.
		select {
			e.kick <- true {}
			else {}
		}
	}
	if !last_healthy {
		return
	}
	_ := <-e.done
	e.finish_close()
}
