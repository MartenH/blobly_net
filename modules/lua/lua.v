// lua — a thin, typed V facade over an embedded Lua 5.4 interpreter. The Lua
// core + standard library are compiled directly into the binary from vendored
// source (thirdparty/lua, via ct_lua_amalg.c) — no system liblua, no runtime
// install — matching the project's "fresh box builds from git alone" principle.
//
// The fiddly bits (Lua's macro-based C API) live in ct_lua_shim.h as flat
// `ctlua_*` functions, the same pattern transport/socketcan_shim.h uses. This
// module is GUI-free and protocol-free: it only knows how to run Lua code and
// move scalars/strings across the boundary. The cantester scripting API (diag,
// bus, signals, the test framework) is layered on top in modules/script.
module lua

#flag -I@VMODROOT/thirdparty/lua
#flag @VMODROOT/thirdparty/lua/ct_lua_amalg.c
// -lm/-ldl are GCC/Unix linker flags (libm, libdl) — Linux only. On Windows the
// math fns live in the CRT and there's no dlopen, and MSVC's linker rejects -l*.
#flag linux -lm
#flag linux -ldl
#flag linux -DLUA_USE_LINUX
#include "ct_lua_shim.h"

// Opaque Lua interpreter handle (a `lua_State *`).
struct C.lua_State {
}

fn C.ctlua_new() &C.lua_State
fn C.ctlua_close(&C.lua_State)
fn C.ctlua_dostring(&C.lua_State, &char) int
fn C.ctlua_dofile(&C.lua_State, &char) int
fn C.ctlua_loadstring(&C.lua_State, &char) int
fn C.ctlua_pcall(&C.lua_State, int, int) int
fn C.ctlua_set_ctx(&C.lua_State, voidptr)
fn C.ctlua_get_ctx(&C.lua_State) voidptr
fn C.ctlua_register(&C.lua_State, &char, CFn)
fn C.ctlua_push_int(&C.lua_State, i64)
fn C.ctlua_push_num(&C.lua_State, f64)
fn C.ctlua_push_bool(&C.lua_State, int)
fn C.ctlua_push_nil(&C.lua_State)
fn C.ctlua_push_lstr(&C.lua_State, &char, int)
fn C.ctlua_getglobal(&C.lua_State, &char)
fn C.ctlua_gettop(&C.lua_State) int
fn C.ctlua_settop(&C.lua_State, int)
fn C.ctlua_pop(&C.lua_State, int)
fn C.ctlua_to_int(&C.lua_State, int) i64
fn C.ctlua_to_num(&C.lua_State, int) f64
fn C.ctlua_to_bool(&C.lua_State, int) int
fn C.ctlua_is_num(&C.lua_State, int) int
fn C.ctlua_is_str(&C.lua_State, int) int
fn C.ctlua_is_nil(&C.lua_State, int) int
fn C.ctlua_to_lstr(&C.lua_State, int, &int) &char
fn C.ctlua_error(&C.lua_State, &char) int
fn C.ctlua_newtable(&C.lua_State)
fn C.ctlua_setfield_num(&C.lua_State, &char, f64)
fn C.ctlua_setfield_str(&C.lua_State, &char, &char, int)

// State is a V handle to a Lua interpreter.
pub type State = &C.lua_State

// CFn is a host function callable from Lua: it receives the state and returns
// the number of results it left on the stack. Use the `arg_*`/`push_*` helpers
// below to read arguments and return values.
pub type CFn = fn (l State) int

// new creates a fresh interpreter with the standard libraries opened.
pub fn new() State {
	return State(C.ctlua_new())
}

// close destroys the interpreter and frees all its memory.
pub fn (l State) close() {
	C.ctlua_close(l)
}

// set_ctx stashes a host pointer (e.g. a &ScriptEnv) so registered functions can
// reach it via get_ctx(); the pointer is NOT GC-tracked, so keep it alive on the
// V side for the interpreter's lifetime.
pub fn (l State) set_ctx(p voidptr) {
	C.ctlua_set_ctx(l, p)
}

// get_ctx returns the pointer stashed by set_ctx (null if none).
pub fn (l State) get_ctx() voidptr {
	return C.ctlua_get_ctx(l)
}

// register binds a host function as a Lua global.
pub fn (l State) register(name string, f CFn) {
	C.ctlua_register(l, &char(name.str), f)
}

// do_string compiles and runs `src`; the error carries Lua's message on failure.
pub fn (l State) do_string(src string) ! {
	if C.ctlua_dostring(l, &char(src.str)) != 0 {
		return error(l.pop_error())
	}
}

// do_file compiles and runs the file at `path`.
pub fn (l State) do_file(path string) ! {
	if C.ctlua_dofile(l, &char(path.str)) != 0 {
		return error(l.pop_error())
	}
}

// call_global calls the global function `name` with no arguments (used to invoke
// a script entry point after loading a prelude + the user script).
pub fn (l State) call_global(name string) ! {
	C.ctlua_getglobal(l, &char(name.str))
	if C.ctlua_pcall(l, 0, 0) != 0 {
		return error(l.pop_error())
	}
}

// pop_error reads and pops the error string left on the stack top.
fn (l State) pop_error() string {
	msg := l.arg_str(-1)
	C.ctlua_pop(l, 1)
	return if msg == '' { 'lua error' } else { msg }
}

// ---- argument readers (1-based, as Lua indexes function arguments) ----

pub fn (l State) arg_int(i int) i64 {
	return C.ctlua_to_int(l, i)
}

pub fn (l State) arg_num(i int) f64 {
	return C.ctlua_to_num(l, i)
}

pub fn (l State) arg_bool(i int) bool {
	return C.ctlua_to_bool(l, i) != 0
}

pub fn (l State) arg_is_nil(i int) bool {
	return C.ctlua_is_nil(l, i) != 0
}

pub fn (l State) arg_is_num(i int) bool {
	return C.ctlua_is_num(l, i) != 0
}

// arg_str copies the (byte-clean) string/byte argument at `i` into a V string.
pub fn (l State) arg_str(i int) string {
	mut n := 0
	p := C.ctlua_to_lstr(l, i, &n)
	if p == unsafe { nil } || n <= 0 {
		return ''
	}
	return unsafe { (&u8(p)).vbytes(n).bytestr() }
}

// arg_bytes copies the byte payload at `i` into a []u8 (CAN/UDS data).
pub fn (l State) arg_bytes(i int) []u8 {
	mut n := 0
	p := C.ctlua_to_lstr(l, i, &n)
	if p == unsafe { nil } || n <= 0 {
		return []u8{}
	}
	return unsafe { (&u8(p)).vbytes(n).clone() }
}

pub fn (l State) nargs() int {
	return C.ctlua_gettop(l)
}

// ---- result pushers ----

pub fn (l State) push_int(v i64) {
	C.ctlua_push_int(l, v)
}

pub fn (l State) push_num(v f64) {
	C.ctlua_push_num(l, v)
}

pub fn (l State) push_bool(v bool) {
	C.ctlua_push_bool(l, if v { 1 } else { 0 })
}

pub fn (l State) push_nil() {
	C.ctlua_push_nil(l)
}

pub fn (l State) push_str(s string) {
	C.ctlua_push_lstr(l, &char(s.str), s.len)
}

// push_bytes pushes a raw byte payload as a Lua (byte-clean) string.
pub fn (l State) push_bytes(b []u8) {
	C.ctlua_push_lstr(l, &char(b.data), b.len)
}

// fail raises a Lua error from a host function (does not return on the Lua side).
pub fn (l State) fail(msg string) int {
	return C.ctlua_error(l, &char(msg.str))
}

// ---- table building: push_table() then set fields on the top-of-stack table ----

pub fn (l State) new_table() {
	C.ctlua_newtable(l)
}

pub fn (l State) set_num(key string, v f64) {
	C.ctlua_setfield_num(l, &char(key.str), v)
}

pub fn (l State) set_str(key string, v string) {
	C.ctlua_setfield_str(l, &char(key.str), &char(v.str), v.len)
}
