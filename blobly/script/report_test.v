module script

import os
import time

fn test_exit_code_precedence() {
	fail := TestResult{
		name: 'f'
	}
	ok := TestResult{
		name: 'p'
		ok:   true
	}
	assert Outcome{}.exit_code() == exit_passed
	assert Outcome{
		results: [ok]
	}.exit_code() == exit_passed
	assert Outcome{
		results: [ok, fail]
	}.exit_code() == exit_failed
	err := ReportError{
		script:  's.lua'
		message: 'boom'
	}
	assert Outcome{
		results: [fail]
		errors:  [err]
	}.exit_code() == exit_script_error
	assert Outcome{
		results:   [fail]
		errors:    [err]
		timed_out: true
	}.exit_code() == exit_timeout
	assert Outcome{
		refused:   'no project'
		timed_out: true
	}.exit_code() == exit_refused
}

fn test_report_counts_and_names_the_timed_out_test() {
	o := Outcome{
		project:   'p.blobnet'
		timed_out: true
		timeout_s: 2
		script:    'a.lua'
		results:   [
			TestResult{
				name:   'one'
				ok:     true
				script: 'a.lua'
				ms:     1.26
			},
			TestResult{
				name:   'two'
				msg:    'a.lua:4: no'
				script: 'a.lua'
				line:   4
			},
			TestResult{
				name:      'three'
				msg:       timeout_note
				script:    'a.lua'
				timed_out: true
			},
		]
	}
	r := o.report()
	assert r.status == 'timeout'
	assert r.exit_code == exit_timeout
	assert r.counts == ReportCounts{
		passed:    1
		failed:    1
		timed_out: 1
	}
	assert r.tests.map(it.status) == ['passed', 'failed', 'timeout']
	assert r.tests[0].duration_ms == 1.3
	assert r.tests[1].line == 4
	t := r.timeout or { panic('no timeout record') }
	assert t.test == 'three' && t.script == 'a.lua' && t.after_s == 2
	assert Outcome{
		script:  'b.lua'
		results: [TestResult{
			name:      'begun in a'
			script:    'a.lua'
			timed_out: true
		}]
	}.timeout_script() == 'a.lua'
	// the first timed-out verdict is the test the deadline ended: an inner one reports first
	assert Outcome{
		timed_out: true
		results:   [TestResult{
			name:      'inner'
			timed_out: true
		}, TestResult{
			name:      'outer'
			timed_out: true
		}]
	}.timeout_test() == 'inner'
	assert r.json().contains('"timeout": {')
	assert !Outcome{}.report().json().contains('"timeout"')
}

// A test the deadline ended before its body caught it has no verdict of its own: it is listed.
fn test_report_lists_a_test_left_without_a_verdict() {
	r := Outcome{
		timed_out: true
		script:    'a.lua'
		test:      'stuck'
	}.report()
	assert r.tests.len == 1
	assert r.tests[0].name == 'stuck' && r.tests[0].status == 'timeout'
	assert r.counts.timed_out == 1
}

fn script_file(name string, src string) string {
	dir := os.join_path(os.temp_dir(), 'blobly_report_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	p := os.join_path(dir, name)
	os.write_file(p, src) or { panic(err) }
	return p
}

fn test_failure_line_is_the_scripts() {
	p := script_file('line.lua', 'local function helper()\n  check.equal(1, 2)\nend\ntest("t", function()\n  helper()\nend)\ntest("u", function() error("x") end)\n')
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.run_file(p)!
	assert env.results.len == 2
	assert env.results[0].line == 2
	assert env.results[0].script == p
	assert env.results[1].line == 7
	assert !env.results[0].timed_out
}

fn test_deadline_ends_a_spinning_test_and_the_script() {
	p := script_file('spin.lua', 'test("a", function() end)\ntest("spin", function()\n  while true do end\nend)\ntest("never", function() end)\n')
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.set_deadline(200)
	t0 := time.sys_mono_now()
	env.run_file(p) or { assert err.msg().contains(timeout_note) }
	assert time.sys_mono_now() - t0 < 2 * time.second
	assert env.expired()
	assert env.results.map(it.name) == ['a', 'spin']
	assert env.results[1].timed_out && !env.results[1].ok
	assert env.results[1].line == 3
}

fn test_deadline_cuts_a_sleep() {
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.set_deadline(100)
	t0 := time.sys_mono_now()
	env.run_source('test("sleeps", function() sleep_ms(60000) end)') or {}
	assert time.sys_mono_now() - t0 < 2 * time.second
	assert env.results.len == 1 && env.results[0].timed_out
}

// A timeout the test caught itself is still the test's timeout, and no test starts after it.
fn test_a_caught_timeout_is_still_one() {
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.set_deadline(100)
	env.run_source('test("catches", function() pcall(function() sleep_ms(60000) end) end)') or {}
	env.run_source('test("late", function() end)') or {}
	assert env.results.len == 1
	assert env.results[0].timed_out && env.results[0].msg == timeout_note
}

fn test_report_text_is_utf8() {
	assert json_text('Grüße') == 'Grüße'
	assert json_text('a\xffb') == 'a\\xFFb'
}

// A loop that catches every error still ends at the deadline.
fn test_a_catching_loop_ends_at_the_deadline() {
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.set_deadline(100)
	t0 := time.sys_mono_now()
	env.run_source('test("swallows", function() while true do pcall(function() while true do end end) end end)') or {}
	assert time.sys_mono_now() - t0 < 2 * time.second
	assert env.results.len == 1 && env.results[0].timed_out
}

// An xpcall whose handler would never return ends at the deadline too.
fn test_an_xpcall_handler_does_not_hold_the_deadline() {
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.set_deadline(100)
	t0 := time.sys_mono_now()
	env.run_source('test("x", function() xpcall(function() while true do end end, function() while true do end end) end)') or {}
	assert time.sys_mono_now() - t0 < 2 * time.second
	assert env.results.len == 1 && env.results[0].timed_out
}

// Tests in two coroutines that end out of order each keep their own start.
fn test_tests_in_coroutines_keep_their_own_durations() {
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.run_source('
		local a = coroutine.create(function() test("a", function() coroutine.yield() end) end)
		local b = coroutine.create(function() test("b", function() coroutine.yield() end) end)
		coroutine.resume(a)
		sleep_ms(150)
		coroutine.resume(b)
		coroutine.resume(a)
		coroutine.resume(b)
	')!
	assert env.results.map(it.name) == ['a', 'b']
	assert env.results[0].ms >= 140
	assert env.results[1].ms < 100
}

// A test that returned a value past the deadline ends the script with the timeout, not the value.
fn test_a_returned_value_is_not_the_timeout_message() {
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.set_deadline(50)
	env.run_source('test("outer", function() test("inner", function() os.execute("sleep 0.2") return "all good" end) end)') or {
		assert err.msg().contains(timeout_note)
	}
	assert env.results.map(it.msg) == [timeout_note, timeout_note]
}

// A test suspended in a coroutine is not the one a deadline reached elsewhere ended.
fn test_a_suspended_test_is_not_the_timed_out_one() {
	mut env := new_env([]) or { panic(err) }
	defer {
		env.close()
	}
	env.set_deadline(100)
	env.run_source('
		local c = coroutine.create(function() test("suspended", function() coroutine.yield() end) end)
		coroutine.resume(c)
		while true do end
	') or {}
	assert env.running_test() == ''
	mut env2 := new_env([]) or { panic(err) }
	defer {
		env2.close()
	}
	env2.set_deadline(100)
	env2.run_source('
		local c = coroutine.create(function() test("suspended", function() coroutine.yield() end) end)
		coroutine.resume(c)
		test("active", function() while true do end end)
	') or {}
	assert env2.results.map(it.name) == ['active']
	assert Outcome{
		timed_out: true
		test:      env2.running_test()
		results:   env2.results
	}.timeout_test() == 'active'
}
