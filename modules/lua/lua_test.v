module lua

fn t_add(l State) int {
	l.push_num(l.arg_num(1) + l.arg_num(2))
	return 1
}

fn t_concat(l State) int {
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
