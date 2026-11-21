/*
 * lua_bridge.h — minimal Lua C API types and macros for bridge.c.
 *
 * Contains only what bridge.c needs, matching the LuaJIT 2.1 / Lua 5.1 ABI.
 * The functions themselves are not declared here: bridge.c resolves every
 * lua_* from the LuaJIT that loads it (see bridge_resolve_symbols), so it
 * needs neither luajit-dev headers nor -lluajit.
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

/* Debug interface (LuaJIT / Lua 5.1 ABI) */
#define LUA_IDSIZE 60

#define LUA_HOOKCALL   0
#define LUA_HOOKRET    1
#define LUA_HOOKLINE   2
#define LUA_HOOKCOUNT  3
#define LUA_HOOKTAILCALL 4

#define LUA_MASKCALL  (1 << LUA_HOOKCALL)
#define LUA_MASKRET   (1 << LUA_HOOKRET)
#define LUA_MASKLINE  (1 << LUA_HOOKLINE)
#define LUA_MASKCOUNT (1 << LUA_HOOKCOUNT)

typedef struct lua_Debug {
  int event;                 /* (hook) */
  const char *name;          /* (n) */
  const char *namewhat;      /* (n) */
  const char *what;          /* (S) */
  const char *source;        /* (S) */
  int currentline;           /* (l) */
  int nups;                  /* (u) */
  int linedefined;           /* (S) */
  int lastlinedefined;       /* (S) */
  char short_src[LUA_IDSIZE];/* (S) */
  int i_ci;                  /* private part */
} lua_Debug;

typedef void (*lua_Hook)(lua_State *L, lua_Debug *ar);

/* The allocator callback type: shared by both builds. The Windows symbol
 * table in bridge.c names it in the lua_newstate signature, and the POSIX
 * prototypes below use it too. */
typedef void *(*lua_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);

/* Convenience macros (matching LuaJIT / Lua 5.1 definitions) */
#define lua_upvalueindex(i)  (LUA_GLOBALSINDEX - (i))
#define lua_newtable(L)      lua_createtable(L, 0, 0)
#define lua_pop(L, n)        lua_settop(L, -(n) - 1)
#define lua_isnil(L, n)      (lua_type(L, n) == LUA_TNIL)
#define lua_tostring(L, i)   lua_tolstring(L, i, NULL)
#define lua_tointeger(L, i)  ((lua_Integer)lua_tonumber(L, i))

/* ── JIT control ── */
/* luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF/ON/FLUSH) */
#define LUAJIT_MODE_ENGINE  0
#define LUAJIT_MODE_FUNC    2
#define LUAJIT_MODE_OFF     0x0000
#define LUAJIT_MODE_ON      0x0100
#define LUAJIT_MODE_FLUSH   0x0200

#endif /* LUA_BRIDGE_H */
