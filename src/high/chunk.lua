-- high/chunk.lua — a loaded guest chunk and its runner.
--
-- A chunk compiles at the first run, then caches the registry ref of the
-- compiled function. A new name or mode drops the cache, so the next run
-- compiles again with the new debug information.

local LUA_OK = 0
local LUA_MULTRET = -1
local LUA_YIELD = 1

local toLua, fromLua, closedError

local chunk = {}

-- setMode words to the loader mode letters
---@type table<string, "t"|"b"|"bt">
local CHUNK_MODES = {
	text = "t",
	["t"] = "t",
	bytecode = "b",
	binary = "b",
	["b"] = "b",
	both = "bt",
	["bt"] = "bt",
	["tb"] = "bt"
}

---@type table<"t"|"b"|"bt", "text"|"bytecode"|"both">
local CHUNK_MODE_NAMES = { t = "text", b = "bytecode", bt = "both" }

---@class lua.Chunk
---@field _state     lua.State
---@field _code      string
---@field _chunkName string?
---@field _chunkMode "t"|"b"|"bt"?
---@field _fnRef     integer?
---@field _fnName    string?
---@field _fnMode    "t"|"b"|"bt"?
local Chunk = {}
Chunk.__index = Chunk

---@param state lua.State
---@param code  string
---@param name  string?
---@return lua.Chunk
function Chunk._new(state, code, name)
	return setmetatable({ _state = state, _code = code, _chunkName = name }, Chunk)
end

-- Drop the compiled function of a chunk, so the next run compiles again. A
-- file-local function: the chunk methods must not make a closure per call.
---@param chunk lua.Chunk
local function dropChunkCache(chunk)
	local ref = chunk._fnRef
	if ref ~= nil then
		local state = chunk._state
		local L = state.L
		if L ~= nil then
			state._raw.unref(L, state._registryIndex, ref)
			if state._chunk_refs ~= nil then state._chunk_refs[chunk] = nil end
		end
		chunk._fnRef = nil
	end
end

---@param chunk lua.Chunk
function Chunk.__gc(chunk)
	dropChunkCache(chunk)
end

--- Set the chunk name for debug info, and return self for chaining. Prefix
--- with "@" for a file path so guest debug.getinfo reports the source.
---@param name string
---@return lua.Chunk
function Chunk:setName(name)
	if name ~= self._chunkName then dropChunkCache(self) end
	self._chunkName = name
	return self
end

--- Restrict the format that the chunk accepts, and return self for chaining.
--- `mode` is "text", "bytecode" or "both" (the default). The Lua letters "t",
--- "b" and "bt" are also correct, and "binary" means "bytecode".
---@param mode "text"|"bytecode"|"both"|"binary"|"t"|"b"|"bt"|"tb"
---@return lua.Chunk
function Chunk:setMode(mode)
	if type(mode) ~= "string" then
		error('setMode: mode must be "text", "bytecode" or "both", got ' .. type(mode), 2)
	end
	local mapped = CHUNK_MODES[mode:lower()]
	if mapped == nil then
		error('setMode: unknown mode "' .. mode .. '" (expected "text", "bytecode" or "both")', 2)
	end
	if mapped ~= self._chunkMode then dropChunkCache(self) end
	self._chunkMode = mapped
	return self
end

--- The format that this chunk accepts: "text", "bytecode" or "both".
---@return "text"|"bytecode"|"both"
function Chunk:getMode()
	return CHUNK_MODE_NAMES[self._chunkMode or "bt"]
end

--- True when the source starts with the escape byte of a precompiled chunk.
--- Use it to refuse untrusted bytecode. LuaJIT bytecode starts with "\27LJ".
---@return boolean
function Chunk:isBytecode()
	return self._state._binding.isBytecode(self._code)
end

-- Internal: compile the chunk and push the function onto the guest stack.
-- Leaves the compiled function at the top of the guest stack on success.
-- Returns the stack base (the index of the function) so the caller can
-- protect-call it.
---@return any L
---@return integer fnIndex
function Chunk:_compile()
	local state = self._state
	local L = state.L
	if L == nil then closedError() end
	local raw = state._raw
	local binding = state._binding
	local code = self._code
	local name = self._chunkName
	local mode = self._chunkMode

	-- Run the function that this chunk compiled with the same name and mode
	-- before. A chunk compiles one time, not at each run.
	local ref = self._fnRef
	if ref ~= nil and self._fnName == name and self._fnMode == mode then
		raw.rawgeti(L, state._registryIndex, ref)
		return L, raw.gettop(L)
	end

	if type(code) ~= "string" then code = tostring(code) end
	mode = mode or "bt"

	local bytecode = binding.isBytecode(code)
	if mode == "b" and not bytecode then
		error("attempt to load chunk with wrong mode", 0)
	elseif mode == "t" and bytecode then
		error("attempt to load chunk with wrong mode", 0)
	end

	-- Load with the binding loader: it takes a length, so bytecode with null
	-- bytes inside is not cut short, and it applies the mode. Without a name,
	-- the source is also the chunk name, which is what luaL_loadstring does.
	local status
	if bytecode then
		-- Do not put "return " before bytecode: that wrapper is text that
		-- contains binary data, and the guest must load the bytecode itself.
		status = binding.load(L, code, name or code, mode)
	else
		local wrapped = "return " .. code
		status = binding.load(L, wrapped, name or wrapped, mode)
		if status ~= LUA_OK then
			raw.pop(L, 1)
			status = binding.load(L, code, name or code, mode)
		end
	end
	if status ~= LUA_OK then
		local err = raw.tolstring(L, -1)
		raw.pop(L, 1)
		error(err, 0)
	end
	local fnIdx = raw.gettop(L)
	raw.pushvalue(L, fnIdx)
	self._fnRef = raw.ref(L, state._registryIndex)
	self._fnName = name
	self._fnMode = self._chunkMode
	if state._chunk_refs ~= nil then state._chunk_refs[self] = true end
	return L, fnIdx
end

--- Compile and evaluate the chunk with the given arguments (accessible
--- as `...` inside the guest), returning the first result.
---
--- If no value is returned by the chunk, returns nil.
---@param ... any
---@return lua.ValueType
function Chunk:eval(...)
	local state = self._state
	if state.L == nil then closedError() end
	local raw = state._raw
	local L, fnIndex = self:_compile()
	local nargs = select("#", ...)
	for i = 1, nargs do toLua(state, L, ((select(i, ...)))) end
	local base = fnIndex - 1
	local status = raw.pcall(L, nargs, LUA_MULTRET, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.settop(L, base)
		error(err, 0)
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
	local state = self._state
	if state.L == nil then closedError() end
	local raw = state._raw
	local L, fnIndex = self:_compile()
	local nargs = select("#", ...)
	for i = 1, nargs do toLua(state, L, ((select(i, ...)))) end
	local base = fnIndex - 1
	local status = raw.pcall(L, nargs, 0, 0)
	if status ~= LUA_OK and status ~= LUA_YIELD then
		local err = raw.tolstring(L, -1)
		raw.settop(L, base)
		error(err, 0)
	end
	raw.settop(L, base)
end

--- Like :eval(), but return `true, ...` (all results) or `false, err` instead
--- of raising. A syntax error is caught too.
---@param ... any
---@return boolean, lua.ValueType
function Chunk:pcall(...)
	if self._state.L == nil then closedError() end
	return Chunk._pcall(self, false, ...)
end

--- Like :pcall(), but the error string also has a guest stack traceback. The
--- guest debug.traceback runs as the error handler, so the frames are complete
--- before the stack unwinds.
---@param ... any
---@return boolean, lua.ValueType
function Chunk:xpcall(...)
	if self._state.L == nil then closedError() end
	return Chunk._pcall(self, true, ...)
end

-- Shared implementation of pcall / xpcall.
---@param chunk          lua.Chunk
---@param withTraceback  boolean
---@return boolean, lua.ValueType
function Chunk._pcall(chunk, withTraceback, ...)
	local state = chunk._state
	local raw = state._raw
	local ok, a, b = pcall(chunk._compile, chunk)
	if not ok then return false, a end
	local L = a
	local fnIndex = b --[[@as integer]]
	local base = fnIndex - 1

	-- debug.traceback goes below the function as the error handler, so the
	-- traceback is complete before unwinding. errfunc 0 means "no handler".
	local errfunc = 0
	local installed = false
	if withTraceback then
		raw.getglobal(L, "debug")
		raw.getfield(L, -1, "traceback")
		raw.remove(L, -2)
		if state._typeNames[raw.type(L, -1)] == "function" then
			raw.insert(L, -2) -- [..base..][traceback][fn]
			errfunc = base + 1
			installed = true
		else
			raw.pop(L, 1) -- no guest debug library: keep the bare message
		end
	end

	local nargs = select("#", ...)
	for i = 1, nargs do toLua(state, L, ((select(i, ...)))) end

	local status = raw.pcall(L, nargs, LUA_MULTRET, errfunc)
	local restore = base
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

---@param to   fun(state: lua.State, L: any, value: any)
---@param from fun(state: lua.State, L: any, index: integer): lua.ValueType
---@param closed fun()
function chunk.bind(to, from, closed)
	toLua, fromLua, closedError = to, from, closed
end

chunk.Chunk = Chunk
chunk.drop = dropChunkCache

return chunk
