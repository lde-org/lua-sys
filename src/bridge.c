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

static lua_State *host_L = NULL;

/* Set to 1 while dispatch_callback is executing a host←→guest transition.
 * luaJIT_profile_dumpstack is unsafe during this period because the guest
 * Lua stack has an incomplete FFI continuation frame. The profiler callback
 * skips dumpstack when this flag is set and records an empty stack instead. */
static volatile int bridge_in_transition = 0;

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

static int bridge_make_callable(lua_State *L) {
    (void)L;
    lua_State *guest = decode_guest_ptr(1);
    lua_pushlightuserdata(host_L, (void *)guest); /* upvalue 1 */
    lua_pushvalue(host_L, 2);                     /* upvalue 2: guestRef */
    lua_pushvalue(host_L, 3);                     /* upvalue 3: guestState */
    lua_pushvalue(host_L, 4);                     /* upvalue 4: callGuestSlow ref */
    lua_pushcclosure(host_L, bound_call, 4);
    return 1;
}

static int bridge_compound_tag(lua_State *L) {
    (void)L;
    /* kept for API compatibility — no longer used by bound_call */
    lua_pushboolean(host_L, 0);
    return 1;
}

// ── dispatch_callback ─────────────────────────────────────────────────────
//
// lua_CFunction installed on the guest state via bridge.push_callback.
// Upvalue 1: integer — registry ref for the host callback function.
//
// host_L's stack must be fully restored on every exit path to avoid
// corrupting nested guest→host→guest→host call chains.

static int dispatch_callback(lua_State *guest) {
    int fn_ref    = (int)lua_tointeger(guest, lua_upvalueindex(1));
    int saved_top = lua_gettop(host_L);

    lua_rawgeti(host_L, LUA_REGISTRYINDEX, fn_ref);

    int nargs = lua_gettop(guest);
    int i;
    for (i = 1; i <= nargs; i++)
        push_primitive_or_error(guest, i, host_L);

    luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
    bridge_in_transition = 1;
    int status = lua_pcall(host_L, nargs, LUA_MULTRET, 0);
    bridge_in_transition = 0;
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
// the ref id.
static int bridge_register(lua_State *L) {
    (void)L;
    luaL_checktype(host_L, 1, LUA_TFUNCTION);
    lua_pushvalue(host_L, 1);
    luaJIT_setmode(host_L, -1, LUAJIT_MODE_FUNC | LUAJIT_MODE_OFF);
    int id = luaL_ref(host_L, LUA_REGISTRYINDEX);
    lua_pushinteger(host_L, id);
    return 1;
}

// Pushes a dispatch_callback closure onto the guest state as a real
// lua_CFunction (not FFI cdata), preventing JIT tracing into the host.
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

// Returns the new state as a lightuserdata so no lua_State* cdata crosses
// the call boundary — safe to call from within a guest callback.
static int bridge_new_state(lua_State *L) {
    (void)L;
    lua_State *new_state = luaL_newstate();
    if (!new_state) {
        lua_pushstring(host_L, "bridge_new_state: luaL_newstate() returned NULL");
        lua_error(host_L);
        return 0;
    }
    luaL_openlibs(new_state);
    lua_pushlightuserdata(host_L, (void *)new_state);
    return 1;
}

// ── Profiler buffer ───────────────────────────────────────────────────────
//
// On Windows, LuaJIT fires the profiler callback on a separate timer thread.
// Calling back into LuaJIT from that thread is unsafe, so the callback only
// calls luaJIT_profile_dumpstack (safe — the guest state is paused) and
// writes into a plain C buffer. The main thread drains the buffer after
// luaJIT_profile_stop() returns, which joins the timer thread and guarantees
// no further writes. This is why profiling is handled here rather than in Lua.

#define PROFILER_STACK_MAX  256
#define PROFILER_BUF_INIT   65536

typedef struct {
    char stack[PROFILER_STACK_MAX];
    int  samples;
    char vmstate;
} profiler_sample_t;

typedef struct profiler_buf {
    profiler_sample_t *entries;
    volatile int       count;
} profiler_buf_t;

typedef struct profiler_node {
    lua_State            *guest;
    profiler_buf_t       *buf;
    struct profiler_node *next;
} profiler_node_t;

static profiler_node_t *profiler_list = NULL;

static profiler_buf_t *profiler_find(lua_State *guest) {
    profiler_node_t *n = profiler_list;
    while (n) {
        if (n->guest == guest) return n->buf;
        n = n->next;
    }
    return NULL;
}

static profiler_buf_t *profiler_alloc(lua_State *guest) {
    profiler_buf_t *buf = (profiler_buf_t *)malloc(sizeof(profiler_buf_t));
    if (!buf) return NULL;
    buf->entries = (profiler_sample_t *)malloc(
        PROFILER_BUF_INIT * sizeof(profiler_sample_t));
    if (!buf->entries) { free(buf); return NULL; }
    buf->count = 0;

    profiler_node_t *node = (profiler_node_t *)malloc(sizeof(profiler_node_t));
    if (!node) { free(buf->entries); free(buf); return NULL; }
    node->guest   = guest;
    node->buf     = buf;
    node->next    = profiler_list;
    profiler_list = node;
    return buf;
}

static void profiler_free(lua_State *guest) {
    profiler_node_t **pp = &profiler_list;
    while (*pp) {
        if ((*pp)->guest == guest) {
            profiler_node_t *dead = *pp;
            *pp = dead->next;
            free(dead->buf->entries);
            free(dead->buf);
            free(dead);
            return;
        }
        pp = &(*pp)->next;
    }
}

static void profiler_callback(void *data, lua_State *L, int samples, int vmstate) {
    profiler_buf_t *buf = (profiler_buf_t *)data;
    int idx = buf->count;
    if (idx >= PROFILER_BUF_INIT) return;

    profiler_sample_t *s = &buf->entries[idx];

    /* Skip dumpstack while a host←→guest transition is in progress.
     * At that point the guest Lua stack has an incomplete FFI frame that
     * lj_debug_dumpstack cannot walk safely. bridge_profile_stop will fill
     * in empty stacks with the guest's stack at stop time. */
    if (!bridge_in_transition) {
        int len = 0;
        const char *stack = luaJIT_profile_dumpstack(L, "f;", 32, &len);
        if (stack && len > 0) {
            int copy = len < PROFILER_STACK_MAX - 1 ? len : PROFILER_STACK_MAX - 1;
            memcpy(s->stack, stack, (size_t)copy);
            s->stack[copy] = '\0';
        } else {
            s->stack[0] = '\0';
        }
    } else {
        s->stack[0] = '\0';
    }

    s->samples = samples;
    s->vmstate = (char)vmstate;
    buf->count = idx + 1;
}

static int bridge_profile_start(lua_State *L) {
    (void)L;
    lua_State  *guest = decode_guest_ptr(1);
    const char *mode  = lua_tostring(host_L, 2);
    if (!mode || mode[0] == '\0') mode = "fi1";

    if (profiler_find(guest)) {
        lua_pushstring(host_L, "bridge_profile_start: profiler already active for this state");
        lua_error(host_L);
        return 0;
    }

    profiler_buf_t *buf = profiler_alloc(guest);
    if (!buf) {
        lua_pushstring(host_L, "bridge_profile_start: out of memory");
        lua_error(host_L);
        return 0;
    }

    luaJIT_profile_start(guest, mode, profiler_callback, (void *)buf);
    return 0;
}

static int bridge_profile_stop(lua_State *L) {
    (void)L;
    lua_State      *guest = decode_guest_ptr(1);
    profiler_buf_t *buf   = profiler_find(guest);

    if (buf) luaJIT_profile_stop(guest);

    int n = buf ? buf->count : 0;
    lua_createtable(host_L, n, 0);

    if (buf) {
        /* After stop the profiler is quiesced and the guest stack is stable.
         * Do a single dumpstack here — safe since we are on the main thread
         * with no FFI frames in flight — and assign it to all buffered samples
         * that did not record a stack during sampling. */
        int len = 0;
        const char *cur_stack = luaJIT_profile_dumpstack(guest, "f;", 32, &len);
        char stack_str[PROFILER_STACK_MAX];
        if (cur_stack && len > 0) {
            int copy = len < PROFILER_STACK_MAX - 1 ? len : PROFILER_STACK_MAX - 1;
            memcpy(stack_str, cur_stack, (size_t)copy);
            stack_str[copy] = '\0';
        } else {
            stack_str[0] = '\0';
        }

        int i;
        for (i = 0; i < n; i++) {
            profiler_sample_t *s = &buf->entries[i];
            const char *stack = s->stack[0] ? s->stack : stack_str;
            lua_createtable(host_L, 0, 3);
            lua_pushstring(host_L, stack);
            lua_setfield(host_L, -2, "stack");
            lua_pushinteger(host_L, s->samples);
            lua_setfield(host_L, -2, "samples");
            lua_pushlstring(host_L, &s->vmstate, 1);
            lua_setfield(host_L, -2, "vmstate");
            lua_rawseti(host_L, -2, i + 1);
        }
        profiler_free(guest);
    }

    return 1;
}

static const luaL_Reg bridge_funcs[] = {
    { "make_callable",   bridge_make_callable  },
    { "compound_tag",    bridge_compound_tag   },
    { "register",        bridge_register       },
    { "push_callback",   bridge_push_callback  },
    { "unregister",      bridge_unregister     },
    { "new_state",       bridge_new_state      },
    { "profile_start",   bridge_profile_start  },
    { "profile_stop",    bridge_profile_stop   },
    { NULL, NULL }
};

int luaopen_lua_sys_bridge(lua_State *L) {
    host_L = L;
    luaL_register(L, "lua-sys.bridge", bridge_funcs);
    return 1;
}

int luaopen_sys_bridge(lua_State *L) { return luaopen_lua_sys_bridge(L); }
int luaopen_bridge(lua_State *L)     { return luaopen_lua_sys_bridge(L); }
