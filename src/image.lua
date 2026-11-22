-- image.lua — loaded images of the process: find, open and resolve symbols.
--
-- One image is one shared object (or the main program) the OS loader has in
-- memory. The FFI namespace `ffi.C` only resolves what the process loaded
-- first, so a library that ships a second Lua must bind through its own image
-- handle. The running LuaJIT is found the same way raw.lua did: the address
-- of an internal function plus dladdr/dyld/GetModuleHandleEx.

local ffi = require("ffi")

local VoidPtr = ffi.typeof("void *")

local isWindows = ffi.os == "Windows"
local isOSX = ffi.os == "OSX"

-- dlopen flags per platform. RTLD_NOLOAD asks "handle for the copy already
-- loaded, never load a new one"; the main program has no path and is
-- reopened with dlopen(NULL, ...).
local RTLD
if isOSX then
	RTLD = { now = 0x2, noLoad = 0x10, local_ = 0x4, deepBind = 0 }
elseif isWindows then
	RTLD = { now = 0, noLoad = 0, local_ = 0, deepBind = 0 }
elseif ffi.os == "BSD" then
	RTLD = { now = 0x2, noLoad = 0x2000, local_ = 0, deepBind = 0 }
else
	-- The host process may export its own lua_* (LuaJIT does). A glibc-loaded
	-- liblua would then bind its internal calls to the host's API, so the
	-- library's own scope must win: RTLD_DEEPBIND (glibc-only).
	RTLD = { now = 0x2, noLoad = 0x4, local_ = 0, deepBind = 0x8 }
end

if isWindows then
	pcall(ffi.cdef, [[
		typedef struct lua_sys_HMODULE__ *lua_sys_HMODULE;
		void *GetCurrentProcess(void);
		int K32EnumProcessModules(void *process, void *modules, unsigned long size, unsigned long *needed);
		unsigned long GetModuleFileNameA(void *module, char *name, unsigned long size);
		int GetModuleHandleExA(unsigned long flags, const char *name, void *module);
		void *GetModuleHandleA(const char *name);
		void *LoadLibraryA(const char *name);
		void *GetProcAddress(void *module, const char *name);
		unsigned long GetLastError(void);
	]])
else
	pcall(ffi.cdef, [[
		typedef struct { const char *dli_fname; void *dli_fbase; const char *dli_sname; void *dli_saddr; } lua_sys_DlInfo;
		void *dlopen(const char *path, int mode);
		void *dlsym(void *handle, const char *name);
		char *dlerror(void);
		int dladdr(const void *address, void *info);
	]])
	if not isOSX then
		pcall(ffi.cdef, [[
			typedef struct {
				unsigned long dlpi_addr;
				const char *dlpi_name;
				void *dlpi_phdr;
				unsigned short dlpi_phnum;
			} lua_sys_dl_phdr_info;
			typedef int (*lua_sys_dl_iterate_cb)(lua_sys_dl_phdr_info *info, size_t size, void *data);
			int dl_iterate_phdr(lua_sys_dl_iterate_cb callback, void *data);
		]])
	else
		pcall(ffi.cdef, [[
			int _dyld_image_count(void);
			const char *_dyld_get_image_name(int index);
			void *_dyld_get_image_header(int index);
		]])
	end
end

local image

--- A loaded image: `ffi.C`, a `dlopen`/`LoadLibrary` handle, or the main program.
---@class lua.Image
---@field handle ffi.cdata*? # dlopen handle / HMODULE, nil when the image cannot be referred to
---@field path string? # file name the loader knows the image by; nil for an unnamed main program
---@field base ffi.cdata*? # load base address
---@field namespace ffi.namespace*? # ffi.C or ffi.load(path) once the ABI binds through names
---@field isRunning boolean # true for the image that contains the running LuaJIT
local Image = {}
Image.__index = Image

---@param handle ffi.cdata*?
---@param path string?
---@param base ffi.cdata*?
---@return lua.Image
local function buildImage(handle, path, base)
	---@type lua.Image
	local instance = {
		handle = handle,
		path = path,
		base = base,
		namespace = nil,
		isRunning = false
	}
	return setmetatable(instance, Image)
end

--- Two image objects are the same image when their handles (or, for an
--- unnamed main program, their names) agree.
---@param other lua.Image?
function Image:isSame(other)
	if other == nil then return false end
	if self == other then return true end
	if self.handle ~= nil and other.handle ~= nil and self.handle == other.handle then return true end
	local a, b = self.path, other.path
	if a ~= nil and b ~= nil and a ~= "" and b ~= "" then
		if a == b then return true end
		local at, bt = a:match("([^/\\]+)$"), b:match("([^/\\]+)$")
		if at ~= nil and at == bt then return true end
	end
	return false
end

--- Stable cache key: the same loaded image gives the same key.
function Image:key()
	if self.handle ~= nil then return tostring(self.handle) end
	return "path:" .. (self.path or "?")
end

---@type table<lua.Image, table<string, ffi.cdata*|false>>
local symbolCache = setmetatable({}, { __mode = "k" }) --[[@as table<lua.Image, table<string, ffi.cdata*|false>>]]

--- The address of an exported symbol in this image, or nil.
---@param name string
---@return ffi.cdata*?
function Image:symbol(name)
	if self.handle == nil then return nil end
	local cache = symbolCache[self]
	if cache == nil then
		cache = {}
		symbolCache[self] = cache
	end
	local cached = cache[name]
	if cached ~= nil then
		if cached == false then return nil end
		return cached --[[@as ffi.cdata*]]
	end
	local address
	if isWindows then
		address = ffi.cast("void *", ffi.C.GetProcAddress(self.handle, name))
	else
		address = ffi.cast("void *", ffi.C.dlsym(self.handle, name))
	end
	if address == nil then
		cache[name] = false
		return nil
	end
	cache[name] = address
	return address --[[@as ffi.cdata*]]
end

--- The namespace to bind real (unprefixed) C names through: `ffi.C` when it
--- already resolves into this image, else `ffi.load(path)`.
---
--- `symbolName` is a symbol the caller has already declared with ffi.cdef; it
--- only decides whether `ffi.C` belongs to this image. The result is cached on
--- the image (`namespace`).
---@param symbolName string
---@return ffi.namespace*
function Image:clib(symbolName)
	if self.namespace ~= nil then return self.namespace end
	local result
	local ok, fn = pcall(function() return ffi.C[symbolName] end)
	if ok and fn ~= nil then
		local owner = image.of(ffi.cast(VoidPtr, fn --[[@as ffi.cdata*]]))
		if owner ~= nil and owner:isSame(self) then result = ffi.C end
	end
	if result == nil then
		local path = self.path
		if path ~= nil and path ~= "" and path:find("[/\\]") then
			local loaded, clib = pcall(ffi.load, path)
			if loaded then result = clib --[[@as ffi.namespace*]] end
		end
	end
	if result == nil then
		if self.isRunning then
			result = ffi.C
		else
			error("lua-sys: cannot bind the Lua library at " .. (self.path or "<unnamed image>"), 3)
		end
	end
	self.namespace = result
	return result
end

image = {}

---@param address ffi.cdata*
---@return lua.Image?
local function imageOfAddress(address)
	if isWindows then
		local module = ffi.new("void*[1]")
		-- FROM_ADDRESS | UNCHANGED_REFCOUNT
		if ffi.C.GetModuleHandleExA(0x4 + 0x2, ffi.cast("const char *", address), ffi.cast(VoidPtr, module)) == 0 then
			return nil
		end
		local handle = module[0] --[[@as ffi.cdata*]]
		local buffer = ffi.new("char[?]", 32768)
		local length = ffi.C.GetModuleFileNameA(handle, buffer, 32768)
		local path = length > 0 and ffi.string(buffer, length) or nil
		return buildImage(handle, path, handle)
	end
	local info = ffi.new("lua_sys_DlInfo")
	if ffi.C.dladdr(address, ffi.cast(VoidPtr, info)) == 0 then return nil end
	local path = info.dli_fname ~= nil and ffi.string(info.dli_fname) or nil
	---@type ffi.cdata*?
	local handle
	if path == nil or path == "" then
		handle = ffi.cast("void *", ffi.C.dlopen(nil, RTLD.now))
		path = nil
	else
		handle = ffi.cast("void *", ffi.C.dlopen(path, RTLD.now | RTLD.noLoad))
		if handle == nil and path:find("[/\\]") then
			handle = ffi.cast("void *", ffi.C.dlopen(path, RTLD.now))
		end
		if handle == nil then handle = ffi.cast("void *", ffi.C.dlopen(nil, RTLD.now)) end
	end
	return buildImage(handle, path, ffi.cast(VoidPtr, info.dli_fbase))
end

---@type lua.Image?
local runningImage
local isResolvingRunning = false

--- The image that contains the LuaJIT running this module, or nil when the
--- host is not LuaJIT.
---@return lua.Image?
function image.running()
	if runningImage ~= nil then return runningImage end
	if isResolvingRunning then return nil end
	isResolvingRunning = true
	local hasUtil, util = pcall(require, "jit.util")
	if hasUtil then
		---@cast util table
		local address = ffi.cast(VoidPtr, util.ircalladdr(0))
		runningImage = imageOfAddress(address)
		if runningImage ~= nil then runningImage.isRunning = true end
	end
	isResolvingRunning = false
	return runningImage
end

--- The image that contains `address`, or nil.
---@param address ffi.cdata*
---@return lua.Image?
function image.of(address)
	local found = imageOfAddress(ffi.cast(VoidPtr, address))
	if found == nil then return nil end
	---@cast found lua.Image
	local running = image.running()
	if running ~= nil then
		---@cast running lua.Image
		if found:isSame(running) then found.isRunning = true end
	end
	return found
end

---@return lua.Image[]
local function listPosix()
	---@type lua.Image[]
	local out = {}
	local callback = ffi.cast("lua_sys_dl_iterate_cb", function(info, _, _)
		local name = info.dlpi_name ~= nil and ffi.string(info.dlpi_name) or ""
		local handle
		if name == "" then
			handle = ffi.cast("void *", ffi.C.dlopen(nil, RTLD.now))
		else
			handle = ffi.cast("void *", ffi.C.dlopen(name, RTLD.now | RTLD.noLoad))
		end
		out[#out + 1] = buildImage(handle, name == "" and nil or name, ffi.cast(VoidPtr, info.dlpi_addr))
		return 0
	end)
	ffi.C.dl_iterate_phdr(callback, nil)
	return out
end

---@return lua.Image[]
local function listOSX()
	---@type lua.Image[]
	local out = {}
	local count = ffi.C._dyld_image_count()
	for i = 0, count - 1 do
		local name = ffi.C._dyld_get_image_name(i)
		local path = name ~= nil and ffi.string(name) or nil
		local handle
		if i == 0 then
			handle = ffi.cast("void *", ffi.C.dlopen(nil, RTLD.now))
		elseif path ~= nil then
			handle = ffi.cast("void *", ffi.C.dlopen(path, RTLD.now | RTLD.noLoad))
		end
		out[#out + 1] = buildImage(handle, path, ffi.cast(VoidPtr, ffi.C._dyld_get_image_header(i)))
	end
	return out
end

---@return lua.Image[]
local function listWindows()
	---@type lua.Image[]
	local out = {}
	local process = ffi.C.GetCurrentProcess()
	local needed = ffi.new("unsigned long[1]")
	ffi.C.K32EnumProcessModules(process, nil, 0, needed)
	local capacity = math.floor(tonumber(needed[0]) / ffi.sizeof(VoidPtr))
	if capacity < 1 then return out end
	local modules = ffi.new("void*[?]", capacity)
	if ffi.C.K32EnumProcessModules(process, ffi.cast(VoidPtr, modules), needed[0], needed) == 0 then
		return out
	end
	local count = math.floor(tonumber(needed[0]) / ffi.sizeof(VoidPtr))
	if count > capacity then count = capacity end
	local buffer = ffi.new("char[?]", 32768)
	for i = 0, count - 1 do
		local handle = modules[i] --[[@as ffi.cdata*]]
		local length = ffi.C.GetModuleFileNameA(handle, buffer, 32768)
		local path = length > 0 and ffi.string(buffer, length) or nil
		out[#out + 1] = buildImage(handle, path, handle)
	end
	return out
end

--- Every image the process has loaded, main program included.
---@return lua.Image[]
function image.list()
	local images = isWindows and listWindows() or (isOSX and listOSX() or listPosix())
	---@cast images lua.Image[]
	local running = image.running()
	if running ~= nil then
		---@cast running lua.Image
		for _, found in ipairs(images) do
			if found:isSame(running) then found.isRunning = true end
		end
	end
	return images
end

--- dlopen / LoadLibrary a library by path.
---@param path string
---@return lua.Image? loaded
---@return string? err
function image.open(path)
	---@type ffi.cdata*?
	local handle
	if isWindows then
		handle = ffi.cast("void *", ffi.C.LoadLibraryA(path))
	else
		handle = ffi.cast("void *", ffi.C.dlopen(path, RTLD.now | RTLD.local_ | RTLD.deepBind))
	end
	if handle == nil then
		local err
		if isWindows then
			err = "LoadLibrary failed (error " .. tonumber(ffi.C.GetLastError()) .. ") for " .. path
		else
			local message = ffi.C.dlerror()
			err = message ~= nil and ffi.string(ffi.cast("const char *", message)) or ("dlopen failed for " .. path)
		end
		return nil, err
	end
	local found = buildImage(handle, path, nil)
	local running = image.running()
	if running ~= nil then
		---@cast running lua.Image
		if found:isSame(running) then found.isRunning = true end
	end
	return found
end

return image
