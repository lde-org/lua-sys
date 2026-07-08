local ffi               = require("ffi")
local raw               = require("lua-sys.raw")
local bridge            = require("lua-sys.bridge")

local unpack            = table.unpack or unpack

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

-- forward declarations: fromLua, toLua and makeCallable are mutually recursive
local fromLua, toLua, makeCallable

local function isGuestValue(v)
	if type(v) ~= "table" then return false end
	local mt = getmetatable(v)
	return mt ~= nil and rawget(mt, "_is_lua_value") == true
end

-- ─── Value ────────────────────────────────────────────────────────────────

---@class lua.Value
---@field _state lua.State
---@field _ref   integer
---@field _type  string
---@field _value any
local Value = { _is_lua_value = true }
Value.__index = Value

---@param state    lua.State
---@param ref      integer
---@param typename string
function Value._ref_new(state, ref, typename)
	return setmetatable({ _state = state, _ref = ref, _type = typename }, Value)
end

---@return "nil"|"boolean"|"number"|"string"|"table"|"function"|"userdata"|"thread"
function Value:type()
	return self._type
end

---@return boolean|number|string|lua.Value
function Value:value()
	if self._ref == LUA_NOREF then return self._value end
	return self
end

function Value:free()
	if self._ref ~= LUA_NOREF and self._state.L ~= nil then
		raw.unref(self._state.L, LUA_REGISTRYINDEX, self._ref)
	end
	self._ref = LUA_NOREF
end

Value.__gc       = Value.free
Value.__tostring = function(self)
	if self._ref == LUA_NOREF then return tostring(self._value) end
	return "lua." .. self._type
end

-- ─── Table ────────────────────────────────────────────────────────────────

---@class lua.Table: lua.Value
local Table      = { _is_lua_value = true }
for k, v in pairs(Value) do Table[k] = v end
Table.__index = Table
Table.__gc    = Value.free

---@param state lua.State
---@param ref   integer
function Table._new(state, ref)
	return setmetatable({ _state = state, _ref = ref, _type = "table" }, Table)
end

---@param key string|number|boolean|lua.Value
function Table:get(key)
	local guestState = self._state
	local L          = guestState.L
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref)
	toLua(guestState, L, key)
	raw.gettable(L, -2)
	local result = fromLua(guestState, L, -1)
	raw.pop(L, 2)
	return result
end

---@param key   string|number|boolean|lua.Value
function Table:set(key, value)
	local guestState = self._state
	local L          = guestState.L
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref)
	toLua(guestState, L, key)
	toLua(guestState, L, value)
	raw.settable(L, -3)
	raw.pop(L, 1)
end

-- Iterate all key/value pairs (equivalent to pairs() on a plain table).
-- Usage: for k, v in t:pairs() do ... end
function Table:pairs()
	local guestState = self._state
	local L          = guestState.L
	local key_ref    = nil                     -- registry ref for the current iteration key
	return function()
		raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref) -- push table
		if key_ref ~= nil then
			raw.rawgeti(L, LUA_REGISTRYINDEX, key_ref)
			raw.unref(L, LUA_REGISTRYINDEX, key_ref)
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
		local v = fromLua(guestState, L, -1)
		local k = fromLua(guestState, L, -2)
		-- save the key for the next lua_next call before popping
		raw.pushvalue(L, -2)
		key_ref = raw.ref(L, LUA_REGISTRYINDEX)
		raw.pop(L, 3) -- pop value, key, table
		return k, v
	end
end

-- Iterate integer keys 1..# (equivalent to ipairs() on a plain table).
-- Usage: for i, v in t:ipairs() do ... end
function Table:ipairs()
	local guestState = self._state
	local L          = guestState.L
	local i          = 0
	return function()
		i = i + 1
		raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref)
		raw.rawgeti(L, -1, i)
		if raw.type(L, -1) == 0 then -- nil — end of sequence
			raw.pop(L, 2)
			return nil
		end
		local v = fromLua(guestState, L, -1)
		raw.pop(L, 2)
		return i, v
	end
end

-- Proxy field reads to Table:get() for unknown keys (methods take priority).
Table.__index = function(self, key)
	local method = rawget(Table, key)
	if method ~= nil then return method end
	return Table.get(self, key)
end

-- Proxy field writes to Table:set().
Table.__newindex = function(self, key, value)
	Table.set(self, key, value)
end

-- ─── fromLua / toLua ──────────────────────────────────────────────────────

---@param guestState lua.State
---@param L          lua.raw.State
---@param stackIndex integer
fromLua = function(guestState, L, stackIndex)
	local typeId = raw.type(L, stackIndex)
	if typeId == 0 then return nil end

	local typename = TYPE_NAMES[typeId]
	if typename == "boolean" then return raw.toboolean(L, stackIndex) end
	if typename == "number" then return raw.tonumber(L, stackIndex) end
	if typename == "string" then return raw.tolstring(L, stackIndex) end

	raw.pushvalue(L, stackIndex)
	local ref = raw.ref(L, LUA_REGISTRYINDEX)

	if typename == "function" then
		return makeCallable(guestState, ref)
	elseif typename == "table" then
		return Table._new(guestState, ref)
	else
		return Value._ref_new(guestState, ref, typename)
	end
end

---@param guestState lua.State
---@param L          lua.raw.State
---@param value      string|number|boolean|table|lua.Value|function|nil
toLua = function(guestState, L, value)
	local valueType = type(value)

	if valueType == "nil" then
		raw.pushnil(L)
	elseif valueType == "boolean" then
		raw.pushboolean(L, value and 1 or 0)
	elseif valueType == "number" then
		raw.pushnumber(L, value)
	elseif valueType == "string" then
		raw.pushlstring(L, value, #value)
	elseif valueType == "table" and isGuestValue(value) then
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
	elseif valueType == "function" then
		if guestState._guest_fns and guestState._guest_fns[value] then
			-- value is a makeCallable closure — push its guest ref directly
			raw.rawgeti(L, LUA_REGISTRYINDEX, guestState._guest_fns[value])
		else
			-- value is a plain host function; register it as a C closure on the
			-- guest state. bridge.push_callback does this entirely in C to avoid
			-- triggering LuaJIT's FFI re-entrancy crash (see docs/bridge-design.md).
			local callbackId = bridge.register(value)
			table.insert(guestState._callbacks, { id = callbackId, fn = value })
			bridge.push_callback(tonumber(ffi.cast("intptr_t", L)), callbackId)
		end
	elseif valueType == "table" then
		-- Plain host table → auto-coerce to a guest table via state:table().
		-- state:table() creates the table, populates it recursively (which
		-- re-enters toLua for nested tables/functions), and returns a
		-- lua.Table wrapper. Push the underlying guest table onto the stack.
		local t = guestState:table(value)
		raw.rawgeti(L, LUA_REGISTRYINDEX, t._ref)
	else
		error("cannot push value of type '" .. valueType .. "' onto guest stack", 2)
	end
end

-- ─── makeCallable ─────────────────────────────────────────────────────────

-- Slow path for cross-state calls when results include compound types
-- (tables, functions, userdata). Called from C via bound_call upvalue 4
-- when bound_call detects a non-primitive result.
---@param guestState lua.State
---@param guestRef   integer
local function callGuestSlow(guestState, guestRef, ...)
	local L     = guestState.L
	local nargs = select("#", ...)
	local base  = raw.gettop(L)
	raw.rawgeti(L, LUA_REGISTRYINDEX, guestRef)
	for i = 1, nargs do toLua(guestState, L, (select(i, ...))) end
	local status = raw.pcall(L, nargs, LUA_MULTRET, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1); raw.settop(L, base); error(err, 0)
	end
	local nresults = raw.gettop(L) - base
	if nresults == 0 then
		raw.settop(L, base); return
	end
	if nresults == 1 then
		local result = fromLua(guestState, L, base + 1)
		raw.settop(L, base)
		return result
	end
	local results = {}
	for i = 1, nresults do results[i] = fromLua(guestState, L, base + i) end
	raw.settop(L, base)
	return unpack(results, 1, nresults)
end

-- Registry ref for callGuestSlow, stored once and baked into every bound_call
-- closure as upvalue 4. Allows C to invoke the slow path without a Lua wrapper.
local callGuestSlowRef = bridge.register(callGuestSlow)

-- Returns a host-callable function backed by a guest registry ref.
--
-- bound_call is returned directly as the callable — no Lua wrapper.
-- Every host↔guest transition goes through a lua_CFunction boundary,
-- which is required to avoid LuaJIT's FFI re-entrancy crash.
-- See docs/bridge-design.md.
--
-- When bound_call detects a compound result it calls callGuestSlow directly
-- from C via upvalue 4, so no Lua wrapper or COMPOUND_TAG check is needed.
---@param guestState lua.State
---@param guestRef   integer
makeCallable = function(guestState, guestRef)
	if not guestState._guest_L_ptr then
		guestState._guest_L_ptr = tonumber(ffi.cast("intptr_t", guestState.L))
	end

	local boundCFn = bridge.make_callable(
		guestState._guest_L_ptr, guestRef, guestState, callGuestSlowRef)

	guestState._guest_fns = guestState._guest_fns or {}
	guestState._guest_fns[boundCFn] = guestRef
	return boundCFn
end

-- ─── Chunk ────────────────────────────────────────────────────────────────

---@class lua.Chunk
---@field _state     lua.State
---@field _code      string
---@field _chunkName string?
local Chunk = {}
Chunk.__index = Chunk

---@param state lua.State
---@param code  string
---@param name  string?
function Chunk._new(state, code, name)
	return setmetatable({ _state = state, _code = code, _chunkName = name }, Chunk)
end

--- Set the chunk name (for debug info). Returns self for chaining.
---
--- Prefix with "@" for a file path (e.g. "@/path/to/file.lua") so that
--- debug.getinfo(1,"S").source returns the correct path inside the guest.
---@param name string
---@return lua.Chunk
function Chunk:setName(name)
	self._chunkName = name
	return self
end

-- Internal: compile the chunk and push the function onto the guest stack.
-- Leaves the compiled function at the top of the guest stack on success.
-- Returns the stack base (the index of the function) so the caller can
-- protect-call it.
---@return lua.raw.State L
---@return integer       fnIndex
function Chunk:_compile()
	local L        = self._state.L
	local code     = self._code
	local name     = self._chunkName
	local retChunk = "return " .. code

	local status
	if name then
		status = raw.loadbuffer(L, retChunk, #retChunk, name)
	else
		status = raw.loadstring(L, retChunk)
	end
	if status ~= LUA_OK then
		raw.pop(L, 1)
		if name then
			status = raw.loadbuffer(L, code, #code, name)
		else
			status = raw.loadstring(L, code)
		end
	end
	if status ~= LUA_OK then
		local err = raw.tolstring(L, -1); raw.pop(L, 1); error(err, 2)
	end
	return L, raw.gettop(L)
end

--- Compile and evaluate the chunk with the given arguments (accessible
--- as `...` inside the guest), returning the first result.
---
--- If no value is returned by the chunk, returns nil.
---@param ... any
function Chunk:eval(...)
	local L, fnIndex = self:_compile()
	local nargs = select("#", ...)
	local state = self._state
	for i = 1, nargs do toLua(state, L, (select(i, ...))) end
	local base = fnIndex - 1
	local status = raw.pcall(L, nargs, LUA_MULTRET, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1); raw.settop(L, base); error(err, 2)
	end
	local nresults = raw.gettop(L) - base
	if nresults == 0 then
		raw.settop(L, base)
		return nil
	end
	local result = fromLua(state, L, base + 1)
	raw.settop(L, base)
	return result
end

-- Allow calling chunk as shorthand
Chunk.__call = Chunk.eval

--- Compile and execute the chunk with the given arguments, discarding
--- any return values.
---@param ... any
function Chunk:call(...)
	local L, fnIndex = self:_compile()
	local nargs = select("#", ...)
	local state = self._state
	for i = 1, nargs do toLua(state, L, (select(i, ...))) end
	local base = fnIndex - 1
	local status = raw.pcall(L, nargs, 0, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1); raw.settop(L, base); error(err, 2)
	end
	raw.settop(L, base)
end

-- ─── State ────────────────────────────────────────────────────────────────

---@class lua.State
---@field L            lua.raw.State
---@field _callbacks   table
---@field _guest_L_ptr number?
---@field _guest_fns   table?
local State = {}
State.__index = State

--- Load a Lua chunk as a builder that can be configured before
--- execution. Call :eval() or :call() on the returned Chunk to run it.
---
---@param chunk     string
---@param chunkName string?
---@return lua.Chunk
function State:load(chunk, chunkName)
	return Chunk._new(self, chunk, chunkName)
end

--- Compile and evaluate a Lua chunk immediately. Equivalent to
--- `state:load(code, chunkName):eval(...)`.
---
--- A bare expression is automatically wrapped in `return` so it
--- produces a value.
---
--- chunkName follows the LuaJIT convention: prefix with "@" for a
--- file path so that debug.getinfo(1,"S").source returns the correct
--- path inside the guest.
---@param code      string
---@param chunkName string?
function State:eval(code, chunkName)
	return self:load(code, chunkName):eval()
end

---@return lua.Table
function State:globals()
	local L = self.L
	raw.pushvalue(L, LUA_GLOBALSINDEX)
	local globals = fromLua(self, L, -1)
	raw.pop(L, 1)
	return globals
end

--- Create a new empty guest table and return it as a lua.Table.
---
--- If `init` is provided it must be a plain host table. Keys and values
--- are set via tbl:set(k, v) which delegates to toLua for conversion:
---   • string / number / boolean  → copied directly
---   • nested plain table         → auto-coerced via state:table()
---   • lua.Value (guest ref)      → stored as-is
---   • function                   → registered as a host callback (CFunction)
---   • anything else              → error
---
---@param init table?
---@return lua.Table
function State:table(init)
	local L = self.L
	raw.createtable(L, 0, init and 16 or 0)
	local ref = raw.ref(L, LUA_REGISTRYINDEX)
	local tbl = Table._new(self, ref)

	if init ~= nil then
		if type(init) ~= "table" then
			error("state:table() init argument must be a table, got " .. type(init), 2)
		end
		-- Cycle detection: the seen set lives on the State so it persists
		-- across recursive state:table() calls triggered by toLua coercion.
		-- The top-level call wraps v in pcall to guarantee cleanup on error.
		local seen = self._table_seen
		local topLevel = (seen == nil)
		if topLevel then
			self._table_seen = {}
			seen = self._table_seen
		end
		local function populate()
			if seen[init] then
				error("state:table(): cycle detected in init table", 0)
			end
			seen[init] = true
			for k, v in pairs(init) do
				local kt = type(k)
				if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then
					error("state:table(): unsupported key type '" .. kt .. "'", 0)
				end
				tbl:set(k, v)
			end
			seen[init] = nil -- done with this table; same table appearing as
			-- a sibling value (not a back-edge) is fine
		end
		if topLevel then
			local ok, err = pcall(populate)
			self._table_seen = nil
			if not ok then error(err, 2) end
		else
			populate()
		end
	end

	return tbl
end

function State:close()
	if self.L then
		for _, cb in ipairs(self._callbacks) do bridge.unregister(cb.id) end
		raw.close(self.L)
		self.L          = nil
		self._callbacks = {}
	end
end

-- ─── Module ───────────────────────────────────────────────────────────────

---@class lua
local lua    = {}

lua.raw      = raw
lua.profiler = require("lua-sys.profiler")

---@return lua.State
function lua.new()
	local L = raw.lnewstate()
	raw.openlibs(L)
	return setmetatable({ L = L, _callbacks = {} }, State)
end

return lua
