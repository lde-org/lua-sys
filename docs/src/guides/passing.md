# Passing A Function to Lua

You can give *host* functions to the guest state. Guest code can call them.

```lua
local lua = require("lua-sys")

local state = lua.new()

state:globals().adder = function(a, b)
	print("Called by guest!")
	return a + b
end

print(state:eval("return adder(5, 5)")) -- 10
```

The bridge converts the arguments for the basic types: numbers, strings and
booleans. Refer to [How values cross the
boundary](../reference.md#how-values-cross-the-boundary).

A guest function that the host receives becomes a normal host function. This
event occurs when a guest function is a result of a call, or a value in a guest
table:

```lua
local double = state:eval("return function(x) return x * 2 end")
print(double(21))  -- 42
```

A guest function as an *argument* of a host callback is different. An argument
of the type function, userdata or thread gives this error:

```
bridge: cannot pass function across independent states
```

Put the value in a guest table and pass the table instead.

## Tables

A table is different from a function. The bridge does not copy a table into a
host value, for three reasons:

1. A table can change at any time. Fields can come and go.
2. Because of reason 1, a copy is not correct.
3. A copy is slow.

Therefore, the host keeps a table as a reference and reads fields as necessary.

The call `state:globals()` shows this design. It returns a `lua.Table` for the
guest global table. The assignment `state:globals().adder = ...` above uses
that proxy.

To identify a `lua.Table`, use `type(x) == "table"`. A guest table always
arrives as a `lua.Table`, never as a plain host table.

> [!TIP]
> For more information, refer to the [API Reference](../reference.md).
