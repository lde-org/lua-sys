/*
 * lua_bridge.h — minimal Lua C API declarations for bridge.c.
 *
 * Contains only what bridge.c needs, matching the LuaJIT 2.1 / Lua 5.1 ABI.
 * This avoids a dependency on system luajit-dev packages: lde already embeds
 * LuaJIT and exports all these symbols, so bridge.so resolves them at runtime
 * via the process image without needing -lluajit at link time.
 */

#ifndef LUA_BRIDGE_H
#define LUA_BRIDGE_H

#include <stddef.h>  /* size_t */

/* Opaque Lua state */
typedef struct lua_State lua_State;

/* C function and registry-list types */
typedef int (*lua_CFunction)(lua_State *L);

typedef struct luaL_Reg {
    const char *name;
    lua_CFunction func;
} luaL_Reg;

/* Basic numeric types */
typedef double    lua_Number;
typedef ptrdiff_t lua_Integer;

/* Type tags */
#define LUA_TNIL           0
#define LUA_TBOOLEAN       1
#define LUA_TLIGHTUSERDATA 2
#define LUA_TNUMBER        3
#define LUA_TSTRING        4
#define LUA_TTABLE         5
#define LUA_TFUNCTION      6
#define LUA_TUSERDATA      7
#define LUA_TTHREAD        8

/* Pseudo-indices */
#define LUA_REGISTRYINDEX  (-10000)
#define LUA_ENVIRONINDEX   (-10001)
#define LUA_GLOBALSINDEX   (-10002)

/* luaL_ref sentinels */
#define LUA_NOREF  (-2)
#define LUA_REFNIL (-1)

/* lua_pcall status */
#define LUA_OK      0
#define LUA_MULTRET (-1)

/* Convenience macros (matching LuaJIT / Lua 5.1 definitions) */
#define lua_upvalueindex(i)  (LUA_GLOBALSINDEX - (i))
#define lua_newtable(L)      lua_createtable(L, 0, 0)
#define lua_pop(L, n)        lua_settop(L, -(n) - 1)
#define lua_isnil(L, n)      (lua_type(L, n) == LUA_TNIL)
#define lua_tostring(L, i)   lua_tolstring(L, i, NULL)
#define lua_tointeger(L, i)  ((lua_Integer)lua_tonumber(L, i))

/* On Windows the exe exports these symbols and bridge.c resolves them at
 * load time via GetProcAddress, defining them there as static function
 * pointers with the same names and signatures. The prototypes are hidden
 * so they don't conflict with those pointers. */
#ifndef _WIN32

/* ── Stack ── */
int   lua_gettop   (lua_State *L);
void  lua_settop   (lua_State *L, int idx);
void  lua_pushvalue(lua_State *L, int idx);
void  lua_remove   (lua_State *L, int idx);
void  lua_replace  (lua_State *L, int idx);

/* ── Type inspection ── */
int         lua_type    (lua_State *L, int idx);
const char *lua_typename(lua_State *L, int tp);

/* ── Push ── */
void        lua_pushnil           (lua_State *L);
void        lua_pushboolean       (lua_State *L, int b);
void        lua_pushnumber        (lua_State *L, lua_Number n);
void        lua_pushinteger       (lua_State *L, lua_Integer n);
void        lua_pushlstring       (lua_State *L, const char *s, size_t len);
void        lua_pushstring        (lua_State *L, const char *s);
const char *lua_pushfstring       (lua_State *L, const char *fmt, ...);
void        lua_pushlightuserdata (lua_State *L, void *p);
void        lua_pushcclosure      (lua_State *L, lua_CFunction fn, int n);

/* ── Read ── */
int          lua_toboolean (lua_State *L, int idx);
lua_Number   lua_tonumber  (lua_State *L, int idx);
const char  *lua_tolstring (lua_State *L, int idx, size_t *len);
void        *lua_touserdata(lua_State *L, int idx);

/* ── Table ── */
void lua_createtable(lua_State *L, int narr, int nrec);
void lua_rawgeti    (lua_State *L, int idx, int n);
void lua_rawseti    (lua_State *L, int idx, int n);
void lua_getfield   (lua_State *L, int idx, const char *k);
void lua_setfield   (lua_State *L, int idx, const char *k);
int  lua_objlen     (lua_State *L, int idx);

/* ── Call / error ── */
int  lua_pcall (lua_State *L, int nargs, int nresults, int errfunc);
int  lua_error (lua_State *L);

/* ── State ── */
lua_State *luaL_newstate(void);
void       luaL_openlibs(lua_State *L);
void       lua_close  (lua_State *L);

#endif /* !_WIN32 */

/* ── JIT control ── */
/* luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF/ON) */
#define LUAJIT_MODE_ENGINE  0
#define LUAJIT_MODE_FUNC    2
#define LUAJIT_MODE_OFF     0x0000
#define LUAJIT_MODE_ON      0x0100

#ifndef _WIN32
int luaJIT_setmode(lua_State *L, int idx, int mode);
#endif /* !_WIN32 */

#ifndef _WIN32
/* ── luaL aux ── */
int  luaL_ref      (lua_State *L, int t);
void luaL_unref    (lua_State *L, int t, int ref);
int  luaL_error    (lua_State *L, const char *fmt, ...);
void luaL_checktype(lua_State *L, int narg, int t);
void luaL_register (lua_State *L, const char *libname, const luaL_Reg *l);
#endif /* !_WIN32 */

#endif /* LUA_BRIDGE_H */
