module transport

import time

// Tests for the one-wire-one-raw-handle layer (issues #147 and #212). Hermetic fakes stand in for
// the driver, so these run on Linux CI with no adapter. What they pin is the behaviour PCAN needs
// — a second open must NOT reach the driver, and the driver must be released exactly once,
// when the last handle goes.

struct FakeBus {
	spec string
mut:
	sent       []CanFrame
	reconciles int
}

fn (mut f FakeBus) send(frame CanFrame) ! {
	f.sent << frame
}

fn (mut f FakeBus) recv(timeout_ms int) !CanFrame {
	fake_recv_calls++
	// HONOURS ITS TIMEOUT, and can be fed. The old fake returned 'timeout' at once, which the
	// hub's reader took as "poll again" — a 100% busy loop for the life of every handle in this
	// file. And it could never yield a frame, so the adapter production PCAN goes through
	// (SharedBusDriver) had no test that fan-out reached it at all.
	wait := if timeout_ms < 0 { 1000 } else { timeout_ms }
	select {
		got := <-fake_rx {
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
}

fn (mut f FakeBus) close() {
	fake_closes++
}

fn (mut f FakeBus) health() BusHealth {
	return .unknown
}

__global (
	fake_opens             int
	fake_closes            int
	fake_fails             bool
	fake_recv_calls        int
	fake_rx                chan CanFrame
	hub_fake_send_gate     chan bool
	hub_fake_send_blocking bool
	hub_fake_rx            chan HubFakeItem
	hub_fake_sent          chan CanFrame
	hub_fake_opened        chan bool
	hub_fake_close_started chan bool
	hub_fake_close_release chan bool
	hub_fake_ack_taken     chan bool
	hub_fake_opens         int
	hub_fake_closes        int
	hub_fake_block_close   bool
	hub_fake_ack_in_send   bool
	hub_fake_send_failure  string
)

fn fake_make(spec string) !Bus {
	if fake_fails {
		return error('driver said no')
	}
	fake_opens++
	return &FakeBus{
		spec: spec
	}
}

fn reset_fakes() {
	fake_opens = 0
	fake_closes = 0
	fake_fails = false
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
	assert fake_closes == 0
	b.close()
	assert fake_closes == 1
}

fn test_closing_a_handle_twice_does_not_release_the_wire() {
	reset_fakes()
	mut a := shared_open('k3', 'fake:1', fake_make)!
	mut b := shared_open('k3', 'fake:1', fake_make)!
	a.close()
	a.close() // the app does this on at least one race path
	// Without the idempotence guard the second decrement reaches zero and closes the driver
	// while `b` is still transmitting on it.
	assert fake_closes == 0
	b.close()
	assert fake_closes == 1
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
	assert fake_closes == 1
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
	assert fake_closes == 1
	b.close()
	assert fake_closes == 2
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
	assert fake_closes == 1
}

// A CLOSED HANDLE TOUCHES NO DRIVER, on the reconcile path as well as on send.
//
// `SilentBus.send` reconciles BEFORE it reaches send, so this method is where a caller holding an
// already-closed handle arrives first — and without the guard it reached the vendor call with the
// underlying channel uninitialized, and could file a fault against a wire nobody is holding
// (codex round 4 on #219). It answers with the same sentence send() does.
fn test_a_closed_shared_handle_does_not_reconcile() {
	fake_opens = 0
	fake_closes = 0
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
	block_close bool
}

fn (mut d HubFakeDriver) send(frame CanFrame) ! {
	hub_fake_sent <- shared_clone_frame(frame)
	if hub_fake_send_blocking {
		// A stuck socket write: this send does not return until the test says so.
		_ := <-hub_fake_send_gate
	}
	if hub_fake_ack_in_send {
		hub_fake_rx <- HubFakeItem{
			ingress: SharedIngress{
				frame:  shared_clone_frame(frame)
				tx_ack: true
			}
		}
		// Prove that the sole reader has accepted the acknowledgement before this raw send
		// returns. That makes the send-error regression below deterministic.
		_ := <-hub_fake_ack_taken
	}
	if hub_fake_send_failure != '' {
		return error(hub_fake_send_failure)
	}
}

fn (mut d HubFakeDriver) recv_shared(timeout_ms int) !SharedIngress {
	select {
		item := <-hub_fake_rx {
			if item.failure != '' {
				return error(item.failure)
			}
			if item.ingress.tx_ack {
				select {
					hub_fake_ack_taken <- true {}
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
		hub_fake_close_started <- true
		_ := <-hub_fake_close_release
	}
	hub_fake_closes++
}

fn (mut d HubFakeDriver) health() BusHealth {
	return .unknown
}

fn (mut d HubFakeDriver) reconcile_silence(want bool) ! {}

fn (mut d HubFakeDriver) reports_tx_ack() bool {
	return true
}

fn hub_fake_make(spec string) !SharedDriver {
	hub_fake_opens++
	select {
		hub_fake_opened <- true {}
		else {}
	}
	return &HubFakeDriver{
		block_close: hub_fake_block_close
	}
}

fn reset_hub_fakes() {
	hub_fake_rx = chan HubFakeItem{cap: shared_ring_capacity + 16}
	hub_fake_sent = chan CanFrame{cap: 16}
	hub_fake_opened = chan bool{cap: 4}
	hub_fake_close_started = chan bool{cap: 1}
	hub_fake_close_release = chan bool{cap: 1}
	hub_fake_ack_taken = chan bool{cap: 1}
	hub_fake_opens = 0
	hub_fake_closes = 0
	hub_fake_block_close = false
	hub_fake_ack_in_send = false
	hub_fake_send_failure = ''
}

fn hub_inject(frame CanFrame) {
	hub_fake_rx <- HubFakeItem{
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
	assert (<-hub_fake_sent).data == frame.data
	hub_fake_rx <- HubFakeItem{
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
	_ := <-hub_fake_sent
	// Content does not consume pending origin state; only CANsub's private TX bit does.
	hub_inject(frame)
	assert sender.recv(1000)!.id == frame.id
	assert observer.recv(1000)!.id == frame.id
	hub_fake_rx <- HubFakeItem{
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
	_ := <-hub_fake_sent
	_ := <-hub_fake_sent
	for _ in 0 .. 2 {
		hub_fake_rx <- HubFakeItem{
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
fn test_a_fast_tx_ack_during_a_failing_send_is_still_the_wires_truth() {
	reset_hub_fakes()
	hub_fake_ack_in_send = true
	hub_fake_send_failure = 'raw write failed'
	mut sender := shared_open_events('hub:send-failure', 'fake:send-failure', hub_fake_make)!
	mut observer := shared_open_events('hub:send-failure', 'fake:send-failure', hub_fake_make)!
	if _ := sender.send(CanFrame{ id: 0x45B }) {
		assert false, 'the fake raw write was configured to fail'
	} else {
		assert err.msg() == 'raw write failed'
	}
	_ := <-hub_fake_sent
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

// THE READER, health(), reconcile_silence() AND close() NEVER WAIT ON A WRITER. One handle is
// stuck in a socket write that will not return; everything else on the wire must still answer.
// This is blocker 1 of code-review high on #221 as a test: before the fix, every line below the
// spawn hung behind send_mu for as long as the write did — in the real failure, 30 seconds, on
// the GUI thread.
fn test_a_stuck_send_does_not_block_health_reconcile_or_close() {
	reset_hub_fakes()
	hub_fake_send_gate = chan bool{cap: 1}
	hub_fake_send_blocking = true
	defer {
		hub_fake_send_blocking = false
	}
	mut stuck := shared_open_events('hub:stuck', 'fake:stuck', hub_fake_make)!
	mut other := shared_open_events('hub:stuck', 'fake:stuck', hub_fake_make)!
	spawn fn [mut stuck] () {
		stuck.send(CanFrame{ id: 0x5A1 }) or {}
	}()
	_ := <-hub_fake_sent // the write is now in flight and parked
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
	hub_fake_rx <- HubFakeItem{
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
	hub_fake_send_gate <- true // release the writer so its handle can close cleanly
	stuck.close()
}

// AN IDLE WIRE COSTS THE DRIVER NOTHING. A handle that only ever sends must not keep the reader
// polling the driver on its behalf — on PCAN that was ~1000 CAN_Read calls a second per idle wire
// (#222 item 2). And the first handle to actually receive must wake the reader promptly, or the
// saving would be paid for in latency.
fn test_a_wire_with_no_subscriber_is_not_polled_and_the_first_recv_wakes_it() {
	fake_opens = 0
	fake_closes = 0
	fake_fails = false
	fake_recv_calls = 0
	fake_rx = chan CanFrame{cap: 8}
	mut tx_only := shared_open('fake:idle', 'fake:idle', fake_make)!
	tx_only.send(CanFrame{ id: 0x100 }) or {}
	time.sleep(300 * time.millisecond)
	// One read at most: the loop may have polled once before it noticed nobody subscribes.
	assert fake_recv_calls <= 1, 'the reader polled the driver ${fake_recv_calls} times with nobody listening'
	// A listener arrives, a frame is injected, and it is delivered within the poll period —
	// not after the park's one-second fallback.
	mut listener := shared_open('fake:idle', 'fake:idle', fake_make)!
	fake_rx <- CanFrame{
		id: 0x101
	}
	t0 := time.ticks()
	f := listener.recv(1000)!
	assert f.id == 0x101
	assert time.ticks() - t0 < 500, 'the first recv took ${time.ticks() - t0} ms: the kick did not wake the reader'
	assert fake_recv_calls >= 1
	listener.close()
	tx_only.close()
}

// FAN-OUT THROUGH THE PATH PCAN ACTUALLY USES. Every other fan-out test here drives
// shared_open_events with a raw SharedDriver fake; production PCAN arrives through shared_open
// and the SharedBusDriver adapter, which until this test was covered only by a bench run.
fn test_shared_open_fans_a_plain_bus_out_to_every_handle() {
	fake_opens = 0
	fake_closes = 0
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
	assert fake_closes == 1
}

fn test_a_tx_ack_from_a_closed_origin_still_reaches_other_handles() {
	reset_hub_fakes()
	mut sender := shared_open_events('hub:closed-origin', 'fake:closed-origin', hub_fake_make)!
	mut observer := shared_open_events('hub:closed-origin', 'fake:closed-origin', hub_fake_make)!
	frame := CanFrame{
		id: 0x45C
	}
	sender.send(frame)!
	_ := <-hub_fake_sent
	sender.close()
	hub_fake_rx <- HubFakeItem{
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
	_ := <-hub_fake_sent
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
	hub_fake_rx <- HubFakeItem{
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
	hub_fake_rx <- HubFakeItem{
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
	hub_fake_rx <- HubFakeItem{
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
	hub_fake_block_close = true
	mut old := shared_open_events('hub:closing', 'fake:closing', hub_fake_make)!
	_ := <-hub_fake_opened
	closed := chan bool{cap: 1}
	mut closer := &SharedTestBusBox{
		bus: old
	}
	spawn closer.close_for_test(closed)
	_ := <-hub_fake_close_started
	// Only generation 1 blocks in close; generation 2 may close normally after it opens.
	hub_fake_block_close = false
	reopened := chan bool{cap: 1}
	spawn reopen_for_test('hub:closing', reopened)
	select {
		_ := <-hub_fake_opened {
			assert false, 'new raw open overlapped the old physical close'
		}
		30 * time.millisecond {}
	}
	hub_fake_close_release <- true
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
