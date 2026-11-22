-- runtime.lua — a bound Lua runtime: its version, capabilities, raw C API and
-- the bridge inputs the high layer needs.
--
-- One Lua object exists per (image, ABI) pair, so `lua:lde()`,
-- `lua:bundled(version)`, `lua:vendored(version)` and `lua:open(path)` return
-- the same handle for the same runtime.

local ffi = require("ffi")

---@class lua.Version
---@field name "LuaJIT"|"Lua"|"Luau"
---@field abi "jit"|"5.1"|"5.4"|"luau"
---@field major integer
---@field minor integer
---@field release string?
---@field jit boolean
---@field string string
local Version = {}
Version.__index = Version

function Version:__tostring() return self.string end

---@class lua.Caps
---@field jit boolean
---@field hooks "full"|"line"|nil
---@field env "fenv"|"_ENV"
---@field integers boolean
---@field source boolean

---@class lua.Lua
---@field version lua.Version
---@field abi "jit"|"5.1"|"5.4"|"luau"
---@field caps lua.Caps
---@field raw table # lua.Raw: the C API table of this runtime's binding
---@field handle ffi.cdata*? # lightuserdata-sized image handle; nil for the running LuaJIT
---@field _binding lua.Binding
---@field _image lua.Image
local Lua = {}
Lua.__index = Lua

function Lua:__tostring() return self.version.string end

-- Probe order from the contract: the Luau and LuaJIT senders are distinct
-- enough to test first, then the 5.4 and 5.1 ABI markers. The ABI name is
-- what a Lua handle reports; the module name is where its binding lives
-- (`5.4` is `abi/lua54.lua`).
local MODULES = {
	{ name = "luau", module = "luau" },
	{ name = "jit", module = "jit" },
	{ name = "5.4", module = "lua54" },
	{ name = "5.1", module = "lua51" }
}

---@class lua.Binding
---@field name string
---@field raw table # lua.Raw
---@field REGISTRYINDEX integer
---@field typeNames table<integer, string>
---@field caps lua.Caps
---@field pushNumber fun(L: ffi.cdata*, n: number)
---@field toNumber fun(L: ffi.cdata*, idx: integer): number
---@field pushGlobals fun(L: ffi.cdata*)
---@field load fun(L: ffi.cdata*, code: string, chunkName: string?, mode: "t"|"b"|"bt"|nil): integer
---@field isBytecode fun(code: string): boolean
---@field getlocal fun(L: ffi.cdata*, level: integer, n: integer): string?
---@field setlocal fun(L: ffi.cdata*, level: integer, n: integer): string?
---@field pushFrameFunction fun(L: ffi.cdata*, level: integer): boolean
---@field getFunctionEnv fun(L: ffi.cdata*, fnIndex: integer)
---@field setChunkEnv fun(L: ffi.cdata*, chunkIndex: integer)
---@field _clib ffi.namespace*?

local runtime = { Version = Version, Caps = {}, Lua = Lua }

---@type table<string, table|false>
local abiModules = {}

--- Load one ABI module, or nil when the feature is not bundled. A module
--- that exists but fails to load raises: masking that as "feature off" would
--- hide real errors.
---@param moduleName string
---@return table?
local function loadAbi(moduleName)
	local cached = abiModules[moduleName]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end
	local ok, module = pcall(require, "lua-sys.abi." .. moduleName)
	if not ok then
		if type(module) == "string" then
			local reason = module --[[@as string]]
			if reason:find("not found", 1, true) then
				abiModules[moduleName] = false
				return nil
			end
		end
		error(module, 0)
	end
	---@cast module table
	abiModules[moduleName] = module
	return module
end

--- The ABI name that can bind `img`, or nil when no bundled ABI matches.
---@param img lua.Image
---@return string? name
---@return table? abi
function runtime.abiOf(img)
	for _, entry in ipairs(MODULES) do
		local module = loadAbi(entry.module)
		if module ~= nil and module.probe(img) then return entry.name, module end
	end
	return nil
end

---@param release string?
---@return string
local function luaJitString(release)
	return release ~= nil and "LuaJIT " .. release or "LuaJIT"
end

--- LuaJIT reports its version only in its `jit` library, so a second copy
--- needs a temporary state to read it. The running one already has it.
---@param binding lua.Binding
---@param img lua.Image
---@return string?
local function luaJitRelease(binding, img)
	if img.isRunning and jit ~= nil then
		return jit.version:match("^LuaJIT%s+(.+)$") or jit.version
	end
	local raw = binding.raw
	local L = raw.lnewstate()
	if L == nil then return nil end
	local ok, value = pcall(function()
		raw.openlibs(L)
		raw.getglobal(L, "jit")
		raw.getfield(L, -1, "version")
		return raw.tolstring(L, -1)
	end)
	raw.close(L)
	if not ok or type(value) ~= "string" then return nil end
	return value:match("^LuaJIT%s+(.+)$") or value
end

--- Lua 5.1/5.4 carry their release in the exported `lua_ident` string; a
--- stripped build falls back to the numeric API version.
---@param binding lua.Binding
---@param img lua.Image
---@return string
---@return integer
---@return integer
local function luaRelease(binding, img)
	local release
	local ident = img:symbol("lua_ident")
	if ident ~= nil then
		local text = ffi.string(ffi.cast("const char *", ident))
		release = text:match("Lua (%d+%.%d+%.%d+)")
	end
	local major, minor
	if release ~= nil then
		major, minor = release:match("(%d+)%.(%d+)")
		major, minor = tonumber(major), tonumber(minor)
	end
	if major == nil or minor == nil then
		local ok, value = pcall(|| -> tonumber(binding.raw.version(nil)))
		if ok and type(value) == "number" then
			major = math.floor(value / 100)
			minor = value % 100
		end
	end
	return release or (major ~= nil and (major .. "." .. minor) or "?"), major or 0, minor or 0
end

---@param abiName "jit"|"5.1"|"5.4"|"luau"
---@param binding lua.Binding
---@param img lua.Image
local function detectVersion(abiName, binding, img)
	if abiName == "luau" then
		return setmetatable(
			{ name = "Luau", abi = "luau", major = 0, minor = 0, release = nil, jit = false, string = "Luau" },
			Version
		) --[[@as lua.Version]]
	end
	if abiName == "jit" then
		local release = luaJitRelease(binding, img)
		return setmetatable({
			name = "LuaJIT",
			abi = "jit",
			major = 5,
			minor = 1,
			release = release,
			jit = true,
			string = luaJitString(release)
		}, Version) --[[@as lua.Version]]
	end
	local release, major, minor = luaRelease(binding, img)
	return setmetatable({
		name = "Lua",
		abi = abiName,
		major = major,
		minor = minor,
		release = release,
		jit = false,
		string = "Lua " .. release
	}, Version) --[[@as lua.Version]]
end

---@type table<string, lua.Lua>
local handles = {}

--- Bind an image to the first enabled ABI that matches. Handles are cached:
--- the same image and ABI return the same Lua object.
---@param img lua.Image
---@return lua.Lua
function runtime.forImage(img)
	local abiName, abiModule = runtime.abiOf(img)
	if abiName == nil then
		local enabled = {}
		for _, entry in ipairs(MODULES) do
			if loadAbi(entry.module) ~= nil then enabled[#enabled + 1] = entry.name end
		end
		error(
			"lua-sys: unsupported Lua library at " .. (img.path or "<unnamed image>") .. "; enabled ABIs: " .. (#enabled > 0 and table.concat(
				enabled,
				", "
			) or "none"),
			3
		)
	end
	assert(abiModule) ---@cast abiModule table
	---@cast abiName "jit"|"5.1"|"5.4"|"luau"
	local key = img:key() .. "|" .. abiName
	local cached = handles[key]
	if cached ~= nil then return cached end
	local binding = abiModule.bind(img)
	local handle
	if not img.isRunning then handle = img.handle end
	---@type lua.Lua
	local created = {
		version = detectVersion(abiName, binding, img),
		abi = abiName,
		caps = binding.caps,
		raw = binding.raw,
		handle = handle,
		_binding = binding,
		_image = img
	}
	setmetatable(created, Lua)
	handles[key] = created
	return created
end

---@class lua.HighModule
---@field new fun(rt: lua.Lua): lua.State
---@field wrap fun(rt: lua.Lua, L: ffi.cdata*): lua.State

--- The high-level module, which owns State/Chunk/Table/Frame. It is a
--- separate feature because it also needs the C bridge.
---@return lua.HighModule
local function high()
	local ok, module = pcall(require, "lua-sys.high")
	if not ok then
		if type(module) == "string" then
			local reason = module --[[@as string]]
			if reason:find("not found", 1, true) then
				error("lua-sys: the 'high' feature is not enabled", 3)
			end
		end
		error(module, 0)
	end
	return module --[[@as lua.HighModule]]
end

--- A new guest state owned by this runtime (a `lua.State` from the `high`
--- feature).
---@return lua.State
function Lua:new()
	return high().new(self)
end

--- A guest state around an existing lua_State* of this runtime (not owned).
---@param L ffi.cdata*
---@return lua.State
function Lua:wrap(L)
	return high().wrap(self, L)
end

return runtime
