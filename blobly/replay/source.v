module replay

import os
import blobly.candb
import blobly.canlog
import blobly.mf4
import blobly.player

// The size, in MiB, from which a recording replays a chunk at a time (player.Chunker) instead
// of from memory: an `.mf4` from BLOBLY_MF4_STREAM_MB, a candump `.log` from
// BLOBLY_LOG_STREAM_MB, these when unset; 0 streams every file of its kind
// (docs/streaming_replay.md, "The switch").
pub const stream_mb_default = 64
pub const log_stream_mb_default = 64

// stream_mb is the `.mf4` threshold in force: BLOBLY_MF4_STREAM_MB when it is a whole number,
// else the default.
pub fn stream_mb() i64 {
	return stream_mb_of(os.getenv('BLOBLY_MF4_STREAM_MB'), stream_mb_default)
}

// log_stream_mb is the candump `.log` threshold in force: BLOBLY_LOG_STREAM_MB when it is a
// whole number, else the default.
pub fn log_stream_mb() i64 {
	return stream_mb_of(os.getenv('BLOBLY_LOG_STREAM_MB'), log_stream_mb_default)
}

// stream_mb_of reads a threshold as the variables spell it, `dflt` when it is not one.
pub fn stream_mb_of(v string, dflt i64) i64 {
	t := v.trim_space()
	if t == '' || !t.bytes().all(it.is_digit()) || t.len > 9 {
		return dflt
	}
	return t.i64()
}

// threshold_mb is the threshold in force for `path`'s kind.
fn threshold_mb(path string) i64 {
	return if is_mdf(path) { stream_mb() } else { log_stream_mb() }
}

// streams says whether a recording of `size` bytes replays in chunks under a threshold of `mb`
// MiB: at or above it.
pub fn streams(size u64, mb i64) bool {
	return size >= u64(mb) << 20
}

// is_mdf says whether `path` is an MDF file — by its identification block, whatever it is
// called, as mf4.load_recording reads it; a file that cannot be read by its name.
pub fn is_mdf(path string) bool {
	return mf4.is_mdf_file(path)
}

// Source is a recording opened for a replay: its buses, and either the recording itself (`log`)
// or, when `streamed`, only what the survey learned — the rows are read again as they play.
pub struct Source {
pub:
	path     string
	buses    []mf4.BusInfo
	streamed bool
	log      canlog.Log // the whole recording; empty when streamed
	note     string     // why a file above the threshold plays from memory, if it does
	size     u64 // a streamed file's size and modification time at the survey: prepare
	mtime    i64 // refuses a file that no longer matches both
	// asked while a streamed source is read before it plays (open and prepare); true gives the
	// read up with `stopped`
	stop fn () bool = unsafe { nil }
}

// open_recording opens `path` for a replay under the threshold in force for its kind.
pub fn open_recording(path string) !Source {
	return open_recording_at(path, threshold_mb(path), unsafe { nil })
}

// open_recording_until is open_recording, given up once `stop` answers true.
pub fn open_recording_until(path string, stop fn () bool) !Source {
	return open_recording_at(path, threshold_mb(path), stop)
}

// open_recording_at opens `path` for a replay under a threshold of `mb` MiB: surveyed when it
// streams, loaded otherwise — and loaded, with a note, when the stream would not reproduce the
// loader's rows (stream_differs, log_stream_differs).
pub fn open_recording_at(path string, mb i64, stop fn () bool) !Source {
	mut note := ''
	size := os.file_size(path)
	mtime := os.file_last_mod_unix(path)
	if streams(size, mb) {
		mut sink := StopSink{
			stop: stop
		}
		buses, why := survey_for(path, mut sink)!
		if why == '' {
			return Source{
				path:     path
				buses:    buses
				streamed: true
				stop:     stop
				size:     size
				mtime:    mtime
			}
		}
		note = '${os.base(path)}: ${why} — replayed from memory'
	}
	log, buses := load(path)!
	return Source{
		path:  path
		buses: buses
		log:   log
		note:  note
		stop:  stop
	}
}

// survey_for surveys `path` through the stream of its kind, handing every row to `sink`: its
// buses as the loader reports them, and why the stream would differ from the loader ('' when
// it would not).
fn survey_for(path string, mut sink StreamSink) !([]mf4.BusInfo, string) {
	if is_mdf(path) {
		sv := mf4.survey_file_into(path, mut sink)!
		if sv.frames == 0 {
			return error('${os.base(path)} holds no frames')
		}
		return sv.buses, stream_differs(sv)
	}
	sv := canlog.survey_file_into(path, mut sink)!
	if sv.frames == 0 {
		return error('${os.base(path)} holds no frames')
	}
	mut counts := map[string]int{}
	for i, l in sv.labels {
		if i < sv.counts.len && sv.counts[i] > 0 {
			counts[l] = sv.counts[i]
		}
	}
	return log_buses(counts), log_stream_differs(sv)
}

// StreamSink is what both surveys hand their rows to (mf4.RowSink, canlog.RowSink).
interface StreamSink {
mut:
	row(labels &canlog.Log, r canlog.Row) bool
}

// stream_differs says how the stream's rows would differ from the loader's, '' when they would
// not: rows out of time order (only the loader's sort places them), or frames whose payload the
// stream could not hold until they were decoded.
pub fn stream_differs(sv mf4.Survey) string {
	if sv.out_of_order > 0 {
		return '${sv.out_of_order} rows out of time order'
	}
	if sv.unresolved > 0 || sv.evicted > 0 {
		return '${sv.unresolved + sv.evicted} frames whose payload the stream cannot hold'
	}
	return ''
}

// log_stream_differs is stream_differs for a candump file: rows the line stream could not put
// in the loader's time order (canlog.time_ordered) within its look-ahead.
pub fn log_stream_differs(sv canlog.Survey) string {
	if sv.out_of_order > 0 {
		return '${sv.out_of_order} rows out of time order past the ${canlog.lookahead_s:.0f} s look-ahead'
	}
	return ''
}

// StopSink keeps nothing and asks `stop` every few thousand rows.
struct StopSink {
	stop fn () bool = unsafe { nil }
mut:
	n int
}

fn (mut s StopSink) row(_ &canlog.Log, _ canlog.Row) bool {
	s.n++
	return s.n % 4096 != 0 || isnil(s.stop) || !s.stop()
}

// Prepared is a source planned for its buses (player.BusSpec): what each bus keeps, the span,
// and the player that plays it. `close` ends a streamed one's reader.
pub struct Prepared {
pub:
	buses    []player.BusPlan
	t0_s     f64
	end_s    f64
	streamed bool
mut:
	plan    player.MultiPlan
	chunker &player.Chunker = unsafe { nil }
}

// prepare plans the source: in memory, build_multi_log; streamed, a Chunker whose open pass is
// the same Planner over the same rows, so both decide the same.
pub fn (s &Source) prepare(specs []player.BusSpec) !Prepared {
	if s.streamed {
		mut c := player.open_chunker_until(s.path, specs, player.chunk_rows, s.stop)!
		if c.size != s.size || c.mtime != s.mtime {
			c.close()
			return error('${s.path} changed since it was opened')
		}
		return Prepared{
			buses:    c.buses
			t0_s:     c.t0_s
			end_s:    c.end_s
			streamed: true
			chunker:  c
		}
	}
	plan := player.build_multi_log(s.log, specs)
	return Prepared{
		buses: plan.buses
		t0_s:  plan.t0_s
		end_s: plan.end_s
		plan:  plan
	}
}

// player plays the plan. One player per Prepared: a streamed plan has one reader.
pub fn (p &Prepared) player(speed f64, repeat bool) player.Player {
	if !isnil(p.chunker) {
		return player.new_player_chunked(p.chunker, speed, repeat)
	}
	return player.new_player_log(p.plan.log, p.plan.sel, speed, repeat, p.plan.t0_s,
		p.plan.end_s)
}

// read_error is the first read error a streamed replay met; a pass ends there. '' in memory.
pub fn (p &Prepared) read_error() string {
	if isnil(p.chunker) {
		return ''
	}
	return p.chunker.err
}

// close ends a streamed plan's reader; nothing in memory.
pub fn (mut p Prepared) close() {
	if !isnil(p.chunker) {
		mut c := p.chunker
		c.close()
	}
}

// scan is a recording's buses and, per bus label, who talks on it through `db`
// (player.NodeCensus): the Replay panel's preview. A streamed source is read once, the census
// taken as the survey passes; nothing of the recording is kept.
pub fn scan(path string, db candb.Database) !([]mf4.BusInfo, map[string]player.NodeCensus) {
	return scan_at(path, db, threshold_mb(path))
}

// scan_at is scan under a threshold of `mb` MiB.
pub fn scan_at(path string, db candb.Database, mb i64) !([]mf4.BusInfo, map[string]player.NodeCensus) {
	mut cens := map[string]player.NodeCensus{}
	if streams(os.file_size(path), mb) {
		mut sink := CensusSink{
			db: db
		}
		buses, why := survey_for(path, mut sink)!
		if why == '' {
			for b in buses {
				i := sink.labels.index(b.iface)
				cens[b.iface] = if i >= 0 && i < sink.by.len {
					sink.by[i].done()
				} else {
					player.new_census(db).done()
				}
			}
			return buses, cens
		}
	}
	log, buses := load(path)!
	for b in buses {
		cens[b.iface] = player.census_sel(&log, player.sel_on_bus(&log, b.iface), db)
	}
	return buses, cens
}

// CensusSink takes a census per recorded bus as the survey reads the rows.
struct CensusSink {
	db candb.Database
mut:
	raw    canlog.Log // the row being tallied, under the survey's labels
	by     []player.Census
	labels []string
}

fn (mut s CensusSink) row(labels &canlog.Log, r canlog.Row) bool {
	b := int(r.bus)
	for s.by.len <= b {
		s.by << player.new_census(s.db)
	}
	s.labels = labels.labels
	s.raw.labels = labels.labels
	s.raw.rows.clear()
	s.raw.rows << r
	s.by[b].add(s.raw.frame(0), r.t_s)
	return true
}
