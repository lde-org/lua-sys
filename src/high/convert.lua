-- high/convert.lua — values crossing between the host and a guest state.
--
-- Primitives are copied, a guest table becomes a lua.Table reference, a guest
-- function becomes a C closure that calls back into that state, and a plain
-- host table becomes a new guest table. Compound values that the bridge moves
-- through the compound paths are passed as registry references.

local ffi = require("ffi")
local bridge = require("lua-sys.bridge")

local unpack = rawget(_G, "unpack") --[[@as fun(list: table, i: integer?, j: integer?): any]]

local LUA_NOREF = -2
local LUA_MULTRET = -1
local LUA_OK = 0
local LUA_YIELD = 1

local convert = {}

---@class lua.bridge
---@field runtime fun(handle: any, abi: string): integer?, string?
---@field compound_tag fun(): any
---@field register fun(fn: function): integer
---@field unregister fun(ref: integer)
---@field make_callable fun(slot: integer, guest: any, ref: integer, guestState: lua.State, slowRef: integer, closedFlag: any, convertRef: integer): function
---@field push_callback fun(slot: integer, guest: any, callbackId: integer, slowRef: integer, jitDepth: any, chainBox: any)
---@field set_hook fun(slot: integer, guest: any, hookRef: integer, mask: integer, count: integer): boolean?, string?
---@field remove_hook fun(slot: integer, guest: any): boolean?
---@field set_frame_meta fun(meta: table)
---@field new_state fun(slot: integer?): any
---@field close_state fun(slot: integer, guest: any)
---@field memory_used fun(slot: integer, guest: any): integer
---@field set_memory_limit fun(slot: integer, guest: any, bytes: integer)
---@field heap_snapshot fun(slot: integer, guest: any, maxDepth: integer, maxPaths: integer): lua.HeapSnapshot

local Table, Value
local fromLua, toLua, makeCallable

-- thread pointer (as a host number) → lua.State. The hook wrapper records the
-- state for the thread an event fired on, including coroutine threads, so a
-- frame can resolve its owner without a field on the info table. Weak values:
-- a state that no longer exists is not kept alive by a stale thread key.
---@type table<number, lua.State>
local threadOwners = setmetatable({}, { __mode = "v" })

---@param state  lua.State
---@param thread any
function convert.rememberThread(state, thread)
	threadOwners[tonumber(ffi.cast("intptr_t", thread))] = state
end

---@param thread any
---@return lua.State?
function convert.ownerOf(thread)
	return threadOwners[tonumber(ffi.cast("intptr_t", thread))]
end

-- Lightuserdata tag prefixing (tag, guest_registry_ref) pairs that
-- dispatch_callback passes host-side for table arguments.
local COMPOUND_TAG = bridge.compound_tag()

-- Guest registry key for the table that maps a guest function to its
-- canonical registry ref.
local FN_REF_KEY = ffi.new("char[1]")

--- A method that dereferences state.L must call this first. After close(), L
--- is nil and a raw call would use a freed lua_State. The level points at the
--- caller of the public method that runs the check.
---@return never
function convert.closedError()
	error("state is closed", 3)
end

---@param v any
---@return boolean
local function isGuestValue(v)
	if type(v) ~= "table" then return false end
	local mt = getmetatable(v)
	return mt ~= nil and rawget(mt, "_is_lua_value") == true
end

-- The canonical registry ref of the guest function at `stackIndex`. The map
-- lives in the guest registry and is keyed by the function, so one guest
-- function always gives one ref. The host callable cache then hits, the guest
-- registry stays small, and a fetch is cheap.
---@param state      lua.State
---@param L          any
---@param stackIndex integer
---@return integer
local function guestFnRef(state, L, stackIndex)
	local raw = state._raw
	local registry = state._registryIndex
	if stackIndex < 0 then stackIndex = raw.gettop(L) + stackIndex + 1 end

	raw.pushlightuserdata(L, FN_REF_KEY)
	raw.rawget(L, registry) -- [map?]
	if raw.type(L, -1) == 0 then
		-- nil: make the map
		raw.pop(L, 1)
		raw.createtable(L, 0, 8)
		raw.pushlightuserdata(L, FN_REF_KEY)
		raw.pushvalue(L, -2)
		raw.rawset(L, registry) -- registry[FN_REF_KEY] = map
	end
	raw.pushvalue(L, stackIndex) -- [map][fn]
	raw.rawget(L, -2) -- [map][ref?]
	if raw.type(L, -1) == 3 then
		-- a number: the ref. tonumber: lua_tointeger returns an int64 cdata,
		-- and a cdata key would not match the Lua number of the miss path.
		local ref = tonumber(raw.tointeger(L, -1))
		raw.pop(L, 2)
		return ref
	end

	raw.pop(L, 1) -- [map]
	raw.pushvalue(L, stackIndex) -- [map][fn]
	local ref = raw.ref(L, registry) -- pops [fn]
	raw.pushvalue(L, stackIndex) -- [map][fn]
	raw.pushinteger(L, ref) -- [map][fn][ref]
	raw.rawset(L, -3) -- map[fn] = ref
	raw.pop(L, 1)
	return ref
end

---@param state      lua.State
---@param L          any
---@param stackIndex integer
---@return lua.ValueType
fromLua = function(state, L, stackIndex)
	local raw = state._raw
	local typeId = raw.type(L, stackIndex)
	if typeId == 0 then return nil end

	local typename = state._typeNames[typeId]
	if typename == "boolean" then return raw.toboolean(L, stackIndex) end
	if typename == "number" then return state._toNumber(L, stackIndex) end
	if typename == "string" then return raw.tolstring(L, stackIndex) end
	if typename == "function" then
		return makeCallable(state, guestFnRef(state, L, stackIndex))
	end

	raw.pushvalue(L, stackIndex)
	local ref = raw.ref(L, state._registryIndex)

	if typename == "table" then
		return Table._new(state, ref)
	else
		return Value._ref_new(state, ref, typename or "unknown")
	end
end

---@param state lua.State
---@param L     any
---@param value any
toLua = function(state, L, value)
	local valueType = type(value)
	local raw = state._raw

	if valueType == "nil" then
		raw.pushnil(L)
	elseif valueType == "boolean" then
		raw.pushboolean(L, value)
	elseif valueType == "number" then
		state._pushNumber(L, value)
	elseif valueType == "string" then
		raw.pushlstring(L, value, #value)
	elseif valueType == "table" and isGuestValue(value) then
		if value._ref ~= LUA_NOREF then
			raw.rawgeti(L, state._registryIndex, value._ref)
		else
			raw.pushnil(L)
		end
	elseif valueType == "function" then
		local guestRef = state._guest_fns and state._guest_fns[value]
		if guestRef ~= nil then
			-- value is a makeCallable closure: push its guest ref directly
			raw.rawgeti(L, state._registryIndex, guestRef)
		else
			-- value is a plain host function; register it as a C closure on the
			-- guest state. bridge.push_callback does this entirely in C to avoid
			-- triggering LuaJIT's FFI re-entrancy crash (see bridge-design.md).
			local callbackId = bridge.register(value)
			table.insert(state._callbacks, { id = callbackId, fn = value })
			bridge.push_callback(
				state._slot,
				state._guest_num,
				callbackId,
				state._slow_dispatch_ref,
				state._jit_depth_num,
				state._chain_num
			)
		end
	elseif valueType == "table" then
		-- Plain host table → auto-coerce to a guest table via state:table().
		-- state:table() creates the table, populates it recursively (which
		-- re-enters toLua for nested tables/functions), and returns a
		-- lua.Table wrapper. Push the underlying guest table onto the stack.
		local t = state:table(value)
		raw.rawgeti(L, state._registryIndex, t._ref)
	else
		error("cannot push value of type '" .. valueType .. "' onto guest stack", 0)
	end
end

-- Slow path for cross-state calls when results include compound types
-- (tables, functions, userdata). Called from C via bound_call upvalue 4 when
-- bound_call detects a non-primitive result.
---@param guestState lua.State
---@param guestRef   integer
---@return lua.ValueType
local function callGuestSlow(guestState, guestRef, ...)
	local L = assert(guestState.L, "state is closed")
	local raw = guestState._raw
	local nargs = select("#", ...)
	local base = raw.gettop(L)
	raw.rawgeti(L, guestState._registryIndex, guestRef)
	for i = 1, nargs do toLua(guestState, L, ((select(i, ...)))) end
	local status = raw.pcall(L, nargs, LUA_MULTRET, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.settop(L, base)
		error(err, 0)
	end
	local nresults = raw.gettop(L) - base
	if nresults == 0 then
		raw.settop(L, base)
		return
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

-- Convert the results of a host -> guest call that sit on the guest stack at
-- `first .. first + n - 1`. bound_call calls this from C (upvalue 6) when a
-- result is compound, so the guest function runs one time only.
---@param guestState lua.State
---@param first      integer
---@param n          integer
---@return lua.ValueType
local function convertGuestResults(guestState, first, n)
	local L = assert(guestState.L, "state is closed")
	local out = {}
	for i = 1, n do out[i] = fromLua(guestState, L, first + i - 1) end
	return unpack(out, 1, n)
end

-- Registry refs for the two helpers the C bridge calls back into. Registered
-- once per lua-sys process and baked into every callable closure.
local callGuestSlowRef = bridge.register(callGuestSlow)
local convertResultsRef = bridge.register(convertGuestResults)

-- One slow dispatcher per lua.State: it knows the state that owns the
-- callback, so table arguments become proxies of the right state without a
-- thread lookup (guest coroutines share the registry of their state).
---@param state lua.State
---@return fun(guest: any, fn: function, ...: any): ...
function convert.makeDispatchSlow(state)
	return function(_, fn, ...)
		if state.L == nil then
			error("bridge: guest state is closed or unknown", 2)
		end
		local n = select("#", ...)
		local real = {}
		local k = 0
		local i = 1
		while i <= n do
			local v = select(i, ...)
			if v == COMPOUND_TAG then
				k = k + 1
				real[k] = Table._new(state, ((select(i + 1, ...))))
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
end

-- Host-callable function for a guest registry ref. bound_call is the callable
-- itself, so the JIT sees a lua_CFunction boundary (see bridge-design.md).
-- C adds fn:pcall() through a function metatable, and calls callGuestSlow
-- (upvalue 4) when a result is compound.
---@param state    lua.State
---@param guestRef integer
---@return function
makeCallable = function(state, guestRef)
	-- One callable per guest function. A new closure at each crossing costs a
	-- C closure, grows the map, and stops the caller from being compiled.
	local cache = state._guest_fn_by_ref
	if cache == nil then
		cache = {}
		state._guest_fn_by_ref = cache
	end
	local cached = cache[guestRef]
	if cached ~= nil then return cached end

	local boundCFn = bridge.make_callable(
		state._slot,
		state._guest_num,
		guestRef,
		state,
		callGuestSlowRef,
		state._closed_num,
		convertResultsRef
	)

	cache[guestRef] = boundCFn
	state._guest_fns = state._guest_fns or {}
	state._guest_fns[boundCFn] = guestRef
	return boundCFn
end

---@param valueModule { Table: table, Value: table }
function convert.bind(valueModule)
	Table = valueModule.Table
	Value = valueModule.Value
end

convert.fromLua = fromLua
convert.toLua = toLua
convert.makeCallable = makeCallable

return convert
