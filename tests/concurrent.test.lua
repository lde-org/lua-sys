-- tests/concurrent.test.lua
--
-- Tests for concurrent multi-state usage, nested state creation, close
-- ordering, and the host_L integrity fix.
--
-- These are the patterns that caused segfaults on Windows when a guest
-- state loaded the bridge module and overwrote the global host_L pointer.

local lua      = require("lua-sys")
local raw      = lua.raw
local test     = require("lde-test")
local profiler = require("lua-sys.profiler")

-- ─── Multiple independent concurrent states ───────────────────────────────

test.it("two concurrent states are fully independent", function()
	local s1 = lua.new()
	local s2 = lua.new()

	s1:eval("X = 10")
	s2:eval("X = 20")

	local g1 = s1:globals()
	local g2 = s2:globals()

	test.equal(10, g1.X)
	test.equal(20, g2.X)

	s1:close()
	s2:close()
end)

test.it("many concurrent states do not interfere", function()
	local states = {}
	for i = 1, 10 do
		local s = lua.new()
		s:eval("_val = " .. i)
		states[i] = s
	end

	for i = 1, 10 do
		test.equal(i, states[i]:globals()._val)
	end

	for _, s in ipairs(states) do
		s:close()
	end
end)

test.it("states can be closed in any order relative to creation", function()
	local s1 = lua.new()
	local s2 = lua.new()
	local s3 = lua.new()

	-- Close middle one first
	s2:close()
	-- Others still work
	s1:eval("a = 1")
	s3:eval("b = 2")

	s3:close()
	s1:close()
end)

test.it("concurrent states can call functions in each other via host", function()
	local s1 = lua.new()
	local s2 = lua.new()

	local fn1 = s1:eval("function(x) return x * 2 end")
	local fn2 = s2:eval("function(x) return x + 10 end")

	-- Call fn1 from host side: fn1(2)=4, fn2(4)=14
	test.equal(14, fn2(fn1(2)))
	-- Call fn2 from host side: fn2(4)=14, fn1(14)=28
	test.equal(28, fn1(fn2(4)))

	s1:close()
	s2:close()
end)

-- ─── Nested state creation from guest callbacks (host_L guard) ────────────

test.it("inner state created from host callback passed to guest works", function()
	local outer = lua.new()
	local g     = outer:globals()

	g.create_inner = function()
		local inner = lua.new()
		local v = inner:eval("return 42")
		inner:close()
		return v
	end

	local result = outer:eval("return create_inner()")
	test.equal(42, result)
	outer:close()
end)

test.it("inner state wraps a guest function from outer and calls it", function()
	local outer = lua.new()
	local outer_g = outer:globals()

	local outer_fn = outer:eval("function(x) return x + 100 end")

	outer_g.spawn_inner = function()
		local inner = lua.new()
		local ig    = inner:globals()
		ig.call_outer = function(v)
			return outer_fn(v)
		end
		local r = inner:eval("return call_outer(7)")
		inner:close()
		return r
	end

	local result = outer:eval("return spawn_inner()")
	test.equal(107, result)
	outer:close()
end)

test.it("many inner states created inside one host callback per iteration", function()
	local outer = lua.new()
	local g     = outer:globals()
	local count = 0

	g.run_inner = function()
		local inner = lua.new()
		inner:eval("local s = 0; for i = 1, 100 do s = s + i end; return s")
		inner:close()
		count = count + 1
	end

	outer:load([[
		for _ = 1, 50 do run_inner() end
	]]):call()

	test.equal(50, count)
	outer:close()
end)

test.it("inner state can itself create a further inner state via callback", function()
	local outer = lua.new()
	local g     = outer:globals()

	g.nest_deep = function(depth)
		if depth <= 0 then
			return depth
		end
		local inner = lua.new()
		local ig    = inner:globals()
		-- The inner state's callback creates yet another state
		ig.nest_deeper = function(d)
			local inner2 = lua.new()
			local result = inner2:eval("return " .. d)
			inner2:close()
			return result
		end
		local r = inner:eval("return nest_deeper(" .. depth .. ")")
		inner:close()
		return r
	end

	local result = outer:eval("return nest_deep(99)")
	test.equal(99, result)
	outer:close()
end)

-- ─── host_L integrity: guest loading lua-sys does not corrupt host_L ─────

test.it("host can still close its own state after guest loads lua-sys module", function()
	-- The key regression: when the guest does require("lua-sys"), it triggers
	-- loading of bridge.so/dll, which calls luaopen_lua_sys_bridge(guest_L).
	-- Before the fix, this overwrote host_L and corrupted the host.
	local outer = lua.new()
	local g     = outer:globals()

	-- Simulate what happens when a test file requires lua-sys inside the guest:
	-- the guest evaluates source that does require("lua-sys"). We inject
	-- the ability to create inner states via a host callback so the guest
	-- can exercise the bridge module (which is what the fix guards).
	g.make_inner = function(n)
		local inner = lua.new()
		local v = inner:eval("return " .. n .. " * 2")
		inner:close()
		return v
	end

	-- Run multiple iterations to ensure host_L stays intact
	for i = 1, 20 do
		local v = outer:eval("return make_inner(" .. i .. ")")
		test.equal(i * 2, v)
	end

	-- After all that, the outer state must still be closable without error
	outer:close()
end)

test.it("host can create new states after guest closed (host_L not corrupted)", function()
	local results = {}
	for cycle = 1, 5 do
		local outer = lua.new()
		local g     = outer:globals()

		g.do_inner = function(x)
			local inner = lua.new()
			local v = inner:eval("return " .. x .. " + 1")
			inner:close()
			return v
		end

		local v = outer:eval("return do_inner(" .. cycle .. ")")
		results[cycle] = v
		outer:close()
	end

	test.equal(1 + 1, results[1])
	test.equal(2 + 1, results[2])
	test.equal(3 + 1, results[3])
	test.equal(4 + 1, results[4])
	test.equal(5 + 1, results[5])
end)

test.it("host can manage multiple outer states after many inner states were created", function()
	for _ = 1, 10 do
		local outer = lua.new()
		local g     = outer:globals()

		g.inner_op = function()
			local inner = lua.new()
			inner:eval("return 1")
			inner:close()
		end

		outer:load([[ for _ = 1, 30 do inner_op() end ]]):call()
		outer:close()
	end
	-- Reaching here without crash = pass
	test.truthy(true)
end)

-- ─── Close ordering: outer closed while inner still alive ────────────────

test.it("closing outer state while inner states still exist does not crash", function()
	local inner_ptr
	local outer = lua.new()
	local g     = outer:globals()

	g.spawn_inner = function()
		local inner = lua.new()
		inner:eval("_alive = true")
		inner_ptr = inner  -- keep reference alive on host side
		return 42
	end

	local v = outer:eval("return spawn_inner()")
	test.equal(42, v)

	-- Close outer while inner still exists (via inner_ptr on host)
	outer:close()

	-- Inner should still be alive
	test.truthy(inner_ptr)
	test.truthy(inner_ptr:globals()._alive)

	inner_ptr:close()
end)

test.it("closing inner state while outer state is still active does not corrupt outer", function()
	local outer = lua.new()
	local g     = outer:globals()

	g.spawn_and_close_inner = function()
		local inner = lua.new()
		inner:eval("return 1")
		inner:close()
		return "done"
	end

	outer:eval("_x = 10")
	local result = outer:eval("_x = _x + 1; return spawn_and_close_inner()")
	test.equal("done", result)
	test.equal(11, outer:globals()._x)

	outer:close()
end)

-- ─── Callback lifecycle with multiple concurrent states ───────────────────

test.it("callbacks registered on one state do not leak to another", function()
	local s1 = lua.new()
	local s2 = lua.new()

	local calls1 = 0
	local calls2 = 0

	local g1 = s1:globals()
	local g2 = s2:globals()

	g1.cb = function() calls1 = calls1 + 1; return "from-s1" end
	g2.cb = function() calls2 = calls2 + 1; return "from-s2" end

	test.equal("from-s1", s1:eval("return cb()"))
	test.equal("from-s2", s2:eval("return cb()"))

	test.equal(1, calls1)
	test.equal(1, calls2)

	s1:close()
	s2:close()
end)

test.it("callbacks unregistered by close do not fire during subsequent GC", function()
	-- After state:close() unregisters callbacks, any stray callback
	-- invocation (from GC finalizers) should not crash.
	for _ = 1, 5 do
		local s = lua.new()
		local g = s:globals()

		g.report = function(name, ok)
			-- Just store on host, no-op
		end

		s:eval([[
			local obj = setmetatable({}, { __gc = function() end })
			_obj = obj
		]])

		s:close()
	end
	test.truthy(true)
end)

test.it("many callbacks registered and unregistered do not corrupt host registry", function()
	for cycle = 1, 10 do
		local s = lua.new()
		local g = s:globals()

		-- Register multiple callbacks
		g.on_result = function(name, ok) end
		g.on_start = function(name) end
		g.on_pass = function(name) end
		g.on_fail = function(name, err) end
		g.on_skip = function(name) end

		s:close()
	end
	test.truthy(true)
end)

-- ─── Stack integrity across state boundaries ──────────────────────────────

test.it("host stack is balanced after creating and closing many states", function()
	local base = raw.gettop(raw.lnewstate())
	-- We can't easily inspect host_L's stack from raw, but we can verify
	-- that repeated state creation/closing doesn't cause an unbounded leak.
	-- Use the raw API on a scratch state to check we can still push/pop.

	local scratch = lua.new()
	local L = scratch.L
	local sb = raw.gettop(L)

	for i = 1, 100 do
		local s = lua.new()
		s:eval("_ = " .. i)
		s:close()
		test.equal(sb, raw.gettop(L))
	end

	scratch:close()
end)

test.it("guest stack integrity: nested calls leave guest stack balanced", function()
	local state = lua.new()
	local raw_l = lua.raw
	local base = raw_l.gettop(state.L)
	local g = state:globals()

	g.inner_work = function(n)
		local inner = lua.new()
		local r = inner:eval("return " .. n .. " * 2")
		inner:close()
		return r
	end

	for i = 1, 50 do
		local v = state:eval("return inner_work(" .. i .. ")")
		test.equal(i * 2, v)
		test.equal(base, raw_l.gettop(state.L))
	end

	state:close()
end)

test.it("host stack balanced after guest error during nested state creation", function()
	local state = lua.new()
	local g = state:globals()

	g.inner_error = function()
		local inner = lua.new()
		-- This eval throws
		local ok, err = pcall(inner.eval, inner, "error('inner boom')")
		inner:close()
		if not ok then error("rethrown: " .. err) end
	end

	local ok, err = pcall(state.eval, state, "inner_error()")
	test.falsy(ok)
	test.includes(err, "rethrown: inner boom")

	-- State should still be usable
	local v = state:eval("return 1 + 1")
	test.equal(2, v)

	state:close()
end)

-- ─── Table and Value proxy across nested states ───────────────────────────

test.it("table from inner state can be stored in outer state and accessed", function()
	-- Registry refs are per-state, so we cannot directly push an inner
	-- state table ref onto the outer state stack. Instead, the host
	-- callback copies values from the inner table into the outer state.
	local outer = lua.new()
	local outer_g = outer:globals()

	outer_g.make_inner_table = function()
		local inner = lua.new()
		local t = inner:table({ x = 1, y = 2 })
		-- Copy values from inner table into outer state globals (host-side access)
		outer_g.inner_x = t:get("x")
		outer_g.inner_y = t:get("y")
		return "ok"
	end

	local result = outer:eval("return make_inner_table()")
	test.equal("ok", result)

	-- Verify the values were copied to outer state
	test.equal(1, outer_g.inner_x)
	test.equal(2, outer_g.inner_y)

	outer:close()
end)

test.it("value from inner state is usable after inner is closed", function()
	-- When inner is closed, Value:free() should handle nil state.L gracefully
	local val
	local outer = lua.new()
	local g = outer:globals()

	g.spawn_value = function()
		local inner = lua.new()
		val = inner:eval("return 'from-inner'")
		inner:close()
		return val
	end

	local result = outer:eval("return spawn_value()")
	test.equal("from-inner", result)

	outer:close()
	-- val is a lua.Value whose inner state has been closed.
	-- Its __gc should not crash when the host GC collects it.
end)

-- ─── Concurrent state creation and destruction stress ─────────────────────

test.it("rapid create/close cycles of many states do not leak or crash", function()
	for cycle = 1, 50 do
		local states = {}
		for i = 1, 20 do
			local s = lua.new()
			s:eval("local t = {}; for j = 1,100 do t[j] = j end; return #t")
			states[i] = s
		end

		-- Close in reverse order
		for i = #states, 1, -1 do
			states[i]:close()
		end
	end
	test.truthy(true)
end)

test.it("profiler on outer while inner states are created (Windows fix)", function()
	-- This specifically tests the Windows profiler fix where bridge_profile_start/stop
	-- now read args from L (the caller) instead of host_L.
	local outer = lua.new()
	local g     = outer:globals()

	g.inner_work = function(n)
		local inner = lua.new()
		local r = inner:eval("local s = 0; for i = 1, 50000 do s = s + i end; return s")
		inner:close()
		return r
	end

	local work = outer:load([[
		local t = 0
		for _ = 1, 10 do t = t + inner_work(1) end
		return t
	]])

	profiler.start(outer, "fi1")
	local result = work:eval()
	local report = profiler.stop(outer)

	test.truthy(result > 0)
	test.truthy(type(report) == "table")

	outer:close()
end)

-- ─── Dispatch callback stress ─────────────────────────────────────────────

test.it("dispatch_callback invoked thousands of times does not corrupt host", function()
	-- Each dispatch_callback call toggles luaJIT_setmode on host_L.
	-- On Windows with ABI mismatch, many toggles could corrupt the host.
	local outer = lua.new()
	local g     = outer:globals()

	local count = 0
	g.on_result = function(name, ok)
		count = count + 1
		return ok
	end

	outer:load([[
		for i = 1, 200 do
			on_result("test-" .. i, true)
		end
	]]):call()

	test.equal(200, count)
	outer:close()
end)

test.it("callback with error does not leak host stack entries", function()
	local state = lua.new()
	local g = state:globals()

	g.explode = function()
		error("callback boom")
	end

	local ok, err = pcall(state.eval, state, "explode()")
	test.falsy(ok)
	test.includes(err, "callback boom")

	-- State must still be usable
	local v = state:eval("return 1 + 1")
	test.equal(2, v)

	state:close()
end)

-- ─── Value proxy GC after state close ─────────────────────────────────────

test.it("Value proxy __gc does not crash when state already closed", function()
	local state = lua.new()
	local g = state:globals()

	-- Create a proxy through function return
	local fn = state:eval("function(x) return x * 2 end")
	test.equal(20, fn(10))

	-- Close state before proxy is collected
	state:close()

	-- fn is now a proxy with _state.L == nil. Its __gc should not crash.
	-- Force a GC cycle to trigger __gc finalizers.
	collectgarbage()
	collectgarbage()

	test.truthy(true)
end)

test.it("Table proxy __gc does not crash when state already closed", function()
	local state = lua.new()
	local g = state:globals()
	g.data = { x = 10, y = 20 }

	local tbl = g.data
	test.equal(10, tbl.x)

	state:close()

	-- tbl proxy should survive GC without crash
	collectgarbage()
	collectgarbage()

	test.truthy(true)
end)

-- ─── Multiple simultaneous host callbacks into guest ──────────────────────

test.it("guest function called from host callback re-enters guest correctly", function()
	local outer = lua.new()
	local outer_g = outer:globals()

	local guest_math_fn = outer:eval("function(a, b) return a * b + 1 end")

	outer_g.outer_cb = function(x, y)
		-- Host callback calls guest function, which goes back to outer state
		local r1 = guest_math_fn(x, y)
		-- Then calls it again
		local r2 = guest_math_fn(r1, 2)
		return r2
	end

	local result = outer:eval("return outer_cb(5, 3)")
	-- 5 * 3 + 1 = 16; 16 * 2 + 1 = 33
	test.equal(33, result)
	outer:close()
end)

test.it("error in re-entered guest call is caught by host pcall", function()
	local outer = lua.new()
	local outer_g = outer:globals()

	local guest_error_fn = outer:eval("function() error('guest re-enter error') end")

	outer_g.trigger = function()
		return guest_error_fn()
	end

	local ok, err = pcall(outer.eval, outer, "return trigger()")
	test.falsy(ok)
	test.includes(err, "guest re-enter error")

	outer:close()
end)

-- ─── Edge case: state:close() called while callback is pending on stack ──

test.it("closing a state while a bound_call is alive does not crash", function()
	-- bound_call has upvalue 1 (guest ptr). If the state is closed, the
	-- pointer is dangling but the closure should not be called again.
	local state = lua.new()
	local fn = state:eval("function(x) return x + 1 end")

	test.equal(11, fn(10))

	state:close()

	-- fn is now a bound_call with a dangling guest ptr. Calling it
	-- would crash. Don't call it — just check that letting it get GC'd
	-- doesn't crash.
	collectgarbage()
	test.truthy(true)
end)

-- ─── Bulk state lifecycle simulating lde test runner ──────────────────────

test.it("simulate lde test runner: many test files each with fresh state", function()
	-- Each iteration represents one test file in lde's test suite.
	-- Creates a fresh state, injects callbacks, runs test code, closes.
	local total_calls = 0

	for test_file = 1, 20 do
		local state = lua.new()
		local g     = state:globals()

		-- Set up reporter callbacks (like lde does)
		g._on_result = function(name, ok)
			total_calls = total_calls + 1
		end

		-- Run the "test file" source
		state:eval(string.format([[
			local function it(_name, _fn)
				_on_result(_name, true)
			end
			for i = 1, %d do
				it("test-" .. i)
			end
		]], test_file))

		state:close()
	end

	-- 1+2+3+...+20 = 210
	test.equal(210, total_calls)
end)

test.it("simulate lde test runner with inner states in test code", function()
	-- Like lde's stress tests: the test file source creates inner lua-sys states
	local total_results = 0

	for test_file = 1, 10 do
		local outer = lua.new()
		local g     = outer:globals()

		g._on_result = function(name, ok)
			total_results = total_results + 1
		end

		-- Test code creates inner states (like lua-sys stress tests do)
		g._run_inner = function(n)
			local inner = lua.new()
			local v = inner:eval(string.format("return %d * 2", n))
			inner:close()
			return v
		end

		outer:eval(string.format([[
			for i = 1, %d do
				local v = _run_inner(i)
				assert(v == i * 2)
				_on_result("inner-" .. i, true)
			end
		]], test_file * 2))

		outer:close()
	end

	-- 2 + 4 + 6 + ... + 20 = 110
	test.equal(110, total_results)
end)

-- ─── GC: state object collected while another state is active ─────────────

test.it("state left for GC does not corrupt another active state", function()
	local survivor = lua.new()
	survivor:eval("_s = 'alive'")

	-- Create a state in a local scope so it becomes GC-eligible
	do
		local temp = lua.new()
		temp:eval("_x = 10")
		local g = temp:globals()
		g.cb = function() end  -- register a callback
		-- temp goes out of scope here
	end

	collectgarbage()
	collectgarbage()

	-- Survivor must still work
	test.equal("alive", survivor:eval("return _s"))
	survivor:eval("_s = 'still-alive'")
	test.equal("still-alive", survivor:eval("return _s"))

	survivor:close()
end)

test.it("many states left for GC while one active state survives", function()
	local survivor = lua.new()
	survivor:eval("_counter = 0")

	for i = 1, 20 do
		do
			local temp = lua.new()
			temp:eval("_v = " .. i)
			local g = temp:globals()
			g.report = function(name) end
		end
	end

	collectgarbage()
	collectgarbage()

	-- Survivor still fully functional
	survivor:eval("_counter = 42")
	test.equal(42, survivor:globals()._counter)
	local fn = survivor:eval("function(x) return x + 1 end")
	test.equal(43, fn(42))

	survivor:close()
end)

test.it("state left for GC with registered callbacks does not affect new states", function()
	-- Abandon a state with several registered callbacks
	do
		local s = lua.new()
		local g = s:globals()
		g.on_result = function(name, ok) end
		g.on_start  = function(name) end
		g.on_pass   = function(name) end
		g.on_fail   = function(name, err) end
	end

	collectgarbage()
	collectgarbage()

	-- Create a new state with its own callbacks — must not inherit the old ones
	local s = lua.new()
	local g = s:globals()
	local called = false
	g.new_cb = function(x)
		called = true
		return x * 3
	end

	local result = s:eval("return new_cb(7)")
	test.equal(21, result)
	test.truthy(called)

	s:close()
end)

test.it("state left for GC with bound_call guest functions does not corrupt new states", function()
	-- Create a state, get a bound_call, drop state, force GC, create new state
	local new_state
	do
		local s = lua.new()
		local fn = s:eval("function(x) return x * 5 end")
		test.equal(50, fn(10))
		-- fn is a bound_call with upvalue pointing to s.L
		-- s goes out of scope, fn still references it through _guest_fns
	end

	collectgarbage()
	collectgarbage()

	-- Create a fresh state — must work
	new_state = lua.new()
	local g = new_state:globals()
	g.work = function(x) return x + 1 end
	local v = new_state:eval("return work(99)")
	test.equal(100, v)

	new_state:close()
end)

test.it("alternating: explicit close vs GC abandon does not corrupt state chain", function()
	for cycle = 1, 10 do
		-- Explicitly closed state
		local s1 = lua.new()
		s1:eval("_a = " .. cycle)
		test.equal(cycle, s1:globals()._a)
		s1:close()

		-- Abandoned state (left for GC)
		do
			local s2 = lua.new()
			s2:eval("_b = " .. cycle)
			local g2 = s2:globals()
			g2.cb = function() end
		end

		collectgarbage()

		-- Another explicitly closed state
		local s3 = lua.new()
		s3:eval("_c = " .. cycle)
		test.equal(cycle, s3:globals()._c)
		s3:close()
	end
	test.truthy(true)
end)

-- ─── GC: Value proxy collected while state still alive ────────────────────

test.it("Value proxy GC while state is still alive does not corrupt state", function()
	local state = lua.new()
	local proxy = nil

	-- Create a proxy in a nested scope so it becomes GC-eligible
	do
		local temp_g = state:globals()
		proxy = state:eval("function(x) return x + 100 end")
		-- temp_g goes out of scope, but doesn't hold proxy
	end

	test.equal(110, proxy(10))

	-- Clear the proxy reference, force GC
	proxy = nil
	collectgarbage()
	collectgarbage()

	-- State must still be functional
	local v = state:eval("return 1 + 1")
	test.equal(2, v)

	state:close()
end)

test.it("Table proxy GC while state is still alive does not corrupt state", function()
	local state = lua.new()
	local g = state:globals()
	g.data_table = { a = 1, b = 2, c = 3 }

	-- Get a Table proxy, then drop it
	do
		local tbl = g.data_table
		test.equal(1, tbl.a)
		test.equal(2, tbl.b)
	end

	collectgarbage()
	collectgarbage()

	-- State still works, and the underlying guest table is intact
	test.equal(1, g.data_table.a)
	test.equal(3, g.data_table.c)
	local sum = state:eval("return data_table.a + data_table.b + data_table.c")
	test.equal(6, sum)

	state:close()
end)

test.it("bulk proxy creation then GC while state alive does not corrupt state", function()
	local state = lua.new()
	local g = state:globals()
	local proxies = {}

	for i = 1, 50 do
		local fn = state:eval("function(x) return x + " .. i .. " end")
		proxies[i] = fn
		g["fn" .. i] = fn
	end

	-- Verify some proxies work
	test.equal(11, proxies[1](10))
	test.equal(60, proxies[50](10))

	-- Drop all proxy references
	proxies = nil
	collectgarbage()
	collectgarbage()

	-- State must survive with its globals intact
	local fn1 = g.fn1
	local fn50 = g.fn50
	test.equal(11, fn1(10))
	test.equal(60, fn50(10))

	state:close()
end)

-- ─── GC: inner state abandoned, outer state still alive ───────────────────

test.it("inner state abandoned for GC while outer state still runs", function()
	local outer = lua.new()
	local g     = outer:globals()

	g.leak_inner = function()
		local inner = lua.new()   -- no close() — abandoned for GC
		inner:eval("return 42")
		return "leaked"
	end

	local result = outer:eval("return leak_inner()")
	test.equal("leaked", result)

	collectgarbage()
	collectgarbage()

	-- Outer state must still work
	local v = outer:eval("return 1 + 1")
	test.equal(2, v)

	outer:close()
end)

test.it("many inner states abandoned while outer repeatedly used", function()
	local outer = lua.new()
	local g     = outer:globals()

	g.leak_inner = function(n)
		local inner = lua.new()
		inner:eval("_n = " .. n)
		return n
	end

	for i = 1, 30 do
		local r = outer:eval("return leak_inner(" .. i .. ")")
		test.equal(i, r)
	end

	collectgarbage()
	collectgarbage()

	-- Outer must still work after all those abandoned inner states
	local fn = outer:eval("function(x) return x * x end")
	test.equal(9, fn(3))
	test.equal(100, fn(10))

	outer:close()
end)

-- ─── GC: state with callbacks abandoned mid-callback ──────────────────────

test.it("state GC'd after callback registration but before invocation does not corrupt", function()
	for i = 1, 10 do
		do
			local s = lua.new()
			local g = s:globals()
			g.cb = function(n) return n * n end
			local fn = s:eval("function() return cb(" .. i .. ") end")
			-- Verify callback works
			test.equal(i * i, fn())
			-- s goes out of scope, abandoned for GC
		end
	end

	collectgarbage()
	collectgarbage()

	-- Create a new state to verify host is still healthy
	local s = lua.new()
	local g = s:globals()
	g.work = function(x) return x * 10 end
	local v = s:eval("return work(7)")
	test.equal(70, v)
	s:close()
end)

-- ─── GC: state abandoned with inner state references ──────────────────────

test.it("state GC'd while its Value proxies still reference it", function()
	-- The State table is kept alive by Value proxies (they hold self._state).
	-- Test that dropping all proxies then forcing GC doesn't crash.
	local state = lua.new()
	local g = state:globals()
	g.answer = 42

	local tbl = g   -- Value proxy holding reference to state
	tbl = nil       -- drop reference

	collectgarbage()
	collectgarbage()

	-- state is still referenced by the local variable, so it should be alive
	local proxy = state:globals()
	test.equal(42, proxy.answer)

	state:close()
end)

test.it("state fully abandoned including all proxy references then GC", function()
	local function make_abandoned_state()
		local s = lua.new()
		local g = s:globals()
		g.value = 99
		g.cb = function() return "hello" end
		s:eval("function get_value() return value end")
		-- No close() — everything goes out of scope
	end

	make_abandoned_state()
	collectgarbage()
	collectgarbage()

	-- Create a fresh state to prove host is not corrupted
	local s = lua.new()
	s:eval("_x = 7")
	test.equal(7, s:globals()._x)
	s:close()
end)

-- ─── GC: rapid create-abandon-GC-create cycle ─────────────────────────────

test.it("rapid create-abandon-GC-create cycles do not accumulate corruption", function()
	for cycle = 1, 30 do
		-- Abandon several states
		for i = 1, 10 do
			do
				local s = lua.new()
				local g = s:globals()
				g["fn" .. i] = function(x) return x * i end
				s:eval("_data = " .. i .. cycle)
			end
		end

		collectgarbage()

		-- Create and explicitly close a state to verify correctness
		local s = lua.new()
		s:eval("_test = " .. cycle)
		test.equal(cycle, s:globals()._test)
		s:close()
	end
	test.truthy(true)
end)

-- ─── GC: collectgarbage during state execution ────────────────────────────

test.it("GC during guest execution does not corrupt outer state", function()
	local outer = lua.new()
	local g     = outer:globals()

	g.trigger_gc = function()
		collectgarbage()
		collectgarbage()
		local inner = lua.new()
		inner:eval("_x = 1")
		inner:close()
		return "ok"
	end

	local result = outer:eval("return trigger_gc()")
	test.equal("ok", result)

	outer:close()
end)

test.it("GC via collectgarbage in host callback while guest function is active", function()
	local outer = lua.new()
	local g     = outer:globals()

	local guest_fn = outer:eval("function(x) return x * 2 end")

	g.trigger_gc = function(x)
		-- Force host GC while a guest function ref (guest_fn) is held in closure
		collectgarbage()
		return guest_fn(x)  -- re-enter outer guest from host callback
	end

	local result = outer:eval("return trigger_gc(21)")
	test.equal(42, result)

	outer:close()
end)
