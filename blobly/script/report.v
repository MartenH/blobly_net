module script

import json2
import math
import strings
import encoding.utf8
import blobly.transport

// The headless runner's exit statuses (cmd/script), stated once; docs/scripting.md lists them.
pub const exit_passed = 0 // every test passed
pub const exit_failed = 1 // a test failed
pub const exit_refused = 2 // bad arguments, or a project that cannot be loaded or started
pub const exit_script_error = 3 // a script raised outside test(), or could not be loaded
pub const exit_timeout = 4 // the run's --timeout passed

// Outcome is what one run of the runner came to: it decides the exit status and the report.
pub struct Outcome {
pub mut:
	refused     string // why the run did not start; '' when it did
	note        string // how a timed-out run was ended, when not by its own close
	project     string
	ms          f64 // the run's wall time
	results     []TestResult
	errors      []ReportError
	timed_out   bool
	timeout_s   f64
	script      string // the script running when the deadline passed
	test        string // the test() it was inside, '' for none
	diagnostics map[string]transport.BusDiagnostics
}

// Report is the --report file. Schema 1; a field is only ever added. docs/scripting.md has it.
pub struct Report {
pub:
	schema        int = 1
	status        string // passed | failed | error | timeout | refused
	exit_code     int
	message       string // why the run was refused, or how a timed-out run was ended; '' otherwise
	project       string
	duration_ms   f64
	counts        ReportCounts
	tests         []ReportTest
	script_errors []ReportError
	timeout       ?ReportTimeout @[omitempty]
	diagnostics   map[string]ReportDiag
}

pub struct ReportCounts {
pub:
	passed        int
	failed        int
	timed_out     int
	script_errors int
}

pub struct ReportTest {
pub:
	name        string
	script      string
	status      string // passed | failed | timeout
	message     string // the failure, '' when it passed
	line        int    // the script line the failure was raised at, 0 when unknown
	duration_ms f64
}

pub struct ReportError {
pub:
	script  string
	message string
}

pub struct ReportTimeout {
pub:
	after_s f64
	script  string
	test    string // '' when the script was outside any test()
}

pub struct ReportDiag {
pub:
	dropped       u64
	bus_errors    u64
	decode_errors u64
}

// exit_code is the runner's exit status for this outcome; the first that applies wins:
// refused, timeout, script error, test failure, passed.
pub fn (o Outcome) exit_code() int {
	if o.refused != '' {
		return exit_refused
	}
	if o.timed_out {
		return exit_timeout
	}
	if o.errors.len > 0 {
		return exit_script_error
	}
	if o.results.any(!it.ok) {
		return exit_failed
	}
	return exit_passed
}

// report is the outcome as the --report record. A test the deadline ended outside its own
// verdict (between test() and its body), when no test took one, is listed as timed out.
pub fn (o Outcome) report() Report {
	mut tests := []ReportTest{}
	mut passed, mut failed, mut timed_out := 0, 0, 0
	for r in o.results {
		status := if r.timed_out {
			'timeout'
		} else if r.ok {
			'passed'
		} else {
			'failed'
		}
		match status {
			'passed' { passed++ }
			'failed' { failed++ }
			else { timed_out++ }
		}
		tests << ReportTest{
			name:        text(r.name)
			script:      text(r.script)
			status:      status
			message:     text(r.msg)
			line:        r.line
			duration_ms: round_ms(r.ms)
		}
	}
	mut timeout := ?ReportTimeout(none)
	if o.timed_out {
		if o.test != '' && !o.results.any(it.timed_out) {
			tests << ReportTest{
				name:    text(o.test)
				script:  text(o.script)
				status:  'timeout'
				message: timeout_note
			}
			timed_out++
		}
		timeout = ReportTimeout{
			after_s: o.timeout_s
			script:  text(o.script)
			test:    text(o.timeout_test())
		}
	}
	mut diags := map[string]ReportDiag{}
	for k, d in o.diagnostics {
		diags[text(k)] = ReportDiag{
			dropped:       d.dropped
			bus_errors:    d.bus_errors
			decode_errors: d.decode_errors
		}
	}
	code := o.exit_code()
	return Report{
		status:        match code {
			exit_passed { 'passed' }
			exit_failed { 'failed' }
			exit_refused { 'refused' }
			exit_timeout { 'timeout' }
			else { 'error' }
		}
		exit_code:     code
		message:       text(if o.refused != '' { o.refused } else { o.note })
		project:       text(o.project)
		duration_ms:   round_ms(o.ms)
		counts:        ReportCounts{
			passed:        passed
			failed:        failed
			timed_out:     timed_out
			script_errors: o.errors.len
		}
		tests:         tests
		script_errors: o.errors.map(ReportError{
			script:  text(it.script)
			message: text(it.message)
		})
		timeout:       timeout
		diagnostics:   diags
	}
}

// timeout_test is the test the deadline ended: the first whose verdict it took (an inner test
// before the tests around it), else the test() the script was inside; '' when outside any test.
pub fn (o Outcome) timeout_test() string {
	for r in o.results {
		if r.timed_out {
			return r.name
		}
	}
	return o.test
}

// json is the report as the --report file holds it.
pub fn (r Report) json() string {
	return json2.encode(r, prettify: true) + '\n'
}

// text is `s` as JSON can carry it: a Lua string may hold any bytes, and one that is not UTF-8
// has each byte above 0x7F written as \xNN.
fn text(s string) string {
	if utf8.validate_str(s) {
		return s
	}
	mut b := strings.new_builder(s.len * 2)
	for c in s.bytes() {
		if c < 0x80 {
			b.write_u8(c)
		} else {
			b.write_string('\\x${c:02X}')
		}
	}
	return b.str()
}

fn round_ms(ms f64) f64 {
	return math.round(ms * 10) / 10
}
