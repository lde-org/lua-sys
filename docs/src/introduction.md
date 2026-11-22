# Introduction

This is the documentation for lua-sys, the Lua C API bindings and multi-runtime
host for lde. One high-level API drives guest states on LuaJIT, Lua 5.1,
Lua 5.4 and Luau.

## Installation

First, set up [lde](https://lde.sh).

> [!NOTE]
> If you are unsure, please consult lde's documentation on adding dependencies and usage of lde.

```bash
lde add lua-sys
```

## Example

Here's a basic example to run some lua code.

```lua
local lua = require("lua-sys")

local jit = lua:lde()                 -- the LuaJIT lua-sys ships with
print(jit.version.string)                  -- LuaJIT 2.1.x
print(jit.abi, jit.caps.jit)               -- jit	true

local state = jit:new()
print(state:eval("return 1 + 2"))          -- 3
state:close()
```

`lua:lde()` is the LuaJIT that lde itself links. `lua:bundled(version)` is the
runtime built by the `bundled` source feature, `lua:vendored(version)` is a
matching runtime the host process already loaded (or nil), and
`lua:open(path)` loads one from a shared library. The same high-level API works
on all of them; the capabilities in `runtime.caps` are what differ.

```lua
local lua = require("lua-sys")

local lua54 = lua:open("/usr/lib64/liblua-5.4.so")
print(lua54.version.string)                -- Lua 5.4.x
print(lua54.caps.integers)                 -- true
print(lua54:new():eval("return 2^53 + 1")) -- exact integer
```

## Next Steps

Look on the sidebar for guides for using different parts of lua-sys!
