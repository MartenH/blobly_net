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

// shared_failed_send_grace_ms is how long a FAILED write's pending entry stays matchable. The
// device may still acknowledge it -- the bytes can reach the wire before the call reports
// failure, and that acknowledgement is either already in the reader's hands or one poll away --
// but a write that never reached the wire will never be acknowledged, and for as long as its
// entry stands an identical frame from ANOTHER handle is credited to it: wrong origin, and the
// real sender receives its own frame as RX (#139's class). So the window is ten reader polls,
// not the ordinary five seconds: enough for a starved reader to match what it already holds,
// short enough that a ghost cannot claim a cyclic sibling's next frame.
const shared_failed_send_grace_ms = 500

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
	diagnostics() BusDiagnostics
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

fn (mut d SharedBusDriver) diagnostics() BusDiagnostics {
	return d.bus.diagnostics()
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
	// failed marks a write the driver reported as failed: kept briefly in case the device
	// acknowledges it anyway (see send), and counted apart when it expires, so that
	// expired_tx_acks keeps meaning "a write that succeeded and was never acknowledged".
	failed bool
}

enum SharedEntryState {
	// opening is the reservation: the entry is in the registry, its factory is running OUTSIDE
	// the registry lock, and it has no driver yet. Nothing joins it, nothing reads it (see
	// shared_open_events).
	opening
	running
	closing
	failed
	closed
}

// SharedNoDriver stands in for a driver that does not exist yet -- an entry in `opening`. Every
// path that could reach a driver is gated on `running`, so none of these should ever run; if one
// does, it answers as a closed bus rather than dereferencing nothing (#147's hazard, made loud).
struct SharedNoDriver {}

fn (mut d SharedNoDriver) send(frame CanFrame) ! {
	return error('bus is not open yet')
}

fn (mut d SharedNoDriver) recv_shared(timeout_ms int) !SharedIngress {
	return error('bus is not open yet')
}

fn (mut d SharedNoDriver) close() {}

fn (mut d SharedNoDriver) health() BusHealth {
	return .unknown
}

fn (mut d SharedNoDriver) reconcile_silence(want bool) ! {
	return error('bus is not open yet')
}

fn (mut d SharedNoDriver) reports_tx_ack() bool {
	return false
}

// SharedEntry is one physical-open generation. `mu` protects its ring, subscribers and lifecycle;
// the process-wide registry lock protects key ownership and is held across no I/O -- a first
// open runs its factory behind an `opening` reservation (see shared_open_events) -- and never
// touches the per-frame path. `send_mu` preserves the raw-write order used to correlate CANsub's untagged TX
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
	// settled is CLOSED by the first opener when its attempt has an outcome, success or failure:
	// a closed channel wakes every waiter at once, which is the broadcast a cap-1 token cannot
	// do. Waiters block on it -- unbounded, and on purpose: a bounded wait is a timed select,
	// and under starvation a timed select can be handed a negative remainder by V's runtime and
	// panic (docs/known_issues.md, "sem_timedwait: Invalid argument"). Every path out of the
	// attempt closes it, so nothing is waited for that cannot come.
	settled chan bool
mut:
	tx_acks bool
	driver  SharedDriver
	// open_failure is why the FIRST OPEN of this generation failed, written by the open path
	// only -- never by the reader, whose terminal error belongs to a generation that did open.
	// A waiter that finds its attempt gone reads this and nothing else: empty means the attempt
	// succeeded and the generation has since left, which is a fresh open, not an error.
	open_failure string
	// opening_waiters counts callers waiting on this attempt (under mu) -- a test hook.
	opening_waiters   int
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

	// expired_failed_sends counts failed writes whose grace ended without an acknowledgement:
	// frames that never reached the wire, as the sender was already told.
	expired_failed_sends u64

	// ring_gaps counts frames the ring overwrote under SOME handle's cursor before it read them,
	// summed over every handle the wire has had (under mu): the WIRE's loss, which is what a
	// row shows, where each handle's own `dropped` is that cursor's and dies with it (#213).
	// AN UPPER BOUND, by sequence: a slot overwritten unread is counted whatever its origin, so
	// on a CANsub wire a sender that fell behind counts its own acknowledgements -- which it
	// would have skipped -- among what it lost. Exact needs each overwritten slot's origin, and
	// the overwrite is what destroyed it (codex round 3 on #231).
	ring_gaps u64
	// parked_discards counts frames the reader read and threw away while nobody subscribed.
	parked_discards   u64
	// parked is true while the reader waits in its park (under mu) — a test hook, so a test can
	// observe the state rather than sleep and hope.
	parked            bool
	// unread maps each handle that has NOT yet received to the tick it opened at. With subs, it
	// is what decides whether anybody is listening — see attentive_locked.
	unread            map[u64]i64
	// pending_admit is every handle inserted into this entry but not yet admitted (under mu).
	// A drain that cannot see a pending join discards frames that join is owed — so a pending
	// join makes the wire attentive to the READER (no parked drain), and to another joiner's
	// boundary drain it means PUBLISH rather than discard: the frames go into the ring behind
	// the pending join's open-time cursor, and the draining joiner takes its own cursor at the
	// tail afterwards (codex rounds 7 and 10 on #224).
	pending_admit     map[u64]bool
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
// attributed to a stale send. EVERY stamped entry is examined, not a prefix: the list is in write
// order but the deadlines are not -- a failed write's grace is short and a successful write's
// window is long, so a ghost queued behind a live earlier send would otherwise outlive its grace
// by the whole of the earlier window (codex round 1 on #228). An in-flight entry (expires_at 0)
// is kept wherever it stands; removing entries around it does not change the order of the rest,
// which is what oldest-equal-first matching depends on.
fn (mut e SharedEntry) expire_pending(now i64) {
	// Looked at before anything is rebuilt: this runs before every send, under e.mu, and with
	// acknowledgements delayed the list is long and nothing in it has expired yet, so a rebuild
	// per call would make sending quadratic and keep the reader off the lock (codex round 2 on
	// #228).
	mut any := false
	for pending in e.pending {
		if pending.expires_at > 0 && pending.expires_at <= now {
			any = true
			break
		}
	}
	if !any {
		return
	}
	mut kept := []SharedPendingSend{cap: e.pending.len}
	for pending in e.pending {
		if pending.expires_at > 0 && pending.expires_at <= now {
			e.retire_pending(pending)
			continue
		}
		kept << pending
	}
	e.pending = kept
}

// retire_pending counts a pending entry that is leaving the list unacknowledged: a write that
// failed was never a lost acknowledgement, whichever path removes it. Caller holds mu.
fn (mut e SharedEntry) retire_pending(pending SharedPendingSend) {
	if pending.failed {
		e.expired_failed_sends++
	} else {
		e.expired_tx_acks++
	}
}

// start_pending_window stamps the deadline on the pending entry `token` (0: the driver reports
// no acks, nothing was recorded). Called once per send, when the raw write returns.
fn (mut e SharedEntry) start_pending_window(token u64, ttl_ms i64, failed bool) {
	if token == 0 {
		return
	}
	e.mu.lock()
	// Appended at registration, so the entry is almost always the last one.
	for i := e.pending.len - 1; i >= 0; i-- {
		if e.pending[i].token == token {
			e.pending[i] = SharedPendingSend{
				...e.pending[i]
				expires_at: time.ticks() + ttl_ms
				failed:     failed
			}
			break
		}
	}
	e.mu.unlock()
}

// book_gap_locked moves a cursor that has fallen behind the ring up to the oldest retained
// sequence and counts what it skipped, for the handle and for the wire. Caller holds e.mu and
// h.mu. Run at receive, at a subscriber's close, and when a subscriber's diagnostics are asked
// for -- the frames are gone whichever of those happens first, and a report taken before the
// close would otherwise be a sample short (codex round 3 on #231).
fn (mut e SharedEntry) book_gap_locked(mut h SharedHandle) {
	oldest := if e.next_seq > u64(shared_ring_capacity) {
		e.next_seq - u64(shared_ring_capacity)
	} else {
		u64(1)
	}
	if h.cursor < oldest {
		h.dropped += oldest - h.cursor
		e.ring_gaps += oldest - h.cursor
		h.cursor = oldest
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
//
// THE FACTORY RUNS OUTSIDE THE REGISTRY LOCK, behind a per-key reservation. It used to run inside
// it, which was harmless while every open was a driver call and only PCAN came through here; a
// CANsub open is a REST PUT, a clock sync and a WebSocket connect against a device found by mDNS,
// and a device reachable enough to stall but not to answer held every other opener in the
// process -- other vendors included -- for the whole of its budget (#211, codex round 8 on
// #204). So a first opener publishes the entry in `opening`, with no driver, and releases the
// registry lock before it calls make(); a second opener that finds `opening` waits for THAT
// attempt rather than starting its own -- which is also what stops a GUI Start, whose monitor
// and two transmit taps all open one wire, from paying an unavailable device three times over.
// On success the entry is filled in and becomes `running` -- only once the controller's policy
// has been applied too; on failure -- the factory's, or that reconcile's -- the failure is recorded on the entry,
// the entry is removed, and every waiter on that attempt gets that error. A caller arriving
// after the removal opens afresh, as before: a failed open still publishes nothing to join.
//
// WHAT A WAITER IS TOLD is the OPEN's outcome and nothing else. It remembers the attempt it
// waited on, and when that attempt has left the registry it reads its open_failure: set, that
// is the answer; empty, the attempt succeeded and the generation has since died or closed,
// which is a fresh open -- the reader's terminal error is never handed to an opener as the
// reason its open failed (self-review). A spec that contradicts the reservation is refused at
// once, not after waiting out a stalled attempt for an error about a rate it never asked for.
//
// No handle is ever issued for an `opening` entry -- that is the hazard #147 was (a second
// opener handed a handle to an entry whose bus did not exist). Joins are gated on `running`,
// the reader is spawned only after the driver is in place, and until then the driver is a
// SharedNoDriver that refuses everything.
fn shared_open_events(key string, spec string, make fn (string) !SharedDriver) !Bus {
	// The attempt this caller has been waiting on, if any.
	mut waited := ?&SharedEntry(none)
	for {
		mut handle := ?&SharedHandle(none)
		mut start := ?&SharedEntry(none)
		mut conflict := ''
		mut wait := false
		mut settled := chan bool{cap: 1}
		mut shared_failure := ''
		mut retry := false
		lock shared_reg {
			// The attempt this caller waited on has left the registry -- the key is absent or
			// belongs to a different generation: its outcome is this caller's answer, read
			// BEFORE the absent key could be taken for a fresh attempt.
			if mut w := waited {
				current := shared_reg.entries[key] or { unsafe { nil } }
				if voidptr(current) != voidptr(w) {
					w.mu.lock()
					shared_failure = w.open_failure
					w.mu.unlock()
					waited = none
					retry = shared_failure == ''
				}
			}
			if shared_failure != '' || retry {
				// resolved below, outside the lock
			} else if mut e := shared_reg.entries[key] {
				e.mu.lock()
				if e.state in [.opening, .running] && canonical_spec(e.spec) != canonical_spec(spec) {
					conflict = e.spec
				} else if e.state == .opening {
					wait = true
					if waited == none {
						e.opening_waiters++
					}
					waited = e
					settled = e.settled
				} else if e.state != .running {
					// Never join a failed/closing generation and never overlap its physical
					// close. The reservation is normally held for at most one bounded reader
					// poll.
					wait = true
				} else {
					e.refs++
					e.next_id++
					e.pending_admit[e.next_id] = true
					handle = &SharedHandle{
						key:    key
						entry:  e
						id:     e.next_id
						cursor: e.next_seq
						wake:   chan bool{cap: 1}
					}
				}
				e.mu.unlock()
			} else {
				mut e := &SharedEntry{
					key:      key
					spec:     spec
					done:     chan bool{cap: 1}
					kick:     chan bool{cap: 1}
					settled:  chan bool{cap: 1}
					driver:   &SharedNoDriver{}
					next_seq: 1
					state:    .opening
				}
				shared_reg.entries[key] = e
				start = e
			}
		}
		if shared_failure != '' {
			return error(shared_failure)
		}
		if retry {
			continue
		}
		if wait {
			if waited != none {
				// Woken by the opener closing `settled` -- see the field for why there is no
				// bound on this wait.
				_ := <-settled
			} else {
				time.sleep(time.millisecond)
			}
			continue
		}
		if conflict != '' {
			return error('${spec}: this wire is already open as `${conflict}` — one destination cannot be opened twice with different settings')
		}
		if mut e := start {
			mut driver := make(spec) or {
				e.fail_open(err.msg())
				return err
			}
			// THE CONTROLLER'S POLICY IS PART OF THE ATTEMPT, so the entry stays `opening` until
			// it has been applied: set `running` first and a waiter woken by its bound could join
			// during a listen-only reconcile that then failed -- the first opener's close was no
			// longer the last, the failed entry stayed, and the waiters retried or returned
			// handles instead of sharing the refusal (codex round 1 on #230). Asked of the
			// driver directly: the handle's own reconcile refuses an entry that is not running.
			want := is_listen_only(spec)
			driver.reconcile_silence(want) or {
				if want {
					message := '${spec}: opened, but its controller would not be set listen-only — ${err.msg()}'
					e.mu.lock()
					e.driver = driver
					e.mu.unlock()
					e.fail_open(message)
					return error(message)
				}
			}
			e.mu.lock()
			e.tx_acks = driver.reports_tx_ack()
			e.driver = driver
			// The ring is allocated HERE, not at the reservation: a quarter-megabyte nobody reads
			// until the generation runs, and garbage on every failed attempt otherwise.
			e.ring = []SharedRingSlot{len: shared_ring_capacity}
			e.refs = 1
			e.next_id = 1
			e.unread[1] = time.ticks()
			e.state = .running
			e.mu.unlock()
			mut h := &SharedHandle{
				key:    key
				entry:  e
				id:     1
				cursor: 1
				wake:   chan bool{cap: 1}
			}
			spawn e.read_loop()
			e.settled.close()
			h.entry.touch(h.id)
			return h
		}
		if mut h := handle {
			h.entry.admit(mut h) or {
				// The generation is failed and removed; this handle's close releases its
				// reference and the loop opens a fresh one through the factory.
				h.close()
				continue
			}
			// A join still reconciles controller policy because its factory did not run.
			want := is_listen_only(spec)
			h.reconcile_silence(want) or {
				if want {
					h.close()
					return error('${spec}: joined an already-open wire but its controller would not be set listen-only — ${err.msg()}')
				}
			}
			// The attentive second starts when the CALLER gets the handle, not when it was
			// admitted: a reconcile that waited behind a mid-run silence transition could
			// otherwise spend the second before open returned, and the first receive would
			// find the reader parked (codex round 9 on #224).
			h.entry.touch(h.id)
			return h
		}
		return error('${spec}: shared_open produced no handle')
	}
	return error('${spec}: shared_open produced no handle')
}

// fail_open ends a reservation whose factory failed: the failure is recorded for the waiters
// (never empty -- an empty message would read as "the attempt succeeded"), the generation goes
// through the one teardown sequence, and the waiters are woken.
fn (mut e SharedEntry) fail_open(message string) {
	e.mu.lock()
	e.state = .failed
	e.open_failure = if message == '' { '${e.spec}: open failed' } else { message }
	e.terminal = e.open_failure
	e.mu.unlock()
	e.finish_close()
	e.settled.close()
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
				more := e.drain_parked(false, false) or {
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
			mut closing := false
			e.mu.lock()
			closing = e.state != .running
			e.mu.unlock()
			if closing {
				e.drain_mu.unlock()
				break
			}
			if err.msg() != 'timeout' {
				// THE FAILURE IS TAKEN UNDER drain_mu, before the lock is released: a joiner
				// queued on it must find the generation failed and go back to the factory,
				// not be admitted to a dead handle in the millisecond the reader yields
				// (codex round 8 on #224).
				e.fail_and_close(err.msg())
				e.drain_mu.unlock()
				e.done <- true
				return
			}
			e.drain_mu.unlock()
			e.yield_to_joiners()
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
			continue
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
		// So an in-flight entry (expires_at == 0) is matchable -- and so, briefly, is a FAILED
		// write's (see send). If the device acknowledged a frame, the frame REACHED THE WIRE,
		// whatever the write call went on to return -- and a frame that
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
// touch restarts an unread handle's attentive second, on a running entry only.
fn (mut e SharedEntry) touch(id u64) {
	e.mu.lock()
	if e.state == .running {
		if _ := e.unread[id] {
			e.unread[id] = time.ticks()
		}
	}
	e.mu.unlock()
}

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

//
// TWO JOINERS AT ONCE are serialised by drain_mu, and the handle's cursor is taken HERE, at the
// end of its admission, not at insertion. Taken at insertion, a second joiner's cursor stood
// while the first joiner's boundary drain discarded frames that arrived after it — frames the
// second was owed (codex round 7 on #224). Under drain_mu nothing is committed (the reader is
// parked, or holds this lock to commit), so the tail now IS this handle's boundary, and what is
// in the driver's queue after the drain is published behind it.
//
// AND A FAILED GENERATION IS NOT ADMITTED TO. The failure below is taken under drain_mu and the
// reader's exit awaited under it, so a second joiner queued on the lock finds the state failed
// and returns to shared_open's loop for a fresh generation — instead of draining a closed
// driver and waiting on a `done` the first joiner already consumed (codex round 7 on #224).
fn (mut e SharedEntry) admit(mut h SharedHandle) ! {
	e.take_drain_lock()
	e.mu.lock()
	failed := e.state != .running
	terminal := e.terminal
	parked := !e.readers_locked(time.ticks())
	// Another join inserted but not yet admitted: its cursor is at its insertion, so what this
	// drain finds is committed, not discarded — see pending_admit.
	others := e.pending_admit.len > 1 || (e.pending_admit.len == 1 && !(h.id in e.pending_admit))
	e.mu.unlock()
	if failed {
		e.mu.lock()
		e.pending_admit.delete(h.id)
		e.mu.unlock()
		e.drain_mu.unlock()
		if terminal != '' {
			return error(terminal)
		}
		return error('${e.key}: generation failed while joining')
	}
	if parked && !e.tx_acks {
		_ := e.drain_boundary(0, true, others) or {
			// The failure is taken under the lock (a queued joiner must find it), the reader is
			// retired with the lock RELEASED: it may be blocked on drain_mu for its next batch,
			// and only it sends done (codex round 10 on #224).
			e.fail_and_close(err.msg())
			e.mu.lock()
			e.pending_admit.delete(h.id)
			e.mu.unlock()
			e.drain_mu.unlock()
			select {
				e.kick <- true {}
				else {}
			}
			_ := <-e.done
			return err
		}
	}
	e.mu.lock()
	if parked && !e.tx_acks {
		// Only where a drain ran on a driver whose reader parks: a CANsub's reader never parks
		// (it acknowledges over the same socket) and keeps committing, so its ring holds this
		// handle's history since its open and the cursor stands (codex round 10 on #224).
		h.cursor = e.next_seq
	}
	e.unread[h.id] = time.ticks()
	e.pending_admit.delete(h.id)
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
fn (mut e SharedEntry) drain_boundary(until i64, join bool, publish bool) !bool {
	mut read := u64(0)
	for read < shared_boundary_drain_frames {
		if until > 0 && time.ticks() >= until {
			ingress := e.driver.recv_shared(0) or {
				if err.msg() == 'timeout' {
					return true
				}
				return err
			}
			if publish {
				e.commit_external(ingress.frame)
			} else {
				e.mu.lock()
				e.parked_discards++
				e.mu.unlock()
			}
			return false
		}
		before := e.discards()
		more := e.drain_parked(join, publish)!
		read += if publish { u64(1) } else { e.discards() - before }
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
	return e.attentive_except(now, 0)
}

// attentive_except is attentive_locked with one pending admission — the caller's own — left
// out. Caller holds mu.
fn (e &SharedEntry) attentive_except(now i64, id u64) bool {
	if e.readers_locked(now) {
		return true
	}
	for pending, _ in e.pending_admit {
		if pending != id {
			return true
		}
	}
	return false
}

// readers_locked is whether anybody is actually READING — subscribed, or young and unread —
// with pending admissions left out entirely. It is what a joiner asks before its boundary
// drain: another pending join must not talk it out of draining (then nobody drains and both
// are served the backlog — codex round 11 on #224); it only turns the drain from discard into
// publish. Caller holds mu.
fn (e &SharedEntry) readers_locked(now i64) bool {
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
// `join` is a handle's boundary drain (pending admissions do not count as readers to it — see
// readers_locked); the reader passes false. `publish` commits what is read instead of
// discarding it, for a drain run while another join is pending.
fn (mut e SharedEntry) drain_parked(join bool, publish bool) !bool {
	e.mu.lock()
	claimed := if join { e.readers_locked(time.ticks()) } else { e.attentive_locked(time.ticks()) }
	e.mu.unlock()
	if claimed {
		return false
	}
	mut n := u64(0)
	mut more := true
	mut fatal := ''
	for n < u64(shared_ring_capacity) {
		ingress := e.driver.recv_shared(0) or {
			if err.msg() != 'timeout' {
				fatal = err.msg()
			}
			more = false
			break
		}
		if publish {
			e.commit_external(ingress.frame)
		}
		n++
	}
	if !publish {
		e.mu.lock()
		e.parked_discards += n
		e.mu.unlock()
	}
	if fatal != '' {
		return error(fatal)
	}
	return more
}

// commit_external appends a frame nobody in this process sent to the ring — a boundary drain
// publishing on behalf of a pending join. No acknowledgement matching: only drivers that do not
// report tx acks park, so nothing here can be ours.
fn (mut e SharedEntry) commit_external(frame CanFrame) {
	e.mu.lock()
	if e.state == .running {
		seq := e.next_seq
		e.ring[int((seq - 1) % u64(shared_ring_capacity))] = SharedRingSlot{
			seq:    seq
			frame:  shared_clone_frame(frame)
			origin: 0
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
	//
	// AND AN EXPIRED SENDER'S BOUNDARY IS ESTABLISHED FIRST, under drain_mu, exactly as a
	// joining handle's is: merely marking it attentive woke the reader onto a queue of old
	// traffic, which was then published ahead of the reply to the request about to go out
	// (codex round 9 on #224). admit is that path — the drain if the wire is parked, the cursor
	// at the tail, the timestamp, the kick — and a fatal found by that drain fails the send the
	// way it fails a join.
	if !subscribed {
		// A SENDER STILL ATTENTIVE ONLY REFRESHES: admission takes drain_mu, which the reader
		// holds across every 50 ms poll on an attentive wire, so a cyclic generator's transmit
		// tap paid up to a poll period per frame for a boundary it did not need (codex round 12
		// on #224). Only a handle whose own second has expired goes through admit.
		e.mu.lock()
		now := time.ticks()
		mut fresh := false
		if opened := e.unread[h.id] {
			if now - opened < shared_attentive_ms {
				e.unread[h.id] = now
				fresh = true
			}
		}
		e.mu.unlock()
		if !fresh {
			e.admit(mut h)!
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
			e.retire_pending(e.pending[0])
			e.pending.delete(0)
		}
		e.next_send_token++
		token = e.next_send_token
		e.pending << SharedPendingSend{
			token:  token
			origin: h.id
			frame:  shared_clone_frame(frame)
			// Zero means the raw write is still in flight: expiry skips it, matching does not
			// (see read_loop), and send() stamps the deadline when the write returns.
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
	// A FAILED WRITE KEEPS ITS ENTRY, for shared_failed_send_grace_ms. It used to be deleted
	// here, which raced the reader: the acknowledgement is taken off the socket at the driver
	// seam and matched under e.mu a moment later, so on a two-core runner this path won often
	// enough to delete the entry first, and the ack was counted unmatched and dropped -- the
	// "vanishes from trace and recording" outcome read_loop's in-flight rule exists to prevent,
	// four CI runs out of four (#227). Whichever thread reaches the hub first, the frame the
	// device acknowledged now exists; the sender is still told its write failed.
	e.driver.send(frame) or {
		e.start_pending_window(token, shared_failed_send_grace_ms, true)
		return err
	}
	// The acknowledgement window begins when the write returns, not while a slow socket write
	// is still in flight; expiry skips the zero marker, matching does not (see read_loop).
	e.start_pending_window(token, shared_pending_ttl_ms, false)
	// AND AGAIN NOW THAT THE FRAME IS ON THE WIRE. The refresh above was taken before a write
	// that can wait on send_mu or stall in the driver; if that took longer than the attentive
	// second, the reader could park the moment the frame left and drain the prompt reply
	// (codex round 8 on #224). The reply clock starts here — unless the handle was closed
	// while the write was in flight, in which case close() has already removed it and a
	// refresh would put a dead handle back (codex round 9 on #224).
	if !subscribed {
		h.mu.lock()
		gone := h.closed || h.subscribed
		h.mu.unlock()
		if !gone {
			e.mu.lock()
			if e.state == .running {
				e.unread[h.id] = time.ticks()
			}
			e.mu.unlock()
			select {
				e.kick <- true {}
				else {}
			}
		}
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
		mut holding := joining
		if joining {
			e.take_drain_lock()
			e.mu.lock()
			failed_now := e.state != .running
			mut unread := !e.readers_locked(time.ticks())
			pending_join := e.pending_admit.len > 0
			e.mu.unlock()
			if failed_now {
				// Failed while this handle waited for the lock: the terminal error is read below
				// like any other, once the lock is dropped.
				e.drain_mu.unlock()
				holding = false
				unread = false
			}
			if unread && !e.tx_acks {
				e.mu.lock()
				h.cursor = e.next_seq
				e.mu.unlock()
				{
					established := e.drain_boundary(if timeout_ms < 0 { i64(0) } else { deadline },
						true, pending_join) or {
						e.fail_and_close(err.msg())
						e.drain_mu.unlock()
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
		if holding {
			e.drain_mu.unlock()
		}
		e.book_gap_locked(mut h)
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

// diagnostics is the driver's counters plus the WIRE's ring gaps -- every handle's, not this
// one's, because a row reports the wire and the handle it polls is usually the one that kept up
// (#213). Asked of the driver whatever the generation's state: a failed generation's counters
// are still what happened, and are often the explanation, so they must not vanish from the row
// the moment the wire dies -- unlike health(), whose .unknown the caller filters (self-review).
// A closed handle answers empty, as health() does.
fn (mut h SharedHandle) diagnostics() BusDiagnostics {
	h.mu.lock()
	closed := h.closed
	subscribed := h.subscribed
	h.mu.unlock()
	if closed {
		return BusDiagnostics{}
	}
	mut e := h.entry
	// Locks in the order recv takes them (h.mu, then e.mu), so this handle's own gap is
	// booked before the wire's total is read.
	h.mu.lock()
	e.mu.lock()
	if subscribed && !h.closed {
		e.book_gap_locked(mut h)
	}
	gaps := BusDiagnostics{
		dropped: e.ring_gaps
	}
	e.mu.unlock()
	h.mu.unlock()
	return gaps.plus(e.driver.diagnostics())
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
	// The subscriber's gap is booked BEFORE the lifecycle section below, in recv's lock order
	// (h.mu, then e.mu) -- taken the other way round it would be the inversion this file's
	// comments exist to prevent.
	if was_subscribed {
		h.mu.lock()
		e.mu.lock()
		e.book_gap_locked(mut h)
		e.mu.unlock()
		h.mu.unlock()
	}
	mut last_healthy := false
	e.mu.lock()
	// WHAT A SUBSCRIBER NEVER READ IS STILL THE WIRE'S LOSS. The gap is booked at receive, so a
	// handle that fell behind the ring and closed without another receive -- a Lua consumer
	// that read once, worked, and was torn down -- left its overwritten frames uncounted, and
	// the row read "nothing dropped" through the handle that kept up (codex round 1 on #231).
	// SUBSCRIBERS ONLY: a transmit tap never asked for delivery, and its cursor is old on any
	// busy wire -- booked, every tap a Start opened would add the whole ring to the wire's loss
	// at Stop (codex round 2 on #231).
	if was_subscribed {
		e.subs = e.subs.filter(it.id != h.id)
	}
	e.unread.delete(h.id)
	e.pending_admit.delete(h.id)
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
