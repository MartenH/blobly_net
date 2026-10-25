module replay

import os
import blobly.candb
import blobly.canlog
import blobly.mf4
import blobly.player

// The size, in MiB, from which an `.mf4` replays a chunk at a time (player.Chunker) instead of
// from memory: BLOBLY_MF4_STREAM_MB, this when unset. 0 streams every `.mf4`. A candump `.log`
// always loads whole (docs/streaming_replay.md, "The switch").
pub const stream_mb_default = 64

// stream_mb is the threshold in force: BLOBLY_MF4_STREAM_MB when it is a whole number, else the
// default.
pub fn stream_mb() i64 {
	return stream_mb_of(os.getenv('BLOBLY_MF4_STREAM_MB'))
}

// stream_mb_of reads a threshold as BLOBLY_MF4_STREAM_MB spells it.
pub fn stream_mb_of(v string) i64 {
	t := v.trim_space()
	if t == '' || !t.bytes().all(it.is_digit()) || t.len > 9 {
		return stream_mb_default
	}
	return t.i64()
}

// streams says whether a recording of `size` bytes at `path` replays in chunks under a threshold
// of `mb` MiB: an `.mf4` at or above it.
pub fn streams(path string, size u64, mb i64) bool {
	return path.to_lower().ends_with('.mf4') && size >= u64(mb) << 20
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
}

// open_recording opens `path` for a replay under the threshold in force.
pub fn open_recording(path string) !Source {
	return open_recording_at(path, stream_mb())
}

// open_recording_at opens `path` for a replay under a threshold of `mb` MiB: surveyed when it
// streams, loaded otherwise. A file the stream cannot put in the loader's order (rows out of
// time order) is loaded, since only the loader's sort places them.
pub fn open_recording_at(path string, mb i64) !Source {
	if streams(path, u64(os.file_size(path)), mb) {
		sv := mf4.survey_file(path)!
		if sv.frames == 0 {
			return error('${os.base(path)} holds no frames')
		}
		if sv.out_of_order == 0 {
			return Source{
				path:     path
				buses:    sv.buses
				streamed: true
			}
		}
		log, buses := load(path)!
		return Source{
			path:  path
			buses: buses
			log:   log
			note:  '${os.base(path)}: ${sv.out_of_order} rows out of time order — replayed from memory'
		}
	}
	log, buses := load(path)!
	return Source{
		path:  path
		buses: buses
		log:   log
	}
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
		c := player.open_chunker(s.path, specs, player.chunk_rows)!
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
	return scan_at(path, db, stream_mb())
}

// scan_at is scan under a threshold of `mb` MiB.
pub fn scan_at(path string, db candb.Database, mb i64) !([]mf4.BusInfo, map[string]player.NodeCensus) {
	mut cens := map[string]player.NodeCensus{}
	if streams(path, u64(os.file_size(path)), mb) {
		mut sink := CensusSink{
			db: db
		}
		sv := mf4.survey_file_into(path, mut sink)!
		if sv.frames == 0 {
			return error('${os.base(path)} holds no frames')
		}
		if sv.out_of_order == 0 {
			for b in sv.buses {
				i := sink.labels.index(b.iface)
				cens[b.iface] = if i >= 0 && i < sink.by.len {
					sink.by[i].done()
				} else {
					player.new_census(db).done()
				}
			}
			return sv.buses, cens
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

fn (mut s CensusSink) row(labels &canlog.Log, r canlog.Row) {
	b := int(r.bus)
	for s.by.len <= b {
		s.by << player.new_census(s.db)
	}
	s.labels = labels.labels
	s.raw.labels = labels.labels
	s.raw.rows.clear()
	s.raw.rows << r
	s.by[b].add(s.raw.frame(0), r.t_s)
}
