// What a recording should NOT replay.
//
// A capture taken from a running vehicle contains the ECU under test alongside everything else.
// Playing it back verbatim puts two transmitters on every id that ECU owns: ours from the file,
// and the real one on the bench. The point of a replayed rest bus is the opposite — the SUT
// hears its actual environment and remains the only source of its own messages.
//
// The database is what makes the subtraction possible: `BO_` names a transmitter per message.
// It is not sufficient on its own, and this file is careful about the three ways it falls short.
//
//   * A message the DBC does not define at all. The recording is ground truth about what was on
//     the wire; the database is one team's description of it, and the two disagree in practice.
//   * A message the DBC defines with no transmitter (`Vector__XXX`, which candb normalises to
//     empty). Real: 8 of 13 databases in the recordings this was written for, up to 20 messages
//     on one bus.
//   * A node name that is not in the database at all — almost always a typo, and one that would
//     otherwise subtract NOTHING and look exactly like a working rest bus.
//   * A REMOTE FRAME, where the sender field answers a question nobody asked. `BO_` names who
//     PRODUCES a message; a remote frame with that id is a REQUEST FOR it, issued by somebody
//     else — very often the tester, and on a rest bus very often the thing the SUT is meant to
//     answer. Keyed on the id alone, a request for a message the excluded node produces was
//     subtracted on that node's account: the SUT never heard the stimulus, its reply was missing
//     from the run, and the one frame in the recording that certainly was NOT the SUT's own
//     traffic is the one we removed (#179).
//
// The first two are reported, never guessed at, and the caller decides. The third is an error,
// because there is no reading of "exclude a node that does not exist" that the user meant. The
// fourth follows the unattributed policy, because it is the same question — see `verdict`.
module player

import canlog
import candb
import j1939
import transport

// Subtraction is what a filter did, in enough detail to argue with. Every count is frames, not
// message definitions, because what reaches the bus is frames.
//
// The two withheld counts are kept APART. Summing them would report a rest bus as quieter on the
// SUT's account than it really is, and hide the cost of the unattributed policy behind a number
// the user reads as "the ECU under test" — the one figure they are most likely to sanity-check.
pub struct Subtraction {
pub:
	kept                  int // frames that will be replayed
	withheld_excluded     int // withheld because an excluded node sends them
	withheld_unattributed int // withheld because the DBC names no transmitter and policy says so
	unattributed          int // frames whose message the DBC defines but gives no transmitter
	unknown               int // frames whose id the DBC does not define at all
	remote                int // remote requests in the recording, which cannot be replayed
	// Of `kept`, how many are CAN-FD frames — the ones a channel PINNED to classic cannot replay.
	// Counted here, in the one walk that decides what is kept, so the front ends state the
	// number that will actually reach the send loop rather than one taken from the recording
	// before subtraction (#184); by the frame's flag, which is what the loaders set.
	fd int
	// The ids behind the two buckets above that have them, so a report can name those rather
	// than merely count them.
	// Sorted, each id once.
	//
	// FORMATTED, AND THE FORMAT CARRIES THE WIDTH: three hex digits for a standard id, eight for
	// an extended one, which is candump's convention and the one this repo already reads traces
	// with. Kept as bare numbers, an 11-bit 0x100 and a 29-bit 0x100 -- two different messages
	// with two different senders, which `key()` exists to keep apart -- collapsed into one entry,
	// so a report claimed one id where two were involved and printed something that could not say
	// which (codex round 2 on #210). The tallies below are keyed the same way.
	unattributed_ids []string
	unknown_ids      []string
	// J1939. A J1939 database defines one message per PGN with a placeholder source address in
	// the BO_ id, and a recorded frame carries the REAL source address in its low byte — so the
	// exact key misses for every frame of the bus, the sender lookup finds nothing, and the
	// SUT's own frames are replayed back at it (#171). `pgn_matched` counts the frames decided
	// through a PGN match instead, which the decider does ONLY for messages the database
	// DECLARED J1939 (`VFrameFormat`): a 29-bit id alone is not evidence, and on a bus using
	// 29-bit UDS ids (0x18DAxxyy) a request and its response share a PGN, so matching every
	// extended frame by PGN would subtract the tester's stimulus on the ECU's account — #179's
	// failure in another coat.
	pgn_matched int
	// Frames the database does NOT define whose PGN a message it defines does share, where that
	// PGN could not decide: a message on it is not declared J1939 (declared or not, another
	// message sharing the PGN cannot then decide for it), or several declared messages define
	// the PGN with DIFFERENT transmitters (two engines spelled out at two source addresses; a
	// third address is genuinely either). Not acted on, but said, because the
	// alternative is a rest bus that quietly replays the SUT's frames while the report reads
	// "not in the DBC" about ids that differ from the DBC's by one byte.
	pgn_hint     int
	pgn_hint_ids []string
	// Frames of J1939 multi-packet transfers — the TP.CM announcement and its TP.DT packets —
	// judged by the parameter group the announcement carries, since the frames' own PGNs (the
	// transport protocol's) say nothing about who sent them and the DBC does not attribute
	// them. An excluded node's 20-byte DM1 is three such frames, and keyed on their own ids
	// every one of them was replayed back at it (codex on #329). The receiver's side of a
	// connection (CTS, end-of-message ack, an abort from the receiver) is nobody the database
	// can name and stays unknown.
	tp_attributed int
}

// id_label formats one identifier the way a trace does, so its WIDTH is visible: three hex digits
// standard, eight extended. `0x100` and `0x00000100` are two different messages, and a report that
// prints them the same way is a report that cannot be acted on.
fn id_label(id u32, ext bool) string {
	return if ext { '0x${id:08X}' } else { '0x${id:03X}' }
}

// key identifies a message the way the bus does: an 11-bit 0x100 and a 29-bit 0x100 are two
// different messages that may have two different senders, and candb.lookup_frame exists because
// conflating them is silent corruption. Keying on the number alone let whichever definition was
// parsed last decide the sender for both — which either silences a bus or replays the SUT's own
// frames back at it, the exact failure this file exists to prevent.
fn key(id u32, ext bool) u64 {
	return (u64(id) << 1) | u64(if ext {
		1
	} else {
		0
	})
}

// Decider is the subtraction expressed as a per-frame question. `without_senders` filters a
// list; a caller that must preserve ORDER across several buses has to walk the recording once
// and ask about each frame in place, and both must use the same rule or the policy lives twice.
pub struct Decider {
	senders_of          map[u64][]string
	defined             map[u64]bool
	excluded            map[string]bool
	replay_unattributed bool
	// By PGN, for the extended messages the database DECLARED J1939 and that agree about who
	// sends the PGN — see Subtraction.pgn_matched. A PGN in here decides; one that is not is
	// either unknown to the database or in `pgn_hint`.
	pgn_senders map[u32][]string
	// The PGNs a miss can only HINT about: defined by an undeclared extended message, or by
	// several declared ones with different transmitters (see Subtraction.pgn_hint).
	pgn_hint map[u32]bool
}

// same_set says whether two transmitter lists name the same nodes, whatever their order.
fn same_set(a []string, b []string) bool {
	if a.len != b.len {
		return false
	}
	mut x := a.clone()
	mut y := b.clone()
	x.sort()
	y.sort()
	return x == y
}

// Walker is the subtraction applied to a recording IN ORDER: the Decider's stateless answer plus
// the one piece of state a J1939 recording needs — which transport-protocol transfers are in
// progress, so a TP.DT frame takes the decision its TP.CM announcement took. Every walk over a
// recording goes through one (subtract, the multi-bus plan, the census preview), or the preview
// and Start would drift apart on exactly these frames. The protocol itself — what announces a
// transfer, what refuses one, which packet ends it, whose an abort is — is `j1939.Transfers`,
// shared with the reassembler; a first cut wrote those rules here a second time and got three
// of them wrong in one review round (codex on #329).
pub struct Walker {
	d Decider
	// Whether the database declared J1939 at all. Without it the walker follows no transfers:
	// a proprietary 29-bit bus can carry ids whose PGN computes to the transport protocol's
	// with payloads that pass as announcements, and its later frames would then inherit a
	// decision made for a parameter group nobody declared — the rule that a 29-bit id alone is
	// not J1939, applied to the transport protocol too (codex on #329).
	j1939 bool
mut:
	tp       j1939.Transfers
	verdicts map[u16]Decision // the announcement's decision, by (originator, destination)
}

pub fn new_walker(db candb.Database, exclude []string, replay_unattributed bool) Walker {
	return Walker{
		d:     new_decider(db, exclude, replay_unattributed)
		j1939: db.j1939_declared()
	}
}

fn tkey(sa u8, da u8) u16 {
	return (u16(sa) << 8) | u16(da)
}

// decide is Decider.decide with the transfers followed, at `t_s` on the recording's clock (the
// transfers expire on it). Standard frames, remote frames and everything that is not TP go
// straight through.
pub fn (mut w Walker) decide(f transport.CanFrame, t_s f64) Decision {
	if !w.j1939 {
		return w.d.decide(f)
	}
	st := w.tp.step_at(f, t_s)
	match st.role {
		.announce {
			// The announcement is judged by the parameter group it announces — through the
			// declared-PGN index, the only thing it carries about the message (decide_pgn).
			base := w.d.decide_pgn(st.pgn)
			dec := Decision{
				...base
				tp:      true
				hint_id: if base.pgn_hint {
					?u32(j1939.compose(st.priority, st.pgn, st.da, st.sa))
				} else {
					none
				}
			}
			w.verdicts[tkey(st.sa, st.da)] = dec
			return dec
		}
		.packet, .sender_abort {
			k := tkey(st.sa, st.da)
			dec := w.verdicts[k] or { w.d.decide(f) }
			if st.done {
				w.verdicts.delete(k)
			}
			return dec
		}
		.receiver, .stray {
			// The receiver's frames are nobody the database can name, and a TP frame no
			// announcement accounts for is attributable through nothing — see
			// Subtraction.tp_attributed. UNKNOWN by construction, not through the decider: a
			// database that happens to define TP.CM as a message would otherwise PGN-match a
			// CTS to that definition's transmitter and withhold the receiver's own frame on the
			// excluded node's account (codex on #329). A transfer this frame ended forgets its
			// decision.
			if st.done {
				w.verdicts.delete(tkey(st.sa, st.da))
			}
			return Decision{
				verdict: .keep_unknown
			}
		}
		.not_tp {
			return w.d.decide(f)
		}
	}
}

// Decision is a verdict and how it was reached, for the report and the census: `senders` is who
// the frame was attributed to (empty for an unknown or unattributed one); `by_pgn` says the
// exact id was not in the database and a DECLARED J1939 message with its PGN decided it;
// `pgn_hint` says the frame is unknown but shares a PGN the database defines without being able
// to decide by it.
pub struct Decision {
pub:
	verdict  Verdict
	senders  []string
	by_pgn   bool
	pgn_hint bool
	// The frame is part of a transport-protocol transfer and took its announcement's decision.
	tp bool
	// For a hint on a transfer's frames: the identity the hint is ABOUT — the application id the
	// announcement stands for — where the frame's own id is the transport protocol's and says
	// nothing about which PGN wants declaring (codex on #329). None for an ordinary frame.
	hint_id ?u32
}

// Verdict says what happened to one frame, so a caller can count without re-deriving the reason.
pub enum Verdict {
	keep              // a node we are not excluding sends it
	keep_unknown      // its id is not in the database at all — replayed, and reported
	keep_unattributed // defined, no transmitter, policy says replay
	drop_excluded     // an excluded node sends it
	drop_unattributed // defined, no transmitter, policy says withhold
	drop_remote       // a remote request, which this app cannot transmit at all
}

pub fn new_decider(db candb.Database, exclude []string, replay_unattributed bool) Decider {
	mut excluded := map[string]bool{}
	for name in exclude {
		excluded[name] = true
	}
	mut senders_of := map[u64][]string{}
	mut defined := map[u64]bool{}
	mut pgn_senders := map[u32][]string{}
	mut pgn_ambiguous := map[u32]bool{}
	mut pgn_hint := map[u32]bool{}
	for m in db.messages {
		k := key(m.id, m.ext)
		senders_of[k] = m.senders()
		defined[k] = true
		if !m.ext {
			continue
		}
		pgn := j1939.pgn(m.id)
		if !m.j1939 {
			// The file did not say this message is J1939, so a frame that differs from it in the
			// low byte is not "the same parameter group from another address" — and a DECLARED
			// message on the same PGN may not decide for it either: the frame is equally this
			// one's neighbour, and attributing it to the declared sender would withhold it on the
			// SUT's account on a guess (codex on #329). The PGN is undecidable either way.
			pgn_hint[pgn] = true
			pgn_ambiguous[pgn] = true
			pgn_senders.delete(pgn)
			continue
		}
		if pgn in pgn_ambiguous {
			continue
		}
		if prev := pgn_senders[pgn] {
			// Two BO_ entries for one PGN — two source addresses spelled out — are one parameter
			// group when they agree about who sends it (as a SET: `BO_` names one transmitter
			// first and `BO_TX_BU_` the rest, and two spellings of one pair are one pair). When
			// they do NOT (two engines, each its own node), a frame from a third address is
			// either's, and picking the first would subtract or replay the SUT's frames on a
			// coin toss: the PGN hints and decides nothing.
			if !same_set(prev, m.senders()) {
				pgn_senders.delete(pgn)
				pgn_ambiguous[pgn] = true
				pgn_hint[pgn] = true
			}
			continue
		}
		pgn_senders[pgn] = m.senders()
	}
	return Decider{
		senders_of:          senders_of.clone()
		defined:             defined.clone()
		excluded:            excluded.clone()
		replay_unattributed: replay_unattributed
		pgn_senders:         pgn_senders.clone()
		pgn_hint:            pgn_hint.clone()
	}
}

// Kept for the callers that ask only the verdict — the tests among them; the front ends and the
// census read `decide`, which carries the provenance the report and the preview need.
pub fn (d Decider) verdict(f transport.CanFrame) Verdict {
	return d.decide(f).verdict
}

// decide is verdict with the report's questions answered beside it.
pub fn (d Decider) decide(f transport.CanFrame) Decision {
	// FIRST, BEFORE THE DATABASE IS CONSULTED. Whether the DBC defines the id has no bearing on
	// this: the frame cannot be transmitted either way, so anything that returns `keep_` for it
	// hands the replay a frame that `send()` will refuse. Placed after the `defined` lookup it
	// caught only the ids a database happened to name — and with no DBC attached, `defined` is
	// EMPTY, so every remote frame in the recording took the unknown branch, was kept, and failed
	// at the wire (self-review). A run would report "not replayed" and then count failures for
	// the same frames.
	//
	// A REMOTE FRAME IS NEVER REPLAYED, because this app does not transmit one at all — see
	// frame_rules.v. Left to the branches below it would be judged by the PRODUCER's name, which
	// is the wrong question about a request: `BO_` says who produces a message, and the frame
	// asking for it came from somebody else. A request for a message the excluded node produces
	// would then be withheld on that node's account, into the `withheld_excluded` figure a user
	// reads as "the ECU under test" (#179).
	//
	// So it gets its own verdict and its own count — not a policy, just a fact about what this
	// app can put on a wire.
	if f.rtr {
		return Decision{
			verdict: .drop_remote
		}
	}
	k := key(f.id, f.extended)
	mut senders := []string{}
	mut by_pgn := false
	if k in d.defined {
		senders = d.senders_of[k] or { []string{} }
	} else {
		if !f.extended {
			return Decision{
				verdict: .keep_unknown
			}
		}
		// A 29-bit id the database does not spell out: a DECLARED J1939 message with its PGN
		// decides for it, because the difference is the source address the DBC could not
		// know. Undeclared, or defined by declared messages that disagree about the sender, the
		// miss stays a miss and the PGN coincidence is reported.
		pgn := j1939.pgn(f.id)
		senders = d.pgn_senders[pgn] or {
			return Decision{
				verdict:  .keep_unknown
				pgn_hint: pgn in d.pgn_hint
			}
		}
		by_pgn = true
	}
	return d.judged(senders, by_pgn)
}

// decide_pgn decides a parameter group announced by a transport-protocol frame: through the
// DECLARED-PGN index only, never an exact id. The announcement carries the PGN and nothing else
// of the application message — the priority and destination it would have carried are the
// announcement's — so an id composed from them can only accidentally equal a defined `BO_`, and
// an undeclared one at that id would then decide for the whole transfer past every declaration
// safeguard (codex on #329).
pub fn (d Decider) decide_pgn(pgn u32) Decision {
	senders := d.pgn_senders[pgn] or {
		return Decision{
			verdict:  .keep_unknown
			pgn_hint: pgn in d.pgn_hint
		}
	}
	return d.judged(senders, true)
}

// judged is the verdict once the transmitters are known: nobody named, an excluded node, or
// somebody else. The one tail for the exact-id path, the PGN path and an announcement.
fn (d Decider) judged(senders []string, by_pgn bool) Decision {
	if senders.len == 0 {
		return Decision{
			verdict: if d.replay_unattributed {
				Verdict.keep_unattributed
			} else {
				Verdict.drop_unattributed
			}
			by_pgn:  by_pgn
		}
	}
	if senders.any(it in d.excluded) {
		return Decision{
			verdict: .drop_excluded
			senders: senders
			by_pgn:  by_pgn
		}
	}
	return Decision{
		verdict: .keep
		senders: senders
		by_pgn:  by_pgn
	}
}

// on_bus keeps only the entries recorded on one bus. Replay drives one channel from one
// recorded bus; a multi-bus file merged onto a single channel would collide ids that never
// shared a wire.
pub fn on_bus(entries []canlog.LogEntry, iface string) []canlog.LogEntry {
	return entries.filter(it.iface == iface)
}

// sel_on_bus is on_bus over the arena: the rows recorded on one bus, in recorded order.
pub fn sel_on_bus(log &canlog.Log, iface string) []u32 {
	mut sel := []u32{}
	bus := log.index_of(iface) or { return sel }
	// By index, reading one u16 per row: `for r in log.rows` copies eighty bytes a row.
	for i in 0 .. log.rows.len {
		if int(log.rows[i].bus) == bus {
			sel << u32(i)
		}
	}
	return sel
}

// without_senders removes every frame whose message the database attributes to one of `exclude`.
//
// `replay_unattributed` decides the messages the database defines but does not attribute. There
// is no safe default and this file will not invent one: replaying them risks colliding with the
// SUT on ids it may well own, and withholding them silences traffic the SUT may be waiting for.
// The caller states which failure it prefers, and the report says how much rode on the choice.
//
// Frames whose id is absent from the database are ALWAYS replayed. Absence is not evidence: the
// recording proves the frame was on the wire, and dropping everything the database omits would
// silently gut a rest bus wherever the database is incomplete — which is the common case.
pub fn without_senders(entries []canlog.LogEntry, db candb.Database, exclude []string, replay_unattributed bool) ([]canlog.LogEntry, Subtraction) {
	log := canlog.from_entries(entries)
	kept, rep := subtract(&log, log.all(), db, exclude, replay_unattributed)
	return log.entries_of(kept), rep
}

// subtract is without_senders over the arena: which of `sel` survive, and the report. The
// ONE body — without_senders is this over a Log built from its entries.
pub fn subtract(log &canlog.Log, sel []u32, db candb.Database, exclude []string, replay_unattributed bool) ([]u32, Subtraction) {
	mut w := new_walker(db, exclude, replay_unattributed)
	mut kept := []u32{cap: sel.len}
	mut acc := Tally{}
	for i in sel {
		f := log.frame(int(i))
		if acc.add_decision(w.decide(f, log.t_s(int(i))), f) {
			kept << i
		}
	}
	return kept, acc.done(kept.len)
}

// Tally accumulates verdicts into a Subtraction. Shared by the single-bus filter and the
// multi-bus walk so their reports cannot drift apart.
pub struct Tally {
mut:
	withheld_excluded int
	withheld_unattr   int
	unattr_n          int
	unknown_n         int
	remote_n          int
	fd_n              int // CAN-FD frames among the kept
	// KEYED BY IDENTITY, not by number — the same `key(id, ext)` the decision itself uses.
	unattr  map[u64]bool
	unknown map[u64]bool
	// J1939 — see Subtraction.
	pgn_matched int
	pgn_hint_n  int
	pgn_hint    map[u64]bool
	tp_n        int
}

// add records one verdict and reports whether the frame survives.
//
// TAKES THE FRAME, not just its number: an id means nothing without the width it was declared at,
// and the tallies below have to keep an 11-bit 0x100 apart from a 29-bit one exactly as `verdict`
// already does.
// Kept beside add_decision for callers that hold only a verdict (the tests); the subtraction
// itself books decisions.
pub fn (mut t Tally) add(v Verdict, f transport.CanFrame) bool {
	return t.add_decision(Decision{ verdict: v }, f)
}

// add_decision is add with the decision's provenance booked too.
pub fn (mut t Tally) add_decision(dec Decision, f transport.CanFrame) bool {
	id := key(f.id, f.extended)
	keep := t.file(dec.verdict, id)
	if keep && f.fd {
		t.fd_n++
	}
	if dec.by_pgn {
		t.pgn_matched++
	}
	if dec.pgn_hint {
		t.pgn_hint_n++
		// filed under what the hint is about: a transfer's frames carry the transport
		// protocol's ids, and the PGN that wants declaring is the announced one

		t.pgn_hint[if h := dec.hint_id {
			key(h, true)
		} else {
			id
		}] = true
	}
	if dec.tp {
		t.tp_n++
	}
	return keep
}

// file books the verdict's bucket and says whether the frame survives; add counts the frame's
// own facts (its format) over the ones that do.
fn (mut t Tally) file(v Verdict, id u64) bool {
	match v {
		.keep {
			return true
		}
		.keep_unknown {
			t.unknown[id] = true
			t.unknown_n++
			return true
		}
		.keep_unattributed {
			t.unattr[id] = true
			t.unattr_n++
			return true
		}
		.drop_unattributed {
			t.unattr[id] = true
			t.unattr_n++
			t.withheld_unattr++
			return false
		}
		.drop_remote {
			t.remote_n++
			return false
		}
		.drop_excluded {
			t.withheld_excluded++
			return false
		}
	}
}

pub fn (t Tally) done(kept int) Subtraction {
	u_ids := labels_of(t.unattr)
	k_ids := labels_of(t.unknown)
	return Subtraction{
		kept:                  kept
		withheld_excluded:     t.withheld_excluded
		withheld_unattributed: t.withheld_unattr
		unattributed:          t.unattr_n
		unknown:               t.unknown_n
		remote:                t.remote_n
		fd:                    t.fd_n
		unattributed_ids:      u_ids
		unknown_ids:           k_ids
		pgn_matched:           t.pgn_matched
		pgn_hint:              t.pgn_hint_n
		pgn_hint_ids:          labels_of(t.pgn_hint)
		tp_attributed:         t.tp_n
	}
}

// labels_of turns a set of message identities into sorted, width-bearing labels. Sorted by the
// KEY rather than by the text, so 0x090 comes before 0x100 instead of after it.
fn labels_of(set map[u64]bool) []string {
	mut ks := set.keys()
	ks.sort()
	mut out := []string{cap: ks.len}
	for k in ks {
		out << id_label(u32(k >> 1), k & 1 == 1)
	}
	return out
}

// check_nodes reports the names in `exclude` that the database does not declare. A misspelled
// node subtracts nothing at all, and the result — a rest bus replaying the SUT's own messages
// back at it — looks like a working setup until the SUT starts losing arbitration against a
// recording of itself. Callers should refuse to run rather than continue.
pub fn check_nodes(db candb.Database, exclude []string) []string {
	mut known := map[string]bool{}
	for n in db.nodes {
		known[n] = true
	}
	// A database can transmit from a node it never declared in BU_, so senders count as known —
	// EVERY sender, including BO_TX_BU_ additions. without_senders honours those, so rejecting a
	// node declared only there would refuse the one exclusion that matters most.
	for m in db.messages {
		for n in m.senders() {
			known[n] = true
		}
	}
	return exclude.filter(it !in known)
}

// unknown_everywhere reports the excluded names that NOT ONE of the mapped databases declares.
//
// Absence from a SINGLE database means nothing: the ECU under test need not transmit on every
// bus it sits on, and vendor databases legitimately declare different node sets — a gateway
// recording maps several buses and the SUT will be missing from most of them. Absence from ALL
// of them is the typo worth refusing, because it subtracts nothing anywhere and leaves the bench
// replaying the SUT's own messages back at it while looking healthy.
//
// This is the rule, and it lives here because both front ends have to reach the same verdict on
// the same configuration. They did not: the CLI judged across every mapping while the GUI
// judged one channel at a time, so a perfectly good multi-bus replay ran headless and was
// refused in the GUI.
pub fn unknown_everywhere(dbs []candb.Database, exclude []string) []string {
	if dbs.len == 0 {
		return []
	}
	mut out := []string{}
	mut judged := map[string]bool{}
	for n in exclude {
		if n in judged {
			continue // `--exclude SUT,SUT` must not be reported, or counted, twice
		}
		judged[n] = true
		mut declared := false
		for db in dbs {
			if check_nodes(db, [n]).len == 0 {
				declared = true
				break
			}
		}
		if !declared {
			out << n
		}
	}
	return out
}

// NodeCensus is who actually talks in a recording, by DBC attribution: the per-node frame
// counts a user needs to SEE before choosing what to exclude — on a captured vehicle bus the
// busiest node is usually the ECU now sitting on the bench. The tally applies the same
// attribution verdict() does, so the preview shows exactly what the subtraction will act on;
// a separate walk with its own lookup would let the two drift.
pub struct NodeCensus {
pub:
	// frames per transmitting node. A frame with several declared senders counts once for
	// EACH: exclusion is per node, so that is the number an exclusion of that node acts on.
	nodes        map[string]int
	unattributed int // defined by the database, but it names no transmitter
	unknown      int // ids the database does not define at all
	remote       int // remote REQUESTS — asking for an id, so no node here transmitted them
	total        int
	// J1939, as Subtraction counts them: frames attributed through a DECLARED message's PGN
	// (they are in `nodes` under its transmitters), and unknown frames whose PGN a defined
	// message shares without deciding — the preview says both, since it is the preview of the
	// subtraction and those are the frames #171 is about.
	pgn_matched int
	pgn_hint    int
	// Frames of multi-packet transfers judged by their announcement (Subtraction.tp_attributed).
	tp_attributed int
}

// census tallies one bus's entries — filter with on_bus first, for the reason on_bus states.
pub fn census(entries []canlog.LogEntry, db candb.Database) NodeCensus {
	log := canlog.from_entries(entries)
	return census_sel(&log, log.all(), db)
}

// census_sel is census over the arena — the ONE body; census is this over a Log built from
// its entries.
pub fn census_sel(log &canlog.Log, sel []u32, db candb.Database) NodeCensus {
	mut w := new_walker(db, [], true)
	mut nodes := map[string]int{}
	mut unattributed := 0
	mut unknown := 0
	mut remote := 0
	mut pgn_matched := 0
	mut pgn_hint := 0
	mut tp_n := 0
	for si in sel {
		f := log.frame(int(si))
		// THROUGH THE DECIDER, because this census is the PREVIEW of what the subtraction will
		// decide, and the two had drifted twice: asking `defined` before RTR put a remote frame on
		// an undefined id into `unknown` -- which the editor labels "replays regardless" -- while
		// the replay drops every remote frame before it looks at the database (codex on #216);
		// and asking the exact key alone, after the decider learned to match a declared J1939
		// message by PGN, told the operator there was nothing to exclude on the very bus where
		// Start would have subtracted by PGN (self-review of #171). One body, no third drift.
		dec := w.decide(f, log.t_s(int(si)))
		if dec.by_pgn {
			pgn_matched++
		}
		if dec.pgn_hint {
			pgn_hint++
		}
		if dec.tp {
			tp_n++
		}
		match dec.verdict {
			.drop_remote {
				remote++
			}
			.keep_unknown {
				unknown++
			}
			.keep_unattributed, .drop_unattributed {
				unattributed++
			}
			.keep, .drop_excluded {
				for n in dec.senders {
					nodes[n]++
				}
			}
		}
	}
	return NodeCensus{
		nodes:         nodes.clone()
		unattributed:  unattributed
		unknown:       unknown
		remote:        remote
		total:         sel.len
		pgn_matched:   pgn_matched
		pgn_hint:      pgn_hint
		tp_attributed: tp_n
	}
}
