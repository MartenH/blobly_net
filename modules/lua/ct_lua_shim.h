/* ct_lua_shim.h — flat C wrappers over Lua 5.4's API so V can call it. Much of
 * Lua's public API is C MACROS (lua_pcall, lua_pushcfunction, lua_setglobal,
 * lua_tostring, luaL_dostring, lua_pop, lua_getextraspace, …), and V's `fn C.x`
 * can only bind real symbols — so we expose static-inline functions with stable
 * names, exactly like socketcan_shim.h does for the SocketCAN macros. V calls
 * only these `ctlua_*` helpers; it never needs the Lua headers directly.
 */
#ifndef BLOBLY_LUA_SHIM_H
#define BLOBLY_LUA_SHIM_H

#include <string.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

/* A C function exposed to Lua: receives the state, returns #results on the stack. */
typedef int (*ctlua_CFunction)(lua_State *L);

/* ---- lifecycle ---- */
static inline lua_State *ctlua_new(void) {
	lua_State *L = luaL_newstate();
	if (L) luaL_openlibs(L);
	return L;
}
static inline void ctlua_close(lua_State *L) { if (L) lua_close(L); }

/* ---- run code. Returns 0 on success, or the Lua error code; on error the error
 * message string is left on top of the stack (read with ctlua_tostring(L,-1)). ---- */
static inline int ctlua_dostring(lua_State *L, const char *src) {
	return luaL_dostring(L, src);
}
static inline int ctlua_dofile(lua_State *L, const char *path) {
	return luaL_dofile(L, path);
}
/* load (compile) without running; 0 on success, else error on stack. */
static inline int ctlua_loadstring(lua_State *L, const char *src) {
	return luaL_loadstring(L, src);
}
/* protected call of a function already on the stack with nargs args. */
static inline int ctlua_pcall(lua_State *L, int nargs, int nresults) {
	return lua_pcall(L, nargs, nresults, 0);
}

/* ---- context pointer: stash a host pointer in the state's extra space so the
 * C functions we register can reach the V-side ScriptEnv. ---- */
static inline void ctlua_set_ctx(lua_State *L, void *p) {
	*((void **)lua_getextraspace(L)) = p;
}
static inline void *ctlua_get_ctx(lua_State *L) {
	return *((void **)lua_getextraspace(L));
}

/* ---- registering host functions ---- */
static inline void ctlua_register(lua_State *L, const char *name, ctlua_CFunction fn) {
	lua_pushcfunction(L, fn);
	lua_setglobal(L, name);
}

/* ---- stack push/get used by both host glue and registered C functions ---- */
static inline void ctlua_push_int(lua_State *L, long long v) { lua_pushinteger(L, (lua_Integer)v); }
static inline void ctlua_push_num(lua_State *L, double v)    { lua_pushnumber(L, (lua_Number)v); }
static inline void ctlua_push_bool(lua_State *L, int v)      { lua_pushboolean(L, v); }
static inline void ctlua_push_nil(lua_State *L)              { lua_pushnil(L); }
/* push a byte string of explicit length (payloads are not NUL-terminated). */
static inline void ctlua_push_lstr(lua_State *L, const char *s, int n) { lua_pushlstring(L, s, (size_t)n); }
static inline void ctlua_setglobal(lua_State *L, const char *name)     { lua_setglobal(L, name); }
static inline void ctlua_getglobal(lua_State *L, const char *name)     { lua_getglobal(L, name); }

static inline int  ctlua_gettop(lua_State *L)        { return lua_gettop(L); }
static inline void ctlua_settop(lua_State *L, int n) { lua_settop(L, n); }
static inline void ctlua_pop(lua_State *L, int n)    { lua_pop(L, n); }

/* argument readers for registered C functions (1-based index). */
static inline long long ctlua_to_int(lua_State *L, int i)  { return (long long)lua_tointegerx(L, i, NULL); }
static inline double    ctlua_to_num(lua_State *L, int i)  { return (double)lua_tonumberx(L, i, NULL); }
static inline int       ctlua_to_bool(lua_State *L, int i) { return lua_toboolean(L, i); }
static inline int       ctlua_is_num(lua_State *L, int i)  { return lua_isnumber(L, i); }
static inline int       ctlua_is_str(lua_State *L, int i)  { return lua_isstring(L, i); }
static inline int       ctlua_is_nil(lua_State *L, int i)  { return lua_isnil(L, i); }
/* returns the string pointer + writes its length to *len (byte-clean). */
static inline const char *ctlua_to_lstr(lua_State *L, int i, int *len) {
	size_t n = 0;
	const char *s = lua_tolstring(L, i, &n);
	if (len) *len = (int)n;
	return s;
}

/* ---- table building (for returning maps like decode() -> {Signal=value}) ----
 * Push a fresh table, then set fields on the table currently at the stack top. */
static inline void ctlua_newtable(lua_State *L) { lua_newtable(L); }
static inline void ctlua_setfield_num(lua_State *L, const char *k, double v) {
	lua_pushnumber(L, (lua_Number)v);
	lua_setfield(L, -2, k);
}
static inline void ctlua_setfield_str(lua_State *L, const char *k, const char *s, int n) {
	lua_pushlstring(L, s, (size_t)n);
	lua_setfield(L, -2, k);
}

/* raise a Lua error with the given message (does not return). */
static inline int ctlua_error(lua_State *L, const char *msg) {
	lua_pushstring(L, msg);
	return lua_error(L);
}

#endif /* BLOBLY_LUA_SHIM_H */
