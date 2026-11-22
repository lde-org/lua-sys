-- abi/jit.lua — LuaJIT: the Lua 5.1 API plus luaJIT_* and the 5.2
-- backports LuaJIT exports. Shares abi/lua51.lua's cdefs and binding.
--
-- The extra declarations live in abi/lua51.lua's cdef block: an image binds
-- through the real `lua_*` names, and the LuaJIT-only fields are added here
-- as direct cdata calls.

local ffi = require("ffi")
local lua51 = require("lua-sys.abi.lua51")

---@param C ffi.namespace*
---@param name string
local function field(C, name)
	local ok, value = pcall(function() return C[name] end)
	if ok then return value --[[@as ffi.cdata*?]] end
	return nil
end

---@param C ffi.namespace*
---@param name string
---@return ffi.cdata*
local function required(C, name)
	local fn = field(C, name)
	if fn == nil then error("lua-sys: the LuaJIT image lacks " .. name, 3) end
	return fn
end

local abi = { name = "jit" }

---@param img lua.Image
function abi.probe(img)
	return img:symbol("luaJIT_setmode") ~= nil
end

---@param img lua.Image
---@return lua.Binding
function abi.bind(img)
	local binding = lua51.bind(img)
	local C = assert(binding._clib) --[[@as ffi.namespace*]]
	local raw = binding.raw

	raw.copy = required(C, "lua_copy")
	local isyieldable = required(C, "lua_isyieldable")
	raw.tointegerx = required(C, "lua_tointegerx")
	raw.tonumberx = required(C, "lua_tonumberx")
	raw.upvalueid = required(C, "lua_upvalueid")
	raw.upvaluejoin = required(C, "lua_upvaluejoin")
	raw.loadx = required(C, "lua_loadx")
	raw.loadbufferx = required(C, "luaL_loadbufferx")
	raw.loadfilex = required(C, "luaL_loadfilex")
	raw.setfuncs = required(C, "luaL_setfuncs")
	raw.lsetmetatable = required(C, "luaL_setmetatable")
	raw.traceback = required(C, "luaL_traceback")
	raw.openBit = required(C, "luaopen_bit")
	raw.openFFI = required(C, "luaopen_ffi")
	raw.openJIT = required(C, "luaopen_jit")
	raw.openStringBuffer = required(C, "luaopen_string_buffer")

	local testudata = required(C, "luaL_testudata")

	---@param L lua.raw.State
	---@return boolean
	function raw.isyieldable(L) return isyieldable(L) ~= 0 end

	---@param L lua.raw.State
	---@param ud integer
	---@param tname string
	---@return boolean
	function raw.testudata(L, ud, tname) return testudata(L, ud, tname) ~= 0 end

	-- JIT extensions (luaJIT_*)
	raw.jit_setmode = required(C, "luaJIT_setmode")
	raw.jit_profile_start = required(C, "luaJIT_profile_start")
	raw.jit_profile_stop = required(C, "luaJIT_profile_stop")

	local loadbufferx = required(C, "luaL_loadbufferx")

	--- Load with LuaJIT's mode-aware loader.
	---@param L lua.raw.State
	---@param code string
	---@param chunkName string?
	---@param mode "t"|"b"|"bt"|nil
	---@return integer
	function binding.load(L, code, chunkName, mode)
		return loadbufferx(L, code, #code, chunkName or code, mode or "bt")
	end

	local dumpstack = required(C, "luaJIT_profile_dumpstack")
	local dumpstackLength = ffi.new("size_t[1]")

	--- The profiler buffer is valid until the next call; copy immediately.
	---@param L lua.raw.State
	---@param fmt string
	---@param depth integer
	---@return string
	function raw.jit_profile_dumpstack(L, fmt, depth)
		local p = dumpstack(L, fmt, depth, dumpstackLength)
		if p == nil then return "" end
		return ffi.string(ffi.cast("const char *", p), dumpstackLength[0])
	end

	binding.name = "jit"
	binding.caps = {
		jit = true,
		hooks = "full",
		env = "fenv",
		integers = false,
		source = true
	}

	return binding --[[@as lua.Binding]]
end

return abi
