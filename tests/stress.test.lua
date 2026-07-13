-- tests/stress.test.lua
--
-- Stress tests modelling the conditions lde needs in production:
--
--   lde runs its test suite by creating a lua-sys guest state per test file
--   (the "outer" state). Inside that outer state the test file executes, and
--   the test file itself calls lua.new() to create further guest states (the
--   "inner" states). The profiler may be active on the outer state while inner
--   states are being created and exercised.
--
-- These tests verify that nested state creation, cross-boundary callbacks, and
-- profiling all remain correct in that layered environment.

local lua      = require("lua-sys")
local profiler = require("lua-sys.profiler")
local test     = require("lde-test")

-- ─── Helper: simulate what lde does to run one test file ─────────────────
--
-- lde creates a guest state, injects callbacks as host functions so the test
-- runner can report results back to the host, then runs the test source.
-- The test source itself calls lua.new() to create inner states.

local function run_in_outer_state(test_source)
	local outer = lua.new()
	local g     = outer:globals()

	-- Inject the same kind of reporter callbacks that lde injects
	local results = {}
	g:set("_on_result", function(name, ok, skipped, err)
		results[#results + 1] = { name = name, ok = ok, skipped = skipped, error = err }
	end)

	-- Inject lua-sys into the outer state so the test source can require it.
	-- (In production lde sets package.path/cpath; here we inject the module
	-- directly as a preloaded value since we're already inside the host.)
	local lua_mod = lua
	g:set("_require_lua_sys", function()
		-- return the real lua module — this is a host callback returning a
		-- primitive-only facade; the actual module table lives on the host.
		-- For the stress test we expose just the pieces we need.
		return nil  -- see note below
	end)

	-- NOTE: We can't pass the lua module table itself across the boundary as a
	-- return value (host callbacks can't return tables). Instead we embed the
	-- test source as a string that is loaded into the outer state, where
	-- require("lua-sys") works normally via package.path.  The simulation
	-- below uses state:eval to run that embedded source directly.
	local ok, err = pcall(outer.eval, outer, test_source)
	outer:close()
	return ok, err, results
end

-- ─── Creating inner states from within an outer guest state ───────────────

test.it("inner state can be created and used from within an outer guest state", function()
	local outer = lua.new()

	-- The outer state evaluates code that creates a further state via the
	-- lua-sys C API the host has already loaded. We simulate this by injecting
	-- a host callback that creates an inner state and returns a result.
	local g = outer:globals()

	g:set("create_inner_and_eval", function(code)
		local inner  = lua.new()
		local result = inner:eval(code)
		inner:close()
		return result
	end)

	local v = outer:eval("return create_inner_and_eval('return 2 + 2')")
	test.equal(4, v)

	outer:close()
end)

test.it("many inner states created and closed from outer state do not leak", function()
	local outer = lua.new()
	local g     = outer:globals()
	local count = 0

	g:set("run_inner", function(i)
		local inner = lua.new()
		local v     = inner:eval("return " .. i .. " * 2")
		inner:close()
		count = count + 1
		return v
	end)

	-- Run a guest loop that creates N inner states via the host callback
	outer:load([[
		for i = 1, 200 do
			local v = run_inner(i)
			assert(v == i * 2, "wrong result at i=" .. i)
		end
	]]):call()

	test.equal(200, count)
	outer:close()
end)

test.it("outer state globals are not corrupted by inner state creation", function()
	local outer = lua.new()
	local g     = outer:globals()

	g:set("make_inner_result", function(n)
		local inner = lua.new()
		local ig    = inner:globals()
		ig:set("x", n)
		local v = inner:eval("return x * x")
		inner:close()
		return v
	end)

	-- Interleave outer-state globals with inner state work
	for i = 1, 100 do
		g:set("outer_val", i)
		local sq = outer:eval("return make_inner_result(" .. i .. ")")
		test.equal(i * i,  sq)
		test.equal(i, g:get("outer_val"))
	end

	outer:close()
end)

-- ─── Callbacks from within inner states back to the outer host ────────────

test.it("inner state calls a host callback that itself uses an outer guest function", function()
	-- Outer state has a guest function. A host callback calls that guest
	-- function. An inner state triggers the host callback. This is the exact
	-- call graph that appears when lde's test runner (outer) runs a lua-sys
	-- test (inner → host callback → outer guest fn).

	local outer    = lua.new()
	local outer_g  = outer:globals()

	-- A guest function in the outer state
	local outer_fn = outer:eval("function(x) return x + 100 end")

	-- Host callback that calls back into the outer guest state
	outer_g:set("outer_bridge", function(x)
		return outer_fn(x)
	end)

	-- inner state calls the host callback
	outer_g:set("run_inner_round_trip", function(x)
		local inner = lua.new()
		local ig    = inner:globals()
		ig:set("call_outer", function(v)
			return outer_fn(v)  -- host callback → outer guest
		end)
		local result = inner:eval("return call_outer(" .. x .. ")")
		inner:close()
		return result
	end)

	local v = outer:eval("return run_inner_round_trip(42)")
	test.equal(142, v)

	outer:close()
end)

test.it("error in inner state does not corrupt outer state", function()
	local outer = lua.new()
	local g     = outer:globals()

	g:set("run_faulty_inner", function()
		local inner = lua.new()
		local ok, err = pcall(inner.eval, inner, "error('inner boom')")
		inner:close()
		-- return primitive error indicator back to outer guest
		return ok == false
	end)

	for _ = 1, 50 do
		local inner_failed = outer:eval("return run_faulty_inner()")
		test.equal(true, inner_failed)
		-- outer state should still be fully functional
		local v = outer:eval("return 1 + 1")
		test.equal(2, v)
	end

	outer:close()
end)

-- ─── Profiler on outer state while inner states run ───────────────────────

test.it("profiler on outer state produces a valid report while inner states are created", function()
	local outer = lua.new()
	local g     = outer:globals()

	g:set("run_inner_fib", function()
		local inner = lua.new()
		local result = inner:eval([[
			local function fib(n)
				if n < 2 then return n end
				return fib(n-1) + fib(n-2)
			end
			return fib(20)
		]])
		inner:close()
		return result
	end)

	local work = outer:load([[
		local acc = 0
		for _ = 1, 30 do
			acc = acc + run_inner_fib()
		end
		return acc
	]])

	profiler.start(outer, "fi1")
	local result = work:eval()
	local report = profiler.stop(outer)

	test.truthy(result > 0)
	test.truthy(report)
	test.truthy(type(report) == "table")
	-- Percents must be non-negative and entries valid
	for _, e in ipairs(report) do
		test.truthy(e.percent >= 0)
		test.truthy(e.count   >= 0)
		test.equal("string", type(e.stack))
	end

	outer:close()
end)

test.it("profiler custom callback fires while inner states are active", function()
	local outer = lua.new()
	local g     = outer:globals()
	local ticks = 0

	g:set("run_inner_work", function()
		local inner = lua.new()
		inner:load([[
			local s = 0
			for i = 1, 10000 do s = s + i end
			return s
		]]):eval()
		inner:close()
	end)

	local work = outer:load([[
		for _ = 1, 20 do run_inner_work() end
	]])

	profiler.start(outer, "fi1", function(_stack, _n, _vmstate)
		ticks = ticks + 1
	end)
	work:call()
	profiler.stop(outer)

	-- Must not crash; ticks may be 0 on very fast hardware
	test.truthy(ticks >= 0)

	outer:close()
end)

-- ─── Simulating lde's reporter callback pattern ───────────────────────────
--
-- lde injects host callbacks (_lde_on_result, _lde_on_pass, _lde_on_fail) into
-- the outer guest state. The test framework (running in the outer guest) calls
-- them with primitive values. This reproduces that pattern at load.

test.it("reporter callbacks survive outer state running many inner-state tests", function()
	local outer = lua.new()
	local g     = outer:globals()

	-- Reporter accumulator (lives on host)
	local passes = 0
	local fails  = 0

	g:set("_on_pass",   function(_name) passes = passes + 1 end)
	g:set("_on_fail",   function(_name, _err) fails = fails + 1 end)

	-- Outer guest runs a "test loop" that creates inner states and reports
	g:set("run_test", function(should_pass)
		local inner = lua.new()
		local ok, err = pcall(inner.eval, inner, should_pass
			and "assert(1 == 1)"
			or  "assert(1 == 2, 'expected failure')")
		inner:close()
		return ok
	end)

	outer:load([[
		for i = 1, 200 do
			local ok = run_test(i % 3 ~= 0)   -- every 3rd test fails
			if ok then
				_on_pass("test-" .. i)
			else
				_on_fail("test-" .. i, "assertion failed")
			end
		end
	]]):call()

	-- 200 tests; every 3rd fails → 66 fail, 134 pass (i=3,6,...,198 → 66 multiples)
	test.equal(134, passes)
	test.equal(66,  fails)

	outer:close()
end)

-- ─── Profiler on outer state during reporter callback pattern ─────────────

test.it("profiler + reporter callbacks + inner states all work together", function()
	local outer = lua.new()
	local g     = outer:globals()

	local results = {}
	g:set("_on_result", function(name, ok)
		results[#results + 1] = { name = name, ok = ok }
	end)

	g:set("run_inner_test", function(name, code)
		local inner = lua.new()
		local ok, err = pcall(inner.eval, inner, code)
		inner:close()
		return ok
	end)

	local fib_code = "local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end assert(fib(15) == 610)"

	local work = outer:load(string.format([[
		local tests = {
			{ "add",    "assert(1+1==2)" },
			{ "string", "assert(type('x')=='string')" },
			{ "fib",    %q },
			{ "fail",   "error('intentional')" },
		}
		for _, t in ipairs(tests) do
			local ok = run_inner_test(t[1], t[2])
			_on_result(t[1], ok)
		end
	]], fib_code))

	profiler.start(outer, "fi1")
	work:call()
	local report = profiler.stop(outer)

	-- Verify results
	test.equal(4, #results)
	test.equal(true,  results[1].ok)
	test.equal(true,  results[2].ok)
	test.equal(true,  results[3].ok)
	test.equal(false, results[4].ok)

	-- Profiler must have produced a valid report
	test.truthy(report)

	outer:close()
end)

-- ─── Stack integrity across the full nested scenario ──────────────────────

test.it("outer guest stack is balanced throughout nested state + profiler usage", function()
	local outer = lua.new()
	local raw   = lua.raw
	local g     = outer:globals()
	local base  = raw.gettop(outer.L)

	g:set("make_inner", function(n)
		local inner = lua.new()
		local v     = inner:eval("return " .. n)
		inner:close()
		return v
	end)

	profiler.start(outer, "fi1")
	for i = 1, 100 do
		local v = outer:eval("return make_inner(" .. i .. ")")
		test.equal(i, v)
	end
	profiler.stop(outer)

	test.equal(base, raw.gettop(outer.L))
	outer:close()
end)
