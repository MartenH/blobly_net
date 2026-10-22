// cmd/script — the headless script/test runner. It brings a project up through blobly/headless
// (the same engine the GUI uses: per-channel buses, simulated ECUs + the native UDS server —
// driver-free on the in-process bus), then runs one or more Lua test scripts (blobly/script)
// and reports pass/fail. Exits non-zero if any test fails, so it drops straight into CI.
//
//   v -enable-globals run cmd/script/run.v \
//       --project projects/sim-demo.blobnet tests/diag_basic.lua
//
// -enable-globals is required for the in-process bus (transport/inproc.v).
module main

import os
import blobly.headless
import blobly.player
import blobly.script

fn main() {
	// a run() on several channels sleeps a 1 ms slice between looks, which is the 15.6 ms
	// default quantum on Windows unless raised (a no-op elsewhere)
	player.raise_timer_resolution()
	mut proj_path := 'projects/sim-demo.blobnet'
	mut explicit := '' // --project as given, distinct from the default above
	mut project_ports := false // --project-ports: host DoIP entities on the ports the project states
	mut scripts := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--project', '-p' {
				i++
				if i < os.args.len {
					explicit = os.args[i]
					proj_path = explicit
				}
			}
			'--project-ports' {
				project_ports = true
			}
			else {
				scripts << a
			}
		}

		i++
	}
	if scripts.len == 0 {
		eprintln('usage: run [--project <file.blobnet>] [--project-ports] <script.lua> [more.lua ...]')
		exit(2)
	}

	// A test that needs a particular project says so in its own head; script.agree decides what
	// that means here, and refuses a run it cannot make true rather than producing failures that
	// read as broken features (#115). See blobly/script/project_decl.v.
	mut decls := []script.Decl{}
	for s in scripts {
		if d := script.declaration_of(s) {
			decls << d
		}
	}
	chosen := script.agree(decls, explicit) or {
		eprintln('cannot decide which project to run: ${err}')
		exit(2)
	}
	if chosen != '' {
		proj_path = chosen
	}

	// A project that cannot be read is a usage error (2); one that loads and is refused — a wire
	// asked to be two things, an entity that cannot bind — is a run that did not start (1).
	proj := headless.load(proj_path, headless.Options{}) or {
		eprintln(err.msg())
		exit(2)
	}
	mut run := headless.start(proj, proj_path, headless.Options{ project_ports: project_ports }) or {
		eprintln(err.msg())
		exit(1)
	}

	mut chans := []script.ChanInfo{}
	for c in run.chans {
		chans << script.ChanInfo{
			name:      c.cfg.name
			// what a script OPENS with — carries the vendor bitrate
			iface:     c.cfg.iface_with_bitrate()
			// what faults are KEYED on — the logical interface, no suffix
			key_iface: c.cfg.iface
			db:        c.db
			nodes:     c.cfg.all_nodes() // so a fault that cannot take effect can be refused
			carrier:   script.carrier_of(c.cfg)
		}
	}
	mut env := script.new_env(chans) or {
		eprintln('script env init failed: ${err}')
		run.stop()
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

	// Joined BEFORE the script's buses are asked: a responder that fell behind books its gap
	// at its close, into the wire, where the script's own handle then reads it.
	run.stop()
	// And what the script's own buses and connections counted (#213). EACH HANDLE REPORTS
	// ITSELF, here and in the loops above at their close: on a shared wire every handle answers
	// with the wire's totals, reconciled for every subscriber at the asking; on a backend that
	// fans out natively each handle counts what it consumed. A separate reporting handle was
	// tried and was wrong both ways -- it had to drain to see anything on the one kind and
	// was itself a dropping subscriber on the other (codex rounds 8-11 on #231).
	for name, d in env.close_reporting() {
		eprintln('${name}: ${d.str()}')
	}
	passed := env.passed()
	failed := env.failed()

	println('\n${passed} passed, ${failed} failed, ${errored} script error(s)')
	if failed > 0 || errored > 0 {
		exit(1)
	}
}
