module lua

fn t_add(l State) i32 {
	l.push_num(l.arg_num(1) + l.arg_num(2))
	return 1
}

fn t_concat(l State) i32 {
	// echoes back the byte string argument prefixed with "got:" — exercises
	// byte-clean string round-tripping across the boundary.
	l.push_str('got:' + l.arg_str(1))
	return 1
}

fn test_run_and_call_host() {
	mut st := new()
	defer { st.close() }
	st.register('add', t_add)
	st.register('concat', t_concat)
	st.do_string('
		assert(add(2, 40) == 42)
		assert(concat("hi") == "got:hi")
		_ok = "yes"
	')!
}

fn test_error_is_surfaced() {
	mut st := new()
	defer { st.close() }
	if _ := st.do_string('error("boom")') {
		assert false, 'expected the Lua error to propagate'
	} else {
		assert err.msg().contains('boom')
	}
}

fn test_byte_clean_payload() {
	// embedded NUL + high bytes must survive the V<->Lua boundary intact.
	mut st := new()
	defer { st.close() }
	st.register('concat', t_concat)
	st.do_string('
		local s = string.char(0, 255, 16)
		assert(#concat(s) == 7)   -- "got:" (4) + 3 bytes
	')!
}

fn t_hook_fail(l State) i32 {
	return l.fail('hook says stop')
}

fn test_count_hook_ends_a_loop() {
	mut st := new()
	defer { st.close() }
	st.set_count_hook(t_hook_fail, 1000)
	if _ := st.do_string('while true do end') {
		assert false, 'an endless loop returned'
	} else {
		assert err.msg().contains('hook says stop')
	}
	st.clear_hook()
	st.do_string('local n = 0 for i = 1, 100000 do n = n + i end')!
}
