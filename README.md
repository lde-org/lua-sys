# lua-sys

High level bindings to LuaJIT's own Lua C API for [lde](https://lde.sh) for simple, safe and fast interaction with lua states.

## Install

```
lde add lua-sys
```

## Quick start

```lua
local lua = require("lua-sys")

local state = lua.new()                        -- make a guest state
print(state:eval("return 1 + 2"))              -- 3

local add = state:load("return function(a, b) return a + b end"):eval()
print(add(1, 2))                               -- 3

local g = state:globals()                      -- the guest global table
g.config = { timeout = 5, retries = 3 }        -- a host table becomes a guest table
g.log = function(text) print("[guest] " .. text) end

state:load("log('timeout is ' .. config.timeout)"):call()   -- [guest] timeout is 5

state:close()                                  -- release the state
```

## Documentation

The complete documentation can be found at https://lde-org.github.io/lua-sys

## How it works

The LuaJIT FFI is not safe for re-entry between independent `lua_State`
instances. A call into a guest state through the FFI while guest code is active
can stop the trace recorder of LuaJIT.

lua-sys sends each host and guest transition through a compiled C function
(`lua_CFunction`). The JIT sees such a function as an opaque boundary and does
not trace through it. Refer to [Bridge Design](docs/src/bridge-design.md) for
the full explanation.

## Performance

A cross-state call costs ~70 - 200 ns. The cost depends on the
direction and the number of arguments:

| Call path | Overhead |
|---|---|
| Host → guest (no operation) | ~70 ns |
| Host → guest (2 arguments, 1 result) | ~120 ns |
| Guest → host callback (no operation) | ~130 ns |
| Host → guest → host (round trip) | ~200 ns |

Run `lde ./benchmarks/latency.lua` for a measurement on your machine.
