module player

import candb
import mf4

// A chunked player must be the in-memory player: the same frames, on the same bus, due at the
// same moment, through a loop wrap, a seek, a stop and a restart. Chunks as small as ONE row put
// a boundary between every pair of frames, so any state the in-memory path carries from row to
// row (the planner's walkers, the pass cursor, the sent count) is asked to survive one.

const chunk_samples = ['two_buses.mf4', 'both_dirs.mf4', 'demo.mf4']

fn chunk_specs(labels []string, db candb.Database, exclude []string) []BusSpec {
	mut specs := []BusSpec{}
	for i, l in labels {
		specs << BusSpec{
			src:     l
			dst:     'live${i}'
			db:      db
			exclude: exclude
		}
	}
	return specs
}

// script drives a player through one fixed sequence and writes down everything it emitted.
fn script(mut p Player) []string {
	mut out := []string{}
	d := p.duration_s()
	step := if d > 0 { d * 1000.0 / 37.0 } else { 1.0 }
	mut now := 0.0
	p.play(now)
	for k in 0 .. 140 {
		match k {
			40 { p.seek(d * 0.55, now) }
			70 { p.set_repeat(false) }
			95 { p.stop() }
			96 { p.play(now) }
			120 { p.seek(0, now) }
			else {}
		}
		es, due := p.due_with_schedule(now)
		for i, e in es {
			out << '${k} ${due[i]:.6f} ${e.iface} ${e.dir} ${e.frame.id} ${e.frame.data}'
		}
		nd := p.next_due_ms() or { -1.0 }
		out << '${k} ${p.state()} sent=${p.sent()}/${p.len()} passes=${p.passes()} next=${nd:.6f}'
		now += step
	}
	return out
}

fn test_chunked_playback_is_the_in_memory_playback() {
	db := candb.load_dbc_file(@VMODROOT + '/dbc/blobly_net.dbc') or { panic(err) }
	for name in chunk_samples {
		path := @VMODROOT + '/samples/' + name
		rec := mf4.load_recording(path) or { panic(err) }
		for exclude in [[]string{}, ['SUT']] {
			specs := chunk_specs(rec.log.labels, db, exclude)
			plan := build_multi_log(rec.log, specs)
			mut mem := new_player_log(plan.log, plan.sel, 1.0, true, plan.t0_s, plan.end_s)
			want := script(mut mem)
			if exclude.len == 0 {
				assert want.len > 140, name // frames were played, not just states
			}
			for rows in [1, 2, 3, 7, 100_000] {
				mut c := open_chunker(path, specs, rows) or { panic(err) }
				assert c.buses == plan.buses, '${name} rows=${rows}'
				mut chunked := new_player_chunked(c, 1.0, true)
				got := script(mut chunked)
				assert c.err == ''
				c.close()
				for i in 0 .. want.len {
					assert got[i] == want[i], '${name} exclude=${exclude} rows=${rows} line ${i}'
				}
				assert got.len == want.len
			}
		}
	}
}
