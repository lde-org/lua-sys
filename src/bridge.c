// src/bridge.c
//
// C bridge for crossing between independent lua_State instances.
//
// lua_xmove cannot be used because host and guest states are created with
// separate luaL_newstate() calls and do not share a global_State. Only
// primitive values (nil, boolean, number, string, lightuserdata) are copied
// directly; compound types (table, function, userdata, thread) are handled on
// the Lua side via registry refs.
//
// Every host↔guest transition is behind a lua_CFunction boundary. This is
// required because LuaJIT's JIT recorder crashes (argv2cdata in
// recff_cdata_call) when it tries to trace FFI calls on a lua_State* pointer
// encountered during re-entrant execution (host → guest → host). See
// docs/src/bridge-design.md.
//
// The HOST side is always the LuaJIT that loaded this module: its API is
// resolved from the caller's image and every host call goes through those
// static pointers. The GUEST side is a runtime slot: `bridge.runtime(handle,
// abi)` resolves a per-ABI API table (LuaJIT, 5.1, 5.4, Luau) from an image
// handle, and every guest operation goes through that table. Slot 0 is
// (nil, "jit") — the LuaJIT that loaded the bridge — and shares the host
// pointers, so today's LuaJIT-on-LuaJIT path pays no extra rounding.
//
// C functions the GUEST runtime calls back (callback dispatch, hooks) are
// per-slot trampolines (dispatch_callback_0..7, hook_dispatch_0..7,
// luau_interrupt_0..7): a lua_CFunction/lua_Hook carries no context, so the
// slot is baked into the function instead of being looked up from upvalues
// the guest API would be needed to read.

/* dladdr1 (glibc) is a GNU extension; it must be requested before any system
 * header. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "lua_bridge.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Host LuaJIT symbol resolution ────────────────────────────────────────
 *
 * bridge must call into the LuaJIT that loaded it, which is not always the
 * one the dynamic linker would bind an undefined lua_* to: inside a library
 * built with `lde compile --shared`, the process can also hold the host's
 * Lua (Lua 5.4, ...), and the first one loaded wins. So every
 * lua_* is a static function pointer, resolved by name from the image that
 * called luaopen: LuaJIT's VM, which exports its API (the lde executable or
 * the lde-built library). PE DLLs need this regardless, since they cannot
 * leave symbols for the loader to bind against the process image. One copy
 * of this module serves one LuaJIT; lde extracts a separate copy per library.
 */
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#define LDE_LUA_SYMS(X)                                                        \
  X(int, lua_gettop, (lua_State * L))                                          \
  X(void, lua_settop, (lua_State * L, int idx))                                \
  X(void, lua_pushvalue, (lua_State * L, int idx))                             \
  X(void, lua_insert, (lua_State * L, int idx))                                \
  X(int, lua_type, (lua_State * L, int idx))                                   \
  X(const char *, lua_typename, (lua_State * L, int tp))                       \
  X(void, lua_pushnil, (lua_State * L))                                        \
  X(void, lua_pushboolean, (lua_State * L, int b))                             \
  X(void, lua_pushnumber, (lua_State * L, lua_Number n))                       \
  X(void, lua_pushinteger, (lua_State * L, lua_Integer n))                     \
  X(void, lua_pushlstring, (lua_State * L, const char *s, size_t len))         \
  X(void, lua_pushstring, (lua_State * L, const char *s))                      \
  X(const char *, lua_pushfstring, (lua_State * L, const char *fmt, ...))      \
  X(void, lua_pushlightuserdata, (lua_State * L, void *p))                     \
  X(void, lua_pushcclosure, (lua_State * L, lua_CFunction fn, int n))          \
  X(int, lua_toboolean, (lua_State * L, int idx))                              \
  X(lua_Number, lua_tonumber, (lua_State * L, int idx))                        \
  X(const char *, lua_tolstring, (lua_State * L, int idx, size_t *len))        \
  X(void *, lua_touserdata, (lua_State * L, int idx))                          \
  X(void, lua_createtable, (lua_State * L, int narr, int nrec))                \
  X(int, lua_rawgeti, (lua_State * L, int idx, int n))                         \
  X(void, lua_rawseti, (lua_State * L, int idx, int n))                        \
  X(void, lua_setfield, (lua_State * L, int idx, const char *k))               \
  X(int, lua_pcall, (lua_State * L, int nargs, int nresults, int errfunc))     \
  X(int, lua_error, (lua_State * L))                                           \
  X(lua_State *, luaL_newstate, (void))                                        \
  X(lua_State *, lua_newstate, (lua_Alloc, void *))                            \
  X(void, luaL_openlibs, (lua_State * L))                                      \
  X(void, lua_close, (lua_State * L))                                          \
  X(lua_Alloc, lua_getallocf, (lua_State * L, void **ud))                      \
  X(void, lua_setallocf, (lua_State * L, lua_Alloc f, void *ud))               \
  X(int, luaJIT_setmode, (lua_State * L, int idx, int mode))                   \
  X(int, luaL_ref, (lua_State * L, int t))                                     \
  X(void, luaL_unref, (lua_State * L, int t, int ref))                         \
  X(int, luaL_error, (lua_State * L, const char *fmt, ...))                    \
  X(void, luaL_checktype, (lua_State * L, int narg, int t))                    \
  X(void, luaL_register,                                                       \
    (lua_State * L, const char *libname, const luaL_Reg *l))                   \
  X(void, lua_rawget, (lua_State * L, int idx))                                \
  X(void, lua_rawset, (lua_State * L, int idx))                                \
  X(int, lua_setmetatable, (lua_State * L, int objindex))                      \
  X(int, lua_sethook, (lua_State * L, lua_Hook func, int mask, int count))     \
  X(int, lua_getstack, (lua_State * L, int level, lua_Debug *ar))              \
  X(int, lua_getinfo, (lua_State * L, const char *what, lua_Debug *ar))        \
  X(int, lua_next, (lua_State * L, int idx))                                   \
  X(int, lua_getmetatable, (lua_State * L, int objindex))                      \
  X(void, lua_getfenv, (lua_State * L, int idx))                               \
  X(const void *, lua_topointer, (lua_State * L, int idx))                     \
  X(lua_State *, lua_tothread, (lua_State * L, int idx))                       \
  X(lua_State *, lua_newthread, (lua_State * L))                               \
  X(int, lua_pushthread, (lua_State * L))                                      \
  X(void, lua_xmove, (lua_State * from, lua_State * to, int n))                \
  X(int, lua_checkstack, (lua_State * L, int extra))                           \
  X(const char *, lua_getlocal, (lua_State * L, const lua_Debug *ar, int n))   \
  X(const char *, lua_getupvalue, (lua_State * L, int funcindex, int n))       \
  X(void *, lua_upvalueid, (lua_State * L, int funcindex, int n))              \
  X(void, lua_replace, (lua_State * L, int idx))

/* Each lua_* name becomes a static function pointer; every call site below
 * calls through it unchanged. */
#define LDE_DECLARE(ret, name, args) static ret(*name) args;
LDE_LUA_SYMS(LDE_DECLARE)
#undef LDE_DECLARE

/* Canonical 3-argument views of LuaJIT's lua_tonumber/lua_tointeger. The
 * extra `isnum` argument is ignored by LuaJIT's 2-argument functions, so slot
 * 0 reads numbers with the same one indirect call the old bridge used.
 * Resolved through void* so the ABI-compatible widening casts are not
 * -Wcast-function-type warnings. */
static double (*host_tonumberx)(lua_State *, int, int *);
static int64_t (*host_tointegerx)(lua_State *, int, int *);

/* Returns 0 when the image that called luaopen does not export LuaJIT's API. */
static int bridge_resolve_symbols(void *caller) {
#ifdef _WIN32
  HMODULE image = NULL;
  if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          (LPCSTR)caller, &image))
    return 0;
#define LDE_RESOLVE(ret, name, args)                                           \
  *(FARPROC *)&name = GetProcAddress(image, #name);
#else
  Dl_info info;
  void *image = NULL;
#ifdef __GLIBC__
  /* The link map is a dlsym handle, so no path has to be reopened. */
  if (!dladdr1(caller, &info, &image, RTLD_DL_LINKMAP))
    return 0;
#else
  if (!dladdr(caller, &info))
    return 0;
  image = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
  /* The main program cannot be reopened by path; its handle searches it first.
   */
  if (image == NULL)
    image = dlopen(NULL, RTLD_NOW);
#endif
#define LDE_RESOLVE(ret, name, args) *(void **)&name = dlsym(image, #name);
#endif
  LDE_LUA_SYMS(LDE_RESOLVE)
#ifdef _WIN32
  *(FARPROC *)&host_tonumberx = GetProcAddress(image, "lua_tonumber");
  *(FARPROC *)&host_tointegerx = GetProcAddress(image, "lua_tointeger");
#else
  *(void **)&host_tonumberx = dlsym(image, "lua_tonumber");
  *(void **)&host_tointegerx = dlsym(image, "lua_tointeger");
#endif
  if (host_tonumberx == NULL || host_tointegerx == NULL)
    return 0;
#undef LDE_RESOLVE
#define LDE_CHECK(ret, name, args)                                             \
  if (name == NULL)                                                            \
    return 0;
  LDE_LUA_SYMS(LDE_CHECK)
#undef LDE_CHECK
  return 1;
}

/* ── Runtime slots ────────────────────────────────────────────────────────
 *
 * A slot is one guest runtime image + ABI. Slot 0 is always the LuaJIT that
 * loaded this module (its API table is a copy of the host pointers). Slots
 * 1..7 are resolved by name from a dlopen/LoadLibrary handle. The same
 * (handle, abi) always maps to the same slot, so repeated image resolution
 * is free.
 */

enum {
  BRIDGE_ABI_JIT = 0,
  BRIDGE_ABI_51,
  BRIDGE_ABI_54,
  BRIDGE_ABI_LUAU
};

#define BRIDGE_MAX_SLOTS 8

/* Luau's lua_Callbacks layout (VM/include/lua.h). Kept in sync with the
 * headers the Luau binding uses; only debugstep/interrupt are touched. */
typedef struct bridge_luau_callbacks {
  void *userdata;
  void (*interrupt)(lua_State *L, int gc);
  void (*panic)(lua_State *L, int errcode);
  void (*userthread)(lua_State *LP, lua_State *L);
  int16_t (*useratom)(lua_State *L, const char *s, size_t l);
  void (*userfinalizer)(lua_State *L, lua_State *co);
  void (*debugbreak)(lua_State *L, void *ar);
  void (*debugstep)(lua_State *L, void *ar);
  void (*debuginterrupt)(lua_State *L, void *ar);
  void (*debugprotectederror)(lua_State *L);
  void (*onallocate)(lua_State *L, void *block, size_t osize, size_t nsize,
                     uint8_t memcat, int tt, int tag);
  void (*preresume)(lua_State *L);
  void (*postresume)(lua_State *L);
  void (*onfree)(lua_State *L, void *block);
} bridge_luau_callbacks;

/* The neutral debug view both the hook path and the heap walker consume. */
typedef struct {
  int event;
  const char *name;
  const char *namewhat;
  const char *what;
  const char *source;
  const char *short_src;
  int currentline;
  int linedefined;
  int lastlinedefined;
  int nups;
} bridge_debug;

typedef struct bridge_slot bridge_slot;

/* One guest runtime API. Every function pointer here is called with the
 * guest lua_State* of that runtime. */
typedef struct bridge_guest_api {
  /* stack */
  int (*gettop)(lua_State *);
  void (*settop)(lua_State *, int);
  void (*pushvalue)(lua_State *, int);
  int (*type)(lua_State *, int);
  const char *(*typename_)(lua_State *, int);
  /* push */
  void (*pushnil)(lua_State *);
  void (*pushboolean)(lua_State *, int);
  void (*pushnumber)(lua_State *, double);
  void (*pushinteger)(lua_State *, int64_t);
  void (*pushlstring)(lua_State *, const char *, size_t);
  void (*pushstring)(lua_State *, const char *);
  const char *(*pushfstring)(lua_State *, const char *, ...);
  void (*pushlightuserdata)(lua_State *, void *);
  void (*pushlightuserdata_tag)(lua_State *, void *, int);
  void (*pushcclosure)(lua_State *, lua_CFunction, int);
  void (*pushcclosurek)(lua_State *, lua_CFunction, const char *, int, void *);
  /* access */
  int (*toboolean)(lua_State *, int);
  double (*tonumberx)(lua_State *, int, int *);
  int64_t (*tointegerx)(lua_State *, int, int *);
  const char *(*tolstring)(lua_State *, int, size_t *);
  void *(*touserdata)(lua_State *, int);
  const void *(*topointer)(lua_State *, int);
  lua_State *(*tothread)(lua_State *, int);
  /* tables */
  void (*createtable)(lua_State *, int, int);
  int (*rawgeti)(lua_State *, int, int);
  void (*rawseti)(lua_State *, int, int);
  void (*rawget)(lua_State *, int);
  void (*rawset)(lua_State *, int);
  void (*setfield)(lua_State *, int, const char *);
  int (*next)(lua_State *, int);
  int (*getmetatable)(lua_State *, int);
  int (*setmetatable)(lua_State *, int);
  /* calls */
  int (*pcall)(lua_State *, int, int, int);
  int (*pcallk)(lua_State *, int, int, int, intptr_t, void *);
  void (*error_)(lua_State *);
  /* refs */
  int (*ref_table)(lua_State *, int);
  void (*unref_table)(lua_State *, int, int);
  int (*ref_value)(lua_State *, int);
  void (*unref_value)(lua_State *, int);
  /* state / threads */
  lua_State *(*newthread)(lua_State *);
  int (*pushthread)(lua_State *);
  void (*xmove)(lua_State *, lua_State *, int);
  int (*checkstack)(lua_State *, int);
  const char *(*getupvalue)(lua_State *, int, int);
  void *(*upvalueid)(lua_State *, int, int);
  void (*getfenv)(lua_State *, int);
  void (*replace)(lua_State *, int);
  void (*copy)(lua_State *, int, int);
  lua_State *(*luaL_newstate)(void);
  lua_State *(*newstate)(lua_Alloc, void *);
  void (*openlibs)(lua_State *);
  lua_Alloc (*getallocf)(lua_State *, void **);
  void (*setallocf)(lua_State *, lua_Alloc, void *);
  void (*close_)(lua_State *);
  /* debug */
  int (*getstack_native)(lua_State *, int, void *);
  int (*stackdepth)(lua_State *);
  int (*getinfo_native)(lua_State *, const char *, void *);
  int (*getinfo_level)(lua_State *, int, const char *, void *);
  const char *(*getlocal_ar)(lua_State *, const void *, int);
  const char *(*getlocal_level)(lua_State *, int, int);
  void (*debug_read)(const void *, int, bridge_debug *);
  int (*debug_nups)(const void *);
  /* hooks */
  void (*sethook)(lua_State *, void (*)(lua_State *, void *), int, int);
  int (*setmode)(lua_State *, int, int);
  bridge_luau_callbacks *(*callbacks)(lua_State *);
  void (*singlestep)(lua_State *, int);
} bridge_guest_api;

struct bridge_slot {
  int used;
  int abi;
  void *handle;
  int registry_index;
  int upvalue_base;
  int t_string;
  int t_table;
  int t_function;
  int t_userdata;
  int t_thread;
  int t_cdata;
  bridge_guest_api api;
};

static bridge_slot g_slots[BRIDGE_MAX_SLOTS];
static bridge_guest_api host_api;

/* ── Debug layouts ───────────────────────────────────────────────────────── */

static void debug_read_51(const void *ar_, int hint, bridge_debug *out) {
  const lua_Debug *ar = (const lua_Debug *)ar_;
  (void)hint;
  memset(out, 0, sizeof(*out));
  out->event = ar->event;
  out->name = ar->name;
  out->namewhat = ar->namewhat;
  out->what = ar->what;
  out->source = ar->source;
  out->short_src = ar->short_src;
  out->currentline = ar->currentline;
  out->linedefined = ar->linedefined;
  out->lastlinedefined = ar->lastlinedefined;
  out->nups = ar->nups;
}

static void debug_read_54(const void *ar_, int hint, bridge_debug *out) {
  const lua54_Debug *ar = (const lua54_Debug *)ar_;
  (void)hint;
  memset(out, 0, sizeof(*out));
  out->event = ar->event;
  out->name = ar->name;
  out->namewhat = ar->namewhat;
  out->what = ar->what;
  out->source = ar->source;
  out->short_src = ar->short_src;
  out->currentline = ar->currentline;
  out->linedefined = ar->linedefined;
  out->lastlinedefined = ar->lastlinedefined;
  out->nups = ar->nups;
}

static void debug_read_luau(const void *ar_, int hint, bridge_debug *out) {
  const luaLuau_Debug *ar = (const luaLuau_Debug *)ar_;
  memset(out, 0, sizeof(*out));
  out->event = hint;
  out->name = ar->name;
  out->namewhat = NULL;
  out->what = ar->what;
  out->source = ar->source;
  out->short_src = ar->short_src;
  out->currentline = ar->currentline;
  out->linedefined = ar->linedefined;
  out->lastlinedefined = -1;
  out->nups = ar->nupvals;
}

static int debug_nups_51(const void *ar) {
  return ((const lua_Debug *)ar)->nups;
}
static int debug_nups_54(const void *ar) {
  return ((const lua54_Debug *)ar)->nups;
}
static int debug_nups_luau(const void *ar) {
  return ((const luaLuau_Debug *)ar)->nupvals;
}

/* ── Host API table ──────────────────────────────────────────────────────── */

static void host_pushinteger(lua_State *L, int64_t n) {
  lua_pushinteger(L, (lua_Integer)n);
}

static int host_getstack(lua_State *L, int level, void *ar) {
  return lua_getstack(L, level, (lua_Debug *)ar);
}

static int host_getinfo(lua_State *L, const char *what, void *ar) {
  return lua_getinfo(L, what, (lua_Debug *)ar);
}

static const char *host_getlocal(lua_State *L, const void *ar, int n) {
  return lua_getlocal(L, (const lua_Debug *)ar, n);
}

static void host_sethook(lua_State *L, void (*fn)(lua_State *, void *),
                         int mask, int count) {
  (void)lua_sethook(L, (lua_Hook)fn, mask, count);
}

static void host_error(lua_State *L) {
  (void)lua_error(L);
}

static void host_pushcclosure(lua_State *L, lua_CFunction fn, int nup) {
  lua_pushcclosure(L, fn, nup);
}

static void init_host_api(void) {
  memset(&host_api, 0, sizeof(host_api));
  host_api.gettop = lua_gettop;
  host_api.settop = lua_settop;
  host_api.pushvalue = lua_pushvalue;
  host_api.type = lua_type;
  host_api.typename_ = lua_typename;
  host_api.pushnil = lua_pushnil;
  host_api.pushboolean = lua_pushboolean;
  host_api.pushnumber = lua_pushnumber;
  host_api.pushinteger = host_pushinteger;
  host_api.pushlstring = lua_pushlstring;
  host_api.pushstring = lua_pushstring;
  host_api.pushfstring = lua_pushfstring;
  host_api.pushlightuserdata = lua_pushlightuserdata;
  host_api.pushcclosure = host_pushcclosure;
  host_api.toboolean = lua_toboolean;
  host_api.tonumberx = host_tonumberx;
  host_api.tointegerx = host_tointegerx;
  host_api.tolstring = lua_tolstring;
  host_api.touserdata = lua_touserdata;
  host_api.topointer = lua_topointer;
  host_api.tothread = lua_tothread;
  host_api.createtable = lua_createtable;
  host_api.rawgeti = lua_rawgeti;
  host_api.rawseti = lua_rawseti;
  host_api.rawget = lua_rawget;
  host_api.rawset = lua_rawset;
  host_api.setfield = lua_setfield;
  host_api.next = lua_next;
  host_api.getmetatable = lua_getmetatable;
  host_api.setmetatable = lua_setmetatable;
  host_api.pcall = lua_pcall;
  host_api.error_ = host_error;
  host_api.ref_table = luaL_ref;
  host_api.unref_table = luaL_unref;
  host_api.newthread = lua_newthread;
  host_api.pushthread = lua_pushthread;
  host_api.xmove = lua_xmove;
  host_api.checkstack = lua_checkstack;
  host_api.getupvalue = lua_getupvalue;
  host_api.upvalueid = lua_upvalueid;
  host_api.getfenv = lua_getfenv;
  host_api.replace = lua_replace;
  host_api.luaL_newstate = luaL_newstate;
  host_api.newstate = lua_newstate;
  host_api.openlibs = luaL_openlibs;
  host_api.getallocf = lua_getallocf;
  host_api.setallocf = lua_setallocf;
  host_api.close_ = lua_close;
  host_api.getstack_native = host_getstack;
  host_api.getinfo_native = host_getinfo;
  host_api.getlocal_ar = host_getlocal;
  host_api.debug_read = debug_read_51;
  host_api.debug_nups = debug_nups_51;
  host_api.sethook = host_sethook;
  host_api.setmode = luaJIT_setmode;
}

/* ── Slot helpers ────────────────────────────────────────────────────────── */

static int slot_upvalue(const bridge_slot *s, int i) {
  return s->upvalue_base - i;
}

static int64_t slot_tointeger(const bridge_slot *s, lua_State *L, int idx) {
  return s->api.tointegerx(L, idx, NULL);
}

static double slot_tonumber(const bridge_slot *s, lua_State *L, int idx) {
  return s->api.tonumberx(L, idx, NULL);
}

static void slot_pushinteger(const bridge_slot *s, lua_State *L, int64_t n) {
  s->api.pushinteger(L, n);
}

static void slot_pushlightuserdata(const bridge_slot *s, lua_State *L,
                                   void *p) {
  if (s->abi == BRIDGE_ABI_LUAU)
    s->api.pushlightuserdata_tag(L, p, 0);
  else
    s->api.pushlightuserdata(L, p);
}

static void slot_pushcclosure(const bridge_slot *s, lua_State *L,
                              lua_CFunction fn, int nup) {
  if (s->abi == BRIDGE_ABI_LUAU)
    s->api.pushcclosurek(L, fn, NULL, nup, NULL);
  else
    s->api.pushcclosure(L, fn, nup);
}

static int slot_pcall(const bridge_slot *s, lua_State *L, int nargs,
                      int nresults, int errfunc) {
  if (s->abi == BRIDGE_ABI_54)
    return s->api.pcallk(L, nargs, nresults, errfunc, 0, NULL);
  return s->api.pcall(L, nargs, nresults, errfunc);
}

/* Reference the value on top of the guest stack (popping it). */
static int slot_ref_top(const bridge_slot *s, lua_State *L) {
  if (s->abi == BRIDGE_ABI_LUAU) {
    int ref = s->api.ref_value(L, -1);
    s->api.settop(L, -2);
    return ref;
  }
  return s->api.ref_table(L, s->registry_index);
}

/* Host pointers (JIT depth, chain box, closed flag) travel as lightuserdata:
 * 64-bit in every guest runtime, unlike Luau's 32-bit lua_Integer. */
static void slot_push_ptr(const bridge_slot *s, lua_State *L, void *p) {
  slot_pushlightuserdata(s, L, p);
}

static void *slot_read_ptr(const bridge_slot *s, lua_State *L, int idx) {
  return s->api.touserdata(L, idx);
}

static void slot_pushglobals(const bridge_slot *s, lua_State *L) {
  if (s->abi == BRIDGE_ABI_54)
    s->api.rawgeti(L, s->registry_index, LUA54_RIDX_GLOBALS);
  else
    s->api.pushvalue(L, LUA_GLOBALSINDEX);
}

/* 5.4 debug info uses lowercase 's' (source); 5.1 accepts 'S'. */
static const char *slot_debug_what(const bridge_slot *s, const char *what,
                                   char *buffer, size_t size) {
  size_t i, n;
  if (s->abi != BRIDGE_ABI_LUAU)
    return what;
  n = strlen(what);
  if (n >= size)
    n = size - 1;
  for (i = 0; i < n; i++)
    buffer[i] = what[i] == 'S' ? 's' : what[i];
  buffer[n] = '\0';
  return buffer;
}

static int slot_getstack(const bridge_slot *s, lua_State *L, int level,
                         void *ar) {
  if (s->abi == BRIDGE_ABI_LUAU)
    return level >= 0 && level < s->api.stackdepth(L);
  return s->api.getstack_native(L, level, ar);
}

static int slot_getinfo(const bridge_slot *s, lua_State *L, int level,
                        const char *what, void *ar) {
  char buffer[8];
  const char *real = slot_debug_what(s, what, buffer, sizeof(buffer));
  if (s->abi == BRIDGE_ABI_LUAU)
    return s->api.getinfo_level(L, level, real, ar);
  return s->api.getinfo_native(L, real, ar);
}

static const char *slot_getlocal(const bridge_slot *s, lua_State *L,
                                 int level, int n) {
  bridge_debug_ar ar;
  if (s->abi == BRIDGE_ABI_LUAU)
    return s->api.getlocal_level(L, level, n);
  memset(&ar, 0, sizeof(ar));
  if (!s->api.getstack_native(L, level, &ar))
    return NULL;
  return s->api.getlocal_ar(L, &ar, n);
}

/* Push the function at `idx`, read its upvalue count and pop it again. */
static int slot_nups(const bridge_slot *s, lua_State *L, int idx, int *nups) {
  bridge_debug_ar ar;
  int ok;
  memset(&ar, 0, sizeof(ar));
  s->api.pushvalue(L, idx);
  if (s->abi == BRIDGE_ABI_LUAU) {
    ok = s->api.getinfo_level(L, -1, "u", &ar);
    s->api.settop(L, -2);
  } else {
    /* '>' pops the function for 5.1/jit/5.4. */
    ok = s->api.getinfo_native(L, ">u", &ar);
  }
  if (!ok)
    return 0;
  *nups = s->api.debug_nups(&ar);
  return 1;
}

static void slot_debug_read(const bridge_slot *s, const void *ar, int hint,
                            bridge_debug *out) {
  s->api.debug_read(ar, hint, out);
}

/* ── Value copying ───────────────────────────────────────────────────────── */

#if defined(__GNUC__) || defined(__clang__)
#define BRIDGE_INLINE static inline __attribute__((always_inline))
#else
#define BRIDGE_INLINE static
#endif


static void push_number_54(const bridge_slot *s, lua_State *L, double n) {
  /* Host numbers stay doubles; integral values in int64 range cross as
   * 5.4 integers (the contract's pushNumber rule). */
  if (n >= -9223372036854775808.0 && n < 9223372036854775808.0 &&
      n == (double)(int64_t)n)
    s->api.pushinteger(L, (int64_t)n);
  else
    s->api.pushnumber(L, n);
}

/* Slot 0's guest runtime is the host LuaJIT itself, so its guest operations
 * can use the static host pointers directly. `isHost` is a compile-time
 * constant at every per-slot trampoline call site (always_inline), so the
 * branch folds away and slot 0 matches the pre-slot bridge exactly. */
BRIDGE_INLINE int guest_gettop(bridge_slot *s, lua_State *L, int isHost) {
  return isHost ? lua_gettop(L) : s->api.gettop(L);
}

BRIDGE_INLINE void guest_settop(bridge_slot *s, lua_State *L, int idx,
                                int isHost) {
  if (isHost)
    lua_settop(L, idx);
  else
    s->api.settop(L, idx);
}

BRIDGE_INLINE int guest_type(bridge_slot *s, lua_State *L, int idx,
                             int isHost) {
  return isHost ? lua_type(L, idx) : s->api.type(L, idx);
}

BRIDGE_INLINE int guest_rawgeti(bridge_slot *s, lua_State *L, int idx, int n,
                                int isHost) {
  return isHost ? lua_rawgeti(L, idx, n) : s->api.rawgeti(L, idx, n);
}

BRIDGE_INLINE int guest_pcall(bridge_slot *s, lua_State *L, int nargs,
                              int nresults, int errfunc, int isHost) {
  if (isHost)
    return lua_pcall(L, nargs, nresults, errfunc);
  return slot_pcall(s, L, nargs, nresults, errfunc);
}

BRIDGE_INLINE const char *guest_tolstring(bridge_slot *s, lua_State *L,
                                          int idx, size_t *len, int isHost) {
  return isHost ? lua_tolstring(L, idx, len) : s->api.tolstring(L, idx, len);
}

BRIDGE_INLINE int64_t guest_tointeger(bridge_slot *s, lua_State *L, int idx,
                                      int isHost) {
  /* The macro is what the pre-slot bridge used: lua_tonumber + cast. */
  return isHost ? (int64_t)lua_tointeger(L, idx)
                : s->api.tointegerx(L, idx, NULL);
}

/* The host's upvalue pseudo-indices are compile-time constants; slot tables
 * carry theirs at runtime. */
BRIDGE_INLINE int guest_upvalue(bridge_slot *s, int i, int isHost) {
  return isHost ? lua_upvalueindex(i) : slot_upvalue(s, i);
}

BRIDGE_INLINE void *guest_touserdata(bridge_slot *s, lua_State *L, int idx,
                                     int isHost) {
  return isHost ? lua_touserdata(L, idx) : s->api.touserdata(L, idx);
}

BRIDGE_INLINE void guest_pushvalue(bridge_slot *s, lua_State *L, int idx,
                                   int isHost) {
  if (isHost)
    lua_pushvalue(L, idx);
  else
    s->api.pushvalue(L, idx);
}

BRIDGE_INLINE void guest_pushstring(bridge_slot *s, lua_State *L,
                                    const char *str, int isHost) {
  if (isHost)
    lua_pushstring(L, str);
  else
    s->api.pushstring(L, str);
}

BRIDGE_INLINE void guest_error(bridge_slot *s, lua_State *L, int isHost) {
  if (isHost)
    (void)lua_error(L);
  else
    s->api.error_(L);
}

BRIDGE_INLINE void *guest_read_ptr(bridge_slot *s, lua_State *L, int idx,
                                   int isHost) {
  if (isHost)
    return (void *)(intptr_t)lua_tointeger(L, idx);
  return slot_read_ptr(s, L, idx);
}

static int is_primitive_type(int t, const bridge_slot *s) {
  return t == LUA_TNIL || t == LUA_TBOOLEAN || t == LUA_TLIGHTUSERDATA ||
         t == LUA_TNUMBER || t == (s != NULL ? s->t_string : LUA_TSTRING);
}

/* Push the value at `idx` of `src` onto `dst`. `dst_slot` NULL means the host
 * state. Returns the source lua_type, or -1 for a compound value (nothing
 * pushed). Inlined: the hot bound_call loop must devirtualize the API table
 * loads exactly like the pre-slot bridge did. */
BRIDGE_INLINE int push_value(const bridge_guest_api *a, lua_State *src, int idx,
                      bridge_slot *dst_slot, lua_State *dst, int isHost) {
  int t = isHost ? lua_type(src, idx) : a->type(src, idx);
  switch (t) {
  case LUA_TNIL:
    if (isHost)
      lua_pushnil(dst);
    else if (dst_slot)
      dst_slot->api.pushnil(dst);
    else
      lua_pushnil(dst);
    break;
  case LUA_TBOOLEAN: {
    int b = isHost ? lua_toboolean(src, idx) : a->toboolean(src, idx);
    if (isHost)
      lua_pushboolean(dst, b);
    else if (dst_slot)
      dst_slot->api.pushboolean(dst, b);
    else
      lua_pushboolean(dst, b);
    break;
  }
  case LUA_TNUMBER: {
    double n = isHost ? lua_tonumber(src, idx)
                      : a->tonumberx(src, idx, NULL);
    if (isHost)
      lua_pushnumber(dst, n);
    else if (dst_slot == NULL)
      lua_pushnumber(dst, n);
    else if (dst_slot->abi == BRIDGE_ABI_54)
      push_number_54(dst_slot, dst, n);
    else
      dst_slot->api.pushnumber(dst, n);
    break;
  }
  case LUA_TLIGHTUSERDATA: {
    void *p = isHost ? lua_touserdata(src, idx) : a->touserdata(src, idx);
    if (isHost)
      lua_pushlightuserdata(dst, p);
    else if (dst_slot)
      slot_pushlightuserdata(dst_slot, dst, p);
    else
      lua_pushlightuserdata(dst, p);
    break;
  }
  case LUA_TSTRING: {
    size_t len;
    const char *str = isHost ? lua_tolstring(src, idx, &len)
                             : a->tolstring(src, idx, &len);
    if (isHost)
      lua_pushlstring(dst, str, len);
    else if (dst_slot)
      dst_slot->api.pushlstring(dst, str, len);
    else
      lua_pushlstring(dst, str, len);
    break;
  }
  default:
    return -1; /* compound — nothing pushed */
  }
  return t;
}

BRIDGE_INLINE void push_value_or_error(const bridge_guest_api *a,
                                       lua_State *src, int idx,
                                       bridge_slot *dst_slot, lua_State *dst,
                                       int isHost) {
  if (push_value(a, src, idx, dst_slot, dst, isHost) < 0) {
    a->pushfstring(src, "bridge: cannot pass %s across independent states",
                   a->typename_(src, a->type(src, idx)));
    a->error_(src);
  }
}

/* ── Argument decoding ───────────────────────────────────────────────────── */

/* Every slot-scoped function takes the runtime slot first: f(slot, guest, ...). */
typedef struct {
  int slot;
  int first; /* first argument after the slot, 1-based */
} bridge_slot_args;

static void decode_slot_args(lua_State *L, bridge_slot_args *out) {
  if (lua_type(L, 1) == LUA_TNUMBER) {
    lua_Number n = lua_tonumber(L, 1);
    if (n >= 0 && n < BRIDGE_MAX_SLOTS && n == (lua_Number)(int)n) {
      out->slot = (int)n;
      out->first = 2;
      return;
    }
  }
  luaL_error(L, "bridge: argument 1 must be a runtime slot (0..%d)", BRIDGE_MAX_SLOTS - 1);
}

static bridge_slot *slot_at(lua_State *L, int index) {
  if (index < 0 || index >= BRIDGE_MAX_SLOTS || !g_slots[index].used)
    luaL_error(L, "bridge: runtime slot %d is not initialized "
                  "(call bridge.runtime first)",
               index);
  return &g_slots[index];
}

/* A LuaJIT pointer cdata is a value box: lua_topointer returns the box
 * address, so its value is the first pointer-sized word. Handles, lua_State*
 * and flag addresses all arrive as pointer cdata; lua_touserdata does not
 * see cdata at all. */
static void *decode_cdata_value(lua_State *L, int idx) {
  const void *box = lua_topointer(L, idx);
  return box != NULL ? *(void *const *)box : NULL;
}

static lua_State *decode_guest_ptr(lua_State *L, int stack_pos) {
  int t = lua_type(L, stack_pos);
  if (t == LUA_TNUMBER)
    return (lua_State *)(uintptr_t)lua_tointeger(L, stack_pos);
  if (t == LUA_TLIGHTUSERDATA)
    return (lua_State *)lua_touserdata(L, stack_pos);
  if (t == LUA_TCDATA)
    return (lua_State *)decode_cdata_value(L, stack_pos);
  luaL_error(L, "bridge: arg %d must be a guest lua_State pointer", stack_pos);
  return NULL; /* unreachable: luaL_error longjmps */
}

/* ── JIT engine guard ────────────────────────────────────────────────────── */

static void jit_guard_enter(lua_State *owner, int *depth) {
  if (depth == NULL) {
    luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
    return;
  }
  if (++(*depth) == 1) {
    luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
  }
}

static void jit_guard_leave(lua_State *owner, int *depth) {
  if (depth == NULL) {
    luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
    return;
  }
  if (--(*depth) == 0) {
    luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
  }
}

/* ── bound_call ──────────────────────────────────────────────────────────── */
//
// lua_CFunction returned by bridge.make_callable.
//
// Upvalue 1: lightuserdata   — guest lua_State*
// Upvalue 2: integer         — guest registry ref for the function
// Upvalue 3: table           — guestState (lua.State object)
// Upvalue 4: integer         — registry ref for callGuestSlow
// Upvalue 5: lightuserdata   — address of the owner's closed flag
// Upvalue 6: integer         — registry ref for convertGuestResults
//
// One function per slot (bound_call_0..7): the slot is a compile-time
// address, so the guest API table and registry index never depend on a value
// read through an upvalue. That keeps slot 0 — where guest and host are the
// same LuaJIT — at the same speed as the pre-slot bridge.

enum {
  BOUND_UV_GUEST = 1,
  BOUND_UV_FNREF = 2,
  BOUND_UV_STATE = 3,
  BOUND_UV_SLOW = 4,
  BOUND_UV_CLOSED = 5,
  BOUND_UV_CONVERT = 6
};

BRIDGE_INLINE int bound_call_impl(lua_State *host, bridge_slot *slot,
                                  int isHost) {
  const bridge_guest_api *ga = &slot->api;
  /* lua-sys sets this flag before lua_close. Check it FIRST: the guest
   * pointer below dangles once the state is closed, so nothing may touch it
   * before this test. NULL means the closure carries no flag. */
  int *closed =
      (int *)(intptr_t)lua_tointeger(host, lua_upvalueindex(BOUND_UV_CLOSED));
  lua_State *guest;
  int fn_ref, nargs, guest_base;

  if (closed != NULL && *closed) {
    return luaL_error(host, "state is closed");
  }

  guest = (lua_State *)lua_touserdata(host, lua_upvalueindex(BOUND_UV_GUEST));
  fn_ref = (int)lua_tointeger(host, lua_upvalueindex(BOUND_UV_FNREF));
  nargs = lua_gettop(host);
  guest_base = guest_gettop(slot, guest, isHost);

  /* Fast path: all args are primitives. */
  int i;
  int all_primitive = 1;
  for (i = 1; i <= nargs; i++) {
    if (!is_primitive_type(lua_type(host, i), NULL)) {
      all_primitive = 0;
      break;
    }
  }

  if (!all_primitive) {
    /* Slow path: delegate to callGuestSlow for Lua-side toLua() handling. */
    int slow_ref = (int)lua_tointeger(host, lua_upvalueindex(BOUND_UV_SLOW));
    lua_rawgeti(host, LUA_REGISTRYINDEX, slow_ref);
    lua_pushvalue(host, lua_upvalueindex(BOUND_UV_STATE));
    lua_pushinteger(host, fn_ref);
    for (i = 1; i <= nargs; i++)
      lua_pushvalue(host, i);
    int status = lua_pcall(host, 2 + nargs, LUA_MULTRET, 0);
    if (status != LUA_OK)
      lua_error(host);
    return lua_gettop(host) - nargs;
  }

  guest_rawgeti(slot, guest, slot->registry_index, fn_ref, isHost);

  for (i = 1; i <= nargs; i++)
    push_value_or_error(&host_api, host, i, slot, guest, isHost);

  int status = guest_pcall(slot, guest, nargs, LUA_MULTRET, 0, isHost);
  if (status != 0) {
    const char *err = guest_tolstring(slot, guest, -1, NULL, isHost);
    guest_settop(slot, guest, guest_base, isHost);
    lua_pushstring(host, err ? err : "bridge: guest error");
    lua_error(host);
    return 0;
  }

  int nresults = guest_gettop(slot, guest, isHost) - guest_base;
  if (nresults == 0)
    return 0; /* guest stack already at guest_base */

  int all_primitive_res = 1;
  for (i = 0; i < nresults; i++) {
    if (!is_primitive_type(guest_type(slot, guest, guest_base + 1 + i, isHost),
                           slot)) {
      all_primitive_res = 0;
      break;
    }
  }

  if (all_primitive_res) {
    for (i = 0; i < nresults; i++)
      push_value(ga, guest, guest_base + 1 + i, NULL, host, isHost);
    guest_settop(slot, guest, guest_base, isHost);
    return nresults;
  }

  /* A compound result: convert each result on the Lua side, from the guest
   * stack. Do NOT call the guest function again — its side effects must
   * happen one time. */
  int convert_ref = (int)lua_tointeger(host, lua_upvalueindex(BOUND_UV_CONVERT));
  lua_rawgeti(host, LUA_REGISTRYINDEX, convert_ref);
  lua_pushvalue(host, lua_upvalueindex(BOUND_UV_STATE));
  lua_pushinteger(host, guest_base + 1); /* first result index */
  lua_pushinteger(host, nresults);
  status = lua_pcall(host, 3, LUA_MULTRET, 0);
  guest_settop(slot, guest, guest_base, isHost);
  if (status != LUA_OK)
    lua_error(host);
  return lua_gettop(host) - nargs;
}

#define BRIDGE_DEFINE_BOUND(n)                                                \
  static int bound_call_##n(lua_State *host) {                                \
    return bound_call_impl(host, &g_slots[n], (n) == 0);                       \
  }

BRIDGE_DEFINE_BOUND(0)
BRIDGE_DEFINE_BOUND(1)
BRIDGE_DEFINE_BOUND(2)
BRIDGE_DEFINE_BOUND(3)
BRIDGE_DEFINE_BOUND(4)
BRIDGE_DEFINE_BOUND(5)
BRIDGE_DEFINE_BOUND(6)
BRIDGE_DEFINE_BOUND(7)

static lua_CFunction g_bound[BRIDGE_MAX_SLOTS] = {
    bound_call_0, bound_call_1, bound_call_2, bound_call_3,
    bound_call_4, bound_call_5, bound_call_6, bound_call_7};

/* ── bound_pcall ─────────────────────────────────────────────────────────── */

static int bound_pcall(lua_State *host) {
  int nargs = lua_gettop(host) - 1; /* exclude self */
  int status = lua_pcall(host, nargs, LUA_MULTRET, 0);
  if (status != LUA_OK) { /* [err] */
    lua_pushboolean(host, 0);
    lua_insert(host, 1); /* [false, err] */
    return 2;
  }
  int nresults = lua_gettop(host); /* [r1..rM] */
  lua_pushboolean(host, 1);
  lua_insert(host, 1); /* [true, r1..rM] */
  return nresults + 1;
}

static char callable_mt_key;

static void init_callable_metatable(lua_State *L);

/* Lightuserdata tag prefixing guest table registry refs. */
static char compound_tag_key;

static int bridge_compound_tag(lua_State *L) {
  lua_pushlightuserdata(L, (void *)&compound_tag_key);
  return 1;
}

static void *decode_host_ptr(lua_State *L, int idx) {
  int t = lua_type(L, idx);
  if (t == LUA_TLIGHTUSERDATA)
    return lua_touserdata(L, idx);
  if (t == LUA_TCDATA)
    return decode_cdata_value(L, idx);
  if (t == LUA_TNUMBER)
    return (void *)(intptr_t)lua_tointeger(L, idx);
  return NULL;
}

static int bridge_make_callable(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *slot = slot_at(L, args.slot);
  lua_State *guest = decode_guest_ptr(L, args.first);
  void *closed = decode_host_ptr(L, args.first + 4);
  (void)slot;
  lua_pushlightuserdata(L, (void *)guest); /* upvalue 1: guest */
  lua_pushvalue(L, args.first + 1);        /* upvalue 2: guestRef */
  lua_pushvalue(L, args.first + 2);        /* upvalue 3: guestState */
  lua_pushvalue(L, args.first + 3);        /* upvalue 4: callGuestSlow ref */
  lua_pushinteger(L, (lua_Integer)(intptr_t)closed); /* upvalue 5 */
  lua_pushvalue(L, args.first + 5);        /* upvalue 6: result converter */
  lua_pushcclosure(L, g_bound[args.slot], 6); /* the callable */
  lua_pushlightuserdata(L, (void *)&callable_mt_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    init_callable_metatable(L);
    lua_pushlightuserdata(L, (void *)&callable_mt_key);
    lua_rawget(L, LUA_REGISTRYINDEX);
  }
  lua_setmetatable(L, -2);
  return 1;
}

static void init_callable_metatable(lua_State *L) {
  lua_createtable(L, 0, 1); /* mt */
  lua_createtable(L, 0, 1); /* methods */
  lua_pushcclosure(L, bound_pcall, 0);
  lua_setfield(L, -2, "pcall");   /* methods.pcall = bound_pcall */
  lua_setfield(L, -2, "__index"); /* mt.__index = methods */
  lua_pushlightuserdata(L, (void *)&callable_mt_key);
  lua_pushvalue(L, -2);             /* [mt, key, mt] */
  lua_rawset(L, LUA_REGISTRYINDEX); /* registry[key] = mt */
  lua_pop(L, 1);
}

/* ── dispatch_callback ───────────────────────────────────────────────────── */
//
// lua_CFunction installed on the guest state via bridge.push_callback.
// Upvalue 1: integer       — guest registry ref for the callback function
// Upvalue 2: integer       — guest registry ref for the slow-path helper
// Upvalue 3: lightuserdata — the owner state holding the two refs
// Upvalue 4: pointer       — JIT depth counter (lightuserdata on Luau)
// Upvalue 5: pointer       — chain depth box (lightuserdata on Luau)

/* The body returns -1 when the error message is on the guest stack. It never
 * raises, so the chain guard of the caller always restores its counter. */
BRIDGE_INLINE int dispatch_callback_body(bridge_slot *s, lua_State *guest,
                                         int isHost) {
  const bridge_guest_api *ga = &s->api;
  int fn_ref = (int)guest_tointeger(s, guest, guest_upvalue(s, 1, isHost),
                                    isHost);
  int slow_ref = (int)guest_tointeger(s, guest, guest_upvalue(s, 2, isHost),
                                      isHost);
  lua_State *owner = (lua_State *)guest_touserdata(
      s, guest, guest_upvalue(s, 3, isHost), isHost);
  int saved_top = lua_gettop(owner);
  int nargs = guest_gettop(s, guest, isHost);
  int i;

  /* Fast path: all args are primitives. */
  int all_primitive = 1;
  for (i = 1; i <= nargs; i++) {
    if (!is_primitive_type(guest_type(s, guest, i, isHost),
                           isHost ? NULL : s)) {
      all_primitive = 0;
      break;
    }
  }

  int n_sent;
  if (!all_primitive) {
    /* Slow path: dispatchCallbackSlow(guest, fn, args...) — table args
     * cross as (TAG, guest_registry_ref) pairs. */
    lua_rawgeti(owner, LUA_REGISTRYINDEX, slow_ref);
    lua_pushlightuserdata(owner, (void *)guest);
    lua_rawgeti(owner, LUA_REGISTRYINDEX, fn_ref);
    n_sent = 2;
    for (i = 1; i <= nargs; i++) {
      if (guest_type(s, guest, i, isHost) ==
          (isHost ? LUA_TTABLE : s->t_table)) {
        guest_pushvalue(s, guest, i, isHost);
        int ref = slot_ref_top(s, guest);
        lua_pushlightuserdata(owner, (void *)&compound_tag_key);
        lua_pushinteger(owner, ref);
        n_sent += 2;
      } else {
        push_value_or_error(ga, guest, i, NULL, owner, isHost);
        n_sent += 1;
      }
    }
  } else {
    lua_rawgeti(owner, LUA_REGISTRYINDEX, fn_ref);
    for (i = 1; i <= nargs; i++)
      push_value_or_error(ga, guest, i, NULL, owner, isHost);
    n_sent = nargs;
  }

  int *depth = (int *)guest_read_ptr(s, guest, guest_upvalue(s, 4, isHost),
                                     isHost);
  jit_guard_enter(owner, depth);
  int status = lua_pcall(owner, n_sent, LUA_MULTRET, 0);
  jit_guard_leave(owner, depth);

  if (status != LUA_OK) {
    const char *err = lua_tostring(owner, -1);
    guest_pushstring(s, guest, err ? err : "bridge: host error", isHost);
    lua_settop(owner, saved_top);
    return -1;
  }

  int nresults = lua_gettop(owner) - saved_top;
  if (nresults == 0)
    return 0;

  for (i = 0; i < nresults; i++) {
    int t = push_value(&host_api, owner, saved_top + 1 + i, s, guest, isHost);
    if (t < 0) {
      lua_settop(owner, saved_top);
      guest_settop(s, guest, 0, isHost);
      ga->pushfstring(guest,
                      "bridge: host callback returned a %s; "
                      "only primitives (nil, boolean, number, string) "
                      "can be returned from host to guest",
                      lua_typename(owner, lua_type(owner, saved_top + 1 + i)));
      return -1;
    }
  }

  lua_settop(owner, saved_top);
  return nresults;
}

/* Guest -> host dispatch, with the chain guard. Inlined into each per-slot
 * trampoline so the slot address is a compile-time constant. */
BRIDGE_INLINE int dispatch_callback_common(bridge_slot *s, lua_State *guest,
                                           int isHost) {
  const bridge_guest_api *ga = &s->api;
  int *box = (int *)guest_read_ptr(s, guest, guest_upvalue(s, 5, isHost),
                                   isHost);
  if (box == NULL) {
    int n = dispatch_callback_body(s, guest, isHost);
    if (n < 0)
      guest_error(s, guest, isHost);
    return n;
  }

  if (box[1] > 0 && box[0] >= box[1]) {
    ga->pushfstring(
        guest,
        "bridge: the cross-state call chain reached its limit of %d levels "
        "(state:setChainLimit)",
        box[1]);
    guest_error(s, guest, isHost);
    return 0;
  }

  box[0]++;
  int n = dispatch_callback_body(s, guest, isHost);
  box[0]--;
  if (n < 0)
    guest_error(s, guest, isHost);
  return n;
}

#define BRIDGE_DEFINE_DISPATCH(n)                                             \
  static int dispatch_callback_##n(lua_State *guest) {                        \
    return dispatch_callback_common(&g_slots[n], guest, (n) == 0);            \
  }

BRIDGE_DEFINE_DISPATCH(0)
BRIDGE_DEFINE_DISPATCH(1)
BRIDGE_DEFINE_DISPATCH(2)
BRIDGE_DEFINE_DISPATCH(3)
BRIDGE_DEFINE_DISPATCH(4)
BRIDGE_DEFINE_DISPATCH(5)
BRIDGE_DEFINE_DISPATCH(6)
BRIDGE_DEFINE_DISPATCH(7)

static lua_CFunction g_dispatch[BRIDGE_MAX_SLOTS] = {
    dispatch_callback_0, dispatch_callback_1, dispatch_callback_2,
    dispatch_callback_3, dispatch_callback_4, dispatch_callback_5,
    dispatch_callback_6, dispatch_callback_7};

/* ── Debug hooks ─────────────────────────────────────────────────────────── */

static char hook_registry_key;
static char hook_meta_key;
static char hook_owner_key;
static char frame_meta_key;

static int hook_info_stack(lua_State *L);
static int hook_info_index(lua_State *L);
static void init_hook_info_metatable(lua_State *L);

static const char *hook_event_name(int event) {
  switch (event) {
  case LUA_HOOKCALL:
    return "call";
  case LUA_HOOKRET:
    return "return";
  case LUA_HOOKLINE:
    return "line";
  case LUA_HOOKCOUNT:
    return "count";
  case LUA_HOOKTAILCALL:
    return "tailcall";
  default:
    return "?";
  }
}

/* lua_Hook installed on a guest state by bridge.set_hook. The event hint is
 * used by Luau, whose lua_Debug has no event field (debugstep = line,
 * interrupt = count); other ABIs read their native ar->event. */
static void hook_dispatch_common(bridge_slot *s, lua_State *guest,
                                 void *hook_ar, int event_hint) {
  const bridge_guest_api *ga = &s->api;
  bridge_debug_ar native_ar;
  bridge_debug dbg;

  /* Locate the callback ref and owner stored by bridge.set_hook. */
  slot_pushlightuserdata(s, guest, (void *)&hook_registry_key);
  ga->rawget(guest, s->registry_index);
  if (ga->type(guest, -1) != LUA_TNUMBER) {
    ga->settop(guest, -2);
    return; /* hook removed between events — no-op */
  }
  int fn_ref = (int)slot_tointeger(s, guest, -1);
  ga->settop(guest, -2);

  slot_pushlightuserdata(s, guest, (void *)&hook_owner_key);
  ga->rawget(guest, s->registry_index);
  if (ga->type(guest, -1) != LUA_TLIGHTUSERDATA) {
    ga->settop(guest, -2);
    return; /* stale hook entry without an owner — no-op */
  }
  lua_State *owner = (lua_State *)ga->touserdata(guest, -1);
  ga->settop(guest, -2);

  memset(&native_ar, 0, sizeof(native_ar));
  if (s->abi == BRIDGE_ABI_LUAU) {
    ga->getinfo_level(guest, 0, "sln", &native_ar);
    slot_debug_read(s, &native_ar,
                    event_hint != 0 ? event_hint : LUA_HOOKLINE, &dbg);
  } else {
    ga->getinfo_native(guest, "Sln", hook_ar);
    slot_debug_read(s, hook_ar, event_hint, &dbg);
  }

  int saved_top = lua_gettop(owner);

  /* Arg 1: event name. */
  lua_pushstring(owner, hook_event_name(dbg.event));

  /* Arg 2: info table with all debug fields populated eagerly. */
  lua_createtable(owner, 0, 12);
  lua_pushstring(owner, hook_event_name(dbg.event));
  lua_setfield(owner, -2, "event");
  if (dbg.name) {
    lua_pushstring(owner, dbg.name);
    lua_setfield(owner, -2, "name");
  }
  if (dbg.namewhat) {
    lua_pushstring(owner, dbg.namewhat);
    lua_setfield(owner, -2, "namewhat");
  }
  if (dbg.what) {
    lua_pushstring(owner, dbg.what);
    lua_setfield(owner, -2, "what");
  }
  if (dbg.source) {
    lua_pushstring(owner, dbg.source);
    lua_setfield(owner, -2, "source");
  }
  if (dbg.short_src) {
    lua_pushstring(owner, dbg.short_src);
    lua_setfield(owner, -2, "short_src");
  }
  lua_pushinteger(owner, dbg.currentline);
  lua_setfield(owner, -2, "currentline");
  lua_pushinteger(owner, dbg.linedefined);
  lua_setfield(owner, -2, "linedefined");
  lua_pushinteger(owner, dbg.lastlinedefined);
  lua_setfield(owner, -2, "lastlinedefined");
  lua_pushinteger(owner, dbg.nups);
  lua_setfield(owner, -2, "nups");
  lua_pushinteger(owner, (lua_Integer)(s - g_slots));
  lua_setfield(owner, -2, "_slot");

  /* The thread the hook fired on. */
  lua_pushlightuserdata(owner, (void *)guest);
  lua_setfield(owner, -2, "thread");
  lua_pushboolean(owner, 1);
  lua_setfield(owner, -2, "_hook_active");

  lua_pushlightuserdata(owner, (void *)&hook_meta_key);
  lua_rawget(owner, LUA_REGISTRYINDEX);
  if (lua_isnil(owner, -1)) {
    lua_pop(owner, 1);
    init_hook_info_metatable(owner);
    lua_pushlightuserdata(owner, (void *)&hook_meta_key);
    lua_rawget(owner, LUA_REGISTRYINDEX);
  }
  lua_setmetatable(owner, -2);
  int info_idx = lua_gettop(owner);

  lua_rawgeti(owner, LUA_REGISTRYINDEX, fn_ref);
  lua_pushvalue(owner, -3); /* event */
  lua_pushvalue(owner, -3); /* info table */

  luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
  int status = lua_pcall(owner, 2, 0, 0);
  luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);

  lua_pushstring(owner, "_hook_active");
  lua_pushboolean(owner, 0);
  lua_rawset(owner, info_idx);

  if (status != LUA_OK) {
    const char *err = lua_tostring(owner, -1);
    ga->pushstring(guest, err ? err : "bridge: hook error");
    lua_settop(owner, saved_top);
    ga->error_(guest);
    return;
  }
  lua_settop(owner, saved_top);
}

#define BRIDGE_DEFINE_HOOKS(n)                                                \
  static void hook_dispatch_##n(lua_State *guest, void *ar) {                 \
    hook_dispatch_common(&g_slots[n], guest, ar, 0);                          \
  }                                                                           \
  static void luau_interrupt_##n(lua_State *guest, int gc) {                  \
    (void)gc;                                                                 \
    hook_dispatch_common(&g_slots[n], guest, NULL, LUA_HOOKCOUNT);            \
  }

BRIDGE_DEFINE_HOOKS(0)
BRIDGE_DEFINE_HOOKS(1)
BRIDGE_DEFINE_HOOKS(2)
BRIDGE_DEFINE_HOOKS(3)
BRIDGE_DEFINE_HOOKS(4)
BRIDGE_DEFINE_HOOKS(5)
BRIDGE_DEFINE_HOOKS(6)
BRIDGE_DEFINE_HOOKS(7)

typedef void (*bridge_hook_fn)(lua_State *, void *);
typedef void (*bridge_interrupt_fn)(lua_State *, int);

static bridge_hook_fn g_hooks[BRIDGE_MAX_SLOTS] = {
    hook_dispatch_0, hook_dispatch_1, hook_dispatch_2, hook_dispatch_3,
    hook_dispatch_4, hook_dispatch_5, hook_dispatch_6, hook_dispatch_7};
static bridge_interrupt_fn g_interrupts[BRIDGE_MAX_SLOTS] = {
    luau_interrupt_0, luau_interrupt_1, luau_interrupt_2, luau_interrupt_3,
    luau_interrupt_4, luau_interrupt_5, luau_interrupt_6, luau_interrupt_7};

/* info:stack() — walk the stack of the thread the hook fired on. */
static int hook_info_stack(lua_State *L) {
  lua_pushstring(L, "_hook_active");
  lua_rawget(L, 1);
  int active = lua_toboolean(L, -1);
  lua_pop(L, 1);
  if (!active) {
    lua_pushstring(L,
                   "info:stack() must be called from within the hook callback");
    lua_error(L);
    return 0;
  }

  lua_pushstring(L, "thread");
  lua_rawget(L, 1);
  lua_State *guest = (lua_State *)lua_touserdata(L, -1);
  lua_pop(L, 1);

  lua_pushstring(L, "_slot");
  lua_rawget(L, 1);
  int slot_index = (int)lua_tointeger(L, -1);
  lua_pop(L, 1);
  if (slot_index < 0 || slot_index >= BRIDGE_MAX_SLOTS ||
      !g_slots[slot_index].used) {
    lua_pushstring(L, "bridge: hook info lost its runtime slot");
    lua_error(L);
    return 0;
  }
  bridge_slot *s = &g_slots[slot_index];

  lua_createtable(L, 8, 0);
  if (guest == NULL)
    return 1;
  int level = 0;
  for (;;) {
    bridge_debug_ar ar;
    bridge_debug dbg;
    memset(&ar, 0, sizeof(ar));
    if (!slot_getstack(s, guest, level, &ar))
      break;
    slot_getinfo(s, guest, level, "Slnu", &ar);
    slot_debug_read(s, &ar, 0, &dbg);
    lua_createtable(L, 0, 12);
    if (dbg.name) {
      lua_pushstring(L, dbg.name);
      lua_setfield(L, -2, "name");
    }
    if (dbg.namewhat) {
      lua_pushstring(L, dbg.namewhat);
      lua_setfield(L, -2, "namewhat");
    }
    if (dbg.what) {
      lua_pushstring(L, dbg.what);
      lua_setfield(L, -2, "what");
    }
    if (dbg.source) {
      lua_pushstring(L, dbg.source);
      lua_setfield(L, -2, "source");
    }
    if (dbg.short_src) {
      lua_pushstring(L, dbg.short_src);
      lua_setfield(L, -2, "short_src");
    }
    lua_pushinteger(L, dbg.currentline);
    lua_setfield(L, -2, "currentline");
    lua_pushinteger(L, dbg.linedefined);
    lua_setfield(L, -2, "linedefined");
    lua_pushinteger(L, dbg.lastlinedefined);
    lua_setfield(L, -2, "lastlinedefined");
    lua_pushinteger(L, dbg.nups);
    lua_setfield(L, -2, "nups");
    lua_pushlightuserdata(L, (void *)guest);
    lua_setfield(L, -2, "thread");
    lua_pushinteger(L, level);
    lua_setfield(L, -2, "level");
    lua_pushvalue(L, 1);
    lua_setfield(L, -2, "_info");
    lua_pushlightuserdata(L, (void *)&frame_meta_key);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_isnil(L, -1)) {
      lua_setmetatable(L, -2);
    } else {
      lua_pop(L, 1);
    }
    lua_rawseti(L, -2, level + 1);
    level++;
  }
  return 1;
}

static int hook_info_index(lua_State *L) {
  const char *key = lua_tostring(L, 2);
  if (key && strcmp(key, "stack") == 0) {
    lua_pushcclosure(L, hook_info_stack, 0);
    return 1;
  }
  return 0;
}

static void init_hook_info_metatable(lua_State *L) {
  lua_createtable(L, 0, 1); /* mt */
  lua_pushcclosure(L, hook_info_index, 0);
  lua_setfield(L, -2, "__index"); /* mt.__index = hook_info_index */
  lua_pushlightuserdata(L, (void *)&hook_meta_key);
  lua_pushvalue(L, -2);             /* [mt, key, mt] */
  lua_rawset(L, LUA_REGISTRYINDEX); /* registry[key] = mt */
  lua_pop(L, 1);
}

/* Install the per-slot trampoline. Luau has no lua_sethook: line hooks use
 * the debugstep callback + singlestep, count hooks use the interrupt
 * callback; call/return events cannot be emulated. */
static int bridge_set_hook(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  const bridge_guest_api *ga = &s->api;
  lua_State *guest = decode_guest_ptr(L, args.first);
  int fn_ref = (int)lua_tointeger(L, args.first + 1);
  int mask = (int)lua_tointeger(L, args.first + 2);
  int count = (int)lua_tointeger(L, args.first + 3);

  if (s->abi == BRIDGE_ABI_LUAU &&
      (mask & (LUA_MASKCALL | LUA_MASKRET)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, "set_hook: call/return hooks are not supported by Luau");
    return 2;
  }

  slot_pushlightuserdata(s, guest, (void *)&hook_registry_key);
  slot_pushinteger(s, guest, fn_ref);
  ga->rawset(guest, s->registry_index);

  slot_pushlightuserdata(s, guest, (void *)&hook_owner_key);
  slot_pushlightuserdata(s, guest, (void *)L);
  ga->rawset(guest, s->registry_index);

  if (s->abi == BRIDGE_ABI_LUAU) {
    bridge_luau_callbacks *cb = ga->callbacks(guest);
    int line = (mask & LUA_MASKLINE) != 0;
    int counter = (mask & LUA_MASKCOUNT) != 0;
    int slot_index = (int)(s - g_slots);
    if (cb != NULL) {
      cb->debugstep = line ? g_hooks[slot_index] : NULL;
      cb->interrupt = counter ? g_interrupts[slot_index] : NULL;
    }
    ga->singlestep(guest, line ? 1 : 0);
  } else {
    int slot_index = (int)(s - g_slots);
    ga->sethook(guest, g_hooks[slot_index], mask, count);
    if (ga->setmode != NULL) {
      ga->setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_FLUSH);
      ga->setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
    }
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int bridge_remove_hook(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  const bridge_guest_api *ga = &s->api;
  lua_State *guest = decode_guest_ptr(L, args.first);

  slot_pushlightuserdata(s, guest, (void *)&hook_registry_key);
  ga->pushnil(guest);
  ga->rawset(guest, s->registry_index);

  slot_pushlightuserdata(s, guest, (void *)&hook_owner_key);
  ga->pushnil(guest);
  ga->rawset(guest, s->registry_index);

  if (s->abi == BRIDGE_ABI_LUAU) {
    bridge_luau_callbacks *cb = ga->callbacks(guest);
    if (cb != NULL) {
      cb->debugstep = NULL;
      cb->interrupt = NULL;
    }
    ga->singlestep(guest, 0);
  } else {
    ga->sethook(guest, NULL, 0, 0);
    if (ga->setmode != NULL)
      ga->setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int bridge_set_frame_meta(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_pushlightuserdata(L, (void *)&frame_meta_key);
  lua_pushvalue(L, 1);
  lua_rawset(L, LUA_REGISTRYINDEX);
  return 0;
}

/* ── Memory accounting ───────────────────────────────────────────────────── */

static const char mem_box_key = 0;

typedef struct {
  int64_t used;        /* bytes in use */
  int64_t limit;       /* cap, 0 = none */
  lua_Alloc old_alloc; /* the wrapped allocator */
  void *old_ud;        /* its context */
} mem_box;

/* Plain allocator used when the runtime has no allocator to wrap (Luau has
 * lua_getallocf but no lua_setallocf; its lua_newstate takes the allocator
 * directly). */
static void *default_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud;
  (void)osize;
  if (nsize == 0) {
    free(ptr);
    return NULL;
  }
  return realloc(ptr, nsize);
}

static void *limited_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  mem_box *box = (mem_box *)ud;
  void *np;

  if (nsize == 0) {
    box->used -= (int64_t)osize;
    return box->old_alloc(box->old_ud, ptr, osize, 0);
  }
  if (box->limit > 0 && nsize > osize &&
      box->used + (int64_t)(nsize - osize) > box->limit) {
    return NULL; /* over the cap: the guest gets "not enough memory" */
  }
  np = box->old_alloc(box->old_ud, ptr, osize, nsize);
  if (np != NULL) {
    box->used += (int64_t)nsize - (int64_t)osize;
  }
  return np;
}

static mem_box *guest_mem_box(const bridge_slot *s, lua_State *guest) {
  mem_box *box;
  slot_pushlightuserdata(s, guest, (void *)&mem_box_key);
  s->api.rawget(guest, s->registry_index);
  box = (mem_box *)s->api.touserdata(guest, -1);
  s->api.settop(guest, -2);
  return box;
}

static int bridge_new_state(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  const bridge_guest_api *ga = &s->api;

  mem_box *box = (mem_box *)malloc(sizeof(mem_box));
  lua_State *new_state = NULL;
  if (box == NULL) {
    lua_pushstring(L, "bridge_new_state: out of memory");
    lua_error(L);
    return 0;
  }
  box->used = 0;
  box->limit = 0;
  box->old_alloc = default_alloc;
  box->old_ud = NULL;

  if (s->abi == BRIDGE_ABI_JIT && ga->luaL_newstate != NULL &&
      ga->getallocf != NULL && ga->setallocf != NULL) {
    /* LuaJIT's own allocator creates the state; the counting wrapper is
     * installed on top of it right after, so every later block still comes
     * from the allocator that knows LuaJIT's rules (GC64 pointer space). */
    new_state = ga->luaL_newstate();
    if (new_state != NULL) {
      box->old_alloc = ga->getallocf(new_state, &box->old_ud);
      ga->setallocf(new_state, limited_alloc, box);
    }
  } else if (ga->newstate != NULL) {
    /* Lua 5.1/5.4/Luau take the counting allocator directly (default_alloc
     * underneath it). */
    new_state = ga->newstate(limited_alloc, box);
  }

  if (new_state == NULL) {
    free(box);
    lua_pushstring(L, "bridge_new_state: the guest runtime failed to create "
                      "a state");
    lua_error(L);
    return 0;
  }

  slot_pushlightuserdata(s, new_state, (void *)&mem_box_key);
  slot_pushlightuserdata(s, new_state, (void *)box);
  ga->rawset(new_state, s->registry_index);

  ga->openlibs(new_state);
  lua_pushlightuserdata(L, (void *)new_state);
  return 1;
}

static int bridge_memory_used(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  lua_State *guest = decode_guest_ptr(L, args.first);
  mem_box *box = guest_mem_box(s, guest);
  lua_pushinteger(L, (lua_Integer)(box ? box->used : 0));
  return 1;
}

static int bridge_set_memory_limit(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  lua_State *guest = decode_guest_ptr(L, args.first);
  mem_box *box = guest_mem_box(s, guest);
  if (box)
    box->limit = (int64_t)lua_tointeger(L, args.first + 1);
  return 0;
}

static int bridge_close_state(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  lua_State *guest = decode_guest_ptr(L, args.first);
  mem_box *box = guest_mem_box(s, guest);
  s->api.close_(guest);
  free(box);
  return 0;
}

/* ── Heap snapshot ───────────────────────────────────────────────────────── */

#define HW_BIG_TABLE 64
#define HW_MAX_FRAMES 2000
#define HW_MAX_SEGMENT 200
#define HW_MAX_KEY 40
#define HW_OTHER_PATH 0

#define HW_SLOT_SIZEOF 1
#define HW_SLOT_QUEUE 2
#define HW_SLOT_LOADED 3

static const char heap_thread_key = 0;

#define HW_REGION_SHIFT 20
#define HW_REGION_WORDS ((1u << HW_REGION_SHIFT) / 8 / 64)

typedef struct {
  uintptr_t region;
  uint64_t *bits;
} hw_region;

typedef struct {
  hw_region *regions;
  size_t mask;
  size_t count;
  hw_region *last;
} hw_set;

typedef struct {
  int parent;
  uint32_t hash;
  char *segment;
  size_t length;
  double self;
  double retained;
  double count;
} hw_path;

typedef struct {
  hw_path *items;
  int count;
  int cap;
  int *index;
  size_t index_mask;
} hw_paths;

typedef struct {
  int kind;
  int base;
  int path;
  int depth;
  int stage;
  int is_big, has_weak_keys, has_weak_values, has_pending_value;
  int array_path, other_path, value_path;
  double array_count, hash_count;
  int upvalue, upvalues;
  double bytes;
  lua_State *thread;
  int level, local, is_root;
} hw_frame;

typedef struct {
  bridge_slot *slot;
  lua_State *walker;
  hw_set seen;
  hw_paths paths;
  hw_frame *frames;
  int frame_count, frame_cap;
  int *queue_path, *queue_depth;
  int queue_count, queue_next, queue_cap;
  int max_depth, max_paths;
  double attributed, objects;
  int is_failed;
} hw_walk;

static hw_region *hw_region_slot(hw_region *regions, size_t mask,
                                 uintptr_t key) {
  size_t i = (size_t)((key * 0x9E3779B97F4A7C15ULL) >> 32) & mask;
  while (regions[i].region != 0 && regions[i].region != key)
    i = (i + 1) & mask;
  return &regions[i];
}

static int hw_set_add(hw_set *set, const void *p) {
  uintptr_t address = (uintptr_t)p;
  uintptr_t key = (address >> HW_REGION_SHIFT) + 1;
  hw_region *region = set->last;
  size_t bit;
  uint64_t flag;
  if (region == NULL || region->region != key) {
    region = hw_region_slot(set->regions, set->mask, key);
    if (region->region == 0) {
      if ((set->count + 1) * 2 > set->mask + 1) {
        size_t cap = (set->mask + 1) * 2, j;
        hw_region *regions = (hw_region *)calloc(cap, sizeof(hw_region));
        if (regions == NULL)
          return -1;
        for (j = 0; j <= set->mask; j++) {
          if (set->regions[j].region != 0) {
            *hw_region_slot(regions, cap - 1, set->regions[j].region) =
                set->regions[j];
          }
        }
        free(set->regions);
        set->regions = regions;
        set->mask = cap - 1;
        region = hw_region_slot(regions, set->mask, key);
      }
      region->bits = (uint64_t *)calloc(HW_REGION_WORDS, sizeof(uint64_t));
      if (region->bits == NULL)
        return -1;
      region->region = key;
      set->count++;
    }
    set->last = region;
  }
  bit = (size_t)((address & ((1u << HW_REGION_SHIFT) - 1)) >> 3);
  flag = (uint64_t)1 << (bit & 63);
  if (region->bits[bit >> 6] & flag)
    return 0;
  region->bits[bit >> 6] |= flag;
  return 1;
}

static uint32_t hw_hash_segment(int parent, const char *s, size_t n) {
  uint32_t h = 2166136261u ^ ((uint32_t)(parent + 1) * 16777619u);
  size_t i;
  for (i = 0; i < n; i++) {
    h ^= (unsigned char)s[i];
    h *= 16777619u;
  }
  return h;
}

static int hw_paths_get(hw_paths *paths, int parent, const char *segment,
                        size_t length, int max_paths) {
  uint32_t hash = hw_hash_segment(parent, segment, length);
  size_t i = hash & paths->index_mask;
  hw_path *path;
  while (paths->index[i] != 0) {
    path = &paths->items[paths->index[i] - 1];
    if (path->hash == hash && path->parent == parent &&
        path->length == length && memcmp(path->segment, segment, length) == 0) {
      return paths->index[i] - 1;
    }
    i = (i + 1) & paths->index_mask;
  }
  if (paths->count >= max_paths)
    return -1;
  if (paths->count == paths->cap) {
    int cap = paths->cap * 2;
    hw_path *items =
        (hw_path *)realloc(paths->items, (size_t)cap * sizeof(hw_path));
    if (items == NULL)
      return -2;
    paths->items = items;
    paths->cap = cap;
  }
  path = &paths->items[paths->count];
  path->segment = (char *)malloc(length);
  if (path->segment == NULL)
    return -2;
  memcpy(path->segment, segment, length);
  path->length = length;
  path->parent = parent;
  path->hash = hash;
  path->self = 0;
  path->retained = 0;
  path->count = 0;
  paths->index[i] = ++paths->count;

  if ((size_t)paths->count * 2 > paths->index_mask + 1) {
    size_t cap = (paths->index_mask + 1) * 2, j;
    int *index = (int *)calloc(cap, sizeof(int));
    if (index == NULL)
      return -2;
    for (j = 0; j < (size_t)paths->count; j++) {
      size_t k = paths->items[j].hash & (cap - 1);
      while (index[k] != 0)
        k = (k + 1) & (cap - 1);
      index[k] = (int)j + 1;
    }
    free(paths->index);
    paths->index = index;
    paths->index_mask = cap - 1;
  }
  return paths->count - 1;
}

static int hw_child(hw_walk *w, int parent, const char *segment, size_t length,
                    int depth) {
  int id;
  if (depth > w->max_depth)
    return parent;
  id = hw_paths_get(&w->paths, parent, segment, length, w->max_paths);
  if (id == -2)
    w->is_failed = 1;
  if (id < 0)
    return parent >= 0 ? parent : HW_OTHER_PATH;
  return id;
}

static void hw_add(hw_walk *w, int path, double bytes) {
  w->paths.items[path].self += bytes;
  w->attributed += bytes;
}

static size_t hw_format(char *out, const char *fmt, const char *a,
                        const char *b) {
  int n = snprintf(out, HW_MAX_SEGMENT, fmt, a, b);
  if (n < 0)
    return 0;
  return n >= HW_MAX_SEGMENT ? HW_MAX_SEGMENT - 1 : (size_t)n;
}

static int hw_is_identifier(const char *s, size_t n) {
  size_t i;
  if (n == 0 || n > HW_MAX_KEY)
    return 0;
  for (i = 0; i < n; i++) {
    char c = s[i];
    int is_alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    if (!is_alpha && (i == 0 || c < '0' || c > '9'))
      return 0;
  }
  return 1;
}

static double hw_cdata_size(hw_walk *w) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  double size = 16;
  if (ga->type(K, HW_SLOT_SIZEOF) == s->t_function) {
    ga->pushvalue(K, HW_SLOT_SIZEOF);
    ga->pushvalue(K, -2);
    if (slot_pcall(s, K, 1, 1, 0) == LUA_OK &&
        ga->type(K, -1) == LUA_TNUMBER) {
      size += slot_tonumber(s, K, -1);
    }
    ga->settop(K, -2);
  }
  return size;
}

static void hw_open(hw_walk *w, int kind, int path, int depth) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  hw_frame *f;
  if (w->frame_count == w->frame_cap) {
    int cap = w->frame_cap * 2;
    hw_frame *frames =
        (hw_frame *)realloc(w->frames, (size_t)cap * sizeof(hw_frame));
    if (frames == NULL) {
      w->is_failed = 1;
      ga->settop(K, -2);
      return;
    }
    w->frames = frames;
    w->frame_cap = cap;
  }
  if (!ga->checkstack(K, 8)) {
    w->is_failed = 1;
    ga->settop(K, -2);
    return;
  }
  f = &w->frames[w->frame_count++];
  memset(f, 0, sizeof(*f));
  f->kind = kind;
  f->base = ga->gettop(K);
  f->path = path;
  f->depth = depth;
  if (kind == s->t_thread) {
    int levels = 0;
    bridge_debug_ar ar;
    f->thread = ga->tothread(K, -1);
    memset(&ar, 0, sizeof(ar));
    while (slot_getstack(s, f->thread, levels, &ar))
      levels++;
    f->level = levels - 1;
  }
}

/* Replace stack slot `idx` with the value on top (popping it). */
static void slot_replace(const bridge_slot *s, lua_State *L, int idx) {
  if (s->api.replace != NULL) {
    s->api.replace(L, idx);
    return;
  }
  s->api.copy(L, -1, idx);
  s->api.settop(L, -2);
}

static void hw_enqueue(hw_walk *w, int path, int depth) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  if (ga->type(K, HW_SLOT_QUEUE) != s->t_table) {
    ga->createtable(K, 0, 0);
    if (hw_set_add(&w->seen, ga->topointer(K, -1)) < 0)
      w->is_failed = 1;
    slot_replace(s, K, HW_SLOT_QUEUE);
  }
  if (w->queue_count + 1 >= w->queue_cap) {
    int cap = w->queue_cap ? w->queue_cap * 2 : 256;
    int *paths = (int *)realloc(w->queue_path, (size_t)cap * sizeof(int));
    int *depths;
    if (paths != NULL)
      w->queue_path = paths;
    depths = (int *)realloc(w->queue_depth, (size_t)cap * sizeof(int));
    if (depths != NULL)
      w->queue_depth = depths;
    if (paths == NULL || depths == NULL) {
      w->is_failed = 1;
      ga->settop(K, -2);
      return;
    }
    w->queue_cap = cap;
  }
  w->queue_count++;
  w->queue_path[w->queue_count] = path;
  w->queue_depth[w->queue_count] = depth;
  ga->rawseti(K, HW_SLOT_QUEUE, w->queue_count);
}

static void hw_discover(hw_walk *w, int parent, int path, int depth) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  int type = ga->type(K, -1);
  int added;
  if (type != s->t_string && type != s->t_table && type != s->t_function &&
      type != s->t_userdata && type != s->t_thread &&
      (s->t_cdata < 0 || type != s->t_cdata)) {
    ga->settop(K, -2);
    return;
  }
  added = hw_set_add(&w->seen, ga->topointer(K, -1));
  if (added <= 0) {
    if (added < 0)
      w->is_failed = 1;
    ga->settop(K, -2);
    return;
  }
  w->objects++;
  if (path != parent)
    w->paths.items[path].count++;
  if (type == s->t_string) {
    size_t length;
    ga->tolstring(K, -1, &length);
    hw_add(w, path, 25.0 + (double)length);
    ga->settop(K, -2);
  } else if (s->t_cdata >= 0 && type == s->t_cdata) {
    hw_add(w, path, hw_cdata_size(w));
    ga->settop(K, -2);
  } else if (w->frame_count >= HW_MAX_FRAMES) {
    hw_enqueue(w, path, depth);
  } else {
    hw_open(w, type, path, depth);
  }
}

static void hw_finish(hw_walk *w, double bytes) {
  hw_frame *f = &w->frames[w->frame_count - 1];
  if (f->path >= 0)
    hw_add(w, f->path, bytes);
  w->slot->api.settop(w->walker, f->base - 1);
  w->frame_count--;
}

static void hw_step_table(hw_walk *w, hw_frame *f) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  int path = f->path, depth = f->depth;
  if (f->stage == 0) {
    f->stage = 1;
    if (ga->getmetatable(K, f->base)) {
      ga->pushstring(K, "__mode");
      ga->rawget(K, -2);
      if (ga->type(K, -1) == s->t_string) {
        const char *mode = ga->tolstring(K, -1, NULL);
        f->has_weak_keys = strchr(mode, 'k') != NULL;
        f->has_weak_values = strchr(mode, 'v') != NULL;
      }
      ga->settop(K, -2);
      hw_discover(w, path, hw_child(w, path, "<mt>", 4, depth + 1), depth + 1);
    }
    return;
  }
  if (f->stage == 1) {
    /* A big table is a collection: its keys are data, not field names. */
    int entries = 0;
    ga->pushnil(K);
    while (ga->next(K, f->base)) {
      ga->settop(K, -2);
      if (++entries > HW_BIG_TABLE) {
        ga->settop(K, -2);
        break;
      }
    }
    f->is_big = entries > HW_BIG_TABLE;
    f->array_path = hw_child(w, path, "[]", 2, depth + 1);
    f->other_path = hw_child(w, path, "[*]", 3, depth + 1);
    f->stage = 2;
    ga->pushnil(K);
    return;
  }
  if (f->has_pending_value) {
    /* [table, key, value]: the key's frame is done, the value is next. */
    f->has_pending_value = 0;
    if (f->has_weak_values) {
      ga->settop(K, -2);
    } else {
      int frames = w->frame_count;
      hw_discover(w, path, f->value_path, depth + 1);
      if (w->frame_count > frames)
        return;
    }
  }
  /* Entries run in this loop until one opens a frame: then the walk goes
   * deeper first and comes back here. */
  for (;;) {
    int value_path = f->other_path, frames, type;
    int key_type;
    if (!ga->next(K, f->base)) {
      double slots = 0;
      if (f->hash_count > 0) {
        slots = 1;
        while (slots < f->hash_count)
          slots *= 2;
      }
      hw_finish(w, 64 + (f->array_count > 0 ? 8 * (f->array_count + 1) : 0) +
                       24 * slots);
      return;
    }
    key_type = ga->type(K, -2);
    if (key_type == LUA_TNUMBER) {
      double n = slot_tonumber(s, K, -2);
      if (n >= 1 && n <= 9007199254740992.0 && n == (double)(int64_t)n) {
        f->array_count++;
        value_path = f->array_path;
      } else {
        f->hash_count++;
      }
    } else if (key_type == s->t_string) {
      size_t length;
      const char *key = ga->tolstring(K, -2, &length);
      int added = hw_set_add(&w->seen, ga->topointer(K, -2));
      f->hash_count++;
      if (added < 0)
        w->is_failed = 1;
      if (added > 0) {
        w->objects++;
        hw_add(w, path, 25.0 + (double)length);
      }
      if (!f->is_big && hw_is_identifier(key, length)) {
        char segment[HW_MAX_KEY + 1];
        segment[0] = '.';
        memcpy(segment + 1, key, length);
        value_path = hw_child(w, path, segment, length + 1, depth + 1);
      }
    } else if (key_type == LUA_TBOOLEAN || key_type == LUA_TLIGHTUSERDATA) {
      f->hash_count++;
    } else {
      f->hash_count++;
      if (!f->has_weak_keys) {
        frames = w->frame_count;
        f->value_path = value_path;
        f->has_pending_value = 1;
        ga->pushvalue(K, -2);
        hw_discover(w, path, hw_child(w, path, "<key>", 5, depth + 1),
                    depth + 1);
        if (w->frame_count > frames)
          return;
        f->has_pending_value = 0;
      }
    }
    if (w->is_failed)
      return;
    type = ga->type(K, -1);
    if (f->has_weak_values || type <= LUA_TNUMBER) {
      ga->settop(K, -2);
      continue;
    }
    frames = w->frame_count;
    hw_discover(w, path, value_path, depth + 1);
    if (w->frame_count > frames)
      return;
  }
}

static void hw_step_function(hw_walk *w, hw_frame *f) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  int path = f->path, depth = f->depth;
  if (f->stage == 0) {
    int nups = 0;
    int known = slot_nups(s, K, f->base, &nups);
    f->upvalues = known ? nups : -1;
    f->bytes = 40.0 + 8.0 * (f->upvalues > 0 ? f->upvalues : 0);
    f->stage = 1;
  }
  if (f->stage == 1) {
    while (f->upvalues < 0 || f->upvalue < f->upvalues) {
      int i = ++f->upvalue;
      const char *name;
      char segment[HW_MAX_SEGMENT];
      if (ga->upvalueid != NULL) {
        void *id = ga->upvalueid(K, f->base, i);
        if (id != NULL) {
          int added = hw_set_add(&w->seen, id);
          if (added < 0)
            w->is_failed = 1;
          if (added <= 0)
            continue;
        }
      }
      /* Closures share upvalue cells: count each cell once. */
      f->bytes += 48;
      name = ga->getupvalue(K, f->base, i);
      if (name == NULL) {
        f->upvalue--;
        break;
      }
      hw_discover(w, path,
                  hw_child(w, path, segment,
                           hw_format(segment, "<upvalue %s%s>",
                                     name[0] ? name : "?", ""),
                           depth + 1),
                  depth + 1);
      return;
    }
    f->stage = 2;
  }
  if (f->stage == 2) {
    f->stage = 3;
    if (ga->getfenv != NULL) {
      ga->getfenv(K, f->base);
      hw_discover(w, path, hw_child(w, path, "<env>", 5, depth + 1),
                  depth + 1);
      return;
    }
  }
  hw_finish(w, f->bytes);
}

static void hw_step_userdata(hw_walk *w, hw_frame *f) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  int path = f->path, depth = f->depth;
  if (f->stage == 0) {
    f->stage = 1;
    if (ga->getmetatable(K, f->base)) {
      hw_discover(w, path, hw_child(w, path, "<mt>", 4, depth + 1), depth + 1);
    }
    return;
  }
  if (f->stage == 1) {
    f->stage = 2;
    if (ga->getfenv != NULL) {
      ga->getfenv(K, f->base);
      hw_discover(w, path, hw_child(w, path, "<env>", 5, depth + 1),
                  depth + 1);
      return;
    }
  }
  hw_finish(w, 40);
}

/* Locals and functions of a thread's Lua frames, outermost frame first. */
static void hw_step_thread(hw_walk *w, hw_frame *f) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker, *T = f->thread;
  int parent = f->is_root ? -1 : f->path;
  int depth = f->is_root ? 1 : f->depth + 1;
  while (f->level >= 0) {
    bridge_debug_ar ar;
    bridge_debug dbg;
    char frame[HW_MAX_SEGMENT], segment[HW_MAX_SEGMENT];
    const char *source, *p;
    size_t length;
    memset(&ar, 0, sizeof(ar));
    if (!slot_getstack(s, T, f->level, &ar)) {
      f->level--;
      f->local = 0;
      continue;
    }
    slot_getinfo(s, T, f->level, "S", &ar);
    slot_debug_read(s, &ar, 0, &dbg);
    if (dbg.what != NULL && dbg.what[0] == 'C') {
      f->level--;
      f->local = 0;
      continue;
    }
    source = dbg.short_src != NULL ? dbg.short_src : "?";
    for (p = source; *p; p++) {
      if (*p == '/' || *p == '\\')
        source = p + 1;
    }
    if (dbg.what != NULL && strcmp(dbg.what, "main") == 0) {
      snprintf(frame, sizeof(frame), "%s", source);
    } else {
      snprintf(frame, sizeof(frame), "%s:%d", source, dbg.linedefined);
    }
    if (f->local >= 0) {
      const char *name = slot_getlocal(s, T, f->level, f->local + 1);
      if (name != NULL) {
        f->local++;
        ga->xmove(T, K, 1);
        length =
            hw_format(segment, f->is_root ? "%s:local %s" : "<%s:local %s>",
                      frame, name[0] == '(' ? "(temp)" : name);
        hw_discover(w, parent, hw_child(w, parent, segment, length, depth),
                    depth);
        return;
      }
      f->local = -1;
    }
    slot_getinfo(s, T, f->level, "f", &ar);
    ga->xmove(T, K, 1);
    f->level--;
    f->local = 0;
    length = hw_format(
        segment, f->is_root ? "%s:function%s" : "<%s:function%s>", frame, "");
    hw_discover(w, parent, hw_child(w, parent, segment, length, depth), depth);
    return;
  }
  hw_finish(w, f->is_root ? 0 : 200);
}

static void hw_drain(hw_walk *w) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  for (;;) {
    while (w->frame_count > 0 && !w->is_failed) {
      hw_frame *f = &w->frames[w->frame_count - 1];
      if (f->kind == s->t_table)
        hw_step_table(w, f);
      else if (f->kind == s->t_function)
        hw_step_function(w, f);
      else if (f->kind == s->t_thread)
        hw_step_thread(w, f);
      else
        hw_step_userdata(w, f);
    }
    if (w->is_failed || w->queue_next >= w->queue_count)
      return;
    w->queue_next++;
    ga->rawgeti(K, HW_SLOT_QUEUE, w->queue_next);
    ga->pushnil(K);
    ga->rawseti(K, HW_SLOT_QUEUE, w->queue_next);
    hw_open(w, ga->type(K, -1), w->queue_path[w->queue_next],
            w->queue_depth[w->queue_next]);
  }
}

static void hw_root(hw_walk *w, const char *label, size_t length) {
  hw_discover(w, -1, hw_child(w, -1, label, length, 1), 1);
  hw_drain(w);
}

static void hw_walk_roots(hw_walk *w, lua_State *guest) {
  bridge_slot *s = w->slot;
  const bridge_guest_api *ga = &s->api;
  lua_State *K = w->walker;
  char label[HW_MAX_SEGMENT];

  ga->settop(K, 0);
  ga->pushnil(K); /* HW_SLOT_SIZEOF */
  ga->pushnil(K); /* HW_SLOT_QUEUE */
  ga->pushstring(K, "_LOADED");
  ga->rawget(K, s->registry_index); /* HW_SLOT_LOADED */
  if (ga->type(K, HW_SLOT_LOADED) == s->t_table) {
    if (s->abi == BRIDGE_ABI_JIT) {
      ga->pushstring(K, "ffi");
      ga->rawget(K, HW_SLOT_LOADED);
      if (ga->type(K, -1) == s->t_table) {
        ga->pushstring(K, "sizeof");
        ga->rawget(K, -2);
        slot_replace(s, K, HW_SLOT_SIZEOF);
      }
      ga->settop(K, -2);
    }
    /* Its entries are roots of their own, not "_G.package.loaded[*]". */
    if (hw_set_add(&w->seen, ga->topointer(K, HW_SLOT_LOADED)) < 0)
      w->is_failed = 1;
  }
  if (hw_set_add(&w->seen, (const void *)K) < 0)
    w->is_failed = 1;
  if (hw_set_add(&w->seen, (const void *)guest) < 0)
    w->is_failed = 1;

  slot_pushglobals(s, K);
  hw_root(w, "_G", 2);

  if (ga->type(K, HW_SLOT_LOADED) == s->t_table) {
    ga->pushnil(K);
    while (!w->is_failed && ga->next(K, HW_SLOT_LOADED)) {
      size_t length = 1, i;
      const char *name = "?";
      if (ga->type(K, -2) == s->t_string)
        name = ga->tolstring(K, -2, &length);
      if (length > 150)
        length = 150;
      length = (size_t)snprintf(label, sizeof(label), "require(\"%.*s\")",
                                (int)length, name);
      for (i = 0; i < length; i++) {
        if ((unsigned char)label[i] < 32)
          label[i] = '?';
      }
      hw_root(w, label, length);
    }
  }

  ga->pushthread(guest);
  ga->xmove(guest, K, 1);
  hw_open(w, s->t_thread, -1, 0);
  if (w->frame_count > 0)
    w->frames[w->frame_count - 1].is_root = 1;
  hw_drain(w);

  ga->pushvalue(K, s->registry_index);
  hw_root(w, "registry", 8);
  ga->settop(K, 0);
}

/* Push the result table onto L. Ids grow from parent to child, so one pass
 * from the last id adds every path's bytes to its parent. */
static int hw_push_result(lua_State *L, hw_walk *w) {
  hw_paths *paths = &w->paths;
  size_t *offsets, *lengths, used = 0, cap = 4096;
  char *names;
  int i;

  for (i = paths->count - 1; i >= 0; i--) {
    hw_path *p = &paths->items[i];
    p->retained += p->self;
    if (p->parent >= 0)
      paths->items[p->parent].retained += p->retained;
  }

  offsets = (size_t *)malloc((size_t)paths->count * sizeof(size_t));
  lengths = (size_t *)malloc((size_t)paths->count * sizeof(size_t));
  names = (char *)malloc(cap);
  if (offsets == NULL || lengths == NULL || names == NULL) {
    free(offsets);
    free(lengths);
    free(names);
    return 0;
  }
  for (i = 0; i < paths->count; i++) {
    hw_path *p = &paths->items[i];
    size_t prefix = p->parent >= 0 ? lengths[p->parent] : 0;
    if (used + prefix + p->length > cap) {
      char *grown;
      while (used + prefix + p->length > cap)
        cap *= 2;
      grown = (char *)realloc(names, cap);
      if (grown == NULL) {
        free(offsets);
        free(lengths);
        free(names);
        return 0;
      }
      names = grown;
    }
    if (prefix > 0)
      memcpy(names + used, names + offsets[p->parent], prefix);
    memcpy(names + used + prefix, p->segment, p->length);
    offsets[i] = used;
    lengths[i] = prefix + p->length;
    used += lengths[i];
  }

  lua_createtable(L, 0, 5);
  lua_pushnumber(L, w->attributed);
  lua_setfield(L, -2, "attributed");
  lua_pushnumber(L, w->objects);
  lua_setfield(L, -2, "objects");
  lua_createtable(L, 0, paths->count); /* retained */
  lua_createtable(L, 0, paths->count); /* counts */
  lua_createtable(L, 0, paths->count); /* parents */
  for (i = 0; i < paths->count; i++) {
    hw_path *p = &paths->items[i];
    lua_pushlstring(L, names + offsets[i], lengths[i]);
    lua_pushnumber(L, p->retained);
    lua_rawset(L, -5);
    if (p->count > 0) {
      lua_pushlstring(L, names + offsets[i], lengths[i]);
      lua_pushnumber(L, p->count);
      lua_rawset(L, -4);
    }
    lua_pushlstring(L, names + offsets[i], lengths[i]);
    if (p->parent >= 0) {
      lua_pushlstring(L, names + offsets[p->parent], lengths[p->parent]);
    } else {
      lua_pushboolean(L, 0);
    }
    lua_rawset(L, -3);
  }
  lua_setfield(L, -4, "parents");
  lua_setfield(L, -3, "counts");
  lua_setfield(L, -2, "retained");

  free(offsets);
  free(lengths);
  free(names);
  return 1;
}

static void hw_free(hw_walk *w) {
  size_t j;
  int i;
  for (i = 0; i < w->paths.count; i++)
    free(w->paths.items[i].segment);
  free(w->paths.items);
  free(w->paths.index);
  if (w->seen.regions != NULL) {
    for (j = 0; j <= w->seen.mask; j++)
      free(w->seen.regions[j].bits);
  }
  free(w->seen.regions);
  free(w->frames);
  free(w->queue_path);
  free(w->queue_depth);
}

static int bridge_heap_snapshot(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  const bridge_guest_api *ga = &s->api;
  lua_State *guest = decode_guest_ptr(L, args.first);
  lua_State *walker;
  hw_walk w;
  int is_pushed;

  memset(&w, 0, sizeof(w));
  w.slot = s;
  w.max_depth = lua_type(L, args.first + 1) == LUA_TNUMBER
                    ? (int)lua_tonumber(L, args.first + 1)
                    : 10;
  w.max_paths = lua_type(L, args.first + 2) == LUA_TNUMBER
                    ? (int)lua_tonumber(L, args.first + 2)
                    : 20000;
  if (w.max_depth < 1)
    w.max_depth = 1;
  if (w.max_paths < 1)
    w.max_paths = 1;

  slot_pushlightuserdata(s, guest, (void *)&heap_thread_key);
  ga->rawget(guest, s->registry_index);
  walker = ga->tothread(guest, -1);
  ga->settop(guest, -2);
  if (walker == NULL) {
    walker = ga->newthread(guest);
    slot_pushlightuserdata(s, guest, (void *)&heap_thread_key);
    ga->pushvalue(guest, -2);
    ga->rawset(guest, s->registry_index);
    ga->settop(guest, -2);
  }
  w.walker = walker;

  w.seen.mask = 63;
  w.seen.regions = (hw_region *)calloc(w.seen.mask + 1, sizeof(hw_region));
  w.paths.cap = 256;
  w.paths.items = (hw_path *)malloc((size_t)w.paths.cap * sizeof(hw_path));
  w.paths.index_mask = 511;
  w.paths.index = (int *)calloc(w.paths.index_mask + 1, sizeof(int));
  w.frame_cap = 64;
  w.frames = (hw_frame *)malloc((size_t)w.frame_cap * sizeof(hw_frame));
  if (w.seen.regions == NULL || w.paths.items == NULL ||
      w.paths.index == NULL || w.frames == NULL ||
      hw_paths_get(&w.paths, -1, "<other>", 7, w.max_paths + 1) !=
          HW_OTHER_PATH) {
    hw_free(&w);
    return luaL_error(L, "heap_snapshot: out of memory");
  }

  if (!ga->checkstack(walker, 16))
    w.is_failed = 1;
  if (!w.is_failed)
    hw_walk_roots(&w, guest);
  ga->settop(walker, 0);

  is_pushed = !w.is_failed && hw_push_result(L, &w);
  hw_free(&w);
  if (!is_pushed)
    return luaL_error(L, "heap_snapshot: out of memory");
  return 1;
}

/* ── Runtime slot resolution ─────────────────────────────────────────────── */

static void *slot_sym(void *handle, const char *name) {
#ifdef _WIN32
  return (void *)(uintptr_t)GetProcAddress((HMODULE)handle, name);
#else
  return dlsym(handle, name);
#endif
}

static void configure_slot(bridge_slot *s, int abi) {
  memset(s, 0, sizeof(*s));
  s->abi = abi;
  switch (abi) {
  case BRIDGE_ABI_54:
    s->registry_index = LUA54_REGISTRYINDEX;
    s->upvalue_base = LUA54_REGISTRYINDEX;
    s->t_string = LUA_TSTRING;
    s->t_table = LUA_TTABLE;
    s->t_function = LUA_TFUNCTION;
    s->t_userdata = LUA_TUSERDATA;
    s->t_thread = LUA_TTHREAD;
    s->t_cdata = -1;
    break;
  case BRIDGE_ABI_LUAU:
    s->registry_index = LUA_REGISTRYINDEX; /* -10000 */
    s->upvalue_base = LUA_GLOBALSINDEX;    /* -10002 */
    s->t_string = 5;
    s->t_table = 6;
    s->t_function = 7;
    s->t_userdata = 8;
    s->t_thread = 9;
    s->t_cdata = -1;
    break;
  default:
    s->registry_index = LUA_REGISTRYINDEX;
    s->upvalue_base = LUA_GLOBALSINDEX;
    s->t_string = LUA_TSTRING;
    s->t_table = LUA_TTABLE;
    s->t_function = LUA_TFUNCTION;
    s->t_userdata = LUA_TUSERDATA;
    s->t_thread = LUA_TTHREAD;
    s->t_cdata = abi == BRIDGE_ABI_JIT ? LUA_TCDATA : -1;
    break;
  }
}

#define SLOT_NEED(api, field, type, name)                                     \
  do {                                                                        \
    void *p_ = slot_sym(handle, name);                                        \
    if (p_ == NULL)                                                           \
      return name;                                                            \
    (api)->field = (type)p_;                                                  \
  } while (0)

#define SLOT_OPT(api, field, type, name)                                      \
  do {                                                                        \
    (api)->field = (type)slot_sym(handle, name);                              \
  } while (0)

/* LuaJIT and PUC Lua 5.1 share the 5.1 ABI; jit adds luaJIT_setmode and
 * lua_upvalueid. */
static const char *resolve_51(bridge_slot *s, void *handle, int jit) {
  bridge_guest_api *a = &s->api;
  SLOT_NEED(a, gettop, int (*)(lua_State *), "lua_gettop");
  SLOT_NEED(a, settop, void (*)(lua_State *, int), "lua_settop");
  SLOT_NEED(a, pushvalue, void (*)(lua_State *, int), "lua_pushvalue");
  SLOT_NEED(a, type, int (*)(lua_State *, int), "lua_type");
  SLOT_NEED(a, typename_, const char *(*)(lua_State *, int), "lua_typename");
  SLOT_NEED(a, pushnil, void (*)(lua_State *), "lua_pushnil");
  SLOT_NEED(a, pushboolean, void (*)(lua_State *, int), "lua_pushboolean");
  SLOT_NEED(a, pushnumber, void (*)(lua_State *, double), "lua_pushnumber");
  SLOT_NEED(a, pushinteger, void (*)(lua_State *, int64_t), "lua_pushinteger");
  SLOT_NEED(a, pushlstring, void (*)(lua_State *, const char *, size_t),
            "lua_pushlstring");
  SLOT_NEED(a, pushstring, void (*)(lua_State *, const char *),
            "lua_pushstring");
  SLOT_NEED(a, pushfstring, const char *(*)(lua_State *, const char *, ...),
            "lua_pushfstring");
  SLOT_NEED(a, pushlightuserdata, void (*)(lua_State *, void *),
            "lua_pushlightuserdata");
  SLOT_NEED(a, pushcclosure, void (*)(lua_State *, lua_CFunction, int),
            "lua_pushcclosure");
  SLOT_NEED(a, toboolean, int (*)(lua_State *, int), "lua_toboolean");
  SLOT_NEED(a, tonumberx, double (*)(lua_State *, int, int *),
            "lua_tonumber");
  SLOT_NEED(a, tointegerx, int64_t (*)(lua_State *, int, int *),
            "lua_tointeger");
  SLOT_NEED(a, tolstring, const char *(*)(lua_State *, int, size_t *),
            "lua_tolstring");
  SLOT_NEED(a, touserdata, void *(*)(lua_State *, int), "lua_touserdata");
  SLOT_NEED(a, topointer, const void *(*)(lua_State *, int), "lua_topointer");
  SLOT_NEED(a, tothread, lua_State * (*)(lua_State *, int), "lua_tothread");
  SLOT_NEED(a, createtable, void (*)(lua_State *, int, int),
            "lua_createtable");
  SLOT_NEED(a, rawgeti, int (*)(lua_State *, int, int), "lua_rawgeti");
  SLOT_NEED(a, rawseti, void (*)(lua_State *, int, int), "lua_rawseti");
  SLOT_NEED(a, rawget, void (*)(lua_State *, int), "lua_rawget");
  SLOT_NEED(a, rawset, void (*)(lua_State *, int), "lua_rawset");
  SLOT_NEED(a, setfield, void (*)(lua_State *, int, const char *),
            "lua_setfield");
  SLOT_NEED(a, next, int (*)(lua_State *, int), "lua_next");
  SLOT_NEED(a, getmetatable, int (*)(lua_State *, int), "lua_getmetatable");
  SLOT_NEED(a, setmetatable, int (*)(lua_State *, int), "lua_setmetatable");
  SLOT_NEED(a, pcall, int (*)(lua_State *, int, int, int), "lua_pcall");
  SLOT_NEED(a, error_, void (*)(lua_State *), "lua_error");
  SLOT_NEED(a, ref_table, int (*)(lua_State *, int), "luaL_ref");
  SLOT_NEED(a, unref_table, void (*)(lua_State *, int, int), "luaL_unref");
  SLOT_NEED(a, newthread, lua_State * (*)(lua_State *), "lua_newthread");
  SLOT_NEED(a, pushthread, int (*)(lua_State *), "lua_pushthread");
  SLOT_NEED(a, xmove, void (*)(lua_State *, lua_State *, int), "lua_xmove");
  SLOT_NEED(a, checkstack, int (*)(lua_State *, int), "lua_checkstack");
  SLOT_NEED(a, getupvalue, const char *(*)(lua_State *, int, int),
            "lua_getupvalue");
  SLOT_NEED(a, getfenv, void (*)(lua_State *, int), "lua_getfenv");
  SLOT_NEED(a, replace, void (*)(lua_State *, int), "lua_replace");
  SLOT_NEED(a, luaL_newstate, lua_State * (*)(void), "luaL_newstate");
  SLOT_NEED(a, newstate, lua_State * (*)(lua_Alloc, void *), "lua_newstate");
  SLOT_NEED(a, openlibs, void (*)(lua_State *), "luaL_openlibs");
  SLOT_NEED(a, getallocf, lua_Alloc(*)(lua_State *, void **),
            "lua_getallocf");
  SLOT_NEED(a, setallocf, void (*)(lua_State *, lua_Alloc, void *),
            "lua_setallocf");
  SLOT_NEED(a, close_, void (*)(lua_State *), "lua_close");
  SLOT_NEED(a, getstack_native, int (*)(lua_State *, int, void *),
            "lua_getstack");
  SLOT_NEED(a, getinfo_native, int (*)(lua_State *, const char *, void *),
            "lua_getinfo");
  SLOT_NEED(a, getlocal_ar, const char *(*)(lua_State *, const void *, int),
            "lua_getlocal");
  SLOT_NEED(a, sethook,
            void (*)(lua_State *, void (*)(lua_State *, void *), int, int),
            "lua_sethook");
  a->debug_read = debug_read_51;
  a->debug_nups = debug_nups_51;
  if (jit) {
    SLOT_NEED(a, setmode, int (*)(lua_State *, int, int), "luaJIT_setmode");
    SLOT_NEED(a, upvalueid, void *(*)(lua_State *, int, int),
              "lua_upvalueid");
  } else {
    SLOT_OPT(a, upvalueid, void *(*)(lua_State *, int, int), "lua_upvalueid");
  }
  return NULL;
}

static const char *resolve_54(bridge_slot *s, void *handle) {
  bridge_guest_api *a = &s->api;
  SLOT_NEED(a, gettop, int (*)(lua_State *), "lua_gettop");
  SLOT_NEED(a, settop, void (*)(lua_State *, int), "lua_settop");
  SLOT_NEED(a, pushvalue, void (*)(lua_State *, int), "lua_pushvalue");
  SLOT_NEED(a, type, int (*)(lua_State *, int), "lua_type");
  SLOT_NEED(a, typename_, const char *(*)(lua_State *, int), "lua_typename");
  SLOT_NEED(a, pushnil, void (*)(lua_State *), "lua_pushnil");
  SLOT_NEED(a, pushboolean, void (*)(lua_State *, int), "lua_pushboolean");
  SLOT_NEED(a, pushnumber, void (*)(lua_State *, double), "lua_pushnumber");
  SLOT_NEED(a, pushinteger, void (*)(lua_State *, int64_t), "lua_pushinteger");
  SLOT_NEED(a, pushlstring, void (*)(lua_State *, const char *, size_t),
            "lua_pushlstring");
  SLOT_NEED(a, pushstring, void (*)(lua_State *, const char *),
            "lua_pushstring");
  SLOT_NEED(a, pushfstring, const char *(*)(lua_State *, const char *, ...),
            "lua_pushfstring");
  SLOT_NEED(a, pushlightuserdata, void (*)(lua_State *, void *),
            "lua_pushlightuserdata");
  SLOT_NEED(a, pushcclosure, void (*)(lua_State *, lua_CFunction, int),
            "lua_pushcclosure");
  SLOT_NEED(a, toboolean, int (*)(lua_State *, int), "lua_toboolean");
  SLOT_NEED(a, tonumberx, double (*)(lua_State *, int, int *),
            "lua_tonumberx");
  SLOT_NEED(a, tointegerx, int64_t (*)(lua_State *, int, int *),
            "lua_tointegerx");
  SLOT_NEED(a, tolstring, const char *(*)(lua_State *, int, size_t *),
            "lua_tolstring");
  SLOT_NEED(a, touserdata, void *(*)(lua_State *, int), "lua_touserdata");
  SLOT_NEED(a, topointer, const void *(*)(lua_State *, int), "lua_topointer");
  SLOT_NEED(a, tothread, lua_State * (*)(lua_State *, int), "lua_tothread");
  SLOT_NEED(a, createtable, void (*)(lua_State *, int, int),
            "lua_createtable");
  SLOT_NEED(a, rawgeti, int (*)(lua_State *, int, int), "lua_rawgeti");
  SLOT_NEED(a, rawseti, void (*)(lua_State *, int, int), "lua_rawseti");
  SLOT_NEED(a, rawget, void (*)(lua_State *, int), "lua_rawget");
  SLOT_NEED(a, rawset, void (*)(lua_State *, int), "lua_rawset");
  SLOT_NEED(a, setfield, void (*)(lua_State *, int, const char *),
            "lua_setfield");
  SLOT_NEED(a, next, int (*)(lua_State *, int), "lua_next");
  SLOT_NEED(a, getmetatable, int (*)(lua_State *, int), "lua_getmetatable");
  SLOT_NEED(a, setmetatable, int (*)(lua_State *, int), "lua_setmetatable");
  SLOT_NEED(a, pcallk, int (*)(lua_State *, int, int, int, intptr_t, void *),
            "lua_pcallk");
  SLOT_NEED(a, error_, void (*)(lua_State *), "lua_error");
  SLOT_NEED(a, ref_table, int (*)(lua_State *, int), "luaL_ref");
  SLOT_NEED(a, unref_table, void (*)(lua_State *, int, int), "luaL_unref");
  SLOT_NEED(a, newthread, lua_State * (*)(lua_State *), "lua_newthread");
  SLOT_NEED(a, pushthread, int (*)(lua_State *), "lua_pushthread");
  SLOT_NEED(a, xmove, void (*)(lua_State *, lua_State *, int), "lua_xmove");
  SLOT_NEED(a, checkstack, int (*)(lua_State *, int), "lua_checkstack");
  SLOT_NEED(a, getupvalue, const char *(*)(lua_State *, int, int),
            "lua_getupvalue");
  SLOT_NEED(a, upvalueid, void *(*)(lua_State *, int, int), "lua_upvalueid");
  SLOT_OPT(a, getfenv, void (*)(lua_State *, int), "lua_getfenv");
  SLOT_OPT(a, replace, void (*)(lua_State *, int), "lua_replace");
  SLOT_NEED(a, copy, void (*)(lua_State *, int, int), "lua_copy");
  SLOT_NEED(a, luaL_newstate, lua_State * (*)(void), "luaL_newstate");
  SLOT_NEED(a, newstate, lua_State * (*)(lua_Alloc, void *), "lua_newstate");
  SLOT_NEED(a, openlibs, void (*)(lua_State *), "luaL_openlibs");
  SLOT_NEED(a, getallocf, lua_Alloc(*)(lua_State *, void **),
            "lua_getallocf");
  SLOT_NEED(a, setallocf, void (*)(lua_State *, lua_Alloc, void *),
            "lua_setallocf");
  SLOT_NEED(a, close_, void (*)(lua_State *), "lua_close");
  SLOT_NEED(a, getstack_native, int (*)(lua_State *, int, void *),
            "lua_getstack");
  SLOT_NEED(a, getinfo_native, int (*)(lua_State *, const char *, void *),
            "lua_getinfo");
  SLOT_NEED(a, getlocal_ar, const char *(*)(lua_State *, const void *, int),
            "lua_getlocal");
  SLOT_NEED(a, sethook,
            void (*)(lua_State *, void (*)(lua_State *, void *), int, int),
            "lua_sethook");
  a->debug_read = debug_read_54;
  a->debug_nups = debug_nups_54;
  return NULL;
}

static const char *resolve_luau(bridge_slot *s, void *handle) {
  bridge_guest_api *a = &s->api;
  SLOT_NEED(a, gettop, int (*)(lua_State *), "lua_gettop");
  SLOT_NEED(a, settop, void (*)(lua_State *, int), "lua_settop");
  SLOT_NEED(a, pushvalue, void (*)(lua_State *, int), "lua_pushvalue");
  SLOT_NEED(a, type, int (*)(lua_State *, int), "lua_type");
  SLOT_NEED(a, typename_, const char *(*)(lua_State *, int), "lua_typename");
  SLOT_NEED(a, pushnil, void (*)(lua_State *), "lua_pushnil");
  SLOT_NEED(a, pushboolean, void (*)(lua_State *, int), "lua_pushboolean");
  SLOT_NEED(a, pushnumber, void (*)(lua_State *, double), "lua_pushnumber");
  /* Luau's lua_pushinteger/lua_tointegerx use a 32-bit lua_Integer. The
   * canonical pointers pass/return 64 bits; every value bridge stores or
   * reads is a small non-negative ref or slot number, so the register
   * truncation/zero-extension is exact. */
  SLOT_NEED(a, pushinteger, void (*)(lua_State *, int64_t),
            "lua_pushinteger");
  SLOT_NEED(a, pushlstring, void (*)(lua_State *, const char *, size_t),
            "lua_pushlstring");
  SLOT_NEED(a, pushstring, void (*)(lua_State *, const char *),
            "lua_pushstring");
  SLOT_NEED(a, pushfstring, const char *(*)(lua_State *, const char *, ...),
            "lua_pushfstringL");
  SLOT_NEED(a, pushlightuserdata_tag, void (*)(lua_State *, void *, int),
            "lua_pushlightuserdatatagged");
  SLOT_NEED(a, pushcclosurek,
            void (*)(lua_State *, lua_CFunction, const char *, int, void *),
            "lua_pushcclosurek");
  SLOT_NEED(a, toboolean, int (*)(lua_State *, int), "lua_toboolean");
  SLOT_NEED(a, tonumberx, double (*)(lua_State *, int, int *),
            "lua_tonumberx");
  SLOT_NEED(a, tointegerx, int64_t (*)(lua_State *, int, int *),
            "lua_tointegerx");
  SLOT_NEED(a, tolstring, const char *(*)(lua_State *, int, size_t *),
            "lua_tolstring");
  SLOT_NEED(a, touserdata, void *(*)(lua_State *, int), "lua_touserdata");
  SLOT_NEED(a, topointer, const void *(*)(lua_State *, int), "lua_topointer");
  SLOT_NEED(a, tothread, lua_State * (*)(lua_State *, int), "lua_tothread");
  SLOT_NEED(a, createtable, void (*)(lua_State *, int, int),
            "lua_createtable");
  SLOT_NEED(a, rawgeti, int (*)(lua_State *, int, int), "lua_rawgeti");
  SLOT_NEED(a, rawseti, void (*)(lua_State *, int, int), "lua_rawseti");
  SLOT_NEED(a, rawget, void (*)(lua_State *, int), "lua_rawget");
  SLOT_NEED(a, rawset, void (*)(lua_State *, int), "lua_rawset");
  SLOT_NEED(a, setfield, void (*)(lua_State *, int, const char *),
            "lua_setfield");
  SLOT_NEED(a, next, int (*)(lua_State *, int), "lua_next");
  SLOT_NEED(a, getmetatable, int (*)(lua_State *, int), "lua_getmetatable");
  SLOT_NEED(a, setmetatable, int (*)(lua_State *, int), "lua_setmetatable");
  SLOT_NEED(a, pcall, int (*)(lua_State *, int, int, int), "lua_pcall");
  SLOT_NEED(a, error_, void (*)(lua_State *), "lua_error");
  SLOT_NEED(a, ref_value, int (*)(lua_State *, int), "lua_ref");
  SLOT_NEED(a, unref_value, void (*)(lua_State *, int), "lua_unref");
  SLOT_NEED(a, newthread, lua_State * (*)(lua_State *), "lua_newthread");
  SLOT_NEED(a, pushthread, int (*)(lua_State *), "lua_pushthread");
  SLOT_NEED(a, xmove, void (*)(lua_State *, lua_State *, int), "lua_xmove");
  SLOT_NEED(a, checkstack, int (*)(lua_State *, int), "lua_checkstack");
  SLOT_NEED(a, getupvalue, const char *(*)(lua_State *, int, int),
            "lua_getupvalue");
  SLOT_NEED(a, getfenv, void (*)(lua_State *, int), "lua_getfenv");
  SLOT_NEED(a, replace, void (*)(lua_State *, int), "lua_replace");
  SLOT_OPT(a, luaL_newstate, lua_State * (*)(void), "luaL_newstate");
  SLOT_NEED(a, newstate, lua_State * (*)(lua_Alloc, void *), "lua_newstate");
  SLOT_NEED(a, openlibs, void (*)(lua_State *), "luaL_openlibs");
  SLOT_OPT(a, getallocf, lua_Alloc(*)(lua_State *, void **), "lua_getallocf");
  SLOT_NEED(a, close_, void (*)(lua_State *), "lua_close");
  SLOT_NEED(a, stackdepth, int (*)(lua_State *), "lua_stackdepth");
  SLOT_NEED(a, getinfo_level,
            int (*)(lua_State *, int, const char *, void *), "lua_getinfo");
  SLOT_NEED(a, getlocal_level, const char *(*)(lua_State *, int, int),
            "lua_getlocal");
  SLOT_NEED(a, callbacks, bridge_luau_callbacks * (*)(lua_State *),
            "lua_callbacks");
  SLOT_NEED(a, singlestep, void (*)(lua_State *, int), "lua_singlestep");
  a->debug_read = debug_read_luau;
  a->debug_nups = debug_nups_luau;
  return NULL;
}

static const char *resolve_slot(bridge_slot *s, void *handle) {
  switch (s->abi) {
  case BRIDGE_ABI_JIT:
    return resolve_51(s, handle, 1);
  case BRIDGE_ABI_51:
    return resolve_51(s, handle, 0);
  case BRIDGE_ABI_54:
    return resolve_54(s, handle);
  default:
    return resolve_luau(s, handle);
  }
}

static int parse_abi(const char *abi) {
  if (strcmp(abi, "jit") == 0)
    return BRIDGE_ABI_JIT;
  if (strcmp(abi, "5.1") == 0)
    return BRIDGE_ABI_51;
  if (strcmp(abi, "5.4") == 0)
    return BRIDGE_ABI_54;
  if (strcmp(abi, "luau") == 0)
    return BRIDGE_ABI_LUAU;
  return -1;
}

static void init_host_slot(void) {
  bridge_slot *s = &g_slots[0];
  if (s->used)
    return;
  configure_slot(s, BRIDGE_ABI_JIT);
  s->handle = NULL;
  s->api = host_api;
  s->used = 1;
}

static int bridge_runtime(lua_State *L) {
  const char *abi_name = lua_tostring(L, 2);
  int abi, handle_type, i;
  void *handle = NULL;

  if (abi_name == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "bridge.runtime: abi string expected");
    return 2;
  }
  abi = parse_abi(abi_name);
  if (abi < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "bridge.runtime: unsupported abi '%s'", abi_name);
    return 2;
  }

  handle_type = lua_type(L, 1);
  if (handle_type == LUA_TLIGHTUSERDATA)
    handle = lua_touserdata(L, 1);
  else if (handle_type == LUA_TCDATA)
    /* LuaJIT cannot mint a lightuserdata from Lua; image handles arrive as a
     * void* cdata. */
    handle = decode_cdata_value(L, 1);
  else if (handle_type == LUA_TNUMBER)
    handle = (void *)(uintptr_t)lua_tointeger(L, 1);
  else if (handle_type != LUA_TNONE && handle_type != LUA_TNIL) {
    lua_pushnil(L);
    lua_pushstring(L,
                   "bridge.runtime: handle must be a lightuserdata, cdata or "
                   "nil");
    return 2;
  }

  if (handle == NULL) {
    if (abi != BRIDGE_ABI_JIT) {
      lua_pushnil(L);
      lua_pushstring(L, "bridge.runtime: a nil handle only names the LuaJIT "
                        "that loaded lua-sys");
      return 2;
    }
    init_host_slot();
    lua_pushinteger(L, 0);
    return 1;
  }

  for (i = 1; i < BRIDGE_MAX_SLOTS; i++) {
    if (g_slots[i].used && g_slots[i].handle == handle &&
        g_slots[i].abi == abi) {
      lua_pushinteger(L, i);
      return 1;
    }
  }
  for (i = 1; i < BRIDGE_MAX_SLOTS; i++) {
    if (!g_slots[i].used)
      break;
  }
  if (i == BRIDGE_MAX_SLOTS) {
    lua_pushnil(L);
    lua_pushstring(L, "bridge.runtime: no free runtime slots (max 8)");
    return 2;
  }

  configure_slot(&g_slots[i], abi);
  g_slots[i].handle = handle;
  const char *missing = resolve_slot(&g_slots[i], handle);
  if (missing != NULL) {
    memset(&g_slots[i], 0, sizeof(g_slots[i]));
    lua_pushnil(L);
    lua_pushfstring(L, "bridge.runtime: %s does not export '%s'", abi_name,
                    missing);
    return 2;
  }
  g_slots[i].used = 1;
  lua_pushinteger(L, i);
  return 1;
}

/* ── Exported functions ──────────────────────────────────────────────────── */

static int bridge_register(lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_pushvalue(L, 1);
  luaJIT_setmode(L, -1, LUAJIT_MODE_FUNC | LUAJIT_MODE_OFF);
  int id = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushinteger(L, id);
  return 1;
}

static int bridge_push_callback(lua_State *L) {
  bridge_slot_args args;
  decode_slot_args(L, &args);
  bridge_slot *s = slot_at(L, args.slot);
  lua_State *guest = decode_guest_ptr(L, args.first);
  int fn_ref = (int)lua_tointeger(L, args.first + 1);
  int slow_ref = (int)lua_tointeger(L, args.first + 2);
  intptr_t depth_addr = (intptr_t)lua_tointeger(L, args.first + 3);
  intptr_t chain_addr = (intptr_t)lua_tointeger(L, args.first + 4);

  slot_pushinteger(s, guest, fn_ref);
  slot_pushinteger(s, guest, slow_ref);
  slot_pushlightuserdata(s, guest, (void *)L); /* upvalue 3: owner */
  if (args.slot == 0) {
    slot_pushinteger(s, guest, (int64_t)depth_addr);
    slot_pushinteger(s, guest, (int64_t)chain_addr);
  } else {
    slot_push_ptr(s, guest, (void *)depth_addr);
    slot_push_ptr(s, guest, (void *)chain_addr);
  }
  slot_pushcclosure(s, guest, g_dispatch[args.slot], 5);
  return 0;
}

static int bridge_unregister(lua_State *L) {
  int fn_ref = (int)lua_tointeger(L, 1);
  luaL_unref(L, LUA_REGISTRYINDEX, fn_ref);
  return 0;
}

static const luaL_Reg bridge_funcs[] = {
    {"runtime", bridge_runtime},
    {"make_callable", bridge_make_callable},
    {"compound_tag", bridge_compound_tag},
    {"register", bridge_register},
    {"push_callback", bridge_push_callback},
    {"unregister", bridge_unregister},
    {"set_hook", bridge_set_hook},
    {"remove_hook", bridge_remove_hook},
    {"set_frame_meta", bridge_set_frame_meta},
    {"new_state", bridge_new_state},
    {"close_state", bridge_close_state},
    {"memory_used", bridge_memory_used},
    {"set_memory_limit", bridge_set_memory_limit},
    {"heap_snapshot", bridge_heap_snapshot},
    {NULL, NULL}};

/* `caller` is the return address of luaopen, inside the VM of the LuaJIT
 * loading this module. */
static int bridge_open(lua_State *L, void *caller) {
  if (!bridge_resolve_symbols(caller)) {
    fprintf(stderr, "lua-sys: the LuaJIT loading lua-sys.bridge does not "
                    "export its C API\n");
    abort();
  }
  init_host_api();
  init_host_slot();
  luaL_register(L, "lua-sys.bridge", bridge_funcs);
  /* Seed this state's registry with the shared metatables. Other states
   * that share the same dlopen'd copy of this .so build them lazily. */
  init_callable_metatable(L);
  init_hook_info_metatable(L);
  return 1;
}

int luaopen_lua_sys_bridge(lua_State *L) {
  return bridge_open(L, __builtin_return_address(0));
}
int luaopen_sys_bridge(lua_State *L) {
  return bridge_open(L, __builtin_return_address(0));
}
int luaopen_bridge(lua_State *L) {
  return bridge_open(L, __builtin_return_address(0));
}
