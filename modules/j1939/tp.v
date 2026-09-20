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

// TP.CM control bytes (data[0]). Public because the rest-bus subtraction reads announcements
// too: an excluded node's multi-packet message is TP.CM and TP.DT frames on the wire, and only
// the announcement says which parameter group they carry.
pub const cm_rts = u8(16)
pub const cm_cts = u8(17)
pub const cm_eom_ack = u8(19)
pub const cm_bam = u8(32)
pub const cm_abort = u8(255)

// Cm is a TP.CM frame's fields, read once (`parse_cm`) for every consumer of them.
pub struct Cm {
pub:
	ctrl     u8
	reserved u8 // byte 4: J1939-21 fixes it at 0xFF in a BAM; in an RTS it is packets-per-CTS
	total    int // bytes announced (RTS, BAM); the abort reason sits in the same byte for an abort
	packets  int // packets announced (RTS, BAM)
	pgn      u32 // the parameter group the frame is about (bytes 5..7)
}

// parse_cm reads a TP.CM payload; none unless it is EXACTLY the eight bytes a J1939-21
// transport frame carries. Longer is not "eight and some": on an FD-capable wire a J1939-22 or
// proprietary frame whose id computes to TP.CM would otherwise be read as an announcement by its
// first eight bytes and the rest invented into a message (codex on #329).
pub fn parse_cm(data []u8) ?Cm {
	if data.len != 8 {
		return none
	}
	return Cm{
		ctrl: data[0]
		total: int(binary.little_endian_u16_at(data, 1))
		packets: int(data[3])
		reserved: data[4]
		pgn: u32(data[5]) | (u32(data[6]) << 8) | (u32(data[7]) << 16)
	}
}

// receiver_control says whether a control frame can be THE RECEIVER'S, for a session that is
// or is not a broadcast.
//
// Two halves, stated once because both branches that look a session up the reversed way need
// them: a BAM has no receiver at all, so nothing answers one; and the global and null addresses
// originate nothing, so a frame "from" either is of some other making. Without this, a CTS
// sourced from 0xFF and addressed to a BAM's originator resolved onto the broadcast session and
// could refresh, rewind or truncate it, and an acknowledgement could close it (codex).
pub fn receiver_control(id Id, bam bool) bool {
	return !bam && id.sa != addr_global && id.sa != addr_null
}

// acknowledges is THE rule for whether an EndOfMsgACK names a given open transfer: its group,
// its byte count and its packet count, all three.
//
// One rule for the same reason `admission` below is one: the reassembler and `Transfers` both
// act on it, and a rule written twice is two rules the moment one is corrected — which is
// exactly what happened here, the PGN-only check being fixed in the reassembler and left in the
// walker one round earlier (codex). A stale or malformed acknowledgement of an EARLIER transfer
// between the same pair, of the same group, otherwise closes the newer one: the reassembler
// abandons a message it could have rejoined, and the walker forgets the announcement verdict,
// so the rest of that transfer's packets replay as unknown.
pub fn (c Cm) acknowledges(pgn u32, total int, packets int) bool {
	return c.pgn == pgn && c.total == total && c.packets == packets
}

// admission is THE rule for whether a TP.CM frame announces a transfer this module will follow,
// and why not when it does not — for the reassembler, which narrates the reason, and for
// Transfers, which attributes frames and must refuse exactly the same announcements, or the two
// walk the same recording and disagree about which frames belong to whom (codex on #329, three
// findings in one round, each a rule written twice). `id` is the frame's own identifier.
pub fn (c Cm) admission(id Id) ?string {
	bam := c.ctrl == cm_bam
	if !bam && c.ctrl != cm_rts {
		return 'TP.CM control byte ${c.ctrl} is not an announcement'
	}
	// A BAM is broadcast by definition and an RTS opens a connection with ONE node: a BAM
	// addressed to a node, or an RTS to everyone, is not a frame J1939 describes, and following
	// it would model something that cannot happen.
	if bam && id.da() != addr_global {
		return 'BAM addressed to 0x${id.da():02X}; a BAM is broadcast'
	}
	if !bam && id.da() == addr_global {
		return 'RTS to the global address; a connection has one destination'
	}
	if !bam && id.da() == addr_null {
		return 'RTS to the null address, which no node holds'
	}
	if c.total < tp_min_size || c.total > tp_max_size {
		return 'announces ${c.total} bytes; a multi-packet message is ${tp_min_size}..${tp_max_size}'
	}
	if c.packets != packets_for(c.total) {
		return 'announces ${c.total} bytes in ${c.packets} packets; ${c.total} bytes take ${packets_for(c.total)}'
	}
	// The PGN it carries must be one: 18 bits, and for a PDU1 group (PF below 0xF0) a zero low
	// byte, since that byte is a destination there and not part of any PGN. Followed anyway,
	// compose() would silently drop the bits and present the transfer as a DIFFERENT, valid
	// parameter group (codex on #329).
	if c.pgn > 0x3FFFF {
		return 'carries PGN 0x${c.pgn:X}, which is wider than 18 bits'
	}
	if ((c.pgn >> 8) & 0xFF) < 0xF0 && (c.pgn & 0xFF) != 0 {
		return 'carries PGN 0x${c.pgn:05X}, a PDU1 group with a nonzero low byte'
	}
	// Byte 4 is RESERVED IN A BAM and J1939-21 fixes it at 0xFF, so a frame carrying anything
	// else there is not a broadcast announcement — and admitted as one it becomes a synthetic
	// message, and something the rest-bus walker attributes and may withhold (codex). In an RTS
	// the same byte is a real field (packets the sender may send per CTS), which this listener
	// does not act on, so it is not judged here.
	if bam && c.reserved != 0xFF {
		return 'BAM reserved byte 0x${c.reserved:02X}; J1939-21 fixes it at 0xFF'
	}
	// And it must come from a node: the null address (a Cannot Claim's source) and the global
	// address originate nothing, so a transfer "from" either is a frame of some other making and
	// must not become a message or an attribution (codex on #329).
	if id.sa == addr_null || id.sa == addr_global {
		return 'announced from 0x${id.sa:02X}, which is not a node address'
	}
	return none
}

// Role is what a frame IS to the transport protocol, for a consumer that needs to know WHOSE
// frame it is rather than what it carries — the rest-bus subtraction, which must withhold an
// excluded node's announcement and packets and has no use for the bytes.
pub enum Role {
	not_tp // not a transport-protocol frame at all
	announce // an admitted BAM or RTS: the first frame of a transfer, from its originator
	packet // a data frame of a transfer in progress — the originator's, duplicate or gap included
	sender_abort // an abort from the originator of a transfer in progress
	receiver // the receiver's side of a connection: CTS, end-of-message ack, an abort from the receiver
	stray // a TP frame nothing accounts for: a refused announcement, a packet or abort with no transfer
}

// Step is one frame's role, with the transfer it belongs to where it has one.
pub struct Step {
pub:
	role     Role
	pgn      u32 // the parameter group the transfer carries
	priority u8 // the announcement's
	sa       u8 // the transfer's originator
	da       u8 // its destination (addr_global for a BAM)
	done     bool // this frame ended the transfer (its last packet, or an abort)
}

struct Open {
	pgn      u32
	priority u8
	total    int // bytes announced; with `packets`, what an acknowledgement must name (acknowledges)
	packets  int
	bam      bool
mut:
	next   u8 // the sequence number expected next
	last_s f64 // the transfer's last frame in either direction, on the caller's clock
}

// Transfers follows which transport-protocol transfers are in progress, by (originator,
// destination), and says what each frame is to them. No data, no clock: a recording is walked
// in its own order, and the question is attribution, not content. Admission is `Cm.admission`,
// the reassembler's rule; a transfer completes on its LAST SEQUENCE NUMBER, not after a count of
// frames, so a retransmitted packet in a capture does not end it early and leave the real last
// packet unaccounted for (codex on #329).
pub struct Transfers {
mut:
	open   map[u16]Open
	last_s f64 // the clock's last reading, for a caller without one

	// The same waits the reassembler applies, in the caller's SECONDS (a recording's clock):
	// T1 between a BAM's packets, T3 for a connection from its last frame in either direction.
	// A transfer whose last packet the capture lost would otherwise stay open for the rest of
	// the file, and a packet on the same pair minutes later — after the address changed hands,
	// say — would inherit its decision (codex on #329).
pub mut:
	t1_s f64 = 0.75
	t3_s f64 = 1.25
}

// step classifies one frame for a caller with NO clock: nothing expires, transfers end on their
// last packet, an abort or an ack, or when the pair announces again. The tests and any consumer
// that walks frames without timestamps.
pub fn (mut t Transfers) step(f transport.CanFrame) Step {
	return t.step_at(f, t.last_s)
}

// step_at classifies one frame at `t_s` on the caller's clock, expiring first the transfers that
// have waited past their limit, then advancing the ones this frame touches.
pub fn (mut t Transfers) step_at(f transport.CanFrame, t_s f64) Step {
	t.last_s = t_s
	if t.open.len > 0 {
		mut stale := []u16{}
		for k, o in t.open {
			limit := if o.bam { t.t1_s } else { t.t3_s }
			if t_s - o.last_s > limit {
				stale << k
			}
		}
		for k in stale {
			t.open.delete(k)
		}
	}
	if !f.extended || f.rtr {
		return Step{
			role: .not_tp
		}
	}
	id := decompose(f.id)
	pgn := id.pgn()
	if pgn == pgn_tp_cm {
		k := skey(id.sa, id.da())
		cm := parse_cm(f.data) or {
			// Not a frame this module reads — but its control byte, if it has one, still says
			// whether the pair started over: a mis-sized RTS or BAM ends the previous transfer
			// like a refused one does, or the replacement's first packet lands in the old
			// session (codex on #329).
			if f.data.len > 0 && (f.data[0] == cm_rts || f.data[0] == cm_bam) {
				had := k in t.open
				t.open.delete(k)
				return Step{
					role: .stray
					sa: id.sa
					da: id.da()
					done: had
				}
			}
			return Step{
				role: .stray
			}
		}
		match cm.ctrl {
			cm_rts, cm_bam {
				if _ := cm.admission(id) {
					// A refused announcement still says the pair started over: the previous
					// transfer, if any, is gone, or the replacement's packets would be filed
					// as the old announcement's (codex on #329). `done` tells the walker.
					had := k in t.open
					t.open.delete(k)
					return Step{
						role: .stray
						sa: id.sa
						da: id.da()
						done: had
					}
				}
				t.open[k] = Open{
					pgn: cm.pgn
					priority: id.priority
					total: cm.total
					packets: cm.packets
					bam: cm.ctrl == cm_bam
					next: 1
					last_s: t_s
				}
				return Step{
					role: .announce
					pgn: cm.pgn
					priority: id.priority
					sa: id.sa
					da: id.da()
				}
			}
			cm_abort {
				// The abort names its PGN; from the originator it ends the transfer keyed this
				// way, from the receiver the one keyed the other way — and neither if it names
				// a transfer neither is (two nodes can be mid-transfer in both directions).
				if s := t.open[k] {
					if s.pgn == cm.pgn {
						t.open.delete(k)
						return Step{
							role: .sender_abort
							pgn: s.pgn
							priority: s.priority
							sa: id.sa
							da: id.da()
							done: true
						}
					}
				}
				rk := skey(id.da(), id.sa)
				if s := t.open[rk] {
					// the RECEIVER's abort, which a broadcast has none of (receiver_control)
					if receiver_control(id, s.bam) && s.pgn == cm.pgn {
						t.open.delete(rk)
						return Step{
							role: .receiver
							pgn: s.pgn
							sa: id.da()
							da: id.sa
							done: true
						}
					}
				}
				return Step{
					role: .stray
				}
			}
			cm_eom_ack {
				// The receiver says the transfer keyed the other way round is complete. A
				// capture that lost the last packet still has this, and a transfer left open
				// there would lend its verdict to the pair's next packets (codex on #329).
				rk := skey(id.da(), id.sa)
				mut done := false
				if s := t.open[rk] {
					// `receiver_control` here too, for the reassembler's reason: a BAM has no
					// receiver, and the global and null addresses originate nothing.
					if receiver_control(id, s.bam) && cm.acknowledges(s.pgn, s.total, s.packets) {
						t.open.delete(rk)
						done = true
					}
				}
				return Step{
					role: .receiver
					pgn: cm.pgn
					sa: id.da()
					da: id.sa
					done: done
				}
			}
			cm_cts {
				// the receiver talking keeps the connection it names alive, as it does for the
				// reassembler — and only a real receiver of a real connection (receiver_control)
				rk := skey(id.da(), id.sa)
				if mut s := t.open[rk] {
					if receiver_control(id, s.bam) && s.pgn == cm.pgn {
						s.last_s = t_s
						t.open[rk] = s
					}
				}
				return Step{
					role: .receiver
					pgn: cm.pgn
					sa: id.da()
					da: id.sa
				}
			}
			else {
				return Step{
					role: .stray
				}
			}
		}
	}
	if pgn == pgn_tp_dt {
		k := skey(id.sa, id.da())
		mut s := t.open[k] or {
			return Step{
				role: .stray
			}
		}
		if f.data.len != 8 {
			// not a J1939-21 data frame (see parse_cm); it neither advances nor ends the transfer
			return Step{
				role: .stray
			}
		}
		seq := f.data[0]
		// Whatever the sequence says, a data frame on an open transfer's pair is its
		// originator's: a duplicate is the sender again, a gap is a frame the capture lost.
		// The transfer ends on EXACTLY its last sequence number — a corrupted number past the
		// count is the sender's frame too, but not the end, or the real last packet would come
		// after the transfer and belong to nobody (codex on #329). A transfer whose last packet
		// the capture lost stays open until the pair's next announcement replaces it.
		if seq >= s.next {
			s.next = seq + 1
		}
		s.last_s = t_s
		done := int(seq) == s.packets
		if done {
			t.open.delete(k)
		} else {
			t.open[k] = s
		}
		return Step{
			role: .packet
			pgn: s.pgn
			priority: s.priority
			sa: id.sa
			da: id.da()
			done: done
		}
	}
	return Step{
		role: .not_tp
	}
}

// open is how many transfers are in progress.
pub fn (t Transfers) open() int {
	return t.open.len
}

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
	// The unused bytes of a final data frame are not the 0xFF J1939-21 pads with. REPORTED AND
	// NOT ABANDONED, alone among these: those bytes lie past the announced length, so the
	// message is whole and correct and only the wire was wrong.
	padding
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
		kind: kind
		sa: i.sa
		da: i.da()
		pgn: pgn
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
		kind: kind
		sa: s.sa
		da: s.da
		pgn: s.pgn
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

	// The receiver's inter-packet timeout, J1939-21 T1: 750 ms. A BAM session that has seen no
	// data frame for this long is abandoned the next time anything is fed or `expire` is called.
pub mut:
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
			out << s.fault(.timeout, 'nothing for ${now_ms - s.t_last_ms:.0} ms after ${s.progress()}; dropped')
		}
	}
	for k in stale {
		r.sessions.delete(k)
	}
	return out
}

fn (mut r Reassembler) on_cm(id Id, data []u8, now_ms f64, mut ev Events) {
	cm := parse_cm(data) or {
		// and a mis-sized RTS or BAM still starts the pair over — see Transfers.step_at
		if data.len > 0 && (data[0] == cm_rts || data[0] == cm_bam) {
			k := skey(id.sa, id.da())
			if old := r.sessions[k] {
				ev.faults << old.fault(.restarted, 'a new announcement arrived after ${old.progress()}; the unfinished message is dropped')
				r.sessions.delete(k)
			}
		}
		ev.faults << id.fault(.malformed, 0, 'TP.CM of ${data.len} bytes; a transport-protocol frame carries exactly 8')
		return
	}
	ctrl := cm.ctrl
	carried := cm.pgn
	match ctrl {
		cm_bam, cm_rts {
			bam := ctrl == cm_bam
			if why := cm.admission(id) {
				// and whatever this pair had in progress is over — the sender started again,
				// however badly — or the replacement's first packet would land in the old
				// session as the old PGN (codex on #329)
				k := skey(id.sa, id.da())
				if old := r.sessions[k] {
					ev.faults << old.fault(.restarted, 'a new announcement arrived after ${old.progress()}; the unfinished message is dropped')
					r.sessions.delete(k)
				}
				ev.faults << id.fault(.malformed, carried, why)
				return
			}
			total := cm.total
			k := skey(id.sa, id.da())
			if old := r.sessions[k] {
				kind := if bam { 'BAM' } else { 'RTS' }
				ev.faults << old.fault(.restarted, 'a new ${kind} arrived after ${old.progress()}; the unfinished message is dropped')
				r.sessions.delete(k)
			}
			r.make_room(mut ev)
			r.sessions[k] = Session{
				sa: id.sa
				da: id.da()
				pgn: carried
				priority: id.priority
				bam: bam
				total: total
				data: []u8{cap: total}
				t_start_ms: now_ms
				t_last_ms: now_ms
			}
		}
		cm_cts {
			// The receiver's side of the conversation: from the receiver (this frame's SA) to the
			// originator (its DA), so the session it keeps alive is keyed the other way round. It
			// changes nothing about the bytes going past — the message completes on its last data
			// frame — but it is the session talking, and the timeout is measured from it.
			// And it names the PGN it is about: a CTS for another transfer between the same two
			// nodes — delayed, or malformed — must not keep a stalled one open (codex on #329).
			k := skey(id.da(), id.sa)
			if mut s := r.sessions[k] {
				// NOT A BROADCAST. A BAM has no receiver, so nothing legitimately answers one —
				// and a CTS sourced from the global address resolves this reversed key straight
				// onto the broadcast session, where matching its PGN would refresh its timeout
				// and rewind or truncate what it has assembled (codex). `receiver_control`
				// states both halves of that once.
				if receiver_control(id, s.bam) && s.pgn == carried {
					s.t_last_ms = now_ms
					// It also names WHICH PACKET to send next, and a receiver that missed one
					// sends the peer BACK. The retransmission then arrived as a sequence the
					// listener had already passed, was read as a duplicate, and abandoned a
					// transfer that was recovering perfectly well (codex). Only backwards, and
					// only within what was announced: a CTS asking for a packet this listener
					// has not reached yet would skip bytes it never saw, and one outside the
					// transfer names nothing.
					want := data[2]
					if want >= 1 && want < s.next && int(want) <= s.packets() {
						s.next = want
						s.data = s.data[..(int(want) - 1) * 7]
					}
					r.sessions[k] = s
				}
			}
		}
		cm_eom_ack {
			// The receiver's acknowledgement of a message that completed on its last data frame
			// — which this listener has already delivered, so ordinarily there is no session to
			// find. One still open under that PGN means the receiver saw a packet this listener
			// did not: the message cannot be rejoined, and that is said here rather than as a
			// timeout a second later (codex on #329).
			k := skey(id.da(), id.sa)
			if s := r.sessions[k] {
				// Not a broadcast's, and not from a non-node, for the CTS's reason above.
				// By the SIZE AND PACKET COUNT it names as well as the PGN. An acknowledgement
				// of an earlier transfer between the same pair, of the same group, would
				// otherwise drop the NEWER session as though the receiver had completed it —
				// and `Transfers.step_at` would clear its subtraction verdict with it, turning
				// the rest of its packets into orphans (codex).
				if receiver_control(id, s.bam) && cm.acknowledges(s.pgn, s.total, s.packets()) {
					ev.faults << s.fault(.sequence, 'acknowledged complete by SA 0x${id.sa:02X} after ${s.progress()}; the rest never reached this listener; dropped')
					r.sessions.delete(k)
				}
			}
		}
		cm_abort {
			// From the originator (session keyed sa->da) or from the receiver (keyed da->sa);
			// the frame does not say which, so both are tried — and the PGN it names decides,
			// because two nodes can be mid-transfer in BOTH directions at once and an abort of
			// one is not an abort of the other (codex on #329). Neither open, or neither
			// carrying that PGN: nothing this listener tracked, and an abort about a session it
			// never saw is not a fault of anything it can name.
			reason := data[1]
			// ONE session, the originator's direction first: two nodes mid-transfer towards each
			// other with the SAME PGN would otherwise both lose to one abort (codex on #329) —
			// and Transfers makes the same choice, so the walker and the trace agree.
			// The forward key is the originator aborting its own transfer; the reversed one is
			// the RECEIVER aborting, which a broadcast has none of and a non-node address
			// cannot be — `receiver_control`, as the clear-to-send and the acknowledgement ask
			// it. Without that, an abort "from" 0xFF deleted an open BAM through the reversed
			// key, and cleared its rest-bus attribution with it (codex).
			// The forward key is the ORIGINATOR aborting its own transfer; the reversed one is
			// the RECEIVER aborting, which a broadcast has none of and a non-node address
			// cannot be — `receiver_control`, as the clear-to-send and the acknowledgement ask
			// it. Without that an abort "from" 0xFF deleted an open BAM through the reversed
			// key, and `Transfers` cleared its rest-bus attribution with it (codex).
			fwd := skey(id.sa, id.da())
			for k in [fwd, skey(id.da(), id.sa)] {
				if s := r.sessions[k] {
					if s.pgn != carried {
						continue
					}
					if k != fwd && !receiver_control(id, s.bam) {
						continue
					}
					ev.faults << s.fault(.aborted, 'aborted by SA 0x${id.sa:02X} after ${s.progress()}: ${abort_reason(reason)}')
					r.sessions.delete(k)
					break
				}
			}
		}
		else {
			ev.faults << id.fault(.malformed, carried, 'TP.CM control byte ${ctrl} is not one this module knows')
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
			ev.faults << id.fault(.orphan, 0, 'data frame ${seq} with no announcement; a transfer already in progress when listening began, or one whose TP.CM was lost')
		}
		return
	}
	// A data frame is EXACTLY eight bytes on the wire, the last one padded with 0xFF: shorter
	// would have to be filled from the next frame — a shifted message returned as valid, as
	// isotp refuses a short Consecutive Frame — and longer is a frame of some other protocol on
	// an FD wire whose tail would be silently dropped (codex on #329).
	if data.len != 8 {
		ev.faults << s.fault(.malformed, 'data frame of ${data.len} bytes; a transport-protocol frame carries exactly 8; dropped')
		r.sessions.delete(k)
		return
	}
	seq := data[0]
	if seq != s.next {
		what := if seq == s.next - 1 { 'duplicate' } else { 'gap' }
		ev.faults << s.fault(.sequence, 'sequence ${what}: got packet ${seq}, expected ${s.next}; dropped')
		r.sessions.delete(k)
		return
	}
	need := s.total - s.data.len
	take := if need < 7 { need } else { 7 }
	// The LAST packet of a message whose length is not a multiple of seven has unused bytes,
	// and J1939-21 fixes them at 0xFF. Anything else there is a sender not following the
	// standard, and saying nothing about it leaves a bench tool quiet about the one thing it
	// is for — but the MESSAGE is whole and correct, since those bytes lie past the announced
	// length, so this is said WITHOUT dropping the transfer (codex). A fault that abandons and
	// a fault that merely reports are different things; only the kinds documented as abandoning
	// delete the session.
	for i in take .. 7 {
		if data[1 + i] != 0xFF {
			ev.faults << s.fault(.padding, 'final packet pads with 0x${data[1 + i]:02X} at byte ${i}; J1939-21 pads with 0xFF')
			break
		}
	}
	s.data << data[1..1 + take]
	s.next++
	s.t_last_ms = now_ms
	if s.data.len >= s.total {
		ev.done << Assembled{
			pgn: s.pgn
			sa: s.sa
			da: s.da
			priority: s.priority
			bam: s.bam
			data: s.data
			t_start_ms: s.t_start_ms
			t_end_ms: now_ms
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
		ev.faults << s.fault(.overflow, '${r.max_sessions} sessions open; the stalest (after ${s.progress()}) is dropped')
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
