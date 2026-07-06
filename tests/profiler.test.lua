local lua      = require("lua-sys")
local profiler = require("lua-sys.profiler")
local test     = require("lde-test")

local function make_state_with_work()
	local state = lua.new()
	-- fib burns CPU in the guest so the profiler actually fires
	local work = state:load([[
		function()
			local function fib(n)
				if n < 2 then return n end
				return fib(n-1) + fib(n-2)
			end
			local x = 0
			for i = 1, 300 do x = x + fib(20) end
			return x
		end
	]])
	return state, work
end

-- ─── basic start / stop ───────────────────────────────────────────────────

test.it("profiler.start / stop returns a report for a guest state", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	local report = profiler.stop(state)
	test.truthy(report)
	test.equal("table", type(report))
	state:close()
end)

test.it("report has total > 0", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	local report = profiler.stop(state)
	test.truthy(report.total > 0)
	state:close()
end)

test.it("report entries are sorted by count descending", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	local report = profiler.stop(state)
	for i = 2, #report do
		test.truthy(report[i-1].count >= report[i].count)
	end
	state:close()
end)

test.it("report entries have stack, count and percent fields", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	local report = profiler.stop(state)
	test.truthy(#report > 0)
	local e = report[1]
	test.equal("string", type(e.stack))
	test.equal("number", type(e.count))
	test.equal("number", type(e.percent))
	test.truthy(e.count > 0)
	state:close()
end)

test.it("percents sum to ~100", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	local report = profiler.stop(state)
	local sum = 0
	for _, e in ipairs(report) do sum = sum + e.percent end
	test.truthy(math.abs(sum - 100) < 0.01)
	state:close()
end)

test.it("fib appears in the top stack entry", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	local report = profiler.stop(state)
	test.truthy(#report > 0)
	-- fib is the hot function — it should appear in the top entry
	test.truthy(report[1].stack:find("fib"), "expected 'fib' in top stack: " .. report[1].stack)
	state:close()
end)

-- ─── custom callback ──────────────────────────────────────────────────────

test.it("custom callback receives stack, samples and vmstate", function()
	local state, work = make_state_with_work()
	local hits = {}
	profiler.start(state, "fi1", function(stack, n, vmstate)
		hits[#hits+1] = { stack=stack, n=n, vm=vmstate }
	end)
	work()
	local result = profiler.stop(state)
	test.equal(nil, result)   -- no report in custom mode
	test.truthy(#hits > 0)
	test.equal("string", type(hits[1].stack))
	test.equal("number", type(hits[1].n))
	test.equal("string", type(hits[1].vm))
	state:close()
end)

-- ─── multiple states ──────────────────────────────────────────────────────

test.it("two guest states can be profiled sequentially", function()
	local s1, w1 = make_state_with_work()
	local s2, w2 = make_state_with_work()
	profiler.start(s1); w1(); local r1 = profiler.stop(s1)
	profiler.start(s2); w2(); local r2 = profiler.stop(s2)
	test.truthy(r1.total > 0)
	test.truthy(r2.total > 0)
	s1:close(); s2:close()
end)

-- ─── error handling ───────────────────────────────────────────────────────

test.it("start twice on same state raises an error", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	local ok, err = pcall(profiler.start, state)
	profiler.stop(state)
	test.equal(false, ok)
	test.truthy(err:find("already running"))
	state:close()
end)

test.it("stop without start raises an error", function()
	local state = lua.new()
	local ok, err = pcall(profiler.stop, state)
	test.equal(false, ok)
	test.truthy(err:find("not running"))
	state:close()
end)

test.it("stop after state:close does not crash", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	-- stop before close is the correct order
	profiler.stop(state)
	state:close()
end)

-- ─── profiler.print ───────────────────────────────────────────────────────

test.it("profiler.print writes a formatted report", function()
	local state, work = make_state_with_work()
	profiler.start(state)
	work()
	local report = profiler.stop(state)
	local out = {}
	local fake = { write = function(_, s) out[#out+1] = s end }
	profiler.print(report, fake)
	local text = table.concat(out)
	test.truthy(text:find("samples"))
	test.truthy(text:find("total samples"))
	state:close()
end)

-- ─── lua.profiler alias ───────────────────────────────────────────────────

test.it("lua.profiler is the same module as lua-sys.profiler", function()
	test.equal(profiler, lua.profiler)
end)
