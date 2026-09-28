# Sandboxing

This page states what a guest state isolates, what it does not isolate, and
what a host program must add before it can run code that it does not trust.

## What the guest cannot do

- The guest cannot see host globals, host modules or host functions. The bridge
  copies primitives and passes compound values by reference, so a value reaches
  the other side only through the API.
- The guest cannot corrupt the host state. An error in the guest returns as a
  string, and the host stack stays balanced.
- A limit on memory is exact and is enforced by the allocator of the state.
  Refer to [`state:setMemoryLimit()`](../reference.md#statesetmemorylimitbytes).
- A count hook gives a reliable instruction limit **while the `debug` and `jit`
  libraries are out of the guest**. Refer to the warning below.

## What a fresh guest state does not isolate

`lua.new()` opens every standard library, which is correct for a cooperating
guest and wrong for an untrusted one. These facts are measured on the current
version:

| Fact | Result |
|---|---|
| `require("ffi")` in the guest | Operates. The FFI gives raw memory and C calls, so it is a full escape. |
| `io.open` in the guest | Reads the host filesystem. |
| `os.execute`, `os.exit` | Operate, and `os.exit` stops the host process. |
| `package.loadlib` | Operates. |
| `loadstring(string.dump(f))` | Loads bytecode, which ignores [chunk modes](../reference.md#chunksetmodemode--luachunk). |
| Guest calls `jit.on()` | Count hooks stop firing. A watchdog built only from a count hook then never runs. |
| Guest calls `debug.sethook()` | Removes the hook of the host. |

A watchdog is therefore only reliable when the guest has no `jit` library and
no `debug` library. Both of them give the guest control over the hook mechanism
itself.

## The recipe for an untrusted guest

Run the code in a state that you prepare, and remove every path out:

1. Build the global table for the guest by hand. Keep the safe core:
   `assert`, `error`, `pcall`, `xpcall`, `select`, `type`, `tostring`,
   `tonumber`, `next`, `pairs`, `ipairs`, `unpack`, `setmetatable`,
   `getmetatable`, `rawget`, `rawset`, `rawequal`, `coroutine`, `table`,
   `string`, `math` and `bit`.
2. Leave out `io`, `os`, `package`, `require`, `debug`, `jit`, `ffi`,
   `loadfile`, `dofile`, `getfenv`, `setfenv` and `string.dump`.
3. Provide `load` and `loadstring` as host functions that use
   [`chunk:setMode("text")`](../reference.md#chunksetmodemode--luachunk), so
   the guest cannot load bytecode.
4. Set a memory limit with
   [`state:setMemoryLimit()`](../reference.md#statesetmemorylimitbytes).
5. Set a deadline with [`state:setHook()`](../reference.md#statesethookfn-mask--count)
   and a count mask, with no `jit` and no `debug` in the guest.
6. Cap the output that host callbacks give back to the guest, for example the
   bytes of a print function, because the guest controls how often it calls
   them.

## The boundary of this library

lua-sys isolates two `lua_State` instances from each other. It is not a
security boundary for the LuaJIT virtual machine itself:

- A hostile bytecode chunk can still damage the interpreter, because LuaJIT
  trusts its own bytecode. Refuse bytecode with a text mode.
- The bridge calls a host callback on the C stack of the guest. A long chain of
  host to guest to host calls uses C stack space for each step, so a sandbox
  needs a limit on the depth of the chain.
- The library gives no limit on execution time by itself. Use a hook, as in
  step 5 above.

For code that must not damage the host under any condition, add the operating
system as a second boundary: run the whole program, or a child process, with a
memory cap and a time limit from the outside. The in-process limits above then
stop most accidents before they reach the operating system.
