module transport

// Tests for the one-wire-one-handle layer (issue #147). Hermetic: a fake Bus stands in for a
// driver, so these run on Linux CI with no adapter. What they pin is the behaviour PCAN needs
// — a second open must NOT reach the driver, and the driver must be released exactly once,
// when the last handle goes.

struct FakeBus {
	spec string
mut:
	sent []CanFrame
}

fn (mut f FakeBus) send(frame CanFrame) ! {
	f.sent << frame
}

fn (mut f FakeBus) recv(timeout_ms int) !CanFrame {
	return error('timeout')
}

fn (mut f FakeBus) close() {
	fake_closes++
}

fn (mut f FakeBus) health() BusHealth {
	return .unknown
}

__global (
	fake_opens  int
	fake_closes int
	fake_fails  bool
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
