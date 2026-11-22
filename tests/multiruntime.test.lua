-- tests/multiruntime.test.lua
--
-- The same high-level checks against every Lua runtime the process can bind:
-- the embedded LuaJIT, the system Lua 5.4 and Lua 5.1, and the Luau fixture.
-- A runtime is skipped only when its fixture is missing. A check that the
-- runtime's capabilities exclude asserts the documented error instead.
--
-- The vendored LuaJIT runs in a separate package (a different embedded
-- runtime), so it is exercised as a nested `lde run`.

local lua = require("lua-sys")
local test = require("lde-test")

local function fileExists(path)
	local file = io.open(path, "rb")
	if file == nil then return false end
	file:close()
	return true
end

---@param env string
---@param defaults string[]
---@return string?
local function firstExisting(env, defaults)
	local fromEnv = os.getenv(env)
	if fromEnv ~= nil and fileExists(fromEnv) then return fromEnv end
	for _, path in ipairs(defaults) do
		if fileExists(path) then return path end
	end
	return nil
end

---@type { label: string, rt: lua.Lua }[]
local runtimes = {}

-- Optional debug filter, e.g. LUA_SYS_MULTI_RUNTIMES="Lua 5.1,Luau".
local onlyRuntimes = os.getenv("LUA_SYS_MULTI_RUNTIMES")

---@param label string
---@param rt    lua.Lua
local function addRuntime(label, rt)
	if onlyRuntimes ~= nil and not onlyRuntimes:find(label, 1, true) then return end
	runtimes[#runtimes + 1] = { label = label, rt = rt }
end

addRuntime("lde LuaJIT", lua:lde())

local lua54 = firstExisting("LUA_SYS_LUA54", {
	"/usr/lib64/liblua-5.4.so",
	"/usr/lib/x86_64-linux-gnu/liblua5.4.so.0",
	"/usr/lib/liblua.so.5.4"
})
if lua54 ~= nil then addRuntime("Lua 5.4", lua:open(lua54)) end

local lua51 = firstExisting("LUA_SYS_LUA51", {
	"/usr/lib64/liblua-5.1.so",
	"/usr/lib/x86_64-linux-gnu/liblua5.1.so.0",
	"/usr/lib/liblua5.1.so.0",
	"/usr/lib/liblua-5.1.so"
})
if lua51 ~= nil then addRuntime("Lua 5.1", lua:open(lua51)) end

local luau = firstExisting("LUA_SYS_LUAU", { "tests/fixtures/luau/libluau.so" })
if luau ~= nil then addRuntime("Luau", lua:open(luau)) end

---@param name string
---@param fn   fun(rt: lua.Lua)
local function forEachRuntime(name, fn)
	for _, entry in ipairs(runtimes) do
		local label, rt = entry.label, entry.rt
		test.it(label .. ": " .. name, function()
			assert(type(rt._binding) == "table", "runtime handle corrupted before: " .. label)
			fn(rt)
			assert(type(rt._binding) == "table", "runtime handle corrupted by: " .. label .. " / " .. name)
		end)
	end
end

-- ─── Evaluating code ─────────────────────────────────────────────────────

forEachRuntime("eval runs a chunk with arguments and results", function(rt)
	local state = rt:new()
	test.equal(3, state:eval("return 1 + 2"))
	test.equal(nil, state:eval("local x = 1"))
	test.equal(7, state:load("local a, b = ...; return a + b"):eval(3, 4))
	test.equal("7x", state:load("return (... + 2) .. 'x'"):eval(5, "unused"))
	test.equal(1, state:load("return 1, 2"):eval())
	local multi = state:eval("return function() return 1, 2, 3 end")
	local a, b, c = multi()
	test.equal(1, a)
	test.equal(2, b)
	test.equal(3, c)
	state:close()
end)

-- ─── Globals and tables ──────────────────────────────────────────────────

forEachRuntime("globals and tables cross both ways", function(rt)
	local state = rt:new()
	local globals = state:globals()
	globals.answer = 42
	test.equal(42, state:eval("return answer"))

	local tbl = state:table({ name = "alice", nested = { n = 2 } })
	test.equal("alice", tbl:get("name"))
	test.equal(2, tbl:get("nested"):get("n"))

	globals.shared = tbl
	test.equal(2, state:eval("return shared.nested.n"))
	tbl:set("name", "bob")
	test.equal("bob", state:eval("return shared.name"))

	state:eval("guest_table = { 10, 20, 30 }")
	local guest = globals:get("guest_table")
	test.equal(20, guest:get(2))
	guest:set(2, 99)
	test.equal(99, state:eval("return guest_table[2]"))
	state:close()
end)

-- ─── Host callbacks ──────────────────────────────────────────────────────

forEachRuntime("host callbacks receive primitives and tables", function(rt)
	local state = rt:new()
	local globals = state:globals()
	local calls = 0

	globals.host_add = function(a, b)
		calls = calls + 1
		return a + b
	end
	globals.host_bump = function(tbl)
		calls = calls + 1
		tbl.x = tbl.x + 1
		return tbl.x
	end
	globals.host_count = function(...) return select("#", ...) end

	test.equal(9, state:eval("return host_add(4, 5)"))
	test.equal(8, state:eval("local t = { x = 7 }; return host_bump(t)"))
	test.equal(3, state:eval("return host_count(1, nil, 3)"))
	test.equal(2, calls)

	globals.host_bad = || -> {}
	local ok, err = pcall(function() state:eval("return host_bad()") end)
	test.falsy(ok)
	test.includes(tostring(err), "only primitives")
	state:close()
end)

forEachRuntime("guest functions are callable from the host", function(rt)
	local state = rt:new()
	local fn = state:eval("return function(a, b) return a + b, a * b end")
	local sum, product = fn(3, 4)
	test.equal(7, sum)
	test.equal(12, product)

	local double = state:eval("return function(t) return t.x * 2 end")
	test.equal(10, double(state:table({ x = 5 })))

	local ok, value = fn:pcall(2, 5)
	test.equal(true, ok)
	test.equal(7, value)
	state:close()
end)

-- ─── Errors ──────────────────────────────────────────────────────────────

forEachRuntime("errors, pcall and xpcall", function(rt)
	local state = rt:new()

	local ok, err = pcall(function() state:eval("error('boom')") end)
	test.falsy(ok)
	test.includes(tostring(err), "boom")

	local pok, perr = state:load("error('chunk boom')"):pcall()
	test.equal(false, pok)
	test.includes(tostring(perr), "chunk boom")

	local xok, xerr = state:load("error('trace boom')"):xpcall()
	test.equal(false, xok)
	test.includes(tostring(xerr), "trace boom")

	local fn = state:eval("return function() error('fn boom') end")
	local fok, ferr = pcall(fn)
	test.falsy(fok)
	test.includes(tostring(ferr), "fn boom")
	local cok, cerr = fn:pcall()
	test.equal(false, cok)
	test.includes(tostring(cerr), "fn boom")
	state:close()
end)

-- ─── Hooks ───────────────────────────────────────────────────────────────

forEachRuntime("setHook fires line events and removes cleanly", function(rt)
	local state = rt:new()

	if rt.caps.hooks == nil then
		local ok, err = pcall(function() state:setHook(function() end, "line") end)
		test.falsy(ok)
		test.includes(tostring(err), "not supported by " .. rt.version.string)
		state:close()
		return
	end

	local events, lines = 0, 0
	state:setHook(function(event, info)
		events = events + 1
		if event == "line" then
			lines = lines + 1
			test.truthy(info.currentline >= 0)
			test.truthy(info.short_src)
			test.truthy(info.thread ~= nil)
		end
	end, "line")

	state:eval("local a = 1\nlocal b = 2\nreturn a + b")
	test.truthy(events > 0, "expected line events")
	test.truthy(lines > 0, "expected the mask to select line events")

	state:setHook(nil)
	local after = events
	state:eval("local c = 3")
	test.equal(after, events)

	if rt.caps.hooks == "line" then
		local ok, err = pcall(function() state:setHook(function() end, "call return") end)
		test.falsy(ok)
		test.includes(tostring(err), "not supported")
	end
	state:close()
end)

forEachRuntime("frame locals, upvalues and eval", function(rt)
	local state = rt:new()
	local done = false
	local stale

	state:setHook(function(_, info)
		local frames = info:stack()
		stale = stale or frames[1]
		if done then return end
		for _, frame in ipairs(frames) do
			if frame:getLocal("marker") then
				done = true
				test.equal(7, frame:getLocal("marker"))
				test.equal(5, frame:getUpvalue("p"))

				local names = {}
				for _, entry in ipairs(frame:locals()) do names[#names + 1] = entry.name end
				test.includes(table.concat(names, ","), "marker")

				test.equal(true, frame:setLocal("marker", 9))
				test.equal(true, frame:setUpvalue("p", 10))
				local ok, value = frame:eval("marker = marker + 1; return marker")
				test.equal(true, ok)
				test.equal(10, value)
			end
		end
	end, "line")

	-- `p` is captured from an outer function that has already returned, so the
	-- upvalue is closed. This is the portable case: Luau's debugstep can read
	-- closed upvalues only.
	local result = state:eval([[
		local function outer(p)
			local function f(x)
				local marker = x + 1
				return marker + p
			end
			return f
		end
		local fn = outer(5)
		return fn(6)
	]])
	test.truthy(done, "the hook did not see the frame")
	test.equal(20, result)
	state:setHook(nil)

	test.truthy(stale)
	test.equal(0, #stale:locals())
	test.equal(nil, stale:getLocal("marker"))
	test.equal(false, stale:setLocal("marker", 1))
	test.equal(nil, stale:getUpvalue("p"))
	test.equal(false, stale:setUpvalue("p", 1))
	local ok, err = stale:eval("marker")
	test.falsy(ok)
	test.includes(tostring(err), "no frame")
	state:close()
end)

-- ─── Memory and heap ─────────────────────────────────────────────────────

forEachRuntime("memory and setMemoryLimit work", function(rt)
	local state = rt:new()
	local before = state:memory()
	test.equal("number", type(before))
	test.truthy(before > 0)

	state:setMemoryLimit(before + 200000)
	local ok, err = state:load("return #string.rep('y', 2000000)"):pcall()
	test.falsy(ok)
	test.includes(tostring(err), "not enough memory")

	state:setMemoryLimit(0)
	test.equal(4, state:eval("return #('abcd')"))
	state:close()
end)

forEachRuntime("heapSnapshot walks the guest", function(rt)
	local state = rt:new()
	state:eval([[
		cache = { entries = {} }
		for i = 1, 100 do cache.entries[i] = string.rep("x", 10) .. i end
	]])
	local snap = state:heapSnapshot()
	test.equal("number", type(snap.objects))
	test.truthy(snap.objects > 0)
	test.equal("number", type(snap.retained["_G.cache.entries"]))
	test.truthy(snap.retained["_G.cache.entries"] > 0)
	state:close()
end)

-- ─── wrap() ──────────────────────────────────────────────────────────────

forEachRuntime("wrap uses an existing state without owning it", function(rt)
	local raw = rt.raw
	local L = raw.lnewstate()
	test.truthy(L)
	raw.openlibs(L)

	local wrapped = rt:wrap(L)
	test.truthy(wrapped.L)
	test.equal(42, wrapped:eval("return 6 * 7"))

	local ok, err = pcall(|| -> wrapped:memory())
	test.falsy(ok)
	test.includes(tostring(err), "wrapped state")
	local ok2, err2 = pcall(function() wrapped:setMemoryLimit(1000) end)
	test.falsy(ok2)
	test.includes(tostring(err2), "wrapped state")

	wrapped:close()
	test.equal(nil, wrapped.L)
	local closedOK, closedErr = pcall(|| -> wrapped:eval("return 1"))
	test.falsy(closedOK)
	test.includes(tostring(closedErr), "state is closed")

	-- close() dropped only lua-sys's registrations: the host state is alive.
	test.equal(0, raw.gettop(L))
	raw.pushnumber(L, 41)
	test.equal(41, raw.tonumber(L, -1))
	raw.pop(L, 1)
	raw.close(L)
end)

-- ─── Capability gating ───────────────────────────────────────────────────

forEachRuntime("unsupported capabilities raise the documented error", function(rt)
	local state = rt:new()
	local profiler = require("lua-sys.profiler")

	if rt.caps.jit then
		test.equal(state, state:jitOff())
		test.equal(false, state:eval("return jit.status()"))
		test.equal(state, state:jitOn())
		profiler.start(state)
		state:eval("local s = 0 for i = 1, 1000 do s = s + i end")
		test.equal("table", type(profiler.stop(state)))
	else
		local ok, err = pcall(function() state:jitOff() end)
		test.falsy(ok)
		test.includes(tostring(err), "not supported by " .. rt.version.string)
		local ok2, err2 = pcall(function() state:jitOn() end)
		test.falsy(ok2)
		test.includes(tostring(err2), "not supported by " .. rt.version.string)
		local ok3, err3 = pcall(function() state:jitFlush() end)
		test.falsy(ok3)
		test.includes(tostring(err3), "not supported by " .. rt.version.string)
		local ok4, err4 = pcall(profiler.start, state)
		test.falsy(ok4)
		test.includes(tostring(err4), "not supported by " .. rt.version.string)
	end
	state:close()
end)

-- ─── Lua 5.4 integers ────────────────────────────────────────────────────

forEachRuntime("integer subtype and math.type", function(rt)
	if not rt.caps.integers then return end
	local state = rt:new()
	test.equal("integer", state:eval("return math.type(1)"))
	test.equal("float", state:eval("return math.type(1.5)"))

	local globals = state:globals()
	globals.n = 3
	test.equal("integer", state:eval("return math.type(n)"))
	globals.f = 3.5
	test.equal("float", state:eval("return math.type(f)"))

	-- Guest integer → host number → guest integer stays an integer.
	local value = state:eval("return 7")
	globals.roundtrip = value
	test.equal("integer", state:eval("return math.type(roundtrip)"))
	test.equal(7, state:eval("return roundtrip"))
	state:close()
end)

-- ─── Bundled runtimes (separate packages) ────────────────────────────────

local ldeBin = os.getenv("LUA_SYS_LDE") or "/home/once/Projects/Personal/lde/packages/lde/lde"
local repo = assert(assert(io.popen("pwd")):read("*l"))

local function quote(path)
	return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function writeFile(path, content)
	local file = assert(io.open(path, "wb"))
	file:write(content)
	file:close()
end

--- The shared high-level checks, run against `l:bundled(version)`.
---@param version string
---@param expectedAbi string
---@param wrongVersion string
---@param extra string
---@return string
local function bundledMain(version, expectedAbi, wrongVersion, extra)
	return ([[
local lua = require("lua-sys")
local rt = lua:bundled(%q)
assert(rt.abi == %q, "abi mismatch: " .. rt.abi)
assert(rt.handle ~= nil, "a bundled runtime must have an image handle")
local state = rt:new()
assert(state:eval("return 1 + 2") == 3)
assert(state:load("local a, b = ...; return a + b"):eval(3, 4) == 7)
local globals = state:globals()
globals.host_add = function(a, b) return a + b end
assert(state:eval("return host_add(4, 5)") == 9)
globals.shared = { 10, 20, 30 }
assert(state:eval("return shared[2]") == 20)
state:eval("guest = { x = 41 }")
state:globals():get("guest"):set("x", 42)
assert(state:eval("return guest.x") == 42)
local add = state:eval("return function(a, b) return a + b end")
assert(add(2, 3) == 5)
local events = 0
state:setHook(function() events = events + 1 end, "line")
state:eval("local a = 1\nlocal b = 2\nreturn a + b")
state:setHook(nil)
assert(events > 0, "expected line events")
%s
assert(not pcall(lua.bundled, lua, %q), "a mismatched version must raise")
state:close()
print("BUNDLED_OK " .. rt.abi .. " " .. rt.version.string)
]]):format(version, expectedAbi, extra, wrongVersion)
end

---@param version string
---@param expectedAbi string
---@param wrongVersion string
---@param extra string
---@param features string
local function bundledCase(version, expectedAbi, wrongVersion, extra, features)
	test.skipIf(not fileExists(ldeBin))("bundled " .. version .. ": builds and passes the high-level checks", function()
		local temp = os.tmpname() .. "-lua-sys-bundled-" .. version
		os.execute("mkdir -p " .. quote(temp))

		local manifest = string.format([[
{
	"name": "lua-sys-bundled-%s-check",
	"version": "0.1.0",
	"dependencies": {
		"lua-sys": {
			"path": %q,
			"features": [%s]
		}
	}
}
]], version, repo, features)
		writeFile(temp .. "/lde.json", manifest)
		writeFile(temp .. "/main.lua", bundledMain(version, expectedAbi, wrongVersion, extra))

		local pipe = assert(io.popen("cd " .. quote(temp) .. " && " .. quote(ldeBin) .. " run main.lua 2>&1"))
		local output = pipe:read("*a")
		local ok = pipe:close()
		os.execute("rm -rf " .. quote(temp))

		test.truthy(ok, output)
		test.includes(output, "BUNDLED_OK")
	end)
end

bundledCase("luajit", "jit", "lua54", [[
assert(rt.version.jit)
assert(rt.caps.jit)
assert(type(state:eval("return jit.version")) == "string")
]], '"bundled", "luajit", "high"')

bundledCase("lua54", "5.4", "luajit", [[
assert(rt.caps.integers)
assert(state:eval("return math.type(3)") == "integer")
]], '"bundled", "lua54", "high"')

bundledCase("luau", "luau", "luajit", [[
assert(rt.caps.source)
assert(state:eval("return 6 * 7") == 42)
]], '"bundled", "luau", "high"')
