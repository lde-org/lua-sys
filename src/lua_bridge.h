/*
 * lua_bridge.h — minimal Lua C API types and layouts for bridge.c.
 *
 * The LuaJIT / Lua 5.1 ABI types match the LuaJIT that loads the bridge.
 * The Lua 5.4 and Luau debug layouts are declared separately: bridge.c never
 * includes their headers (they would clash with the 5.1 declarations), it
 * resolves symbols per runtime and reads/allocates the matching layout.
 */

#ifndef LUA_BRIDGE_H
#define LUA_BRIDGE_H

#include <stddef.h>  /* size_t */
#include <stdint.h>  /* int64_t */

/* Opaque Lua state */
typedef struct lua_State lua_State;

/* C function and registry-list types */
typedef int (*lua_CFunction)(lua_State *L);

typedef struct luaL_Reg {
    const char *name;
    lua_CFunction func;
} luaL_Reg;

/* Basic numeric types (LuaJIT / Lua 5.1) */
typedef double    lua_Number;
typedef ptrdiff_t lua_Integer;

/* Type tags (identical for nil/boolean/lightuserdata/number everywhere) */
#define LUA_TNONE          (-1)
#define LUA_TNIL           0
#define LUA_TBOOLEAN       1
#define LUA_TLIGHTUSERDATA 2
#define LUA_TNUMBER        3
#define LUA_TSTRING        4
#define LUA_TTABLE         5
#define LUA_TFUNCTION      6
#define LUA_TUSERDATA      7
#define LUA_TTHREAD        8
#define LUA_TCDATA         10  /* LuaJIT only */

/* Pseudo-indices */
#define LUA_REGISTRYINDEX  (-10000)
#define LUA_ENVIRONINDEX   (-10001)
#define LUA_GLOBALSINDEX   (-10002)

/* Lua 5.4: LUA_REGISTRYINDEX == -LUAI_MAXSTACK - 1000, LUAI_MAXSTACK is
 * 1000000 in every stock build. lua_upvalueindex(i) = LUA_REGISTRYINDEX - i. */
#define LUA54_REGISTRYINDEX (-1001000)
#define LUA54_RIDX_GLOBALS   2

/* Luau: LUA_REGISTRYINDEX == -LUAI_MAXCSTACK - 2000 (8000 -> -10000), and
 * lua_upvalueindex(i) = LUA_GLOBALSINDEX - i (same numbers as 5.1). */
/* Fedora builds Lua 5.1/5.4 with LUA_IDSIZE=512 and a Luau build may
 * override LUA_IDSIZE too. Over-allocating is safe: a library built with a
 * smaller size writes less, and the bridge never reads the private fields
 * that follow short_src. */
#define LUA_LUAU_IDSIZE 512

/* luaL_ref sentinels */
#define LUA_NOREF  (-2)
#define LUA_REFNIL (-1)

/* lua_pcall status */
#define LUA_OK      0
#define LUA_MULTRET (-1)

/* Debug interface (LuaJIT / Lua 5.1 ABI) */
#define LUA_IDSIZE 512

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

/* Lua 5.4 debug layout (Fedora/upstream; LUA_IDSIZE is 512 here). */
#define LUA54_IDSIZE 512

typedef struct lua54_Debug {
  int event;
  const char *name;
  const char *namewhat;
  const char *what;
  const char *source;
  size_t srclen;
  int currentline;
  int linedefined;
  int lastlinedefined;
  unsigned char nups;
  unsigned char nparams;
  char isvararg;
  char istailcall;
  unsigned short ftransfer;
  unsigned short ntransfer;
  char short_src[LUA54_IDSIZE];
  void *i_ci;
} lua54_Debug;

/* Luau debug layout (lua_Debug in VM/include/lua.h). */
typedef struct luaLuau_Debug {
  const char *name;
  const char *what;
  const char *source;
  const char *short_src;
  int linedefined;
  int currentline;
  int protoid;
  int bytecodeid;
  unsigned char nupvals;
  unsigned char nparams;
  char isvararg;
  void *userdata;
  char ssbuf[LUA_LUAU_IDSIZE];
} luaLuau_Debug;

/* Enough room for whichever lua_getstack/getinfo target is used. */
typedef union {
  lua_Debug v51;
  lua54_Debug v54;
  luaLuau_Debug luau;
} bridge_debug_ar;

/* The allocator callback type: shared by all builds. */
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
