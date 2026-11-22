local ffi = require("ffi")
local lua = require("lua-sys")
local test = require("lde-test")

---@param path string
---@return boolean
local function exists(path)
	local file = io.open(path, "rb")
	if file == nil then return false end
	file:close()
	return true
end

---@return string?
local function lua54Path()
	local fromEnv = os.getenv("LUA_SYS_LUA54")
	if fromEnv ~= nil and fromEnv ~= "" then return fromEnv end
	local candidates = {
		"/usr/lib64/liblua-5.4.so",
		"/usr/lib/x86_64-linux-gnu/liblua5.4.so.0",
		"/usr/lib/liblua.so.5.4"
	}
	for _, path in ipairs(candidates) do
		if exists(path) then return path end
	end
	return nil
end

---@return string?
local function luauPath()
	local fromEnv = os.getenv("LUA_SYS_LUAU")
	if fromEnv ~= nil and fromEnv ~= "" then return fromEnv end
	local source = debug.getinfo(1, "S").source
	if type(source) ~= "string" then return nil end
	if source:sub(1, 1) == "@" then source = source:sub(2) end
	local root = source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
	local path = root .. "/tests/fixtures/luau/libluau.so"
	if exists(path) then return path end
	return nil
end

test.it("lde is the running LuaJIT", function()
	local rt = lua:lde()
	test.equal("jit", rt.abi)
	test.equal("LuaJIT", rt.version.name)
	test.equal(true, rt.version.jit)
	test.equal(5, rt.version.major)
	test.equal(1, rt.version.minor)
	test.equal(jit.version, rt.version.string)
	test.equal(jit.version:match("^LuaJIT%s+(.+)$"), rt.version.release)
	test.equal("full", rt.caps.hooks)
	test.equal("fenv", rt.caps.env)
	test.equal(false, rt.caps.integers)
	test.equal(true, rt.caps.source)
	test.truthy(rt.caps.jit)
	test.truthy(rt.raw)
	test.equal(rt, lua:lde())
	test.equal(nil, rt.handle)
end)

test.it("vendored is nil while no other runtime is loaded", function()
	test.equal(nil, lua:vendored("lua51"))
	test.equal(nil, lua:vendored("luau"))
end)

test.it("vendored rejects an unknown version", function()
	local vendored = lua["vendored"]
	test.errors(function() vendored(lua, "lua53") end)
	test.errors(function() vendored(lua, "jit") end)
end)

test.it("bundled rejects an unknown version before loading anything", function()
	local bundled = lua["bundled"]
	test.errors(function() bundled(lua, "lua53") end)
	test.errors(function() bundled(lua, "jit") end)
end)

test.it("the raw API creates a state and runs a chunk", function()
	local rt = lua:lde()
	local raw = rt.raw
	local L = raw.lnewstate()
	test.truthy(L)
	raw.openlibs(L)
	raw.createtable(L, 0, 0)
	test.equal("table", ffi.string(raw.typename(L, raw.type(L, -1))))
	raw.settop(L, 0)
	test.equal(0, rt._binding.load(L, "return 2 + 2", "=runtime-test", "t"))
	test.equal(0, raw.pcall(L, 0, 1, 0))
	test.equal(4, raw.tonumber(L, -1))
	raw.close(L)
end)

local path54 = lua54Path()

test.skipIf(path54 == nil)("binds the system Lua 5.4", function()
	local path = assert(path54)
	local rt = lua:open(path)
	test.equal("5.4", rt.abi)
	test.equal("Lua", rt.version.name)
	test.equal(false, rt.version.jit)
	test.equal(5, rt.version.major)
	test.equal(4, rt.version.minor)
	local release = assert(rt.version.release)
	test.truthy(release:match("^5%.4%.") ~= nil)
	test.equal("Lua " .. release, rt.version.string)
	test.equal(true, rt.caps.integers)
	test.equal("full", rt.caps.hooks)
	test.equal("_ENV", rt.caps.env)
	test.equal(-1001000, rt._binding.REGISTRYINDEX)
	test.equal("number", rt._binding.typeNames[3])

	local raw = rt.raw
	local binding = rt._binding
	local L = raw.lnewstate()
	test.truthy(L)
	raw.openlibs(L)

	raw.pushinteger(L, 8589934592)
	test.equal(8589934592, tonumber(raw.tointeger(L, -1)))
	test.equal(true, raw.isinteger(L, -1))

	binding.pushNumber(L, 1.5)
	test.equal(1.5, binding.toNumber(L, -1))
	binding.pushNumber(L, 1099511627776)
	test.equal(true, raw.isinteger(L, -1))
	test.equal(1099511627776, tonumber(raw.tointeger(L, -1)))

	raw.settop(L, 0)
	test.equal(0, binding.load(L, "return 6 * 7", "=runtime-test", "t"))
	test.equal(0, raw.pcall(L, 0, 1, 0))
	test.equal(42, tonumber(raw.tointeger(L, -1)))

	raw.settop(L, 0)
	test.equal(3, binding.load(L, "return )", "=bad", "t"))
	test.includes(raw.tolstring(L, -1), "unexpected symbol")

	raw.close(L)
end)

test.skipIf(path54 == nil)("vendored finds an ffi.loaded 5.4 and caches it", function()
	local path = assert(path54)
	assert(ffi.load(path))
	local found = lua:vendored("lua54")
	test.truthy(found)
	test.equal("5.4", found.abi)
	test.equal(nil, lua:vendored("lua51"))
	test.equal(nil, lua:vendored("luau"))
	test.equal(found, lua:open(path))
	test.equal(found, lua:open(path))
end)

local pathLuau = luauPath()

test.skipIf(pathLuau == nil)("binds a Luau VM", function()
	local path = assert(pathLuau)
	local rt = lua:open(path)
	test.equal("luau", rt.abi)
	test.equal("Luau", rt.version.name)
	test.equal(0, rt.version.major)
	test.equal(0, rt.version.minor)
	test.equal(nil, rt.version.release)
	test.equal("Luau", rt.version.string)
	test.equal(false, rt.caps.jit)
	test.equal("fenv", rt.caps.env)
	test.equal(false, rt.caps.integers)
	test.equal("line", rt.caps.hooks)
	test.equal(rt.raw.luau_compile ~= nil, rt.caps.source)
	test.equal("vector", rt._binding.typeNames[4])
	test.equal(-10000, rt._binding.REGISTRYINDEX)

	local raw = rt.raw
	local binding = rt._binding
	local L = raw.lnewstate()
	test.truthy(L)
	raw.openlibs(L)

	if raw.luau_compile ~= nil then
		test.equal(0, binding.load(L, "return 6 * 7", "=runtime-test", "t"))
		test.equal(0, raw.pcall(L, 0, 1, 0))
		test.equal(42, raw.tonumber(L, -1))

		local source = "return 11 * 2"
		local size = ffi.new("size_t[1]")
		local bytecode = raw.luau_compile(source, #source, nil, size)
		test.truthy(bytecode)
		local compiled = ffi.string(bytecode, size[0])
		raw.free(bytecode)
		test.equal(true, binding.isBytecode(compiled))

		raw.settop(L, 0)
		test.equal(0, binding.load(L, compiled, "=bc", "b"))
		test.equal(0, raw.pcall(L, 0, 1, 0))
		test.equal(22, raw.tonumber(L, -1))
	end

	raw.close(L)
end)
