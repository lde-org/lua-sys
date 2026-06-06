local ffi = require("ffi")
local raw = require("lua-sys.raw")

local unpack = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

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

-- Run a coroutine, dispatching any Lua callbacks that fire via yields.
-- Leaves results on co's stack on success.
-- Returns true on success, or false + error_message on failure.
---@param state lua.State
---@param co    lua.raw.State   -- the coroutine thread
---@param nargs integer         -- number of arguments on co's stack (after the function)
---@return boolean, string|nil
local function run_coroutine(state, co, nargs)
	while true do
		local status = raw.resume(co, nargs)
		if status == LUA_YIELD then
			-- The coroutine yielded — check for a pending Lua callback.
			-- The proxy function stores callback info in _G.__lua_cb on the
			-- coroutine's globals, then yields. We read it, dispatch, push
			-- results onto the coroutine stack, and resume.

			-- Read _G.__lua_cb from the coroutine's globals
			raw.pushvalue(co, LUA_GLOBALSINDEX)
			raw.getfield(co, -1, "__lua_cb")
			local cb_nil = (raw.type(co, -1) == 0)
			raw.pop(co, 2)

			if cb_nil then
				-- Spurious yield — pass nothing back
				nargs = 0
			else
				-- Read the callback info table from globals via a fresh lookup
				raw.pushvalue(co, LUA_GLOBALSINDEX)
				raw.getfield(co, -1, "__lua_cb")
				local cb_info = fromLua(state, co, -1)
				raw.pop(co, 2)

				local id_tbl = cb_info:get("id")
				local args_val = cb_info:get("args")
				local id = id_tbl and id_tbl:value()
				local outer_fn = state._lua_callbacks[id]

				if outer_fn then
					-- Collect inner-state arguments
					local inner_args = {}
					if args_val and args_val._type == "table" then
						for i = 1, math.huge do
							local v = args_val:get(i)
							if v == nil then break end
							inner_args[i] = v
						end
					end

					-- Call the outer function with state as first arg
					local rets = pack(outer_fn(state, unpack(inner_args, 1, #inner_args)))

					-- Push results onto the coroutine stack for the proxy to receive
					for i = 1, rets.n do
						toLua(state, co, rets[i])
					end
					nargs = rets.n
				else
					nargs = 0
				end

				-- Clear the callback info
				raw.pushvalue(co, LUA_GLOBALSINDEX)
				raw.pushnil(co)
				raw.setfield(co, -2, "__lua_cb")
				raw.pop(co, 1)
			end
		elseif status == LUA_OK then
			-- Finished normally — results are on the coroutine stack
			return true
		else
			-- Error in the coroutine
			local err = raw.tolstring(co, -1)
			raw.settop(co, 0)
			return false, err
		end
	end
end

--- Call the function, raising on error. Results are returned as lua.Values.
---@param ... string | number | boolean | lua.Value | function | nil
---@return lua.Value ...
function Function:call(...)
	local state = self._state
	local L     = state.L

	local base  = raw.gettop(L)

	-- Create a coroutine thread (pushed onto L's stack)
	local co    = raw.newthread(L)

	-- Push the function onto the coroutine stack
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref)
	raw.xmove(L, co, 1)

	-- Push arguments onto the coroutine stack
	local n = select("#", ...)
	for i = 1, n do
		toLua(state, L, (select(i, ...)))
	end
	if n > 0 then
		raw.xmove(L, co, n)
	end

	-- Run the coroutine with callback dispatch
	local ok, err = run_coroutine(state, co, n)

	-- Pop the coroutine thread from L's stack (it was the only thing above base)
	-- L is back to where it was before newthread
	raw.pop(L, 1)

	if not ok then
		raw.settop(L, base)
		error(err, 2)
	end

	-- Move results from the coroutine stack to L
	local nresults = raw.gettop(co)
	if nresults > 0 then
		raw.xmove(co, L, nresults)
	end

	local results = {}
	for i = 1, nresults do
		results[i] = fromLua(state, L, base + i)
	end
	raw.settop(L, base)
	return unpack(results, 1, nresults)
end

--- Protected call. Returns false + error string on failure, true + results on success.
---@param ... string | number | boolean | lua.Value | function | nil
---@return boolean, ...
function Function:pcall(...)
	local state = self._state
	local L     = state.L

	local base  = raw.gettop(L)

	-- Create a coroutine thread (pushed onto L's stack)
	local co    = raw.newthread(L)

	-- Push the function onto the coroutine stack
	raw.rawgeti(L, LUA_REGISTRYINDEX, self._ref)
	raw.xmove(L, co, 1)

	-- Push arguments onto the coroutine stack
	local n = select("#", ...)
	for i = 1, n do
		toLua(state, L, (select(i, ...)))
	end
	if n > 0 then
		raw.xmove(L, co, n)
	end

	-- Run the coroutine with callback dispatch
	local ok, err = run_coroutine(state, co, n)

	-- Pop the coroutine thread from L's stack
	raw.pop(L, 1)

	if not ok then
		raw.settop(L, base)
		return false, err
	end

	-- Move results from the coroutine stack to L
	local nresults = raw.gettop(co)
	if nresults > 0 then
		raw.xmove(co, L, nresults)
	end

	local results = {}
	for i = 1, nresults do
		results[i] = fromLua(state, L, base + i)
	end
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
---@param value string | number | boolean | lua.Value | lua.Function | lua.Table | function | nil
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
-- or plain Lua functions (registered as yield-based proxy in the inner state).
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
		raw.pushstring(L, value)
	elseif t == "table" and isValue(value) then
		-- lua.Value: push from registry ref for compound types, or push primitive directly
		if value._ref ~= LUA_NOREF then
			raw.rawgeti(L, LUA_REGISTRYINDEX, value._ref)
		elseif value._type == "number" then
			raw.pushnumber(L, value._value)
		elseif value._type == "string" then
			raw.pushstring(L, value._value)
		elseif value._type == "boolean" then
			raw.pushboolean(L, value._value and 1 or 0)
		else
			raw.pushnil(L)
		end
	elseif t == "function" then
		-- Store the outer Lua function by ID and load a proxy into the inner state.
		-- The proxy captures args, stores them in _G.__lua_cb, and yields.
		-- The outer dispatch loop (in run_coroutine) reads __lua_cb, calls
		-- the real function, pushes results onto the coroutine stack, and resumes.
		local id = #state._lua_callbacks + 1
		state._lua_callbacks[id] = value

		local proxy_code = ([[
			return function(...)
				_G.__lua_cb = { id = %d, args = {...} }
				local results = { coroutine.yield() }
				_G.__lua_cb = nil
				if #results > 0 then
					return unpack(results, 1, #results)
				end
				return
			end
		]]):format(id)

		local ok = raw.loadstring(L, proxy_code) == 0
		if not ok then
			local err = raw.tolstring(L, -1)
			raw.pop(L, 1)
			error("failed to load callback proxy: " .. err, 2)
		end
		ok = raw.pcall(L, 0, 1, 0) == 0
		if not ok then
			local err = raw.tolstring(L, -1)
			raw.pop(L, 1)
			error("failed to init callback proxy: " .. err, 2)
		end
		-- The proxy function is now on the stack (returned by the loaded chunk)
	else
		error("cannot coerce value of type '" .. t .. "' to a Lua value", 2)
	end
end

-- ─── State ────────────────────────────────────────────────────────────────

---@class lua.State
---@field L               lua.raw.State
---@field _callbacks      table  -- keeps ffi cdata callbacks alive (legacy)
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

	-- Execute via coroutine so callbacks (yields) are handled.
	-- The loaded function is at the top of L.
	local base = raw.gettop(L) - 1 -- base of loaded function
	local co   = raw.newthread(L) -- L: [..., func, co], top = base + 2

	-- Move the loaded function from L to co
	-- Function is at base + 1 on L, move it (and it alone) to co
	raw.pushvalue(L, base + 1) -- duplicate func: L: [..., func, co, func]
	raw.xmove(L, co, 1)     -- move duplicate to co: L: [..., func, co]. co: [func]

	-- The coroutine is at base + 2 on L
	-- Remove the original loaded function from L (it was at base + 1)
	raw.remove(L, base + 1) -- L: [..., co] (func removed)

	-- Run coroutine
	local ok, err = run_coroutine(self, co, 0)

	-- Pop the coroutine thread from L
	raw.pop(L, 1) -- L: back to base

	if not ok then
		raw.settop(L, base)
		error(err, 2)
	end

	-- Move results from co to L
	local nresults = raw.gettop(co)
	if nresults > 0 then
		raw.xmove(co, L, nresults)
	end

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
jit.off(run_coroutine, true)

return lua
