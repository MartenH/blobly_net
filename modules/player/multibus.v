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
	mut out := []canlog.LogEntry{}
	mut plans := []BusPlan{}
	mut t0 := 0.0
	mut end := 0.0
	mut seen_any := false
	for sp in specs {
		src := on_bus(entries, sp.src)
		if src.len == 0 {
			plans << BusPlan{
				src: sp.src
				dst: sp.dst
			}
			continue
		}
		// The span comes from the SOURCE frames, before subtraction, and spans every bus.
		if !seen_any {
			t0 = src[0].t_s
			end = src[src.len - 1].t_s
			seen_any = true
		} else {
			if src[0].t_s < t0 {
				t0 = src[0].t_s
			}
			if src[src.len - 1].t_s > end {
				end = src[src.len - 1].t_s
			}
		}
		kept, rep := without_senders(src, sp.db, sp.exclude, sp.replay_unattributed)
		for e in kept {
			// Relabelled to the DESTINATION, so the sender is a map lookup and the player never
			// learns that a mapping happened.
			out << canlog.LogEntry{
				t_s:   e.t_s
				dir:   e.dir
				iface: sp.dst
				frame: e.frame
			}
		}
		plans << BusPlan{
			src:    sp.src
			dst:    sp.dst
			source: src.len
			report: rep
		}
	}
	out.sort(a.t_s < b.t_s)
	return MultiPlan{
		entries: out
		buses:   plans
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
		dst_seen[sp.dst]++
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
