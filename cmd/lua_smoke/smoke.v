// lua_smoke — verify the embedded Lua 5.4 builds, runs a script, and can call a
// host function registered from V. No GUI, no bus; just proves modules/lua.
//   v -path "@vlib|@vmodules|modules" run cmd/lua_smoke/smoke.v
module main

import lua

// a host function exposed to Lua as add(a, b) -> a+b
fn l_add(l lua.State) int {
	a := l.arg_num(1)
	b := l.arg_num(2)
	l.push_num(a + b)
	return 1
}

fn main() {
	mut st := lua.new()
	defer { st.close() }
	st.register('add', l_add)

	st.do_string('
		print("hello from Lua " .. _VERSION)
		local s = add(2, 40)
		assert(s == 42, "host add broken: " .. s)
		print("add(2,40) =", s)
	') or {
		eprintln('lua error: ${err}')
		exit(1)
	}
	println('lua_smoke OK')
}
