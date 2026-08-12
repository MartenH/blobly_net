// wiretap — who put this frame on the wire?
//
// On a normal bench three parties transmit on one bus: we act as the tester, we simulate the
// ECUs around the device under test, and the device under test is real. Every backend delivers
// our own sends back to a monitoring bus instance (transport.test_inproc_cross_delivery pins
// that), so all three arrive at a monitor looking identical, and a trace that only records
// "did I press send" cannot tell them apart.
//
// The label has to be OBSERVED, never declared. Deriving it from configuration ("this id
// belongs to a simulated node") mislabels the one case most worth catching: leave a simulated
// ECU running while the real ECU it stands in for is on the bench and both transmit the same
// id — config-derived labelling paints that collision as normal.
//
// So each emitter records what it is about to send, and a received frame is matched against
// those records. What is left over — everything that matches nothing of ours — is the other
// side. This module is that record; the caller owns the display.
//
// Pure V, no OS-specific code and no GUI (see the module convention in CLAUDE.md).
module wiretap

import transport

// Origins. Direction is a FUNCTION of these — the first three are outbound, `bus` is inbound —
// so a separate direction column would carry no information.
pub const tst = 'TST' // we emitted it as a tester
pub const sim = 'SIM' // our simulated rest-of-bus emitted it
pub const rep = 'REP' // from a recording: candump carries no origin, so this is the honest ceiling
pub const bus = 'BUS' // not ours — the device under test, or anything else real on the wire

// How long an emission may take to come back before it counts as missing. Generous on purpose:
// an echo is normally there in microseconds, and calling a slow one missing would accuse a
// healthy bus of a fault it does not have.
pub const default_window_ms = f64(2000)

// Bound on outstanding emissions. A bus that never echoes at all (down link, no ACK) would
// otherwise grow this without limit. Dropping the oldest costs a `missed` verdict, never a
// wrong one — the row simply stays unresolved.
pub const default_cap = 1024

// Pending is one emission still waiting for its echo. `seq` is the caller's row identity,
// returned when the echo arrives so the caller can mark the right row.
struct Pending {
	seq   u64
	iface string
	id    u32
	ext   bool
	rtr   bool
	data  []u8
	t_ms  f64
	// The monitors that existed WHEN THIS WAS SENT. A monitor that opened afterwards never saw
	// the frame, so letting it claim the record would suppress a real frame that merely looks
	// identical — the record must not outlive the set of sockets that could have received it.
	allowed []int
mut:
	// Which monitors have already accounted for this emission. Several monitors may watch one
	// interface (two channel entries can share a bus), and each gets its own copy of every
	// frame — so a record consumed outright by the first would make our own frame look foreign
	// to the second. Claimed once PER MONITOR keeps both honest while still exposing a second
	// transmitter: a repeat arriving at a monitor that already claimed this record finds
	// nothing left for it.
	claimed []int
}

// Ring holds the emissions not yet accounted for. Not thread-safe: the caller serialises it
// (the GUI already holds one mutex over the trace this indexes into).
pub struct Ring {
pub mut:
	window_ms f64 = default_window_ms
	cap       int = default_cap
mut:
	items []Pending
}

// note records a frame we are about to put on the wire. Call it BEFORE the send: a monitor
// thread can see the frame the instant the driver takes it, and a record added afterwards
// arrives too late to claim its own echo.
// Returns the row identities evicted to stay within `cap` without ever having been accounted
// for — reported, not dropped in silence, because the whole point of the record is that every
// emission ends with a verdict. Silent eviction would go quiet in exactly the sustained-traffic
// case where a dead bus matters most.
pub fn (mut r Ring) note(seq u64, iface string, f transport.CanFrame, t_ms f64, monitors []int) []u64 {
	r.items << Pending{
		seq:     seq
		allowed: monitors.clone()
		iface:   iface
		id:    f.id
		ext:   f.extended
		rtr:   f.rtr
		data:  f.data.clone()
		t_ms:  t_ms
	}
	mut evicted := []u64{}
	if r.cap > 0 && r.items.len > r.cap {
		drop := r.items.len - r.cap
		for pd in r.items[..drop] {
			if pd.claimed.len == 0 {
				evicted << pd.seq
			}
		}
		r.items = r.items[drop..].clone()
	}
	return evicted
}

// claim reports which emission this frame is the echo of, consuming it, or none if the frame
// is somebody else's.
//
// ONE-SHOT, oldest first. Consuming the record is what makes a duplicate transmitter visible:
// when a simulated ECU and the real one both send the same id, the first frame claims our
// record and the second finds nothing left, so it is attributed to the bus. Matching without
// consuming would attribute both to us and hide the collision this exists to surface.
pub fn (mut r Ring) claim(monitor int, iface string, f transport.CanFrame, t_ms f64) ?u64 {
	r.drop_expired(t_ms)
	for i, p in r.items {
		if monitor in p.claimed {
			continue // this monitor already accounted for that emission
		}
		if p.allowed.len > 0 && monitor !in p.allowed {
			continue // this socket did not exist when the frame went out
		}
		// Width- and kind-exact. An extended frame is NOT the echo of a standard one that
		// happens to share the low 11 bits, and an RTR request is not the echo of the data
		// frame answering it — either shortcut would attribute a real ECU's frame to us.
		if p.iface == iface && p.id == f.id && p.ext == f.extended && p.rtr == f.rtr
			&& p.data == f.data {
			r.items[i].claimed << monitor
			return p.seq
		}
	}
	return none
}

// expire retires emissions whose echo never came, returning their row identities. Callers drive
// this from the emit/receive paths, so on a bus that falls completely silent the last few stay
// unresolved until something moves — the alternative is a timer thread whose only job is to say
// "still nothing", which is a worse trade than a late verdict.
pub fn (mut r Ring) expire(now_ms f64) []u64 {
	mut missed := []u64{}
	mut keep := []Pending{cap: r.items.len}
	for p in r.items {
		if now_ms - p.t_ms <= r.window_ms {
			keep << p
			continue
		}
		// Only what NO monitor ever saw. A record kept around to serve a second monitor has
		// already been accounted for once, and reporting it again would accuse a bus that
		// carried the frame perfectly well.
		if p.claimed.len == 0 {
			missed << p.seq
		}
	}
	r.items = keep
	return missed
}

// forget discards the record for one emission without a verdict — for a send that FAILED, where
// the frame never went out and the caller has already said so on the row itself.
pub fn (mut r Ring) forget(seq u64) {
	for i, p in r.items {
		if p.seq == seq {
			r.items.delete(i)
			return
		}
	}
}

// drop_expired discards timed-out records without reporting them — used on the claim path,
// where the caller is asking a different question and expire() drives the verdicts.
fn (mut r Ring) drop_expired(now_ms f64) {
	if r.items.len == 0 {
		return
	}
	mut keep := []Pending{cap: r.items.len}
	for p in r.items {
		if now_ms - p.t_ms <= r.window_ms {
			keep << p
		}
	}
	r.items = keep
}

// outstanding is how many emissions are still unaccounted for.
pub fn (r Ring) outstanding() int {
	return r.items.len
}

// No clear(): a trace Clear must NOT drop these. The records are what makes an echo still in
// flight recognisable as ours; forgetting them turns the next few of our own frames into BUS
// rows, recording entries and E2E-verifier input. Row identities are monotonic and the trace
// base already makes old ones unresolvable, so a stale record can suppress its echo without
// ever confirming a row that came later.
