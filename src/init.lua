local ffi               = require("ffi")
local raw               = require("lua-sys.raw")

local unpack            = table.unpack or unpack

-- Lua 5.1 / LuaJIT pseudo-indices and constants
local LUA_REGISTRYINDEX = -10000
local LUA_GLOBALSINDEX  = -10002
local LUA_NOREF         = -2
local LUA_MULTRET       = -1
local LUA_OK            = 0
local LUA_YIELD         = 1

local TYPE_NAMES        = {
	[0] = "nil",
	[1] = "boolean",
	[2] = "lightuserdata",
	[3] = "number",
	[4] = "string",
	[5] = "table",
	[6] = "function",
	[7] = "userdata",
	[8] = "thread"
}

--- Function you can pass to lua
---@alias lua.LFunction fun(...: lua.Value): ...lua.Value

-- Forward declarations (mutually recursive)
local fromLua, toLua

-- Check if a value is any lua.Value subtype (via sentinel in metatable)
local function isValue(v)
	if type(v) ~= "table" then return false end
	local mt = getmetatable(v)
	return mt ~= nil and rawget(mt, "_is_lua_value") == true
end

-- ─── Value ────────────────────────────────────────────────────────────────

---@class lua.Value
---@field _state lua.State
---@field _ref   integer   -- LUA_NOREF for primitive values
---@field _type  string
---@field _value any       -- only set for primitive Values (boolean/number/string)
local Value = { _is_lua_value = true }
Value.__index = Value

---@param state   lua.State
---@param ref     integer
---@param typename string
---@return lua.Value
function Value._ref_new(state, ref, typename)
	return setmetatable({ _state = state, _ref = ref, _type = typename }, Value)
end

---@param state   lua.State
---@param value   any
---@param typename string
---@return lua.Value
function Value._prim_new(state, value, typename)
	return setmetatable({ _state = state, _ref = LUA_NOREF, _type = typename, _value = value }, Value)
end

---@return "nil" | "boolean" | "number" | "string" | "table" | "function" | "userdata" | "thread"
function Value:type()
	return self._type
end

--- Returns the raw Lua primitive for boolean/number/string Values, or self for compound types.
---@return boolean | number | string | lua.Value
function Value:value()
	if self._ref == LUA_NOREF then
		return self._value
	end
	return self
end

--- Release the registry reference. Called automatically by __gc.
function Value:free()
	if self._ref ~= LUA_NOREF and self._state.L ~= nil then
		raw.unref(self._state.L, LUA_REGISTRYINDEX, self._ref)
	end
	self._ref = LUA_NOREF
end

Value.__gc = Value.free

function Value:__tostring()
	if self._ref == LUA_NOREF then
		return tostring(self._value)
	end

	return "lua." .. self._type
end

-- ─── Function ─────────────────────────────────────────────────────────────

---@class lua.Function: lua.Value
local Function = { _is_lua_value = true }

-- Inherit from Value.
for k, v in pairs(Value) do Function[k] = v end

Function.__index = Function
Function.__gc    = Value.free

---@param state lua.State
---@param ref   integer
---@return lua.Function
function Function._new(state, ref)
	return setmetatable({ _state = state, _ref = ref, _type = "function" }, Function)
end

--- Call the function, raising on error. Results are returned as lua.Values.
---@param ... string | number | boolean | lua.Value | function | nil
---@return lua.Value ...
function Function:call(...)
	local L    = self._state.L
	local base = raw.gettop(L)
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref)
	local n = select("#", ...)
	for i = 1, n do toLua(self._state, L, (select(i, ...))) end
	raw.call(L, n, LUA_MULTRET)
	local nresults = raw.gettop(L) - base
	local results  = {}
	for i = 1, nresults do results[i] = fromLua(self._state, L, base + i) end
	raw.settop(L, base)
	return unpack(results, 1, nresults)
end

--- Protected call. Returns false + error string on failure, true + results on success.
---@param ... string | number | boolean | lua.Value | function | nil
---@return boolean
---@return lua.Value ...
function Function:pcall(...)
	local L    = self._state.L
	local base = raw.gettop(L)
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref)
	local n = select("#", ...)
	for i = 1, n do toLua(self._state, L, (select(i, ...))) end
	local status = raw.pcall(L, n, LUA_MULTRET, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.settop(L, base)
		return false, err
	end
	local nresults = raw.gettop(L) - base
	local results  = {}
	for i = 1, nresults do results[i] = fromLua(self._state, L, base + i) end
	raw.settop(L, base)
	return true, unpack(results, 1, nresults)
end

-- ─── Table ────────────────────────────────────────────────────────────────

---@class lua.Table: lua.Value
local Table = { _is_lua_value = true }

-- Inherit from Value.
for k, v in pairs(Value) do Table[k] = v end

Table.__index = Table
Table.__gc    = Value.free

---@param state lua.State
---@param ref   integer
---@return lua.Table
function Table._new(state, ref)
	return setmetatable({ _state = state, _ref = ref, _type = "table" }, Table)
end

---@param key string | number | boolean | lua.Value
---@return lua.Value | nil
function Table:get(key)
	local L = self._state.L
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref) -- push table
	toLua(self._state, L, key)                -- push key
	raw.gettable(L, -2)                       -- pop key, push value
	local result = fromLua(self._state, L, -1)
	raw.pop(L, 2)                             -- pop value + table
	return result
end

---@param key   string | number | boolean | lua.Value
---@param value string | number | boolean | lua.Value | lua.Function | lua.Table | lua.LFunction | nil
function Table:set(key, value)
	local L = self._state.L
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref) -- push table
	toLua(self._state, L, key)                -- push key
	toLua(self._state, L, value)              -- push value
	raw.settable(L, -3)                       -- pop key + value
	raw.pop(L, 1)                             -- pop table
end

-- ─── fromLua / toLua ──────────────────────────────────────────────────────

-- Reads the Lua value at `idx` on the stack and returns it as a lua.Value.
-- Primitives (boolean/number/string) are stored by value; compound types
-- (table/function/userdata/thread) are anchored in the registry.
-- Returns nil (Lua nil) for a nil stack slot.
---@param state lua.State
---@param L     lua.raw.State
---@param idx   integer
---@return lua.Value | nil
fromLua = function(state, L, idx)
	local t = raw.type(L, idx)
	if t == 0 then return nil end

	local typename = TYPE_NAMES[t]

	-- Primitives: copy directly, no registry ref needed
	if typename == "boolean" then
		return Value._prim_new(state, raw.toboolean(L, idx), "boolean")
	elseif typename == "number" then
		return Value._prim_new(state, raw.tonumber(L, idx), "number")
	elseif typename == "string" then
		return Value._prim_new(state, raw.tolstring(L, idx), "string")
	end

	-- Compound types: push a copy and create a registry ref (luaL_ref pops it)
	raw.pushvalue(L, idx)
	local ref = raw.ref(L, LUA_REGISTRYINDEX)

	if typename == "function" then
		return Function._new(state, ref)
	elseif typename == "table" then
		return Table._new(state, ref)
	else
		return Value._ref_new(state, ref, typename)
	end
end

-- Pushes `value` onto the Lua stack.
-- Accepts plain Lua primitives, lua.Value subtypes (pushed via their registry ref),
-- or plain Lua functions (wrapped as lua_CFunctions via ffi.cast).
---@param state lua.State
---@param L     lua.raw.State
---@param value string | number | boolean | lua.Value | function | nil
toLua = function(state, L, value)
	local t = type(value)

	if t == "nil" then
		raw.pushnil(L)
	elseif t == "boolean" then
		raw.pushboolean(L, value and 1 or 0)
	elseif t == "number" then
		raw.pushnumber(L, value)
	elseif t == "string" then
		raw.pushlstring(L, value, #value)
	elseif t == "table" and isValue(value) then
		-- lua.Value: push from registry ref for compound types, or push primitive directly
		if value._ref ~= LUA_NOREF then
			raw.rawgeti(L, LUA_REGISTRYINDEX, value._ref)
		elseif value._type == "number" then
			raw.pushnumber(L, value._value)
		elseif value._type == "string" then
			raw.pushlstring(L, value._value, #value._value)
		elseif value._type == "boolean" then
			raw.pushboolean(L, value._value and 1 or 0)
		else
			raw.pushnil(L)
		end
	elseif t == "function" then
		local nparams = debug.getinfo(value, "u").nparams

		-- Specialize on number of params known ahead of time.
		local cb
		if nparams == 0 then
			cb = ffi.cast("lua_CFunction", function(L_raw)
				raw.pop(L_raw, raw.gettop(L_raw))

				local rets = { value() }
				local nrets = #rets
				for i = 1, nrets do
					toLua(state, L_raw, rets[i])
				end

				return nrets == 0 and 0 or -1
			end)
		elseif nparams == 1 then
			cb = ffi.cast("lua_CFunction", function(L_raw)
				local arg1 = fromLua(state, L_raw, 1)
				raw.pop(L_raw, raw.gettop(L_raw))

				local rets = { value(arg1) }
				local nrets = #rets
				for i = 1, nrets do
					toLua(state, L_raw, rets[i])
				end

				return nrets == 0 and 0 or -1
			end)
		elseif nparams == 2 then
			cb = ffi.cast("lua_CFunction", function(L_raw)
				local arg1 = fromLua(state, L_raw, 1)
				local arg2 = fromLua(state, L_raw, 2)
				raw.pop(L_raw, raw.gettop(L_raw))

				local rets = { value(arg1, arg2) }
				local nrets = #rets
				for i = 1, nrets do
					toLua(state, L_raw, rets[i])
				end

				return nrets == 0 and 0 or -1
			end)
		elseif nparams == 3 then
			cb = ffi.cast("lua_CFunction", function(L_raw)
				local arg1 = fromLua(state, L_raw, 1)
				local arg2 = fromLua(state, L_raw, 2)
				local arg3 = fromLua(state, L_raw, 3)
				raw.pop(L_raw, raw.gettop(L_raw))

				local rets = { value(arg1, arg2, arg3) }
				local nrets = #rets
				for i = 1, nrets do
					toLua(state, L_raw, rets[i])
				end

				return nrets == 0 and 0 or -1
			end)
		elseif nparams == 4 then
			cb = ffi.cast("lua_CFunction", function(L_raw)
				local arg1 = fromLua(state, L_raw, 1)
				local arg2 = fromLua(state, L_raw, 2)
				local arg3 = fromLua(state, L_raw, 3)
				local arg4 = fromLua(state, L_raw, 4)
				raw.pop(L_raw, raw.gettop(L_raw))

				local rets = { value(arg1, arg2, arg3, arg4) }
				local nrets = #rets
				for i = 1, nrets do
					toLua(state, L_raw, rets[i])
				end

				return nrets == 0 and 0 or -1
			end)
		else
			cb = ffi.cast("lua_CFunction", function(L_raw)
				local n = raw.gettop(L_raw)

				local args = {}
				for i = 1, n do
					args[i] = fromLua(state, L_raw, i)
				end

				raw.pop(L_raw, n)

				local rets = { value(unpack(args, 1, n)) }
				local nrets = #rets
				for i = 1, nrets do
					toLua(state, L_raw, rets[i])
				end

				return nrets == 0 and 0 or -1
			end)
		end

		table.insert(state._callbacks, cb)
		raw.pushcclosure(L, cb, 0)
	else
		error("cannot coerce value of type '" .. t .. "' to a Lua value", 2)
	end
end

-- ─── State ────────────────────────────────────────────────────────────────

---@class lua.State
---@field L               lua.raw.State
---@field _callbacks      table  -- keeps ffi cdata callbacks alive
---@field _lua_callbacks  table  -- outer-state Lua functions registered as callbacks
local State = {}
State.__index = State

--- Compile and evaluate a Lua chunk, returning the first result as a lua.Value.
--- As a convenience, a bare expression (e.g. `"function(a,b) end"`) is
--- automatically wrapped with `return` so it evaluates to a value.
---@param code string
---@return lua.Function | lua.Table | lua.Value | nil
function State:load(code)
	local L = self.L
	-- Try loading as an expression first; fall back to a plain chunk
	local status = raw.loadstring(L, "return " .. code)
	if status ~= LUA_OK then
		raw.pop(L, 1)
		status = raw.loadstring(L, code)
	end
	if status ~= LUA_OK then
		local err = raw.tolstring(L, -1)
		raw.pop(L, 1)
		error(err, 2)
	end
	local base = raw.gettop(L) - 1
	status = raw.pcall(L, 0, LUA_MULTRET, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.pop(L, 1)
		error(err, 2)
	end
	local nresults = raw.gettop(L) - base
	if nresults == 0 then return nil end
	local result = fromLua(self, L, base + 1)
	raw.settop(L, base)
	return result
end

--- Returns a lua.Table wrapping the global environment (_G).
---@return lua.Table
function State:globals()
	local L = self.L
	raw.pushvalue(L, LUA_GLOBALSINDEX)
	local tbl = fromLua(self, L, -1)
	raw.pop(L, 1)
	return tbl
end

--- Close the underlying Lua state and release all resources.
function State:close()
	if self.L then
		raw.close(self.L)
		self.L              = nil
		self._callbacks     = {}
		self._lua_callbacks = {}
	end
end

-- ─── Module ───────────────────────────────────────────────────────────────

---@class lua
local lua = {}

lua.raw = raw

--- Create a new Lua state with all standard libraries loaded.
---@return lua.State
function lua.new()
	local L = raw.lnewstate()
	raw.openlibs(L)
	return setmetatable({ L = L, _callbacks = {}, _lua_callbacks = {} }, State)
end

-- Disable JIT on functions that call into the inner Lua state so that
-- FFI callbacks can safely re-enter the outer (lde) interpreter.
jit.off(Function.call, true)
jit.off(Function.pcall, true)
jit.off(State.load, true)

return lua
