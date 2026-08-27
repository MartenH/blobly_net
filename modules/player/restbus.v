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
	for m in db.messages {
		k := key(m.id, m.ext)
		senders_of[k] = m.senders()
		defined[k] = true
	}
	return Decider{
		senders_of:          senders_of.clone()
		defined:             defined.clone()
		excluded:            excluded.clone()
		replay_unattributed: replay_unattributed
	}
}

pub fn (d Decider) verdict(f transport.CanFrame) Verdict {
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
		return .drop_remote
	}
	k := key(f.id, f.extended)
	if k !in d.defined {
		return .keep_unknown
	}
	senders := d.senders_of[k] or { []string{} }
	if senders.len == 0 {
		return if d.replay_unattributed {
			Verdict.keep_unattributed
		} else {
			Verdict.drop_unattributed
		}
	}
	if senders.any(it in d.excluded) {
		return .drop_excluded
	}
	return .keep
}

// on_bus keeps only the entries recorded on one bus. Replay drives one channel from one
// recorded bus; a multi-bus file merged onto a single channel would collide ids that never
// shared a wire.
pub fn on_bus(entries []canlog.LogEntry, iface string) []canlog.LogEntry {
	return entries.filter(it.iface == iface)
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
	d := new_decider(db, exclude, replay_unattributed)
	mut kept := []canlog.LogEntry{cap: entries.len}
	mut acc := Tally{}
	for e in entries {
		if acc.add(d.verdict(e.frame), e.frame) {
			kept << e
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
	// KEYED BY IDENTITY, not by number — the same `key(id, ext)` the decision itself uses.
	unattr  map[u64]bool
	unknown map[u64]bool
}

// add records one verdict and reports whether the frame survives.
//
// TAKES THE FRAME, not just its number: an id means nothing without the width it was declared at,
// and the tallies below have to keep an 11-bit 0x100 apart from a 29-bit one exactly as `verdict`
// already does.
pub fn (mut t Tally) add(v Verdict, f transport.CanFrame) bool {
	id := key(f.id, f.extended)
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
		unattributed_ids:      u_ids
		unknown_ids:           k_ids
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
}

// census tallies one bus's entries — filter with on_bus first, for the reason on_bus states.
pub fn census(entries []canlog.LogEntry, db candb.Database) NodeCensus {
	d := new_decider(db, [], true)
	mut nodes := map[string]int{}
	mut unattributed := 0
	mut unknown := 0
	mut remote := 0
	for e in entries {
		// REMOTE FIRST, in the same order `verdict` uses, because this census is the PREVIEW of
		// what that will decide. Asking `defined` first put a remote frame on an undefined id into
		// `unknown` -- which the editor labels "replays regardless" -- while the replay drops every
		// remote frame before it looks at the database. The preview promised the opposite of what
		// Start does, and with no DBC attached, where `defined` is empty, it did so for every one
		// of them (codex on #216).
		if e.frame.rtr {
			remote++
			continue
		}
		k := key(e.frame.id, e.frame.extended)
		if k !in d.defined {
			unknown++
			continue
		}
		senders := d.senders_of[k] or { []string{} }
		if senders.len == 0 {
			unattributed++
			continue
		}
		for n in senders {
			nodes[n]++
		}
	}
	return NodeCensus{
		nodes:        nodes.clone()
		unattributed: unattributed
		unknown:      unknown
		remote:       remote
		total:        entries.len
	}
}
