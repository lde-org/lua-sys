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

local LUA_MASKCALL  = 1
local LUA_MASKRET   = 2
local LUA_MASKLINE  = 4
local LUA_MASKCOUNT = 8

-- LuaJIT JIT mode constants for state:jitOff / state:jitOn / state:jitFlush
local LUAJIT_MODE_ENGINE = 0
local LUAJIT_MODE_FUNC   = 2
local LUAJIT_MODE_OFF    = 0x0000
local LUAJIT_MODE_ON     = 0x0100
local LUAJIT_MODE_FLUSH  = 0x0200

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
local dispatchCallbackSlowRef

-- Guest lua_State* (as lightuserdata) → lua.State wrapper. dispatch_callback's
-- slow path uses this to build lua.Table proxies for guest-passed tables.
local guestStates = {}

-- id → lua.State, for resolving coroutine threads: the guest registry (keyed
-- by GUEST_ID_KEY) is shared by all threads of a state, so any thread — main
-- or coroutine — can be mapped back to its lua.State wrapper.
local guestById   = {}
local nextGuestId = 1
local GUEST_ID_KEY = ffi.new("char[1]")

--- Resolve a guest thread (main or coroutine) to its lua.State wrapper.
---@param thread lua.raw.State|lightuserdata
---@return lua.State?
local function resolveGuestState(thread)
	local state = guestStates[thread]
	if state then return state end
	-- Coroutine thread: fall back to the registry marker, which every thread
	-- of the same guest state shares.
	ffi.C.lua_pushlightuserdata(thread, GUEST_ID_KEY)
	ffi.C.lua_rawget(thread, LUA_REGISTRYINDEX)
	local id = tonumber(ffi.C.lua_tointeger(thread, -1)) -- int64 cdata → Lua number key
	ffi.C.lua_settop(thread, -2)
	return guestById[id]
end

-- Lightuserdata tag prefixing (tag, guest_registry_ref) pairs that
-- dispatch_callback passes host-side for table arguments.
local COMPOUND_TAG = bridge.compound_tag()

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
			bridge.push_callback(tonumber(ffi.cast("intptr_t", L)), callbackId, dispatchCallbackSlowRef)
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

-- Slow path for guest → host callback dispatch (dispatch_callback upvalue 2):
-- converts guest-passed table arguments (received as (tag, ref) pairs) into
-- lua.Table proxies and calls the real host callback, preserving argument
-- order and nil slots. Called by C only when at least one argument is a table.
---@param guestPtr lightuserdata
---@param fn        function
local function dispatchCallbackSlow(guestPtr, fn, ...)
	local guestState = resolveGuestState(guestPtr)
	if guestState == nil then
		error("bridge: guest state is closed or unknown", 2)
	end
	local n    = select("#", ...)
	local real = {}
	local k    = 0
	local i    = 1
	while i <= n do
		local v = select(i, ...)
		if v == COMPOUND_TAG then
			k = k + 1
			real[k] = Table._new(guestState, select(i + 1, ...))
			i = i + 2
		else
			k = k + 1
			real[k] = v
			i = i + 1
		end
	end
	-- unpack with explicit bounds preserves nil holes, so nil args are kept
	return fn(unpack(real, 1, k))
end

-- Registry ref for dispatchCallbackSlow, baked into every dispatch_callback
-- closure as upvalue 2 (alongside the callback's own ref).
dispatchCallbackSlowRef = bridge.register(dispatchCallbackSlow)

-- Returns a host-callable function backed by a guest registry ref.
--
-- bound_call is returned directly as the callable — no Lua wrapper.
-- Every host↔guest transition goes through a lua_CFunction boundary,
-- which is required to avoid LuaJIT's FFI re-entrancy crash.
-- See docs/bridge-design.md.
--
-- The callable carries a function metatable (attached in C by
-- bridge.make_callable) providing `fn:pcall(...)`, which runs the guest
-- call with pcall semantics: `true, ...` on success, `false, err` on error.
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

--- Compile and execute the chunk with the given arguments, returning
--- `true, ...` (all results) on success or `false, err` on error instead
--- of raising on the host side.
---
--- Unlike :eval(), a guest error is returned as `false, err`. Compile
--- (syntax) errors are also caught and returned as `false, err`.
---@param ... any
function Chunk:pcall(...)
	return Chunk._pcall(self, false, ...)
end

--- Like :pcall(), but the error string on failure includes a stack
--- traceback of the guest stack at the point of failure (the guest
--- debug.traceback is installed as pcall's error handler, so the frames
--- are captured before unwinding). Use this when reporting program errors
--- without wrapping the program in a guest-side xpcall launcher.
---@param ... any
function Chunk:xpcall(...)
	return Chunk._pcall(self, true, ...)
end

-- Shared implementation of pcall / xpcall.
---@param chunk          lua.Chunk
---@param withTraceback  boolean
function Chunk._pcall(chunk, withTraceback, ...)
	local ok, a, b = pcall(chunk._compile, chunk)
	if not ok then return false, a end
	local L, fnIndex = a, b
	local base = fnIndex - 1

	-- Install debug.traceback below the function as pcall's error handler so
	-- the traceback is captured while the guest stack is still intact.
	-- lua_pcall treats errfunc == 0 as "no handler", so it must point at the
	-- traceback slot (base + 1 after the insert), never at a zero index.
	local errfunc   = 0
	local installed = false
	if withTraceback then
		raw.getglobal(L, "debug")
		raw.getfield(L, -1, "traceback")
		raw.remove(L, -2)
		if raw.type(L, -1) == 6 then -- LUA_TFUNCTION
			raw.insert(L, -2) -- [..base..][traceback][fn]
			errfunc   = base + 1
			installed = true
		else
			raw.pop(L, 1) -- guest debug library unavailable — bare message
		end
	end

	local nargs = select("#", ...)
	local state = chunk._state
	for i = 1, nargs do toLua(state, L, (select(i, ...))) end

	local status = raw.pcall(L, nargs, LUA_MULTRET, errfunc)
	local restore    = base
	local resultBase = base + (installed and 1 or 0) -- results sit above the traceback
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.settop(L, restore)
		return false, err
	end
	local nresults = raw.gettop(L) - resultBase
	if nresults == 0 then
		raw.settop(L, restore)
		return true
	end
	local results = {}
	for i = 1, nresults do results[i] = fromLua(state, L, resultBase + i) end
	raw.settop(L, restore)
	return true, unpack(results, 1, nresults)
end

-- ─── State ────────────────────────────────────────────────────────────────

---@class lua.State
---@field L            lua.raw.State
---@field _callbacks   table
---@field _guest_L_ptr number?
---@field _guest_fns   table?
---@field _hook_ref    integer?
---@field _guest_light lightuserdata?
---@field _guest_id    integer?
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

-- ─── JIT control ─────────────────────────────────────────────────────────

-- Shared helper: apply a per-function JIT mode to a guest callable.
---@param guestState lua.State
---@param guestRef   integer
---@param mode       integer
local function setFuncJitMode(guestState, guestRef, mode)
	local L = guestState.L
	if L == nil then error("state is closed", 2) end
	raw.rawgeti(L, LUA_REGISTRYINDEX, guestRef)
	raw.jit_setmode(L, -1, LUAJIT_MODE_FUNC + mode)
	raw.pop(L, 1)
end

--- Disable the JIT compiler for the guest state, or for a single guest
--- function when `fn` (a callable obtained from this state) is given.
--- Returns self for chaining.
---
--- Debug hooks only fire on interpreted code, so disabling the JIT is
--- required for line/count hooks to fire reliably on hot code (note that
--- state:setHook does this automatically for the whole state while a hook
--- is installed).
---@param fn function?
function State:jitOff(fn)
	local L = self.L
	if L == nil then error("state is closed", 2) end
	if fn == nil then
		raw.jit_setmode(L, 0, LUAJIT_MODE_ENGINE + LUAJIT_MODE_OFF)
	else
		local ref = self._guest_fns and self._guest_fns[fn]
		if ref == nil then
			error("jitOff: fn must be a guest callable obtained from this state", 2)
		end
		setFuncJitMode(self, ref, LUAJIT_MODE_OFF)
	end
	return self
end

--- Re-enable the JIT compiler for the guest state, or for a single guest
--- function when `fn` is given. Returns self for chaining.
---@param fn function?
function State:jitOn(fn)
	local L = self.L
	if L == nil then error("state is closed", 2) end
	if fn == nil then
		raw.jit_setmode(L, 0, LUAJIT_MODE_ENGINE + LUAJIT_MODE_ON)
	else
		local ref = self._guest_fns and self._guest_fns[fn]
		if ref == nil then
			error("jitOn: fn must be a guest callable obtained from this state", 2)
		end
		setFuncJitMode(self, ref, LUAJIT_MODE_ON)
	end
	return self
end

--- Flush all compiled traces from the guest state. Useful after disabling
--- the JIT or before re-enabling it, to drop previously compiled code.
function State:jitFlush()
	local L = self.L
	if L == nil then error("state is closed", 2) end
	raw.jit_setmode(L, 0, LUAJIT_MODE_ENGINE + LUAJIT_MODE_FLUSH)
end

-- ─── Debug hooks ──────────────────────────────────────────────────────────

--- A stack frame (`info:stack()`), usable while the guest thread is paused
--- at the hook. Locals/upvalues can be read and written, and code can be
--- evaluated with the frame's locals and upvalues in scope.
---@class lua.Frame
---@field thread          lua.raw.State -- lightuserdata of the guest lua_State* at runtime
---@field level           integer       -- stack level (0 = the hook frame)
---@field name            string? -- function name, when derivable
---@field namewhat        string? -- "global", "local", "method", ...
---@field what            string? -- "Lua", "main" or "C"
---@field source          string? -- chunk source of the frame
---@field short_src       string  -- shortened source name
---@field currentline     integer -- line at the hook point (-1 when unknown)
---@field linedefined     integer
---@field lastlinedefined integer
---@field nups            integer
---@field locals          fun(self: lua.Frame): { name: string, value: any }[]
---@field getLocal        fun(self: lua.Frame, name: string): any
---@field setLocal        fun(self: lua.Frame, name: string, value: any): boolean
---@field upvalues        fun(self: lua.Frame): { name: string, value: any }[]
---@field getUpvalue      fun(self: lua.Frame, name: string): any
---@field setUpvalue      fun(self: lua.Frame, name: string, value: any): boolean
---@field eval            fun(self: lua.Frame, code: string): boolean, any

--- The `info` argument passed to a state:setHook callback. All fields are
--- populated eagerly; `stack()` walks the triggering thread while it is
--- paused at the hook, so it must be called from within the callback.
---@class lua.HookInfo
---@field event            "call"|"return"|"line"|"count"|"tailcall"
---@field thread           lightuserdata -- lua_State* the hook fired on
---@field name             string?
---@field namewhat         string?
---@field what             string?
---@field source           string?
---@field short_src        string
---@field currentline      integer
---@field linedefined      integer
---@field lastlinedefined  integer
---@field nups             integer
---@field stack            fun(self: lua.HookInfo): lua.Frame[]

local HOOK_MASK_NAMES = {
	call        = LUA_MASKCALL,
	["return"] = LUA_MASKRET,
	ret         = LUA_MASKRET,
	line        = LUA_MASKLINE,
	count       = LUA_MASKCOUNT,
}

--- Parse a hook mask into LuaJIT's LUA_MASK* bitmask: a space-separated
--- string of event names ("line", "call return", "count", ...) or a raw
--- integer bitmask.
---@param mask string|integer
---@return integer
local function parseHookMask(mask)
	if type(mask) == "number" then return mask end
	if type(mask) ~= "string" then
		error("setHook: mask must be a string like \"line\" or an integer bitmask, got " .. type(mask), 3)
	end
	local bits = 0
	for word in mask:gmatch("%S+") do
		local bit = HOOK_MASK_NAMES[word]
		if bit == nil then
			error("setHook: unknown hook event '" .. word .. "' (expected call, return, line, count)", 3)
		end
		bits = bits + bit
	end
	if bits == 0 then error("setHook: hook mask cannot be empty", 3) end
	return bits
end

--- Install or remove a debug hook on the guest state. This is the
--- high-level counterpart to the raw lua_sethook API — no FFI casting or
--- raw callback plumbing required.
---
--- `fn` is a host Lua function called as `fn(event, info)` for every hook
--- event, where `event` is one of "call", "return", "line", "count" or
--- "tailcall".
---
--- `info` (a lua.HookInfo) describes the event. All fields are populated
--- eagerly, including `info.thread` — a lightuserdata holding the lua_State*
--- the hook fired on: the guest main thread, or a coroutine thread running
--- inside it. Cast it back with ffi.cast("lua_State*", info.thread) to call
--- lua_getstack / lua_getinfo / lua_getlocal on the triggering thread
--- (needed for correct stack traces and locals inside coroutines).
---
--- `info:stack()` returns the stack trace of the triggering thread as an
--- array of lua.Frame objects (index 1 = the frame the hook fired in),
--- each with the same debug fields as `info` plus methods to read/write
--- locals and upvalues and evaluate code in the frame. It walks the thread
--- while it is paused at the hook, so it must be called from within the
--- callback — a stored info table raises if you call it after the hook
--- returns.
---
--- `mask` selects which events fire: a space-separated string of event
--- names ("line", "call return line", "count", ...) or an integer bitmask
--- (LUA_MASKCALL=1, LUA_MASKRET=2, LUA_MASKLINE=4, LUA_MASKCOUNT=8).
---
--- `count` is the instruction interval for the "count" event (default 1).
---
--- LuaJIT only fires hooks on interpreted code, so while a hook is installed
--- the guest JIT engine is disabled (and existing traces flushed); removing
--- the hook re-enables it. Use state:jitOff / state:jitOn for explicit
--- control.
---
--- Passing nil removes the hook: `state:setHook(nil)`.
---
--- A hook that errors aborts the running guest code with that error
--- (catchable with pcall around state:eval / chunk:eval), mirroring what
--- calling lua_error from a raw hook does.
---@param fn    fun(event: "call"|"return"|"line"|"count"|"tailcall", info: lua.HookInfo)|nil
---@param mask  string|integer
---@param count integer?
function State:setHook(fn, mask, count)
	local L = self.L
	if L == nil then error("state is closed", 2) end

	-- Drop the previous hook callback (if any) before installing a new one.
	if self._hook_ref then
		bridge.unregister(self._hook_ref)
		self._hook_ref = nil
	end

	if fn == nil then
		bridge.remove_hook(tonumber(ffi.cast("intptr_t", L)))
		return
	end

	if type(fn) ~= "function" then
		error("setHook: fn must be a function or nil, got " .. type(fn), 2)
	end

	local bits = parseHookMask(mask)
	count = count or 1

	self._hook_ref = bridge.register(fn)
	bridge.set_hook(tonumber(ffi.cast("intptr_t", L)), self._hook_ref, bits, count)
end

function State:close()
	if self.L then
		if self._hook_ref then
			bridge.unregister(self._hook_ref)
			self._hook_ref = nil
		end
		for _, cb in ipairs(self._callbacks) do bridge.unregister(cb.id) end
		bridge.close_state(tonumber(ffi.cast("intptr_t", self.L)))
		guestStates[self._guest_light] = nil
		guestById[self._guest_id]      = nil
		self.L          = nil
		self._callbacks = {}
	end
end

-- ─── Frame ────────────────────────────────────────────────────────────────

---@class lua.Frame
local Frame = {}
Frame.__index = Frame

-- Internal: resolve the owning lua.State wrapper for a frame. The frame's
-- thread (self.thread) is carried as a lightuserdata but typed lua.raw.State
-- so raw API calls typecheck; LuaJIT converts lightuserdata to pointers.
---@param frame lua.Frame
---@return lua.State?
local function frameGuestState(frame)
	return resolveGuestState(frame.thread)
end

--- List this frame's active locals as { name, value } pairs, in order.
---@return { name: string, value: any }[]
function Frame:locals()
	local guestState = frameGuestState(self)
	if guestState == nil then return {} end
	local L = self.thread
	local ar = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar) == 0 then return {} end
	local out = {}
	for i = 1, 200 do
		local name = ffi.C.lua_getlocal(L, ar, i)
		if name == nil then break end
		out[i] = { name = ffi.string(name), value = fromLua(guestState, L, -1) }
		ffi.C.lua_settop(L, -2)
	end
	return out
end

---@param name string
function Frame:getLocal(name)
	local guestState = frameGuestState(self)
	if guestState == nil then return nil end
	local L = self.thread
	local ar = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar) == 0 then return nil end
	for i = 1, 200 do
		local ln = ffi.C.lua_getlocal(L, ar, i)
		if ln == nil then return nil end
		local lname = ffi.string(ln)
		if lname == name then
			local value = fromLua(guestState, L, -1)
			ffi.C.lua_settop(L, -2)
			return value
		end
		ffi.C.lua_settop(L, -2)
	end
	return nil
end

--- Assign to a local of the frame. Only active locals can be written.
---@param name  string
---@param value any
---@return boolean
function Frame:setLocal(name, value)
	local guestState = frameGuestState(self)
	if guestState == nil then return false end
	local L = self.thread
	local ar = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar) == 0 then return false end
	for i = 1, 200 do
		local ln = ffi.C.lua_getlocal(L, ar, i)
		if ln == nil then return false end
		local lname = ffi.string(ln)
		ffi.C.lua_settop(L, -2) -- pop the read value
		if lname == name then
			toLua(guestState, L, value)
			ffi.C.lua_setlocal(L, ar, i) -- pops the value, assigns the local
			return true
		end
	end
	return false
end

--- List this frame's function's upvalues as { name, value } pairs.
---@return { name: string, value: any }[]
function Frame:upvalues()
	local guestState = frameGuestState(self)
	if guestState == nil then return {} end
	local L = self.thread
	local ar = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar) == 0 then return {} end
	ffi.C.lua_getinfo(L, "f", ar) -- push the frame's function
	local fnIdx = raw.gettop(L)
	local out = {}
	for i = 1, 200 do
		local name = ffi.C.lua_getupvalue(L, fnIdx, i)
		if name == nil then break end
		out[i] = { name = ffi.string(name), value = fromLua(guestState, L, -1) }
		ffi.C.lua_settop(L, -2)
	end
	ffi.C.lua_settop(L, fnIdx - 1) -- pop the function
	return out
end

---@param name string
function Frame:getUpvalue(name)
	local guestState = frameGuestState(self)
	if guestState == nil then return nil end
	local L = self.thread
	local ar = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar) == 0 then return nil end
	ffi.C.lua_getinfo(L, "f", ar)
	local fnIdx = raw.gettop(L)
	for i = 1, 200 do
		local un = ffi.C.lua_getupvalue(L, fnIdx, i)
		if un == nil then break end
		local uname = ffi.string(un)
		if uname == name then
			local value = fromLua(guestState, L, -1)
			ffi.C.lua_settop(L, -2)
			ffi.C.lua_settop(L, fnIdx - 1)
			return value
		end
		ffi.C.lua_settop(L, -2)
	end
	ffi.C.lua_settop(L, fnIdx - 1)
	return nil
end

--- Assign to an upvalue of the frame's function.
---@param name  string
---@param value any
---@return boolean
function Frame:setUpvalue(name, value)
	local guestState = frameGuestState(self)
	if guestState == nil then return false end
	local L = self.thread
	local ar = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar) == 0 then return false end
	ffi.C.lua_getinfo(L, "f", ar)
	local fnIdx = raw.gettop(L)
	for i = 1, 200 do
		local un = ffi.C.lua_getupvalue(L, fnIdx, i)
		if un == nil then break end
		local uname = ffi.string(un)
		ffi.C.lua_settop(L, -2)
		if uname == name then
			toLua(guestState, L, value)
			ffi.C.lua_setupvalue(L, fnIdx, i)
			ffi.C.lua_settop(L, fnIdx - 1)
			return true
		end
	end
	ffi.C.lua_settop(L, fnIdx - 1)
	return false
end

--- Evaluate `code` with this frame's locals and upvalues in scope.
---
--- The chunk runs in a fresh guest environment seeded with the frame's
--- active locals and upvalues; reads of other names fall through (via
--- __index) to the frame function's environment, and writes to new names go
--- there too (via __newindex). On success, assignments to existing locals
--- and upvalues are written back to the frame, so `frame:eval("x = 42")`
--- changes the running program. Returns `true, first result` or
--- `false, err`. Must be called from within the hook callback.
---@param code string
---@return boolean, any
function Frame:eval(code)
	local guestState = frameGuestState(self)
	if guestState == nil then
		return false, "no frame at stack level " .. tostring(self.level)
	end
	local L = self.thread
	local ar = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar) == 0 then
		return false, "no frame at stack level " .. tostring(self.level)
	end

	-- Env: a fresh guest table seeded with the frame's active locals.
	raw.createtable(L, 0, 32)
	local envIdx = raw.gettop(L)
	for i = 1, 200 do
		local ln = ffi.C.lua_getlocal(L, ar, i)
		if ln == nil then break end
		local lname = ffi.string(ln)
		raw.pushstring(L, lname)   -- [env][value][key]
		raw.pushvalue(L, -2)       -- [env][value][key][value]
		raw.settable(L, envIdx)    -- [env][value]
		raw.pop(L, 1)              -- [env]
	end

	-- ... and the frame function's upvalues.
	ffi.C.lua_getinfo(L, "f", ar)
	local fnIdx = raw.gettop(L)
	for i = 1, 200 do
		local un = ffi.C.lua_getupvalue(L, fnIdx, i)
		if un == nil then break end
		local uname = ffi.string(un)
		raw.pushstring(L, uname)   -- [fn][value][key]
		raw.pushvalue(L, -2)       -- [fn][value][key][value]
		raw.settable(L, envIdx)    -- [fn][value]
		raw.pop(L, 1)              -- [fn]
	end

	-- Chain reads/writes of other names to the frame function's environment.
	ffi.C.lua_getfenv(L, fnIdx)    -- [fn][fenv]
	raw.createtable(L, 0, 2)       -- [fn][fenv][mt]
	raw.pushvalue(L, -2)
	raw.setfield(L, -2, "__index") -- [fn][fenv][mt]
	raw.pushvalue(L, -2)
	raw.setfield(L, -2, "__newindex")
	raw.setmetatable(L, envIdx)
	ffi.C.lua_settop(L, fnIdx - 1) -- drop [fn][fenv][mt]; env stays at envIdx

	-- Load "return <code>", falling back to plain code (like Chunk)._compile.
	local wrapped = "return " .. code
	local status = raw.loadstring(L, wrapped)
	if status ~= LUA_OK then
		raw.pop(L, 1)
		status = raw.loadstring(L, code)
	end
	if status ~= LUA_OK then
		local err = raw.tolstring(L, -1)
		raw.pop(L, 1)
		raw.settop(L, envIdx - 1)
		return false, err
	end

	raw.pushvalue(L, envIdx)       -- [chunk][env]
	ffi.C.lua_setfenv(L, -2)       -- [chunk]
	local pstatus = raw.pcall(L, 0, LUA_MULTRET, 0)
	if pstatus ~= LUA_OK and pstatus ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.settop(L, envIdx - 1)
		return false, err
	end

	-- Convert the results (they sit at envIdx + 1.. above the env table)
	-- before any stack churn below.
	local nresults = raw.gettop(L) - envIdx
	local results = {}
	for i = 1, nresults do results[i] = fromLua(guestState, L, envIdx + i) end

	-- Write assignments to existing locals/upvalues back to the frame.
	local ar2 = ffi.new("lua_Debug")
	if ffi.C.lua_getstack(L, self.level, ar2) ~= 0 then
		for i = 1, 200 do
			local ln = ffi.C.lua_getlocal(L, ar2, i)
			if ln == nil then break end
			local lname = ffi.string(ln)
			ffi.C.lua_settop(L, -2)        -- pop the read value
			raw.getfield(L, envIdx, lname) -- push env[lname]
			ffi.C.lua_setlocal(L, ar2, i)  -- pop + assign to the local
		end
		ffi.C.lua_getinfo(L, "f", ar2)
		local fn2 = raw.gettop(L)
		for i = 1, 200 do
			local un = ffi.C.lua_getupvalue(L, fn2, i)
			if un == nil then break end
			local uname = ffi.string(un)
			ffi.C.lua_settop(L, -2)
			raw.getfield(L, envIdx, uname)
			ffi.C.lua_setupvalue(L, fn2, i)
		end
		ffi.C.lua_settop(L, fn2 - 1)
	end

	raw.settop(L, envIdx - 1)
	if nresults == 0 then return true end
	return true, results[1]
end

-- Frames returned by info:stack() carry this class as their metatable.
bridge.set_frame_meta(Frame)

-- ─── Module ───────────────────────────────────────────────────────────────

---@class lua
local lua    = {}

lua.raw      = raw
lua.profiler = require("lua-sys.profiler")

---@return lua.State
function lua.new()
	-- bridge.new_state() calls luaL_newstate() + luaL_openlibs() entirely in C,
	-- returning the pointer as lightuserdata. This is safe to call from any
	-- context — including from within a host callback triggered by guest code —
	-- because no FFI cdata argument is involved at the call boundary.
	-- We cast to lua_State* cdata here, on host_L outside any guest execution.
	local light = bridge.new_state()
	local L     = ffi.cast("lua_State*", light)
	local id    = nextGuestId
	nextGuestId = nextGuestId + 1
	local state = setmetatable({
		L = L, _callbacks = {}, _guest_light = light, _guest_id = id,
	}, State)
	guestStates[light] = state
	guestById[id]      = state
	-- Registry marker so coroutine threads (which have their own lua_State*)
	-- can be resolved back to this wrapper via resolveGuestState.
	ffi.C.lua_pushlightuserdata(L, GUEST_ID_KEY)
	ffi.C.lua_pushinteger(L, id)
	ffi.C.lua_rawset(L, LUA_REGISTRYINDEX)
	return state
end

return lua
