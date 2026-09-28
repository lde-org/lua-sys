# API Reference

`lua-sys` gives you the Lua C API of LuaJIT. Use it to make guest `lua_State`
instances and to control them from the host program.

```lua
local lua = require("lua-sys")
```

The module has three members:

| Member | Function |
|---|---|
| `lua.new()` | Makes a guest state. |
| `lua.raw` | The [`lua-sys.raw`](#lua-sysraw) module. It binds the complete Lua C API with FFI. |
| `lua.profiler` | The [`lua-sys.profiler`](#profiler) module. It samples guest states. |

The high-level API below is the approved method to control a guest state.
Values cross between the host and the guest in two ways: by copy for
primitives, or by reference for tables, functions, userdata and threads.

## Quick index

| Object | Members |
|---|---|
| `lua` | [`new()`](#luanew--luastate) |
| `lua.State` | [`load`](#stateloadcode--chunkname--luachunk), [`eval`](#stateevalcode--chunkname--value), [`globals`](#stateglobals--luatable), [`table`](#statetableinit--luatable), [`setHook`](#statesethookfn-mask--count), [`jitOff`](#statejitofffn--state-statejitonfn--state-statejitflush), [`jitOn`](#statejitofffn--state-statejitonfn--state-statejitflush), [`jitFlush`](#statejitofffn--state-statejitonfn--state-statejitflush), [`close`](#stateclose), `L` |
| `lua.Chunk` | [`eval`](#chunkeval--value), [`call`](#chunkcall), [`pcall`](#chunkpcall--true---false-err), [`xpcall`](#chunkxpcall--true---false-err), [`setName`](#chunksetnamename--luachunk), [`setMode`](#chunksetmodemode--luachunk), [`getMode`](#chunkgetmode--text--bytecode--both), [`isBytecode`](#chunkisbytecode--boolean) |
| guest callable | `fn(...)`, [`fn:pcall(...)`](#fnpcall--true---false-err) |
| `lua.Table` | [`get`](#tablegetkey--value), [`set`](#tablesetkey-value), field syntax, [`pairs`](#tablepairs--iterator), [`ipairs`](#tableipairs--iterator), [`type`](#valuetype--string), [`value`](#valuevalue--any), [`free`](#valuefree) |
| `lua.Value` | [`type`](#valuetype--string), [`value`](#valuevalue--any), [`free`](#valuefree) |
| `lua.HookInfo` | debug fields, `thread`, [`stack()`](#infostack--luaframe) |
| `lua.Frame` | [`locals`](#framelocals---name-value-), [`getLocal`](#framegetlocalname--value), [`setLocal`](#framesetlocalname-value--boolean), [`upvalues`](#frameupvalues---name-value-), [`getUpvalue`](#framegetupvaluename--value), [`setUpvalue`](#framesetupvaluename-value--boolean), [`eval`](#frameevalcode--true-any--false-err) |
| `lua.profiler` | [`start`](#profilerstartstate--mode--callback), [`stop`](#profilerstopstate--report), [`print`](#profilerprintreport--out--min_percent) |
| `lua.raw` | The complete Lua C API with FFI. Refer to [Naming](#naming). |

## How values cross the boundary

The guest is an independent interpreter. It has its own heap, its own globals,
its own `package.loaded` and its own JIT engine. Nothing is shared with the
host. Each value that crosses is a copy or a reference.

### Host → guest

| Host value | Result in the guest |
|---|---|
| `nil`, `boolean`, `number`, `string` | A copy. A string can contain null bytes. |
| Plain Lua table `{ ... }` | A new guest table. The conversion is recursive. Refer to [`state:table()`](#statetableinit--luatable). |
| `lua.Table` | The same guest table, as a reference. |
| `lua.Value` | The same guest value, as a reference. |
| Host function | A guest C closure. Guest code can call it. Each crossing makes a new closure, so two uses of the same host function are not equal in the guest. |
| Guest callable of this state | The original guest function. |
| All other values | An error: `cannot push value of type '<type>' onto guest stack`. |

### Guest → host

| Guest value | Result on the host |
|---|---|
| `nil`, `boolean`, `number`, `string` | A plain host value. |
| `table` | A `lua.Table` proxy. The proxy is a live view, not a copy. |
| `function` | A [guest callable](#guest-function-callables), which is a plain host function. |
| `userdata`, `lightuserdata`, `thread` | A `lua.Value` reference. |

Thus `type(x)` on the host is a reliable test. A guest table always arrives as
a host `table`, and this value is always a `lua.Table`.

### Arguments of host callbacks

Guest code can call a host function. The bridge converts the arguments from
guest values to host values. Only primitives and tables can cross in this
direction. A function, a userdata or a thread causes this error:

```
bridge: cannot pass <type> across independent states
```

To send these values to the host, put them in a guest table and pass the table.

### Return values of host callbacks

A host callback can return primitives only: `nil`, `boolean`, `number` and
`string`. The bridge copies each returned value into the guest. This error
occurs if the callback returns a table, a `lua.Table`, a function or another
compound value:

```
bridge: host callback returned a <type>; only primitives (nil, boolean, number, string) can be returned from host to guest
```

To give structured data to the guest, write the data into the guest. You can
do one of these two steps:

- Set a guest global.
- Let the guest pass a table to the callback. The callback gets a live
  `lua.Table` view and can change the table.

```lua
state:globals().fill = function(t)
    t.timeout = 5          -- t is the guest table from the guest
    t.retries = 3
    return true            -- a primitive result is correct
end

state:eval("local cfg = {}; fill(cfg); return cfg.timeout")  -- 5
```

## `lua.new() → lua.State`

Makes a new guest `lua_State`. These libraries are open in the new state: the
base library, `package`, `coroutine`, `table`, `string`, `math`, `io`, `os`,
`debug`, `bit` and `jit`.

The modules `ffi` and `string.buffer` are not preloaded. However,
`require("ffi")` and `require("string.buffer")` operate in the guest.

The new state is fully independent of the host interpreter.

```lua
local state = lua.new()
print(state:eval("return _VERSION"))       -- Lua 5.1
print(state:eval("return jit.version"))    -- LuaJIT 2.1.x
state:close()
```

Close the state with [`state:close()`](#stateclose) when you do not need it
again.

### `state.L → lua_State*`

The raw guest state pointer, as an FFI `cdata` value. Use it with
[`lua-sys.raw`](#lua-sysraw), with `ffi.C` calls, or to compare it with
`info.thread` in a hook. The value is `nil` after the state is closed.

### `state:close()`

Closes the guest state. The operation releases the heap, the registry
references and all host callbacks of the state. A second call is safe.

All `lua.Table` objects, `lua.Value` objects and guest callables of the state
become invalid. Their registry references stop with the state.

> [!NOTE]
> Each operation on a closed state gives the error `state is closed`. This rule
> covers `state:eval`, `state:load`, `state:globals`, `state:table`, the
> `lua.Chunk` methods, the `lua.Table` methods and calls to a guest callable.
> A call with `fn:pcall()` gives `false, "state is closed"`. A stored
> [frame](#luaframe) gives neutral results, as it does after the hook returns.
> The process does not stop.

Close the state one time only, at the end of its life. Do not use the objects
of a closed state.

## Evaluating code

### `state:load(code [, chunkName]) → lua.Chunk`

Wraps Lua source code in a builder. You can set up the builder before the code
runs. The operation does not compile the code. Therefore, a syntax error occurs
at the call that runs the chunk, not at `state:load()`.

`chunkName` sets the chunk name for the debug information. Guest code sees this
name as `debug.getinfo(1, "S").source`. Use the prefix `@` for a file path, for
example `"@/path/to/file.lua"`.

The argument `code` can be source text or LuaJIT bytecode. A chunk accepts both
by default. Refer to [`chunk:setMode()`](#chunksetmodemode--luachunk) to refuse
one format, and to
[`chunk:isBytecode()`](#chunkisbytecode--boolean) to examine the source.

### `state:eval(code [, chunkName]) → value`

Compiles and runs `code` immediately. The method returns the first result. It
returns `nil` if the chunk has no result. This method is the same as
`state:load(code, chunkName):eval()`.

The method first compiles the code as `return <code>`. If the result is a
syntax error, it compiles the original source. Thus a bare expression operates,
and a block of statements operates also:

```lua
local state = lua.new()

print(state:eval("1 + 2"))                        -- 3
print(state:eval("return 1 + 2"))                 -- 3
print(state:eval("local x = 5; return x * 2"))    -- 10
print(state:eval("local x = 5"))                  -- nil
```

An error in the guest, and a syntax error, becomes a string error on the host.
Use `pcall` to catch it:

```lua
local ok, err = pcall(function() return state:eval("error('boom')") end)
-- ok == false, err == "boom"
```

### `lua.Chunk`

The builder from `state:load()`. It holds the source code, an optional chunk
name, an optional [mode](#chunksetmodemode--luachunk) and the owner state.

The chunk compiles one time, at its first run, and keeps the result. Later runs
use the compiled function again, so a run costs about the same as a call to a
guest function. A chunk that returns a function still creates a new closure at
each run. A change of the name or of the mode compiles the chunk again.

A chunk accepts source text and LuaJIT bytecode by default. Use
[`chunk:setMode()`](#chunksetmodemode--luachunk) to refuse one format, and
[`chunk:isBytecode()`](#chunkisbytecode--boolean) to examine the source before
the chunk runs.

#### `chunk:eval(...) → value`

Compiles and runs the chunk. The arguments become `...` in the guest. The
method returns the first result, or `nil` if the chunk has no result. An error
in the guest becomes an error on the host.

```lua
local chunk = state:load("return ...")
print(chunk:eval("hello"))   -- hello
print(chunk:eval("world"))   -- world
```

#### `chunk:call(...)`

Compiles and runs the chunk. The arguments become `...` in the guest. The
method discards all results. Use it for a script with side effects.

```lua
state:load("print('hello from guest')"):call()
state:load("_sum = select('#', ...)"):call(1, 2, 3)
print(state:globals()._sum)  -- 3
```

#### `chunk:pcall(...) → true, ... | false, err`

The same as `:eval()`, but the method returns errors and does not raise them.
The result is `true` and all results after a success, or `false, err` after a
failure. The method also catches a syntax error, because the compilation occurs
inside the protected call.

```lua
local ok, a, b = state:load("return ... + 1, ... * 2"):pcall(10)
-- ok == true, a == 11, b == 20

local ok2 = state:load("local x = 1"):pcall()
-- ok2 == true, because a chunk without a result gives only true

local ok3, err3 = state:load("1 +"):pcall()
-- ok3 == false, err3 == "[string \"1 +\"]:1: unexpected symbol near '1'"

local ok4, err4 = state:load("error('boom')"):pcall()
-- ok4 == false, err4 == "boom"
```

#### `chunk:xpcall(...) → true, ... | false, err`

This method has the same result as `:pcall()`. In addition, the error string
contains a guest stack traceback after a failure. The guest `debug.traceback`
is the error handler for the call, so the traceback is complete before the
stack clears.

```lua
local ok, err = state:load("error('boom')"):xpcall()
-- ok == false
-- err == "boom\nstack traceback:\n\t..."
```

Use `:xpcall()` to report an error in guest code with context. Use `:pcall()`
when the message alone is sufficient.

#### `chunk:setName(name) → lua.Chunk`

Sets the chunk name for the debug information. The method returns the chunk, so
you can add more calls. A new name makes the next run compile again. This method is the same as the argument `chunkName` of
`state:load()`.

```lua
local src = state:load("return debug.getinfo(1, 'S').source")
    :setName("@myscript.lua")
    :eval()
print(src)  -- @myscript.lua
```

#### `chunk:setMode(mode) → lua.Chunk`

Sets the format that the chunk accepts. The method returns the chunk, so you
can add more calls. A new mode makes the next run compile again.

| Mode | Meaning |
|---|---|
| `"text"` | Source text only. The loader refuses bytecode. |
| `"bytecode"` | LuaJIT bytecode only. The loader refuses source text. |
| `"both"` | Source text or bytecode. This is the default. |

The Lua mode letters `"t"`, `"b"` and `"bt"` are also correct, and `"binary"`
is an alias of `"bytecode"`. The value is not case sensitive.

A mismatch shows at the call that runs the chunk. The error is
`attempt to load chunk with wrong mode`:

```lua
local bytecode = state:eval("return string.dump(function() return 7 end)")

state:load(bytecode):eval()                     -- 7, the mode is "both"
state:load(bytecode):setMode("text"):eval()     -- raises "wrong mode"
state:load(bytecode):setMode("bytecode"):eval() -- 7
state:load("return 1"):setMode("bytecode"):eval() -- raises "wrong mode"
```

The method `chunk:pcall()` returns the error instead of raising it:

```lua
local ok, err = state:load(bytecode):setMode("text"):pcall()
-- ok == false, err == "attempt to load chunk with wrong mode"
```

An unknown mode gives `setMode: unknown mode "<mode>" (expected "text",
"bytecode" or "both")`. A value that is not a string gives `setMode: mode must
be "text", "bytecode" or "both", got <type>`.

#### `chunk:getMode() → "text" | "bytecode" | "both"`

The format that the chunk accepts. The value is `"both"` until you call
`setMode()`.

```lua
print(state:load("return 1"):getMode())                    -- both
print(state:load("return 1"):setMode("text"):getMode())    -- text
```

#### `chunk:isBytecode() → boolean`

`true` when the source of the chunk starts with the escape byte that marks a
precompiled chunk. Use this method to examine data from a source that you do
not trust, before the chunk runs.

LuaJIT loads bytecode with the signature `\27LJ`. Other binary data also starts
with the escape byte. The loader refuses such data with `cannot load
incompatible bytecode` or `cannot load malformed bytecode`.

```lua
local chunk = state:load(source)

if chunk:isBytecode() then
    error("bytecode is not permitted")
end

chunk:setMode("text"):call()
```

The mode does not change the result of `isBytecode()`.

#### `chunk(...)`

The `__call` metamethod. A direct call to a chunk is the same as
`chunk:eval(...)`.

```lua
print(state:load("return ... * 2")(21))  -- 42
```

## Guest function callables

A guest function arrives on the host as an ordinary host function. This event
occurs when the function is a result of `state:eval()`, `:load():eval()`,
`chunk:pcall()`, `Table:get()` or an iteration with `pairs()`. The host
function calls back into the guest:

```lua
local add = state:eval("return function(a, b) return a + b end")
print(add(1, 2))  -- 3

local double = state:eval("return function(x) return x * 2 end")
state:globals().double = double          -- and back into the guest
print(state:eval("return double(21)"))   -- 42
```

Arguments and results obey the rules above. The bridge copies primitives, and
it passes tables by reference. An error in the guest raises an error on the
host.

Each crossing makes a new host closure. Therefore, two references to the same
guest function are not `==` on the host. The same rule applies to two proxies
of one guest table. Compare values in the guest if identity is important.

#### `fn:pcall(...) → true, ... | false, err`

Calls the guest function with protection. The result is `true` and all results,
or `false, err` when the guest function raises an error. The host gets no
error.

```lua
local fn = state:eval("return function(x) return x * 2, x + 1 end")
local ok, a, b = fn:pcall(21)
-- ok == true, a == 42, b == 22

local boom = state:eval("return function() error('kaboom') end")
local ok2, err = boom:pcall()
-- ok2 == false, err == "[string \"return function() error('kaboom') end\"]:1: kaboom"
```

A guest function without a result gives `true` only. The method comes from a
function metatable, so the field `fn.pcall` is also available.

## Globals and tables

### `state:globals() → lua.Table`

Returns a `lua.Table` proxy for the global environment of the guest (`_G`):

```lua
local g = state:globals()
g.myVar = 42
print(state:eval("return myVar"))  -- 42
print(g.print == nil)              -- false, because print is a callable
```

Each call gives a new proxy for the same guest table. Two proxies are never
`==`. Keep one proxy, or compare the guest tables in the guest.

### `state:table([init]) → lua.Table`

Makes a new empty guest table. The argument `init` is optional and is a plain
host table. The new table is not registered. Assign it to a global, return it,
or pass it to guest code.

```lua
local t = state:table({
    name = "alice",
    pos  = { x = 1, y = 2 },
    greet = function(n) return "hi " .. n end,
})

print(t.name)                     -- alice
print(t.pos.x)                    -- 1
print(t:get("greet")("world"))    -- hi world
```

The bridge converts the keys and the values of `init` with the normal host →
guest rules:

| Entry in `init` | Result in the guest |
|---|---|
| Key of type `string`, `number` or `boolean` | A copy. |
| Value `nil`, `boolean`, `number` or `string` | A copy. |
| Value is a plain nested table | A new guest table. The conversion is recursive. |
| Value is a `lua.Table` or a `lua.Value` | The guest value, as a reference. |
| Value is a host function | A host callback. |

`state:table()` gives these errors:

| Condition | Error |
|---|---|
| `init` is not a table (`nil` is permitted) | `state:table() init argument must be a table, got <type>` |
| A key is not a string, a number or a boolean | `state:table(): unsupported key type '<type>'` |
| The table contains itself, directly or mutually | `state:table(): cycle detected in init table` |

The cycle test tells a back edge from a duplicate. One table as two sibling
values gives two copies and no error. A table that contains itself gives an
error. A circular structure is not possible across state boundaries, so the
bridge rejects it.

### `Table:get(key) → value`

Reads a key. Primitive values come back directly. A guest function comes back
as a callable, a nested table as a `lua.Table` proxy, and a userdata or a
thread as a `lua.Value`. A key that is absent gives `nil`.

The key can be a primitive or a guest value, such as a `lua.Table`, a callable
or a `lua.Value`.

### `Table:set(key, value)`

Writes a key. The value can be a primitive, a host function, a guest callable,
a `lua.Table` or `lua.Value` reference, or a plain host table. A plain host
table becomes a new guest table. A key with the value `nil` is removed.

### `Table` field access

A `lua.Table` proxy sends field reads to `:get()` and field writes to `:set()`.
Thus `tbl.key` is the same as `tbl:get("key")`, and `tbl.key = v` is the same
as `tbl:set("key", v)`:

```lua
local g = state:globals()
g.myVar = 42                     -- g:set("myVar", 42)
g.config = { timeout = 5 }       -- plain table becomes a guest table
print(g.myVar)                   -- 42
print(g.config.timeout)          -- 5
```

A method name has priority over a guest key. The names `get`, `set`, `pairs`,
`ipairs`, `type`, `value` and `free` always give the method of the proxy. To
read a guest key with one of these names, use `:get()` with a string, for
example `t:get("type")`.

### `Table:pairs() → iterator`

Gives a stateless iterator for all key/value pairs of the guest table. It is
the same as `pairs()` on a plain table, and it uses the `next` function of the
guest:

```lua
for k, v in t:pairs() do
    print(k, v)
end
```

### `Table:ipairs() → iterator`

Gives a stateless iterator for the integer keys `1..n`. The iteration stops at
the first `nil`. It is the same as `ipairs()`:

```lua
for i, v in t:ipairs() do
    print(i, v)
end
```

> [!WARNING]
> Use the methods of the proxy. Do not use the host operators `#t`, `pairs(t)`
> and `ipairs(t)`. These operators act on the host wrapper table of the proxy
> and its internal fields `_state`, `_ref` and `_type`. The result is incorrect
> for the guest table. For example, `#t` gives `0`, and `pairs(t)` iterates the
> internal fields. The function `next(t)` is also incorrect. Always use
> `t:pairs()` and `t:ipairs()`. Use the `#` operator in the guest when you need
> a length.

## `lua.Value`

A reference to a guest value without its own host proxy: `userdata`,
`lightuserdata` and `thread`. `lua.Table` has the same methods.

```lua
local out = state:eval("return io.stdout")
print(type(out), out:type())   -- table, userdata
print(tostring(out))           -- lua.userdata
out:free()                     -- release the registry reference now
```

### `Value:type() → string`

The name of the guest type: `"nil"`, `"boolean"`, `"number"`, `"string"`,
`"table"`, `"function"`, `"userdata"`, `"lightuserdata"` or `"thread"`. For a
`lua.Table`, the result is `"table"`.

### `Value:value() → any`

The value behind the reference. For a live reference, the method returns the
object itself. The guest value is not copied. After `free()` or
`state:close()`, the method returns the stored plain value. That value is `nil`
for a referenced type.

### `Value:free()`

Releases the guest registry reference immediately. The garbage collector also
releases the reference at collection of the proxy (`__gc`). Use `free()` to
reclaim memory early. A program that uses many guest values for a long time
benefits from this call.

`free()` is safe to call more than one time. It is also safe after
`state:close()`.

## Debug hooks and frames

### `state:setHook(fn, mask [, count])`

Installs a debug hook on the guest state. This method is the high-level
equivalent of the raw `lua_sethook`. It needs no FFI cast and no raw callback.

The bridge calls `fn` as `fn(event, info)` at each event:

- `event` is `"call"`, `"return"`, `"line"`, `"count"` or `"tailcall"`.
- `info` is a [`lua.HookInfo`](#luahookinfo) table for the event.

`mask` selects the events. Use a string with event names and spaces, or an
integer bitmask:

| Name | Bit | Constant |
|---|---|---|
| `call` | 1 | `LUA_MASKCALL` |
| `return` (or `ret`) | 2 | `LUA_MASKRET` |
| `line` | 4 | `LUA_MASKLINE` |
| `count` | 8 | `LUA_MASKCOUNT` |

```lua
state:setHook(function(event, info) end, "line")
state:setHook(function(event, info) end, "call return")
state:setHook(function(event, info) end, 4)          -- the same as "line"
state:setHook(function(event, info) end, "count", 1000)
```

`count` is the instruction interval for the `"count"` event. The default value
is `1`. A new hook replaces the old hook. The call `state:setHook(nil)` removes
the hook.

An incorrect argument gives one of these errors:

| Condition | Error |
|---|---|
| `fn` is not a function and not `nil` | `setHook: fn must be a function or nil, got <type>` |
| `mask` is not a string and not a number | `setHook: mask must be a string like "line" or an integer bitmask, got <type>` |
| `mask` contains an unknown word | `setHook: unknown hook event '<word>' (expected call, return, line, count)` |
| `mask` is an empty string | `setHook: hook mask cannot be empty` |

The hook is on the guest state, not on the host. It operates while guest code
runs, including code in a guest coroutine.

> [!NOTE]
> LuaJIT fires hooks on interpreted code only. Thus the guest JIT engine is off
> while a hook is installed, and the bridge flushes the traces. Removal of the
> hook starts the engine again. A hook decreases the speed of hot guest code.

A hook that calls `error()` stops the running guest code with that error. A
`pcall` around the call that started the guest code catches the error, and
`chunk:pcall` also catches it. Therefore, a count hook is a simple timeout
check:

```lua
state:setHook(function()
    error("timeout: guest code ran too long")
end, "count", 1000)

local ok, err = pcall(function()
    state:eval("while true do end")
end)
-- ok == false, err contains "timeout"
```

### `lua.HookInfo`

The `info` table of the hook callback. The bridge fills all debug fields at the
event, so the fields stay readable after the callback returns.

| Field | Type | Description |
|---|---|---|
| `event` | `string` | `"call"`, `"return"`, `"line"`, `"count"` or `"tailcall"`. |
| `thread` | `lightuserdata` | The `lua_State*` of the event. This is the main thread of the guest or a coroutine thread. |
| `name` | `string?` | The function name, when available. |
| `namewhat` | `string?` | The source of `name`, such as `"global"`, `"local"` or `"method"`. |
| `what` | `string?` | `"Lua"`, `"main"` or `"C"`. |
| `source` | `string?` | The source name of the chunk. |
| `short_src` | `string` | The short source name. |
| `currentline` | `integer` | The line at the hook point. The value is `-1` if the line is not known. |
| `linedefined` | `integer` | The first line of the running function. |
| `lastlinedefined` | `integer` | The last line of the running function. |
| `nups` | `integer` | The number of upvalues of the running function. |

The metatable of the table supplies the method `info.stack`. It is not a stored
field. Refer to [`info:stack()`](#infostack--luaframe).

`info.thread` is a lightuserdata with the thread pointer. Cast it to examine
that thread with the raw API. This method is necessary for the frames of a
coroutine, because `lua_getstack` requires the running thread:

```lua
local ffi = require("ffi")

state:setHook(function(event, info)
    if ffi.cast("lua_State*", info.thread) ~= state.L then
        -- the hook fired in a coroutine
    end
end, "line")
```

#### `info:stack() → lua.Frame[]`

Returns the stack trace of the thread as an array of [`lua.Frame`](#luaframe)
objects. Item `1` is level `0`, which is the frame of the hook event. The last
item is the outermost frame.

```lua
state:setHook(function(event, info)
    for i, frame in ipairs(info:stack()) do
        print(i, frame.what, frame.source, frame.currentline)
    end
end, "line")
```

> [!WARNING]
> `info:stack()` examines the thread while it is paused at the hook. Call it
> inside the callback only. A later call raises
> `info:stack() must be called from within the hook callback`. The debug fields
> stay readable after the callback. The frames become inactive as described in
> [`lua.Frame`](#luaframe).

### `lua.Frame`

One stack frame. A frame is valid while the thread is paused at the hook. A
frame has the same debug fields as `info`, but no `event` field. It has these
two more fields:

| Field | Type | Description |
|---|---|---|
| `thread` | `lightuserdata` | The `lua_State*` of this frame. |
| `level` | `integer` | The stack level. Level `0` is the frame of the hook event. |

A frame also has methods to read and write its state. A local and an upvalue
are copies that the bridge converts with the normal guest → host rules. Thus a
table local arrives as a `lua.Table` view of the live guest table.

#### `Frame:locals() → { name, value }[]`

Lists the active locals of the frame, in order. The result is an empty table if
the frame does not exist, for example after the hook returns.

#### `Frame:getLocal(name) → value`

Reads one local by name. The result is `nil` if the frame has no local with
that name.

#### `Frame:setLocal(name, value) → boolean`

Writes to an active local. The result is `true` on a success, and `false` if
the local does not exist or the frame is gone. You can write only to locals
that are active at the hook point. The running program sees the change:

```lua
state:setHook(function(event, info)
    local frame = info:stack()[1]
    if frame:getLocal("marker") then
        frame:setLocal("marker", 777)   -- the guest reads 777 afterwards
    end
end, "line")
```

#### `Frame:upvalues() → { name, value }[]`

Lists the upvalues of the running function as `{ name, value }` pairs.

#### `Frame:getUpvalue(name) → value`

Reads one upvalue of the running function. The result is `nil` if the function
has no upvalue with that name.

#### `Frame:setUpvalue(name, value) → boolean`

Writes to an upvalue of the running function. The result shows if the bridge
found the upvalue. A write to an upvalue changes the shared cell, so other
closures over that cell see the new value.

#### `Frame:eval(code) → true, any | false, err`

Evaluates `code` with the locals and the upvalues of the frame in scope. The
code runs in a new environment that contains the active locals and the
upvalues. A read of another name continues to the environment of the running
function. A write to a new name goes there also. After a success, the bridge
writes assignments to existing locals and upvalues back into the frame. Thus
`frame:eval("x = 42")` changes the running program:

```lua
state:setHook(function(event, info)
    local frame = info:stack()[1]
    if frame:getLocal("marker") then
        local ok, value = frame:eval("marker * 2")   -- reads the local
        frame:eval("marker = marker + 1")            -- writes it back
    end
end, "line")
```

The result is `true, firstResult`, or `false, err` after an error in the guest
or a syntax error. Like the other frame methods, call it inside the hook
callback only.

#### Frames after the hook returns

A frame is valid only while the thread is paused at the hook. After the hook
returns, and after the [close](#stateclose) of its state, the methods give
neutral results and do not stop the process:

| Call | Result |
|---|---|
| `frame:locals()` | `{}` |
| `frame:getLocal(name)` | `nil` |
| `frame:setLocal(name, value)` | `false` |
| `frame:upvalues()` | `{}` |
| `frame:getUpvalue(name)` | `nil` |
| `frame:setUpvalue(name, value)` | `false` |
| `frame:eval(code)` | `false, "no frame at stack level <level>"` |

## JIT control

### `state:jitOff([fn]) → state`, `state:jitOn([fn]) → state`, `state:jitFlush()`

These three methods control the JIT compiler of the guest. Without an
argument, the method switches the complete engine of the state. With a guest
callable of the same state, the method changes that function only. `jitOff` and
`jitOn` return the state, so you can add more calls. `jitFlush` returns
nothing.

```lua
state:jitOff()        -- disable the JIT for the complete guest state
state:jitOn()         -- enable it again
state:jitOff(fn)      -- disable compilation of one guest function
state:jitOn(fn)       -- enable that function again
state:jitFlush()      -- discard all compiled traces
```

An argument that is not a guest callable of this state gives
`jitOff: fn must be a guest callable obtained from this state`. The method
`jitOn` gives the same error. After [`close()`](#stateclose), each of the three
methods gives `state is closed`.

`state:setHook` disables the engine while a hook is installed and flushes the
traces at removal. These methods give direct control. For example, you can keep
the other functions of the state compiled while one function stays
interpreted.

## Profiler

```lua
local profiler = require("lua-sys.profiler")   -- also lua.profiler
```

A sampling profiler for guest states. It uses the profiler hooks of LuaJIT.

### `profiler.start(state [, mode] [, callback])`

Starts the sampling of `state`, which must be an open `lua.State`. The method
gives `profiler.start: expected an open lua.State` for `nil`, a plain table or
an already [closed](#stateclose) state. It gives
`profiler already running for this state` if the state is in the sampling mode
already.

The profiler keys its bookkeeping by the state object and not by its address.
A state that you close without `profiler.stop` therefore does not block the
next state.

- `mode` is a LuaJIT profiler mode string. The default is `"fi1"`. Use `f` for
  function-level stacks, `l` for line-level stacks, and `i<ms>` for the
  sampling interval in milliseconds.
- `callback` is optional and has the form `function(stack, samples, vmstate)`.
  The bridge calls it at each sample. `stack` is the frame list with semicolons,
  `samples` is the number of samples in this interval, and `vmstate` is a
  one-character string for the VM state from LuaJIT, for example `"N"` or
  `"I"`. A callback stops the aggregation of the samples, so
  [`stop`](#profilerstopstate--report) returns `nil`.

### `profiler.stop(state) → report`

Stops the sampling. The method returns the aggregated report, in order of
sample count from high to low. The result is `nil` if the profiler started with
a custom callback. A state without active sampling gives
`profiler not running for this state`.

The report is an array of entries with an extra field `total`:

```lua
{
    { stack = "fib;fib;fib;main", vmstate = "N", count = 150, percent = 75.0 },
    { stack = "main",             vmstate = "I", count = 50,  percent = 25.0 },
    total = 200,
}
```

| Field | Description |
|---|---|
| `stack` | The frame names with semicolons. The innermost frame is first. |
| `vmstate` | The one-character VM state of the samples in this entry. |
| `count` | The number of samples in this entry. |
| `percent` | The part of `total`, so the percentages add up to approximately 100. |
| `total` | The complete number of samples. This field is on the report, not on an entry. |

### `profiler.print(report [, out] [, min_percent])`

Writes the report to `out` as a table. The default for `out` is `io.stdout`.
The method hides entries below `min_percent`. The default is `1`.

```lua
local state = lua.new()
local work = state:load("local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end for i = 1, 300 do fib(20) end")

profiler.start(state)
work()
profiler.print(profiler.stop(state))
state:close()
```

## `lua-sys.raw`

`require("lua-sys.raw")` is a thin FFI binding of the complete Lua 5.1 and
LuaJIT C API. The module is also available as `lua.raw`. Each function takes a
`lua_State*` as the first argument. Use `state.L` for a guest, or another state
pointer. The high-level API uses this module.

```lua
local raw = require("lua-sys.raw")

local L = raw.lnewstate()
raw.openlibs(L)
raw.loadstring(L, "return 2 + 2")
raw.pcall(L, 0, 1, 0)          -- 0 == LUA_OK
print(raw.tonumber(L, -1))     -- 4
raw.close(L)
```

### Naming

| C name | `raw` name | Example |
|---|---|---|
| `lua_X` | `raw.X` | `lua_gettop` → `raw.gettop` |
| `luaL_X` | `raw.X` if the name is free | `luaL_loadstring` → `raw.loadstring`, `luaL_ref` → `raw.ref` |
| `luaL_X` | `raw.lX` if `raw.X` is in use | `luaL_newstate` → `raw.lnewstate`, because `lua_newstate` → `raw.newstate` |
| `luaopen_X` | `raw.openX` | `luaopen_string` → `raw.openString` |
| `luaJIT_X` | `raw.jit_X` | `luaJIT_setmode` → `raw.jit_setmode` |

More examples of the `raw.lX` form: `luaL_error` → `raw.lerror`,
`luaL_checkstack` → `raw.lcheckstack`, `luaL_setmetatable` →
`raw.lsetmetatable`.

### Differences from the C API

- The C API gives an integer for a status or a test. In `raw`, these results
  are Lua booleans: `raw.equal`, `raw.rawequal`, `raw.lessthan`, `raw.next`,
  `raw.checkstack`, `raw.isnumber`, `raw.isstring`, `raw.iscfunction`,
  `raw.isuserdata`, `raw.isyieldable`, `raw.getmetatable`,
  `raw.setmetatable`, `raw.getfenv`, `raw.setfenv`, `raw.pushthread`,
  `raw.callmeta` and `raw.testudata`.
- The module wraps the output parameters. `raw.tolstring(L, idx)` and
  `raw.checklstring(L, idx)` return a Lua string.
  `raw.jit_profile_dumpstack(L, fmt, depth)` copies the profiler buffer into a
  Lua string. The C buffer is valid until the next call only.
- The module has helpers for common sequences: `raw.pop(L, n)` is
  `lua_settop(L, -n-1)`, and `raw.getglobal(L, name)` is
  `lua_getfield(L, LUA_GLOBALSINDEX, name)`.
- `state.L` is a `lua_State*` cdata. Each `raw` function accepts it directly.

> [!CAUTION]
> A `raw` call into a state uses the LuaJIT FFI. The FFI is not safe for
> re-entry across independent states. A guest state that you control with
> `raw` while guest code calls back into the host can stop the trace recorder
> of LuaJIT. Use the high-level API for all traffic between the host and a
> guest. The bridge sends each transition through a `lua_CFunction`, which the
> JIT treats as an opaque boundary. Refer to [Bridge Design](bridge-design.md)
> for the full explanation.

## `lua-sys.bridge`

An internal compiled module (`bridge.so`, `.dylib` or `.dll`). Its functions
support the high-level API: `new_state`, `close_state`, `make_callable`,
`push_callback`, `register`, `unregister`, `set_hook`, `remove_hook`,
`compound_tag` and `set_frame_meta`.

These functions are not a public interface. Their signatures and their
operation can change without notice. Do not call them. Use `lua-sys.raw` when
you need a function below the high-level API.

## Rules and caveats

- **Close the state one time, at the end.** `state:close()` releases everything
  that belongs to the state, including the references in it. The guarded
  methods give `state is closed`. All other operations, such as the evaluation
  of code, table access and calls to guest functions, stop the process when the
  state is gone.
- **References, not copies.** A `lua.Table`, a `lua.Value` and a callable point
  to values in the registry of the guest state. They are valid while the state
  is valid. The garbage collector releases them.
- **A state is fully isolated.** The guest cannot see host globals or host
  modules. The host cannot see guest globals, except through the API. Two guest
  states never share values. A value of one state cannot go into the other
  state, and the bridge gives `cannot pass <type> across independent states`.
- **Some results are discarded by design.** `state:eval` and `chunk:eval`
  return the first result. `chunk:call` returns no result. Use `chunk:pcall` or
  `fn:pcall` to get all results.
- **Errors are strings.** An error in the guest becomes a plain string error on
  the host. The string is the guest message, and it can contain the guest
  position `[string "..."]:line:`. The library adds no position of its own to a
  guest error. An error that the library reports, such as an incorrect
  argument, contains the host position of the caller. Use `pcall`,
  `chunk:pcall` or `fn:pcall` to examine the error. Use `chunk:xpcall` when you
  need a guest traceback.
- **Host callbacks exchange primitives and guest tables.** An argument can be a
  primitive or a table. A table arrives as a live `lua.Table` view. A return
  value must be a primitive.
- **A hook and the JIT engine interact.** A hook needs interpreted code.
  Therefore, the installation of a hook disables the JIT engine of the guest
  until the removal of the hook.
- **Set the debug names.** Give `chunkName` to `state:load()`, or use
  `chunk:setName`. Use the prefix `@` for a file path. Then a guest stack trace
  and `debug.getinfo` give a usable name.
- **Bytecode is code.** A chunk accepts bytecode by default, and bytecode runs
  with the full power of the guest. Examine data from a source that you do not
  trust with `chunk:isBytecode()`, or refuse it with
  `chunk:setMode("text")`.
