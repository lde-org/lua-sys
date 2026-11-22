-- init.lua — entry module: pick a Lua runtime, bind it, hand it to the high
-- layer. The high-level API (State, Chunk, Table, Frame, hooks) is a separate
-- `high` feature that also needs the C bridge.
--
-- One runtime per build: the version features gate the bindings and the source
-- features pick where the runtime comes from (`lde`, `bundled` or the host,
-- through `vendored(version)`).

local image = require("lua-sys.image")
local runtime = require("lua-sys.runtime")

---@class lua
local lua = {}

local VERSION_ABI = {
	luajit = "jit",
	lua51 = "5.1",
	lua54 = "5.4",
	luau = "luau"
}

--- Validate a public version name and return the ABI it maps to.
---@param version string
---@return "jit"|"5.1"|"5.4"|"luau"
local function abiOfVersion(version)
	local abi = VERSION_ABI[version]
	if abi == nil then
		error(
			'lua-sys: unknown version "' .. tostring(version)
			.. '" (expected "luajit", "lua51", "lua54" or "luau")',
			3
		)
	end
	return abi --[[@as "jit"|"5.1"|"5.4"|"luau"]]
end

---@class lua.EmbeddedBackend
---@field image fun(): lua.Image?, string?
---@field loaded fun(): lua.Image?

---@type table<string, lua.EmbeddedBackend|false>
local backends = {}

--- Load one backend module, or nil when its feature is not bundled.
---@param name string
---@return lua.EmbeddedBackend?
local function backend(name)
	local cached = backends[name]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end
	local ok, module = pcall(require, "lua-sys.embedded." .. name)
	if not ok then
		if type(module) == "string" then
			local reason = module --[[@as string]]
			if reason:find("not found", 1, true) then
				backends[name] = false
				return nil
			end
		end
		error(module, 0)
	end
	---@cast module lua.EmbeddedBackend
	backends[name] = module
	return module
end

---@type lua.Lua?
local ldeHandle

--- The LuaJIT that lde itself links (the image running lua-sys).
--- Never nil; raises when the `lde` feature is not bundled.
---@return lua.Lua
function lua:lde()
	if ldeHandle ~= nil then return ldeHandle end
	local module = backend("lde")
	if module == nil then
		error("lua-sys: the 'lde' feature is not enabled", 2)
	end
	local found = module.image()
	if found == nil then
		error("lua-sys: cannot locate the LuaJIT that runs lua-sys", 2)
	end
	ldeHandle = runtime.forImage(found)
	return ldeHandle
end

---@type table<string, lua.Lua>
local bundledHandles = {}

--- The runtime built by the `bundled` feature, from `lua-sys.bundled`.
--- Never nil; raises when `bundled` is off or `version` is not its version.
---@param version "luajit"|"lua51"|"lua54"|"luau"
---@return lua.Lua
function lua:bundled(version)
	local abi = abiOfVersion(version)
	local cached = bundledHandles[version]
	if cached ~= nil then return cached end
	local module = backend("bundled")
	if module == nil then
		error("lua-sys: the 'bundled' feature is not enabled", 2)
	end
	local found, err = module.image()
	if found == nil then
		error("lua-sys: cannot load lua-sys.bundled: " .. tostring(err), 2)
	end
	local bound = runtime.forImage(found)
	if bound.abi ~= abi then
		error(
			("lua-sys: the bundled runtime is %s, not %s"):format(bound.version.string, version),
			2
		)
	end
	bundledHandles[version] = bound
	return bound
end

--- A runtime the host process already has, excluding lde's and the bundled
--- image. Nil when the process has no loaded runtime of that version.
---@param version "luajit"|"lua51"|"lua54"|"luau"
---@return lua.Lua?
function lua:vendored(version)
	local abi = abiOfVersion(version)
	---@type lua.Image[]
	local excluded = {}
	local running = image.running()
	if running ~= nil then
		---@cast running lua.Image
		excluded[#excluded + 1] = running
	end
	local bundled = backend("bundled")
	if bundled ~= nil and bundled.loaded ~= nil then
		local loaded = bundled.loaded()
		if loaded ~= nil then
			---@cast loaded lua.Image
			excluded[#excluded + 1] = loaded
		end
	end

	local images = image.list()
	---@cast images lua.Image[]
	for _, candidate in ipairs(images) do
		local isOurs = false
		for _, other in ipairs(excluded) do
			if candidate:isSame(other) then
				isOurs = true
				break
			end
		end
		if not isOurs and runtime.abiOf(candidate) == abi then
			return runtime.forImage(candidate)
		end
	end
	return nil
end

--- Bind the Lua library at `path` (dlopen / LoadLibrary). Raises when the
--- path cannot be loaded or does not export a supported Lua ABI.
---@param path string
---@return lua.Lua
function lua:open(path)
	local found, err = image.open(path)
	if found == nil then
		error("lua-sys: " .. (err or ("cannot open " .. path)), 2)
	end
	---@cast found lua.Image
	if runtime.abiOf(found) == nil then
		error("lua-sys: " .. path .. " is not a supported Lua library", 2)
	end
	return runtime.forImage(found)
end

return lua
