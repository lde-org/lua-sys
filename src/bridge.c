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

static lua_State *host_L = NULL;

// ── Value copying ─────────────────────────────────────────────────────────

// Pushes src[idx] onto dst if it is a primitive type, returns the lua_type.
// Returns -1 for compound types (nothing pushed onto dst).
// Single lua_type call covers both the check and the dispatch — eliminates
// the double type-check of a separate is_primitive() + push_primitive().
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

static lua_State *decode_guest_ptr(int stack_pos) {
    int t = lua_type(host_L, stack_pos);
    if (t == LUA_TNUMBER)
        return (lua_State *)(uintptr_t)lua_tonumber(host_L, stack_pos);
    if (t == LUA_TLIGHTUSERDATA)
        return (lua_State *)lua_touserdata(host_L, stack_pos);
    luaL_error(host_L, "bridge: arg %d must be a guest lua_State pointer", stack_pos);
    return NULL; /* unreachable: luaL_error longjmps */
}

// ── bound_call ────────────────────────────────────────────────────────────
//
// lua_CFunction installed on the host state via bridge.make_callable.
// Upvalue 1: lightuserdata  — guest lua_State*
// Upvalue 2: integer        — guest LUA_REGISTRYINDEX ref for the function
//
// Called directly by host Lua code as fn(...). This is a lua_CFunction, not
// an FFI call, so JIT traces see it as an opaque C boundary and do not
// attempt to record through it into the guest — preventing the re-entrancy
// crash described in docs/bridge-design.md.
//
// Return protocol:
//   All-primitive results: returns them directly (zero overhead on hot path).
//   Compound results: returns COMPOUND_TAG_ADDR as a lightuserdata sentinel.
//     The Lua wrapper detects the tag and calls callGuestSlow instead.
//   Guest error: raises a Lua error normally.

static char COMPOUND_TAG_ADDR;

static int bound_call(lua_State *host) {
    lua_State *guest = (lua_State *)lua_touserdata(host, lua_upvalueindex(1));
    int fn_ref       = (int)lua_tointeger(host, lua_upvalueindex(2));
    int nargs        = lua_gettop(host);
    int guest_base   = lua_gettop(guest);

    lua_rawgeti(guest, LUA_REGISTRYINDEX, fn_ref);

    int i;
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
            lua_settop(host, nargs);
            lua_settop(guest, guest_base);
            lua_pushlightuserdata(host, (void *)&COMPOUND_TAG_ADDR);
            return 1;
        }
    }
    lua_settop(guest, guest_base);
    return nresults;
}

static int bridge_make_callable(lua_State *L) {
    (void)L;
    lua_State *guest = decode_guest_ptr(1);
    lua_pushlightuserdata(host_L, (void *)guest);
    lua_pushvalue(host_L, 2); /* guest_fn_ref */
    lua_pushcclosure(host_L, bound_call, 2);
    return 1;
}

static int bridge_compound_tag(lua_State *L) {
    (void)L;
    lua_pushlightuserdata(host_L, (void *)&COMPOUND_TAG_ADDR);
    return 1;
}

// ── dispatch_callback ─────────────────────────────────────────────────────
//
// lua_CFunction installed on the guest state via bridge.push_callback.
// Upvalue 1: integer — LUA_REGISTRYINDEX ref for the host callback function.
//
// Each callback is stored as a direct registry ref (luaL_ref / luaL_unref).
// This allows a single lua_rawgeti to retrieve the function — replacing the
// old double rawgeti (table ref → table → function) with one call.
//
// Called by guest Lua code when it invokes a host-provided function. This is
// a lua_CFunction on the guest, so it is never called through LuaJIT FFI —
// the guest interpreter dispatches it via BC_FUNCC, keeping the C boundary
// intact in the guest→host direction as well.
//
// saved_top/lua_settop: host_L's stack must be fully restored on every exit
// path. If this function returns without restoring, re-entrant calls from
// nested guest→host→guest→host chains will corrupt each other's stack frames.

static int dispatch_callback(lua_State *guest) {
    int fn_ref    = (int)lua_tointeger(guest, lua_upvalueindex(1));
    int saved_top = lua_gettop(host_L);

    lua_rawgeti(host_L, LUA_REGISTRYINDEX, fn_ref);

    // host_fn_idx == saved_top + 1: exactly one value (the fn) was pushed above.
    int nargs = lua_gettop(guest);
    int i;
    for (i = 1; i <= nargs; i++)
        push_primitive_or_error(guest, i, host_L);

    int status = lua_pcall(host_L, nargs, LUA_MULTRET, 0);
    if (status != LUA_OK) {
        const char *err = lua_tostring(host_L, -1);
        lua_pushstring(guest, err ? err : "bridge: host error");
        lua_settop(host_L, saved_top);
        lua_error(guest);
        return 0;
    }

    int nresults = lua_gettop(host_L) - saved_top;
    if (nresults == 0) return 0; /* host stack already at saved_top */

    for (i = 0; i < nresults; i++)
        push_primitive_or_error(host_L, saved_top + 1 + i, guest);

    lua_settop(host_L, saved_top);
    return nresults;
}

// ── Exported functions ────────────────────────────────────────────────────

// Stores the host function (arg 1) in the registry and returns its ref as
// the callback id. bridge.push_callback and bridge.unregister use this ref.
static int bridge_register(lua_State *L) {
    (void)L;
    luaL_checktype(host_L, 1, LUA_TFUNCTION);
    lua_pushvalue(host_L, 1);
    int id = luaL_ref(host_L, LUA_REGISTRYINDEX);
    lua_pushinteger(host_L, id);
    return 1;
}

// Pushes a dispatch_callback closure onto the guest state.
// Done in C so the closure is a real lua_CFunction on the guest — not an FFI
// cdata — preventing JIT tracing into the host from the guest side.
static int bridge_push_callback(lua_State *L) {
    (void)L;
    lua_State *guest = decode_guest_ptr(1);
    int fn_ref       = (int)lua_tointeger(host_L, 2);
    lua_pushinteger(guest, fn_ref);
    lua_pushcclosure(guest, dispatch_callback, 1);
    return 0;
}

static int bridge_unregister(lua_State *L) {
    (void)L;
    int fn_ref = (int)lua_tointeger(host_L, 1);
    luaL_unref(host_L, LUA_REGISTRYINDEX, fn_ref);
    return 0;
}

static const luaL_Reg bridge_funcs[] = {
    { "make_callable",  bridge_make_callable },
    { "compound_tag",   bridge_compound_tag  },
    { "register",       bridge_register      },
    { "push_callback",  bridge_push_callback },
    { "unregister",     bridge_unregister    },
    { NULL, NULL }
};

int luaopen_lua_sys_bridge(lua_State *L) {
    host_L = L;
    luaL_register(L, "lua-sys.bridge", bridge_funcs);
    return 1;
}

int luaopen_sys_bridge(lua_State *L) __attribute__((alias("luaopen_lua_sys_bridge")));
int luaopen_bridge(lua_State *L)     __attribute__((alias("luaopen_lua_sys_bridge")));
