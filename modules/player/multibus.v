// Replaying SEVERAL recorded buses at once, which is the shape a real bench needs.
//
// The ECU under test sits on every bus in the recording, and on most of them it is a gateway:
// it takes a message from one and emits a derived one on another, within a deadline it also
// polices. That is the whole reason this is not just the single-bus path run N times.
//
// ONE CLOCK. All buses are replayed from a single time-sorted stream against one player, so the
// recording's cross-bus ordering survives. N independent players, each started when its thread
// happened to reach `play()`, would put an arbitrary skew between buses — invisible in a trace,
// and precisely the relationship a gateway exists to check. A per-bus skew of a few milliseconds
// is not a rounding error to a receiver watching for a response within ten.
//
// The trick that keeps the player bus-agnostic: entries are RE-LABELLED to their destination
// interface as they are selected, so a sender only has to look up `entry.iface` in a map of open
// buses. Nothing downstream needs to know a mapping existed.
module player

import canlog
import candb
import transport

// BusSpec maps one recorded bus onto one live one. `src` is the label the recording's entries
// carry (`mf4:group25`), NOT the name a person types — resolving a name to a label is the
// caller's job, because a name is not unique and a label is.
pub struct BusSpec {
pub:
	src                 string
	dst                 string
	db                  candb.Database
	exclude             []string
	replay_unattributed bool = true
}

// BusPlan is what one mapping did, kept per bus rather than summed. A total would hide the case
// that matters: one bus subtracting to nothing while the others look healthy.
pub struct BusPlan {
pub:
	src    string
	dst    string
	source int // frames on this bus in the recording
	report Subtraction
}

// MultiPlan is the whole replay: one stream, and what each bus contributed to it.
pub struct MultiPlan {
pub:
	// The recording's rows, SHARED with the source Log, under labels that name the destination
	// interfaces; and which rows play, in recorded order. Nothing is copied to plan a replay.
	log   canlog.Log
	sel   []u32
	buses []BusPlan
	// The SOURCE span across every selected bus — not the span of what survived. Filtering must
	// not shorten a lap or move its origin, and with several buses in one stream a per-bus span
	// would be meaningless anyway.
	t0_s  f64
	end_s f64
}

// entries is the plan in the old shape — every payload cloned, O(n). For tests.
pub fn (p &MultiPlan) entries() []canlog.LogEntry {
	return p.log.entries_of(p.sel)
}

// build_multi is build_multi_log over entries: the tests' door.
pub fn build_multi(entries []canlog.LogEntry, specs []BusSpec) MultiPlan {
	return build_multi_log(canlog.from_entries(entries), specs)
}

// build_multi_log selects, subtracts and merges. Order of `specs` does not matter; the
// result is in recorded time, so the buses interleave exactly as they did in the car.
pub fn build_multi_log(log canlog.Log, specs []BusSpec) MultiPlan {
	// ONE pass over the recording, in recorded order. Filtering bus by bus and sorting the
	// concatenation by timestamp afterwards loses the order of frames that share a timestamp —
	// and simultaneous cross-bus stimuli are exactly what a gateway is watching. Their order
	// would then be decided by --map order or by the sort's tie behaviour, which is the skew
	// this whole feature exists to avoid.
	mut p := new_planner(specs)
	mut sel := []u32{}
	for ri in 0 .. log.rows.len {
		if p.keep(&log, ri) {
			sel << u32(ri)
		}
	}
	p.resolve(&log) // a log with no rows still relabels every bus it names
	// Same rows, destination labels.
	return MultiPlan{
		log:   log.relabelled(p.dst)
		sel:   sel
		buses: p.plans()
		t0_s:  p.t0
		end_s: p.end
	}
}

// Planner decides, row by row, which recorded frames to replay and onto which bus. Both the
// in-memory plan and the chunked reader use it. It keeps state across rows (J1939 sessions,
// tallies), so one Planner covers a whole pass.
pub struct Planner {
	specs []BusSpec
mut:
	spec_of []int    // per label index: which spec it replays under, -1 for none
	dst     []string // per label index: the bus it replays onto
	walkers []Walker
	tallies []Tally
	sources []int
	t0      f64
	end     f64
	seen    bool
}

pub fn new_planner(specs []BusSpec) Planner {
	mut p := Planner{
		specs: specs
	}
	for sp in specs {
		p.walkers << new_walker(sp.db, sp.exclude, sp.replay_unattributed)
		p.tallies << Tally{}
		p.sources << 0
	}
	return p
}

// resolve maps each label index to its spec and destination bus. It reruns when the label table
// has grown, since a stream adds a bus label the first time it sees one.
fn (mut p Planner) resolve(log &canlog.Log) {
	if p.spec_of.len == log.labels.len {
		return
	}
	p.spec_of = []int{len: log.labels.len, init: -1}
	p.dst = log.labels.clone()
	for i, sp in p.specs {
		if j := log.index_of(sp.src) {
			p.spec_of[j] = i
			p.dst[j] = sp.dst
		}
	}
}

// keep decides whether row `ri` of `log` plays.
pub fn (mut p Planner) keep(log &canlog.Log, ri int) bool {
	p.resolve(log)
	r := log.rows[ri]
	i := p.spec_of[r.bus]
	if i < 0 {
		return false
	}
	p.sources[i]++
	// The span comes from the SOURCE frames, before subtraction, across every mapped bus.
	if !p.seen {
		p.t0 = r.t_s
		p.end = r.t_s
		p.seen = true
	} else {
		if r.t_s < p.t0 {
			p.t0 = r.t_s
		}
		if r.t_s > p.end {
			p.end = r.t_s
		}
	}
	f := log.frame(ri) // a view: the verdict reads id, width, RTR and length
	return p.tallies[i].add_decision(p.walkers[i].decide(f, r.t_s), f)
}

// plans is the census so far: what each bus sourced, and what its subtraction withheld.
pub fn (p Planner) plans() []BusPlan {
	mut out := []BusPlan{}
	for i, sp in p.specs {
		r := p.tallies[i].done(0)
		// kept = source minus every withheld bucket; a new bucket must be subtracted here too.
		out << BusPlan{
			src:    sp.src
			dst:    sp.dst
			source: p.sources[i]
			// spread, so every count in Subtraction is carried; only `kept` is set here
			report: Subtraction{
				...r
				kept: p.sources[i] - r.withheld_excluded - r.withheld_unattributed - r.remote
			}
		}
	}
	return out
}

// conflicts reports mappings that cannot be run as given. Both are user errors that otherwise
// produce a plausible-looking run: the same recorded bus sent to two places duplicates its
// traffic, and two recorded buses sharing one destination merges buses that never shared a wire
// — which is the collapse `bus_iface` in modules/mf4 exists to prevent, reintroduced by config.
pub fn conflicts(specs []BusSpec) []string {
	mut out := []string{}
	mut src_seen := map[string]int{}
	mut dst_seen := map[string]int{}
	for sp in specs {
		src_seen[sp.src]++
		// By DESTINATION IDENTITY, not spelling. `inproc` and `inproc:CAN` are one medium; so
		// are `pcan:PCAN_USBBUS1` and `pcan:usb1@500000`, which the vendor backend resolves to
		// one handle. Compared as strings, two recorded buses would land on one live bus with
		// this check reporting no conflict at all.
		dst_seen[transport.destination_key(sp.dst)]++
	}
	for k, n in src_seen {
		if n > 1 {
			out << 'recorded bus ${k} is mapped ${n} times — its traffic would be sent twice'
		}
	}
	for k, n in dst_seen {
		if n > 1 {
			out << '${n} recorded buses are mapped onto ${k} — ids that never shared a wire would collide'
		}
	}
	out.sort()
	return out
}

// resolve_bus turns what a person configured — `CAN1`, or `mf4:group25` — into the label the
// recording's entries actually carry.
//
// ONE implementation, because there were two: the GUI and cmd/restbus each grew their own and
// had already drifted in their fallbacks. Which bus a recording means is a fact about the file,
// not a front-end convenience, so it belongs here (CLAUDE.md: anything deciding what a wire
// format MEANS lives in modules/).
//
// The LABEL is the identity and is matched first, in its own pass. The acquisition name is free
// text a writer chose: it may collide with another bus's label, and it may not be unique, so an
// ambiguous name is refused rather than resolved by picking one.
pub fn resolve_bus(buses []BusName, labels []string, want string) !string {
	if want == '' {
		if labels.len != 1 {
			return error('the recording holds ${labels.len} buses — name one')
		}
		return labels[0]
	}
	for b in buses {
		if b.iface == want {
			return b.iface
		}
	}
	if want in labels {
		return want
	}
	mut named := []string{}
	for b in buses {
		if b.name != '' && b.name == want {
			named << b.iface
		}
	}
	if named.len == 1 {
		return named[0]
	}
	if named.len > 1 {
		return error('"${want}" names ${named.len} buses — use the label instead')
	}
	return error('no bus "${want}" in the recording')
}

// BusName is the (label, name) pair resolve_bus needs, so this module does not depend on mf4 —
// a recording format is one caller's concern, and canlog files have no bus names at all.
pub struct BusName {
pub:
	iface string
	name  string
}
