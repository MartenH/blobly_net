// timebase — every CLOCK DOMAIN placed on one timeline (#149).
//
// The trace used to stamp a frame when our thread dequeued it, so `t (s)` was a host clock read by
// whichever receive thread got there first — two channels on one wire disagreed about one physical
// frame by tens of microseconds, rendered to the microsecond. Every hardware backend already has
// the wire's own time and drops it. This module is what makes those stamps usable at all: each
// device's clock has its own zero and its own rate, so its numbers mean nothing next to another's
// until they are placed on a common timeline.
//
// NOT CLOCK SYNCHRONISATION, and that is the design. Only a few backends can synchronise clocks
// (PTP on a CANsub, a vendor's own multi-device sync), and only with their own hardware. None of it
// is needed. A DOMAIN is one clock and one epoch. RAW stamps within a domain are directly
// comparable; this module places the domain on the host's monotonic timeline, by estimation,
// within host scheduling jitter — which is the accuracy every comparison had before, so mixing
// backends costs nothing relative to then.
//
// THE RULE FOR CALLERS, and it matters more than anything below: a delta WITHIN a domain — cycle
// time, jitter, request to response, gateway latency between two channels of one interface — is
// taken from the RAW stamps, which are exact. A mapped time is for PLACING a frame beside frames
// from other domains, and it moves whenever the estimate does. Computing cycle time from mapped
// times would put a small step into the jitter every time the minimum changed.
//
// THE MODEL. Our thread always sees a frame AFTER the wire did — USB, driver, scheduling — and that
// latency is only ever ADDED. So the smallest `host − hw` gap is the best estimate of the offset
// between the two clocks: the minimum-delay principle NTP uses. The minimum is taken over a SLIDING
// WINDOW of recent host time, and that one choice carries all the rest:
//
//   - DRIFT is followed by the window's recency. Two crystals 50 ppm apart drift 180 ms an hour;
//     over a 10 s window the offset moves at most 50 ppm × 10 s = 0.5 ms, which is the error bound.
//   - A FORWARD STEP of the device clock lowers every gap, and the new minimum is adopted at once.
//   - A BACKWARD STEP raises every gap; the old minimum lingers until its samples leave the window,
//     so for up to one window after the LAST pre-step frame the domain maps early by the step. The
//     one price of this design, and bounded.
//   - A STALL, a STRAGGLER, a DRIVER BACKLOG — anything delivered late — produces a HIGH gap, and a
//     high gap is never the minimum, so the estimate is untouched. And such a frame is PLACED right:
//     mapped through the correct offset, it lands at its true wire time however late it arrived.
//   - ACROSS A STEP, IN EITHER DIRECTION, a frame stamped on the far side of it is placed wrong by
//     the step, because one domain has one offset and it describes one clock. A pre-step straggler
//     arriving after a forward step is placed early by the whole step; after a backward step it is
//     the post-step frames that are early, until the window passes. The estimate is right for the
//     clock that is current; a stamp from the previous one cannot be placed by it.
//   - A QUIET DOMAIN keeps its estimate across the silence: when a slide would empty the window,
//     the previous minimum is carried forward, inflated by `drift_ppm` over the time elapsed so it
//     stays an UPPER bound on the true offset. A short silence therefore keeps an estimate good to
//     the drift, rather than taking a lone first frame's latency — up to a 700 ms collector pause —
//     as the offset; a long one inflates it past usefulness, and a fresh sample wins by itself.
//
// WHY NOT A FITTED LINE WITH STEP DETECTION, which is what this was first written as and what #149
// first described. It tracked drift better, and the review of it found five failures with one
// cause: a single-epoch state machine that flipped on one contradicting observation, fed by several
// receive threads whose deliveries disagree as a matter of course. A 3 s stall on one channel's
// thread produced 599 "clock steps"; a straggler after a real step flipped the epoch back; a
// sub-threshold step tilted the line by ±500 ms for five minutes; a startup backlog was reported as
// a step. Each was patchable, and patching five symptoms of one cause is the loop CLAUDE.md warns
// about. Here there is no state to flip.
//
// ALL INTEGER. A CANsub stamps a 48-bit count of microseconds since 2025-01-01 UTC; placed on the
// Unix epoch in nanoseconds that is ~1.76×10¹⁸, past the 2⁵³ an f64 holds exactly, so through
// floating point a 10 ms delta would come back rounded to 256 ns. Nothing here is floating.
//
// THE CONTRACT ON STAMPS: nanoseconds, 64-bit, and MONOTONIC WITHIN AN EPOCH. A backend whose
// counter is narrower must extend it before observing, because a counter that wraps is a PERIODIC
// backward step — each one mapping a window of frames early by the whole wrap. Among ours only
// Kvaser's is narrow enough to matter: `canRead`'s time is 32 bits, which at microsecond resolution
// wraps every ~71.6 minutes. PCAN's timestamp is 48-bit milliseconds, a CANsub's 48-bit
// microseconds (~8.9 years), Vector's and SocketCAN's 64-bit.
//
// PURE AND UNSYNCHRONISED: a Domain is a decision with state, and the caller holds whatever lock
// guards it, like txhealth.Gate.
module timebase

// slots is how many slots the window holds, and slot_ns how much HOST time each one covers.
//
// Host time and not device time, because a backward step sends the device clock back into a range
// it already covered, where a device-time window would find the old samples again; host time only
// moves forward, so every sample leaves on schedule.
//
// The window's length is a trade: shorter follows drift more closely and forgets a backward step
// sooner; longer keeps a good estimate through a stretch in which every frame is delivered late (a
// host under sustained load), where a short window drifts late with the delivery. 10 s bounds drift
// error to 0.5 ms at 50 ppm — inside host jitter, which is the accuracy promised across domains.
//
// A minimum per SLOT rather than per sample, in a FIXED array, so memory is constant by type
// however fast a domain delivers: a sliding minimum over raw samples can hold a whole window of
// them when latency happens to rise steadily, which at 4000 frames/s is 40,000 entries a domain.
// Fixed rather than a slice for a second reason: V copies a slice's header and not its data, so a
// copied Domain shared its ring with the original and each corrupted the other's estimate.
pub const slots = 100
pub const slot_ns = i64(100) * 1_000_000
pub const window_ns = i64(slots) * slot_ns

// drift_ppm is the rate difference a carried estimate is inflated by across a quiet stretch. Two
// crystals of ±50 ppm differ by up to 100 ppm; allowed that much, a carried estimate stays an upper
// bound on the true offset, so the domain is never mapped EARLY by carrying it.
pub const drift_ppm = i64(100)

struct Slot {
mut:
	s    i64 // which slot of host time: host / slot_ns
	min  i64 // the smallest `host − hw` delivered in it
	used bool
}

// Domain is one clock and one epoch.
//
// The zero value is ready: nothing observed, nothing mapped.
pub struct Domain {
mut:
	started bool
	ring    [slots]Slot
	newest  i64 // the most recent slot delivered into
	offset  i64 // the minimum over the live slots: what map() adds
	n       u64
}

// observe records one frame: its hardware stamp and when this host saw it, both in nanoseconds.
//
// `host_ns` MUST BE MONOTONIC (time.sys_mono_now), never wall time: wall time can step under NTP,
// and a step on the host side is indistinguishable from one on the device's.
//
// Calls may arrive slightly out of host order — several receive threads read the clock and then
// race for the lock — and that is handled: a sample is filed under its own slot, not the newest.
pub fn (mut d Domain) observe(hw_ns i64, host_ns i64) {
	d.n++
	gap := host_ns - hw_ns
	s := floor_div(host_ns, slot_ns)
	if d.started && s <= d.newest - slots {
		return // older than the window by the time it got the lock: says nothing about now
	}
	if !d.started || s > d.newest {
		// THE FIRST FRAME, OR THE WINDOW SLID — one path for both, since a first frame is a slide
		// onto an empty ring. Samples may have left the window, so the minimum is recomputed from
		// what is still inside: at most ten times a second per domain, so the per-frame cost is O(1).
		prev := d.offset
		emptied := d.started && s - d.newest >= slots
		elapsed := (s - d.newest) * slot_ns
		d.started = true
		d.newest = s
		d.put(s, gap)
		d.recompute()
		if emptied {
			// A QUIET DOMAIN'S ESTIMATE IS CARRIED, not dropped: every slot just expired, and without
			// this the lone first frame after the silence would BE the offset, however late it was
			// delivered. Inflated by the drift allowance so it stays an upper bound, and filed one
			// slot behind so it leaves one window from now, by which time fresh samples have replaced
			// it. Divided before multiplied: an allowance needs no sub-millisecond precision, and a
			// domain quiet for years must not overflow computing one.
			carried := prev + elapsed / 1_000_000 * drift_ppm
			d.put(s - 1, carried)
			if carried < d.offset {
				d.offset = carried
			}
		}
		return
	}
	if d.put(s, gap) && gap < d.offset {
		d.offset = gap
	}
}

// map places a hardware stamp on the host's monotonic timeline, or none before anything has been
// observed. For PLACEMENT beside other domains — see the rule for callers above: a delta within a
// domain is taken from the raw stamps, not from two mapped ones. And a stamp from the far side of a
// clock step is placed wrong by the step: see the model above.
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
	i := int(floor_mod(s, i64(slots)))
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

// floor_div and floor_mod round toward negative infinity, as a slot index must. V's `/` and `%`
// truncate toward zero, which files −1 ns in slot 0 beside +1 ns — harmless for a monotonic clock
// that never goes negative, and exactly the kind of assumption that stops holding in a test.
fn floor_div(a i64, b i64) i64 {
	q := a / b
	return if (a % b != 0) && ((a < 0) != (b < 0)) { q - 1 } else { q }
}

fn floor_mod(a i64, b i64) i64 {
	return a - floor_div(a, b) * b
}
