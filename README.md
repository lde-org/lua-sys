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
g.greet = function(name)
    print("Hello, " .. name .. "!")
end

-- Plain host tables are automatically coerced to guest tables
g.config = { timeout = 5, retries = 3 }

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

### `state:load(chunk [, chunkName]) → callable`

Compiles and evaluates a Lua chunk in the guest state. A bare expression (e.g. `"function(a, b) end"`) is automatically wrapped with `return`. Returns the first result as a callable if it's a function, a `lua.Table` if it's a table, or a primitive value.

An optional `chunkName` sets the chunk name visible to `debug.getinfo(1, "S").source` inside the guest. Prefix with `@` for file paths (e.g. `"@/path/to/file.lua"`), which follows the LuaJIT convention.

### `state:globals() → lua.Table`

Returns a `lua.Table` wrapping the guest state's global environment (`_G`).

### `state:table([init]) → lua.Table`

Creates a new empty guest table. If `init` is provided, it must be a plain host table whose keys and values are recursively copied into the guest table:

| Host value type | Converted to |
|---|---|
| `string`, `number`, `boolean` | Copied directly |
| Plain nested table | Recursively converted to a guest table |
| `lua.Value` (guest ref) | Stored as-is |
| `function` | Registered as a host callback |

Self-referencing or mutually-referencing tables raise a `"cycle detected"` error, since deep copies cannot reproduce circular references across state boundaries. Non-cyclic duplicates (same table as separate values) produce independent copies.

```lua
local t = state:table({ name = "alice", pos = { x = 1, y = 2 }, greet = function(n) return "hi " .. n end })
print(t.name)       -- alice
print(t.pos.x)      -- 1
print(t:get("greet")("world"))  -- hi world
```

### `state:close()`

Closes the guest state and releases all resources. Must be called when the state is no longer needed.

### `lua.Table:get(key) → value`

Reads a key from the table. Returns primitives as-is, functions as callables, and nested tables as `lua.Table` proxies.

### `lua.Table:set(key, value)`

Writes a key into the table. Accepts primitives, host Lua functions, guest function callables, and other `lua.Table` values. Plain host tables (`{ ... }`) are automatically coerced to guest tables.

### `lua.Table` field access

`lua.Table` proxies field reads and writes directly to `:get()` and `:set()`, so you can use `tbl.key` syntax instead of `tbl:get("key")`. Plain host tables assigned this way are automatically coerced:

```lua
local g = state:globals()
g.myVar = 42                     -- same as g:set("myVar", 42)
g.config = { timeout = 5 }       -- plain table → guest table
print(g.myVar)                   -- same as g:get("myVar")
print(g.config.timeout)          -- 5
```

Method names (`get`, `set`, `pairs`, `ipairs`, `type`, `value`, `free`) take priority over table keys.

### `lua.Table:pairs() → iterator`

Returns a stateless iterator over all key/value pairs, equivalent to `pairs()` on a plain table:

```lua
for k, v in t:pairs() do
    print(k, v)
end
```

### `lua.Table:ipairs() → iterator`

Returns a stateless iterator over the integer keys `1..n`, equivalent to `ipairs()`:

```lua
for i, v in t:ipairs() do
    print(i, v)
end
```

## Profiler

lua-sys includes a sampling profiler that profiles guest `lua_State` instances using LuaJIT's built-in profiler hooks:

```lua
local profiler = require("lua-sys.profiler")

profiler.start(state, "fi1")
-- ... run guest code ...
local report = profiler.stop(state)
profiler.print(report)
```

### `profiler.start(state [, mode] [, callback])`

Starts profiling a guest state.

- `mode` — LuaJIT profiler mode string (default `"fi1"`): `f` for function-level, `l` for line-level, `i<ms>` for sampling interval.
- `callback` — optional `function(stack, samples, vmstate)` called once per sample tick. When omitted, samples are aggregated and returned by `stop()`.

### `profiler.stop(state) → report`

Stops profiling and returns an aggregated report (sorted by sample count descending):

```lua
{
    { stack = "fn1;fn2", count = 150, percent = 75.0 },
    { stack = "fn3",     count = 50,  percent = 25.0 },
    total = 200,
}
```

Returns `nil` if started with a custom callback.

### `profiler.print(report [, out] [, min_percent])`

Prints a report to stdout (or a file handle), hiding entries below `min_percent` (default 1%).

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
