// The transport protocol (J1939-21), OBSERVED. Anything over 8 bytes rides TP: a connection
// management frame (TP.CM, PGN 0xEC00) announces a message — its size, its packet count, the
// PGN it carries — and data transfer frames (TP.DT, PGN 0xEB00) deliver it seven bytes at a
// time, numbered from 1. BAM is the broadcast form (announce, then send); RTS/CTS is the
// destination-specific one, where the receiver paces the sender with Clear-To-Send frames.
//
// This is a LISTENER, not a peer. It sends nothing — no CTS, no acknowledgement, no abort —
// and never times out a sender on its behalf; it only rejoins what goes past so a trace can
// show the message the frames were carrying. That is the shape `modules/isotp` solved for
// ISO 15765-2 with a channel of its own; here the same state machine is fed from the outside
// with every frame off the wire, because a rest-bus trace watches EVERY session at once and
// none of them is ours. A session is keyed by (source, destination): J1939 allows one
// connection per pair per direction, so two ECUs talking to each other, or one ECU
// broadcasting while it also answers a request, are two sessions and are kept apart.
//
// What comes out is one Assembled per completed message and one Fault per thing that did not
// go to plan, stated rather than swallowed, because a missing 20-byte parameter group in a
// trace should say WHY it is missing (a dropped packet, an abort, a sender that stopped).
module j1939

import encoding.binary
import transport

// TP.CM control bytes (data[0]).
const cm_rts = u8(16)
const cm_cts = u8(17)
const cm_eom_ack = u8(19)
const cm_bam = u8(32)
const cm_abort = u8(255)

// A multi-packet message is at least 9 bytes (anything shorter fits one frame and is sent as
// one) and at most 255 packets of 7: 1785 bytes.
pub const tp_min_size = 9
pub const tp_max_size = 1785

// packets_for is how many data frames `size` bytes take, seven to a frame. The ONE spelling:
// the announcement's packet count is checked against it and a session's progress is reported
// in terms of it, so the two cannot drift.
pub fn packets_for(size int) int {
	return (size + 6) / 7
}

// FaultKind is what went wrong with a session — the vocabulary a trace or log narrates in.
pub enum FaultKind {
	// A data frame with no session to belong to. Normal for a listener that attaches
	// mid-transfer, and the reason the caller decides how loudly to say it.
	orphan
	// A sequence number that is not the next one: a dropped packet, or a duplicate. The session
	// is abandoned, as a J1939 receiver would abandon it.
	sequence
	// A new announcement for a pair that still had a session open: the previous one was never
	// finished and is dropped in favour of the new one.
	restarted
	// A TP.CM Connection Abort, from either side. The detail carries the reason.
	aborted
	// Nothing from the session within its wait: T1 between a BAM's data frames, T3 for a
	// connection whose receiver has gone quiet. The sender stopped, or the frames went where
	// this listener could not see them.
	timeout
	// A control frame this module cannot read: a size or packet count that do not agree, a BAM
	// addressed to one node, an RTS broadcast, a frame too short to carry its fields.
	malformed
	// More sessions open than this listener keeps; the stalest was dropped to make room.
	overflow
}

// Fault is one thing that went wrong, about one session.
pub struct Fault {
pub:
	kind   FaultKind
	sa     u8
	da     u8
	pgn    u32 // the PGN the session carried; 0 where nothing said (an orphan data frame)
	detail string
}

// str is the fault in words, for a log line.
pub fn (f Fault) str() string {
	who := if f.da == addr_global {
		'SA 0x${f.sa:02X} broadcast'
	} else {
		'SA 0x${f.sa:02X} to 0x${f.da:02X}'
	}
	what := if f.pgn != 0 { ' PGN 0x${f.pgn:04X}' } else { '' }
	return 'TP ${who}${what}: ${f.detail}'
}

// fault is a Fault about a frame with no session behind it: the addresses are the frame's own,
// the PGN whatever the frame announced (0 for a data frame, which announces nothing).
fn (i Id) fault(kind FaultKind, pgn u32, detail string) Fault {
	return Fault{
		kind:   kind
		sa:     i.sa
		da:     i.da()
		pgn:    pgn
		detail: detail
	}
}

// Assembled is one completed multi-packet message.
pub struct Assembled {
pub:
	pgn      u32
	sa       u8
	da       u8 // addr_global for a BAM
	priority u8 // the announcing frame's
	bam      bool
	data     []u8 // exactly the announced size; the last frame's 0xFF padding removed
	// When the announcement was seen and when the last packet was — the message spans both.
	t_start_ms f64
	t_end_ms   f64
}

// id is the identifier a SINGLE frame of this PGN from this sender to this destination would
// carry — what a database lookup matches on, so a reassembled parameter group decodes against
// the same BO_ a short one would.
pub fn (a Assembled) id() u32 {
	return compose(a.priority, a.pgn, a.da, a.sa)
}

// packets is how many data frames carried it.
pub fn (a Assembled) packets() int {
	return packets_for(a.data.len)
}

// Events is what one frame produced: usually nothing, sometimes a message, sometimes a fault —
// and occasionally both, when a frame completes one session while another has just expired.
pub struct Events {
pub mut:
	done   []Assembled
	faults []Fault
}

struct Session {
mut:
	sa         u8
	da         u8
	pgn        u32
	priority   u8
	bam        bool
	total      int
	next       u8 = 1 // the sequence number the next data frame must carry
	data       []u8
	t_start_ms f64
	t_last_ms  f64 // the session's last frame in either direction
}

fn (s Session) packets() int {
	return packets_for(s.total)
}

// progress is where the session stands, for a fault's detail.
fn (s Session) progress() string {
	return 'packet ${s.next - 1} of ${s.packets()}'
}

// fault is a Fault about this session.
fn (s Session) fault(kind FaultKind, detail string) Fault {
	return Fault{
		kind:   kind
		sa:     s.sa
		da:     s.da
		pgn:    s.pgn
		detail: detail
	}
}

fn skey(sa u8, da u8) u16 {
	return (u16(sa) << 8) | u16(da)
}

// Reassembler is the listener's state: every session in progress on one bus.
pub struct Reassembler {
mut:
	sessions map[u16]Session
pub mut:
	// The receiver's inter-packet timeout, J1939-21 T1: 750 ms. A BAM session that has seen no
	// data frame for this long is abandoned the next time anything is fed or `expire` is called.
	t1_ms f64 = 750
	// An RTS/CTS session is paced by its receiver, which may take up to T3 (1250 ms) to answer
	// an RTS or a completed block with a CTS, and may hold the sender with a CTS for zero
	// packets — so a connection is timed from its LAST FRAME IN EITHER DIRECTION and given the
	// longer wait, or a listener would drop a session both peers consider healthy (a receiver
	// that takes a second to say "go on" is within the standard).
	t3_ms f64 = 1250
	// How many sessions are kept at once. J1939 bounds it at one per (source, destination)
	// pair, which is not a bound worth allocating for; a bench sees a handful. Past this the
	// stalest is dropped and said.
	max_sessions int = 64
}

// open is the number of sessions in progress.
pub fn (r Reassembler) open() int {
	return r.sessions.len
}

// feed observes one frame at `now_ms` (any monotonic millisecond clock — the caller's trace
// time, or a recording's). Standard, remote and non-TP frames produce nothing.
pub fn (mut r Reassembler) feed(f transport.CanFrame, now_ms f64) Events {
	mut ev := Events{}
	if !f.extended || f.rtr {
		return ev
	}
	id := decompose(f.id)
	// Expiry first, so a session that stalled is said before whatever this frame does — but a
	// data frame arriving just past the limit is the LATE PACKET of the session that expired,
	// not an orphan of nothing: the timeout already explains it, saying "no announcement" about
	// a frame whose announcement was seen would be false, and it would spend the caller's
	// once-per-wire orphan notice on it (self-review of #171).
	mut expired := []Fault{}
	if r.sessions.len > 0 {
		expired = r.expire(now_ms)
		ev.faults << expired
	}
	match id.pgn() {
		pgn_tp_cm {
			r.on_cm(id, f.data, now_ms, mut ev)
		}
		pgn_tp_dt {
			late := expired.any(it.sa == id.sa && it.da == id.da())
			r.on_dt(id, f.data, now_ms, late, mut ev)
		}
		else {}
	}

	return ev
}

// expire drops every session that has waited longer than its limit for the next frame.
pub fn (mut r Reassembler) expire(now_ms f64) []Fault {
	mut out := []Fault{}
	mut stale := []u16{}
	for k, s in r.sessions {
		limit := if s.bam { r.t1_ms } else { r.t3_ms }
		if now_ms - s.t_last_ms > limit {
			stale << k
			out << s.fault(.timeout,
				'nothing for ${now_ms - s.t_last_ms:.0} ms after ${s.progress()}; dropped')
		}
	}
	for k in stale {
		r.sessions.delete(k)
	}
	return out
}

fn (mut r Reassembler) on_cm(id Id, data []u8, now_ms f64, mut ev Events) {
	if data.len < 8 {
		ev.faults << id.fault(.malformed, 0,
			'TP.CM of ${data.len} bytes; a control frame carries 8')
		return
	}
	ctrl := data[0]
	carried := u32(data[5]) | (u32(data[6]) << 8) | (u32(data[7]) << 16)
	match ctrl {
		cm_bam, cm_rts {
			bam := ctrl == cm_bam
			// A BAM is broadcast by definition and an RTS opens a connection with ONE node:
			// a BAM addressed to a node, or an RTS to everyone, is not a frame J1939 describes,
			// and rejoining it would model something that cannot happen.
			if bam && id.da() != addr_global {
				ev.faults << id.fault(.malformed, carried,
					'BAM addressed to 0x${id.da():02X}; a BAM is broadcast')
				return
			}
			if !bam && id.da() == addr_global {
				ev.faults << id.fault(.malformed, carried,
					'RTS to the global address; a connection has one destination')
				return
			}
			total := int(binary.little_endian_u16_at(data, 1))
			packets := int(data[3])
			if total < tp_min_size || total > tp_max_size {
				ev.faults << id.fault(.malformed, carried,
					'announces ${total} bytes; a multi-packet message is ${tp_min_size}..${tp_max_size}')
				return
			}
			if packets != packets_for(total) {
				ev.faults << id.fault(.malformed, carried,
					'announces ${total} bytes in ${packets} packets; ${total} bytes take ${packets_for(total)}')
				return
			}
			k := skey(id.sa, id.da())
			if old := r.sessions[k] {
				kind := if bam { 'BAM' } else { 'RTS' }
				ev.faults << old.fault(.restarted,
					'a new ${kind} arrived after ${old.progress()}; the unfinished message is dropped')
				r.sessions.delete(k)
			}
			r.make_room(mut ev)
			r.sessions[k] = Session{
				sa:         id.sa
				da:         id.da()
				pgn:        carried
				priority:   id.priority
				bam:        bam
				total:      total
				data:       []u8{cap: total}
				t_start_ms: now_ms
				t_last_ms:  now_ms
			}
		}
		cm_cts {
			// The receiver's side of the conversation: from the receiver (this frame's SA) to the
			// originator (its DA), so the session it keeps alive is keyed the other way round. It
			// changes nothing about the bytes going past — the message completes on its last data
			// frame — but it is the session talking, and the timeout is measured from it.
			k := skey(id.da(), id.sa)
			if mut s := r.sessions[k] {
				s.t_last_ms = now_ms
				r.sessions[k] = s
			}
		}
		cm_eom_ack {
			// The receiver's acknowledgement of a message that completed on its last data frame,
			// acknowledged or not. Nothing to do.
		}
		cm_abort {
			// From the originator (session keyed sa->da) or from the receiver (keyed da->sa);
			// the frame does not say which, so both are tried. Neither open: nothing this
			// listener tracked, and an abort about a session it never saw is not a fault of
			// anything it can name.
			reason := data[1]
			for k in [skey(id.sa, id.da()), skey(id.da(), id.sa)] {
				if s := r.sessions[k] {
					ev.faults << s.fault(.aborted,
						'aborted by SA 0x${id.sa:02X} after ${s.progress()}: ${abort_reason(reason)}')
					r.sessions.delete(k)
				}
			}
		}
		else {
			ev.faults << id.fault(.malformed, carried,
				'TP.CM control byte ${ctrl} is not one this module knows')
		}
	}
}

// on_dt takes a data frame; `late` says its session expired on this very frame, so it is not an
// orphan but the packet the timeout was about.
fn (mut r Reassembler) on_dt(id Id, data []u8, now_ms f64, late bool, mut ev Events) {
	k := skey(id.sa, id.da())
	mut s := r.sessions[k] or {
		if !late {
			seq := if data.len > 0 { int(data[0]) } else { 0 }
			ev.faults << id.fault(.orphan, 0,
				'data frame ${seq} with no announcement; a transfer already in progress when listening began, or one whose TP.CM was lost')
		}
		return
	}
	if data.len < 1 {
		ev.faults << s.fault(.malformed, 'empty data frame; dropped')
		r.sessions.delete(k)
		return
	}
	seq := data[0]
	if seq != s.next {
		what := if seq == s.next - 1 { 'duplicate' } else { 'gap' }
		ev.faults << s.fault(.sequence,
			'sequence ${what}: got packet ${seq}, expected ${s.next}; dropped')
		r.sessions.delete(k)
		return
	}
	need := s.total - s.data.len
	take := if need < 7 { need } else { 7 }
	// A data frame is always 8 bytes on the wire, the last one padded with 0xFF. Anything
	// short of what this packet must carry would have to be filled from the next frame, which
	// is a shifted message returned as valid — refused, as isotp refuses a short Consecutive
	// Frame with more to come.
	if data.len - 1 < take {
		ev.faults << s.fault(.malformed,
			'data frame ${seq} carries ${data.len - 1} bytes where ${take} were due; dropped')
		r.sessions.delete(k)
		return
	}
	s.data << data[1..1 + take]
	s.next++
	s.t_last_ms = now_ms
	if s.data.len >= s.total {
		ev.done << Assembled{
			pgn:        s.pgn
			sa:         s.sa
			da:         s.da
			priority:   s.priority
			bam:        s.bam
			data:       s.data
			t_start_ms: s.t_start_ms
			t_end_ms:   now_ms
		}
		r.sessions.delete(k)
		return
	}
	r.sessions[k] = s
}

// make_room drops the stalest session when the table is full, and says so.
fn (mut r Reassembler) make_room(mut ev Events) {
	for r.sessions.len >= r.max_sessions {
		mut victim := u16(0)
		mut oldest := f64(0)
		mut first := true
		for k, s in r.sessions {
			if first || s.t_last_ms < oldest {
				victim = k
				oldest = s.t_last_ms
				first = false
			}
		}
		s := r.sessions[victim]
		ev.faults << s.fault(.overflow,
			'${r.max_sessions} sessions open; the stalest (after ${s.progress()}) is dropped')
		r.sessions.delete(victim)
	}
}

// abort_reason names a Connection Abort reason byte (J1939-21).
pub fn abort_reason(code u8) string {
	return match code {
		1 { 'reason 1, already in one or more connection-managed sessions' }
		2 { 'reason 2, system resources needed for another task' }
		3 { 'reason 3, a timeout occurred' }
		4 { 'reason 4, CTS received while data transfer was in progress' }
		5 { 'reason 5, maximum retransmit request limit reached' }
		6 { 'reason 6, unexpected data transfer packet' }
		7 { 'reason 7, bad sequence number' }
		8 { 'reason 8, duplicate sequence number' }
		9 { 'reason 9, message too large to send' }
		else { 'reason ${code}' }
	}
}
