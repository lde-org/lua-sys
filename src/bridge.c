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

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <stdint.h>

#define COMPOUND_RESULT_MSG "bridge: compound result"

static lua_State *host_L       = NULL;
static int        callback_table_ref = LUA_NOREF;

// ── Value copying ─────────────────────────────────────────────────────────

static int is_primitive(lua_State *L, int idx) {
    int t = lua_type(L, idx);
    return t == LUA_TNIL || t == LUA_TBOOLEAN || t == LUA_TNUMBER || t == LUA_TSTRING;
}

static void push_primitive(lua_State *src, int idx, lua_State *dst) {
    switch (lua_type(src, idx)) {
    case LUA_TNIL:     lua_pushnil(dst); break;
    case LUA_TBOOLEAN: lua_pushboolean(dst, lua_toboolean(src, idx)); break;
    case LUA_TNUMBER:  lua_pushnumber(dst, lua_tonumber(src, idx)); break;
    case LUA_TSTRING: {
        size_t len;
        const char *s = lua_tolstring(src, idx, &len);
        lua_pushlstring(dst, s, len);
        break;
    }
    default: break;
    }
}

static void push_primitive_or_error(lua_State *src, int idx, lua_State *dst) {
    if (is_primitive(src, idx)) {
        push_primitive(src, idx, dst);
    } else {
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

// ── Callback table ────────────────────────────────────────────────────────

static void ensure_callback_table(void) {
    if (callback_table_ref != LUA_NOREF) {
        lua_rawgeti(host_L, LUA_REGISTRYINDEX, callback_table_ref);
        if (!lua_isnil(host_L, -1)) { lua_pop(host_L, 1); return; }
        lua_pop(host_L, 1);
    }
    lua_newtable(host_L);
    callback_table_ref = luaL_ref(host_L, LUA_REGISTRYINDEX);
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

static int bound_call(lua_State *host) {
    lua_State *guest    = (lua_State *)lua_touserdata(host, lua_upvalueindex(1));
    int        guest_fn_ref = (int)lua_tointeger(host, lua_upvalueindex(2));
    int        nargs    = lua_gettop(host);
    int        guest_base = lua_gettop(guest);

    lua_rawgeti(guest, LUA_REGISTRYINDEX, guest_fn_ref);

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
    for (i = 0; i < nresults; i++) {
        if (!is_primitive(guest, guest_base + 1 + i)) {
            // Signal the Lua wrapper to fall back to the slow path, which
            // handles compound types via fromLua/toLua registry refs.
            lua_settop(guest, guest_base);
            lua_pushstring(host, COMPOUND_RESULT_MSG);
            lua_error(host);
            return 0;
        }
    }
    for (i = 0; i < nresults; i++)
        push_primitive(guest, guest_base + 1 + i, host);

    lua_settop(guest, guest_base);
    return nresults;
}

// bridge.make_callable(guest_L_ptr, guest_fn_ref) → bound_call closure
//
// Creates a bound_call closure on host_L with the guest pointer and ref
// baked in as upvalues. Returned to Lua as the callable for a guest function.
static int bridge_make_callable(lua_State *L) {
    (void)L;
    lua_State *guest = decode_guest_ptr(1);
    lua_pushlightuserdata(host_L, (void *)guest);
    lua_pushvalue(host_L, 2); /* guest_fn_ref */
    lua_pushcclosure(host_L, bound_call, 2);
    return 1;
}

// ── dispatch_callback ─────────────────────────────────────────────────────
//
// lua_CFunction installed on the guest state via bridge.push_callback.
// Upvalue 1: integer — callback id in the host callback table.
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
    int callback_id = (int)lua_tointeger(guest, lua_upvalueindex(1));
    int saved_top   = lua_gettop(host_L);

    // callback_table_ref: use rawgeti (O(1) int lookup) rather than
    // getfield (string hash) — shaves ~13 ns off every callback invocation.
    if (callback_table_ref == LUA_NOREF) {
        lua_pushstring(guest, "bridge: callback table missing");
        lua_error(guest);
        return 0;
    }
    lua_rawgeti(host_L, LUA_REGISTRYINDEX, callback_table_ref);
    lua_rawgeti(host_L, -1, callback_id);
    lua_remove(host_L, -2);

    if (lua_isnil(host_L, -1)) {
        lua_settop(host_L, saved_top);
        lua_pushfstring(guest, "bridge: callback %d not found", callback_id);
        lua_error(guest);
        return 0;
    }

    int host_fn_idx = lua_gettop(host_L);
    int nargs       = lua_gettop(guest);
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

    int nresults = lua_gettop(host_L) - host_fn_idx + 1;
    for (i = 0; i < nresults; i++)
        push_primitive_or_error(host_L, host_fn_idx + i, guest);

    lua_settop(host_L, saved_top);
    return nresults;
}

// ── Exported functions ────────────────────────────────────────────────────

// bridge.register(host_fn) → callback_id
static int bridge_register(lua_State *L) {
    (void)L;
    luaL_checktype(host_L, 1, LUA_TFUNCTION);
    ensure_callback_table();
    lua_rawgeti(host_L, LUA_REGISTRYINDEX, callback_table_ref);
    int id = (int)lua_objlen(host_L, -1) + 1;
    lua_pushvalue(host_L, 1);
    lua_rawseti(host_L, -2, id);
    lua_pop(host_L, 1);
    lua_pushinteger(host_L, id);
    return 1;
}

// bridge.push_callback(guest_L_ptr, callback_id)
// Pushes a dispatch_callback closure onto the guest state.
// Done in C so the closure is a real lua_CFunction on the guest — not an FFI
// cdata — preventing JIT tracing into the host from the guest side.
static int bridge_push_callback(lua_State *L) {
    (void)L;
    lua_State *guest = decode_guest_ptr(1);
    int callback_id  = (int)lua_tointeger(host_L, 2);
    lua_pushinteger(guest, callback_id);
    lua_pushcclosure(guest, dispatch_callback, 1);
    return 0;
}

// bridge.unregister(callback_id)
static int bridge_unregister(lua_State *L) {
    (void)L;
    if (callback_table_ref == LUA_NOREF) return 0;
    int callback_id = (int)lua_tointeger(host_L, 1);
    lua_rawgeti(host_L, LUA_REGISTRYINDEX, callback_table_ref);
    lua_pushnil(host_L);
    lua_rawseti(host_L, -2, callback_id);
    lua_pop(host_L, 1);
    return 0;
}

// bridge.call(guest_L_ptr, guest_fn_ref, arg1, ...) → results...
// Kept for completeness; hot path uses bound_call via make_callable instead.
static int bridge_call(lua_State *L) {
    (void)L;
    lua_State *guest    = decode_guest_ptr(1);
    int        fn_ref   = (int)lua_tointeger(host_L, 2);
    int        nargs    = lua_gettop(host_L) - 2;
    int        guest_base = lua_gettop(guest);

    lua_rawgeti(guest, LUA_REGISTRYINDEX, fn_ref);

    int i;
    for (i = 3; i <= 2 + nargs; i++)
        push_primitive_or_error(host_L, i, guest);

    int status = lua_pcall(guest, nargs, LUA_MULTRET, 0);
    if (status != 0) {
        const char *err = lua_tostring(guest, -1);
        lua_settop(guest, guest_base);
        lua_pushstring(host_L, err ? err : "bridge: guest error");
        lua_error(host_L);
        return 0;
    }

    int nresults = lua_gettop(guest) - guest_base;
    for (i = 0; i < nresults; i++) {
        if (!is_primitive(guest, guest_base + 1 + i)) {
            lua_settop(guest, guest_base);
            lua_pushstring(host_L, COMPOUND_RESULT_MSG);
            lua_error(host_L);
            return 0;
        }
    }
    for (i = 0; i < nresults; i++)
        push_primitive(guest, guest_base + 1 + i, host_L);

    lua_settop(guest, guest_base);
    return nresults;
}

static const luaL_Reg bridge_funcs[] = {
    { "call",           bridge_call },
    { "make_callable",  bridge_make_callable },
    { "register",       bridge_register },
    { "push_callback",  bridge_push_callback },
    { "unregister",     bridge_unregister },
    { NULL, NULL }
};

int luaopen_lua_sys_bridge(lua_State *L) {
    host_L             = L;
    callback_table_ref = LUA_NOREF;
    luaL_register(L, "lua-sys.bridge", bridge_funcs);
    return 1;
}

int luaopen_sys_bridge(lua_State *L) __attribute__((alias("luaopen_lua_sys_bridge")));
int luaopen_bridge(lua_State *L)     __attribute__((alias("luaopen_lua_sys_bridge")));
