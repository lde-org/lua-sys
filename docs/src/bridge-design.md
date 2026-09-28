# Bridge Design

lua-sys gives the Lua C API of LuaJIT to a guest `lua_State` that the host
makes. This page explains two points:

- Why a compiled C bridge is necessary.
- How the re-entry limits control each design decision.

## The Problem: Two Independent States

The call `lua.new()` makes a guest state with `luaL_newstate()`. This state is
fully independent of the host LuaJIT interpreter. It has its own heap, its own
`global_State` and its own call stack.

`lua_xmove` is the standard function for values between two states. However,
that function operates on states that *share* a `global_State` only, such as
coroutines or threads of the same root state. It does not operate here.

The only safe method between two independent states is a copy. The bridge reads
a value from one state and pushes an equivalent value into the other state.
This library copies primitives directly: `nil`, `boolean`, `number` and
`string`. A compound type, such as a table, a function or a userdata, stays in
the state that owns it. The other state uses a `LUA_REGISTRYINDEX` reference to
it.

## Why Not Use LuaJIT FFI for Calls?

The LuaJIT FFI lets Lua code call C functions and use C pointers. The
`lua-sys.raw` module gives the complete Lua C API in this way. The functions
`raw.pcall`, `raw.rawgeti` and `raw.gettop` are examples of FFI-bound
functions.

FFI calls are sufficient for simple host to guest transitions. However, they
stop the process under re-entry. The fault is in `argv2cdata` inside
`recff_cdata_call` in the JIT recorder of LuaJIT.

### What triggers the fault

The JIT recorder compiles a hot call site. If the call site has an FFI call
with a `lua_State*` pointer, the recorder must make code that passes the
pointer as a C argument. This step is `argv2cdata`. Under re-entry, the
recorder finds the same FFI call while it records a trace for an outer call.
The result is a fault.

This chain causes the fault:

```
Host Lua calls fn()                   <- JIT starts to record this call site
  fn() calls raw.pcall(guest_L, ...)  <- FFI call; JIT records argv2cdata for guest_L
    guest Lua runs
      guest calls host_callback()
        dispatch_callback (C) runs
          lua_pcall(host_L, ...)       <- runs host Lua in a C frame
            host Lua calls fn() again  <- JIT tries to record the same site again
              raw.pcall(guest_L, ...)  <- argv2cdata on guest_L during the trace
                                          => FAULT
```

The depth of the calls is not important. One condition is sufficient: a guest
to host callback that causes the host to call a guest function through the FFI.

### Why `jit.off` does not fully correct the problem

The mark `jit.off` on the FFI function prevents the JIT from compiling *that
function*. It does not prevent the JIT from compiling the *callers*. A hot
caller tries to record through the call boundary. The trace then inlines the
FFI path, because the callee has no JIT metadata that identifies it as opaque.

In addition, `jit.off` makes each FFI call in that function interpreted. A call
such as `raw.pcall`, `raw.gettop` or `raw.settop` costs approximately 1 to 8 ns
when the JIT compiles it. The cost is higher when it is interpreted, and the
bridge calls these functions at each cross-state transition.

## The Solution: lua_CFunction Boundaries

A `lua_CFunction` is fully opaque to the JIT recorder. The JIT traces a call to
a C function that `lua_pushcfunction` or `lua_pushcclosure` registered. It
emits a call instruction and stops the trace. It never examines the function.
This boundary is correct.

The bridge registers each cross-state call as a `lua_CFunction`:

**Host to guest** (`bound_call`): `bridge.make_callable(guest_L_ptr, ref)`
pushes a `bound_call` closure onto the host state. The guest pointer and the
function reference are C upvalues of the closure. Host code calls the closure
as a normal Lua function. The JIT compiles the call site to `bound_call` and
stops. Inside `bound_call`, the C code calls `lua_pcall` on the guest state. No
FFI is necessary.

**Guest to host** (`dispatch_callback`): `bridge.push_callback(guest_L_ptr,
cb_id)` pushes a `dispatch_callback` closure onto the guest state. Guest code
that calls a host function dispatches through `BC_FUNCC`, which is a C function
call and not an FFI call. Inside `dispatch_callback`, the C code calls
`lua_pcall` on the host state.

In both directions, the transition is always:

```
Lua interpreter -> lua_CFunction (C) -> lua_pcall on the other state
```

The JIT never examines the other side of the boundary.

## Callbacks That Make New States or Call the lua-sys API

A host callback from guest code runs inside the `lua_pcall(host_L, ...)` of
`dispatch_callback`. At that moment, the JIT can be in the middle of a trace
for the call site that started the guest code.

An FFI call from the host callback with a `lua_State*` cdata argument causes
the `argv2cdata` conversion. Almost each `raw.*` function has this argument
type. The result is the same fault as the first re-entry problem, but the host
side causes it.

This condition occurs in the test runner of lde. The runner makes a new
`lua_State` with `lua.new()` inside a host callback from a guest test runner
state.

### Correction: JIT engine off for each callback

`dispatch_callback` disables the JIT engine before the call
`lua_pcall(host_L, ...)` and enables it again after the call. The enable step
occurs on each path, including an error path:

```c
luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
int status = lua_pcall(host_L, nargs, LUA_MULTRET, 0);
luaJIT_setmode(host_L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
```

While the JIT is off, all code in the callback is interpreted. An FFI call is
correct in interpreted code. The bridge prevents the JIT recording only, so
`argv2cdata` never occurs. The JIT starts the compilation again when the
callback returns.

The cost is that the body of a host callback is interpreted for its duration. A
callback from a tight guest loop is therefore slower. Almost all lua-sys
callbacks are short, for example to record a result or to make a state.
Therefore, the cost is small.

### Correction: bridge_new_state for safe state creation

The function `lua.new()` used `raw.lnewstate()` (FFI) and then
`raw.openlibs()` (FFI). Both functions use a `lua_State*` cdata. The JIT-off
correction makes this sequence safe from a callback. In addition, the bridge
has `bridge_new_state`. This C function calls `luaL_newstate()` and
`luaL_openlibs()` fully in C. It returns the pointer as a lightuserdata, not as
cdata. The function `lua.new()` calls it and casts the result to `lua_State*`
cdata on the host side:

```lua
local L = ffi.cast("lua_State*", bridge.new_state())
```

Thus state creation occurs behind a C boundary at each JIT state. This sequence
agrees with the design rule that all cross-state operations go through
`lua_CFunction` boundaries.

## Debug Hooks

The method `state:setHook` installs a `lua_Hook` on the guest state. The hook
dispatches to a host function, which is the same host and guest pattern as
`dispatch_callback`.

A `lua_Hook` is a plain C function pointer without upvalues. Therefore, the
bridge parks the callback reference in the guest registry under a private
lightuserdata key, and the hook reads the key at each event:

```
hook fires (guest interpreter)
  hook_dispatch (C, lua_Hook)
    lua_getinfo(guest, "Sln", ar)     <- fill the debug fields in the guest
    build the info table on host_L (all debug fields, event, thread, shared mt)
    lua_pcall(host_L, ...)            <- run the host callback (JIT engine off)
    lua_error(guest) on a callback error <- stops guest code, catchable by pcall
```

The argument `guest` of the hook is the *thread* of the event. This thread is
the main thread of the guest or a coroutine in it. `hook_dispatch` gives this
thread to the host callback as `info.thread`, which is a lightuserdata of the
`lua_State*`. Host code casts it back with
`ffi.cast("lua_State*", info.thread)`. Then it can call `lua_getstack`,
`lua_getinfo` or `lua_getlocal` on the thread of the event. A stack trace or a
local read on the main thread gives an incorrect result while a coroutine runs.

The bridge fills all debug fields (`name`, `what`, `source`, `currentline` and
more) at the event. The info table also contains `event`, `thread` and a shared
metatable. The metatable is made one time at module load and parked in the host
registry, in the same way as the callable metatable. It supplies
`info:stack()`.

The method `stack()` examines the stack of the thread of the event with
`lua_getstack` and `lua_getinfo`. It returns an array of `lua.Frame` objects.
Item 1 is the frame of the hook event. The examination needs the thread paused
at the hook. Therefore, the info table has a flag `_hook_active`. The bridge
clears the flag when `hook_dispatch` finishes. A later call to `stack()` on a
stored info table raises an error and does not examine an old stack.

A frame contains the thread and the level. Thus the host can do these steps:

- Read and write the active locals of the frame (`frame:getLocal` and
  `frame:setLocal` with `lua_getlocal` and `lua_setlocal`).
- Read and write the upvalues of its function (`frame:getUpvalue` and
  `frame:setUpvalue`).
- Evaluate code in the context of the frame (`frame:eval`).

The eval chunk runs in a new environment. The environment contains the locals
and the upvalues of the frame. The metafields `__index` and `__newindex` connect
it to the environment of the frame function (`lua_getfenv`). After the chunk
runs, the bridge writes assignments to existing locals and upvalues back with
`lua_setlocal` and `lua_setupvalue`. Thus `frame:eval("x = 42")` changes the
running program.

A frame is valid while the callback runs only. Like the fields, a frame finds
its `lua.State` through the guest registry, which all threads share. Therefore,
a frame also operates on a coroutine frame.

LuaJIT fires hooks from the interpreter only. Code in a compiled trace does not
dispatch through the hook. A hot `while true do end` becomes a `LOOP` bytecode,
the JIT compiles it, and count hooks then stop without a message. Therefore,
`bridge_set_hook` flushes the existing traces and disables the JIT engine of
the guest while the hook is installed. `bridge_remove_hook` enables the engine
again. The methods `state:jitOff`, `state:jitOn` and `state:jitFlush` give the
same `luaJIT_setmode` calls for direct control.

## Stack Safety Under Re-entry

The library supports host to guest to host chains. Therefore, the bridge can
call `dispatch_callback` while `bound_call` runs on the C stack, and while the
call stack of `host_L` is active. Both functions save and restore
`lua_gettop(host_L)` around their work. Thus a nested call cannot corrupt the
result slots of another call.

```
bound_call called from the host:
  guest_base = lua_gettop(guest)       <- save the guest stack
  lua_pcall(guest, ...)                <- guest runs, may call dispatch_callback
    dispatch_callback:
      saved_top = lua_gettop(host_L)   <- save the host stack depth
      lua_pcall(host_L, ...)           <- run the host callback
      lua_settop(host_L, saved_top)    <- restore the host stack on EACH path
  results start at guest_base+1
  lua_settop(guest, guest_base)        <- restore the guest stack
```

Without the call `lua_settop(host_L, saved_top)`, each nested
`dispatch_callback` leaves the host stack a small amount taller. After
sufficient nesting, the stack overflows. A smaller problem is that the bridge
reads the results of an inner call as the results of an outer call.

## Value Passing: Why Only Primitives Cross Directly

The bridge does not copy a compound type, such as a table or a function. Such a
value contains references to the GC heap of its owner state. A table from the
guest state contains pointers into the memory of the guest. If the host uses
these pointers after a guest GC cycle, the pointers can be invalid.

Therefore, a compound value stays in its home state and the other state uses a
`LUA_REGISTRYINDEX` reference. A reference is a stable integer. It prevents the
GC from collecting the value while the reference is live. The host receives a
guest function as a `makeCallable` wrapper with a reference. The host receives
a guest table as a `lua.Table` proxy that holds a reference.

Strings are the one exception. LuaJIT interns strings, and `lua_tolstring`
returns a C `const char*` that is valid until the collection of the string. The
bridge immediately calls `lua_pushlstring` into the destination state, which
copies the bytes. Therefore, this step is safe.

## Guest to Host Table Arguments

`dispatch_callback` has the same two paths as `bound_call`. If all arguments
are primitives, it copies them directly. This is the fast path. If one argument
is a table, it uses the slow path. Each table argument crosses as a pair
`(tag, ref)`:

- A lightuserdata tag from `bridge.compound_tag()`.
- A `LUA_REGISTRYINDEX` reference that the bridge takes in the guest.

The host helper `dispatchCallbackSlow` is registered one time and is carried in
upvalue 2 of the closure. It converts each pair back into a `lua.Table` proxy.
For this step, it finds the owner `lua.State` in a map with lightuserdata keys
that `lua.new()` fills. Then it calls the real callback with the original
argument order and the `nil` slots.

The proxies are live views. A read or a write goes directly to the guest table.
The bridge releases the guest reference at the collection of the proxy.

All other compound argument types, such as functions, userdata and threads,
give the error `cannot pass`. A return value from the host to the guest must be
a primitive.

## Performance Notes

Each cross-state transition costs a minimum of `lua_rawgeti` and `lua_pcall` on
the destination state. On a modern CPU, this cost is approximately 18 ns.

The C bridge adds this overhead for each call:

| Step | Overhead |
|---|---|
| Decode the upvalues (guest pointer and reference) | approximately 2 ns |
| Copy each primitive argument | approximately 2 to 8 ns |
| Examine and copy each result | approximately 2 to 8 ns |
| Cleanup with `lua_settop` | approximately 2 ns |

The callback lookup in `dispatch_callback` uses a cached `luaL_ref` integer,
which is an O(1) `lua_rawgeti`. It does not use `lua_getfield` on the registry
string key, which is an O(n) hash lookup. Thus each guest to host call saves
approximately 13 ns.
