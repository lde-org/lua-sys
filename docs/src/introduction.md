# Introduction

This is the documentation for using the lua-sys library for LuaJIT.

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

local state = lua.new()
print(state:eval("return 1 + 2")) -- 3
```

## Next Steps

Look on the sidebar for guides for using different parts of lua-sys!
