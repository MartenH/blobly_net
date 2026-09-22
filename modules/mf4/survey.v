// The SURVEY: what one bounded pass over a recording learns without keeping a row of it
// (docs/streaming_replay.md, step 2). The in-memory loader answers these questions from the
// whole recording it holds — which buses are in it, under what names, how many frames each, the
// span — and the Replay panel, `resolve_bus` and the rest-bus subtraction report all ask them
// BEFORE a replay starts. A player over a window cannot hold the recording to answer, so the
// survey reads the stream once, retaining counts and labels and nothing else, and its answers
// are pinned to `load_recording`'s by the golden test: the same buses, the same names, the same
// counts, on every image and every sample.
//
// It also measures what the stream's caps were set to by guesswork: the read-ahead an unsorted
// data group actually needed (`max_queued`, in rows, against `unsorted_readahead`) and the skew
// between its channel groups (`max_skew_s`, the furthest a row was behind the latest row read
// when it was emitted). The design says the cap is a number once the survey has measured it;
// this is where it is measured.
module mf4

import canlog

// Survey is one pass over a recording: its buses as `load_recording` reports them, its span,
// and the stream's counters and high-water marks. Nothing of the recording is retained.
pub struct Survey {
pub mut:
	buses  []BusInfo
	frames u64
	// The span: the earliest and the latest time any row carried — the loader's first and last
	// row, which it sorted; the stream counts a clock that runs backwards rather than sorting
	// it, so its first row is not always the earliest.
	t0     f64
	end    f64
	groups int // data groups read, one cursor each
	// The stream's counters, folded (see Stream): what the survey asks the caps to be measured
	// against, and what a replay would have to say about this file.
	out_of_order   int
	forced         int
	evicted        int
	refused        int
	unresolved     int
	max_queued     int // the most rows an unsorted group ever had queued ahead of an emission
	max_skew_s     f64 // the furthest an emitted row was behind the latest row read, in seconds
	max_disorder_s f64 // the writer's disorder: the furthest a record read was behind one read before it
}

// survey reads the recording once through the stream. A cursor's failure is the survey's, as
// it is the loader's: a half-surveyed file is not a surveyed one.
pub fn survey(mut src ByteSource) !Survey {
	mut s := open_stream(mut src)!
	mut sv := Survey{
		groups: s.cursors.len
	}
	// The Log here interns LABELS only; no row is ever appended to it, so it is a label table
	// and nothing more. Counts are by label index, one array increment a row, as the loader's
	// tally is.
	mut log := canlog.Log{}
	mut counts := []int{}
	// The acquisition name of every bus, by label index, under tally_buses' rule: the first
	// name seen is the bus's, and a SECOND, different name for the same label is two names for
	// one bus, which is no name — trust neither. Kept as three arrays so the per-row cost is a
	// compare, not a map lookup.
	mut acq_of := []string{}
	mut seen := []bool{}
	mut mixed := []bool{}
	for {
		r := s.next(mut log) or { break }
		b := int(r.bus)
		for counts.len <= b {
			counts << 0
			acq_of << ''
			seen << false
			mixed << false
		}
		if sv.frames == 0 {
			sv.t0 = r.t_s
			sv.end = r.t_s
		} else if r.t_s > sv.end {
			sv.end = r.t_s
		} else if r.t_s < sv.t0 {
			sv.t0 = r.t_s
		}
		sv.frames++
		counts[b]++
		if !seen[b] {
			seen[b] = true
			acq_of[b] = s.last_acq
		} else if !mixed[b] && acq_of[b] != s.last_acq {
			mixed[b] = true
		}
	}
	if s.err != '' {
		return error(s.err)
	}
	sv.out_of_order = s.out_of_order
	sv.forced = s.forced
	sv.evicted = s.evicted
	sv.refused = s.refused
	sv.unresolved = s.unresolved
	sv.max_queued = s.max_queued
	sv.max_skew_s = s.max_skew_s
	sv.max_disorder_s = s.max_disorder_s
	// The buses as parse_recording builds them: a name that covers SEVERAL labels is a name for
	// none of them (one channel group whose records carry their own BusChannel is two buses
	// under one acquisition name), and the list is sorted by label.
	mut names := map[string]string{}
	mut labels_per_name := map[string]int{}
	for b, n in counts {
		if n == 0 {
			continue
		}
		nm := if mixed[b] { '' } else { acq_of[b] }
		names[log.labels[b]] = nm
		if nm != '' {
			labels_per_name[nm]++
		}
	}
	for b, n in counts {
		if n == 0 {
			continue
		}
		lbl := log.labels[b]
		nm := names[lbl]
		sv.buses << BusInfo{
			iface:  lbl
			name:   if labels_per_name[nm] > 1 { '' } else { nm }
			frames: n
		}
	}
	sv.buses.sort(a.iface < b.iface)
	return sv
}

// survey_file surveys a file on disk through its own FileSource.
pub fn survey_file(path string) !Survey {
	mut src := open_source(path)!
	defer {
		src.close()
	}
	return survey(mut src)!
}
