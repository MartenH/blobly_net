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
// data group actually needed (`max_queued` in rows, against `unsorted_readahead`; `max_ahead_s`
// in seconds) and the WRITER's disorder (`max_disorder_s`: how far a record was behind the
// latest time read before it in its epoch, what `unsorted_lookahead_s` must cover). The design says the cap is a
// number once the survey has measured it; this is where it is measured — and where the
// measurement replaced the rule (see `settled` in stream.v).
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
	// it, so its first row is not always the earliest. Earliest to latest, not the duration
	// recorded: a clock that stepped back makes the two differ, and `out_of_order` says so.
	t0     f64
	end    f64
	groups int // data groups with a channel-group chain, one cursor each: a group whose channels are not CAN frames counts, an empty data group does not
	// The stream's counters, folded (see Stream): what the survey asks the caps to be measured
	// against, and what a replay would have to say about this file.
	out_of_order   int
	forced         int
	evicted        int
	refused        int
	unresolved     int
	max_queued     int // the most rows an unsorted group ever had queued ahead of an emission
	max_ahead_s    f64 // the furthest the reader had run ahead (its epoch's latest time read) of a row when it emitted it, in seconds
	max_disorder_s f64 // the writer's disorder: the furthest a record was behind the latest time read before it in its epoch
	clock_steps    int // times the clock stepped back by more than the window — counted apart from disorder
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
	// The acquisition name of every bus, filed under the loader's rule (note_bus_name) — asked
	// only when a bus's name CHANGES from row to row, so the per-row cost is one string compare
	// and not a map lookup.
	mut names := map[string]string{}
	mut acq_of := []string{}
	mut seen := []bool{}
	for {
		r := s.next(mut log) or { break }
		b := int(r.bus)
		for counts.len <= b {
			counts << 0
			acq_of << ''
			seen << false
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
		if !seen[b] || acq_of[b] != s.last_acq {
			seen[b] = true
			acq_of[b] = s.last_acq
			note_bus_name(mut names, log.labels[b], s.last_acq)
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
	sv.max_ahead_s = s.max_ahead_s
	sv.max_disorder_s = s.max_disorder_s
	sv.clock_steps = s.clock_steps
	// the buses as parse_recording builds them: the same fold over the same two maps
	mut by_label := map[string]int{}
	for b, n in counts {
		if n > 0 {
			by_label[log.labels[b]] = n
		}
	}
	sv.buses = fold_buses(names, by_label)
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
