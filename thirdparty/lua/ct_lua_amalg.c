/* ct_lua_amalg.c — single translation unit that builds the whole Lua 5.4 core +
 * standard library compiled INTO the cantester binary (no system liblua, no
 * runtime install). Lua's sources are designed to be #include'd into one TU
 * (this is what upstream's onelua.c does); we list them here ourselves because
 * the 5.4.7 tarball ships no onelua.c. The standalone programs lua.c / luac.c are
 * deliberately omitted — we embed the library, not the interpreter.
 *
 * Build flags (set via V `#flag` in modules/lua/lua.v): -I this dir, -lm, and on
 * Linux -DLUA_USE_LINUX -ldl. LUA_USE_READLINE only affects lua.c (not built),
 * so no readline dependency is pulled in.
 */
/* core */
#include "lzio.c"
#include "lctype.c"
#include "lopcodes.c"
#include "lmem.c"
#include "lundump.c"
#include "ldump.c"
#include "lstate.c"
#include "lgc.c"
#include "llex.c"
#include "lcode.c"
#include "lparser.c"
#include "ldebug.c"
#include "lfunc.c"
#include "lobject.c"
#include "ltm.c"
#include "lstring.c"
#include "ltable.c"
#include "ldo.c"
#include "lvm.c"
#include "lapi.c"

/* standard library */
#include "lauxlib.c"
#include "lbaselib.c"
#include "lcorolib.c"
#include "ldblib.c"
#include "liolib.c"
#include "lmathlib.c"
#include "loadlib.c"
#include "loslib.c"
#include "lstrlib.c"
#include "ltablib.c"
#include "lutf8lib.c"
#include "linit.c"
