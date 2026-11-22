-- high/frame.lua — a stack frame from info:stack().
--
-- A frame is valid while the thread is paused at the hook: the frame holds the
-- hook info table, and the bridge clears _hook_active when the hook returns.
-- The debug calls go through the binding helpers, which hide the different
-- 5.1/5.4/Luau lua_Debug layouts.

local ffi = require("ffi")
local bridge = require("lua-sys.bridge")
local convert = require("lua-sys.high.convert")

local LUA_OK = 0
local LUA_MULTRET = -1
local LUA_YIELD = 1

---@class lua.Frame
---@field thread          ffi.cdata*
---@field level           integer
---@field _info           table?
---@field name            string?
---@field namewhat        string?
---@field what            string?
---@field source          string?
---@field short_src       string
---@field currentline     integer
---@field linedefined     integer
---@field lastlinedefined integer
---@field nups            integer
local Frame = {}
Frame.__index = Frame

-- Internal: resolve the owning lua.State wrapper for a frame. The hook
-- wrapper (high/hooks.lua) records the state of every thread an event fires
-- on, so frames of a coroutine resolve to the same state as its main thread.
---@param frame lua.Frame
---@return lua.State?
local function frameGuestState(frame)
	local info = frame._info
	if info == nil or rawget(info, "_hook_active") ~= true then return nil end
	local state = convert.ownerOf(frame.thread)
	if state == nil or state.L == nil then return nil end
	return state
end

-- Resolve a frame for a method call: the owner state and the thread, or nil
-- for a stale frame. File-local: the methods make no closure per call.
---@param frame lua.Frame
---@return lua.State? guestState
---@return ffi.cdata* L
local function frameContext(frame)
	local guestState = frameGuestState(frame)
	if guestState == nil then return nil end
	return guestState, frame.thread
end

--- List this frame's active locals as { name, value } pairs, in order.
---@return { name: string, value: any }[]
function Frame:locals()
	local state, L = frameContext(self)
	if state == nil then return {} end
	local binding = state._binding
	local raw = state._raw
	local out = {}
	for i = 1, 200 do
		local name = binding.getlocal(L, self.level, i)
		if name == nil then break end
		out[i] = { name = name, value = convert.fromLua(state, L, -1) }
		raw.settop(L, -2)
	end
	return out
end

---@param name string
---@return any
function Frame:getLocal(name)
	local state, L = frameContext(self)
	if state == nil then return nil end
	local binding = state._binding
	local raw = state._raw
	for i = 1, 200 do
		local lname = binding.getlocal(L, self.level, i)
		if lname == nil then return nil end
		if lname == name then
			local value = convert.fromLua(state, L, -1)
			raw.settop(L, -2)
			return value
		end
		raw.settop(L, -2)
	end
	return nil
end

--- Assign to a local of the frame. Only active locals can be written.
---@param name  string
---@param value any
---@return boolean
function Frame:setLocal(name, value)
	local state, L = frameContext(self)
	if state == nil then return false end
	local binding = state._binding
	local raw = state._raw
	for i = 1, 200 do
		local lname = binding.getlocal(L, self.level, i)
		if lname == nil then return false end
		raw.settop(L, -2) -- pop the read value
		if lname == name then
			convert.toLua(state, L, value)
			binding.setlocal(L, self.level, i) -- pops the value, assigns the local
			return true
		end
	end
	return false
end

--- List this frame's function's upvalues as { name, value } pairs.
---@return { name: string, value: any }[]
function Frame:upvalues()
	local state, L = frameContext(self)
	if state == nil then return {} end
	local binding = state._binding
	local raw = state._raw
	if not binding.pushFrameFunction(L, self.level) then return {} end
	local fnIdx = raw.gettop(L)
	local out = {}
	for i = 1, 200 do
		local name = raw.getupvalue(L, fnIdx, i)
		if name == nil then break end
		out[i] = { name = ffi.string(name), value = convert.fromLua(state, L, -1) }
		raw.settop(L, -2)
	end
	raw.settop(L, fnIdx - 1) -- pop the function
	return out
end

---@param name string
---@return any
function Frame:getUpvalue(name)
	local state, L = frameContext(self)
	if state == nil then return nil end
	local binding = state._binding
	local raw = state._raw
	if not binding.pushFrameFunction(L, self.level) then return nil end
	local fnIdx = raw.gettop(L)
	for i = 1, 200 do
		local uname = raw.getupvalue(L, fnIdx, i)
		if uname == nil then break end
		if ffi.string(uname) == name then
			local value = convert.fromLua(state, L, -1)
			raw.settop(L, -2)
			raw.settop(L, fnIdx - 1)
			return value
		end
		raw.settop(L, -2)
	end
	raw.settop(L, fnIdx - 1)
	return nil
end

--- Assign to an upvalue of the frame's function.
---@param name  string
---@param value any
---@return boolean
function Frame:setUpvalue(name, value)
	local state, L = frameContext(self)
	if state == nil then return false end
	local binding = state._binding
	local raw = state._raw
	if not binding.pushFrameFunction(L, self.level) then return false end
	local fnIdx = raw.gettop(L)
	for i = 1, 200 do
		local uname = raw.getupvalue(L, fnIdx, i)
		if uname == nil then break end
		raw.settop(L, -2)
		if ffi.string(uname) == name then
			convert.toLua(state, L, value)
			raw.setupvalue(L, fnIdx, i)
			raw.settop(L, fnIdx - 1)
			return true
		end
	end
	raw.settop(L, fnIdx - 1)
	return false
end

--- Evaluate `code` with the locals and upvalues of the frame in scope. The
--- environment chains to the function environment through __index and
--- __newindex, and assignments to existing locals and upvalues go back into
--- the frame, so `frame:eval("x = 42")` changes the running program. Returns
--- `true, firstResult` or `false, err`. Call it inside the hook callback.
---@param code string
---@return boolean, lua.ValueType
function Frame:eval(code)
	local state, L = frameContext(self)
	if state == nil then
		return false, "no frame at stack level " .. tostring(self.level)
	end
	local raw = state._raw
	local binding = state._binding

	-- Env: a fresh guest table seeded with the frame's active locals.
	raw.createtable(L, 0, 32)
	local envIdx = raw.gettop(L)
	for i = 1, 200 do
		local lname = binding.getlocal(L, self.level, i)
		if lname == nil then break end
		raw.pushstring(L, lname) -- [env][value][key]
		raw.pushvalue(L, -2) -- [env][value][key][value]
		raw.settable(L, envIdx) -- [env][value]
		raw.pop(L, 1) -- [env]
	end

	-- ... and the frame function's upvalues.
	if not binding.pushFrameFunction(L, self.level) then
		raw.settop(L, envIdx - 1)
		return false, "no frame at stack level " .. tostring(self.level)
	end
	local fnIdx = raw.gettop(L)
	for i = 1, 200 do
		local uname = raw.getupvalue(L, fnIdx, i)
		if uname == nil then break end
		raw.pushstring(L, ffi.string(uname)) -- [fn][value][key]
		raw.pushvalue(L, -2) -- [fn][value][key][value]
		raw.settable(L, envIdx) -- [fn][value]
		raw.pop(L, 1) -- [fn]
	end

	-- Chain reads/writes of other names to the frame function's environment.
	binding.getFunctionEnv(L, fnIdx) -- [fn][fenv]
	raw.createtable(L, 0, 2) -- [fn][fenv][mt]
	raw.pushvalue(L, -2)
	raw.setfield(L, -2, "__index") -- [fn][fenv][mt]
	raw.pushvalue(L, -2)
	raw.setfield(L, -2, "__newindex")
	raw.setmetatable(L, envIdx)
	raw.settop(L, fnIdx - 1) -- drop [fn][fenv]; env stays at envIdx

	-- Load "return <code>", falling back to plain code (like Chunk:_compile).
	local wrapped = "return " .. code
	local status = binding.load(L, wrapped, nil, "t")
	if status ~= LUA_OK then
		raw.pop(L, 1)
		status = binding.load(L, code, nil, "t")
	end
	if status ~= LUA_OK then
		local err = raw.tolstring(L, -1)
		raw.pop(L, 1)
		raw.settop(L, envIdx - 1)
		return false, err
	end

	local chunkIndex = raw.gettop(L)
	raw.pushvalue(L, envIdx) -- [chunk][env]
	binding.setChunkEnv(L, chunkIndex) -- pops the env
	local pstatus = raw.pcall(L, 0, LUA_MULTRET, 0)
	if pstatus ~= LUA_OK and pstatus ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.settop(L, envIdx - 1)
		return false, err
	end

	-- Convert the results (they sit above the env table) before any stack
	-- churn below.
	local nresults = raw.gettop(L) - envIdx
	local results = {}
	for i = 1, nresults do results[i] = convert.fromLua(state, L, envIdx + i) end

	-- Write assignments to existing locals/upvalues back to the frame.
	for i = 1, 200 do
		local lname = binding.getlocal(L, self.level, i)
		if lname == nil then break end
		raw.settop(L, -2) -- pop the read value
		raw.getfield(L, envIdx, lname) -- push env[lname]
		binding.setlocal(L, self.level, i) -- pop + assign to the local
	end
	if binding.pushFrameFunction(L, self.level) then
		local fn2 = raw.gettop(L)
		for i = 1, 200 do
			local uname = raw.getupvalue(L, fn2, i)
			if uname == nil then break end
			raw.settop(L, -2)
			raw.getfield(L, envIdx, ffi.string(uname))
			raw.setupvalue(L, fn2, i)
		end
		raw.settop(L, fn2 - 1)
	end

	raw.settop(L, envIdx - 1)
	if nresults == 0 then return true end
	return true, results[1]
end

-- Frames returned by info:stack() carry this class as their metatable.
bridge.set_frame_meta(Frame)

return { Frame = Frame }
