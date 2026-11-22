-- high/value.lua — guest value and table proxies.
--
-- A lua.Value is a registry reference to a guest value; a lua.Table is a live
-- view of a guest table. Both keep the lua.State that owns the reference, so
-- a proxy is invalid after its state closes. The conversion functions come
-- from high/convert.lua through `bind`, so the methods make no per-call
-- require or table lookup for them.

local LUA_NOREF = -2

local fromLua, toLua

local value = {}

---@class lua.Callable: function
---@field pcall fun(self: lua.ValueType, ...: any): boolean, lua.ValueType
---@operator call(...: any): lua.ValueType

--- A value that crosses from the guest: any primitive, a table proxy, a
--- reference to a userdata/thread, or a callable guest function.
---@alias lua.ValueType lua.Table|lua.Value|lua.Callable|function|number|string|boolean|nil

---@class lua.Value
---@field _state lua.State
---@field _ref integer
---@field _type string
local Value = { _is_lua_value = true }
Value.__index = Value

---@param state    lua.State
---@param ref      integer
---@param typename string
---@return lua.Value
function Value._ref_new(state, ref, typename)
	return setmetatable({ _state = state, _ref = ref, _type = typename }, Value)
end

---@return "nil"|"boolean"|"number"|"string"|"table"|"function"|"userdata"|"lightuserdata"|"thread"|"cdata"|"vector"|"buffer"
function Value:type()
	return self._type
end

---@return lua.Value?
function Value:value()
	if self._ref == LUA_NOREF then return nil end
	return self
end

function Value:free()
	local state = self._state
	local L = state.L
	if self._ref ~= LUA_NOREF and L ~= nil then
		state._raw.unref(L, state._registryIndex, self._ref)
	end
	self._ref = LUA_NOREF
end

Value.__gc = Value.free

---@param self lua.Value
Value.__tostring = function(self)
	if self._ref == LUA_NOREF then return "nil" end
	return "lua." .. self._type
end

---@class lua.Table: lua.Value
---@field [string] any
local Table = { _is_lua_value = true }
for k, v in pairs(Value) do Table[k] = v end
Table.__gc = Value.free

---@param state lua.State
---@param ref   integer
---@return lua.Table
function Table._new(state, ref)
	return setmetatable({ _state = state, _ref = ref, _type = "table" }, Table)
end

---@param key any
---@return lua.ValueType
function Table:get(key)
	local state = self._state
	local L = state.L
	if L == nil then error("state is closed", 3) end
	local raw = state._raw
	raw.rawgeti(L, state._registryIndex, self._ref)
	toLua(state, L, key)
	raw.gettable(L, -2)
	local result = fromLua(state, L, -1)
	raw.pop(L, 2)
	return result
end

---@param key   any
---@param value any
function Table:set(key, value)
	local state = self._state
	local L = state.L
	if L == nil then error("state is closed", 3) end
	local raw = state._raw
	raw.rawgeti(L, state._registryIndex, self._ref)
	toLua(state, L, key)
	toLua(state, L, value)
	raw.settable(L, -3)
	raw.pop(L, 1)
end

-- Iterate all key/value pairs (equivalent to pairs() on a plain table).
-- Usage: for k, v in t:pairs() do ... end
---@return fun(): any, any
function Table:pairs()
	local state = self._state
	if state.L == nil then error("state is closed", 3) end
	local key_ref = nil -- registry ref for the current iteration key
	return function()
		local L = state.L
		if L == nil then error("state is closed", 3) end
		local raw = state._raw
		local registry = state._registryIndex
		raw.rawgeti(L, registry, self._ref) -- push table
		if key_ref ~= nil then
			raw.rawgeti(L, registry, key_ref)
			raw.unref(L, registry, key_ref)
			key_ref = nil
		else
			raw.pushnil(L) -- initial key
		end
		local more = raw.next(L, -2)
		if not more then
			raw.pop(L, 1) -- pop table
			return nil
		end
		-- stack: table, next-key, value
		local v = fromLua(state, L, -1)
		local k = fromLua(state, L, -2)
		-- save the key for the next lua_next call before popping
		raw.pushvalue(L, -2)
		key_ref = raw.ref(L, registry)
		raw.pop(L, 3) -- pop value, key, table
		return k, v
	end
end

-- Iterate integer keys 1..# (equivalent to ipairs() on a plain table).
-- Usage: for i, v in t:ipairs() do ... end
---@return fun(): integer?, any
function Table:ipairs()
	local state = self._state
	if state.L == nil then error("state is closed", 3) end
	local i = 0
	return function()
		local L = state.L
		if L == nil then error("state is closed", 3) end
		local raw = state._raw
		i = i + 1
		raw.rawgeti(L, state._registryIndex, self._ref)
		raw.rawgeti(L, -1, i)
		if state._typeNames[raw.type(L, -1)] == "nil" then
			-- nil: end of sequence
			raw.pop(L, 2)
			return nil
		end
		local v = fromLua(state, L, -1)
		raw.pop(L, 2)
		return i, v
	end
end

-- Proxy field reads to Table:get() for unknown keys (methods take priority).
---@param self lua.Table
---@param key string
Table.__index = function(self, key)
	local method = rawget(Table, key)
	if method ~= nil then return method end
	return Table.get(self, key)
end

-- Proxy field writes to Table:set().
---@param self lua.Table
---@param key string
Table.__newindex = function(self, key, value)
	Table.set(self, key, value)
end

---@param from fun(state: lua.State, L: any, index: integer): lua.ValueType
---@param to   fun(state: lua.State, L: any, value: any)
function value.bind(from, to)
	fromLua = from
	toLua = to
end

value.Value = Value
value.Table = Table

return value
