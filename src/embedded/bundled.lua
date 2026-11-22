-- embedded/bundled.lua — the runtime built for the `bundled` source feature.
--
-- build.lua produces `bundled.<so|dll|dylib>` as the module `lua-sys.bundled`.
-- It is loaded through ffi.load so lde's compiled-binary shim can map the name
-- to the copy embedded in the executable; the image is then identified from an
-- exported address. Every supported runtime (LuaJIT, 5.1, 5.4, Luau) exports
-- `luaL_newstate`, and the declaration is only added when no ABI declared it.

local ffi = require("ffi")
local image = require("lua-sys.image")

local backend = {}
---@type lua.Image?
local cached

-- lua_State *luaL_newstate(void) is what abi/lua51 declares; a 5.4-only or
-- Luau-only build has no lua_* declaration, so add a compatible one. A failed
-- redefinition means it is already declared and indexed through that type.
pcall(ffi.cdef, "void *luaL_newstate(void);")

---@return lua.Image? loaded
---@return string? err
local function load()
	if cached ~= nil then return cached end
	local path = package.searchpath("lua-sys.bundled", package.cpath)
	---@type ffi.namespace*?
	local library
	if path ~= nil then
		local ok, loaded = pcall(ffi.load, path)
		if ok then library = loaded --[[@as ffi.namespace*]] end
	end
	if library == nil then
		local ok, loaded = pcall(ffi.load, "lua-sys.bundled")
		if not ok then return nil, tostring(loaded) end
		library = loaded --[[@as ffi.namespace*]]
	end
	local address = ffi.cast("void *", library.luaL_newstate
		--[[@as ffi.cdata*]])
	local found = image.of(address)
	if found == nil then
		return nil, "cannot locate the loaded lua-sys.bundled image"
	end
	---@cast found lua.Image
	cached = found
	return found
end

---@return lua.Image? loaded
---@return string? err
function backend.image()
	return load()
end

--- The image only when the library has already been loaded.
---@return lua.Image?
function backend.loaded()
	return cached
end

return backend
