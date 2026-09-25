// timebase — every CLOCK DOMAIN placed on one timeline (#149).
//
// The trace stamps a frame when OUR THREAD dequeued it, so two channels on one wire disagree about
// one physical frame by tens of microseconds. Every hardware backend has the wire's own time and
// drops it; this module makes those stamps usable. Each device clock has its own zero and rate, so
// its stamps mean nothing beside another's until they share a timeline.
//
// NOT CLOCK SYNCHRONISATION. A DOMAIN is one clock and one epoch. RAW stamps within a domain are
// exactly comparable — and a delta within a domain (cycle time, jitter, request to response) is
// taken from them, never from two mapped times, which move whenever the estimate does. `map` places
// a domain on the host's monotonic timeline, for sorting frames from different domains together.
//
// THE MODEL. Our thread always sees a frame AFTER the wire did, and that latency is only ever added,
// so the smallest `host − hw` gap is the best estimate of the offset (NTP's minimum-delay
// principle). The minimum is taken over a SLIDING WINDOW of the last 10 s of host time:
//
//   - drift is followed by the window's recency: 50 ppm moves the offset at most 0.5 ms in 10 s;
//   - a frame delivered late (a stall, a backlog, a collector pause) has a HIGH gap, which is never
//     the minimum — so it never moves the estimate, and is itself placed at its true wire time;
//   - after a silence longer than the window, the first frame back sets the estimate alone.
//
// What a frame mapped on arrival gets, held by a property test: never later than its own receipt
// (its gap is in the window), and early by at most the drift over the larger of one window and its
// own age — ~0.5 ms at 50 ppm for a prompt frame, ~3 ms for a stamp a minute old. Clock steps do not
// occur mid-run in this app (a reopen is a new run and a new domain); a frame stamped across one
// would be misplaced by the step.
//
// A fitted line with step detection was tried first and removed: fed by several receive threads, it
// read ordinary delivery disagreement as clock steps (#149 has the account).
//
// STAMPS: nanoseconds, 64-bit, monotonic within an epoch. All arithmetic is integer — a CANsub
// stamp on the Unix epoch in ns is ~1.76×10¹⁸, past the 2⁵³ an f64 holds exactly. Note for step 3:
// Kvaser's `canReadWait` time is MILLISECONDS unless the timer scale is set, and the shim does not
// set it, so a Kvaser stamp is 1 ms coarse as things stand.
//
// PURE AND UNSYNCHRONISED: the caller holds the lock, like txhealth.Gate.
module timebase

// slots of slot_ns host time make up the window. Host time only moves forward, so every sample
// leaves on schedule. A minimum per slot keeps memory fixed however fast frames arrive, and the ring
// is a FIXED array because V copies a slice's header, not its data — a copied Domain would share its
// ring with the original, and V copies a struct out of a map on every read.
pub const slots = 100
pub const slot_ns = i64(100) * 1_000_000
pub const window_ns = i64(slots) * slot_ns

struct Slot {
mut:
	s    i64 // which slot of host time: host / slot_ns
	min  i64 // the smallest `host − hw` delivered in it
	used bool
}

// Domain is one clock and one epoch. The zero value is ready: nothing observed, nothing mapped.
pub struct Domain {
mut:
	started bool
	ring    [slots]Slot
	newest  i64 // the most recent slot delivered into
	offset  i64 // the minimum over the live slots: what map() adds
	n       u64
}

// observe records one frame: its hardware stamp and when this host saw it, both in nanoseconds.
// `host_ns` is the monotonic clock (time.sys_mono_now), never wall time, which can step under NTP.
// Calls may arrive slightly out of host order — receive threads race for the lock — and a sample is
// filed under its own slot.
pub fn (mut d Domain) observe(hw_ns i64, host_ns i64) {
	d.n++
	gap := host_ns - hw_ns
	s := host_ns / slot_ns
	if d.started && s <= d.newest - slots {
		return // older than the window: its slot now belongs to a newer one
	}
	if !d.started || s > d.newest {
		// the first frame, or the window slid: recompute from what is still inside — at most ten
		// times a second per domain, so the per-frame cost stays O(1)
		d.started = true
		d.newest = s
		d.put(s, gap)
		d.recompute()
		return
	}
	if d.put(s, gap) && gap < d.offset {
		d.offset = gap
	}
}

// map places a hardware stamp on the host's monotonic timeline, or none before anything has been
// observed. For placing frames beside other domains — a delta within a domain comes from raw stamps.
pub fn (d &Domain) map(hw_ns i64) ?i64 {
	if !d.started {
		return none
	}
	return hw_ns + d.offset
}

// observed is how many frames this domain has been fed.
pub fn (d &Domain) observed() u64 {
	return d.n
}

// put files a gap under its slot, reporting whether it lowered that slot's minimum. A slot still
// holding an index from a previous lap of the ring is stale and is overwritten.
fn (mut d Domain) put(s i64, gap i64) bool {
	i := int(s % i64(slots))
	if !d.ring[i].used || d.ring[i].s != s {
		d.ring[i] = Slot{
			s:    s
			min:  gap
			used: true
		}
		return true
	}
	if gap < d.ring[i].min {
		d.ring[i].min = gap
		return true
	}
	return false
}

// recompute takes the minimum over the slots still inside the window.
fn (mut d Domain) recompute() {
	mut first := true
	for e in d.ring {
		if e.used && e.s > d.newest - slots {
			if first || e.min < d.offset {
				d.offset = e.min
				first = false
			}
		}
	}
}

// Placer decides where a received frame goes on the host's monotonic timeline (#149 step 4): the
// one place that answers it, so the trace and anything after it cannot each answer differently.
//
// Three cases, by what the frame carries:
//   - no stamp: its receipt, knowingly — the host time the trace has always used;
//   - a stamp already on the host's monotonic clock (SocketCAN, which the shim converts): the stamp
//     itself, with no estimation to add bias;
//   - a stamp on a foreign clock: that domain's mapping.
//
// Each foreign domain's estimator is held by POINTER: V copies a struct out of a map on every read,
// and a Domain's fixed ring would be copied twice per frame. Unsynchronised; the caller holds the lock.
pub struct Placer {
mut:
	domains map[string]&Domain
}

// place returns the frame's time on the host monotonic clock, in nanoseconds. `host_clock` says the
// stamp is already on that clock; `host_ns` is when this host received the frame.
pub fn (mut p Placer) place(domain string, hw_ns i64, host_ns i64, host_clock bool) i64 {
	if domain == '' {
		return host_ns
	}
	if host_clock {
		return hw_ns
	}
	mut d := p.domains[domain] or {
		nd := &Domain{}
		p.domains[domain] = nd
		nd
	}
	d.observe(hw_ns, host_ns)
	return d.map(hw_ns) or { host_ns }
}

// reset forgets every domain: a new run opens every clock again.
pub fn (mut p Placer) reset() {
	p.domains = map[string]&Domain{}
}
