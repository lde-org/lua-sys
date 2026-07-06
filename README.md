# lua-sys

Safe bindings to LuaJIT's own exposed Lua C API for [lde](https://lde.sh). Lets you create and interact with independent guest `lua_State` instances from host LuaJIT code.

## Usage

```
lde add lua-sys --git https://github.com/lde-org/lua-sys
```

## Example

```lua
local lua = require("lua-sys")

-- Create an independent guest Lua state
local state = lua.new()

-- Load and call guest functions
local add = state:load("function(a, b) return a + b end")
print(add(1, 2))  -- 3

-- Expose host functions to guest code
local g = state:globals()
g:set("greet", function(name)
    print("Hello, " .. name .. "!")
end)

local runner = state:load('function() greet("world") end')
runner()  -- Hello, world!

-- Guest can call back into host, host can call back into guest
g:set("double", function(x) return x * 2 end)
local nested = state:load("function(x) return double(x) + double(x) end")
print(nested(5))  -- 20

-- Always close when done
state:close()
```

## API

### `lua.new() → lua.State`

Creates a new guest `lua_State` with all standard libraries loaded.

### `state:load(chunk) → callable`

Compiles and evaluates a Lua chunk in the guest state. A bare expression (e.g. `"function(a, b) end"`) is automatically wrapped with `return`. Returns the first result as a callable if it's a function, a `lua.Table` if it's a table, or a primitive value.

### `state:globals() → lua.Table`

Returns a `lua.Table` wrapping the guest state's global environment (`_G`).

### `state:close()`

Closes the guest state and releases all resources. Must be called when the state is no longer needed.

### `lua.Table:get(key) → value`

Reads a key from the table. Returns primitives as-is, functions as callables, and nested tables as `lua.Table` proxies.

### `lua.Table:set(key, value)`

Writes a key into the table. Accepts primitives, host Lua functions, guest function callables, and other `lua.Table` values.

## How it works

LuaJIT's FFI is not re-entrant safe across independent `lua_State` boundaries. Calling into a guest state via FFI while already inside a guest callback causes LuaJIT's JIT recorder to crash (`argv2cdata` in `recff_cdata_call`).

lua-sys avoids this by routing every host↔guest transition through compiled C functions (`lua_CFunction`) rather than FFI calls. The JIT sees these as opaque C boundaries and never tries to trace through them. See [`docs/bridge-design.md`](docs/bridge-design.md) for a full explanation.

## Performance

Cross-state calls have approximately 70–200 ns overhead depending on direction and argument count:

| Call path | Overhead |
|---|---|
| Host → Guest (noop) | ~70 ns |
| Host → Guest (2 args, 1 return) | ~120 ns |
| Guest → Host callback (noop) | ~130 ns |
| Host → Guest → Host round-trip | ~200 ns |

Run `lde ./benchmarks/latency.lua` for measurements on your machine.
