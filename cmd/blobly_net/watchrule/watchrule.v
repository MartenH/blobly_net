// WHICH ROWS A WATCHED SIGNAL IS MADE OF, AS A RULE.
//
// A plotted signal names a message, and "the same message" got narrower twice in one review:
// first `tp`, because one parameter group arrives both as a frame and as a transfer rejoined
// from frames, and a series matching on the identifier alone mixed two payload shapes into one
// line; then `wire`, because a rejoined message is looked up BY PGN and two wires may define
// one (PGN, SA) differently.
//
// Each time the field went into some of the places that ask the question and not others, and
// each time review found the rest one at a time — the comparisons, then the DBC editor's
// rewrites, then ImPlot's series id, then the series' own database lookup, then the plot
// window's x-axis, then the rewrite predicate. Six sites, one concept, three rounds. This is
// that concept, in one place with one test, which is what this repo does when repairs cluster
// (CLAUDE.md, "when findings repeat in one path, write the test").
//
// Then `wire` for EVERY watch (#330): two wires may carry one identifier with different data, or
// with different layouts in their own databases, and an unscoped frame watch interleaved both
// into one line and decoded them with whichever database was listed first.
module watchrule

// Ident is everything that makes two plotted signals DIFFERENT signals.
pub struct Ident {
pub:
	id  u32
	ext bool
	// A message rejoined from a transport session rather than a frame. One PGN can arrive both
	// ways from one node, and the two carry different payload shapes.
	tp bool
	// The wire it came off, for every kind (#330): its destination key live, the recorded bus
	// for an import (`TraceRow.wire`). The WIRE and not the row: two rows aliasing one wire
	// carry the same frames, which are filed under whichever row read or sent them, so a watch
	// keyed by row would split one wire's traffic by who put it there. Empty is UNBOUND — a
	// message picked from the database list rather than off a row — and covers nothing until
	// `bind` gives it one.
	wire string
	sig  string
	// The parameter group a REJOINED message carries, which its identifier does not settle: the
	// id is composed from the group, the sender and a priority, while the database's `BO_` for
	// that group may spell another source address entirely — that PGN fallback is the whole
	// reason such a message resolves at all. So a DBC edit is matched by this, not by the id
	// (codex). Zero on a frame's watch, which matches by id as it always did.
	pgn u32
	// The destination of a CONNECTION-MODE transfer, where its identifier cannot carry one: a
	// PDU2 group has no destination field, so `compose` drops it and two transfers of that
	// group from one sender to different receivers wore the same identifier — one producer in
	// the trace, one series in a plot (codex). -1 on everything else, including a broadcast,
	// which really has none.
	da int = -1
}

// key is the identity as one string: what a comparison compares, and what ImPlot keys a series
// by so two of them keep their own legend entry, colour and visibility. The wire is ESCAPED: a
// recorded bus's wire starts with a NUL (so no live destination key can spell it), and ImGui
// reads an id as a C string — every imported series' id ended at that NUL and the series
// shared one legend entry.
pub fn (i Ident) key() string {
	return '${i.id}|${i.ext}|${i.tp}|${id_safe(i.wire)}|${i.pgn}|${i.da}|${i.sig}'
}

// id_safe is `s` with no NUL in it, injectively (a backslash is escaped too, so a backslash-zero
// typed into a name cannot spell an escaped NUL): what any string reaching an ImGui id must be.
pub fn id_safe(s string) string {
	if !s.contains_any('\x00\\') {
		return s
	}
	return s.replace('\\', '\\\\').replace('\x00', '\\0')
}

// same reports whether two identities are one signal.
pub fn (i Ident) same(o Ident) bool {
	return i.key() == o.key()
}

// Row is what a trace row offers this question.
pub struct Row {
pub:
	id     u32
	ext    bool
	tp     bool
	wire   string
	someip bool
	da     int = -1
}

// covers reports whether a row is one of this signal's samples.
//
// The one predicate for the series, for the plot window's extent and for anything else that
// asks "is this row mine" — because the answer drifting between them is what put a series'
// samples on one wire and its x-axis on another's traffic.
pub fn (i Ident) covers(r Row) bool {
	if r.someip {
		return false // no DBC message behind it; its payload is the deployment's
	}
	if r.id != i.id || r.ext != i.ext || r.tp != i.tp {
		return false
	}
	if i.wire == '' {
		return false // unbound: no wire has been chosen, so no wire's rows are its
	}
	return r.wire == i.wire && r.da == i.da
}

// rec_prefix starts the wire of a recorded bus the project placed nowhere: a NUL, so no live
// destination key can spell it (codex on #329).
pub const rec_prefix = '\x00rec:'

// bind_candidate says whether a row's wire may be bound to: a CONFIGURED wire, or a recorded
// bus. A live key no configured channel is on is refused — after an interface edit or a deleted
// row the history still carries the old key, and its database lookup falls back to every file,
// so a rebinding watch would land straight back on the dead wire (codex on #410).
pub fn bind_candidate(wire string, configured bool) bool {
	return wire != '' && (configured || wire.starts_with(rec_prefix))
}

// bind is the wire an UNBOUND identity takes: the wire of the OLDEST of `n` rows it would cover
// there, among `bind_candidate` wires whose databases define its message (`defines`). The
// oldest, so the answer does not move as traffic arrives; a defining wire, so a message picked
// from a database is not bound to a wire that carries the same number under no definition of
// it. '' when no row qualifies yet. A bound identity keeps its wire.
pub fn (i Ident) bind(n int, at fn (int) Row, configured fn (string) bool, defines fn (string) bool) string {
	if i.wire != '' {
		return i.wire
	}
	mut asked := map[string]bool{}
	for k in 0 .. n {
		r := at(k)
		if r.someip || r.wire == '' || r.id != i.id || r.ext != i.ext || r.tp != i.tp
			|| r.da != i.da {
			continue
		}
		if r.wire !in asked {
			asked[r.wire] = bind_candidate(r.wire, configured(r.wire)) && defines(r.wire)
		}
		if asked[r.wire] {
			return r.wire
		}
	}
	return ''
}

// renamed_by reports whether a DBC edit to `(id, ext)` on `wire`, whose message carries `pgn`,
// names THIS watch's message — the question a SIGNAL RENAME asks, since the signal's name is
// the database's whichever kind of row carries it. `wire` is a wire the edited database BACKS
// this watch on (the caller decides that: it is the lookup, not this package's), compared for
// every kind since #330 — an edit to one wire's database must not move another wire's watch.
//
// A rejoined message is matched by its GROUP: its own identifier is composed from the group,
// the sender and a priority, while the database's `BO_` for that group commonly spells another
// source address — which is the whole reason such a message resolves by PGN at all, so
// comparing the identifier missed exactly the case the fallback exists for. Scoped by wire too:
// an edit to ONE database must not reach a rejoined watch another wire's database backs.
pub fn (i Ident) renamed_by(id u32, ext bool, wire string, pgn u32) bool {
	if i.ext != ext || i.wire != wire {
		return false
	}
	if i.tp {
		return i.pgn == pgn
	}
	return i.id == id
}

// WHAT AN EDIT CHANGES is the caller's, and it differs by kind — which is the whole of what two
// rounds got wrong in both directions:
//
//   - A FRAME's watch takes the new IDENTIFIER, because its rows are that identifier.
//   - A REJOINED message's watch takes the new GROUP (`moved_to`), and its identifier is
//     RECOMPOSED from it, because that identifier comes from the transfer on the wire — group,
//     sender, priority — so writing the database's raw `BO_` id into it pointed the watch at a
//     number no row carries, while leaving the group alone left it on one the file no longer
//     defines. The caller recomposes because composing an identifier is `modules/j1939`'s to
//     do, and this package stays dependency-free: CI runs its test with a bare `v test`, which
//     cannot reach `modules/`.
//
// `renamed_by` answers whether the edit concerns this watch at all, for every kind and for
// every edit — a rename, an id change, a signal rename. There is no second predicate, because
// there is no second question.

// moved_to is the same watch under another parameter group: what a rejoined watch becomes when
// an edit moves its message there.
pub fn (i Ident) moved_to(pgn u32) Ident {
	return Ident{
		...i
		pgn: pgn
	}
}
