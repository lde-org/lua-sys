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
#include <stdio.h>
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
    X(lua_State *,  lua_newstate,           (lua_Alloc, void *)) \
    X(void,         luaL_openlibs,          (lua_State *L)) \
    X(void,         lua_close,              (lua_State *L)) \
    X(lua_Alloc,    lua_getallocf,          (lua_State *L, void **ud)) \
    X(void,         lua_setallocf,          (lua_State *L, lua_Alloc f, void *ud)) \
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
    X(int,          lua_getinfo,            (lua_State *L, const char *what, lua_Debug *ar)) \
    X(int,          lua_next,               (lua_State *L, int idx)) \
    X(int,          lua_getmetatable,       (lua_State *L, int objindex)) \
    X(void,         lua_getfenv,            (lua_State *L, int idx)) \
    X(const void *, lua_topointer,          (lua_State *L, int idx)) \
    X(lua_State *,  lua_tothread,           (lua_State *L, int idx)) \
    X(lua_State *,  lua_newthread,          (lua_State *L)) \
    X(int,          lua_pushthread,         (lua_State *L)) \
    X(void,         lua_xmove,              (lua_State *from, lua_State *to, int n)) \
    X(int,          lua_checkstack,         (lua_State *L, int extra)) \
    X(const char *, lua_getlocal,           (lua_State *L, const lua_Debug *ar, int n)) \
    X(const char *, lua_getupvalue,         (lua_State *L, int funcindex, int n)) \
    X(void *,       lua_upvalueid,          (lua_State *L, int funcindex, int n)) \
    X(void,         lua_replace,            (lua_State *L, int idx))

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

// ── Per-state ownership ───────────────────────────────────────────────────
//
// There is intentionally NO process-global "host state" pointer in this file.
// Every lua_State that loads lua-sys is self-contained: bridge.register stores
// callbacks in the calling state's own registry, and cross-state closures
// (bound_call, dispatch_callback, hook_dispatch) carry the state that owns
// their registrations explicitly (as an upvalue or a guest-registry entry).
//
// This matters because a dlopen'd copy of bridge.so may be shared by many
// states: on glibc, closing a state dlcloses the library (so each state gets
// a fresh image with fresh statics), but musl's dlclose is a no-op — a loaded
// image stays mapped forever, so a process-global static would be claimed by
// whichever state loaded the copy first and every later state would fail.
// Per-state ownership makes the design independent of dlopen/dlclose behavior.

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
// Upvalue 5: integer        — address of the owner's closed flag
// Upvalue 6: integer        — registry ref for convertGuestResults
//
// Primitive args and results copy directly. Compound args go through
// callGuestSlow on the Lua side. A compound result goes through
// convertGuestResults, which reads the results from the guest stack, so the
// guest function never runs a second time.

static int bound_call(lua_State *host) {
    /* lua-sys sets this flag before lua_close. Check it FIRST: the guest
     * pointer below dangles once the state is closed, so nothing may touch it
     * before this test. NULL means the closure carries no flag. */
    int *closed = (int *)(intptr_t)lua_tointeger(host, lua_upvalueindex(5));
    lua_State *guest;
    int fn_ref, nargs, guest_base;

    if (closed != NULL && *closed) {
        return luaL_error(host, "state is closed");
    }

    guest      = (lua_State *)lua_touserdata(host, lua_upvalueindex(1));
    fn_ref     = (int)lua_tointeger(host, lua_upvalueindex(2));
    nargs      = lua_gettop(host);
    guest_base = lua_gettop(guest);

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

    int all_primitive_res = 1;
    for (i = 0; i < nresults; i++) {
        int t = lua_type(guest, guest_base + 1 + i);
        if (t != LUA_TNIL && t != LUA_TBOOLEAN && t != LUA_TNUMBER && t != LUA_TSTRING) {
            all_primitive_res = 0;
            break;
        }
    }

    if (all_primitive_res) {
        for (i = 0; i < nresults; i++)
            push_primitive_typed(guest, guest_base + 1 + i, host);
        lua_settop(guest, guest_base);
        return nresults;
    }

    /* A compound result: convert each result on the Lua side, from the guest
     * stack. Do NOT call the guest function again — its side effects must
     * happen one time. */
    int convert_ref = (int)lua_tointeger(host, lua_upvalueindex(6));
    lua_rawgeti(host, LUA_REGISTRYINDEX, convert_ref);
    lua_pushvalue(host, lua_upvalueindex(3));   /* guestState */
    lua_pushinteger(host, guest_base + 1);      /* first result index */
    lua_pushinteger(host, nresults);
    status = lua_pcall(host, 3, LUA_MULTRET, 0);
    lua_settop(guest, guest_base);
    if (status != LUA_OK) lua_error(host);
    return lua_gettop(host) - nargs;
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

static void init_callable_metatable(lua_State *L);

// Lightuserdata tag prefixing guest table registry refs passed host-side by
// dispatch_callback's slow path. bridge.compound_tag() returns it so the host
// can recognise (tag, ref) pairs.
static char compound_tag_key;

static int bridge_make_callable(lua_State *L) {
    // bound_call operates on the state that created the closure: every state
    // that loads lua-sys is self-contained (its registrations live in its own
    // registry), so the callable is built on the calling state L with the
    // upvalues read from L's stack. There is no process-global host state.
    lua_State *guest = decode_guest_ptr(L, 1);
    lua_pushlightuserdata(L, (void *)guest);      /* upvalue 1 */
    lua_pushvalue(L, 2);                          /* upvalue 2: guestRef */
    lua_pushvalue(L, 3);                          /* upvalue 3: guestState */
    lua_pushvalue(L, 4);                          /* upvalue 4: callGuestSlow ref */
    lua_pushvalue(L, 5);                          /* upvalue 5: closed flag address */
    lua_pushvalue(L, 6);                          /* upvalue 6: result converter */
    lua_pushcclosure(L, bound_call, 6);           /* the callable */
    /* Ensure the fn:pcall() metatable exists in THIS state's registry. A
     * dlopen'd copy of bridge.so may be shared by many states (musl never
     * unloads libraries), so luaopen — and its init_callable_metatable — only
     * ran for whichever state opened the copy first. */
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

// Build the metatable providing `fn:pcall()` on every bound_call closure and
// park it in a state's registry under a lightuserdata key. Shared by all
// callables so each closure carries only the metatable reference. Called from
// luaopen (for the opening state) and lazily from bridge_make_callable (for
// every other state that shares the same dlopen'd copy).
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

// ── JIT engine guard ──────────────────────────────────────────────────────
//
// A host callback runs with the JIT engine off: a trace recorded inside it can
// attempt argv2cdata on a lua_State* FFI argument (docs/src/bridge-design.md).
// The counter is per owner state, so a nested callback (host -> guest -> host)
// does not enable the engine again while an outer callback still runs. A NULL
// counter keeps the plain behavior.

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

// ── dispatch_callback ─────────────────────────────────────────────────────
//
// lua_CFunction installed on the guest state via bridge.push_callback.
// Upvalue 1: integer — registry ref for the callback function.
// Upvalue 2: integer — registry ref for the slow-path helper
//            (dispatchCallbackSlow), used when any argument is a table.
// Upvalue 3: lightuserdata — the owner state whose registry holds the two
//            refs above (the state that called bridge.push_callback).
//
// The owner's stack must be fully restored on every exit path to avoid
// corrupting nested guest→host→guest→host call chains.

// The body returns -1 when the error message is on the guest stack. It never
// raises, so the chain guard of the caller always restores its counter.
static int dispatch_callback_body(lua_State *guest) {
    int fn_ref       = (int)lua_tointeger(guest, lua_upvalueindex(1));
    int slow_ref     = (int)lua_tointeger(guest, lua_upvalueindex(2));
    lua_State *owner = (lua_State *)lua_touserdata(guest, lua_upvalueindex(3));
    int saved_top    = lua_gettop(owner);
    int nargs        = lua_gettop(guest);
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
        lua_rawgeti(owner, LUA_REGISTRYINDEX, slow_ref);
        lua_pushlightuserdata(owner, (void *)guest);
        lua_rawgeti(owner, LUA_REGISTRYINDEX, fn_ref);
        n_sent = 2;
        for (i = 1; i <= nargs; i++) {
            if (lua_type(guest, i) == LUA_TTABLE) {
                lua_pushvalue(guest, i);
                int ref = luaL_ref(guest, LUA_REGISTRYINDEX);
                lua_pushlightuserdata(owner, (void *)&compound_tag_key);
                lua_pushinteger(owner, ref);
                n_sent += 2;
            } else {
                push_primitive_or_error(guest, i, owner);
                n_sent += 1;
            }
        }
    } else {
        lua_rawgeti(owner, LUA_REGISTRYINDEX, fn_ref);
        for (i = 1; i <= nargs; i++)
            push_primitive_or_error(guest, i, owner);
        n_sent = nargs;
    }

    int *depth = (int *)(intptr_t)lua_tointeger(guest, lua_upvalueindex(4));
    jit_guard_enter(owner, depth);
    int status = lua_pcall(owner, n_sent, LUA_MULTRET, 0);
    jit_guard_leave(owner, depth);

    if (status != LUA_OK) {
        const char *err = lua_tostring(owner, -1);
        lua_pushstring(guest, err ? err : "bridge: host error");
        lua_settop(owner, saved_top);
        return -1;
    }

    int nresults = lua_gettop(owner) - saved_top;
    if (nresults == 0) return 0; /* owner stack already at saved_top */

    for (i = 0; i < nresults; i++) {
        int t = push_primitive_typed(owner, saved_top + 1 + i, guest);
        if (t < 0) {
            lua_settop(owner, saved_top);
            lua_settop(guest, 0);
            lua_pushfstring(guest,
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

// Guest -> host dispatch, with the chain guard.
//
// Every level of a nested host <-> guest chain passes through this function, so
// its counter is the depth of the chain. Each level costs C stack, and a chain
// that is too deep stops the process: deepen it inside a tail call on the guest
// side and the guest Lua stack stays flat, so only the C stack grows. The
// counter belongs to the guest state (upvalue 5): box[0] is the current depth
// and box[1] is the limit (0 = no limit).
static int dispatch_callback(lua_State *guest) {
    int *box = (int *)(intptr_t)lua_tointeger(guest, lua_upvalueindex(5));
    if (box == NULL) {
        int n = dispatch_callback_body(guest);
        if (n < 0) lua_error(guest);
        return n;
    }

    if (box[1] > 0 && box[0] >= box[1]) {
        lua_pushfstring(guest,
            "bridge: the cross-state call chain reached its limit of %d levels "
            "(state:setChainLimit)", box[1]);
        lua_error(guest);
        return 0;
    }

    box[0]++;
    int n = dispatch_callback_body(guest);
    box[0]--;
    if (n < 0) lua_error(guest);
    return n;
}

// ── Exported functions ────────────────────────────────────────────────────

// Stores the function in the CALLING state's registry, marks it
// LUAJIT_MODE_FUNC|OFF so the JIT never compiles it (prevents argv2cdata on
// lua_State* cdata args in FFI calls made by the callback — see
// docs/bridge-design.md), and returns the ref id. Every state is
// self-contained: the ref lands in L's own registry, and the dispatch
// closures that consume it carry L (the owner) explicitly.
static int bridge_register(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    luaJIT_setmode(L, -1, LUAJIT_MODE_FUNC | LUAJIT_MODE_OFF);
    int id = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pushinteger(L, id);
    return 1;
}

// Pushes a dispatch_callback closure onto the guest state as a real
// lua_CFunction (not FFI cdata), preventing JIT tracing into the host.
// L is the OWNER: the state whose registry holds fn_ref/slow_ref. The owner
// is baked into the closure as upvalue 3 so dispatch_callback can reach the
// registrations without a process-global state pointer.
static int bridge_push_callback(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    int fn_ref       = (int)lua_tointeger(L, 2);
    int slow_ref     = (int)lua_tointeger(L, 3);
    lua_pushinteger(guest, fn_ref);
    lua_pushinteger(guest, slow_ref);
    lua_pushlightuserdata(guest, (void *)L); /* upvalue 3: owner */
    lua_pushinteger(guest, lua_tointeger(L, 4)); /* upvalue 4: JIT depth counter */
    lua_pushinteger(guest, lua_tointeger(L, 5)); /* upvalue 5: chain depth box */
    lua_pushcclosure(guest, dispatch_callback, 5);
    return 0;
}

static int bridge_unregister(lua_State *L) {
    int fn_ref = (int)lua_tointeger(L, 1);
    luaL_unref(L, LUA_REGISTRYINDEX, fn_ref);
    return 0;
}

// ── Debug hooks ───────────────────────────────────────────────────────────
//
// High-level counterpart to lua_sethook: the hook fires on the guest state
// while guest code runs, and dispatches to a callback function stored in the
// OWNER state's registry (the state that installed the hook) — the same
// owner↔guest pattern as dispatch_callback. A lua_Hook is a plain C function
// pointer with no upvalues, so the callback ref AND the owner pointer are
// parked in the guest registry under private keys that the hook looks up on
// every event.

static char hook_registry_key;
static char hook_meta_key;
static char hook_owner_key;

/* Host-side lua.Frame class, registered via bridge.set_frame_meta; applied as
 * the metatable of every frame returned by info:stack() so Frame methods
 * (locals, getLocal, setLocal, eval, ...) resolve through __index. Stored per
 * state under a lightuserdata registry key — not a process-global ref —
 * because a dlopen'd copy of bridge.so may be shared by many states. */
static char frame_meta_key;

static int hook_info_stack(lua_State *L);
static int hook_info_index(lua_State *L);
static void init_hook_info_metatable(lua_State *L);

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
    /* Locate the callback ref AND the owner state stored by bridge_set_hook. */
    lua_pushlightuserdata(guest, (void *)&hook_registry_key);
    lua_rawget(guest, LUA_REGISTRYINDEX);
    if (lua_isnil(guest, -1)) {
        lua_pop(guest, 1);
        return; /* hook removed between events — no-op */
    }
    int fn_ref = (int)lua_tointeger(guest, -1);
    lua_pop(guest, 1);

    lua_pushlightuserdata(guest, (void *)&hook_owner_key);
    lua_rawget(guest, LUA_REGISTRYINDEX);
    if (lua_type(guest, -1) != LUA_TLIGHTUSERDATA) {
        lua_pop(guest, 1);
        return; /* stale hook entry without an owner — no-op */
    }
    lua_State *owner = (lua_State *)lua_touserdata(guest, -1);
    lua_pop(guest, 1);

    int saved_top = lua_gettop(owner);

    /* Arg 1: event name. */
    lua_pushstring(owner, hook_event_name(ar->event));

    /* Arg 2: info table with all debug fields populated eagerly. */
    lua_getinfo(guest, "Sln", ar);
    lua_createtable(owner, 0, 12);
    lua_pushstring(owner, hook_event_name(ar->event));
    lua_setfield(owner, -2, "event");
    if (ar->name)     { lua_pushstring(owner, ar->name); lua_setfield(owner, -2, "name"); }
    if (ar->namewhat) { lua_pushstring(owner, ar->namewhat); lua_setfield(owner, -2, "namewhat"); }
    if (ar->what)     { lua_pushstring(owner, ar->what); lua_setfield(owner, -2, "what"); }
    if (ar->source)   { lua_pushstring(owner, ar->source); lua_setfield(owner, -2, "source"); }
    lua_pushstring(owner, ar->short_src);
    lua_setfield(owner, -2, "short_src");
    lua_pushinteger(owner, ar->currentline); lua_setfield(owner, -2, "currentline");
    lua_pushinteger(owner, ar->linedefined); lua_setfield(owner, -2, "linedefined");
    lua_pushinteger(owner, ar->lastlinedefined); lua_setfield(owner, -2, "lastlinedefined");
    lua_pushinteger(owner, ar->nups); lua_setfield(owner, -2, "nups");

    /* The thread the hook fired on — the guest main thread, or a coroutine
     * running inside it. */
    lua_pushlightuserdata(owner, (void *)guest);
    lua_setfield(owner, -2, "thread");
    lua_pushboolean(owner, 1);
    lua_setfield(owner, -2, "_hook_active");

    /* Shared metatable providing info:stack() — ensure it exists in the
     * owner's registry (the .so image may be shared by many states). */
    lua_pushlightuserdata(owner, (void *)&hook_meta_key);
    lua_rawget(owner, LUA_REGISTRYINDEX);
    if (lua_isnil(owner, -1)) {
        lua_pop(owner, 1);
        init_hook_info_metatable(owner);
        lua_pushlightuserdata(owner, (void *)&hook_meta_key);
        lua_rawget(owner, LUA_REGISTRYINDEX);
    }
    lua_setmetatable(owner, -2);
    int info_idx = lua_gettop(owner); /* info table stays put through pcall */

    lua_rawgeti(owner, LUA_REGISTRYINDEX, fn_ref); /* callback fn */
    lua_pushvalue(owner, -3);                      /* event */
    lua_pushvalue(owner, -3);                      /* info table */

    luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
    int status = lua_pcall(owner, 2, 0, 0);
    luaJIT_setmode(owner, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);

    /* The hook's ar is about to go out of scope — invalidate the info table
     * so a stored info:stack() refuses instead of walking a stale stack. */
    lua_pushstring(owner, "_hook_active");
    lua_pushboolean(owner, 0);
    lua_rawset(owner, info_idx);

    if (status != LUA_OK) {
        /* A hook that raises aborts the running guest code with that error. */
        const char *err = lua_tostring(owner, -1);
        lua_pushstring(guest, err ? err : "bridge: hook error");
        lua_settop(owner, saved_top);
        lua_error(guest);
        return; /* unreachable: lua_error longjmps */
    }
    lua_settop(owner, saved_top);
}

// info:stack() — walk the stack of the thread the hook fired on (level 0 =
// the frame the hook fired in), returning an array of lua.Frame objects,
// each with the debug fields plus thread/level and the Frame metatable so
// the host can read/write locals and upvalues and eval in the frame. Must
// be called from within the hook callback while the thread is paused.
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
        lua_createtable(L, 0, 12);
        if (ar.name)     { lua_pushstring(L, ar.name);     lua_setfield(L, -2, "name"); }
        if (ar.namewhat) { lua_pushstring(L, ar.namewhat); lua_setfield(L, -2, "namewhat"); }
        if (ar.what)     { lua_pushstring(L, ar.what);     lua_setfield(L, -2, "what"); }
        if (ar.source)   { lua_pushstring(L, ar.source);   lua_setfield(L, -2, "source"); }
        lua_pushstring(L, ar.short_src);        lua_setfield(L, -2, "short_src");
        lua_pushinteger(L, ar.currentline);     lua_setfield(L, -2, "currentline");
        lua_pushinteger(L, ar.linedefined);     lua_setfield(L, -2, "linedefined");
        lua_pushinteger(L, ar.lastlinedefined); lua_setfield(L, -2, "lastlinedefined");
        lua_pushinteger(L, ar.nups);            lua_setfield(L, -2, "nups");
        lua_pushlightuserdata(L, (void *)guest);
        lua_setfield(L, -2, "thread");
        lua_pushinteger(L, level);
        lua_setfield(L, -2, "level");
        /* Keep the info table on the frame: it clears _hook_active when the
         * hook returns, so a stale frame can refuse before it touches the
         * guest thread. */
        lua_pushvalue(L, 1);
        lua_setfield(L, -2, "_info");
        /* Attach the host-side lua.Frame class (registered via
         * bridge.set_frame_meta in this state's registry) so Frame methods
         * resolve via __index. */
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
// table and park it in a state's registry under a lightuserdata key (same
// pattern as init_callable_metatable), so hook_dispatch only pays a
// rawget + setmetatable per event. Called from luaopen (for the opening
// state) and lazily from hook_dispatch (for every other state that shares
// the same dlopen'd copy).
static void init_hook_info_metatable(lua_State *L) {
    lua_createtable(L, 0, 1);           /* mt */
    lua_pushcclosure(L, hook_info_index, 0);
    lua_setfield(L, -2, "__index");     /* mt.__index = hook_info_index */
    lua_pushlightuserdata(L, (void *)&hook_meta_key);
    lua_pushvalue(L, -2);               /* [mt, key, mt] */
    lua_rawset(L, LUA_REGISTRYINDEX);   /* registry[key] = mt */
    lua_pop(L, 1);
}

// Stores the callback ref in the guest registry — together with the OWNER
// state (L, whose registry holds the actual callback function) — and
// installs hook_dispatch as the guest's debug hook.
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

    lua_pushlightuserdata(guest, (void *)&hook_owner_key);
    lua_pushlightuserdata(guest, (void *)L);
    lua_rawset(guest, LUA_REGISTRYINDEX);

    lua_sethook(guest, hook_dispatch, mask, count);
    luaJIT_setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_FLUSH); /* unpatch traces */
    luaJIT_setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);   /* stop compilation */
    return 0;
}

// Removes the debug hook, drops the stored callback ref and owner, and
// re-enables the JIT engine that bridge_set_hook turned off.
static int bridge_remove_hook(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);

    lua_pushlightuserdata(guest, (void *)&hook_registry_key);
    lua_pushnil(guest);
    lua_rawset(guest, LUA_REGISTRYINDEX);

    lua_pushlightuserdata(guest, (void *)&hook_owner_key);
    lua_pushnil(guest);
    lua_rawset(guest, LUA_REGISTRYINDEX);

    lua_sethook(guest, NULL, 0, 0);
    luaJIT_setmode(guest, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
    return 0;
}

// Stores the host-side lua.Frame class table as the metatable for frames
// returned by info:stack(), so Frame methods resolve via __index. Called by
// init.lua at module load in every state that loads lua-sys; stored in the
// calling state's own registry (a dlopen'd copy of bridge.so may be shared
// by many states, so a process-global ref would point at the wrong registry).
static int bridge_set_frame_meta(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushlightuserdata(L, (void *)&frame_meta_key);
    lua_pushvalue(L, 1);
    lua_rawset(L, LUA_REGISTRYINDEX);
    return 0;
}

// Returns the new state as a lightuserdata so no lua_State* cdata crosses
// the call boundary — safe to call from within a guest callback.
// ── Memory accounting ─────────────────────────────────────────────────────
//
// Every guest state counts its own allocations, so the host can read the usage
// and set a hard cap. box->used is the bytes in use, box->limit is the cap
// (0 = no cap).
//
// The box is allocated here, in C, and stashed in the guest's registry as a
// lightuserdata, so no pointer ever crosses the Lua boundary as a number: a
// pointer carried through a Lua number is rounded to a double above 2^53 and
// comes back corrupted. The box lives exactly as long as the guest state — it
// is freed by bridge_close_state.

/* Registry key under which the guest state's mem_box is stored. */
static const char mem_box_key = 0;

/* The state is created with luaL_newstate(), i.e. with LuaJIT's own allocator,
 * and the counting allocator wraps that one. Blocks keep coming from the
 * allocator that already knows LuaJIT's rules — notably the 47-bit GC64
 * pointer space, where a plain malloc() block above the limit makes
 * lua_newstate() refuse the state (the ARM64 CI crash) — while the wrapper
 * only counts bytes and enforces the cap. */
typedef struct {
    int64_t used;        /* bytes in use */
    int64_t limit;       /* cap, 0 = none */
    lua_Alloc old_alloc; /* the wrapped allocator (LuaJIT's own) */
    void *old_ud;        /* its context */
} mem_box;

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

/* The mem_box of a guest state, or NULL when it has none (not created by
 * bridge_new_state, or already closed). */
static mem_box *guest_mem_box(lua_State *guest) {
    mem_box *box;
    lua_pushlightuserdata(guest, (void *)&mem_box_key);
    lua_rawget(guest, LUA_REGISTRYINDEX);
    box = (mem_box *)lua_touserdata(guest, -1);
    lua_pop(guest, 1);
    return box;
}

static int bridge_new_state(lua_State *L) {
    /* The box is allocated and owned here, never in Lua: its pointer must not
     * travel through a Lua number. */
    mem_box *box = (mem_box *)malloc(sizeof(mem_box));
    lua_State *new_state;
    if (box == NULL) {
        lua_pushstring(L, "bridge_new_state: out of memory");
        lua_error(L);
        return 0;
    }
    box->used = 0;
    box->limit = 0;
    box->old_alloc = NULL;
    box->old_ud = NULL;

    /* LuaJIT's own allocator creates the state; the counting wrapper is
     * installed on top of it right after, so every later block still comes
     * from the allocator that knows LuaJIT's rules. */
    new_state = luaL_newstate();
    if (!new_state) {
        free(box);
        lua_pushstring(L, "bridge_new_state: luaL_newstate() returned NULL");
        lua_error(L);
        return 0;
    }
    box->old_alloc = lua_getallocf(new_state, &box->old_ud);
    lua_setallocf(new_state, limited_alloc, box);

    /* Hand the box to the guest state itself: the memory accessors and close
     * find it through the registry, so it stays a plain pointer end to end. */
    lua_pushlightuserdata(new_state, (void *)&mem_box_key);
    lua_pushlightuserdata(new_state, (void *)box);
    lua_rawset(new_state, LUA_REGISTRYINDEX);

    luaL_openlibs(new_state);
    lua_pushlightuserdata(L, (void *)new_state);
    return 1;
}

/* Bytes the guest state holds right now. */
static int bridge_memory_used(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    mem_box *box = guest_mem_box(guest);
    lua_pushinteger(L, (lua_Integer)(box ? box->used : 0));
    return 1;
}

/* Set the guest state's memory cap; 0 removes it. */
static int bridge_set_memory_limit(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    mem_box *box = guest_mem_box(guest);
    if (box) box->limit = (int64_t)lua_tointeger(L, 2);
    return 0;
}

// Close a guest Lua state created by bridge_new_state.
// This must be called instead of raw lua_close() so that on Windows the
// state is freed by bridge.dll's CRT — the same one that allocated it via
// luaL_newstate(). Using the host's lua_close() (via ffi.C) on a state
// allocated by bridge.dll's luaL_newstate() is a cross-CRT free and
// corrupts the heap.
static int bridge_close_state(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    /* Recover the allocator box before the state (and its registry) is gone,
     * then release both. The box is C memory, so it outlives lua_close. */
    mem_box *box = guest_mem_box(guest);
    lua_close(guest);
    free(box);
    return 0;
}

// ── Heap snapshot ─────────────────────────────────────────────────────────
//
// bridge.heap_snapshot(guest, max_depth, max_paths) walks every object that
// is reachable in the guest and gives each one to the first retainer path
// that reaches it, for example "init.lua:local cache.entries[]". It returns
//   { attributed = bytes, objects = n,
//     retained = { path = bytes reachable through it },
//     counts   = { path = objects whose path is exactly this one },
//     parents  = { path = parent path, or false for a root } }
//
// The walk adds no garbage to the guest. The visited set and the paths are C
// memory, and the containers in progress sit on the stack of a walker thread
// that the guest registry keeps between snapshots. It only reads the guest and
// runs no metamethods, so it is safe from a hook or a profiler callback.
//
// Root order sets attribution: _G, then each package.loaded entry, then the
// main thread's stack, then the registry. Sizes follow LuaJIT's GC64 object
// layouts. String and cdata sizes are exact (cdata through the guest's
// ffi.sizeof); table and function sizes are estimates from their contents.

#define LUA_TCDATA 10

#define HW_BIG_TABLE    64      /* more keys than this: string keys share "[*]" */
#define HW_MAX_FRAMES   2000    /* up to 3 stack slots each; lua_checkstack caps a C frame at 8000 */
#define HW_MAX_SEGMENT  200
#define HW_MAX_KEY      40
#define HW_OTHER_PATH   0       /* roots that do not fit in max_paths */

/* Fixed slots on the walker thread's stack; frames start above them. */
#define HW_SLOT_SIZEOF  1
#define HW_SLOT_QUEUE   2
#define HW_SLOT_LOADED  3

/* Registry key under which the guest keeps its walker thread. */
static const char heap_thread_key = 0;

/* The visited set is a bitmap per 1 MB of address space: one bit per 8 bytes.
 * GC objects, cdata payloads and upvalue cells are 8-byte aligned and never
 * share an address. Objects allocated together sit together, so the walk
 * touches far fewer cache lines than with a hash set of pointers. */
#define HW_REGION_SHIFT 20
#define HW_REGION_WORDS ((1u << HW_REGION_SHIFT) / 8 / 64)

typedef struct {
    uintptr_t region;    /* address >> HW_REGION_SHIFT, plus 1 (0 = empty) */
    uint64_t *bits;
} hw_region;

typedef struct {
    hw_region *regions;
    size_t mask;
    size_t count;
    hw_region *last;     /* the region of the previous lookup */
} hw_set;

typedef struct {
    int parent;          /* -1 for a root */
    uint32_t hash;
    char *segment;
    size_t length;
    double self;         /* bytes of the objects first reached here */
    double retained;     /* self plus every descendant path */
    double count;        /* objects whose path is exactly this one */
} hw_path;

typedef struct {
    hw_path *items;
    int count;
    int cap;
    int *index;          /* open addressing: path id + 1, 0 = empty */
    size_t index_mask;
} hw_paths;

typedef struct {
    int kind;            /* LUA_TTABLE, LUA_TFUNCTION, LUA_TTHREAD, LUA_TUSERDATA */
    int base;            /* walker stack slot of the container */
    int path;
    int depth;
    int stage;
    /* table */
    int is_big, has_weak_keys, has_weak_values, has_pending_value;
    int array_path, other_path, value_path;
    double array_count, hash_count;
    /* function */
    int upvalue, upvalues;
    double bytes;
    /* thread */
    lua_State *thread;
    int level, local, is_root;
} hw_frame;

typedef struct {
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

static hw_region *hw_region_slot(hw_region *regions, size_t mask, uintptr_t key) {
    size_t i = (size_t)((key * 0x9E3779B97F4A7C15ULL) >> 32) & mask;
    while (regions[i].region != 0 && regions[i].region != key) i = (i + 1) & mask;
    return &regions[i];
}

/* 1 when p is new, 0 when the set has it, -1 when out of memory. */
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
                if (regions == NULL) return -1;
                for (j = 0; j <= set->mask; j++) {
                    if (set->regions[j].region != 0) {
                        *hw_region_slot(regions, cap - 1, set->regions[j].region) = set->regions[j];
                    }
                }
                free(set->regions);
                set->regions = regions;
                set->mask = cap - 1;
                region = hw_region_slot(regions, set->mask, key);
            }
            region->bits = (uint64_t *)calloc(HW_REGION_WORDS, sizeof(uint64_t));
            if (region->bits == NULL) return -1;
            region->region = key;
            set->count++;
        }
        set->last = region;
    }
    bit = (size_t)((address & ((1u << HW_REGION_SHIFT) - 1)) >> 3);
    flag = (uint64_t)1 << (bit & 63);
    if (region->bits[bit >> 6] & flag) return 0;
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

/* The id of (parent, segment), added while there is room. -1 when the table
 * is full, -2 when out of memory. */
static int hw_paths_get(hw_paths *paths, int parent, const char *segment, size_t length, int max_paths) {
    uint32_t hash = hw_hash_segment(parent, segment, length);
    size_t i = hash & paths->index_mask;
    hw_path *path;
    while (paths->index[i] != 0) {
        path = &paths->items[paths->index[i] - 1];
        if (path->hash == hash && path->parent == parent && path->length == length
            && memcmp(path->segment, segment, length) == 0) {
            return paths->index[i] - 1;
        }
        i = (i + 1) & paths->index_mask;
    }
    if (paths->count >= max_paths) return -1;
    if (paths->count == paths->cap) {
        int cap = paths->cap * 2;
        hw_path *items = (hw_path *)realloc(paths->items, (size_t)cap * sizeof(hw_path));
        if (items == NULL) return -2;
        paths->items = items;
        paths->cap = cap;
    }
    path = &paths->items[paths->count];
    path->segment = (char *)malloc(length);
    if (path->segment == NULL) return -2;
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
        if (index == NULL) return -2;
        for (j = 0; j < (size_t)paths->count; j++) {
            size_t k = paths->items[j].hash & (cap - 1);
            while (index[k] != 0) k = (k + 1) & (cap - 1);
            index[k] = (int)j + 1;
        }
        free(paths->index);
        paths->index = index;
        paths->index_mask = cap - 1;
    }
    return paths->count - 1;
}

/* The path of a child named `segment` at `depth`: its parent's past
 * max_depth or when the path table is full. */
static int hw_child(hw_walk *w, int parent, const char *segment, size_t length, int depth) {
    int id;
    if (depth > w->max_depth) return parent;
    id = hw_paths_get(&w->paths, parent, segment, length, w->max_paths);
    if (id == -2) w->is_failed = 1;
    if (id < 0) return parent >= 0 ? parent : HW_OTHER_PATH;
    return id;
}

static void hw_add(hw_walk *w, int path, double bytes) {
    w->paths.items[path].self += bytes;
    w->attributed += bytes;
}

static size_t hw_format(char *out, const char *fmt, const char *a, const char *b) {
    int n = snprintf(out, HW_MAX_SEGMENT, fmt, a, b);
    if (n < 0) return 0;
    return n >= HW_MAX_SEGMENT ? HW_MAX_SEGMENT - 1 : (size_t)n;
}

static int hw_is_identifier(const char *s, size_t n) {
    size_t i;
    if (n == 0 || n > HW_MAX_KEY) return 0;
    for (i = 0; i < n; i++) {
        char c = s[i];
        int is_alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        if (!is_alpha && (i == 0 || c < '0' || c > '9')) return 0;
    }
    return 1;
}

/* The cdata on top of the walker stack: header plus ffi.sizeof. */
static double hw_cdata_size(hw_walk *w) {
    lua_State *K = w->walker;
    double size = 16;
    if (lua_type(K, HW_SLOT_SIZEOF) == LUA_TFUNCTION) {
        lua_pushvalue(K, HW_SLOT_SIZEOF);
        lua_pushvalue(K, -2);
        /* sizeof raises for a variable-length ctype object and returns nil
         * for an incomplete type: both count as header only. */
        if (lua_pcall(K, 1, 1, 0) == LUA_OK && lua_type(K, -1) == LUA_TNUMBER) {
            size += lua_tonumber(K, -1);
        }
        lua_pop(K, 1);
    }
    return size;
}

/* Open a frame for the container on top of the walker stack. */
static void hw_open(hw_walk *w, int kind, int path, int depth) {
    lua_State *K = w->walker;
    hw_frame *f;
    if (w->frame_count == w->frame_cap) {
        int cap = w->frame_cap * 2;
        hw_frame *frames = (hw_frame *)realloc(w->frames, (size_t)cap * sizeof(hw_frame));
        if (frames == NULL) {
            w->is_failed = 1;
            lua_pop(K, 1);
            return;
        }
        w->frames = frames;
        w->frame_cap = cap;
    }
    if (!lua_checkstack(K, 8)) {
        w->is_failed = 1;
        lua_pop(K, 1);
        return;
    }
    f = &w->frames[w->frame_count++];
    memset(f, 0, sizeof(*f));
    f->kind = kind;
    f->base = lua_gettop(K);
    f->path = path;
    f->depth = depth;
    if (kind == LUA_TTHREAD) {
        lua_Debug ar;
        int levels = 0;
        f->thread = lua_tothread(K, -1);
        while (lua_getstack(f->thread, levels, &ar)) levels++;
        f->level = levels - 1;
    }
}

/* A container past HW_MAX_FRAMES waits in a queue table on the walker. */
static void hw_enqueue(hw_walk *w, int path, int depth) {
    lua_State *K = w->walker;
    if (lua_type(K, HW_SLOT_QUEUE) != LUA_TTABLE) {
        lua_createtable(K, 0, 0);
        if (hw_set_add(&w->seen, lua_topointer(K, -1)) < 0) w->is_failed = 1;
        lua_replace(K, HW_SLOT_QUEUE);
    }
    if (w->queue_count + 1 >= w->queue_cap) {
        int cap = w->queue_cap ? w->queue_cap * 2 : 256;
        int *paths = (int *)realloc(w->queue_path, (size_t)cap * sizeof(int));
        int *depths;
        if (paths != NULL) w->queue_path = paths;
        depths = (int *)realloc(w->queue_depth, (size_t)cap * sizeof(int));
        if (depths != NULL) w->queue_depth = depths;
        if (paths == NULL || depths == NULL) {
            w->is_failed = 1;
            lua_pop(K, 1);
            return;
        }
        w->queue_cap = cap;
    }
    w->queue_count++;
    w->queue_path[w->queue_count] = path;
    w->queue_depth[w->queue_count] = depth;
    lua_rawseti(K, HW_SLOT_QUEUE, w->queue_count);
}

/* Consume the value on top of the walker stack. A new container gets a frame
 * and stays on the stack as that frame's base. */
static void hw_discover(hw_walk *w, int parent, int path, int depth) {
    lua_State *K = w->walker;
    int type = lua_type(K, -1);
    int added;
    if (type != LUA_TSTRING && type != LUA_TTABLE && type != LUA_TFUNCTION
        && type != LUA_TUSERDATA && type != LUA_TTHREAD && type != LUA_TCDATA) {
        lua_pop(K, 1);
        return;
    }
    added = hw_set_add(&w->seen, lua_topointer(K, -1));
    if (added <= 0) {
        if (added < 0) w->is_failed = 1;
        lua_pop(K, 1);
        return;
    }
    w->objects++;
    if (path != parent) w->paths.items[path].count++;
    if (type == LUA_TSTRING) {
        size_t length;
        lua_tolstring(K, -1, &length);
        hw_add(w, path, 25.0 + (double)length);
        lua_pop(K, 1);
    } else if (type == LUA_TCDATA) {
        hw_add(w, path, hw_cdata_size(w));
        lua_pop(K, 1);
    } else if (w->frame_count >= HW_MAX_FRAMES) {
        hw_enqueue(w, path, depth);
    } else {
        hw_open(w, type, path, depth);
    }
}

static void hw_finish(hw_walk *w, double bytes) {
    hw_frame *f = &w->frames[w->frame_count - 1];
    if (f->path >= 0) hw_add(w, f->path, bytes);
    lua_settop(w->walker, f->base - 1);
    w->frame_count--;
}

static void hw_step_table(hw_walk *w, hw_frame *f) {
    lua_State *K = w->walker;
    int path = f->path, depth = f->depth;
    if (f->stage == 0) {
        f->stage = 1;
        if (lua_getmetatable(K, f->base)) {
            lua_pushstring(K, "__mode");
            lua_rawget(K, -2);
            if (lua_type(K, -1) == LUA_TSTRING) {
                const char *mode = lua_tostring(K, -1);
                f->has_weak_keys = strchr(mode, 'k') != NULL;
                f->has_weak_values = strchr(mode, 'v') != NULL;
            }
            lua_pop(K, 1);
            hw_discover(w, path, hw_child(w, path, "<mt>", 4, depth + 1), depth + 1);
        }
        return;
    }
    if (f->stage == 1) {
        /* A big table is a collection: its keys are data, not field names. */
        int entries = 0;
        lua_pushnil(K);
        while (lua_next(K, f->base)) {
            lua_pop(K, 1);
            if (++entries > HW_BIG_TABLE) {
                lua_pop(K, 1);
                break;
            }
        }
        f->is_big = entries > HW_BIG_TABLE;
        f->array_path = hw_child(w, path, "[]", 2, depth + 1);
        f->other_path = hw_child(w, path, "[*]", 3, depth + 1);
        f->stage = 2;
        lua_pushnil(K);
        return;
    }
    if (f->has_pending_value) {
        /* [table, key, value]: the key's frame is done, the value is next. */
        f->has_pending_value = 0;
        if (f->has_weak_values) {
            lua_pop(K, 1);
        } else {
            int frames = w->frame_count;
            hw_discover(w, path, f->value_path, depth + 1);
            if (w->frame_count > frames) return;
        }
    }
    /* Entries run in this loop until one opens a frame: then the walk goes
     * deeper first and comes back here. */
    for (;;) {
        int value_path = f->other_path, frames, type;
        if (!lua_next(K, f->base)) {
            double slots = 0;
            if (f->hash_count > 0) {
                slots = 1;
                while (slots < f->hash_count) slots *= 2;
            }
            hw_finish(w, 64 + (f->array_count > 0 ? 8 * (f->array_count + 1) : 0) + 24 * slots);
            return;
        }
        switch (lua_type(K, -2)) {
        case LUA_TNUMBER: {
            lua_Number n = lua_tonumber(K, -2);
            if (n >= 1 && n <= 9007199254740992.0 && n == (lua_Number)(int64_t)n) {
                f->array_count++;
                value_path = f->array_path;
            } else {
                f->hash_count++;
            }
            break;
        }
        case LUA_TSTRING: {
            size_t length;
            const char *key = lua_tolstring(K, -2, &length);
            int added = hw_set_add(&w->seen, lua_topointer(K, -2));
            f->hash_count++;
            if (added < 0) w->is_failed = 1;
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
            break;
        }
        case LUA_TBOOLEAN:
        case LUA_TLIGHTUSERDATA:
            f->hash_count++;
            break;
        default:
            f->hash_count++;
            if (!f->has_weak_keys) {
                frames = w->frame_count;
                f->value_path = value_path;
                f->has_pending_value = 1;
                lua_pushvalue(K, -2);
                hw_discover(w, path, hw_child(w, path, "<key>", 5, depth + 1), depth + 1);
                if (w->frame_count > frames) return;
                f->has_pending_value = 0;
            }
            break;
        }
        if (w->is_failed) return;
        type = lua_type(K, -1);
        if (f->has_weak_values || type <= LUA_TNUMBER) {
            lua_pop(K, 1);
            continue;
        }
        frames = w->frame_count;
        hw_discover(w, path, value_path, depth + 1);
        if (w->frame_count > frames) return;
    }
}

static void hw_step_function(hw_walk *w, hw_frame *f) {
    lua_State *K = w->walker;
    int path = f->path, depth = f->depth;
    if (f->stage == 0) {
        lua_Debug ar;
        lua_pushvalue(K, f->base);
        lua_getinfo(K, ">u", &ar);
        f->upvalues = ar.nups;
        f->bytes = 40.0 + 8.0 * ar.nups;
        f->stage = 1;
    }
    if (f->stage == 1) {
        while (f->upvalue < f->upvalues) {
            int i = ++f->upvalue;
            /* Closures share upvalue cells: count each cell once. */
            int added = hw_set_add(&w->seen, lua_upvalueid(K, f->base, i));
            const char *name;
            char segment[HW_MAX_SEGMENT];
            if (added < 0) w->is_failed = 1;
            if (added <= 0) continue;
            f->bytes += 48;
            name = lua_getupvalue(K, f->base, i);
            if (name == NULL) continue;
            hw_discover(w, path, hw_child(w, path, segment,
                hw_format(segment, "<upvalue %s%s>", name[0] ? name : "?", ""), depth + 1), depth + 1);
            return;
        }
        f->stage = 2;
    }
    if (f->stage == 2) {
        f->stage = 3;
        lua_getfenv(K, f->base);
        hw_discover(w, path, hw_child(w, path, "<env>", 5, depth + 1), depth + 1);
        return;
    }
    hw_finish(w, f->bytes);
}

static void hw_step_userdata(hw_walk *w, hw_frame *f) {
    lua_State *K = w->walker;
    int path = f->path, depth = f->depth;
    if (f->stage == 0) {
        f->stage = 1;
        if (lua_getmetatable(K, f->base)) {
            hw_discover(w, path, hw_child(w, path, "<mt>", 4, depth + 1), depth + 1);
        }
        return;
    }
    if (f->stage == 1) {
        f->stage = 2;
        lua_getfenv(K, f->base);
        hw_discover(w, path, hw_child(w, path, "<env>", 5, depth + 1), depth + 1);
        return;
    }
    hw_finish(w, 40);
}

/* Locals and functions of a thread's Lua frames, outermost frame first. The
 * main thread is a root: its locals are root paths ("init.lua:local x");
 * another thread's are children ("<init.lua:12:local x>"). */
static void hw_step_thread(hw_walk *w, hw_frame *f) {
    lua_State *K = w->walker, *T = f->thread;
    int parent = f->is_root ? -1 : f->path;
    int depth = f->is_root ? 1 : f->depth + 1;
    while (f->level >= 0) {
        lua_Debug ar;
        char frame[HW_MAX_SEGMENT], segment[HW_MAX_SEGMENT];
        const char *source, *p;
        size_t length;
        if (!lua_getstack(T, f->level, &ar)) {
            f->level--;
            f->local = 0;
            continue;
        }
        lua_getinfo(T, "S", &ar);
        if (ar.what != NULL && ar.what[0] == 'C') {
            f->level--;
            f->local = 0;
            continue;
        }
        source = ar.short_src;
        for (p = ar.short_src; *p; p++) {
            if (*p == '/' || *p == '\\') source = p + 1;
        }
        if (ar.what != NULL && strcmp(ar.what, "main") == 0) {
            snprintf(frame, sizeof(frame), "%s", source);
        } else {
            snprintf(frame, sizeof(frame), "%s:%d", source, ar.linedefined);
        }
        if (f->local >= 0) {
            const char *name = lua_getlocal(T, &ar, f->local + 1);
            if (name != NULL) {
                f->local++;
                lua_xmove(T, K, 1);
                length = hw_format(segment, f->is_root ? "%s:local %s" : "<%s:local %s>",
                    frame, name[0] == '(' ? "(temp)" : name);
                hw_discover(w, parent, hw_child(w, parent, segment, length, depth), depth);
                return;
            }
            f->local = -1;
        }
        lua_getinfo(T, "f", &ar);
        lua_xmove(T, K, 1);
        f->level--;
        f->local = 0;
        length = hw_format(segment, f->is_root ? "%s:function%s" : "<%s:function%s>", frame, "");
        hw_discover(w, parent, hw_child(w, parent, segment, length, depth), depth);
        return;
    }
    hw_finish(w, f->is_root ? 0 : 200);
}

/* Run frames until none is left, then the queued containers. */
static void hw_drain(hw_walk *w) {
    lua_State *K = w->walker;
    for (;;) {
        while (w->frame_count > 0 && !w->is_failed) {
            hw_frame *f = &w->frames[w->frame_count - 1];
            switch (f->kind) {
            case LUA_TTABLE:    hw_step_table(w, f); break;
            case LUA_TFUNCTION: hw_step_function(w, f); break;
            case LUA_TTHREAD:   hw_step_thread(w, f); break;
            default:            hw_step_userdata(w, f); break;
            }
        }
        if (w->is_failed || w->queue_next >= w->queue_count) return;
        w->queue_next++;
        lua_rawgeti(K, HW_SLOT_QUEUE, w->queue_next);
        lua_pushnil(K);
        lua_rawseti(K, HW_SLOT_QUEUE, w->queue_next);
        hw_open(w, lua_type(K, -1), w->queue_path[w->queue_next], w->queue_depth[w->queue_next]);
    }
}

/* Walk the value on top of the walker stack as a root named `label`. */
static void hw_root(hw_walk *w, const char *label, size_t length) {
    hw_discover(w, -1, hw_child(w, -1, label, length, 1), 1);
    hw_drain(w);
}

static void hw_walk_roots(hw_walk *w, lua_State *guest) {
    lua_State *K = w->walker;
    char label[HW_MAX_SEGMENT];

    lua_settop(K, 0);
    lua_pushnil(K);                                  /* HW_SLOT_SIZEOF */
    lua_pushnil(K);                                  /* HW_SLOT_QUEUE */
    lua_pushstring(K, "_LOADED");
    lua_rawget(K, LUA_REGISTRYINDEX);                /* HW_SLOT_LOADED */
    if (lua_type(K, HW_SLOT_LOADED) == LUA_TTABLE) {
        lua_pushstring(K, "ffi");
        lua_rawget(K, HW_SLOT_LOADED);
        if (lua_type(K, -1) == LUA_TTABLE) {
            lua_pushstring(K, "sizeof");
            lua_rawget(K, -2);
            lua_replace(K, HW_SLOT_SIZEOF);
        }
        lua_pop(K, 1);
        /* Its entries are roots of their own, not "_G.package.loaded[*]". */
        if (hw_set_add(&w->seen, lua_topointer(K, HW_SLOT_LOADED)) < 0) w->is_failed = 1;
    }
    if (hw_set_add(&w->seen, (const void *)K) < 0) w->is_failed = 1;
    if (hw_set_add(&w->seen, (const void *)guest) < 0) w->is_failed = 1;

    lua_pushvalue(K, LUA_GLOBALSINDEX);
    hw_root(w, "_G", 2);

    if (lua_type(K, HW_SLOT_LOADED) == LUA_TTABLE) {
        lua_pushnil(K);
        while (!w->is_failed && lua_next(K, HW_SLOT_LOADED)) {
            size_t length = 1, i;
            const char *name = "?";
            if (lua_type(K, -2) == LUA_TSTRING) name = lua_tolstring(K, -2, &length);
            if (length > 150) length = 150;
            length = (size_t)snprintf(label, sizeof(label), "require(\"%.*s\")", (int)length, name);
            for (i = 0; i < length; i++) {
                if ((unsigned char)label[i] < 32) label[i] = '?';
            }
            hw_root(w, label, length);
        }
    }

    lua_pushthread(guest);
    lua_xmove(guest, K, 1);
    hw_open(w, LUA_TTHREAD, -1, 0);
    if (w->frame_count > 0) w->frames[w->frame_count - 1].is_root = 1;
    hw_drain(w);

    lua_pushvalue(K, LUA_REGISTRYINDEX);
    hw_root(w, "registry", 8);
    lua_settop(K, 0);
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
        if (p->parent >= 0) paths->items[p->parent].retained += p->retained;
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
            while (used + prefix + p->length > cap) cap *= 2;
            grown = (char *)realloc(names, cap);
            if (grown == NULL) {
                free(offsets);
                free(lengths);
                free(names);
                return 0;
            }
            names = grown;
        }
        if (prefix > 0) memcpy(names + used, names + offsets[p->parent], prefix);
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
    lua_createtable(L, 0, paths->count);             /* retained */
    lua_createtable(L, 0, paths->count);             /* counts */
    lua_createtable(L, 0, paths->count);             /* parents */
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
    for (i = 0; i < w->paths.count; i++) free(w->paths.items[i].segment);
    free(w->paths.items);
    free(w->paths.index);
    if (w->seen.regions != NULL) {
        for (j = 0; j <= w->seen.mask; j++) free(w->seen.regions[j].bits);
    }
    free(w->seen.regions);
    free(w->frames);
    free(w->queue_path);
    free(w->queue_depth);
}

static int bridge_heap_snapshot(lua_State *L) {
    lua_State *guest = decode_guest_ptr(L, 1);
    lua_State *walker;
    hw_walk w;
    int is_pushed;

    memset(&w, 0, sizeof(w));
    w.max_depth = lua_type(L, 2) == LUA_TNUMBER ? (int)lua_tonumber(L, 2) : 10;
    w.max_paths = lua_type(L, 3) == LUA_TNUMBER ? (int)lua_tonumber(L, 3) : 20000;
    if (w.max_depth < 1) w.max_depth = 1;
    if (w.max_paths < 1) w.max_paths = 1;

    lua_pushlightuserdata(guest, (void *)&heap_thread_key);
    lua_rawget(guest, LUA_REGISTRYINDEX);
    walker = lua_tothread(guest, -1);
    lua_pop(guest, 1);
    if (walker == NULL) {
        walker = lua_newthread(guest);
        lua_pushlightuserdata(guest, (void *)&heap_thread_key);
        lua_pushvalue(guest, -2);
        lua_rawset(guest, LUA_REGISTRYINDEX);
        lua_pop(guest, 1);
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
    if (w.seen.regions == NULL || w.paths.items == NULL || w.paths.index == NULL || w.frames == NULL
        || hw_paths_get(&w.paths, -1, "<other>", 7, w.max_paths + 1) != HW_OTHER_PATH) {
        hw_free(&w);
        return luaL_error(L, "heap_snapshot: out of memory");
    }

    if (!lua_checkstack(walker, 16)) w.is_failed = 1;
    if (!w.is_failed) hw_walk_roots(&w, guest);
    lua_settop(walker, 0);

    is_pushed = !w.is_failed && hw_push_result(L, &w);
    hw_free(&w);
    if (!is_pushed) return luaL_error(L, "heap_snapshot: out of memory");
    return 1;
}

static const luaL_Reg bridge_funcs[] = {
    { "make_callable",   bridge_make_callable  },
    { "compound_tag",    bridge_compound_tag   },
    { "register",        bridge_register       },
    { "push_callback",   bridge_push_callback  },
    { "unregister",      bridge_unregister     },
    { "set_hook",        bridge_set_hook       },
    { "remove_hook",     bridge_remove_hook    },
    { "set_frame_meta",  bridge_set_frame_meta },
    { "new_state",       bridge_new_state      },
    { "close_state",     bridge_close_state    },
    { "memory_used",     bridge_memory_used    },
    { "set_memory_limit", bridge_set_memory_limit },
    { "heap_snapshot",   bridge_heap_snapshot  },
    { NULL, NULL }
};

int luaopen_lua_sys_bridge(lua_State *L) {
#ifdef _WIN32
    bridge_resolve_symbols();
#endif
    luaL_register(L, "lua-sys.bridge", bridge_funcs);
    /* Seed this state's registry with the shared metatables. Other states
     * that share the same dlopen'd copy of this .so build them lazily (see
     * bridge_make_callable / hook_dispatch). */
    init_callable_metatable(L);
    init_hook_info_metatable(L);
    return 1;
}

int luaopen_sys_bridge(lua_State *L) { return luaopen_lua_sys_bridge(L); }
int luaopen_bridge(lua_State *L)     { return luaopen_lua_sys_bridge(L); }