// tp.v — J1939 transport protocol (J1939-21), OBSERVED.
//
// Anything over 8 bytes on a J1939 bus travels as a transport session: an announcement on
// PGN 0xEC00 (TP.CM) and a run of 7-byte packets on PGN 0xEB00 (TP.DT). Until #171 those
// arrived in the trace as a burst of unrelated frames, so the payloads people actually care
// about on a truck bus were the ones the tool could not read.
//
// This is a PASSIVE observer, and that is the whole design. blobly is not a participant in the
// session: it never sends a CTS, never acknowledges, never aborts anybody. It watches the two
// PGNs go past and rebuilds what they carried. Every rule below follows from that -- the
// timeouts are abandonment tests rather than protocol timers, a CTS is read only for what it
// says about the session's liveness, and an EndOfMsgAck for a transfer this side did not
// complete is evidence THIS TOOL dropped frames, which is worth saying out loud on a bench.
//
// The state machine is the shape of `modules/isotp`'s and shares none of its code: ISO-TP is
// point to point over a pair of CAN ids with a PCI nibble and receiver-paced flow control,
// where this is two fixed PGNs, a sequence byte, sessions keyed by the addresses inside the
// 29-bit id, and a broadcast form with no flow control at all.
module j1939

// The two parameter groups a session is made of.
pub const tp_cm_pgn = u32(0x00EC00)
pub const tp_dt_pgn = u32(0x00EB00)

// TP.CM control bytes (byte 0 of the announcement).
pub const cm_rts = u8(0x10)
pub const cm_cts = u8(0x11)
pub const cm_eoma = u8(0x13)
pub const cm_bam = u8(0x20)
pub const cm_abort = u8(0xFF)

// A session's bounds. 7 bytes per packet, a one-byte sequence number that starts at 1, and a
// size that must not fit in a single frame -- a transport session for 8 bytes or fewer is
// malformed, since the parameter group would simply have been sent.
pub const tp_bytes_per_packet = 7 // 8, less the sequence byte


pub const tp_min_size = 9
pub const tp_max_size = 255 * tp_bytes_per_packet // 1785


// max_sessions bounds what one noisy or hostile wire can make this cost. A real bus runs a
// handful of concurrent transfers; 64 is far past anything legitimate, and refusing the 65th
// with a reason beats evicting a transfer that is halfway through.
pub const max_sessions = 64

// Abandonment deadlines. J1939-21's T1 (750 ms between data packets) and T2/T3/T4 (1250 ms
// around the handshake) are timers for the PARTICIPANTS; here they are the point at which a
// watcher concludes a session it is following has stopped. Broadcast gets the tighter one
// because a BAM has no handshake to wait through.
pub const bam_gap_ms = f64(750)
pub const cm_gap_ms = f64(1250)

// TpKind separates the two forms, which behave differently enough that a reader of the trace
// should not have to work out which one it is looking at.
pub enum TpKind {
	bam // broadcast: announced to everybody, no flow control, packets follow at a fixed gap
	cm // connection mode: RTS/CTS between two addresses
}

pub fn (k TpKind) str() string {
	return if k == .bam { 'BAM' } else { 'CM' }
}

// TpMessage is one parameter group, rebuilt.
pub struct TpMessage {
pub:
	pgn     u32
	sa      u8
	da      u8 // addr_global for a BAM
	kind    TpKind
	packets int
	data    []u8
	t_ms    f64 // the LAST packet's timestamp: when the message finished arriving
	// The priority the SESSION ran at, carried because a rebuilt message has no identifier of
	// its own -- its packets carried the transport group's, not the data's -- and a caller
	// that synthesises one (`id_for`, for the trace row and the database lookup) would
	// otherwise have to invent this field. It is an observed number, not the priority the
	// parameter group would have had if it had fitted in one frame; nothing on the wire says
	// what that would have been.
	priority u8
}

// TpAbort is a session this side stopped following, and why. It is reported rather than
// dropped for the reason the ARXML reader reports what it could not read: a transfer that
// silently vanishes from the trace is indistinguishable from one that never happened.
pub struct TpAbort {
pub:
	pgn      u32
	sa       u8
	da       u8
	kind     TpKind
	reason   string
	got      int // packets seen
	packets  int // packets the announcement promised
	t_ms     f64
	priority u8 // the session's, as TpMessage carries it
}

// Session is one transfer being followed.
struct Session {
	pgn      u32
	sa       u8
	da       u8
	kind     TpKind
	size     int
	packets  int
	started  f64
	priority u8
mut:
	data     []u8
	got      []bool
	n_got    int
	last_ms  f64 // the last frame of this session, of any kind: what the deadline runs from
	deadline f64
}

fn (s Session) abort(reason string, t_ms f64) TpAbort {
	return TpAbort{
		pgn: s.pgn
		sa: s.sa
		da: s.da
		kind: s.kind
		reason: reason
		got: s.n_got
		packets: s.packets
		t_ms: t_ms
		priority: s.priority
	}
}

// TpEvents is what one observed frame settled. Both lists are usually empty; a frame completes
// at most one message, and can abandon more than one only through a timeout sweep.
pub struct TpEvents {
pub:
	done    []TpMessage
	aborted []TpAbort
	// This frame WAS a readable frame of a session — the answer a caller marks its row with.
	//
	// Returned rather than asked again outside, because asking twice is how the two answers
	// drift: the callers gated `observe` on their own copy of the shape test, which meant the
	// frames the module exists to REFUSE never reached it and `Counts.malformed` could not
	// count them (codex, on the previous round's own fix). Callers now hand over anything whose
	// IDENTIFIER is a transport group (`is_tp`) and let this say what it was.
	part bool
}

// Reassembler follows every session on ONE wire. Sessions are keyed by the address pair, which
// is what J1939 scopes a transfer by -- one BAM per sender, one connection per sender/receiver
// pair -- so it holds no CAN-id state and nothing here is per-channel except the caller's
// choice of where to keep it. Not thread-safe by design: one reader per wire owns one of these
// (`docs/one_reader_per_wire.md`), the way the verifier map in `rx_loop` is owned.
pub struct Reassembler {
mut:
	sessions map[u64]Session
	// Counters, not events. A wire this tool joined mid-transfer delivers data packets for a
	// session whose announcement was never seen, and a bench that started the measurement
	// late would otherwise be told about it once per packet, forever.
	orphan_dt   int
	malformed   int
	refused     int
	tail_orphan bool // the last observe() saw an orphan packet: see orphan_seen()
}

// Counts is what the reassembler saw and did not turn into a message, since open, in the shape
// `transport.Bus.diagnostics()` answers: what is neither a frame nor a verdict still happened.
pub struct Counts {
pub:
	orphan_dt int // data packets for a session that was never announced here
	malformed int // a TP frame this could not read at all
	refused   int // announcements refused: impossible sizes, or too many sessions at once
	open      int // sessions being followed right now
}

pub fn (r &Reassembler) counts() Counts {
	return Counts{
		orphan_dt: r.orphan_dt
		malformed: r.malformed
		refused: r.refused
		open: r.sessions.len
	}
}

// orphan_seen reports whether the LAST observe met a data packet for a transfer it never saw
// announced. For a caller that wants to say so once — a measurement or a capture that began in
// the middle of a transfer is the ordinary reason, and saying it per packet would be a flood,
// which is why the count exists at all.
pub fn (r &Reassembler) orphan_seen() bool {
	return r.tail_orphan
}

// pending is how many sessions are open -- the one question a caller asks on its idle path
// before deciding whether `tick` has anything to do.
pub fn (r &Reassembler) pending() int {
	return r.sessions.len
}

// is_tp reports whether a frame is part of a transport session at all. This is the question
// asked of EVERY frame on the wire, so it is two comparisons over the id and nothing else --
// no struct, no allocation. Standard frames are never J1939.
pub fn is_tp(id u32, ext bool) bool {
	if !ext {
		return false
	}
	// The PAGE BITS are part of the group number, so 0x1EC00 and 0x1EB00 are different
	// parameter groups from 0xEC00 and 0xEB00 and carry no session of ours. Reading the format
	// byte alone let one be taken apart as an announcement (codex).
	if (id >> 24) & 0x3 != 0 {
		return false
	}
	pf := (id >> 16) & 0xFF
	return pf == 0xEC || pf == 0xEB
}

// tp_frame is whether a FRAME is part of a transport session: the identifier, and the shape
// J1939-21 gives every frame of one.
//
// A session is CLASSIC CAN, eight bytes, always — the protocol exists BECAUSE a classic frame
// carries eight, and it pads with 0xFF rather than shortening. So a CAN-FD frame at a transport
// identifier is not a session frame however plausible its bytes look, and neither is a remote
// frame, which asks for a payload and carries none (a backend that hands back a buffer of the
// requested length anyway delivered one as sequence 0, which tore down a live transfer). Both
// came from review a round apart, which is why the shape is ONE predicate: the live reader, the
// importer and the reassembler all ask it, and they must not answer differently.
pub fn tp_frame(id u32, ext bool, rtr bool, fd bool, len int) bool {
	return is_tp(id, ext) && !rtr && !fd && len == 8
}

fn key_of(sa u8, da u8) u64 {
	return (u64(sa) << 8) | u64(da)
}

// le16 and le24 read the little-endian fields of a control message. J1939 is little-endian on
// the wire for these, which is the opposite of how the same bytes would be read in a big-endian
// signal, so they are spelled out once here rather than inline three times.
fn le16(b []u8, at int) int {
	return int(u32(b[at]) | (u32(b[at + 1]) << 8))
}

fn le24(b []u8, at int) u32 {
	return u32(b[at]) | (u32(b[at + 1]) << 8) | (u32(b[at + 2]) << 16)
}

// abort_reason names the codes J1939-21 defines for a Connection Abort. An unnamed code is
// reported as its number rather than as "unknown": the number is what the sender said.
pub fn abort_reason(code u8) string {
	return match code {
		1 { 'already in a connection-managed session' }
		2 { 'system resources needed for another task' }
		3 { 'a timeout occurred' }
		4 { 'CTS while data transfer in progress' }
		5 { 'retransmit request limit reached' }
		6 { 'unexpected data transfer packet' }
		7 { 'bad sequence number' }
		8 { 'duplicate sequence number' }
		9 { 'total message size too big' }
		250 { 'no reason given' }
		else { 'reason ${code}' }
	}
}

// canonical_pgn reports whether a value is a parameter group number AS J1939 ENCODES ONE, which
// is narrower than "three bytes" in two ways.
//
// ONE predicate rather than a check per round: two consecutive reviews found the same class in
// different halves of it -- a value past the 18-bit field, then a PDU1 value whose destination
// byte was not zero -- and both mattered for the same reason. The announcement's three bytes are
// carried into the session, but `id_for` builds the rebuilt row's identifier by the encoding
// rules, so any bit the encoding does not keep is a bit on which the row DISPLAYS and DECODES a
// different group from the one announced. Refusing here is refusing to rebuild a message whose
// name this tool would then get wrong.
pub fn canonical_pgn(pgn u32) bool {
	if pgn > 0x3FFFF {
		return false // the field is 18 bits: two page bits, the format byte, one more byte
	}
	// PDU1 (format byte below 0xF0) spends that last byte on the DESTINATION in an identifier,
	// so it is not part of the group, and a group number carrying one is not canonical.
	return (pgn >> 8) & 0xFF >= 0xF0 || pgn & 0xFF == 0
}

// announcement_refusal is why an announcement does not describe a transport message, or '' when
// it does: a size that would not need a session at all (8 bytes or fewer would simply have been
// sent), one past what 255 packets carry, or a packet count that does not follow from the size.
//
// One rule, because it is asked twice for different purposes: the reassembler refuses a session
// with it, and `announces_session` treats passing it as EVIDENCE that a recording is J1939. A
// looser evidence test than the acceptance test would claim a bus this cannot then read.
pub fn announcement_refusal(ctrl u8, da u8, reserved u8, pgn u32, size int, packets int) string {
	// Byte 4 is RESERVED IN A BAM and J1939-21 fixes it at 0xFF, so a frame that puts something
	// else there is not a broadcast announcement — and taking it for one both classified a
	// recording as J1939 and opened a session that could go on to produce a rebuilt message
	// (codex). In an RTS the same byte is a real field (how many packets the sender may send
	// in answer to one CTS), which a passive observer does not act on, so it is not checked;
	// applying the rule to both is what this file's own test caught.
	if ctrl == cm_bam && reserved != 0xFF {
		return 'reserved byte 0x${reserved:02X} where a broadcast announcement has 0xFF'
	}
	if !canonical_pgn(pgn) {
		return 'announced group number 0x${pgn:06X}, which is not one a parameter group has'
	}
	// The MODE and the destination are one statement, not two: a BAM is announced to everybody
	// and an RTS opens a connection to one node, so an addressed BAM or a global RTS is a frame
	// no J1939 stack produces. Left out, an addressed BAM was proof enough to read a whole
	// recording as J1939 and to complete a session that cannot exist (codex).
	if ctrl == cm_bam && da != addr_global {
		return 'a broadcast announcement addressed to ${addr_str(da)}'
	}
	if ctrl == cm_rts && da == addr_global {
		return 'a connection announcement addressed to everybody'
	}
	if size < tp_min_size {
		return 'announced ${size} bytes, which is not a transport message'
	}
	if size > tp_max_size {
		return 'announced ${size} bytes, past the ${tp_max_size} a session can carry'
	}
	if packets != (size + tp_bytes_per_packet - 1) / tp_bytes_per_packet {
		return 'announced ${size} bytes in ${packets} packets, which do not agree'
	}
	return ''
}

// announces_session reports whether this frame is a WELL-FORMED transport announcement — a BAM
// or an RTS whose size and packet count agree.
//
// It exists so a RECORDING can answer for itself. A live wire has an owner to ask, and is asked
// (`project.Channel.j1939`); a file somebody sends you has nobody, so the honest question is
// whether the bytes in it prove what they are. This is proof and not a guess: a control byte of
// 0x20 or 0x10 on PGN 0xEC00, carrying a byte count and a packet count that agree, is not
// something a bus that is not J1939 produces by accident. A J1939 recording with no multi-packet
// transfer in it is not recognised, which is a missing reading and never a wrong one.
pub fn announces_session(id u32, ext bool, rtr bool, fd bool, data []u8) bool {
	if !tp_frame(id, ext, rtr, fd, data.len) {
		return false
	}
	iid := decode_id(id)
	if iid.pf != 0xEC {
		return false
	}
	if data[0] != cm_bam && data[0] != cm_rts {
		return false
	}
	return announcement_refusal(data[0], iid.ps, data[4], le24(data, 5), le16(data, 1), int(data[3])) == ''
}

// observe feeds one received frame and returns whatever it settled. A frame that is not part of
// a session settles nothing and costs one `is_tp` call.
pub fn (mut r Reassembler) observe(id u32, ext bool, rtr bool, fd bool, data []u8, t_ms f64) TpEvents {
	r.tail_orphan = false
	if !is_tp(id, ext) {
		return TpEvents{}
	}
	// A sweep on every transport frame, not only on the idle path: a session abandoned while
	// the wire stays busy is abandoned just the same, and this is the moment we are here.
	//
	// BEFORE the two refusals below, not after. A stream of frames this cannot read is still a
	// stream of transport frames, and skipping the sweep on them held an already-expired
	// session open for as long as they kept coming — reported at EOF as merely unfinished
	// (codex).
	mut aborted := r.expire(t_ms)
	// The SHAPE, by the one predicate the callers use (`tp_frame`): classic, not remote, eight
	// bytes. A frame at a transport identifier that is none of those is COUNTED rather than
	// read, because reading it would mean guessing which field was cut off, or which bytes of
	// an FD payload were the protocol's.
	if !tp_frame(id, ext, rtr, fd, data.len) {
		r.malformed++
		return TpEvents{
			aborted: aborted
		}
	}
	part := true
	mut done := []TpMessage{}
	iid := decode_id(id)
	if iid.pf == 0xEC {
		r.control(iid, data, t_ms, mut aborted)
	} else {
		r.packet(iid, data, t_ms, mut done, mut aborted)
	}
	return TpEvents{
		done: done
		aborted: aborted
		part: part
	}
}

// tick abandons sessions that have gone quiet, for a caller whose wire has stopped carrying
// transport frames entirely. `pending()` first: an empty reassembler has nothing to sweep.
pub fn (mut r Reassembler) tick(now_ms f64) []TpAbort {
	return r.expire(now_ms)
}

// close abandons every open session -- the end of a measurement, where a transfer still in
// flight is neither complete nor timed out, and saying nothing about it would leave the trace
// claiming the wire simply went quiet.
pub fn (mut r Reassembler) close(now_ms f64) []TpAbort {
	mut out := []TpAbort{}
	for _, s in r.sessions {
		out << s.abort('the measurement ended with the transfer unfinished', now_ms)
	}
	r.sessions.clear()
	return out
}

fn (mut r Reassembler) expire(now_ms f64) []TpAbort {
	if r.sessions.len == 0 {
		return []
	}
	mut dead := []u64{}
	for k, s in r.sessions {
		if now_ms >= s.deadline {
			dead << k
		}
	}
	if dead.len == 0 {
		return []
	}
	mut out := []TpAbort{cap: dead.len}
	for k in dead {
		s := r.sessions[k]
		gap := if s.kind == .bam { bam_gap_ms } else { cm_gap_ms }
		out << s.abort('no packet for ${int(gap)} ms', now_ms)
		r.sessions.delete(k)
	}
	return out
}

// session_named is WHICH OPEN TRANSFER A CONTROL FRAME REFERS TO: among the address pairs its
// own direction makes candidates, the one carrying the parameter group it names.
//
// ONE lookup, because three consecutive reviews found the same defect in the three control
// frames one at a time -- the abort, then the acknowledgement, then the clear-to-send -- and
// each was the same sentence: matched by address alone, a stale or malformed frame reached
// whatever transfer happened to be open between those two nodes. A node may be sending one
// transfer and receiving another to the same peer, and a delayed frame from a transfer that has
// finished looks exactly like a current one until its PGN is read. Every control frame's bytes
// are parsed already; this is only the rule that they must be used.
fn (r &Reassembler) session_named(pgn u32, keys []u64) ?u64 {
	for k in keys {
		if s := r.sessions[k] {
			if s.pgn == pgn {
				return k
			}
		}
	}
	return none
}

// any_session is the same question with the PGN ignored -- for the ONE frame that ends a
// transfer it cannot name (see the abort), and nowhere else.
fn (r &Reassembler) any_session(keys []u64) ?u64 {
	for k in keys {
		if _ := r.sessions[k] {
			return k
		}
	}
	return none
}

// control handles TP.CM, which never COMPLETES a message -- only the last data packet does --
// so it settles abandonments alone: an announcement replacing an unfinished session, an
// EndOfMsgAck for one this side did not finish, an abort from either end.
fn (mut r Reassembler) control(iid Id, data []u8, t_ms f64, mut aborted []TpAbort) {
	ctrl := data[0]
	pgn := le24(data, 5)
	if ctrl == cm_bam || ctrl == cm_rts {
		size := le16(data, 1)
		packets := int(data[3])
		kind := if ctrl == cm_bam { TpKind.bam } else { TpKind.cm }
		k := key_of(iid.sa, iid.ps)
		// The announcement is where a session is refused, since everything after it is read
		// against these numbers. One rule (`announcement_refusal`), so what this accepts and
		// what `announces_session` calls evidence of a J1939 bus cannot drift apart.
		mut why := announcement_refusal(ctrl, iid.ps, data[4], pgn, size, packets)
		if why == '' && r.sessions.len >= max_sessions && k !in r.sessions {
			why = '${max_sessions} sessions already open on this wire'
		}
		if why != '' {
			r.refused++
			// The transfer this announcement was REPLACING is over either way. The sender has
			// moved on — that is what a second announcement between one pair means — and
			// leaving the old session open applied the rejected transfer's data packets to it,
			// which fabricated a message under the OLD group number with the NEW payload
			// (codex). A refusal refuses the new session; it does not preserve the old one.
			if old := r.sessions[k] {
				r.sessions.delete(k)
				aborted << old.abort('replaced by an announcement that could not be read: ${why}', t_ms)
			}
			aborted << TpAbort{
				priority: iid.priority
				pgn: pgn
				sa: iid.sa
				da: iid.ps
				kind: kind
				reason: why
				got: 0
				packets: packets
				t_ms: t_ms
			}
			return
		}
		// An announcement while one is open from the same sender to the same destination
		// replaces it: J1939 allows one at a time, so the old one is over, whatever this side
		// saw of it.
		if old := r.sessions[k] {
			aborted << old.abort('replaced by a new announcement from the same sender', t_ms)
		}
		r.sessions[k] = Session{
			priority: iid.priority
			pgn: pgn
			sa: iid.sa
			da: iid.ps
			kind: kind
			size: size
			packets: packets
			started: t_ms
			data: []u8{len: size}
			got: []bool{len: packets}
			last_ms: t_ms
			deadline: t_ms + if kind == .bam { bam_gap_ms } else { cm_gap_ms }
		}
		return
	}
	if ctrl == cm_cts {
		// Sent BY the receiver, so the session it names is the other way round from this
		// frame's own addresses. Read only to keep the session alive: packets are placed by
		// their sequence numbers, so which one the receiver asks for next changes nothing
		// about where they land.
		k := r.session_named(pgn, [key_of(iid.ps, iid.sa)]) or { return }
		mut s := r.sessions[k]
		s.last_ms = t_ms
		s.deadline = t_ms + cm_gap_ms
		r.sessions[k] = s
		return
	}
	if ctrl == cm_eoma {
		// Also from the receiver, and it means the transfer SUCCEEDED. So if this side is still
		// missing packets, the gap is in what this tool captured rather than on the bus, and
		// that is the useful thing to say.
		// It names the transfer by SIZE AND PACKET COUNT as well, and both are checked: a
		// delayed acknowledgement of an earlier transfer between the same two nodes, of the
		// same group, would otherwise close the one that is open and report its packets as
		// dropped here. The same class as the PGN match beside it, in the one control frame
		// that carries more than a PGN (codex).
		k := r.session_named(pgn, [key_of(iid.ps, iid.sa)]) or { return }
		s := r.sessions[k]
		if le16(data, 1) != s.size || int(data[3]) != s.packets {
			return
		}
		r.sessions.delete(k)
		aborted << s.abort('the receiver acknowledged the whole message; ${s.n_got} of ${s.packets} packets reached this tool', t_ms)
		return
	}
	if ctrl == cm_abort {
		// Either end may abort, so both directions are candidates and the PGN picks between
		// them. Unlike the two above, an abort naming no transfer this side is following still
		// ENDS the one it is addressed to: the peers have agreed the connection is over,
		// whatever this side made of the numbers.
		why := abort_reason(data[1])
		out := key_of(iid.sa, iid.ps)
		incoming := key_of(iid.ps, iid.sa)
		k := r.session_named(pgn, [out, incoming]) or {
			r.any_session([out, incoming]) or { return }
		}
		s := r.sessions[k]
		r.sessions.delete(k)
		aborted << s.abort('aborted by ${addr_str(iid.sa)}: ${why}', t_ms)
		return
	}
	// A control byte this does not know. Counted rather than guessed at: the remaining bytes
	// mean whatever that byte says they mean.
	r.malformed++
}

// packet handles TP.DT: one sequence byte and seven data bytes.
fn (mut r Reassembler) packet(iid Id, data []u8, t_ms f64, mut done []TpMessage, mut aborted []TpAbort) {
	k := key_of(iid.sa, iid.ps)
	mut s := r.sessions[k] or {
		// No announcement seen: the measurement started mid-transfer, or the announcement was
		// missed. Counted, not reported -- see the note on the counters.
		r.orphan_dt++
		r.tail_orphan = true
		return
	}
	seq := int(data[0])
	if seq < 1 || seq > s.packets {
		// Not recoverable: a sequence number outside the announced run means this side can no
		// longer say where any later packet belongs.
		r.sessions.delete(k)
		aborted << s.abort('packet ${seq} is outside the announced 1..${s.packets}', t_ms)
		return
	}
	// Placed by sequence rather than appended, which is what makes a retransmission (a CTS can
	// send the peer back to an earlier packet) land where it belongs instead of past the end.
	off := (seq - 1) * tp_bytes_per_packet
	n := if off + tp_bytes_per_packet > s.size { s.size - off } else { tp_bytes_per_packet }
	for i in 0 .. n {
		s.data[off + i] = data[1 + i]
	}
	if !s.got[seq - 1] {
		s.got[seq - 1] = true
		s.n_got++
	}
	s.last_ms = t_ms
	s.deadline = t_ms + if s.kind == .bam { bam_gap_ms } else { cm_gap_ms }
	if s.n_got == s.packets {
		r.sessions.delete(k)
		done << TpMessage{
			priority: s.priority
			pgn: s.pgn
			sa: s.sa
			da: s.da
			kind: s.kind
			packets: s.packets
			data: s.data
			t_ms: t_ms
		}
		return
	}
	r.sessions[k] = s
}

// addr_str spells an address the way the trace does: two hex digits, or the name for each of
// the two the standard reserves.
pub fn addr_str(a u8) string {
	return match a {
		addr_global { 'all' }
		addr_null { 'none' }
		else { '${a:02X}' }
	}
}
