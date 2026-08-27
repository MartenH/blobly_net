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
	entries []canlog.LogEntry // time-sorted, relabelled to destination interfaces
	buses   []BusPlan
	// The SOURCE span across every selected bus — not the span of what survived. Filtering must
	// not shorten a lap or move its origin, and with several buses in one stream a per-bus span
	// would be meaningless anyway.
	t0_s  f64
	end_s f64
}

// build_multi selects, subtracts and merges. Order of `specs` does not matter; the result is
// sorted by recorded time, so the buses interleave exactly as they did in the car.
pub fn build_multi(entries []canlog.LogEntry, specs []BusSpec) MultiPlan {
	// ONE pass over the recording, in recorded order. Filtering bus by bus and sorting the
	// concatenation by timestamp afterwards loses the order of frames that share a timestamp —
	// and simultaneous cross-bus stimuli are exactly what a gateway is watching. Their order
	// would then be decided by --map order or by the sort's tie behaviour, which is the skew
	// this whole feature exists to avoid.
	mut idx_of := map[string]int{} // src label -> index into specs
	for i, sp in specs {
		idx_of[sp.src] = i
	}
	mut deciders := []Decider{}
	mut tallies := []Tally{}
	mut sources := []int{}
	for sp in specs {
		deciders << new_decider(sp.db, sp.exclude, sp.replay_unattributed)
		tallies << Tally{}
		sources << 0
	}
	mut out := []canlog.LogEntry{}
	mut t0 := 0.0
	mut end := 0.0
	mut seen_any := false
	for e in entries {
		i := idx_of[e.iface] or { continue }
		sources[i]++
		// The span comes from the SOURCE frames, before subtraction, across every mapped bus.
		if !seen_any {
			t0 = e.t_s
			end = e.t_s
			seen_any = true
		} else {
			if e.t_s < t0 {
				t0 = e.t_s
			}
			if e.t_s > end {
				end = e.t_s
			}
		}
		if tallies[i].add(deciders[i].verdict(e.frame), e.frame) {
			// Relabelled to the DESTINATION, so the sender is a map lookup and the player never
			// learns that a mapping happened.
			out << canlog.LogEntry{
				t_s:   e.t_s
				dir:   e.dir
				iface: specs[i].dst
				frame: e.frame
			}
		}
	}
	mut plans := []BusPlan{}
	for i, sp in specs {
		plans << BusPlan{
			src:    sp.src
			dst:    sp.dst
			source: sources[i]
			report: tallies[i].done(0) // kept is filled below from the tally's own counts
		}
	}
	// kept per bus: the Tally does not know it, so count what each bus contributed.
	//
	// EVERY WITHHELD BUCKET has to be subtracted here, and this is the second place that has to
	// be told when one is added -- the remote-request bucket (#179) was not, so with
	// --drop-unattributed the frames it withheld were absent from `entries` and still counted as
	// replayed. A bus whose traffic was all remote requests then reported kept == source, and the
	// "silent: all frames withheld" diagnosis could never fire for it (self-review).
	mut kept_of := []int{len: specs.len}
	for i in 0 .. specs.len {
		r := plans[i].report
		kept_of[i] = sources[i] - r.withheld_excluded - r.withheld_unattributed
	}
	mut fixed := []BusPlan{}
	for i, pl in plans {
		fixed << BusPlan{
			src:    pl.src
			dst:    pl.dst
			source: pl.source
			// SPREAD, not field by field. Listing them meant a count added to Subtraction was
			// simply absent here and read as zero everywhere downstream -- which is what happened
			// to the remote-request counts, leaving their reporting in `cmd/restbus` dead on this
			// path while it worked perfectly on the single-bus one (self-review). `kept` is the
			// only field this loop actually computes.
			report: Subtraction{
				...pl.report
				kept: kept_of[i]
			}
		}
	}
	return MultiPlan{
		entries: out
		buses:   fixed
		t0_s:    t0
		end_s:   end
	}
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
