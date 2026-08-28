module transport

import sync.stdatomic
import time

// Tests for the one-wire-one-raw-handle layer (issues #147 and #212). Hermetic fakes stand in for
// the driver, so these run on Linux CI with no adapter. What they pin is the behaviour PCAN needs
// — a second open must NOT reach the driver, and the driver must be released exactly once,
// when the last handle goes.

// EVERY FAKE CAPTURES ITS CHANNELS WHEN IT IS MADE, as fields, and never reads the globals by
// name from its reader thread. A test that fails part-way leaves its handles open and its hub
// reader alive; the next test's reset used to swap the globals under that reader, whose next
// poll then consumed the next test's injected item -- one timed-out receive turned into five
// failures and a crash, in CI and on a two-core bench alike (#227). The globals are the TEST
// thread's way to reach the current instance; a leftover reader keeps polling its own.
// FakeControls is the reader-side state of one FakeBus generation: the counters its reader
// thread touches and the failure it is armed with. One allocation per test, captured by pointer
// at make, so a leftover reader from a failed earlier test counts and consumes on its own.
struct FakeControls {
mut:
	closes     i64
	recv_calls i64
	recv_fails i64
}

struct FakeBus {
	spec string
	rx   chan CanFrame
	ctl  &FakeControls
	// reconcile_gate, when set, is waited on by every reconcile -- a controller that is slow to
	// answer -- and reconcile_failure is what it then says. Only the slow factory sets them.
	reconcile_gate    chan bool = chan bool{cap: 0}
	reconcile_failure string
	gated_reconcile   bool
mut:
	sent       []CanFrame
	reconciles int
}

fn (mut f FakeBus) send(frame CanFrame) ! {
	f.sent << frame
}

fn (mut f FakeBus) recv(timeout_ms int) !CanFrame {
	// Counted atomically: the hub's reader thread increments it and the test thread reads it.
	stdatomic.add_i64(&f.ctl.recv_calls, 1)
	// Fails ONCE per unit armed, so a test can fail one generation's read and let its
	// replacement work.
	if stdatomic.load_i64(&f.ctl.recv_fails) > 0 {
		stdatomic.add_i64(&f.ctl.recv_fails, -1)
		return error(fake_recv_failure_msg)
	}
	if timeout_ms == 0 {
		// A zero timeout is one look, not a wait — what a parked reader's drain asks for.
		select {
			got := <-f.rx {
				return got
			}
			else {
				return error('timeout')
			}
		}
	}
	// HONOURS ITS TIMEOUT, and can be fed. The old fake returned 'timeout' at once, which the
	// hub's reader took as "poll again" — a 100% busy loop for the life of every handle in this
	// file. And it could never yield a frame, so the adapter production PCAN goes through
	// (SharedBusDriver) had no test that fan-out reached it at all.
	wait := if timeout_ms < 0 { 1000 } else { timeout_ms }
	select {
		got := <-f.rx {
			return got
		}
		wait * time.millisecond {
			return error('timeout')
		}
	}
	return error('timeout')
}

fn (mut f FakeBus) reconcile_silence(want bool) ! {
	f.reconciles++
	if f.gated_reconcile {
		_ := <-f.reconcile_gate
		if f.reconcile_failure != '' {
			return error(f.reconcile_failure)
		}
	}
}

fn (mut f FakeBus) close() {
	// Atomic: the hub's reader thread closes a failed generation while a test thread polls.
	stdatomic.add_i64(&f.ctl.closes, 1)
}

fn (mut f FakeBus) health() BusHealth {
	return .unknown
}

fn (mut f FakeBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

// HubFakeConfig is everything a HubFakeDriver is made from: the channels the test thread
// injects into and reads from, and the knobs a test turns before it opens. One global, one
// fresh literal per reset, one snapshot by value at make -- there is no list to keep in step.
struct HubFakeConfig {
mut:
	block_close   bool
	send_blocking bool
	ack_in_send   bool
	send_failure  string
	// fail_id fails only writes of this id, so one wire can carry a good send and a bad one.
	fail_id u32
	// diag is what the fake driver reports as its diagnostics.
	diag          BusDiagnostics
	rx            chan HubFakeItem
	sent          chan CanFrame
	send_gate     chan bool
	ack_taken     chan bool
	close_started chan bool
	close_release chan bool
}

// slow_fake_make is a factory that does not return until the test releases it -- a CANsub open
// against a device that is reachable enough to stall. Which outcome it then has is the test's
// choice; how many times it ran is counted, because one attempt shared is the whole point.
__global (
	slow_fake_gates             map[string]chan bool // one per wire: a token must release THAT factory
	slow_fake_calls             i64
	slow_fake_failure           string
	slow_fake_reconcile_gate    chan bool
	slow_fake_reconcile_failure string
)

fn slow_fake_make(spec string) !Bus {
	stdatomic.add_i64(&slow_fake_calls, 1)
	gate := slow_fake_gates[spec]
	_ := <-gate
	if slow_fake_failure != '' {
		return error(slow_fake_failure)
	}
	return &FakeBus{
		spec:              spec
		rx:                fake_rx
		ctl:               fake_ctl
		gated_reconcile:   slow_fake_reconcile_failure != ''
		reconcile_gate:    slow_fake_reconcile_gate
		reconcile_failure: slow_fake_reconcile_failure
	}
}

fn reset_slow_fake(failure string) {
	reset_fakes()
	slow_fake_gates = {
		'slow:shared':  chan bool{cap: 8}
		'slow:other':   chan bool{cap: 8}
		'slow:failing': chan bool{cap: 8}
		'slow:refused': chan bool{cap: 8}
	}
	stdatomic.store_i64(&slow_fake_calls, 0)
	slow_fake_failure = failure
	slow_fake_reconcile_gate = chan bool{cap: 8}
	slow_fake_reconcile_failure = ''
}

// THE CONTROLLER'S POLICY IS PART OF THE ATTEMPT. A listen-only wire whose factory succeeds and
// whose controller then refuses silence: a waiter that wakes while that reconcile is still in
// flight must not join -- the entry is not running yet -- and when the refusal lands every
// waiter shares it, from one factory call, with no handle issued to anybody (codex round 1 on
// #230).
fn test_a_first_open_whose_listen_only_reconcile_is_refused_fails_every_waiter_with_it() {
	reset_slow_fake('')
	slow_fake_reconcile_failure = 'controller stays normal'
	set_listen_only('slow:refused', true)
	defer {
		set_listen_only('slow:refused', false)
	}
	out := chan SharedOpenOutcome{cap: 3}
	for _ in 0 .. 3 {
		spawn open_slow_for_test('slow:refused', out)
	}
	deadline := time.ticks() + 2000
	for stdatomic.load_i64(&slow_fake_calls) < 1 {
		assert time.ticks() < deadline, 'the factory was never called'
		time.sleep(time.millisecond)
	}
	for shared_test_opening_waiters('slow:refused') < 2 {
		assert time.ticks() < deadline, 'the other openers never found the reservation'
		time.sleep(time.millisecond)
	}
	slow_fake_gates['slow:refused'] <- true // the factory returns; the reconcile now stalls
	// Longer than the waiters' wake-up bound: they wake, find the entry still opening, wait on.
	time.sleep((shared_reader_poll_ms + 20) * time.millisecond)
	assert out.len == 0, 'an opener returned while the controller policy was still being applied'
	slow_fake_reconcile_gate <- true
	for _ in 0 .. 3 {
		select {
			got := <-out {
				assert got.err.contains('controller stays normal'), 'an opener got `${got.err}`'
			}
			2000 * time.millisecond {
				assert false, 'an opener never returned'
			}
		}
	}
	assert stdatomic.load_i64(&slow_fake_calls) == 1, 'waiters on a refused attempt started their own'
	assert fake_ctl.closes == 1, 'the refused generation must release its driver once'
	assert shared_test_opening_waiters('slow:refused') == 0, 'the refused reservation must be gone'
}

// shared_test_opening_waiters is how many callers are waiting on `key`'s current reservation.
fn shared_test_opening_waiters(key string) int {
	mut n := 0
	lock shared_reg {
		if mut e := shared_reg.entries[key] {
			e.mu.lock()
			n = e.opening_waiters
			e.mu.unlock()
		}
	}
	return n
}

struct SharedOpenOutcome {
	bus &Bus = unsafe { nil }
	err string
}

fn open_slow_for_test(key string, out chan SharedOpenOutcome) {
	mut bus := shared_open(key, key, slow_fake_make) or {
		out <- SharedOpenOutcome{
			err: err.msg()
		}
		return
	}
	out <- SharedOpenOutcome{
		bus: &bus
	}
}

// THE FACTORY RUNS OUTSIDE THE REGISTRY LOCK, AND ONE ATTEMPT SERVES EVERY CALLER. Three
// openers of one wire arrive while its factory is stalled: none of them starts a second attempt,
// and -- the part #211 is about -- an opener of a DIFFERENT wire is not held up by it at all.
fn test_concurrent_first_opens_share_one_stalled_attempt_and_block_nobody_else() {
	reset_slow_fake('')
	out := chan SharedOpenOutcome{cap: 3}
	for _ in 0 .. 3 {
		spawn open_slow_for_test('slow:shared', out)
	}
	deadline := time.ticks() + 2000
	for stdatomic.load_i64(&slow_fake_calls) < 1 {
		assert time.ticks() < deadline, 'the factory was never called'
		time.sleep(time.millisecond)
	}
	// Another wire opens while the first is stalled: the registry lock is not held across make.
	other_out := chan SharedOpenOutcome{cap: 1}
	spawn open_slow_for_test('slow:other', other_out)
	for stdatomic.load_i64(&slow_fake_calls) < 2 {
		assert time.ticks() < deadline, 'a second wire could not begin opening while the first was stalled'
		time.sleep(time.millisecond)
	}
	slow_fake_gates['slow:other'] <- true
	select {
		got := <-other_out {
			assert got.err == '', 'the other wire failed: ${got.err}'
			mut b := *got.bus
			b.close()
		}
		2000 * time.millisecond {
			assert false, 'the other wire waited behind the stalled open'
		}
	}
	// Nobody on the shared wire has an answer yet, and only one attempt is running.
	assert out.len == 0
	assert stdatomic.load_i64(&slow_fake_calls) == 2
	slow_fake_gates['slow:shared'] <- true
	mut handles := []&Bus{}
	for _ in 0 .. 3 {
		select {
			got := <-out {
				assert got.err == '', 'an opener failed: ${got.err}'
				handles << got.bus
			}
			2000 * time.millisecond {
				assert false, 'an opener never returned'
			}
		}
	}
	assert stdatomic.load_i64(&slow_fake_calls) == 2, 'the stalled attempt was duplicated'
	// All three share one entry.
	mut entries := []voidptr{}
	for h in handles {
		mut b := *h
		if mut b is SharedHandle {
			entries << voidptr(b.entry)
		}
	}
	assert entries.len == 3
	assert entries[0] == entries[1] && entries[1] == entries[2]
	for h in handles {
		mut b := *h
		b.close()
	}
	assert fake_ctl.closes == 2
}

// A STALLED ATTEMPT THAT FAILS FAILS EVERY CALLER WAITING ON IT, with its error, and runs the
// factory once for all of them; the next caller after that opens afresh, because a failed open
// publishes nothing to join.
fn test_waiters_on_a_failing_first_open_share_its_error_and_the_next_open_retries() {
	reset_slow_fake('device said no')
	out := chan SharedOpenOutcome{cap: 3}
	for _ in 0 .. 3 {
		spawn open_slow_for_test('slow:failing', out)
	}
	deadline := time.ticks() + 2000
	for stdatomic.load_i64(&slow_fake_calls) < 1 {
		assert time.ticks() < deadline, 'the factory was never called'
		time.sleep(time.millisecond)
	}
	// Both other openers are OBSERVED waiting on the reservation before it is failed -- a
	// late arrival after the removal would be served by a fresh attempt, which is correct
	// and not what this test is about.
	for shared_test_opening_waiters('slow:failing') < 2 {
		assert time.ticks() < deadline, 'the other openers never found the reservation'
		time.sleep(time.millisecond)
	}
	slow_fake_gates['slow:failing'] <- true
	for _ in 0 .. 3 {
		select {
			got := <-out {
				assert got.err == 'device said no', 'an opener got `${got.err}`'
			}
			2000 * time.millisecond {
				assert false, 'an opener never returned'
			}
		}
	}
	assert stdatomic.load_i64(&slow_fake_calls) == 1, 'waiters on a failing attempt started their own'
	// Nothing was left behind, and the next open runs the factory again.
	slow_fake_failure = ''
	slow_fake_gates['slow:failing'] <- true
	mut again := shared_open('slow:failing', 'slow:failing', slow_fake_make)!
	assert stdatomic.load_i64(&slow_fake_calls) == 2
	again.close()
}

__global (
	fake_opens      int
	fake_fails      bool
	fake_rx         chan CanFrame
	fake_ctl        &FakeControls
	hub_fake        HubFakeConfig
	hub_fake_opened chan bool
	hub_fake_opens  int
	hub_fake_closes int
)

fn fake_make(spec string) !Bus {
	if fake_fails {
		return error('driver said no')
	}
	fake_opens++
	return &FakeBus{
		spec: spec
		rx:   fake_rx
		ctl:  fake_ctl
	}
}

fn reset_fakes() {
	fake_opens = 0
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	fake_ctl = &FakeControls{}
}

fn test_second_open_does_not_reach_the_driver() {
	reset_fakes()
	mut a := shared_open('k1', 'fake:1', fake_make)!
	mut b := shared_open('k1', 'fake:1', fake_make)!
	// The whole point: PCANBasic's second CAN_Initialize is the failure, so it must never
	// happen. Two callers, one open.
	assert fake_opens == 1
	a.close()
	b.close()
}

fn test_driver_is_released_only_when_the_last_handle_closes() {
	reset_fakes()
	mut a := shared_open('k2', 'fake:1', fake_make)!
	mut b := shared_open('k2', 'fake:1', fake_make)!
	a.close()
	// The reader closing must not take the wire away from the transmit taps still holding it.
	assert fake_ctl.closes == 0
	b.close()
	assert fake_ctl.closes == 1
}

fn test_closing_a_handle_twice_does_not_release_the_wire() {
	reset_fakes()
	mut a := shared_open('k3', 'fake:1', fake_make)!
	mut b := shared_open('k3', 'fake:1', fake_make)!
	a.close()
	a.close() // the app does this on at least one race path
	// Without the idempotence guard the second decrement reaches zero and closes the driver
	// while `b` is still transmitting on it.
	assert fake_ctl.closes == 0
	b.close()
	assert fake_ctl.closes == 1
}

fn test_a_closed_handle_refuses_to_send() {
	reset_fakes()
	mut a := shared_open('k4', 'fake:1', fake_make)!
	mut b := shared_open('k4', 'fake:1', fake_make)!
	a.close()
	if _ := a.send(CanFrame{ id: 0x100 }) {
		assert false, 'a closed handle must not send on a wire it no longer holds'
	}
	// ... while the handle still holding it works.
	b.send(CanFrame{ id: 0x100 })!
	b.close()
}

fn test_reopening_after_the_last_close_opens_the_driver_again() {
	reset_fakes()
	mut a := shared_open('k5', 'fake:1', fake_make)!
	a.close()
	assert fake_ctl.closes == 1
	// Stop then Start: the entry must be gone, not a stale one pointing at a closed driver.
	mut b := shared_open('k5', 'fake:1', fake_make)!
	assert fake_opens == 2
	b.close()
}

fn test_different_destinations_are_independent() {
	reset_fakes()
	mut a := shared_open('k6a', 'fake:1', fake_make)!
	mut b := shared_open('k6b', 'fake:2', fake_make)!
	assert fake_opens == 2
	a.close()
	assert fake_ctl.closes == 1
	b.close()
	assert fake_ctl.closes == 2
}

fn test_same_wire_with_different_settings_is_refused() {
	reset_fakes()
	mut a := shared_open('k7', 'fake:1@500000', fake_make)!
	// Two project rows on one adapter at different bitrates. The channel is already
	// configured, so the second request cannot be honoured — say so instead of silently
	// running at the first one's rate.
	if _ := shared_open('k7', 'fake:1@250000', fake_make) {
		assert false, 'a conflicting spec must be refused, not silently aliased'
	}
	assert fake_opens == 1
	a.close()
}

fn test_a_failed_open_leaves_no_reservation_behind() {
	reset_fakes()
	fake_fails = true
	if _ := shared_open('k8', 'fake:1', fake_make) {
		assert false, 'the open failed; shared_open must surface it'
	}
	// The reservation must be withdrawn: a later open that joined a bus-less entry would
	// return a handle whose every send fails, with the driver never actually opened.
	fake_fails = false
	mut a := shared_open('k8', 'fake:1', fake_make)!
	assert fake_opens == 1
	a.send(CanFrame{ id: 0x123 })!
	a.close()
	assert fake_ctl.closes == 1
}

// A CLOSED HANDLE TOUCHES NO DRIVER, on the reconcile path as well as on send.
//
// `SilentBus.send` reconciles BEFORE it reaches send, so this method is where a caller holding an
// already-closed handle arrives first — and without the guard it reached the vendor call with the
// underlying channel uninitialized, and could file a fault against a wire nobody is holding
// (codex round 4 on #219). It answers with the same sentence send() does.
fn test_a_closed_shared_handle_does_not_reconcile() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	mut a := shared_open('fake:silent-guard', 'fake:silent-guard', fake_make) or {
		assert false, err.msg()
		return
	}
	a.reconcile_silence(true) or { assert false, 'an open handle must reconcile: ${err.msg()}' }
	a.close()
	if _ := a.reconcile_silence(true) {
		assert false, 'a closed handle must not reach the driver'
	} else {
		assert err.msg().contains('bus is closed'), err.msg()
	}
}

// HubFakeDriver exposes the raw ingress-event seam directly, including CANsub-shaped TX
// acknowledgements and injected fatal errors. Its channels make the reader tests deterministic:
// no adapter, socket or wall-clock polling is involved.
struct HubFakeItem {
	ingress SharedIngress
	failure string
}

struct HubFakeDriver {
	HubFakeConfig
}

// hub_fake_take is a bounded wait on one of the fake's handshake channels. Both waits in send
// run under the hub's send_mu, so an unbounded one on a generation whose reader has died (a
// test that failed an assertion and returned) would hold that lock for the rest of the run.
fn hub_fake_take(ch chan bool, what string) ! {
	select {
		_ := <-ch {}
		hub_fake_handshake_ms * time.millisecond {
			return error('${what}: nobody answered the fake within ${hub_fake_handshake_ms} ms')
		}
	}
}

fn (mut d HubFakeDriver) send(frame CanFrame) ! {
	d.sent <- shared_clone_frame(frame)
	if d.send_blocking {
		// A stuck socket write: this send does not return until the test says so.
		hub_fake_take(d.send_gate, 'stuck write')!
	}
	if d.ack_in_send {
		d.rx <- HubFakeItem{
			ingress: SharedIngress{
				frame:  shared_clone_frame(frame)
				tx_ack: true
			}
		}
		// Prove that the sole reader has taken the acknowledgement off the driver before this
		// raw send returns -- the ordering the send-error regression below is about. What the
		// hub does with it after that is the hub's race to get right, not this handshake's.
		hub_fake_take(d.ack_taken, 'acknowledgement')!
	}
	if d.send_failure != '' {
		return error(d.send_failure)
	}
	if d.fail_id != 0 && frame.id == d.fail_id {
		return error('raw write of ${frame.id:x} failed')
	}
}

fn (mut d HubFakeDriver) recv_shared(timeout_ms int) !SharedIngress {
	select {
		item := <-d.rx {
			if item.failure != '' {
				return error(item.failure)
			}
			if item.ingress.tx_ack {
				select {
					d.ack_taken <- true {}
					else {}
				}
			}
			return item.ingress
		}
		i64(timeout_ms) * time.millisecond {
			return error('timeout')
		}
	}
	return error('timeout')
}

fn (mut d HubFakeDriver) close() {
	if d.block_close {
		d.close_started <- true
		_ := <-d.close_release
	}
	hub_fake_closes++
}

fn (mut d HubFakeDriver) health() BusHealth {
	return .unknown
}

fn (mut d HubFakeDriver) diagnostics() BusDiagnostics {
	return d.diag
}

fn (mut d HubFakeDriver) reconcile_silence(want bool) ! {}

fn (mut d HubFakeDriver) reports_tx_ack() bool {
	return true
}

const hub_fake_handshake_ms = 5000

// hub_fake_make snapshots the CURRENT config into the driver it makes -- see FakeBus.
fn hub_fake_make(spec string) !SharedDriver {
	hub_fake_opens++
	select {
		hub_fake_opened <- true {}
		else {}
	}
	return &HubFakeDriver{
		HubFakeConfig: hub_fake
	}
}

fn reset_hub_fakes() {
	hub_fake = HubFakeConfig{
		rx:            chan HubFakeItem{cap: shared_ring_capacity + 16}
		sent:          chan CanFrame{cap: 16}
		send_gate:     chan bool{cap: 1}
		ack_taken:     chan bool{cap: 1}
		close_started: chan bool{cap: 1}
		close_release: chan bool{cap: 1}
	}
	hub_fake_opened = chan bool{cap: 4}
	hub_fake_opens = 0
	hub_fake_closes = 0
}

fn hub_inject(frame CanFrame) {
	hub_fake.rx <- HubFakeItem{
		ingress: SharedIngress{
			frame: frame
		}
	}
}

fn test_shared_hub_fans_one_raw_ingress_out_to_every_handle() {
	reset_hub_fakes()
	mut a := shared_open_events('hub:fanout', 'fake:fanout', hub_fake_make)!
	mut b := shared_open_events('hub:fanout', 'fake:fanout', hub_fake_make)!
	assert hub_fake_opens == 1
	hub_inject(CanFrame{
		id:   0x123
		data: [u8(0xDE), 0xAD]
	})
	assert a.recv(1000)!.id == 0x123
	assert b.recv(1000)!.id == 0x123
	a.close()
	b.close()
	assert hub_fake_closes == 1
}

fn test_shared_hub_returns_payload_copies_per_handle() {
	reset_hub_fakes()
	mut a := shared_open_events('hub:copy', 'fake:copy', hub_fake_make)!
	mut b := shared_open_events('hub:copy', 'fake:copy', hub_fake_make)!
	hub_inject(CanFrame{
		id:   0x321
		data: [u8(1), 2, 3]
	})
	mut first := a.recv(1000)!
	first.data[0] = 0xFF
	second := b.recv(1000)!
	assert second.data == [u8(1), 2, 3]
	a.close()
	b.close()
}

fn test_shared_hub_skips_tx_ack_for_its_sender_only() {
	reset_hub_fakes()
	mut sender := shared_open_events('hub:origin', 'fake:origin', hub_fake_make)!
	mut observer := shared_open_events('hub:origin', 'fake:origin', hub_fake_make)!
	frame := CanFrame{
		id:   0x456
		data: [u8(4), 5, 6]
	}
	sender.send(frame)!
	assert (<-hub_fake.sent).data == frame.data
	hub_fake.rx <- HubFakeItem{
		ingress: SharedIngress{
			frame:  frame
			tx_ack: true
		}
	}
	assert observer.recv(1000)!.id == frame.id
	if _ := sender.recv(20) {
		assert false, 'the originating handle must not receive its own TX acknowledgement'
	} else {
		assert err.msg() == 'timeout'
	}
	sender.close()
	observer.close()
}

fn test_an_external_frame_identical_to_a_pending_send_stays_external() {
	reset_hub_fakes()
	mut sender := shared_open_events('hub:external-identical', 'fake:external-identical',
		hub_fake_make)!
	mut observer := shared_open_events('hub:external-identical', 'fake:external-identical',
		hub_fake_make)!
	frame := CanFrame{
		id:   0x45A
		data: [u8(4), 5, 0xA]
	}
	sender.send(frame)!
	_ := <-hub_fake.sent
	// Content does not consume pending origin state; only CANsub's private TX bit does.
	hub_inject(frame)
	assert sender.recv(1000)!.id == frame.id
	assert observer.recv(1000)!.id == frame.id
	hub_fake.rx <- HubFakeItem{
		ingress: SharedIngress{
			frame:  frame
			tx_ack: true
		}
	}
	assert observer.recv(1000)!.id == frame.id
	if _ := sender.recv(20) {
		assert false, 'the sender must skip the later TX acknowledgement'
	} else {
		assert err.msg() == 'timeout'
	}
	sender.close()
	observer.close()
}

fn test_identical_tx_acks_are_attributed_to_the_oldest_pending_origin() {
	reset_hub_fakes()
	mut a := shared_open_events('hub:identical', 'fake:identical', hub_fake_make)!
	mut b := shared_open_events('hub:identical', 'fake:identical', hub_fake_make)!
	frame := CanFrame{
		id:   0x45E
		data: [u8(4), 5, 0xE]
	}
	a.send(frame)!
	b.send(frame)!
	_ := <-hub_fake.sent
	_ := <-hub_fake.sent
	for _ in 0 .. 2 {
		hub_fake.rx <- HubFakeItem{
			ingress: SharedIngress{
				frame:  frame
				tx_ack: true
			}
		}
	}
	// Ack 1 belongs to A, ack 2 to B. Each handle skips its own and receives the other one.
	assert a.recv(1000)!.id == frame.id
	assert b.recv(1000)!.id == frame.id
	if _ := a.recv(20) {
		assert false, "A received more than B's acknowledgement"
	} else {
		assert err.msg() == 'timeout'
	}
	if _ := b.recv(20) {
		assert false, "B received more than A's acknowledgement"
	} else {
		assert err.msg() == 'timeout'
	}
	a.close()
	b.close()
}

// AN ACKNOWLEDGED FRAME REACHED THE WIRE, whatever the write call went on to return. This test
// used to assert the opposite — that an ack arriving while its write was still failing must be
// dropped — and the machinery that guaranteed it was the reader waiting on send_mu behind every
// in-flight write (blocker 1). The device's word is the better evidence: the monitor records the
// frame, attributed to its origin; the sender is told its write failed; and neither is lied to.
//
// AND WHICH THREAD REACHES THE HUB FIRST MUST NOT DECIDE IT. The fake hands the ack to the
// reader before the raw write returns its failure; from there the reader's match and the
// sender's error path race for e.mu, and on a two-core runner the sender won four CI runs out
// of four — its error path deleted the pending entry and the reader counted the ack unmatched
// (#227). A failed write's entry now stays for the ordinary window, so either order publishes.
fn test_a_fast_tx_ack_during_a_failing_send_is_still_the_wires_truth() {
	reset_hub_fakes()
	hub_fake.ack_in_send = true
	hub_fake.send_failure = 'raw write failed'
	mut sender := shared_open_events('hub:send-failure', 'fake:send-failure', hub_fake_make)!
	mut observer := shared_open_events('hub:send-failure', 'fake:send-failure', hub_fake_make)!
	if _ := sender.send(CanFrame{ id: 0x45B }) {
		assert false, 'the fake raw write was configured to fail'
	} else {
		assert err.msg() == 'raw write failed'
	}
	_ := <-hub_fake.sent
	// The observer sees it: it happened on the bus.
	assert observer.recv(1000)!.id == 0x45B
	// The origin does not: it is that handle's own transmission.
	if _ := sender.recv(100) {
		assert false, 'a handle must not receive its own acknowledged frame as RX'
	} else {
		assert err.msg() == 'timeout'
	}
	sender.close()
	observer.close()
}

// AND THE RULE ITSELF, WITH NO RACE TO WIN: the write fails with nothing acknowledged yet, and
// the device's acknowledgement arrives only AFTER the failure has been returned. The entry must
// still be there to match it -- for its grace, not for ever -- so the observer receives the
// frame, the origin does not, and a grace that ends without an acknowledgement is counted as
// a failed send, not as a lost acknowledgement.
fn test_a_failed_write_stays_matchable_for_its_grace_then_counts_as_failed() {
	reset_hub_fakes()
	hub_fake.send_failure = 'raw write failed'
	mut sender := shared_open_events('hub:failed-grace', 'fake:failed-grace', hub_fake_make)!
	mut observer := shared_open_events('hub:failed-grace', 'fake:failed-grace', hub_fake_make)!
	frame := CanFrame{
		id:   0x45F
		data: [u8(4), 5, 0xF]
	}
	if _ := sender.send(frame) {
		assert false, 'the fake raw write was configured to fail'
	} else {
		assert err.msg() == 'raw write failed'
	}
	_ := <-hub_fake.sent
	assert shared_test_pending(mut sender) == 1, 'a failed write must keep its pending entry'
	hub_fake.rx <- HubFakeItem{
		ingress: SharedIngress{
			frame:  frame
			tx_ack: true
		}
	}
	assert observer.recv(1000)!.id == frame.id
	if _ := sender.recv(50) {
		assert false, 'the origin must not receive its own acknowledged frame as RX'
	} else {
		assert err.msg() == 'timeout'
	}
	assert shared_test_unmatched(mut sender) == 0
	// A second failed write that nobody acknowledges: gone after its grace, and counted as
	// what it was.
	if _ := sender.send(CanFrame{ id: 0x460 }) {
		assert false, 'the fake raw write was configured to fail'
	} else {
		assert err.msg() == 'raw write failed'
	}
	_ := <-hub_fake.sent
	deadline := time.ticks() + shared_failed_send_grace_ms + 2000
	for shared_test_pending(mut sender) > 0 {
		if time.ticks() >= deadline {
			assert false, 'the failed write did not expire after its grace'
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert shared_test_expired(mut sender) == 0, 'a failed write is not a lost acknowledgement'
	assert shared_test_expired_failed(mut sender) == 1
	sender.close()
	observer.close()
}

// AND THE GRACE HOLDS BEHIND A LIVE ENTRY. Pending sends are in write order; their deadlines are
// not. A successful write that is still awaiting its acknowledgement, then a failed one: the
// ghost must expire on its own clock, not the earlier send's five seconds -- expiry that only
// cut a prefix left it matchable for the whole of the earlier window (codex round 1 on #228).
fn test_a_failed_write_behind_a_live_send_still_expires_on_its_own_grace() {
	reset_hub_fakes()
	hub_fake.fail_id = 0x462
	mut sender := shared_open_events('hub:failed-behind', 'fake:failed-behind', hub_fake_make)!
	mut failing := shared_open_events('hub:failed-behind', 'fake:failed-behind', hub_fake_make)!
	sender.send(CanFrame{ id: 0x461 })! // acknowledged never; lives out the ordinary window
	_ := <-hub_fake.sent
	if _ := failing.send(CanFrame{ id: 0x462 }) {
		assert false, 'the fake raw write was configured to fail'
	} else {
		assert err.msg() == 'raw write of 462 failed'
	}
	_ := <-hub_fake.sent
	assert shared_test_pending(mut sender) == 2
	deadline := time.ticks() + shared_failed_send_grace_ms + 2000
	for shared_test_pending(mut sender) > 1 {
		if time.ticks() >= deadline {
			assert false, 'the failed write behind a live send did not expire after its grace'
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert shared_test_expired_failed(mut sender) == 1
	assert shared_test_expired(mut sender) == 0, 'the live send must still be waiting for its acknowledgement'
	sender.close()
	failing.close()
}

// THE READER, health(), reconcile_silence() AND close() NEVER WAIT ON A WRITER. One handle is
// stuck in a socket write that will not return; everything else on the wire must still answer.
// This is blocker 1 of code-review high on #221 as a test: before the fix, every line below the
// spawn hung behind send_mu for as long as the write did — in the real failure, 30 seconds, on
// the GUI thread.
fn test_a_stuck_send_does_not_block_health_reconcile_or_close() {
	reset_hub_fakes()
	hub_fake.send_blocking = true
	mut stuck := shared_open_events('hub:stuck', 'fake:stuck', hub_fake_make)!
	mut other := shared_open_events('hub:stuck', 'fake:stuck', hub_fake_make)!
	spawn fn [mut stuck] () {
		stuck.send(CanFrame{ id: 0x5A1 }) or {}
	}()
	_ := <-hub_fake.sent // the write is now in flight and parked
	// Everything below is bounded by its own deadline; a hang here is the regression.
	done := chan bool{cap: 4}
	spawn fn [mut other, done] () {
		_ = other.health()
		done <- true
	}()
	spawn fn [mut other, done] () {
		other.reconcile_silence(false) or {}
		done <- true
	}()
	// And the reader still delivers external traffic while that write is stuck.
	hub_fake.rx <- HubFakeItem{
		ingress: SharedIngress{
			frame: CanFrame{
				id: 0x5A2
			}
		}
	}
	spawn fn [mut other, done] () {
		if f := other.recv(2000) {
			assert f.id == 0x5A2
		} else {
			assert false, 'the reader parked behind a stuck writer'
		}
		done <- true
	}()
	for _ in 0 .. 3 {
		select {
			_ := <-done {}
			2000 * time.millisecond {
				assert false, 'a call waited on the stuck write'
			}
		}
	}
	// Closing the OTHER handle must not wait either.
	spawn fn [mut other, done] () {
		other.close()
		done <- true
	}()
	select {
		_ := <-done {}
		2000 * time.millisecond {
			assert false, 'close waited on the stuck write'
		}
	}
	hub_fake.send_gate <- true // release the writer so its handle can close cleanly
	stuck.close()
}

// AN IDLE WIRE COSTS THE DRIVER ALMOST NOTHING. A handle that only ever sends must not keep the
// reader polling the driver on its behalf — on PCAN that was ~1000 CAN_Read calls a second per
// idle wire (#222 item 2); after the attentive second, it is one zero-timeout drain a second.
// What that drain finds is nobody's: a frame from before a listener OPENED is discarded, not
// served to it as new. And a handle opening onto a parked wire must wake the reader promptly, or
// the saving would be paid for in latency.
fn test_a_wire_with_no_subscriber_is_not_polled_and_the_first_recv_wakes_it() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut tx_only := shared_open('fake:idle', 'fake:idle', fake_make)!
	tx_only.send(CanFrame{ id: 0x100 }) or {}
	// OBSERVED parked, not assumed after a sleep: on a loaded runner the reader thread may not
	// have run yet, and a frame injected before it parks is delivered legitimately (codex round
	// 1 on #224).
	shared_test_wait_parked(mut tx_only)
	// Parked after the attentive second, which the reader spent polling on the fresh handle's
	// behalf; what is counted is the cost from here on.
	stdatomic.store_i64(&fake_ctl.recv_calls, 0)
	time.sleep(300 * time.millisecond)
	// One drain at most in the window.
	reads := stdatomic.load_i64(&fake_ctl.recv_calls)
	assert reads <= 1, 'the reader polled the driver ${reads} times with nobody listening'
	// A frame arrives while nobody listens; then a listener opens. The kick that wakes the reader
	// drains that frame away, so the listener's first receive is a timeout, not stale history.
	fake_rx <- CanFrame{
		id: 0x100
	}
	mut listener := shared_open('fake:idle', 'fake:idle', fake_make)!
	if _ := listener.recv(150) {
		assert false, 'a frame from before the listener opened was served to it as new'
	} else {
		assert err.msg() == 'timeout'
	}
	assert shared_test_parked_discards(mut listener) == 1
	// What arrives after it listens is delivered within the poll period — not after the park's
	// drain period, which is what a lost kick would cost.
	fake_rx <- CanFrame{
		id: 0x101
	}
	t0 := time.ticks()
	f := listener.recv(1000)!
	assert f.id == 0x101
	assert time.ticks() - t0 < 500, 'the first recv took ${time.ticks() - t0} ms: the kick did not wake the reader'
	listener.close()
	tx_only.close()
}

// A DEVICE THAT FAILS WHILE NOBODY LISTENS IS NOTICED THEN, not when somebody does: the parked
// drain reads the driver, and a fatal read error takes the generation down like any other.
fn test_a_fatal_read_error_reaches_a_parked_reader() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut tx_only := shared_open('fake:idle-fatal', 'fake:idle-fatal', fake_make)!
	shared_test_wait_parked(mut tx_only)
	stdatomic.store_i64(&fake_ctl.recv_fails, 1)
	// The next drain tick finds it; nothing subscribes and nothing kicks. Observed on THIS
	// entry — a global close count could be another test's leftover reader failing on the same
	// global switch.
	deadline := time.ticks() + 2 * shared_parked_drain_ms
	for !shared_test_failed(mut tx_only) {
		if time.ticks() >= deadline {
			assert false, 'the parked reader never noticed the fatal read error'
			break
		}
		time.sleep(10 * time.millisecond)
	}
	if _ := tx_only.send(CanFrame{ id: 0x102 }) {
		assert false, 'a failed generation must reject later sends'
	} else {
		assert err.msg() == fake_recv_failure_msg
	}
	tx_only.close()
}

const fake_recv_failure_msg = 'device unplugged'

// A JOIN ONTO A PARKED WIRE WHOSE ADAPTER HAS GONE GETS A FRESH GENERATION, not a handle on the
// dead one. The join's own boundary drain is the first driver call since the park, so it is where
// the failure is found; it fails the generation and the open goes through the factory again
// (codex rounds 1 and 2 on #224).
fn test_a_join_that_finds_the_parked_generation_dead_reopens_through_the_factory() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut tx_only := shared_open('fake:idle-dead', 'fake:idle-dead', fake_make)!
	shared_test_wait_parked(mut tx_only)
	stdatomic.store_i64(&fake_ctl.recv_fails, 1)
	mut listener := shared_open('fake:idle-dead', 'fake:idle-dead', fake_make)!
	assert fake_opens == 2, 'the join found the generation dead and must have opened a new one'
	assert stdatomic.load_i64(&fake_ctl.recv_fails) == 0, 'the armed failure was consumed by the join'
	if _ := tx_only.send(CanFrame{ id: 0x103 }) {
		assert false, 'the old generation must be failed'
	} else {
		assert err.msg() == fake_recv_failure_msg
	}
	fake_rx <- CanFrame{
		id: 0x104
	}
	assert listener.recv(1000)!.id == 0x104, 'the fresh generation must be live'
	listener.close()
	tx_only.close()
}

// AN EXPIRED TAP'S HISTORY BEGINS AT ITS FIRST RECEIVE, ring included: what the reader committed
// on its behalf in its attentive second is not served to it a minute later as new (codex round 3
// on #224).
fn test_an_expired_tap_starts_at_the_tail_when_it_finally_receives() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut tap := shared_open('fake:idle-tap', 'fake:idle-tap', fake_make)!
	mut reader := shared_open('fake:idle-tap', 'fake:idle-tap', fake_make)!
	// Committed while the tap is attentive: the reader receives it, the tap does not read.
	fake_rx <- CanFrame{
		id: 0x200
	}
	assert reader.recv(1000)!.id == 0x200
	reader.close()
	shared_test_wait_parked(mut tap)
	if _ := tap.recv(50) {
		assert false, 'the expired tap was served a frame from its attentive second as new'
	} else {
		assert err.msg() == 'timeout'
	}
	fake_rx <- CanFrame{
		id: 0x201
	}
	assert tap.recv(1000)!.id == 0x201
	tap.close()
}

// A LATE FIRST RECEIVE THAT FINDS THE ADAPTER GONE FAILS THE GENERATION AND SAYS SO — the error
// is the caller's answer, not a timeout followed by silence (codex round 3 on #224).
fn test_a_late_first_receive_that_finds_the_adapter_gone_reports_it() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut tap := shared_open('fake:idle-late-fatal', 'fake:idle-late-fatal', fake_make)!
	shared_test_wait_parked(mut tap)
	stdatomic.store_i64(&fake_ctl.recv_fails, 1)
	if _ := tap.recv(1000) {
		assert false, 'a fatal read must not be swallowed by the late first receive'
	} else {
		assert err.msg() == fake_recv_failure_msg
	}
	assert shared_test_failed(mut tap)
	tap.close()
}

// A SEND KEEPS A HANDLE ATTENTIVE: a diagnostic client that sits idle for a second and then
// sends a request must get the reply, not have it drained as nobody's (codex round 4 on #224).
fn test_a_send_after_a_silent_second_keeps_the_reply() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut client := shared_open('fake:idle-client', 'fake:idle-client', fake_make)!
	shared_test_wait_parked(mut client)
	client.send(CanFrame{ id: 0x7E0, data: [u8(0x3E)] })!
	// The reply arrives before the client calls recv — the ordinary case.
	fake_rx <- CanFrame{
		id: 0x7E8
	}
	assert client.recv(1000)!.id == 0x7E8, 'the reply to a request sent after a silent second was lost'
	client.close()
}

// A 0 ms POLL FROM AN EXPIRED TAP STILL SUBSCRIBES on a quiet wire: one look finds the queue
// empty, that is the boundary, and what arrives after it is delivered (codex round 6 on #224).
fn test_a_zero_timeout_poll_from_an_expired_tap_subscribes_on_a_quiet_wire() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut tap := shared_open('fake:idle-poll', 'fake:idle-poll', fake_make)!
	shared_test_wait_parked(mut tap)
	if _ := tap.recv(0) {
		assert false, 'nothing was sent'
	} else {
		assert err.msg() == 'timeout'
	}
	fake_rx <- CanFrame{
		id: 0x300
	}
	assert tap.recv(1000)!.id == 0x300, 'the poll did not subscribe the tap'
	tap.close()
}

fn shared_test_failed(mut bus Bus) bool {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		failed := e.terminal != ''
		e.mu.unlock()
		return failed
	}
	return false
}

// shared_test_wait_parked returns once the hub's reader is observed in its park, or fails.
fn shared_test_wait_parked(mut bus Bus) {
	if mut bus is SharedHandle {
		mut e := bus.entry
		deadline := time.ticks() + 2000
		for {
			e.mu.lock()
			parked := e.parked
			e.mu.unlock()
			if parked {
				return
			}
			if time.ticks() >= deadline {
				assert false, 'the reader never parked'
				return
			}
			time.sleep(time.millisecond)
		}
	}
}

fn shared_test_parked_discards(mut bus Bus) u64 {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		n := e.parked_discards
		e.mu.unlock()
		return n
	}
	return 0
}

// FAN-OUT THROUGH THE PATH PCAN ACTUALLY USES. Every other fan-out test here drives
// shared_open_events with a raw SharedDriver fake; production PCAN arrives through shared_open
// and the SharedBusDriver adapter, which until this test was covered only by a bench run.
fn test_shared_open_fans_a_plain_bus_out_to_every_handle() {
	fake_opens = 0
	fake_ctl = &FakeControls{}
	fake_fails = false
	fake_rx = chan CanFrame{cap: 8}
	mut a := shared_open('fake:fanout', 'fake:fanout', fake_make)!
	mut b := shared_open('fake:fanout', 'fake:fanout', fake_make)!
	assert fake_opens == 1, 'one physical open for two logical handles'
	fake_rx <- CanFrame{
		id:   0x7E8
		data: [u8(0x02), 0x50, 0x03]
	}
	fa := a.recv(1000)!
	fb := b.recv(1000)!
	assert fa.id == 0x7E8 && fb.id == 0x7E8
	assert fa.data == fb.data
	// And they are copies, not one buffer seen twice.
	unsafe {
		fa.data[0] = 0xFF
	}
	assert fb.data[0] == 0x02
	a.close()
	b.close()
	assert fake_ctl.closes == 1
}

fn test_a_tx_ack_from_a_closed_origin_still_reaches_other_handles() {
	reset_hub_fakes()
	mut sender := shared_open_events('hub:closed-origin', 'fake:closed-origin', hub_fake_make)!
	mut observer := shared_open_events('hub:closed-origin', 'fake:closed-origin', hub_fake_make)!
	frame := CanFrame{
		id: 0x45C
	}
	sender.send(frame)!
	_ := <-hub_fake.sent
	sender.close()
	hub_fake.rx <- HubFakeItem{
		ingress: SharedIngress{
			frame:  frame
			tx_ack: true
		}
	}
	assert observer.recv(1000)!.id == frame.id
	observer.close()
}

fn test_a_lost_tx_ack_expires_while_external_traffic_continues() {
	reset_hub_fakes()
	mut sender := shared_open_events('hub:ack-expiry', 'fake:ack-expiry', hub_fake_make)!
	sender.send(CanFrame{ id: 0x45D })!
	_ := <-hub_fake.sent
	shared_test_expire_first_pending(mut sender)
	hub_inject(CanFrame{ id: 0x45F })
	assert sender.recv(1000)!.id == 0x45F
	shared_test_wait_expired(mut sender, 1)
	sender.close()
}

fn test_a_late_handle_starts_at_the_current_tail() {
	reset_hub_fakes()
	mut early := shared_open_events('hub:late', 'fake:late', hub_fake_make)!
	hub_inject(CanFrame{ id: 0x501 })
	assert early.recv(1000)!.id == 0x501
	mut late := shared_open_events('hub:late', 'fake:late', hub_fake_make)!
	if _ := late.recv(0) {
		assert false, 'a new handle must not receive retained history from before its open'
	} else {
		assert err.msg() == 'timeout'
	}
	hub_inject(CanFrame{ id: 0x502 })
	assert early.recv(1000)!.id == 0x502
	assert late.recv(1000)!.id == 0x502
	early.close()
	late.close()
}

fn test_shared_hub_drops_an_unmatched_tx_ack() {
	reset_hub_fakes()
	mut a := shared_open_events('hub:unmatched', 'fake:unmatched', hub_fake_make)!
	hub_fake.rx <- HubFakeItem{
		ingress: SharedIngress{
			frame:  CanFrame{
				id: 0x777
			}
			tx_ack: true
		}
	}
	if _ := a.recv(30) {
		assert false, 'an ownerless local record must not leak into ordinary RX'
	} else {
		assert err.msg() == 'timeout'
	}
	shared_test_wait_unmatched(mut a, 1)
	a.close()
}

fn shared_test_next_sequence(mut bus Bus) u64 {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		next := e.next_seq
		e.mu.unlock()
		return next
	}
	return 0
}

fn shared_test_entry(mut bus Bus) &SharedEntry {
	if mut bus is SharedHandle {
		return bus.entry
	}
	panic('shared test bus was not a SharedHandle')
}

fn shared_test_dropped(mut bus Bus) u64 {
	if mut bus is SharedHandle {
		bus.mu.lock()
		dropped := bus.dropped
		bus.mu.unlock()
		return dropped
	}
	return 0
}

fn shared_test_unmatched(mut bus Bus) u64 {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		unmatched := e.unmatched_tx_acks
		e.mu.unlock()
		return unmatched
	}
	return 0
}

fn shared_test_wait_unmatched(mut bus Bus, want u64) {
	deadline := time.ticks() + 500
	for shared_test_unmatched(mut bus) != want {
		if time.ticks() >= deadline {
			assert false, 'TX-ack diagnostic did not reach ${want}'
			return
		}
		time.sleep(time.millisecond)
	}
}

fn shared_test_expire_first_pending(mut bus Bus) {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		assert e.pending.len == 1
		pending := e.pending[0]
		e.pending[0] = SharedPendingSend{
			...pending
			expires_at: time.ticks() - 1
		}
		e.mu.unlock()
	}
}

fn shared_test_pending(mut bus Bus) int {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		n := e.pending.len
		e.mu.unlock()
		return n
	}
	return -1
}

fn shared_test_expired_failed(mut bus Bus) u64 {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		n := e.expired_failed_sends
		e.mu.unlock()
		return n
	}
	return 0
}

fn shared_test_expired(mut bus Bus) u64 {
	if mut bus is SharedHandle {
		mut e := bus.entry
		e.mu.lock()
		expired := e.expired_tx_acks
		e.mu.unlock()
		return expired
	}
	return 0
}

fn shared_test_wait_expired(mut bus Bus, want u64) {
	deadline := time.ticks() + 500
	for shared_test_expired(mut bus) != want {
		if time.ticks() >= deadline {
			assert false, 'missing-TX-ack diagnostic did not reach ${want}'
			return
		}
		time.sleep(time.millisecond)
	}
}

// THE HUB'S DIAGNOSTICS ARE THE DRIVER'S PLUS THE WIRE'S RING GAPS: what the ring overwrote
// under a slow handle's cursor is reported by EVERY handle on the wire -- the row polls the one
// that kept up -- and survives the slow handle's close; a closed handle still answers with the
// wire's totals, so a sample taken after its close sees what that close booked.
fn test_shared_hub_diagnostics_fold_the_drivers_counters_with_the_wires_ring_gaps() {
	reset_hub_fakes()
	hub_fake.diag = BusDiagnostics{
		bus_errors: 2
	}
	mut slow := shared_open_events('hub:diag', 'fake:diag', hub_fake_make)!
	mut fast := shared_open_events('hub:diag', 'fake:diag', hub_fake_make)!
	// Reads once -- a subscriber -- then never again, and closes behind the ring: its loss is
	// booked at its close. `fast` never reads: a transmit tap, whose old cursor is nobody's loss.
	mut lagging := shared_open_events('hub:diag', 'fake:diag', hub_fake_make)!
	hub_inject(CanFrame{ id: 0xAAA })
	assert lagging.recv(1000)!.id == 0xAAA
	assert fast.diagnostics() == BusDiagnostics{
		bus_errors: 2
	}
	assert fast.diagnostics().str() == '2 controller error(s)'
	total := shared_ring_capacity + 3
	for i in 0 .. total {
		hub_inject(CanFrame{ id: u32(i) })
	}
	deadline := time.ticks() + 2000
	for shared_test_next_sequence(mut slow) < u64(total + 1) {
		assert time.ticks() < deadline, 'the raw reader did not publish the injected ring in time'
		time.sleep(time.millisecond)
	}
	// BEFORE the stalled subscriber acts: lagging has read once, so it IS a subscriber, and the
	// three the flood overwrote past its cursor are the wire's loss the moment anybody asks --
	// here the handle that kept up. slow has not received yet and is not a subscriber; what it
	// missed becomes the wire's when it subscribes.
	assert fast.diagnostics().dropped == 3, "a stalled subscriber's loss is visible while it stalls"
	_ := slow.recv(1000)!
	assert shared_test_dropped(mut slow) == 4 // 0xAAA and the first three of the flood
	want := BusDiagnostics{
		dropped:    7 // lagging's three, then slow's four at its subscribing receive
		bus_errors: 2
	}
	assert slow.diagnostics() == want
	assert fast.diagnostics() == want, "the wire's gap is every handle's answer"
	assert want.short() == '7 dropped · 2 err'
	assert want.minus(BusDiagnostics{ bus_errors: 2 }) == BusDiagnostics{
		dropped: 7
	}
	assert BusDiagnostics{}.fell(want)
	assert !want.fell(BusDiagnostics{})
	slow.close()
	assert slow.diagnostics() == want, 'a closed handle answers with the wire totals'
	assert fast.diagnostics() == want, 'the gap outlives the handle that suffered it'
	// Asked before its close, a subscriber's gap is booked at the asking: a report taken
	// before teardown is not a sample short.
	assert lagging.diagnostics().dropped == 7, 'already booked from the sibling poll: nothing more at the asking'
	lagging.close()
	assert fast.diagnostics().dropped == 7, 'a close books nothing that was already booked'
	// Keeps the generation alive past fast's close, which is a transmit tap's (fast never read).
	mut after := shared_open_events('hub:diag', 'fake:diag', hub_fake_make)!
	fast.close()
	assert after.diagnostics().dropped == 7, 'a transmit tap that never read books nothing at its close'
	after.close()
	assert after.diagnostics().dropped == 7, 'the last close still answers with what the wire counted'
}

fn test_shared_hub_ring_overwrite_only_advances_the_slow_cursor() {
	reset_hub_fakes()
	mut slow := shared_open_events('hub:ring', 'fake:ring', hub_fake_make)!
	total := shared_ring_capacity + 2
	for i in 0 .. total {
		hub_inject(CanFrame{ id: u32(i) })
	}
	deadline := time.ticks() + 2000
	for shared_test_next_sequence(mut slow) < u64(total + 1) {
		if time.ticks() >= deadline {
			assert false, 'the raw reader did not publish the injected ring in time'
			break
		}
		time.sleep(time.millisecond)
	}
	first_retained := slow.recv(1000)!
	assert first_retained.id == u32(total - shared_ring_capacity)
	assert shared_test_dropped(mut slow) == 2
	slow.close()
}

struct SharedTestBusBox {
mut:
	bus Bus
}

fn (mut box SharedTestBusBox) wait_for_recv_error(result chan string) {
	box.bus.recv(-1) or {
		result <- err.msg()
		return
	}
	result <- 'received a frame'
}

fn assert_shared_recv_error(mut bus Bus, message string) {
	if _ := bus.recv(1000) {
		assert false, 'a fatal reader error cannot degrade into a timeout'
	} else {
		assert err.msg() == message
	}
}

fn wait_for_hub_fake_closes(want int) {
	deadline := time.ticks() + 1000
	for hub_fake_closes < want {
		if time.ticks() >= deadline {
			assert false, 'raw close count did not reach ${want}'
			return
		}
		time.sleep(time.millisecond)
	}
}

fn test_close_wakes_an_infinite_receive_on_that_handle() {
	reset_hub_fakes()
	mut a := shared_open_events('hub:close-wake', 'fake:close-wake', hub_fake_make)!
	mut keeper := shared_open_events('hub:close-wake', 'fake:close-wake', hub_fake_make)!
	result := chan string{cap: 1}
	mut waiter := &SharedTestBusBox{
		bus: a
	}
	spawn waiter.wait_for_recv_error(result)
	time.sleep(10 * time.millisecond)
	a.close()
	select {
		message := <-result {
			assert message.contains('bus is closed'), message
		}
		500 * time.millisecond {
			assert false, 'close did not wake recv(-1)'
		}
	}
	keeper.close()
}

fn test_fatal_reader_error_reaches_every_handle_with_an_empty_ring() {
	reset_hub_fakes()
	mut a := shared_open_events('hub:fatal-empty', 'fake:fatal-empty', hub_fake_make)!
	mut b := shared_open_events('hub:fatal-empty', 'fake:fatal-empty', hub_fake_make)!
	hub_fake.rx <- HubFakeItem{
		failure: 'empty raw reader failed'
	}
	assert_shared_recv_error(mut a, 'empty raw reader failed')
	assert_shared_recv_error(mut b, 'empty raw reader failed')
	wait_for_hub_fake_closes(1)
	a.close()
	b.close()
}

fn test_fatal_reader_error_is_sticky_and_a_new_open_gets_a_new_generation() {
	reset_hub_fakes()
	mut a := shared_open_events('hub:fatal', 'fake:fatal', hub_fake_make)!
	mut b := shared_open_events('hub:fatal', 'fake:fatal', hub_fake_make)!
	hub_inject(CanFrame{ id: 0x101 })
	hub_fake.rx <- HubFakeItem{
		failure: 'raw reader failed'
	}
	assert a.recv(1000)!.id == 0x101
	assert b.recv(1000)!.id == 0x101
	for _ in 0 .. 2 {
		if _ := a.recv(1000) {
			assert false, 'the fatal error must remain sticky after buffered frames drain'
		} else {
			assert err.msg() == 'raw reader failed'
		}
	}
	if _ := b.recv(1000) {
		assert false, 'the fatal error must reach every logical handle'
	} else {
		assert err.msg() == 'raw reader failed'
	}
	if _ := a.send(CanFrame{ id: 0x102 }) {
		assert false, 'a failed generation must reject later sends'
	} else {
		assert err.msg() == 'raw reader failed'
	}
	// fail_and_close keeps its reservation until physical close, then this creates generation 2
	// even though the old logical handles still exist.
	mut fresh := shared_open_events('hub:fatal', 'fake:fatal', hub_fake_make)!
	assert hub_fake_opens == 2
	assert hub_fake_closes == 1
	fresh.close()
	a.close()
	b.close()
}

fn (mut box SharedTestBusBox) close_for_test(done chan bool) {
	box.bus.close()
	done <- true
}

fn reopen_for_test(key string, done chan bool) {
	mut bus := shared_open_events(key, 'fake:closing', hub_fake_make) or {
		done <- false
		return
	}
	bus.close()
	done <- true
}

fn test_reopen_waits_until_the_previous_physical_close_finishes() {
	reset_hub_fakes()
	hub_fake.block_close = true
	mut old := shared_open_events('hub:closing', 'fake:closing', hub_fake_make)!
	_ := <-hub_fake_opened
	closed := chan bool{cap: 1}
	mut closer := &SharedTestBusBox{
		bus: old
	}
	spawn closer.close_for_test(closed)
	_ := <-hub_fake.close_started
	// Only generation 1 blocks in close; generation 2 may close normally after it opens.
	hub_fake.block_close = false
	reopened := chan bool{cap: 1}
	spawn reopen_for_test('hub:closing', reopened)
	select {
		_ := <-hub_fake_opened {
			assert false, 'new raw open overlapped the old physical close'
		}
		30 * time.millisecond {}
	}
	hub_fake.close_release <- true
	select {
		_ := <-hub_fake_opened {}
		1000 * time.millisecond {
			assert false, 'new generation did not open after close completed'
		}
	}
	assert <-closed
	assert <-reopened
	assert hub_fake_opens == 2
	assert hub_fake_closes == 2
}

fn test_an_old_generation_cannot_remove_its_replacement() {
	reset_hub_fakes()
	mut old := shared_open_events('hub:generation-guard', 'fake:generation-guard', hub_fake_make)!
	old_entry := shared_test_entry(mut old)
	old.close()
	mut fresh := shared_open_events('hub:generation-guard', 'fake:generation-guard', hub_fake_make)!
	assert hub_fake_opens == 2
	// This is the tail of the reader-error/final-close race: the stale closer resumes after a
	// replacement has already claimed the key. Removal must be by generation identity, not key.
	shared_remove_entry(old_entry)
	mut join := shared_open_events('hub:generation-guard', 'fake:generation-guard', hub_fake_make)!
	assert hub_fake_opens == 2
	join.close()
	fresh.close()
}
