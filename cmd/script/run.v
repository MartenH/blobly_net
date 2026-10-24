// cmd/script — the headless script/test runner. It brings a project up through blobly/headless
// (the same engine the GUI uses: per-channel buses, simulated ECUs + the native UDS server —
// driver-free on the in-process bus), then runs one or more Lua test scripts (blobly/script)
// and reports pass/fail. Its exit status (script.exit_*) and its --report file are what CI and an
// agent read; docs/scripting.md states both.
//
//   v -enable-globals run cmd/script/run.v \
//       --project projects/sim-demo.blobnet [--report run.json] [--timeout 60] tests/diag_basic.lua
//
// -enable-globals is required for the in-process bus (transport/inproc.v).
module main

import math
import os
import strconv
import sync
import time
import blobly.headless
import blobly.player
import blobly.project
import blobly.script
import blobly.udsconn

const usage = 'usage: run [--project <file.blobnet>] [--project-ports] [--report <file.json>] [--timeout <s>] <script.lua> [more.lua ...]'

// how long after its deadline a run that has not ended is exited by the watchdog: past the
// longest host call the deadline does not cut, a DoIP connection being opened
const watchdog_grace = udsconn.doip_open_ms * time.millisecond + 3 * time.second

// Watch is what the watchdog reads: the script running, and whether the run has ended.
struct Watch {
mut:
	mu     sync.Mutex
	ended  bool
	script string
}

fn main() {
	// a run() on several channels sleeps a 1 ms slice between looks, which is the 15.6 ms
	// default quantum on Windows unless raised (a no-op elsewhere)
	player.raise_timer_resolution()
	t0 := time.sys_mono_now()
	mut o := script.Outcome{}
	mut w := &Watch{}
	report_path := run(mut o, mut w, t0)
	w.mu.lock()
	w.ended = true
	w.mu.unlock()
	o.ms = f64(time.sys_mono_now() - t0) / 1_000_000.0
	if o.refused != '' {
		eprintln(o.refused)
	}
	code := o.exit_code()
	if report_path != '' {
		os.write_file(report_path, o.report().json()) or {
			eprintln('cannot write the report ${report_path}: ${err}')
			// the run's own verdict stands; a pass whose record is missing is not one
			exit(if code == script.exit_passed { script.exit_refused } else { code })
		}
	}
	exit(code)
}

// watchdog exits a run still going `watchdog_grace` after its deadline, which the deadline could
// not end (a Lua finalizer, a script's own debug hook, a host call that does not return): the
// report says so, and the buses are left to the process exit.
fn watchdog(mut w Watch, o script.Outcome, report_path string, t0 u64, after time.Duration) {
	time.sleep(after + watchdog_grace)
	w.mu.lock()
	if w.ended {
		w.mu.unlock()
		return
	}
	mut late := script.Outcome{
		project:   o.project
		ms:        f64(time.sys_mono_now() - t0) / 1_000_000.0
		timed_out: true
		timeout_s: o.timeout_s
		script:    w.script
		note:      'the run did not end within ${watchdog_grace} of its deadline; exited without closing its buses'
	}
	eprintln('  TIMEOUT: ${late.note}')
	if report_path != '' {
		os.write_file(report_path, late.report().json()) or {
			eprintln('cannot write the report ${report_path}: ${err}')
		}
	}
	exit(script.exit_timeout)
}

// run is one run of the runner into `o`; it answers the --report path ('' for none).
fn run(mut o script.Outcome, mut w Watch, t0 u64) string {
	mut proj_path := 'projects/sim-demo.blobnet'
	mut explicit := '' // --project as given, distinct from the default above
	mut project_ports := false // --project-ports: host DoIP entities on the ports the project states
	// found first, so a refusal of any other argument is reported too
	mut report_path := ''
	mut report_given := false
	for k := 1; k < os.args.len; k++ {
		if os.args[k] in ['--project', '-p', '--report', '--timeout'] && k + 1 < os.args.len {
			if os.args[k] == '--report' {
				report_path = os.args[k + 1]
				report_given = true
			}
			k++
		}
	}
	if report_given && report_path == '' {
		o.refused = '--report names no file'
		return report_path
	}
	mut timeout_s := 0.0
	mut scripts := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--project', '-p', '--report', '--timeout' {
				i++
				if i >= os.args.len {
					o.refused = '${a} needs a value\n${usage}'
					return report_path
				}
				v := os.args[i]
				if a == '--timeout' {
					timeout_s = strconv.atof64(v) or { -1.0 }
					// also refuses nan, and more than one Windows sleep can wait (49 days)
					if !(timeout_s > 0 && timeout_s <= 1e6) {
						o.refused = '--timeout ${v}: not a number of seconds above 0, up to 1000000'
						return report_path
					}
					o.timeout_s = timeout_s
				} else if a != '--report' {
					explicit = v
					proj_path = explicit
				}
			}
			'--project-ports' {
				project_ports = true
			}
			else {
				if a.starts_with('-') {
					o.refused = 'unknown option ${a}\n${usage}'
					return report_path
				}
				scripts << a
			}
		}

		i++
	}
	if scripts.len == 0 {
		o.refused = usage
		return report_path
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
		o.refused = 'cannot decide which project to run: ${err}'
		return report_path
	}
	if chosen != '' {
		proj_path = chosen
	}
	o.project = proj_path

	proj := headless.load(proj_path, headless.Options{}) or {
		o.refused = err.msg()
		return report_path
	}
	mut hrun := headless.start(proj, proj_path, headless.Options{ project_ports: project_ports }) or {
		o.refused = err.msg()
		return report_path
	}

	mut chans := []script.ChanInfo{}
	rows := hrun.chans.map(it.cfg)
	for c in hrun.chans {
		nominal, data_rate := project.wire_rates(rows, c.cfg.iface_with_bitrate()) or {
			c.cfg.nominal_bitrate(), 0
		}
		chans << script.ChanInfo{
			name:      c.cfg.name
			// what a script OPENS with — carries the vendor bitrate
			iface:     c.cfg.iface_with_bitrate()
			// what faults are KEYED on — the logical interface, no suffix
			key_iface: c.cfg.iface
			db:        c.db
			nodes:     c.cfg.all_nodes() // so a fault that cannot take effect can be refused
			hosts:     c.cfg.hosts_doip_entity()
			verify:    c.cfg.verify // what a received frame's E2E is judged by first
			carrier:   script.carrier_of(c.cfg)
			nominal:   nominal
			data_rate: data_rate
			replay:    c.replay_cfg(os.dir(hrun.path))
		}
	}
	mut env := script.new_env(chans) or {
		hrun.stop()
		o.errors << script.ReportError{
			message: 'script env init failed: ${err}'
		}
		eprintln(o.errors.last().message)
		return report_path
	}
	env.gens = hrun
	env.sys = hrun.sys
	if timeout_s > 0 {
		after_ms := i64(math.ceil(timeout_s * 1000))
		env.set_deadline(after_ms)
		spawn watchdog(mut w, o, report_path, t0, after_ms * time.millisecond)
	}

	for s in scripts {
		println('\n=== ${s} ===')
		w.mu.lock()
		w.script = s
		w.mu.unlock()
		mut failure := ''
		env.run_file(s) or { failure = err.msg() }
		// what this script left playing or recording ends with it; a recording that failed is its error
		for e in env.stop_replays() {
			failure = if failure == '' { e } else { '${failure}; ${e}' }
		}
		if env.expired() {
			o.timed_out = true
			o.script = s
			o.test = env.running_test()
			o.results = env.results
			t := o.timeout_test()
			eprintln('  TIMEOUT after ${timeout_s} s in ${s}${if t == '' { '' } else { ', test "${t}"' }}')
			break
		}
		if failure != '' {
			eprintln('  ERROR running ${s}: ${failure}')
			o.errors << script.ReportError{
				script:  s
				message: failure
			}
		}
	}

	// Joined BEFORE the script's buses are asked: a responder that fell behind books its gap
	// at its close, into the wire, where the script's own handle then reads it.
	hrun.stop()
	// And what the script's own buses and connections counted (#213). EACH HANDLE REPORTS
	// ITSELF, here and in the loops above at their close: on a shared wire every handle answers
	// with the wire's totals, reconciled for every subscriber at the asking; on a backend that
	// fans out natively each handle counts what it consumed. A separate reporting handle was
	// tried and was wrong both ways -- it had to drain to see anything on the one kind and
	// was itself a dropping subscriber on the other (codex rounds 8-11 on #231).
	o.diagnostics = env.close_reporting()
	for name, d in o.diagnostics {
		eprintln('${name}: ${d.str()}')
	}
	o.results = env.results

	println('\n${env.passed()} passed, ${env.failed()} failed, ${o.errors.len} script error(s)${if o.timed_out { ', timed out' } else { '' }}')
	return report_path
}
