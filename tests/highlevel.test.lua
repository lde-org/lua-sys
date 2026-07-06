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
	test.equal(42,      tbl.x)
	test.equal("hello", tbl.msg)
	test.equal(true,    tbl.flag)
	state:close()
end)

test.it("__index does not shadow Table methods", function()
	local state = lua.new()
	-- guest table has a key named 'get' — the method must still win
	local tbl = state:load([[{get = "notamethod"}]])
	test.equal("function", type(tbl.get))  -- method, not the guest string
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
	test.equal(3, (function() local n = 0; for _ in pairs(got) do n = n + 1 end; return n end)())
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
		keys[#keys+1] = i
		vals[#vals+1] = v
	end
	test.equal(3, #keys)
	test.equal(1,  keys[1]); test.equal(10, vals[1])
	test.equal(2,  keys[2]); test.equal(20, vals[2])
	test.equal(3,  keys[3]); test.equal(30, vals[3])
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
	for _, v in tbl:ipairs() do vals[#vals+1] = v end
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
