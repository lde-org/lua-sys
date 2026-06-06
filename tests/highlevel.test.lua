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

test.it("state:load returns a lua.Function for a function expression", function()
	local state = lua.new()
	local fn = state:load("return function(a, b) return a + b end")
	test.truthy(fn)
	test.equal("function", fn:type())
	state:close()
end)

test.it("state:load handles explicit return chunks too", function()
	local state = lua.new()
	local v = state:load("return 42")
	test.truthy(v)
	test.equal("number", v:type())
	test.equal(42, v:value())
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

-- ─── Function:call / pcall ────────────────────────────────────────────────

test.it("fn:call returns results as lua.Values", function()
	local state = lua.new()
	local fn = state:load("function(a, b) return a + b end")
	local result = fn:call(3, 4)
	test.equal("number", result:type())
	test.equal(7, result:value())
	state:close()
end)

test.it("fn:call passes string arguments", function()
	local state = lua.new()
	local fn = state:load("function(s) return s .. '!' end")
	local result = fn:call("hello")
	test.equal("string", result:type())
	test.equal("hello!", result:value())
	state:close()
end)

test.it("fn:call passes boolean arguments", function()
	local state = lua.new()
	local fn = state:load("function(b) return not b end")
	local result = fn:call(true)
	test.equal("boolean", result:type())
	test.equal(false, result:value())
	state:close()
end)

test.it("fn:call returns multiple results", function()
	local state = lua.new()
	local fn = state:load("function(a, b) return a, b, a + b end")
	local r1, r2, r3 = fn:call(10, 20)
	test.equal(10, r1:value())
	test.equal(20, r2:value())
	test.equal(30, r3:value())
	state:close()
end)

test.it("fn:pcall returns true and results on success", function()
	local state = lua.new()
	local fn = state:load("function(x) return x * 2 end")
	local ok, result = fn:pcall(21)
	test.equal(true, ok)
	test.equal(42, result:value())
	state:close()
end)

test.it("fn:pcall returns false and error string on failure", function()
	local state = lua.new()
	local fn = state:load("function() error('boom') end")
	local ok, err = fn:pcall()
	test.equal(false, ok)
	test.equal("string", type(err))
	test.includes(err, "boom")
	state:close()
end)

test.it("fn:call can pass lua.Value results as arguments", function()
	local state = lua.new()
	local double = state:load("function(x) return x * 2 end")
	local r = double:call(5)  -- r is a lua.Value number
	local again = double:call(r) -- pass Value directly
	test.equal(20, again:value())
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

test.it("globals:get returns known global", function()
	local state = lua.new()
	local g = state:globals()
	local v = g:get("type")
	test.truthy(v)
	test.equal("function", v:type())
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
	test.equal("number", v:type())
	test.equal(42, v:value())
	state:close()
end)

test.it("globals:set / globals:get roundtrip for string", function()
	local state = lua.new()
	local g = state:globals()
	g:set("greeting", "hello")
	local v = g:get("greeting")
	test.equal("string", v:type())
	test.equal("hello", v:value())
	state:close()
end)

test.it("globals:set / globals:get roundtrip for boolean", function()
	local state = lua.new()
	local g = state:globals()
	g:set("flag", true)
	local v = g:get("flag")
	test.equal("boolean", v:type())
	test.equal(true, v:value())
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

test.it("globals:set accepts a lua.Value", function()
	local state = lua.new()
	local fn    = state:load("function(x) return x + 1 end")
	local g     = state:globals()
	g:set("increment", fn)
	-- verify it's visible from within Lua by loading a wrapper function and calling it
	local runner = state:load("function() return increment(9) end")
	local v = runner:call()
	test.equal(10, v:value())
	state:close()
end)

-- ─── Lua function wrapping ────────────────────────────────────────────────

test.it("globals:set accepts a plain Lua function (wrapped as CFunction)", function()
	local state = lua.new()
	local g = state:globals()

	g:set("add", function(st, a, b)
		return a:value() + b:value()
	end)

	local v = state:load("return add(3, 4)")
	test.equal(7, v:value())
	state:close()
end)

test.it("wrapped Lua function can return multiple values", function()
	local state = lua.new()
	local g = state:globals()

	g:set("swap", function(st, a, b)
		return b, a
	end)

	-- load runs the chunk; swap returns two values but load captures only the first
	local fn = state:load("function() return swap(1, 2) end")
	local r1, r2 = fn:call()
	test.equal(2, r1:value())
	test.equal(1, r2:value())
	state:close()
end)

test.it("wrapped Lua function returning nil produces no results", function()
	local state = lua.new()
	local g = state:globals()
	local called = false

	g:set("noop", function(st)
		called = true
	end)

	local v = state:load("noop(); return 'done'")
	test.equal(true, called)
	test.equal("done", v:value())
	state:close()
end)

-- ─── Value helpers ────────────────────────────────────────────────────────

test.it("Value:type() covers all core types", function()
	local state = lua.new()

	local fn    = state:load("function() end")
	local tbl   = state:load("{}")

	test.equal("function", fn:type())
	test.equal("table", tbl:type())

	state:close()
end)

test.it("Value:value() unwraps primitives and returns self for compound types", function()
	local state = lua.new()
	local fn = state:load("function(a, b) return a, b end")

	local numV, strV = fn:call(3.14, "hi")
	test.equal(3.14, numV:value())
	test.equal("hi", strV:value())

	local tbl = state:load("{}")
	test.equal(tbl, tbl:value()) -- compound type returns self

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
	fn:call(v)
	fn:pcall(v)

	test.equal(base, raw.gettop(L))
	state:close()
end)
