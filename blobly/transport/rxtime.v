module transport

import time
import blobly.timebase

// RxClock is the process's one placement of received frames on the host's monotonic clock: the
// trace's rows and every script's frames ask it, so one frame has one time wherever it is read.
// A foreign clock's estimate is learned from every frame of its domain, whoever reads it.
struct RxClock {
mut:
	p timebase.Placer
}

__global (
	rx_clock shared RxClock
)

// received_at is when a received frame arrived, on the host's monotonic clock (time.sys_mono_now)
// in nanoseconds: its own receive stamp as timebase places it, or `host_ns`, the caller's receipt,
// where it carries none (a software bus) — so an unstamped frame's time is when THIS reader read
// it, and two readers of one such frame each have their own.
pub fn received_at(f CanFrame, host_ns i64) i64 {
	host_clock := on_host_clock(f.hw_domain)
	if t := timebase.unestimated(f.hw_domain, f.hw_ns, host_ns, host_clock) {
		return t // no estimate to read: no lock to take
	}
	mut t := host_ns
	lock rx_clock {
		t = rx_clock.p.place(f.hw_domain, f.hw_ns, host_ns, host_clock)
	}
	return t
}

// received_now is received_at for a frame recv has just returned.
pub fn received_now(f CanFrame) i64 {
	return received_at(f, i64(time.sys_mono_now()))
}

// reset_receive_clock forgets every foreign clock's estimate: a new run opens its clocks again.
pub fn reset_receive_clock() {
	lock rx_clock {
		rx_clock.p.reset()
	}
}
