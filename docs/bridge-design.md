# Bridge Design

lua-sys exposes LuaJIT's own Lua C API back to a guest `lua_State` created from the host. This document explains why a compiled C bridge is necessary and how the re-entrancy constraints shape every design decision.

## The Problem: Two Independent States

When you call `lua.new()`, it creates a guest state with `luaL_newstate()`. This state is entirely independent of the host LuaJIT interpreter — it has its own heap, its own `global_State`, and its own call stack. The standard mechanism for sharing values between two states that *share* a `global_State` is `lua_xmove`, but that only works for coroutines or threads created from the same root state. It does not apply here.

The only safe way to pass values between two independent states is by copy: read the value out of one state, push an equivalent value into the other. This library only copies primitives (nil, boolean, number, string) directly. Compound types (tables, functions, userdata) are kept in whichever state owns them and accessed via `LUA_REGISTRYINDEX` refs.

## Why Not Use LuaJIT FFI for Calls?

LuaJIT's FFI lets you call C functions and use C pointers from Lua code. The `lua-sys.raw` module exposes the entire Lua C API this way — `raw.pcall`, `raw.rawgeti`, `raw.gettop`, etc. are all FFI-bound functions.

Using FFI calls directly to drive the host→guest transition works fine in simple cases but crashes under re-entrant execution. The crash site is `argv2cdata` inside `recff_cdata_call` in LuaJIT's JIT recorder.

### What triggers the crash

The JIT recorder tries to compile a hot call site. When that call site involves an FFI call on a `lua_State*` pointer, the recorder needs to emit code to pass the pointer as a C argument — this is the `argv2cdata` step. During re-entrant execution the recorder encounters the same FFI call while already in the middle of recording a trace for an outer call, and it crashes.

The re-entrant chain that triggers it:

```
Host Lua calls fn()                   ← JIT starts recording this call site
  fn() calls raw.pcall(guest_L, ...)  ← FFI call; JIT records argv2cdata for guest_L
    guest Lua runs
      guest calls host_callback()
        dispatch_callback (C) runs
          lua_pcall(host_L, ...)       ← executes host Lua inside a C frame
            host Lua calls fn() again  ← JIT tries to record the same site again
              raw.pcall(guest_L, ...)  ← argv2cdata on guest_L while trace in progress
                                          → CRASH
```

The crash happens regardless of how deeply nested the calls are. It only requires that a guest→host callback ever causes the host to call back into a guest function via FFI.

### Why `jit.off` doesn't fully solve it

Marking the FFI-calling function with `jit.off` prevents the JIT from compiling *that function*, but it does not prevent the JIT from attempting to compile its *callers*. A caller that is hot will still try to record through the call boundary, and the trace will attempt to inline the FFI path if the callee has no JIT metadata to indicate it should be treated as opaque.

More importantly, `jit.off` makes every FFI call in that function run interpreted. Each `raw.pcall`, `raw.gettop`, `raw.settop` etc. costs ~1-8 ns when JIT-compiled but more when interpreted, and they are called on every cross-state transition.

## The Solution: lua_CFunction Boundaries

A `lua_CFunction` is completely opaque to the JIT recorder. When the JIT traces a call to a C function registered via `lua_pushcfunction` or `lua_pushcclosure`, it emits a call instruction and stops recording — it never looks inside. This is the correct boundary.

The bridge registers every cross-state call as a `lua_CFunction`:

**Host → Guest** (`bound_call`): `bridge.make_callable(guest_L_ptr, ref)` pushes a `bound_call` closure onto the host state with the guest pointer and function ref baked in as C upvalues. Host code calls it as a normal Lua function. The JIT compiles the call site up to `bound_call` and stops. Inside `bound_call`, the C code calls `lua_pcall` on the guest state — no FFI involved.

**Guest → Host** (`dispatch_callback`): `bridge.push_callback(guest_L_ptr, cb_id)` pushes a `dispatch_callback` closure onto the guest state. When guest code calls a host-provided function, the guest interpreter dispatches via `BC_FUNCC` — again, a C function call, not FFI. Inside `dispatch_callback`, the C code calls `lua_pcall` on the host state.

In both directions, the transition is always: `Lua interpreter → lua_CFunction (C) → lua_pcall on the other state`. The JIT never sees across the boundary.

## Callbacks That Create New States or Call lua-sys APIs

A host callback triggered by guest code runs inside `dispatch_callback`'s `lua_pcall(host_L, ...)`. At that point the JIT may be in the middle of recording a trace for the call site that triggered the guest execution. Any FFI call made from the host callback that takes a `lua_State*` cdata argument (virtually every `raw.*` function) causes the JIT recorder to attempt `argv2cdata` conversion — the same crash path as the original re-entrancy problem, but now triggered from the *host* side.

This matters for lde's test runner, which creates a new `lua_State` (via `lua.new()`) from within a host callback that is invoked from a guest test runner state.

### Fix: JIT engine off for the duration of each callback

`dispatch_callback` disables the JIT engine before calling `lua_pcall(host_L, ...)` and re-enables it unconditionally afterward (including on all error paths):

```c
luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
int status = lua_pcall(host_L, nargs, LUA_MULTRET, 0);
luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
```

While the JIT is off, all code inside the callback runs interpreted. FFI calls are still legal interpreted — only JIT recording is prevented, so `argv2cdata` is never attempted. The JIT resumes compilation normally the moment the callback returns.

The performance cost is that host callback bodies run interpreted for their duration. Callbacks invoked from tight guest loops that are otherwise JIT-compiled will run slightly slower. In practice lua-sys callbacks are almost always short (record a result, create a state, call a function) so the overhead is negligible.

### Fix: bridge_new_state for safe state creation

`lua.new()` previously called `raw.lnewstate()` (FFI) followed by `raw.openlibs()` (FFI). Both take or return a `lua_State*` cdata. Although the JIT-off fix makes this safe from callbacks, there is also `bridge_new_state`: a C function that calls `luaL_newstate()` and `luaL_openlibs()` entirely in C and returns the pointer as a lightuserdata (not cdata). `lua.new()` calls this and casts the result to `lua_State*` cdata on the host side:

```lua
local L = ffi.cast("lua_State*", bridge.new_state())
```

This keeps state creation behind a C boundary regardless of JIT state, matching the design principle that all cross-state operations go through `lua_CFunction` boundaries.

## Debug Hooks

`state:setHook` installs a `lua_Hook` on the guest state that dispatches back to a host function — the same host↔guest pattern as `dispatch_callback`. A `lua_Hook` is a plain C function pointer with no upvalues, so the host callback ref is parked in the guest registry under a private lightuserdata key and looked up on every event:

```
hook fires (guest interpreter)
  hook_dispatch (C, lua_Hook)
    lua_getinfo(guest, "Sln", ar)     ← fill debug fields on the guest
    push event name + build info table on host_L (info.thread = guest lua_State*)
    lua_pcall(host_L, ...)            ← run host callback (JIT engine off, like dispatch_callback)
    lua_error(guest) on callback error ← aborts guest execution, catchable via pcall
```

The hook's `guest` argument is the *thread* the event fired on — the guest main thread, or a coroutine running inside it. `hook_dispatch` exposes it to the host callback as `info.thread` (a lightuserdata of the `lua_State*`). Host code casts it back with `ffi.cast("lua_State*", info.thread)` and can then call `lua_getstack` / `lua_getinfo` / `lua_getlocal` on the triggering thread to build stack traces or read locals — which would be wrong if done on the main thread while a coroutine is running.

LuaJIT only fires hooks from the interpreter — code compiled to traces never dispatches through the hook (a hot `while true do end` becomes a `LOOP` bytecode that is JIT-compiled, after which count hooks silently stop firing). `bridge_set_hook` therefore flushes existing traces and disables the guest JIT engine for as long as the hook is installed; `bridge_remove_hook` re-enables it. `state:jitoff`/`state:jiton`/`state:jitflush` expose the same `luaJIT_setmode` calls directly for explicit control.

## Stack Safety Under Re-entrancy

Because host→guest→host chains are supported, `dispatch_callback` can be called while `bound_call` is already executing on the C stack (and thus while `host_L`'s call stack is active). Both functions save and restore `lua_gettop(host_L)` around their work so that nested calls cannot corrupt each other's result slots.

```
bound_call called from host:
  guest_base = lua_gettop(guest)       ← save guest stack
  lua_pcall(guest, ...)                ← guest runs, may trigger dispatch_callback
    dispatch_callback:
      saved_top = lua_gettop(host_L)   ← save host stack depth
      lua_pcall(host_L, ...)           ← run host callback
      lua_settop(host_L, saved_top)    ← restore host stack ← MUST happen on all paths
  results start at guest_base+1
  lua_settop(guest, guest_base)        ← restore guest stack
```

If `lua_settop(host_L, saved_top)` were missing, each nested `dispatch_callback` invocation would leave the host stack slightly taller. After enough nesting the stack would overflow; at best results from inner calls would be misread as results from outer calls.

## Value Passing: Why Only Primitives Cross Directly

Compound types (tables, functions) are not copied because they contain references to their owning state's GC heap. A table from the guest state holds pointers into the guest's memory; if the host were to use those pointers after the guest GC ran, they could be dangling.

Instead, compound values are kept in their home state and accessed through `LUA_REGISTRYINDEX` refs. A ref is a stable integer that prevents the GC from collecting the value while the ref is live. When the host receives a guest function, it gets a `makeCallable` wrapper backed by a ref; when the host receives a guest table, it gets a `lua.Table` proxy that holds a ref.

The only exception is strings: LuaJIT interns strings, and `lua_tolstring` returns a C `const char*` that remains valid until the string is collected. Since we immediately `lua_pushlstring` into the destination state (which copies the bytes), this is safe.

## Performance Notes

All cross-state transitions pay at minimum the cost of `lua_rawgeti` + `lua_pcall` on the destination state (~18 ns on a modern CPU). The C bridge adds per-call overhead for:

- Decoding upvalues (guest pointer + ref): ~2 ns
- Copying primitive arguments: ~2-8 ns each
- Checking result types and copying them back: ~2-8 ns each
- `lua_settop` cleanup: ~2 ns

The callback table lookup in `dispatch_callback` uses a cached `luaL_ref` integer (O(1) `lua_rawgeti`) rather than a `lua_getfield` on the registry string key (O(n) hash lookup), saving ~13 ns per guest→host call.
