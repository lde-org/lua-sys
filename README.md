# lua-sys

Lua C API bindings and a multi-runtime host for [lde](https://lde.sh): guest
states on LuaJIT, Lua 5.1, Lua 5.4 and Luau, behind one high-level API.

## Install

```
lde add lua-sys
```

`lde add` pre-fills the `default` feature list of lua-sys: `lde`, `luajit` and
`high`. A plain `lde add lua-sys` therefore gets lde's LuaJIT and the
high-level API. A build picks one version (`luajit`, `lua51`, `lua54` or
`luau`) and one source (`lde`, `bundled` or the host's `vendored` runtime).

## Quick start

```lua
local lua = require("lua-sys")

local rt = lua:lde()                           -- lde's own LuaJIT
local state = rt:new()                         -- make a guest state
print(state:eval("return 1 + 2"))              -- 3

local add = state:load("return function(a, b) return a + b end"):eval()
print(add(1, 2))                               -- 3

local g = state:globals()                      -- the guest global table
g.config = { timeout = 5, retries = 3 }        -- a host table becomes a guest table
g.log = function(text) print("[guest] " .. text) end

state:load("log('timeout is ' .. config.timeout)"):call()   -- [guest] timeout is 5

state:close()                                  -- release the state
```

## Runtimes

`require("lua-sys")` returns four entry points:

| Call | Result |
|---|---|
| `lua:lde()` | The LuaJIT that lde itself links. Never nil; raises when `lde` is off. |
| `lua:bundled(version)` | The runtime built by `bundled` (`lua-sys.bundled`). Never nil; raises when `bundled` is off or `version` is not the built one. |
| `lua:vendored(version)` | A runtime of that version already loaded in the process, or `nil`. Never loads one. |
| `lua:open(path)` | A `Lua` for the library at `path` (`dlopen`/`LoadLibrary`). Raises when it is no supported Lua. |

`version` is `"luajit"`, `"lua51"`, `"lua54"` or `"luau"`; anything else raises.
Handles are cached per (image, ABI): the same runtime returns the same
`lua.Lua`. Each handle reports what it is:

```lua
local lua = require("lua-sys")

local rt = lua:open("/usr/lib64/liblua-5.4.so")
print(rt.abi)              -- "5.4"
print(rt.version.name)     -- "Lua"
print(rt.version.string)   -- "Lua 5.4.8"
print(rt.version.release)  -- "5.4.8"
print(rt.caps.integers)    -- true
print(rt.caps.env)         -- "_ENV"
print(rt.raw)              -- the C API of this runtime

local state = rt:new()     -- lua.State; close() frees it
local wrapped = rt:wrap(L) -- around an existing lua_State* of this runtime
```

Version detection never runs guest code: LuaJIT reports through a temporary
state, Lua 5.1 and 5.4 through `lua_ident`, Luau by name. Capabilities are
`jit`, `hooks` (`"full"` or `"line"`), `env` (`"fenv"` or `"_ENV"`),
`integers` and `source`. Methods whose capability is off raise
`<method>: not supported by <version>`.

## Features

One runtime per build: exactly one version feature and at most one source
feature. Modules no feature claims are always bundled.

| Feature | Kind | Claims | Function |
|---|---|---|---|
| `luajit` | version | `lua-sys.abi.lua51`, `lua-sys.abi.jit`, `lua-sys.profiler` | LuaJIT bindings, JIT control, profiler. |
| `lua51` | version | `lua-sys.abi.lua51` | Lua 5.1 bindings. |
| `lua54` | version | `lua-sys.abi.lua54` | Lua 5.4 bindings. |
| `luau` | version | `lua-sys.abi.luau` | Luau bindings. |
| `lde` | source | `lua-sys.embedded.lde`, the LuaJIT bindings | The LuaJIT lde itself links. Implies `luajit`. |
| `bundled` | source | `lua-sys.embedded.bundled`, `lua-sys.bundled` | build.lua builds the chosen version as `lua-sys.bundled`. |
| `vendored` | source | none | The host process provides the runtime. A build-script flag only. |
| `high` | add-on | `lua-sys.high`, `lua-sys.high.*`, `lua-sys.bridge` | High-level API and the C bridge. |

The manifest declares `"default": ["lde", "luajit", "high"]`. Only `lde add`
reads that list; it enables those features on the new dependency. `vendored`
claims no modules, so it is not declared: a dependent can still request it and
`build.lua` sees it through `build:feature("vendored")`.

The lde LuaJIT keeps today's path: the `luajit` binding declares the real
`lua_*` names and binds through the running image's own namespace, so the raw
functions are the same direct cdata calls. The Lua 5.4 and Luau bindings use
prefixed types and cast addresses, so a process can host several Lua ABIs at
once.

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
