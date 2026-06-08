module main

// Headless reproduction of the GUI's startup + sim build, with NO sokol/GUI.
// Loads a project, every channel's DBC, builds every simulated ECU, and pumps
// one round of due_frames per channel — to isolate logic crashes from GUI ones.

import os
import project
import candb
import sim

fn main() {
	path := os.args[1] or { 'projects/ecu-vcm.yml' }
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

fn build_node(db candb.Database, cfg project.NodeCfg) sim.SimEcu {
	if cfg.signals.len == 0 && cfg.responses.len == 0 {
		return sim.build_ecu(db, cfg.name)
	}
	mut gens := map[string]sim.Gen{}
	for g in cfg.signals {
		gens[g.signal] = gen_of(g)
	}
	mut rules := []sim.ResponseRule{}
	for r in cfg.responses {
		rules << sim.ResponseRule{
			req_id:     r.request
			resp_id:    r.response
			byte_index: r.byte
			add:        r.add
		}
	}
	return sim.build_configured_ecu(db, cfg.name, gens, rules)
}

fn gen_of(g project.GenCfg) sim.Gen {
	return match g.typ {
		'sine' { sim.gen_sine(g.offset, g.amplitude, g.freq, g.phase) }
		'sawtooth' { sim.gen_sawtooth(g.min, g.max, g.period) }
		'counter' { sim.gen_counter(g.start, g.step, g.modulo) }
		'stepmod' { sim.gen_stepmod(g.period, g.count, g.base) }
		else { sim.gen_const(g.value) }
	}
}
