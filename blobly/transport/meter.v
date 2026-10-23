module transport

import time

// BusLoad is what a LoadMeter says about the frames one handle carried: the load of DECODED
// frames only (busload.v: error frames, retransmissions and overrun drops occupied the wire and
// are not in it), priced by frame_bits at `nominal` and its data rate.
pub struct BusLoad {
pub:
	// percent is the load over the last whole second; -1 until one second has passed
	percent f32
	// average is the load since open; -1 until one second has passed
	average f32
	// frames is the frames counted since open: received through this handle and sent on it
	frames u64
	// bits is their nominal bit-times since open
	bits f64
	// nominal is the arbitration rate the frames are priced at, bit/s
	nominal int
}

// LoadMeter counts a handle's frames into one-second intervals aligned on its open. A frame is
// counted when the handle receives it or the driver accepts its send, so a frame left queued
// lands in the second it is READ. Unsynchronised: the caller's thread owns it, as it owns the bus.
pub struct LoadMeter {
	nominal int
	data    int
	opened  i64 // ns, the host's monotonic clock
mut:
	k      i64 // the interval in progress, whole seconds since open
	bits   f64 // in interval k
	last   f32 = -1 // interval k-1's percent
	frames u64
	total  f64
}

// new_load_meter prices frames at `nominal` bit/s, a BRS data phase at `data` (0: none).
pub fn new_load_meter(nominal int, data int, now_ns i64) LoadMeter {
	return LoadMeter{
		nominal: nominal
		data:    if data > 0 { data } else { nominal }
		opened:  now_ns
	}
}

// roll closes the interval in progress once `now_ns` is past it; one skipped carried nothing.
fn (mut m LoadMeter) roll(now_ns i64) {
	k := (now_ns - m.opened) / i64(time.second)
	if k <= m.k {
		return
	}
	m.last = if k == m.k + 1 { load_percent(m.bits, 1000, m.nominal) } else { f32(0) }
	m.bits = 0
	m.k = k
}

// note counts `f` at `now_ns`.
pub fn (mut m LoadMeter) note(f CanFrame, now_ns i64) {
	m.roll(now_ns)
	b := frame_bits(f, m.nominal, m.data)
	m.bits += b
	m.total += b
	m.frames++
}

// read is the load at `now_ns`.
pub fn (mut m LoadMeter) read(now_ns i64) BusLoad {
	m.roll(now_ns)
	return BusLoad{
		percent: m.last
		average: if m.k > 0 {
			load_percent(m.total, (now_ns - m.opened) / i64(time.millisecond), m.nominal)
		} else {
			f32(-1)
		}
		frames:  m.frames
		bits:    m.total
		nominal: m.nominal
	}
}

// MeteredBus is a bus whose frames a LoadMeter counts, both directions: what it receives, and
// what it sends once the driver accepted it. Its own sends do not come back to it (an echo goes
// to the wire's other handles), so no frame is counted twice.
@[heap]
pub struct MeteredBus {
	iface string
mut:
	inner Bus
pub mut:
	meter LoadMeter
}

// metered wraps `b` — a bus `open` returned on `iface`, or a host's own that frames its sends as
// open's do — its frames priced at `nominal` and `data` bit/s (project.wire_rates).
pub fn metered(b Bus, iface string, nominal int, data int) &MeteredBus {
	return &MeteredBus{
		iface: iface
		inner: b
		meter: new_load_meter(nominal, data, i64(time.sys_mono_now()))
	}
}

pub fn (mut m MeteredBus) send(f CanFrame) ! {
	m.inner.send(f)!
	// priced as it went out: what open's SilentBus handed the backend (framed by its one policy
	// read), else framed as open's buses frame it — a host's own bus, the GUI's tap, does — then
	// padded or clamped by the backend as wire_frame says
	mut inner := m.inner
	sent := if mut inner is SilentBus { inner.sent } else { framed_for_wire(m.iface, f) }
	m.meter.note(wire_frame(m.iface, sent), i64(time.sys_mono_now()))
}

pub fn (mut m MeteredBus) recv(timeout_ms int) !CanFrame {
	f := m.inner.recv(timeout_ms)!
	m.meter.note(f, i64(time.sys_mono_now()))
	return f
}

pub fn (mut m MeteredBus) close() {
	m.inner.close()
}

pub fn (mut m MeteredBus) health() BusHealth {
	return m.inner.health()
}

pub fn (mut m MeteredBus) diagnostics() BusDiagnostics {
	return m.inner.diagnostics()
}

pub fn (mut m MeteredBus) reconcile_silence(want bool) ! {
	m.inner.reconcile_silence(want)!
}

// load is the meter's reading now.
pub fn (mut m MeteredBus) load() BusLoad {
	return m.meter.read(i64(time.sys_mono_now()))
}
