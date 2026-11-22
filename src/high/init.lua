-- high/init.lua — the high-level API of lua-sys.
--
-- `require("lua-sys.high")` returns `{ new, wrap }`; the classes live in the
-- sibling modules. This file wires them together once, so the per-call
-- methods hold direct function references instead of module lookups.

local value = require("lua-sys.high.value")
local convert = require("lua-sys.high.convert")
local chunk = require("lua-sys.high.chunk")
require("lua-sys.high.frame") -- installs the frame metatable on the bridge
local state = require("lua-sys.high.state")

value.bind(convert.fromLua, convert.toLua)
convert.bind(value)
chunk.bind(convert.toLua, convert.fromLua, convert.closedError)

---@class lua.HighModule
---@field new fun(rt: lua.Lua): lua.State
---@field wrap fun(rt: lua.Lua, L: any): lua.State

return { new = state.new, wrap = state.wrap }
