module main

// Headless reproduction of the GUI's startup + sim build, with NO sokol/GUI.
// Loads a project, every channel's DBC, builds every simulated ECU, and pumps
// one round of due_frames per channel — to isolate logic crashes from GUI ones.

import os
import project
import candb
import sim

fn main() {
	path := os.args[1] or { 'projects/sim-demo.blobnet' }
	p := project.load(path) or {
		eprintln('project.load failed: ${err}')
		exit(2)
	}
	println('project: ${p.name}, channels=${p.channels.len}')
	proj_dir := os.dir(os.real_path(path))
	mut total_msgs := 0
	mut failed := 0
	for ch in p.channels {
		// resolve_asset + merge_files, the same as the GUI and the runner. Reading only
		// databases[0] as written meant a project kept outside the repository loaded nothing,
		// and this check then reported OK on a simulation that transmitted nothing at all.
		mut db := candb.Database{}
		if ch.databases.len > 0 {
			paths := ch.databases.map(project.resolve_asset(proj_dir, it))
			// EACH file, not just the aggregate. merge_files skips one it cannot read, so a
			// channel listing a good DBC beside a missing or malformed one still returned
			// messages and passed — with part of the catalogue, and the frames it defines,
			// quietly absent. That is the shape of failure this tool exists to catch.
			mut lost := 0
			for pth in paths {
				candb.load_dbc_file(pth) or {
					eprintln('  ${ch.name}: cannot load ${pth}: ${err}')
					lost++
					continue
				}
			}
			db = candb.merge_files(paths)
			if lost > 0 || db.messages.len == 0 {
				if db.messages.len == 0 {
					eprintln('  ${ch.name}: no messages loaded from ${paths}')
				}
				failed++
				continue
			}
		}
		mut engine := sim.Engine{}
		for cfg in ch.all_nodes() {
			engine.ecus << build_node(db, cfg)
		}
		// pump a few rounds of due_frames across a simulated 200ms
		mut count := 0
		for t in [f64(0), 10, 20, 50, 100, 200] {
			count += engine.due_frames(t).len
		}
		total_msgs += count
		// Only a node that SHOULD transmit unsolicited counts as a failure. due_frames skips
		// messages with no cycle time by design, so an ECU whose behaviour is purely
		// request/response emits nothing here and is perfectly valid — failing it would reject
		// a working project.
		mut cyclic := 0
		for ecu in engine.ecus {
			for m in ecu.messages {
				if m.period_ms > 0 {
					cyclic++
				}
			}
		}
		if cyclic > 0 && count == 0 {
			eprintln('  ${ch.name}: ${cyclic} cyclic message(s) but NO frames in 200ms')
			failed++
		}
		println('  ${ch.name}: nodes=${ch.all_nodes().len} db_msgs=${db.messages.len} frames_in_200ms=${count}')
	}
	if failed > 0 {
		eprintln('FAILED: ${failed} channel(s) loaded nothing or emitted nothing')
		exit(1)
	}
	println('OK total frames in first 200ms across all buses: ${total_msgs}')
}

// build_node delegates to sim.from_project — the single implementation shared with the GUI
// and the headless runner, so a startup check cannot pass on frames the real runs never send.
fn build_node(db candb.Database, cfg project.NodeCfg) sim.SimEcu {
	// A protect: entry naming a message or signal that is not there applies nothing, and the
	// run would otherwise score a protected project against unprotected traffic without a word.
	for w in sim.validate_cfg(db, cfg) {
		eprintln('${cfg.name}: ${w}')
	}
	return sim.from_project(db, cfg)
}
