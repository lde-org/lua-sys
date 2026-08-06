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

-- Evaluate an expression in the guest (shorthand)
print(state:eval("return 1 + 2"))  -- 3

-- Load a chunk, then evaluate it — returns the first result
local add = state:load("return function(a, b) return a + b end"):eval()
print(add(1, 2))  -- 3

-- Shortcut: chunk(...) is equivalent to chunk:eval(...)
local mul = state:load("return function(a, b) return a * b end")()
print(mul(3, 4))  -- 12

-- Expose host functions to guest code
local g = state:globals()
g.greet = function(name)
    print("Hello, " .. name .. "!")
end

-- Plain host tables are automatically coerced to guest tables
g.config = { timeout = 5, retries = 3 }

-- Execute a chunk without expecting a return value
state:load('function() greet("world") end'):call()  -- Hello, world!

-- Pass arguments that populate ... inside the guest
state:load("_person = ..."):call("Alice")
print(g._person)  -- Alice

-- Guest can call back into host, host can call back into guest
g:set("double", function(x) return x * 2 end)
local nested = state:eval("return function(x) return double(x) + double(x) end")
print(nested(5))  -- 20

-- Always close when done
state:close()
```

## API

### `lua.new() → lua.State`

Creates a new guest `lua_State` with all standard libraries loaded.

### `state:eval(code [, chunkName]) → value`

Compiles and evaluates a Lua chunk immediately, returning the first result. Equivalent to `state:load(code, chunkName):eval()`. A bare expression (e.g. `"1 + 2"`) is automatically wrapped with `return`.

```lua
local v = state:eval("return 42")           -- 42
local fn = state:eval("function(x) return x * 2 end")
print(fn(5))  -- 10
```

An optional `chunkName` sets the chunk name visible to `debug.getinfo(1, "S").source` inside the guest. Prefix with `@` for file paths (e.g. `"@/path/to/file.lua"`).

### `state:load(code [, chunkName]) → lua.Chunk`

Loads Lua source code and returns a `lua.Chunk` builder. The chunk is **not** compiled or executed until you call `:eval()` or `:call()` on it. This lets you configure the chunk (e.g. set its debug name) before running it, and pass arguments that populate `...` inside the guest.

```lua
-- Configure before running
local chunk = state:load("return ...")
    :setName("@myscript.lua")

print(chunk:eval("hello"))  -- hello
print(chunk:eval("world"))  -- world (can re-evaluate multiple times)

-- Execute a script without expecting a return value
state:load("print(\"hello from guest\")"):call()

-- Pass multiple arguments that populate ...
state:load("local a, b = ...; _result = a + b"):call(3, 4)
print(state:globals()._result)  -- 7

-- Chunk is callable: chunk(...) is shorthand for chunk:eval(...)
print(state:load("return ... * 2")(21))  -- 42
```

### `lua.Chunk`

A builder object returned by `state:load()` that holds Lua source code and optional configuration. Compilation happens lazily when you execute the chunk.

#### `chunk:eval(...) → value`

Compiles and evaluates the chunk, passing any arguments as `...` inside the guest. Returns the first result, or `nil` if the chunk returns nothing.

#### `chunk:call(...)`

Compiles and executes the chunk, discarding any return values. Arguments are passed as `...` inside the guest. Use this for side-effectful scripts where you don't need a result.

#### `chunk:pcall(...) → true, ... | false, err`

Like `:eval()`, but errors are returned instead of raised on the host side. Returns `true` followed by **all** results on success, or `false, err` when the chunk raises a guest error. Compile (syntax) errors are also caught and returned as `false, err`.

```lua
local ok, a, b = state:load("return ... + 1, ... * 2"):pcall(10)
-- ok == true, a == 11, b == 20

local ok, err = state:load("error('boom')"):pcall()
-- ok == false, err == "...boom..."
```

#### `chunk:setName(name) → lua.Chunk`

Sets the chunk name for debug purposes (visible via `debug.getinfo(1, "S").source`). Prefix with `@` for file paths. Returns self for chaining.

#### `chunk(...)`

The `__call` metamethod. Calling a chunk directly is shorthand for `chunk:eval(...)`.

### Guest function callables

Guest functions obtained from the state (e.g. via `state:eval("function(...) ... end")` or `Table:get`) are plain host functions — call them directly with `fn(...)`. Each callable also carries a `pcall` method for protected calls.

#### `fn:pcall(...) → true, ... | false, err`

Calls the guest function with pcall semantics: returns `true` followed by **all** results on success, or `false, err` on error — the guest error is returned instead of being raised on the host side.

```lua
local fn = state:eval("function(x) return x * 2, x + 1 end")
local ok, a, b = fn:pcall(21)
-- ok == true, a == 42, b == 22

local boom = state:eval("function() error('kaboom') end")
local ok, err = boom:pcall()
-- ok == false, err == "...kaboom..."
```

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

### `state:setHook(fn, mask [, count])`

Installs a debug hook on the guest state — the high-level counterpart to the raw `lua_sethook` API, so you don't need FFI casts or raw callback plumbing. `fn` is a host Lua function called as `fn(event, info)` on each hook event:

- `event` — one of `"call"`, `"return"`, `"line"`, `"count"`, `"tailcall"`
- `info` — a plain table with the standard debug fields: `event`, `name`, `namewhat`, `what`, `source`, `short_src`, `currentline`, `linedefined`, `lastlinedefined`, `nups`

`mask` selects which events fire: a space-separated string of event names (`"line"`, `"call return"`, `"count"`, ...) or an integer bitmask (`LUA_MASKCALL`=1, `LUA_MASKRET`=2, `LUA_MASKLINE`=4, `LUA_MASKCOUNT`=8). `count` sets the instruction interval for the `"count"` event (default 1).

Passing `nil` removes the hook: `state:setHook(nil)`.

LuaJIT only fires hooks on interpreted code, so while a hook is installed the guest JIT engine is disabled (and existing traces flushed); removing the hook re-enables it. A hook that errors aborts the running guest code with that error (catchable with `pcall` around `state:eval`/`chunk:eval`), which makes count hooks a convenient way to enforce execution timeouts:

```lua
state:setHook(function(event, info)
    error("timeout: infinite loop detected")
end, "count", 1000)

local ok, err = pcall(function()
    state:eval("while true do end")
end)
-- ok == false, err contains "timeout"
```

### `state:jitOff([fn])` / `state:jitOn([fn])` / `state:jitFlush()`

Disable/re-enable the JIT compiler for the guest state — or for a single guest function when a callable obtained from the state is passed — and drop all compiled traces:

```lua
state:jitOff()        -- disable JIT for the whole guest state
state:jitOff(fn)      -- disable JIT for just one guest function
state:jitOn()         -- re-enable
state:jitFlush()      -- drop all compiled traces
```

`state:setHook` manages the engine automatically while a hook is installed, but these methods give you explicit control (e.g. to keep the rest of the state JIT-compiled while tracing one function). `state:jitOff()`/`state:jitOn()` return the state for chaining.

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
