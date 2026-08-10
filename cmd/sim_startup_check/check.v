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
	mut total_msgs := 0
	for ch in p.channels {
		mut db := candb.Database{}
		if ch.databases.len > 0 {
			db = candb.load_dbc_file(ch.databases[0]) or {
				eprintln('  ${ch.name}: load_dbc_file(${ch.databases[0]}) failed: ${err}')
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
		println('  ${ch.name}: nodes=${ch.all_nodes().len} db_msgs=${db.messages.len} frames_in_200ms=${count}')
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
