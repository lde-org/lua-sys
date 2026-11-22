-- high/state.lua — a guest lua_State of one lua.Lua runtime.
--
-- Every guest operation goes through the runtime's binding (`state._raw`,
-- `state._binding`) and the bridge slot of that runtime. The fields are
-- resolved once at creation, so the hot methods do not look up modules.

local ffi = require("ffi")
local bridge = require("lua-sys.bridge")
local chunk = require("lua-sys.high.chunk")
local convert = require("lua-sys.high.convert")
local hooks = require("lua-sys.high.hooks")
local value = require("lua-sys.high.value")

local Chunk = chunk.Chunk
local Table = value.Table

-- LuaJIT JIT mode constants for state:jitOff / state:jitOn / state:jitFlush
local LUAJIT_MODE_ENGINE = 0
local LUAJIT_MODE_FUNC = 2
local LUAJIT_MODE_OFF = 0x0000
local LUAJIT_MODE_ON = 0x0100
local LUAJIT_MODE_FLUSH = 0x0200

-- Default limit of a nested host <-> guest chain. One level needs about 450
-- bytes of C stack, and a thread stack can be 1 MB, so stay well below that.
local CHAIN_LIMIT_DEFAULT = 200

--- The pointer type of each ABI; the bindings declare `lua_State`,
--- `lua54_State` and `luau_State`.
---@type table<string, string>
local STATE_CASTS = { jit = "lua_State*", ["5.1"] = "lua_State*", ["5.4"] = "lua54_State*", luau = "luau_State*" }

---@type table<lua.Lua, integer>
local slots = setmetatable({}, { __mode = "k" })

--- The bridge slot of a runtime, or an error. The bridge caches the slot in
--- C; this cache saves the call and the argument conversion.
---@param rt lua.Lua
---@return integer
local function slotFor(rt)
	local slot = slots[rt]
	if slot ~= nil then return slot end
	local created, err = bridge.runtime(rt.handle, rt.abi)
	if created == nil then
		error("lua-sys: " .. tostring(err), 3)
	end
	slots[rt] = created
	return created
end

---@class lua.State
---@field L                ffi.cdata*?
---@field rt               lua.Lua
---@field _raw             table
---@field _binding         lua.Binding
---@field _registryIndex   integer
---@field _typeNames       table<integer, string>
---@field _pushNumber      fun(L: ffi.cdata*, n: number)
---@field _toNumber        fun(L: ffi.cdata*, idx: integer): number
---@field _slot            integer
---@field _guest_num       number?
---@field _owned           boolean
---@field _callbacks       { id: integer, fn: function }[]
---@field _guest_fns       table<function, integer>?
---@field _guest_fn_by_ref table<integer, function>?
---@field _chunk_refs      table<table, boolean>?
---@field _hook_ref        integer?
---@field _slow_dispatch_ref integer?
---@field _closed_flag     ffi.cdata*
---@field _closed_num      number
---@field _jit_depth       ffi.cdata*
---@field _jit_depth_num   number
---@field _chain_box       ffi.cdata*
---@field _chain_num       number
---@field _table_seen      table<table, boolean>?
local State = {}
State.__index = State

---@param rt    lua.Lua
---@param slot  integer
---@param L     ffi.cdata*
---@param owned boolean
---@return lua.State
local function buildState(rt, slot, L, owned)
	-- int[2] for the chain guard: [0] is the depth, [1] is the limit.
	local chain = ffi.new("int[2]")
	chain[1] = CHAIN_LIMIT_DEFAULT
	local closed = ffi.new("int[1]")
	local jitDepth = ffi.new("int[1]")
	local binding = rt._binding

	---@type lua.State
	local state = setmetatable({
		L = L,
		rt = rt,
		_raw = rt.raw,
		_binding = binding,
		_registryIndex = binding.REGISTRYINDEX,
		_typeNames = binding.typeNames,
		_pushNumber = binding.pushNumber,
		_toNumber = binding.toNumber,
		_slot = slot,
		_guest_num = tonumber(ffi.cast("intptr_t", L)),
		_owned = owned,
		_callbacks = {},
		_chunk_refs = setmetatable({}, { __mode = "k" }),
		-- int[1] flag: the C callable reads it, so a call after close()
		-- gives "state is closed" instead of using the freed pointer.
		_closed_flag = closed,
		_closed_num = tonumber(ffi.cast("intptr_t", closed)),
		-- int[1] counter: the bridge disables the JIT engine around a host
		-- callback and uses this to keep a nested callback from enabling it
		-- again while an outer callback still runs.
		_jit_depth = jitDepth,
		_jit_depth_num = tonumber(ffi.cast("intptr_t", jitDepth)),
		-- int[2]: the depth of the current host <-> guest chain and its limit.
		_chain_box = chain,
		_chain_num = tonumber(ffi.cast("intptr_t", chain))
	}, State)

	state._slow_dispatch_ref = bridge.register(convert.makeDispatchSlow(state))
	return state
end

--- A new guest state owned by this runtime.
---@param rt lua.Lua
---@return lua.State
function State.new(rt)
	local slot = slotFor(rt)
	local light = bridge.new_state(slot)
	if light == nil then
		error("lua-sys: the guest runtime failed to create a state", 3)
	end
	local ctor = STATE_CASTS[rt.abi]
	if ctor == nil then
		error("lua-sys: unknown ABI '" .. tostring(rt.abi) .. "'", 3)
	end
	return buildState(rt, slot, ffi.cast(ctor, light), true)
end

--- A guest state around an existing lua_State* of this runtime. Not owned:
--- close() only drops the registrations lua-sys made and never closes L.
---@param rt lua.Lua
---@param L  ffi.cdata*
---@return lua.State
function State.wrap(rt, L)
	if L == nil then
		error("wrap: expected an existing lua_State pointer", 3)
	end
	local slot = slotFor(rt)
	local ctor = STATE_CASTS[rt.abi]
	if ctor == nil then
		error("lua-sys: unknown ABI '" .. tostring(rt.abi) .. "'", 3)
	end
	return buildState(rt, slot, ffi.cast(ctor, L), false)
end

--- Load a chunk as a builder. Configure it, then run it with :eval() or
--- :call().
---
---@param code      string
---@param chunkName string?
---@return lua.Chunk
function State:load(code, chunkName)
	if self.L == nil then convert.closedError() end
	return Chunk._new(self, code, chunkName)
end

--- Compile and evaluate a chunk now, the same as
--- `state:load(code, chunkName):eval()`. A bare expression gets a `return`
--- wrapper. Prefix chunkName with "@" for a file path.
---@param code      string
---@param chunkName string?
---@return lua.ValueType
function State:eval(code, chunkName)
	if self.L == nil then convert.closedError() end
	return self:load(code, chunkName):eval()
end

---@return lua.Table
function State:globals()
	local L = self.L
	if L == nil then convert.closedError() end
	local raw = self._raw
	self._binding.pushGlobals(L)
	local globals = convert.fromLua(self, L, -1)
	raw.pop(L, 1)
	return globals --[[@as lua.Table]]
end

-- Fill a guest table from a plain host table, with cycle detection through the
-- `seen` set. File-local: State:table must not make a closure per call.
---@param tbl  lua.Table
---@param init table
---@param seen table<table, boolean> -- host tables on the current path
local function populateGuestTable(tbl, init, seen)
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
	seen[init] = nil -- done with this table; the same table as a sibling value
	-- (not a back-edge) is correct
end

--- Create a guest table. `init` is an optional plain host table: primitives
--- are copied, a nested plain table becomes a guest table, a lua.Value keeps
--- its reference, and a host function becomes a callback.
---@param init table?
---@return lua.Table
function State:table(init)
	local L = self.L
	if L == nil then convert.closedError() end
	local raw = self._raw
	raw.createtable(L, 0, init and 16 or 0)
	local ref = raw.ref(L, self._registryIndex)
	local tbl = Table._new(self, ref)

	if init ~= nil then
		if type(init) ~= "table" then
			error("state:table() init argument must be a table, got " .. type(init), 2)
		end
		-- The seen set lives on the State, so it survives the recursive
		-- state:table() calls of toLua coercion. pcall cleans it up on error.
		local topLevel = self._table_seen == nil
		local seen = self._table_seen or {}
		if topLevel then self._table_seen = seen end
		if topLevel then
			local ok, err = pcall(populateGuestTable, tbl, init, seen)
			self._table_seen = nil
			if not ok then error(err, 2) end
		else
			populateGuestTable(tbl, init, seen)
		end
	end

	return tbl
end

-- ─── JIT control ─────────────────────────────────────────────────────────

-- Shared helper: apply a per-function JIT mode to a guest callable.
---@param state lua.State
---@param ref   integer
---@param mode  integer
local function setFuncJitMode(state, ref, mode)
	local L = state.L
	if L == nil then error("state is closed", 2) end
	local raw = state._raw
	raw.rawgeti(L, state._registryIndex, ref)
	raw.jit_setmode(L, -1, LUAJIT_MODE_FUNC + mode)
	raw.pop(L, 1)
end

---@param state  lua.State
---@param method string
local function checkJit(state, method)
	if state.L == nil then convert.closedError() end
	if not state.rt.caps.jit then
		error(method .. ": not supported by " .. state.rt.version.string, 3)
	end
end

--- Disable the JIT engine of the guest state, or of one guest function when
--- `fn` is a callable of this state. Returns self for chaining. A hook needs
--- interpreted code, and setHook does this for the state while installed.
---@param fn function?
---@return lua.State
function State:jitOff(fn)
	checkJit(self, "jitOff")
	if fn == nil then
		self._raw.jit_setmode(self.L, 0, LUAJIT_MODE_ENGINE + LUAJIT_MODE_OFF)
	else
		local ref = self._guest_fns and self._guest_fns[fn]
		if ref == nil then
			error("jitOff: fn must be a guest callable obtained from this state", 2)
		end
		setFuncJitMode(self, ref, LUAJIT_MODE_OFF)
	end
	return self
end

--- Enable the JIT engine of the guest state, or of one guest function when
--- `fn` is given. Returns self for chaining.
---@param fn function?
---@return lua.State
function State:jitOn(fn)
	checkJit(self, "jitOn")
	if fn == nil then
		self._raw.jit_setmode(self.L, 0, LUAJIT_MODE_ENGINE + LUAJIT_MODE_ON)
	else
		local ref = self._guest_fns and self._guest_fns[fn]
		if ref == nil then
			error("jitOn: fn must be a guest callable obtained from this state", 2)
		end
		setFuncJitMode(self, ref, LUAJIT_MODE_ON)
	end
	return self
end

--- Flush the compiled traces of the guest state.
function State:jitFlush()
	checkJit(self, "jitFlush")
	self._raw.jit_setmode(self.L, 0, LUAJIT_MODE_ENGINE + LUAJIT_MODE_FLUSH)
end

--- Limit the depth of a nested host <-> guest call chain. Each level of the
--- chain uses C stack, so a chain that is too deep stops the process. The
--- default is 200 levels, and the value 0 removes the limit.
---@param levels integer
function State:setChainLimit(levels)
	if self.L == nil then convert.closedError() end
	self._chain_box[1] = levels or 0
end

--- The current depth of the host <-> guest chain, for diagnostics.
---@return integer
function State:chainDepth()
	if self.L == nil then convert.closedError() end
	return tonumber(self._chain_box[0])
end

--- The number of bytes that the guest state holds now. The count comes from
--- the allocator of the state, so it is exact. A wrapped state has no
--- accounting: lua-sys did not create it.
---@return integer
function State:memory()
	if self.L == nil then convert.closedError() end
	if not self._owned then
		error("memory: not supported on a wrapped state", 2)
	end
	return tonumber(bridge.memory_used(self._slot, self._guest_num))
end

--- Limit the memory of the guest state to `bytes`. An allocation that would
--- pass the limit fails, and the guest gets the error "not enough memory".
--- The value 0 removes the limit, which is the default.
---@param bytes integer
function State:setMemoryLimit(bytes)
	if self.L == nil then convert.closedError() end
	if not self._owned then
		error("setMemoryLimit: not supported on a wrapped state", 2)
	end
	bridge.set_memory_limit(self._slot, self._guest_num, bytes or 0)
end

---@class lua.HeapSnapshot
---@field attributed number
---@field objects    number
---@field retained   table<string, number>
---@field counts     table<string, number>
---@field parents    table<string, string|false>

--- Walk every object that is reachable in the guest state and give each one
--- to the first path that reaches it, such as `init.lua:local cache.entries[]`.
--- The walk is C code, adds no garbage to the guest and runs no metamethods,
--- so it is safe from a hook or a profiler callback.
---@param opts { maxDepth: integer?, maxPaths: integer? }?
---@return lua.HeapSnapshot
function State:heapSnapshot(opts)
	if self.L == nil then convert.closedError() end
	return bridge.heap_snapshot(self._slot, self._guest_num, opts and opts.maxDepth or 10, opts and opts.maxPaths or 20000)
end

function State:close()
	local L = self.L
	if L == nil then return end

	self._closed_flag[0] = 1

	if self._hook_ref ~= nil then
		bridge.remove_hook(self._slot, self._guest_num)
		bridge.unregister(self._hook_ref)
		self._hook_ref = nil
	end

	for _, cb in ipairs(self._callbacks) do bridge.unregister(cb.id) end
	self._callbacks = {}

	if self._slow_dispatch_ref ~= nil then
		bridge.unregister(self._slow_dispatch_ref)
		self._slow_dispatch_ref = nil
	end

	-- Drop the registry refs of compiled chunks before the state goes away.
	if self._chunk_refs ~= nil then
		for cached in pairs(self._chunk_refs) do chunk.drop(cached) end
	end

	if self._owned then
		-- No cap while closing: the state releases its memory block by block.
		bridge.set_memory_limit(self._slot, self._guest_num, 0)
		bridge.close_state(self._slot, self._guest_num)
	end

	self.L = nil
	self._guest_num = nil
	self._guest_fns = nil
	self._guest_fn_by_ref = nil
	self._chunk_refs = nil
end

hooks.install(State)

---@param rt lua.Lua
---@return lua.State
local function new(rt)
	return State.new(rt)
end

---@param rt lua.Lua
---@param L  ffi.cdata*
---@return lua.State
local function wrap(rt, L)
	return State.wrap(rt, L)
end

return { State = State, new = new, wrap = wrap, closedError = convert.closedError }
