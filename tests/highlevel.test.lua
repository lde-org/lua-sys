local lua  = require("lua-sys")
local test = require("lde-test")

-- ─── State ────────────────────────────────────────────────────────────────

test.it("lua.new() creates a state", function()
	local state = lua.new()
	test.truthy(state)
	test.truthy(state.L)
	state:close()
end)

-- ─── load ─────────────────────────────────────────────────────────────────

test.it("state:load returns a callable function", function()
	local state = lua.new()
	local fn = state:load("return function(a, b) return a + b end")
	test.truthy(fn)
	test.equal("function", type(fn))
	state:close()
end)

test.it("state:load handles explicit return chunks too", function()
	local state = lua.new()
	local v = state:load("return 42")
	test.equal(42, v)
	state:close()
end)

test.it("state:load returns nil for a void chunk", function()
	local state = lua.new()
	local v = state:load("local x = 1")
	test.equal(nil, v)
	state:close()
end)

test.it("state:load raises on syntax error", function()
	local state = lua.new()
	local ok, err = pcall(function() state:load(")(invalid") end)
	test.equal(false, ok)
	test.truthy(err)
	state:close()
end)

-- ─── Calling guest functions ──────────────────────────────────────────────

test.it("calling a guest function returns plain values", function()
	local state = lua.new()
	local fn = state:load("function(a, b) return a + b end")
	local result = fn(3, 4)
	test.equal(7, result)
	state:close()
end)

test.it("guest function passes string arguments", function()
	local state = lua.new()
	local fn = state:load("function(s) return s .. '!' end")
	local result = fn("hello")
	test.equal("hello!", result)
	state:close()
end)

test.it("guest function passes boolean arguments", function()
	local state = lua.new()
	local fn = state:load("function(b) return not b end")
	local result = fn(true)
	test.equal(false, result)
	state:close()
end)

test.it("guest function returns multiple results", function()
	local state = lua.new()
	local fn = state:load("function(a, b) return a, b, a + b end")
	local r1, r2, r3 = fn(10, 20)
	test.equal(10, r1)
	test.equal(20, r2)
	test.equal(30, r3)
	state:close()
end)

test.it("pcall on guest function returns true and results on success", function()
	local state = lua.new()
	local fn = state:load("function(x) return x * 2 end")
	local ok, result = pcall(fn, 21)
	test.equal(true, ok)
	test.equal(42, result)
	state:close()
end)

test.it("pcall on guest function returns false and error on failure", function()
	local state = lua.new()
	local fn = state:load("function() error('boom') end")
	local ok, err = pcall(fn)
	test.equal(false, ok)
	test.equal("string", type(err))
	test.includes(err, "boom")
	state:close()
end)

test.it("can pass result of guest call to another guest call", function()
	local state = lua.new()
	local double = state:load("function(x) return x * 2 end")
	local r = double(5)
	local again = double(r)
	test.equal(20, again)
	state:close()
end)

-- ─── globals ──────────────────────────────────────────────────────────────

test.it("state:globals() returns a lua.Table", function()
	local state = lua.new()
	local g = state:globals()
	test.truthy(g)
	test.equal("table", g:type())
	state:close()
end)

test.it("globals:get returns known global as callable function", function()
	local state = lua.new()
	local g = state:globals()
	local v = g:get("type")
	test.truthy(v)
	test.equal("function", type(v))
	state:close()
end)

test.it("globals:get returns nil for unknown key", function()
	local state = lua.new()
	local g = state:globals()
	local v = g:get("__this_does_not_exist__")
	test.equal(nil, v)
	state:close()
end)

-- ─── Table:set ────────────────────────────────────────────────────────────

test.it("globals:set / globals:get roundtrip for number", function()
	local state = lua.new()
	local g = state:globals()
	g:set("bar", 42)
	local v = g:get("bar")
	test.equal(42, v)
	state:close()
end)

test.it("globals:set / globals:get roundtrip for string", function()
	local state = lua.new()
	local g = state:globals()
	g:set("greeting", "hello")
	local v = g:get("greeting")
	test.equal("hello", v)
	state:close()
end)

test.it("globals:set / globals:get roundtrip for boolean", function()
	local state = lua.new()
	local g = state:globals()
	g:set("flag", true)
	local v = g:get("flag")
	test.equal(true, v)
	state:close()
end)

test.it("globals:set nil removes the key", function()
	local state = lua.new()
	local g = state:globals()
	g:set("tmp", 99)
	g:set("tmp", nil)
	local v = g:get("tmp")
	test.equal(nil, v)
	state:close()
end)

test.it("globals:set accepts a guest function and it stays callable", function()
	local state = lua.new()
	local fn    = state:load("function(x) return x + 1 end")
	local g     = state:globals()
	g:set("increment", fn)
	-- verify it's visible from within Lua
	local runner = state:load("function() return increment(9) end")
	local v = runner()
	test.equal(10, v)
	state:close()
end)

-- ─── Lua function wrapping ────────────────────────────────────────────────

test.it("globals:set accepts a plain Lua function (wrapped as CFunction)", function()
	local state = lua.new()
	local g = state:globals()

	g:set("add", function(a, b)
		return a + b
	end)

	local v = state:load("return add(3, 4)")
	test.equal(7, v)
	state:close()
end)

test.it("wrapped Lua function can return multiple values", function()
	local state = lua.new()
	local g = state:globals()

	g:set("swap", function(a, b)
		return b, a
	end)

	local fn = state:load("function() return swap(1, 2) end")
	local r1, r2 = fn()
	test.equal(2, r1)
	test.equal(1, r2)
	state:close()
end)

test.it("wrapped Lua function returning nil produces no results", function()
	local state = lua.new()
	local g = state:globals()
	local called = false

	g:set("noop", function()
		called = true
	end)

	local fn = state:load("function() noop(); return 'done' end")
	local v = fn()
	test.equal(true, called)
	test.equal("done", v)
	state:close()
end)

-- ─── Tables ───────────────────────────────────────────────────────────────

test.it("state:load of a table returns lua.Table", function()
	local state = lua.new()
	local tbl = state:load("{}")
	test.truthy(tbl)
	test.equal("table", tbl:type())
	state:close()
end)

test.it("table from guest has get/set", function()
	local state = lua.new()
	local tbl = state:load("{x = 10}")
	test.equal(10, tbl:get("x"))
	tbl:set("y", 20)
	test.equal(20, tbl:get("y"))
	state:close()
end)

test.it("stack is balanced after every operation", function()
	local state = lua.new()
	local L     = state.L
	local raw   = lua.raw
	local base  = raw.gettop(L)

	local fn    = state:load("function(x) return x end")
	local g     = state:globals()
	g:set("x", 10)
	local v = g:get("x")
	fn(v)
	pcall(fn, v)

	test.equal(base, raw.gettop(L))
	state:close()
end)

test.it("pcall succeeds when function calls wrapped Lua function", function()
	local state = lua.new()
	local g = state:globals()
	g:set("double", function(x)
		return x * 2
	end)
	local fn = state:load("function(x) return double(x) end")
	local ok, result = pcall(fn, 5)
	test.equal(true, ok)
	test.equal(10, result)
	state:close()
end)

test.it("pcall catches errors that occur after wrapped calls", function()
	local state = lua.new()
	local g = state:globals()
	g:set("noop", function() end)
	local fn = state:load("function() noop(); error('kaboom') end")
	local ok, err = pcall(fn)
	test.equal(false, ok)
	test.equal("string", type(err))
	test.includes(err, "kaboom")
	state:close()
end)

test.it("pcall returns results from wrapped function calls", function()
	local state = lua.new()
	local g = state:globals()
	g:set("add", function(a, b)
		return a + b
	end)
	local fn = state:load("function(a, b) return add(a, b) end")
	local ok, result = pcall(fn, 10, 20)
	test.equal(true, ok)
	test.equal(30, result)
	state:close()
end)

-- ─── Table index/newindex proxy ───────────────────────────────────────────

test.it("table[key] reads via __index proxy", function()
	local state = lua.new()
	local tbl = state:load("{x = 10, y = 20}")
	test.equal(10, tbl.x)
	test.equal(20, tbl.y)
	test.equal(nil, tbl.z)
	state:close()
end)

test.it("table[key] = val writes via __newindex proxy", function()
	local state = lua.new()
	local tbl = state:load("{}")
	tbl.x = 42
	tbl.msg = "hello"
	tbl.flag = true
	test.equal(42, tbl.x)
	test.equal("hello", tbl.msg)
	test.equal(true, tbl.flag)
	state:close()
end)

test.it("__index does not shadow Table methods", function()
	local state = lua.new()
	-- guest table has a key named 'get' — the method must still win
	local tbl = state:load([[{get = "notamethod"}]])
	test.equal("function", type(tbl.get)) -- method, not the guest string
	test.equal("notamethod", tbl:get("get"))
	state:close()
end)

test.it("__newindex on globals roundtrip", function()
	local state = lua.new()
	local g = state:globals()
	g.answer = 99
	test.equal(99, g.answer)
	local v = state:load("return answer")
	test.equal(99, v)
	state:close()
end)

-- ─── Table:pairs ──────────────────────────────────────────────────────────

test.it("pairs() iterates all key/value pairs", function()
	local state = lua.new()
	local tbl = state:load("{a = 1, b = 2, c = 3}")
	local got = {}
	for k, v in tbl:pairs() do
		got[k] = v
	end
	test.equal(1, got.a)
	test.equal(2, got.b)
	test.equal(3, got.c)
	test.equal(3, (function()
		local n = 0; for _ in pairs(got) do n = n + 1 end; return n
	end)())
	state:close()
end)

test.it("pairs() on empty table yields nothing", function()
	local state = lua.new()
	local tbl = state:load("{}")
	local count = 0
	for _ in tbl:pairs() do count = count + 1 end
	test.equal(0, count)
	state:close()
end)

test.it("pairs() can be called multiple times independently", function()
	local state = lua.new()
	local tbl = state:load("{x = 1, y = 2}")
	local first, second = {}, {}
	for k in tbl:pairs() do first[k] = true end
	for k in tbl:pairs() do second[k] = true end
	test.equal(true, first.x and first.y)
	test.equal(true, second.x and second.y)
	state:close()
end)

test.it("pairs() two concurrent iterators on same table", function()
	local state = lua.new()
	local tbl = state:load("{a=1, b=2, c=3, d=4}")
	local iter1 = tbl:pairs()
	local iter2 = tbl:pairs()
	local s1, s2 = {}, {}
	for k, v in iter1 do s1[k] = v end
	for k, v in iter2 do s2[k] = v end
	test.equal(s1.a, s2.a)
	test.equal(s1.b, s2.b)
	state:close()
end)

-- ─── Table:ipairs ─────────────────────────────────────────────────────────

test.it("ipairs() iterates sequential integer keys", function()
	local state = lua.new()
	local tbl = state:load("{10, 20, 30}")
	local keys, vals = {}, {}
	for i, v in tbl:ipairs() do
		keys[#keys + 1] = i
		vals[#vals + 1] = v
	end
	test.equal(3, #keys)
	test.equal(1, keys[1]); test.equal(10, vals[1])
	test.equal(2, keys[2]); test.equal(20, vals[2])
	test.equal(3, keys[3]); test.equal(30, vals[3])
	state:close()
end)

test.it("ipairs() stops at first nil hole", function()
	local state = lua.new()
	local tbl = state:load("{10, 20, nil, 40}")
	local count = 0
	for _ in tbl:ipairs() do count = count + 1 end
	test.equal(2, count)
	state:close()
end)

test.it("ipairs() on empty table yields nothing", function()
	local state = lua.new()
	local tbl = state:load("{}")
	local count = 0
	for _ in tbl:ipairs() do count = count + 1 end
	test.equal(0, count)
	state:close()
end)

test.it("ipairs() returns string values correctly", function()
	local state = lua.new()
	local tbl = state:load('{"a", "b", "c"}')
	local vals = {}
	for _, v in tbl:ipairs() do vals[#vals + 1] = v end
	test.equal("a", vals[1])
	test.equal("b", vals[2])
	test.equal("c", vals[3])
	state:close()
end)



test.it("strings with embedded nulls survive guest fn roundtrip", function()
	local state = lua.new()
	local id = state:load("function(s) return s end")
	local original = "hello\0world"
	test.equal(11, #original)
	local result = id(original)
	test.equal(original, result)
	state:close()
end)

test.it("strings with embedded nulls survive Table set/get roundtrip", function()
	local state = lua.new()
	local g = state:globals()
	local original = "foo\0bar"
	test.equal(7, #original)
	g:set("nulkey", original)
	local v = g:get("nulkey")
	test.equal(original, v)
	state:close()
end)

test.it("strings with embedded nulls survive table set/get in Lua evaluation", function()
	local state = lua.new()
	local original = "a\0b\0c"
	test.equal(5, #original)
	local getter = state:load("function() return tbl end")
	local g = state:globals()
	g:set("tbl", original)
	local result = getter()
	test.equal(original, result)
	state:close()
end)

-- ─── Nested / recursive calls ─────────────────────────────────────────────

test.it("host callback can call back into guest (Host → Guest → Host)", function()
	local state = lua.new()
	local g = state:globals()

	local guest_inc = state:load("function(x) return inc(x) end")

	g:set("inc", function(x)
		return x + 1
	end)

	g:set("nested_test", function(x)
		local r = guest_inc(x)
		return r + 1
	end)

	local v = state:load("return nested_test(40)")
	test.equal(42, v)
	state:close()
end)

test.it("deeper nesting: guest → host_A → guest → host_B → guest", function()
	local state     = lua.new()
	local g         = state:globals()

	local inc_fn    = state:load("function(x) return inc(x) end")
	local double_fn = state:load("function(x) return double(x) end")

	g:set("inc", function(x) return x + 1 end)
	g:set("double", function(x)
		local r = inc_fn(x)
		return r * 2
	end)
	g:set("triple", function(x)
		local r = double_fn(x)
		return r * 3
	end)

	local fn = state:load("function(x) return triple(x) end")
	local result = fn(5)
	test.equal(36, result)
	state:close()
end)

test.it("guest stack is balanced after nested cross-boundary calls", function()
	local state = lua.new()
	local raw = lua.raw
	local g = state:globals()
	local base = raw.gettop(state.L)

	local guest_fn = state:load("function() return inner() end")

	g:set("inner", function() return 1 end)
	g:set("outer", function()
		local r = guest_fn()
		return r + 2
	end)

	local fn = state:load("function() return outer() end")

	for _ = 1, 100 do
		local v = fn()
		test.equal(3, v)
		test.equal(base, raw.gettop(state.L))
	end

	state:close()
end)

test.it("many iterations of nested calls do not corrupt state", function()
	local state = lua.new()
	local g = state:globals()

	local guest_add = state:load("function(a, b) return add(a, b) end")

	g:set("add", function(a, b) return a + b end)
	g:set("multiply_add", function(a, b, c)
		local r1 = guest_add(a, b)
		local r2 = guest_add(r1, c)
		return r2
	end)

	local fn = state:load("function(a, b, c) return multiply_add(a, b, c) end")

	for _ = 1, 1000 do
		local result = fn(2, 3, 4)
		test.equal(9, result)
	end

	state:close()
end)

-- ─── Host callbacks returning compound types ──────────────────────────────
--
-- dispatch_callback currently calls push_primitive_or_error on the host result
-- before returning to the guest. If the host function returns a table (compound),
-- bridge.c calls lua_error(host_L) outside any pcall on host_L — undefined
-- behaviour that causes crashes or silent exits on macOS/Windows.

test.it("host callback returning a table raises a clear guest error (not a crash)", function()
	local state = lua.new()
	local g = state:globals()

	-- Host function returns a compound value (table). The bridge cannot copy
	-- tables across independent states; it must raise a clear guest-side error
	-- rather than crashing or calling lua_error on the host outside a pcall.
	g:set("get_obj", function()
		return { value = 42 }
	end)

	local ok, err = pcall(state.load, state, [[
		local obj = get_obj()
	]])
	-- Must fail with a bridge error message, not a process crash
	test.falsy(ok)
	test.truthy(type(err) == "string", "expected string error, got " .. type(err))
	test.includes(err, "bridge:")
	state:close()
end)

test.it("host callback returning a table error is catchable with guest pcall", function()
	local state = lua.new()
	local g = state:globals()

	g:set("get_obj", function()
		return { value = 42 }
	end)

	-- Guest-side pcall should catch the bridge error cleanly
	local ok, err = pcall(state.load, state, [[
		local ok, err = pcall(get_obj)
		assert(not ok, "expected error from get_obj")
		assert(type(err) == "string" and err:find("bridge:"), "expected bridge error")
	]])
	test.truthy(ok, tostring(err))
	state:close()
end)

test.it("host callback NOT returning a table still works fine", function()
	local state = lua.new()
	local g = state:globals()

	g:set("get_num", function()
		return 42
	end)

	local ok, err = pcall(state.load, state, [[
		local n = get_num()
		assert(n == 42, "expected 42, got " .. tostring(n))
	]])
	test.truthy(ok, tostring(err))
	state:close()
end)

-- ─── state:load with chunk name ───────────────────────────────────────────
--
-- state:load currently uses luaL_loadstring which does not accept a chunk name.
-- debug.getinfo inside guest code therefore returns source = "=(load)" instead
-- of the real file path, breaking packages like git2-sys that locate native
-- libraries via debug.getinfo(1, "S").source.

test.it("state:load with chunk name exposes correct source via debug.getinfo", function()
	local state = lua.new()

	local source = [[
		local info = debug.getinfo(1, "S")
		return info.source
	]]

	-- Load with an explicit chunk name (the "@path" convention)
	local chunkName = "@/some/path/to/file.lua"
	local result = state:load(source, chunkName)
	test.equal(chunkName, result)
	state:close()
end)

test.it("state:load without chunk name still works (source is =(load) or similar)", function()
	local state = lua.new()
	local result = state:load([[
		local info = debug.getinfo(1, "S")
		return info.source
	]])
	-- Without a chunk name the source will be something like "=(load)" — just
	-- verify it doesn't crash and returns a string.
	test.equal("string", type(result))
	state:close()
end)

-- ─── state:table() ────────────────────────────────────────────────────────

test.it("state:table() returns an empty lua.Table", function()
	local state = lua.new()
	local t = state:table()
	test.truthy(t)
	test.equal("table", t:type())
	state:close()
end)

test.it("state:table() result is visible to guest code", function()
	local state = lua.new()
	local g = state:globals()
	local t = state:table()
	t:set("x", 99)
	g:set("obj", t)
	local v = state:load("return obj.x")
	test.equal(99, v)
	state:close()
end)

test.it("state:table({ ... }) populates string/number/boolean keys", function()
	local state = lua.new()
	local t = state:table({ name = "alice", score = 42, active = true })
	test.equal("alice", t:get("name"))
	test.equal(42, t:get("score"))
	test.equal(true, t:get("active"))
	state:close()
end)

test.it("state:table() with integer keys", function()
	local state = lua.new()
	local t = state:table({ "a", "b", "c" })
	test.equal("a", t:get(1))
	test.equal("b", t:get(2))
	test.equal("c", t:get(3))
	state:close()
end)

test.it("state:table() with nested plain table", function()
	local state = lua.new()
	local t = state:table({ pos = { x = 1, y = 2 } })
	local pos = t:get("pos")
	test.equal("table", pos:type())
	test.equal(1, pos:get("x"))
	test.equal(2, pos:get("y"))
	state:close()
end)

test.it("state:table() with deeply nested tables", function()
	local state = lua.new()
	local t = state:table({ a = { b = { c = { d = 42 } } } })
	local g = state:globals()
	g:set("obj", t)
	local v = state:load("return obj.a.b.c.d")
	test.equal(42, v)
	state:close()
end)

test.it("state:table() with a function value registers it as host callback", function()
	local state = lua.new()
	local called = false
	local t = state:table({
		greet = function(name)
			called = true
			return "hi " .. name
		end
	})
	local g = state:globals()
	g:set("obj", t)
	local result = state:load("return obj.greet('world')")
	test.equal("hi world", result)
	test.truthy(called)
	state:close()
end)

test.it("state:table() with nil init is same as no arg", function()
	local state = lua.new()
	local t = state:table(nil)
	test.truthy(t)
	test.equal("table", t:type())
	state:close()
end)

test.it("state:table() errors on non-table init", function()
	local state = lua.new()
	local ok, err = pcall(function() state:table("oops") end)
	test.falsy(ok)
	test.includes(err, "init argument must be a table")
	state:close()
end)

test.it("state:table() errors on unsupported key type", function()
	local state = lua.new()
	local ok, err = pcall(function()
		state:table({ [{}] = "bad" })
	end)
	test.falsy(ok)
	test.includes(err, "unsupported key type")
	state:close()
end)

test.it("state:table() result can be passed to a guest function and read back", function()
	local state = lua.new()
	local t = state:table({ value = 7 })
	local fn = state:load("function(tbl) return tbl.value * 6 end")
	local result = fn(t)
	test.equal(42, result)
	state:close()
end)

test.it("state:table() result can be mutated by guest code and read on host", function()
	local state = lua.new()
	local t = state:table({ count = 0 })
	local g = state:globals()
	g:set("counter", t)
	state:load("counter.count = counter.count + 10")
	test.equal(10, t:get("count"))
	state:close()
end)

-- ─── Table auto-coercion ──────────────────────────────────────────────────
--
-- Plain host tables passed to Table:set (or the __newindex proxy) are
-- automatically coerced into guest tables via toLua → state:table().

test.it("plain table assigned to global becomes a guest table", function()
	local state = lua.new()
	local g = state:globals()
	g.config = { timeout = 5, retries = 3 }
	local timeout = state:load("return config.timeout")
	local retries = state:load("return config.retries")
	test.equal(5, timeout)
	test.equal(3, retries)
	state:close()
end)

test.it("plain table coercion works with :set() too", function()
	local state = lua.new()
	local g = state:globals()
	g:set("data", { x = 10, y = 20 })
	test.equal(10, g.data.x)
	test.equal(20, g.data.y)
	state:close()
end)

test.it("nested plain tables are recursively coerced", function()
	local state = lua.new()
	local g = state:globals()
	g.player = { name = "alice", pos = { x = 1, y = 2 } }
	test.equal("alice", g.player.name)
	test.equal(1, g.player.pos.x)
	test.equal(2, g.player.pos.y)
	local fromGuest = state:load("return player.pos.x + player.pos.y")
	test.equal(3, fromGuest)
	state:close()
end)

test.it("array-like plain tables coerce to guest tables with integer keys", function()
	local state = lua.new()
	local g = state:globals()
	g.items = { "a", "b", "c" }
	local result = state:load("return items[1] .. items[2] .. items[3]")
	test.equal("abc", result)
	state:close()
end)

test.it("coerced table can be passed as argument to guest function", function()
	local state = lua.new()
	local fn = state:load("function(t) return t.a + t.b end")
	local result = fn({ a = 10, b = 32 })
	test.equal(42, result)
	state:close()
end)

test.it("coerced table with nested functions works in guest code", function()
	local state = lua.new()
	local g = state:globals()
	g.api = { greet = function(n) return "hi " .. n end }
	local result = state:load("return api.greet('world')")
	test.equal("hi world", result)
	state:close()
end)

test.it("coerced table can contain guest values (lua.Table)", function()
	local state = lua.new()
	local g = state:globals()
	local inner = state:table({ key = "inner-value" })
	g.wrapper = { child = inner, label = "top" }
	test.equal("top", g.wrapper.label)
	test.equal("inner-value", g.wrapper.child.key)
	state:close()
end)

test.it("coerced table is mutable from guest side", function()
	local state = lua.new()
	local g = state:globals()
	g.counter = { n = 0 }
	state:load("counter.n = counter.n + 5")
	state:load("counter.n = counter.n + 7")
	test.equal(12, g.counter.n)
	state:close()
end)

test.it("deeply nested table coercion does not corrupt guest state", function()
	local state = lua.new()
	local g = state:globals()
	g.deep = { a = { b = { c = { d = { e = 42 } } } } }
	local result = state:load("return deep.a.b.c.d.e")
	test.equal(42, result)
	-- After coercion the state should still be usable
	g.other = "hello"
	test.equal("hello", state:load("return other"))
	state:close()
end)

test.it("multiple table coercions in sequence do not corrupt stack", function()
	local state = lua.new()
	local g = state:globals()
	for i = 1, 20 do
		g["t" .. i] = { index = i }
	end
	for i = 1, 20 do
		test.equal(i, state:load("return t" .. i .. ".index"))
	end
	state:close()
end)

test.it("self-referencing table raises a cycle error", function()
	local state = lua.new()
	local t = {}
	t.self = t
	local ok, err = pcall(function()
		state:table(t)
	end)
	test.falsy(ok)
	test.includes(err, "cycle detected")
	-- State should still be usable after the error
	local g = state:globals()
	g.x = 42
	test.equal(42, state:load("return x"))
	state:close()
end)

test.it("mutually-referencing tables raise a cycle error", function()
	local state = lua.new()
	local a = {}
	local b = { prev = a }
	a.next = b
	local ok, err = pcall(function()
		state:table(a)
	end)
	test.falsy(ok)
	test.includes(err, "cycle detected")
	state:close()
end)

test.it("table coercion via __newindex also detects cycles", function()
	local state = lua.new()
	local g = state:globals()
	local t = {}
	t.self = t
	local ok, err = pcall(function()
		g.bad = t
	end)
	test.falsy(ok)
	test.includes(err, "cycle detected")
	state:close()
end)

test.it("cycle detection does not false-positive on non-cyclic duplicates", function()
	local state = lua.new()
	-- Same table value appearing twice is fine (independent copies)
	local child = { x = 1 }
	local t = { a = child, b = child }
	local gt = state:table(t)
	local g = state:globals()
	g.dup = gt
	-- Both guest tables have x = 1
	test.equal(1, state:load("return dup.a.x"))
	test.equal(1, state:load("return dup.b.x"))
	-- Mutating one does not affect the other (they are independent copies)
	state:load("dup.a.x = 99")
	test.equal(99, gt.a.x)
	test.equal(1, gt.b.x)
	state:close()
end)
