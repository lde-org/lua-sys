// src/bridge.c
//
// C bridge for crossing between independent lua_State instances.
//
// lua_xmove cannot be used because host and guest states are created with
// separate luaL_newstate() calls and do not share a global_State. Only
// primitive values (nil, boolean, number, string) are copied directly;
// compound types (table, function, userdata, thread) are handled on the
// Lua side via registry refs.
//
// Every host↔guest transition is behind a lua_CFunction boundary. This is
// required because LuaJIT's JIT recorder crashes (argv2cdata in recff_cdata_call)
// when it tries to trace FFI calls on a lua_State* pointer encountered during
// re-entrant execution (host → guest → host). See docs/bridge-design.md.

#include "lua_bridge.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ── Windows symbol resolution ────────────────────────────────────────────
 *
 * PE DLLs cannot leave symbols unresolved for the loader to bind against the
 * process image (unlike ELF/Mach-O). Instead, lde exports all LuaJIT symbols
 * from the exe (-Wl,--export-all-symbols), and we resolve them here at module
 * load via GetProcAddress on the process handle. The lua_* names are defined
 * as static function pointers (lua_bridge.h hides its prototypes on Windows),
 * so bridge.dll has no undefined lua_* symbols and needs no import library.
 * This keeps a single LuaJIT runtime and a single allocator in the process,
 * exactly like the POSIX build. */
#ifdef _WIN32
#include <windows.h>

#define LDE_LUA_SYMS(X) \
    X(int,          lua_gettop,             (lua_State *L)) \
    X(void,         lua_settop,             (lua_State *L, int idx)) \
    X(void,         lua_pushvalue,          (lua_State *L, int idx)) \
    X(void,         lua_insert,             (lua_State *L, int idx)) \
    X(int,          lua_type,               (lua_State *L, int idx)) \
    X(const char *, lua_typename,           (lua_State *L, int tp)) \
    X(void,         lua_pushnil,            (lua_State *L)) \
    X(void,         lua_pushboolean,        (lua_State *L, int b)) \
    X(void,         lua_pushnumber,         (lua_State *L, lua_Number n)) \
    X(void,         lua_pushinteger,        (lua_State *L, lua_Integer n)) \
    X(void,         lua_pushlstring,        (lua_State *L, const char *s, size_t len)) \
    X(void,         lua_pushstring,         (lua_State *L, const char *s)) \
    X(const char *, lua_pushfstring,        (lua_State *L, const char *fmt, ...)) \
    X(void,         lua_pushlightuserdata,  (lua_State *L, void *p)) \
    X(void,         lua_pushcclosure,       (lua_State *L, lua_CFunction fn, int n)) \
    X(int,          lua_toboolean,          (lua_State *L, int idx)) \
    X(lua_Number,   lua_tonumber,           (lua_State *L, int idx)) \
    X(const char *, lua_tolstring,          (lua_State *L, int idx, size_t *len)) \
    X(void *,       lua_touserdata,         (lua_State *L, int idx)) \
    X(void,         lua_createtable,        (lua_State *L, int narr, int nrec)) \
    X(void,         lua_rawgeti,            (lua_State *L, int idx, int n)) \
    X(void,         lua_rawseti,            (lua_State *L, int idx, int n)) \
    X(void,         lua_setfield,           (lua_State *L, int idx, const char *k)) \
    X(int,          lua_pcall,              (lua_State *L, int nargs, int nresults, int errfunc)) \
    X(int,          lua_error,              (lua_State *L)) \
    X(lua_State *,  luaL_newstate,          (void)) \
    X(void,         luaL_openlibs,          (lua_State *L)) \
    X(void,         lua_close,              (lua_State *L)) \
    X(int,          luaJIT_setmode,         (lua_State *L, int idx, int mode)) \
    X(int,          luaL_ref,               (lua_State *L, int t)) \
    X(void,         luaL_unref,             (lua_State *L, int t, int ref)) \
    X(int,          luaL_error,             (lua_State *L, const char *fmt, ...)) \
    X(void,         luaL_checktype,         (lua_State *L, int narg, int t)) \
    X(void,         luaL_register,          (lua_State *L, const char *libname, const luaL_Reg *l)) \
    X(void,         lua_rawget,             (lua_State *L, int idx)) \
    X(void,         lua_rawset,             (lua_State *L, int idx)) \
    X(int,          lua_setmetatable,       (lua_State *L, int objindex)) \
    X(int,          lua_sethook,            (lua_State *L, lua_Hook func, int mask, int count)) \
    X(int,          lua_getstack,           (lua_State *L, int level, lua_Debug *ar)) \
    X(int,          lua_getinfo,            (lua_State *L, const char *what, lua_Debug *ar))

/* Each lua_* name becomes a static function pointer; every call site below
 * calls through it unchanged. */
#define LDE_DECLARE(ret, name, args) static ret (*name) args;
LDE_LUA_SYMS(LDE_DECLARE)
#undef LDE_DECLARE

static void bridge_resolve_symbols(void) {
    HMODULE exe = GetModuleHandleA(NULL);
#define LDE_RESOLVE(ret, name, args) *(FARPROC *)&name = GetProcAddress(exe, #name);
    LDE_LUA_SYMS(LDE_RESOLVE)
#undef LDE_RESOLVE
}
#endif /* _WIN32 */

static lua_State *host_L = NULL;

// ── Value copying ─────────────────────────────────────────────────────────

// Returns lua_type and pushes the value onto dst, or returns -1 for compound
// types (nothing pushed).
static int push_primitive_typed(lua_State *src, int idx, lua_State *dst) {
    int t = lua_type(src, idx);
    switch (t) {
    case LUA_TNIL:     lua_pushnil(dst); break;
    case LUA_TBOOLEAN: lua_pushboolean(dst, lua_toboolean(src, idx)); break;
    case LUA_TNUMBER:  lua_pushnumber(dst, lua_tonumber(src, idx)); break;
    case LUA_TSTRING: {
        size_t len;
        const char *s = lua_tolstring(src, idx, &len);
        lua_pushlstring(dst, s, len);
        break;
    }
    default: return -1; /* compound — nothing pushed */
    }
    return t;
}

static void push_primitive_or_error(lua_State *src, int idx, lua_State *dst) {
    if (push_primitive_typed(src, idx, dst) < 0) {
        lua_pushfstring(src, "bridge: cannot pass %s across independent states",
            lua_typename(src, lua_type(src, idx)));
        lua_error(src);
    }
}

// ── Guest state pointer decoding ─────────────────────────────────────────

static lua_State *decode_guest_ptr(lua_State *L, int stack_pos) {
    int t = lua_type(L, stack_pos);
    if (t == LUA_TNUMBER)
        return (lua_State *)(uintptr_t)lua_tonumber(L, stack_pos);
    if (t == LUA_TLIGHTUSERDATA)
        return (lua_State *)lua_touserdata(L, stack_pos);
    luaL_error(L, "bridge: arg %d must be a guest lua_State pointer", stack_pos);
    return NULL; /* unreachable: luaL_error longjmps */
}

// ── bound_call ────────────────────────────────────────────────────────────
//
// lua_CFunction returned by bridge.make_callable.
//
// Upvalue 1: lightuserdata  — guest lua_State*
// Upvalue 2: integer        — guest registry ref for the function
// Upvalue 3: table          — guestState (lua.State object)
// Upvalue 4: integer        — registry ref for callGuestSlow(guestState, guestRef, ...)
//
// All-primitive args/results go through the fast path (direct copy).
// Any compound arg or result falls back to callGuestSlow on the Lua side.

static int bound_call(lua_State *host) {
    lua_State *guest = (lua_State *)lua_touserdata(host, lua_upvalueindex(1));
    int fn_ref       = (int)lua_tointeger(host, lua_upvalueindex(2));
    int nargs        = lua_gettop(host);
    int guest_base   = lua_gettop(guest);

    /* Fast path: all args are primitives. */
    int i;
    int all_primitive = 1;
    for (i = 1; i <= nargs; i++) {
        int t = lua_type(host, i);
        if (t != LUA_TNIL && t != LUA_TBOOLEAN && t != LUA_TNUMBER && t != LUA_TSTRING) {
            all_primitive = 0;
            break;
        }
    }

    if (!all_primitive) {
        /* Slow path: delegate to callGuestSlow for Lua-side toLua() handling. */
        int slow_ref = (int)lua_tointeger(host, lua_upvalueindex(4));
        lua_rawgeti(host, LUA_REGISTRYINDEX, slow_ref);
        lua_pushvalue(host, lua_upvalueindex(3));
        lua_pushinteger(host, fn_ref);
        for (i = 1; i <= nargs; i++)
            lua_pushvalue(host, i);
        int status = lua_pcall(host, 2 + nargs, LUA_MULTRET, 0);
        if (status != LUA_OK) lua_error(host);
        return lua_gettop(host) - nargs;
    }

    lua_rawgeti(guest, LUA_REGISTRYINDEX, fn_ref);

    for (i = 1; i <= nargs; i++)
        push_primitive_or_error(host, i, guest);

    int status = lua_pcall(guest, nargs, LUA_MULTRET, 0);
    if (status != 0) {
        const char *err = lua_tostring(guest, -1);
        lua_settop(guest, guest_base);
        lua_pushstring(host, err ? err : "bridge: guest error");
        lua_error(host);
        return 0;
    }

    int nresults = lua_gettop(guest) - guest_base;
    if (nresults == 0) return 0; /* guest stack already at guest_base */

    for (i = 0; i < nresults; i++) {
        if (push_primitive_typed(guest, guest_base + 1 + i, host) < 0) {
            // Compound result — fall back to callGuestSlow with original args.
            lua_settop(host, nargs);
            lua_settop(guest, guest_base);

            int slow_ref = (int)lua_tointeger(host, lua_upvalueindex(4));
            lua_rawgeti(host, LUA_REGISTRYINDEX, slow_ref);
            lua_pushvalue(host, lua_upvalueindex(3));
            lua_pushinteger(host, fn_ref);
            for (i = 1; i <= nargs; i++)
                lua_pushvalue(host, i);
            status = lua_pcall(host, 2 + nargs, LUA_MULTRET, 0);
            if (status != LUA_OK) lua_error(host);
            return lua_gettop(host) - nargs;
        }
    }
    lua_settop(guest, guest_base);
    return nresults;
}

// ── bound_pcall ───────────────────────────────────────────────────────────
//
// `fn:pcall(...)` method attached to every bound_call closure via a shared
// function metatable (built in init_callable_metatable).
//
// Runs the same guest call as bound_call but with pcall semantics: returns
// `true, ...results` on success or `false, err` on error instead of raising a
// host error. The guest call itself is delegated to the bound_call closure at
// host stack index 1 (self), so the fast/slow path and compound-result
// handling are all reused unchanged.

static int bound_pcall(lua_State *host) {
    /* The method call `fn:pcall(a1, ..., aN)` arrives as [fn, a1..aN] with
       fn at index 1 — exactly the layout lua_pcall expects (callee at
       top - nargs). fn is the bound_call closure, so the whole guest call
       (fast path, slow path, compound results) is reused unchanged. */
    int nargs = lua_gettop(host) - 1; /* exclude self */
    int status = lua_pcall(host, nargs, LUA_MULTRET, 0);
    if (status != LUA_OK) {           /* [err] */
        lua_pushboolean(host, 0);
        lua_insert(host, 1);          /* [false, err] */
        return 2;
    }
    int nresults = lua_gettop(host);  /* [r1..rM] */
    lua_pushboolean(host, 1);
    lua_insert(host, 1);              /* [true, r1..rM] */
    return nresults + 1;
}

// Registry key for the shared callable metatable (built at module open).
static char callable_mt_key;

// Lightuserdata tag prefixing guest table registry refs passed host-side by
// dispatch_callback's slow path. bridge.compound_tag() returns it so the host
// can recognise (tag, ref) pairs.
static char compound_tag_key;

static int bridge_make_callable(lua_State *L) {
    // bound_call operates on host_L (it receives L == host_L via the C
    // function convention when called from host_L's Lua code). The closure
    // must be created on host_L so the upvalues are read from host_L's stack.
    // When called from a guest state (L != host_L), the guestState upvalue
    // (a table) cannot be moved across states, so we restrict this to host-only.
    if (L != host_L) {
        lua_pushstring(L, "bridge.make_callable must be called from host state");
        lua_error(L);
        return 0;
    }
    lua_State *guest = decode_guest_ptr(L, 1);
    lua_pushlightuserdata(host_L, (void *)guest); /* upvalue 1 */
    lua_pushvalue(host_L, 2);                     /* upvalue 2: guestRef */
    lua_pushvalue(host_L, 3);                     /* upvalue 3: guestState */
    lua_pushvalue(host_L, 4);                     /* upvalue 4: callGuestSlow ref */
    lua_pushcclosure(host_L, bound_call, 4);      /* the callable */
    lua_pushlightuserdata(host_L, (void *)&callable_mt_key);
    lua_rawget(host_L, LUA_REGISTRYINDEX);        /* shared fn:pcall() metatable */
    lua_setmetatable(host_L, -2);
    return 1;
}

// Build the metatable providing `fn:pcall()` on every bound_call closure and
// park it in the host registry under a lightuserdata key. Shared by all
// callables so each closure carries only the metatable reference.
static void init_callable_metatable(lua_State *L) {
    lua_createtable(L, 0, 1);         /* mt */
    lua_createtable(L, 0, 1);         /* methods */
    lua_pushcclosure(L, bound_pcall, 0);
    lua_setfield(L, -2, "pcall");     /* methods.pcall = bound_pcall */
    lua_setfield(L, -2, "__index");   /* mt.__index = methods */
    lua_pushlightuserdata(L, (void *)&callable_mt_key);
    lua_pushvalue(L, -2);             /* [mt, key, mt] */
    lua_rawset(L, LUA_REGISTRYINDEX); /* registry[key] = mt */
    lua_pop(L, 1);
}

static int bridge_compound_tag(lua_State *L) {
    lua_pushlightuserdata(L, (void *)&compound_tag_key);
    return 1;
}

// ── dispatch_callback ─────────────────────────────────────────────────────
//
// lua_CFunction installed on the guest state via bridge.push_callback.
// Upvalue 1: integer — registry ref for the host callback function.
// Upvalue 2: integer — registry ref for the host slow-path helper
//            (dispatchCallbackSlow), used when any argument is a table.
//
// host_L's stack must be fully restored on every exit path to avoid
// corrupting nested guest→host→guest→host call chains.

static int dispatch_callback(lua_State *guest) {
    int fn_ref     = (int)lua_tointeger(guest, lua_upvalueindex(1));
    int slow_ref   = (int)lua_tointeger(guest, lua_upvalueindex(2));
    int saved_top  = lua_gettop(host_L);
    int nargs      = lua_gettop(guest);
    int i;

    /* Fast path: all args are primitives. */
    int all_primitive = 1;
    for (i = 1; i <= nargs; i++) {
        int t = lua_type(guest, i);
        if (t != LUA_TNIL && t != LUA_TBOOLEAN && t != LUA_TNUMBER && t != LUA_TSTRING) {
            all_primitive = 0;
            break;
        }
    }

    int n_sent;
    if (!all_primitive) {
        /* Slow path: dispatchCallbackSlow(guest, fn, args...) — table args
         * cross as (TAG, guest_registry_ref) pairs so the Lua side can wrap
         * them in lua.Table proxies. */
        lua_rawgeti(host_L, LUA_REGISTRYINDEX, slow_ref);
        lua_pushlightuserdata(host_L, (void *)guest);
        lua_rawgeti(host_L, LUA_REGISTRYINDEX, fn_ref);
        n_sent = 2;
        for (i = 1; i <= nargs; i++) {
            if (lua_type(guest, i) == LUA_TTABLE) {
                lua_pushvalue(guest, i);
                int ref = luaL_ref(guest, LUA_REGISTRYINDEX);
                lua_pushlightuserdata(host_L, (void *)&compound_tag_key);
                lua_pushinteger(host_L, ref);
                n_sent += 2;
            } else {
                push_primitive_or_error(guest, i, host_L);
                n_sent += 1;
            }
        }
    } else {
        lua_rawgeti(host_L, LUA_REGISTRYINDEX, fn_ref);
        for (i = 1; i <= nargs; i++)
            push_primitive_or_error(guest, i, host_L);
        n_sent = nargs;
    }

    luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
    int status = lua_pcall(host_L, n_sent, LUA_MULTRET, 0);
    luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);

    if (status != LUA_OK) {
        const char *err = lua_tostring(host_L, -1);
        lua_pushstring(guest, err ? err : "bridge: host error");
        lua_settop(host_L, saved_top);
        lua_error(guest);
        return 0;
    }

    int nresults = lua_gettop(host_L) - saved_top;
    if (nresults == 0) return 0; /* host stack already at saved_top */

    for (i = 0; i < nresults; i++) {
        int t = push_primitive_typed(host_L, saved_top + 1 + i, guest);
        if (t < 0) {
            lua_settop(host_L, saved_top);
            lua_settop(guest, 0);
            lua_pushfstring(guest,
                "bridge: host callback returned a %s; "
                "only primitives (nil, boolean, number, string) "
                "can be returned from host to guest",
                lua_typename(host_L, lua_type(host_L, saved_top + 1 + i)));
            lua_error(guest);
            return 0;
        }
    }

    lua_settop(host_L, saved_top);
    return nresults;
}

// ── Exported functions ────────────────────────────────────────────────────

// Stores the host function in the registry, marks it LUAJIT_MODE_FUNC|OFF so
// the JIT never compiles it (prevents argv2cdata on lua_State* cdata args in
// FFI calls made by the callback — see docs/bridge-design.md), and returns
// the ref id. May be called from any state; the function is moved to host_L's
// registry so dispatch_callback (which operates on host_L) can retrieve it.
static int bridge_register(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    if (L == host_L) {
        lua_pushvalue(host_L, 1);
    } else {
        // Called from a guest state — move the function value into host_L's
        // stack slot so it can be stored in host_L's registry. The function
        // value on L's stack is a Lua object reference; we push it to host_L
        // via the slow-path approach: create a temporary guest function that
        // delegates back, then store the host function as a callback.
        //
        // For now, bridge_register must be called from the host. Nested-state
        // callbacks reach through toLua which always runs on the host side.
        lua_pushstring(L, "bridge.register must be called from host state");
        lua_error(L);
        return 0;
    }
    luaJIT_setmode(host_L, -1, LUAJIT_MODE_FUNC | LUAJIT_MODE_OFF);
    int id = luaL_ref(host_L, LUA_REGISTRYINDEX);
    lua_pushinteger(L, id);
    return 1;
}

// Pushes a dispatch_callback closure onto the guest state as a real
// lua_CFunction (not FFI cdata), preventing JIT tracing into the host.
static int bridge_push_callback(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    int fn_ref       = (int)lua_tointeger(L, 2);
    int slow_ref     = (int)lua_tointeger(L, 3);
    lua_pushinteger(guest, fn_ref);
    lua_pushinteger(guest, slow_ref);
    lua_pushcclosure(guest, dispatch_callback, 2);
    return 0;
}

static int bridge_unregister(lua_State *L) {
    int fn_ref = (int)lua_tointeger(L, 1);
    luaL_unref(host_L, LUA_REGISTRYINDEX, fn_ref);
    return 0;
}

// ── Debug hooks ───────────────────────────────────────────────────────────
//
// High-level counterpart to lua_sethook: the hook fires on the guest state
// while guest code runs, and dispatches to a host function stored in
// host_L's registry — the same host↔guest pattern as dispatch_callback.
// A lua_Hook is a plain C function pointer with no upvalues, so the host
// callback ref is parked in the guest registry under a private key that the
// hook looks up on every event.

static char hook_registry_key;
static char hook_meta_key;

static int hook_info_stack(lua_State *L);
static int hook_info_index(lua_State *L);

static const char *hook_event_name(int event) {
    switch (event) {
    case LUA_HOOKCALL:      return "call";
    case LUA_HOOKRET:       return "return";
    case LUA_HOOKLINE:      return "line";
    case LUA_HOOKCOUNT:     return "count";
    case LUA_HOOKTAILCALL:  return "tailcall";
    default:                return "?";
    }
}

// lua_Hook installed on the guest state by bridge_set_hook.
//
// The info table handed to the host callback carries every debug field
// (name, what, source, short_src, currentline, ...), `event`, `thread`, and
// a shared metatable providing info:stack(). The `_hook_active` flag is
// cleared when this function returns so a stored info table's stack() —
// which needs the guest thread paused at the hook — refuses instead of
// walking a stale stack.
static void hook_dispatch(lua_State *guest, lua_Debug *ar) {
    int saved_top = lua_gettop(host_L);

    /* Locate the host callback ref stored by bridge_set_hook. */
    lua_pushlightuserdata(guest, (void *)&hook_registry_key);
    lua_rawget(guest, LUA_REGISTRYINDEX);
    if (lua_isnil(guest, -1)) {
        lua_pop(guest, 1);
        return; /* hook removed between events — no-op */
    }
    int fn_ref = (int)lua_tointeger(guest, -1);
    lua_pop(guest, 1);

    /* Arg 1: event name. */
    lua_pushstring(host_L, hook_event_name(ar->event));

    /* Arg 2: info table with all debug fields populated eagerly. */
    lua_getinfo(guest, "Sln", ar);
    lua_createtable(host_L, 0, 12);
    lua_pushstring(host_L, hook_event_name(ar->event));
    lua_setfield(host_L, -2, "event");
    if (ar->name)     { lua_pushstring(host_L, ar->name); lua_setfield(host_L, -2, "name"); }
    if (ar->namewhat) { lua_pushstring(host_L, ar->namewhat); lua_setfield(host_L, -2, "namewhat"); }
    if (ar->what)     { lua_pushstring(host_L, ar->what); lua_setfield(host_L, -2, "what"); }
    if (ar->source)   { lua_pushstring(host_L, ar->source); lua_setfield(host_L, -2, "source"); }
    lua_pushstring(host_L, ar->short_src);
    lua_setfield(host_L, -2, "short_src");
    lua_pushinteger(host_L, ar->currentline); lua_setfield(host_L, -2, "currentline");
    lua_pushinteger(host_L, ar->linedefined); lua_setfield(host_L, -2, "linedefined");
    lua_pushinteger(host_L, ar->lastlinedefined); lua_setfield(host_L, -2, "lastlinedefined");
    lua_pushinteger(host_L, ar->nups); lua_setfield(host_L, -2, "nups");

    /* The thread the hook fired on — the guest main thread, or a coroutine
     * running inside it. */
    lua_pushlightuserdata(host_L, (void *)guest);
    lua_setfield(host_L, -2, "thread");
    lua_pushboolean(host_L, 1);
    lua_setfield(host_L, -2, "_hook_active");

    /* Shared metatable providing info:stack(). */
    lua_pushlightuserdata(host_L, (void *)&hook_meta_key);
    lua_rawget(host_L, LUA_REGISTRYINDEX);
    lua_setmetatable(host_L, -2);
    int info_idx = lua_gettop(host_L); /* info table stays put through pcall */

    lua_rawgeti(host_L, LUA_REGISTRYINDEX, fn_ref); /* callback fn */
    lua_pushvalue(host_L, -3);                      /* event */
    lua_pushvalue(host_L, -3);                      /* info table */

    luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
    int status = lua_pcall(host_L, 2, 0, 0);
    luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);

    /* The hook's ar is about to go out of scope — invalidate the info table
     * so a stored info:stack() refuses instead of walking a stale stack. */
    lua_pushstring(host_L, "_hook_active");
    lua_pushboolean(host_L, 0);
    lua_rawset(host_L, info_idx);

    if (status != LUA_OK) {
        /* A hook that raises aborts the running guest code with that error. */
        const char *err = lua_tostring(host_L, -1);
        lua_pushstring(guest, err ? err : "bridge: hook error");
        lua_settop(host_L, saved_top);
        lua_error(guest);
        return; /* unreachable: lua_error longjmps */
    }
    lua_settop(host_L, saved_top);
}

// info:stack() — walk the stack of the thread the hook fired on (level 0 =
// the frame the hook fired in), returning an array of frame tables, each
// with the same debug fields as the info table. Must be called from within
// the hook callback while the thread is still paused at the hook.
static int hook_info_stack(lua_State *L) {
    /* Refuse once the hook has returned (thread may have moved on). */
    lua_pushstring(L, "_hook_active");
    lua_rawget(L, 1);
    int active = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (!active) {
        lua_pushstring(L, "info:stack() must be called from within the hook callback");
        lua_error(L);
        return 0;
    }

    lua_pushstring(L, "thread");
    lua_rawget(L, 1); /* self.thread — lightuserdata of the guest lua_State */
    lua_State *guest = (lua_State *)lua_touserdata(L, -1);
    lua_pop(L, 1);

    lua_createtable(L, 8, 0);
    if (guest == NULL) return 1; /* defensive: no thread — empty trace */
    int level = 0;
    for (;;) {
        lua_Debug ar;
        if (!lua_getstack(guest, level, &ar)) break;
        lua_getinfo(guest, "Slnu", &ar);
        lua_createtable(L, 0, 10);
        if (ar.name)     { lua_pushstring(L, ar.name);     lua_setfield(L, -2, "name"); }
        if (ar.namewhat) { lua_pushstring(L, ar.namewhat); lua_setfield(L, -2, "namewhat"); }
        if (ar.what)     { lua_pushstring(L, ar.what);     lua_setfield(L, -2, "what"); }
        if (ar.source)   { lua_pushstring(L, ar.source);   lua_setfield(L, -2, "source"); }
        lua_pushstring(L, ar.short_src);        lua_setfield(L, -2, "short_src");
        lua_pushinteger(L, ar.currentline);     lua_setfield(L, -2, "currentline");
        lua_pushinteger(L, ar.linedefined);     lua_setfield(L, -2, "linedefined");
        lua_pushinteger(L, ar.lastlinedefined); lua_setfield(L, -2, "lastlinedefined");
        lua_pushinteger(L, ar.nups);            lua_setfield(L, -2, "nups");
        lua_rawseti(L, -2, level + 1);
        level++;
    }
    return 1;
}

// __index for hook info tables: provides info:stack(). All debug fields are
// populated eagerly, so only the method lookup takes this path.
static int hook_info_index(lua_State *L) {
    const char *key = lua_tostring(L, 2);
    if (key && strcmp(key, "stack") == 0) {
        lua_pushcclosure(L, hook_info_stack, 0);
        return 1;
    }
    return 0;
}

// Build the shared metatable providing `info:stack()` on every hook info
// table and park it in the host registry under a lightuserdata key (same
// pattern as init_callable_metatable), so hook_dispatch only pays a
// rawget + setmetatable per event.
static void init_hook_info_metatable(lua_State *L) {
    lua_createtable(L, 0, 1);           /* mt */
    lua_pushcclosure(L, hook_info_index, 0);
    lua_setfield(L, -2, "__index");     /* mt.__index = hook_info_index */
    lua_pushlightuserdata(L, (void *)&hook_meta_key);
    lua_pushvalue(L, -2);               /* [mt, key, mt] */
    lua_rawset(L, LUA_REGISTRYINDEX);   /* registry[key] = mt */
    lua_pop(L, 1);
}

// Stores the host callback ref in the guest registry and installs
// hook_dispatch as the guest's debug hook.
//
// LuaJIT only fires debug hooks from the interpreter — code compiled to
// traces never dispatches through the hook. To make hooks reliable we
// unpatch any existing traces and disable the JIT engine for as long as the
// hook is installed; bridge_remove_hook re-enables it.
static int bridge_set_hook(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    int fn_ref       = (int)lua_tointeger(L, 2);
    int mask         = (int)lua_tointeger(L, 3);
    int count        = (int)lua_tointeger(L, 4);

    lua_pushlightuserdata(guest, (void *)&hook_registry_key);
    lua_pushinteger(guest, fn_ref);
    lua_rawset(guest, LUA_REGISTRYINDEX);

    lua_sethook(guest, hook_dispatch, mask, count);
    luaJIT_setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_FLUSH); /* unpatch traces */
    luaJIT_setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);   /* stop compilation */
    return 0;
}

// Removes the debug hook, drops the stored callback ref, and re-enables
// the JIT engine that bridge_set_hook turned off.
static int bridge_remove_hook(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);

    lua_pushlightuserdata(guest, (void *)&hook_registry_key);
    lua_pushnil(guest);
    lua_rawset(guest, LUA_REGISTRYINDEX);

    lua_sethook(guest, NULL, 0, 0);
    luaJIT_setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
    return 0;
}

// Returns the new state as a lightuserdata so no lua_State* cdata crosses
// the call boundary — safe to call from within a guest callback.
static int bridge_new_state(lua_State *L) {
    lua_State *new_state = luaL_newstate();
    if (!new_state) {
        lua_pushstring(L, "bridge_new_state: luaL_newstate() returned NULL");
        lua_error(L);
        return 0;
    }
    luaL_openlibs(new_state);
    lua_pushlightuserdata(L, (void *)new_state);
    return 1;
}

// Close a guest Lua state created by bridge_new_state.
// This must be called instead of raw lua_close() so that on Windows the
// state is freed by bridge.dll's CRT — the same one that allocated it via
// luaL_newstate(). Using the host's lua_close() (via ffi.C) on a state
// allocated by bridge.dll's luaL_newstate() is a cross-CRT free and
// corrupts the heap.
static int bridge_close_state(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    lua_close(guest);
    return 0;
}

static const luaL_Reg bridge_funcs[] = {
    { "make_callable",   bridge_make_callable  },
    { "compound_tag",    bridge_compound_tag   },
    { "register",        bridge_register       },
    { "push_callback",   bridge_push_callback  },
    { "unregister",      bridge_unregister     },
    { "set_hook",        bridge_set_hook       },
    { "remove_hook",     bridge_remove_hook    },
    { "new_state",       bridge_new_state      },
    { "close_state",     bridge_close_state    },
    { NULL, NULL }
};

int luaopen_lua_sys_bridge(lua_State *L) {
#ifdef _WIN32
    bridge_resolve_symbols();
#endif
    if (!host_L) host_L = L;
    luaL_register(L, "lua-sys.bridge", bridge_funcs);
    init_callable_metatable(L);
    init_hook_info_metatable(L);
    return 1;
}

int luaopen_sys_bridge(lua_State *L) { return luaopen_lua_sys_bridge(L); }
int luaopen_bridge(lua_State *L)     { return luaopen_lua_sys_bridge(L); }