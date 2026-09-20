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
module watchrule

// Ident is everything that makes two plotted signals DIFFERENT signals.
pub struct Ident {
pub:
	id  u32
	ext bool
	// A message rejoined from a transport session rather than a frame. One PGN can arrive both
	// ways from one node, and the two carry different payload shapes.
	tp bool
	// The wire it came off. It scopes a REJOINED message, whose lookup is by PGN and so can
	// land on another wire's layout; an ordinary frame's watch is unscoped, which is #330 and
	// is about every row rather than about this one.
	wire string
	sig  string
}

// key is the identity as one string: what a comparison compares, and what ImPlot keys a series
// by so two of them keep their own legend entry, colour and visibility.
pub fn (i Ident) key() string {
	return '${i.id}|${i.ext}|${i.tp}|${i.wire}|${i.sig}'
}

// same reports whether two identities are one signal.
pub fn (i Ident) same(o Ident) bool {
	return i.key() == o.key()
}

// scoped_by_wire says whether this identity's rows are restricted to one wire. Only a rejoined
// message is: its lookup is by PGN, so another wire's definition of that group is a different
// message wearing the same number.
pub fn (i Ident) scoped_by_wire() bool {
	return i.tp
}

// Row is what a trace row offers this question.
pub struct Row {
pub:
	id     u32
	ext    bool
	tp     bool
	wire   string
	someip bool
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
	return !i.scoped_by_wire() || r.wire == i.wire
}

// rewritten_by reports whether a DBC edit to `(id, ext)` on `wire` should move this watch.
//
// Scoped, because an edit to ONE database must not move a watch that another wire's database
// backs: the rewrite loops matched `(id, ext)` alone, so editing the first-loaded DBC moved a
// rejoined watch belonging to a different wire to the edited id and kind. A frame's watch is
// unscoped for the reason `covers` leaves it unscoped.
pub fn (i Ident) rewritten_by(id u32, ext bool, wire string) bool {
	if i.id != id || i.ext != ext {
		return false
	}
	return !i.scoped_by_wire() || i.wire == wire
}
