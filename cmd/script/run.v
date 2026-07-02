// cmd/script — the headless script/test runner. It loads a project, brings the
// same engine the GUI uses up (per-channel buses, simulated ECUs + the native
// UDS server — driver-free on the in-process bus), then runs one or more Lua
// test scripts (modules/script) and reports pass/fail. Exits non-zero if any
// test fails, so it drops straight into CI.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v \
//       --project projects/sim-demo.blobnet tests/diag_basic.lua
//
// -enable-globals is required for the in-process bus (transport/inproc.v).
module main

import os
import time
import candb
import project
import transport
import isotp
import uds
import sim
import script

// Ctl is the shared run flag the simulation threads poll; set false to stop them.
struct Ctl {
mut:
	running bool = true
}

fn main() {
	mut proj_path := 'projects/sim-demo.blobnet'
	mut scripts := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--project', '-p' {
				i++
				if i < os.args.len {
					proj_path = os.args[i]
				}
			}
			else {
				scripts << a
			}
		}
		i++
	}
	if scripts.len == 0 {
		eprintln('usage: run [--project <file.blobnet>] <script.lua> [more.lua ...]')
		exit(2)
	}

	proj := project.load(proj_path) or {
		eprintln('cannot load project ${proj_path}: ${err}')
		exit(2)
	}
	println('project: ${proj.name}  (${proj_path})')

	// Build per-channel DBC catalogs + bring the simulation up on every enabled
	// channel that hosts simulated ECUs (exactly like the GUI's Start).
	mut ctl := &Ctl{}
	mut chans := []script.ChanInfo{}
	for ch in proj.channels {
		if !ch.enabled {
			continue
		}
		db := load_channel_db(ch)
		chans << script.ChanInfo{
			name:  ch.name
			iface: ch.iface
			db:    db
		}
		nodes := ch.all_nodes()
		if nodes.len > 0 {
			spawn sim_loop(ch.iface, db, nodes, ctl)
			spawn diag_server_loop(ch.iface, ctl)
			println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s) + UDS server')
		} else {
			println('channel ${ch.name} (${ch.iface}): monitor only')
		}
	}
	// Let the sims start emitting / the UDS server start polling before scripts run.
	time.sleep(150 * time.millisecond)

	mut env := script.new_env(chans) or {
		eprintln('script env init failed: ${err}')
		exit(2)
	}

	mut errored := 0
	for s in scripts {
		println('\n=== ${s} ===')
		env.run_file(s) or {
			eprintln('  ERROR running ${s}: ${err}')
			errored++
		}
	}

	ctl.running = false
	passed := env.passed()
	failed := env.failed()
	env.close()

	println('\n${passed} passed, ${failed} failed, ${errored} script error(s)')
	if failed > 0 || errored > 0 {
		exit(1)
	}
}

// load_channel_db merges every DBC attached to a channel into one catalog (first
// definition of an id wins) — a GUI-free slice of src/main.v's load_databases.
fn load_channel_db(ch project.Channel) candb.Database {
	mut msgs := []candb.Message{}
	mut nodes := []string{}
	mut seen := map[u32]bool{}
	for path in ch.databases {
		db := candb.load_dbc_file(path) or { continue }
		for m in db.messages {
			if m.id !in seen {
				seen[m.id] = true
				msgs << m
			}
		}
		for n in db.nodes {
			if n !in nodes {
				nodes << n
			}
		}
	}
	return candb.Database{
		messages: msgs
		nodes:    nodes
	}
}

// sim_loop runs the channel's simulated ECUs on a dedicated in-process bus
// instance (driver-free twin of src/main.v's sim_loop, minus the GUI).
fn sim_loop(iface string, db candb.Database, nodes []project.NodeCfg, ctl &Ctl) {
	mut bus := transport.open(iface) or { return }
	mut engine := sim.Engine{}
	for n in nodes {
		engine.ecus << build_node(db, n)
	}
	t0 := time.ticks()
	for ctl.running {
		now_ms := f64(time.ticks() - t0)
		for f in engine.due_frames(now_ms) {
			bus.send(f) or {}
		}
		if frame := bus.recv(5) {
			for resp in engine.on_frame(frame) {
				bus.send(resp) or {}
			}
		}
	}
	bus.close()
}

// diag_server_loop answers UDS requests (rx 0x7E0 / tx 0x7E8) over software
// ISO-TP on the channel's bus, until stopped.
fn diag_server_loop(iface string, ctl &Ctl) {
	// Server side: transmit responses on 0x7E8, receive requests on 0x7E0
	// (the mirror of the tester's tx 0x7E0 / rx 0x7E8).
	mut ch := isotp.open_software(iface, 0x7E8, 0x7E0, false) or { return }
	mut srv := uds.default_server()
	for ctl.running {
		req := ch.recv(50) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}

// build_node / gen_of mirror src/main.v: turn a project NodeCfg into a sim.SimEcu.
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
