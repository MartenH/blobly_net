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
//
// The first two are reported, never guessed at, and the caller decides. The third is an error,
// because there is no reading of "exclude a node that does not exist" that the user meant.
module player

import canlog
import candb

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
	// The ids behind the last two, so a report can name them rather than merely count them.
	// Sorted, each id once.
	unattributed_ids []u32
	unknown_ids      []u32
}

// key identifies a message the way the bus does: an 11-bit 0x100 and a 29-bit 0x100 are two
// different messages that may have two different senders, and candb.lookup_frame exists because
// conflating them is silent corruption. Keying on the number alone let whichever definition was
// parsed last decide the sender for both — which either silences a bus or replays the SUT's own
// frames back at it, the exact failure this file exists to prevent.
fn key(id u32, ext bool) u64 {
	return (u64(id) << 1) | u64(if ext { 1 } else { 0 })
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
	mut excluded := map[string]bool{}
	for name in exclude {
		excluded[name] = true
	}
	// (id, kind) -> sender, once, rather than a linear scan of the database per frame. A capture
	// is hundreds of thousands of frames and a database is hundreds of messages; the product is
	// what made this worth a map.
	//
	// EXACT matches only — deliberately not candb.lookup_frame, whose J1939 PGN fallback would
	// attribute a frame to a definition whose source address differs. Here that would withhold
	// another ECU's traffic under the SUT's name, and silence is the failure this tool is least
	// able to notice. Ids the database does not define exactly are reported as unknown instead,
	// where a person can see them.
	mut sender_of := map[u64]string{}
	mut defined := map[u64]bool{}
	for m in db.messages {
		k := key(m.id, m.ext)
		sender_of[k] = m.sender
		defined[k] = true
	}
	mut kept := []canlog.LogEntry{cap: entries.len}
	mut withheld_excluded := 0
	mut withheld_unattr := 0
	mut unattr := map[u32]bool{}
	mut unknown := map[u32]bool{}
	mut unattr_n := 0
	mut unknown_n := 0
	for e in entries {
		id := e.frame.id
		k := key(id, e.frame.extended)
		if k !in defined {
			unknown[id] = true
			unknown_n++
			kept << e
			continue
		}
		sender := sender_of[k] or { '' }
		if sender == '' {
			unattr[id] = true
			unattr_n++
			if replay_unattributed {
				kept << e
			} else {
				withheld_unattr++
			}
			continue
		}
		if sender in excluded {
			withheld_excluded++
			continue
		}
		kept << e
	}
	mut u_ids := unattr.keys()
	u_ids.sort()
	mut k_ids := unknown.keys()
	k_ids.sort()
	return kept, Subtraction{
		kept:                  kept.len
		withheld_excluded:     withheld_excluded
		withheld_unattributed: withheld_unattr
		unattributed:          unattr_n
		unknown:               unknown_n
		unattributed_ids:      u_ids
		unknown_ids:           k_ids
	}
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
	// A database can transmit from a node it never declared in BU_, so senders count as known.
	for m in db.messages {
		if m.sender != '' {
			known[m.sender] = true
		}
	}
	return exclude.filter(it !in known)
}
