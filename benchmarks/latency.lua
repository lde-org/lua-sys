-- benchmarks/latency.lua
-- Measures the nanosecond latency of cross-boundary calls between the
-- LuaJIT host and a guest lua_State.
--
-- Run with:  lde ./benchmarks/latency.lua

local lua = require("lua-sys")
local ffi = require("ffi")

-- ─── Timer ────────────────────────────────────────────────────────────────

ffi.cdef([[
  struct timespec { long tv_sec; long tv_nsec; };
  int clock_gettime(int clkid, struct timespec *tp);
]])

local CLOCK_MONOTONIC = 1
local _ts = ffi.new("struct timespec")

local function now_ns()
	ffi.C.clock_gettime(CLOCK_MONOTONIC, _ts)
	return tonumber(_ts.tv_sec) * 1000000000 + tonumber(_ts.tv_nsec)
end

-- ─── Helpers ──────────────────────────────────────────────────────────────

-- Burn N warmup iterations (not timed), then time M iterations.
-- Returns ns/call.
local function measure(fn, warmup, iters)
	for _ = 1, warmup do fn() end
	local t0 = now_ns()
	for _ = 1, iters do fn() end
	local t1 = now_ns()
	return (t1 - t0) / iters
end

local function fmt(ns)
	if ns >= 1000 then
		return string.format("%.1f µs", ns / 1000)
	end
	return string.format("%.1f ns", ns)
end

local function row(label, ns, baseline_ns)
	local overhead = baseline_ns and (ns - baseline_ns) or nil
	if overhead then
		io.write(string.format("  %-42s  %8s  (+%s overhead)\n",
			label, fmt(ns), fmt(overhead)))
	else
		io.write(string.format("  %-42s  %8s\n", label, fmt(ns)))
	end
end

local WARMUP = 50000
local ITERS  = 2000000

-- ─── Baseline: plain LuaJIT function calls ────────────────────────────────

print("=== lua-sys Cross-Boundary Call Latency ===\n")
print("Baseline (same-state LuaJIT calls):")

local function noop() end
local function add(a, b) return a + b end

local baseline_noop_ns = measure(function() noop() end, WARMUP, ITERS)
local baseline_add_ns  = measure(function() add(1, 2) end, WARMUP, ITERS)

row("noop()", baseline_noop_ns)
row("add(1, 2)", baseline_add_ns)

-- ─── Host → Guest ─────────────────────────────────────────────────────────

print("\nHost → Guest (LuaJIT calls into guest lua_State):")

do
	local state        = lua.new()

	local g_noop       = state:eval("function() end")
	local g_add        = state:eval("function(a,b) return a+b end")
	local g_echo4      = state:eval("function(a,b,c,d) return a,b,c,d end")

	local h2g_noop_ns  = measure(function() g_noop() end, WARMUP, ITERS)
	local h2g_add_ns   = measure(function() g_add(1, 2) end, WARMUP, ITERS)
	local h2g_echo4_ns = measure(function() g_echo4(1, 2, 3, 4) end, WARMUP, ITERS)

	row("noop()", h2g_noop_ns, baseline_noop_ns)
	row("add(1, 2) → number", h2g_add_ns, baseline_add_ns)
	row("echo(1,2,3,4) → 4x", h2g_echo4_ns, baseline_noop_ns)

	state:close()
end

-- ─── Guest → Host ─────────────────────────────────────────────────────────

print("\nGuest → Host (guest lua_State calls back into LuaJIT):")

do
	local state = lua.new()
	local g     = state:globals()

	g:set("host_noop", function() end)
	g:set("host_add", function(a, b) return a + b end)
	g:set("host_echo4", function(a, b, c, d) return a, b, c, d end)

	-- Guest wrapper functions that call the host functions
	local call_noop    = state:eval("function() host_noop() end")
	local call_add     = state:eval("function() host_add(1, 2) end")
	local call_echo4   = state:eval("function() host_echo4(1,2,3,4) end")

	local g2h_noop_ns  = measure(function() call_noop() end, WARMUP, ITERS)
	local g2h_add_ns   = measure(function() call_add() end, WARMUP, ITERS)
	local g2h_echo4_ns = measure(function() call_echo4() end, WARMUP, ITERS)

	row("noop()", g2h_noop_ns, baseline_noop_ns)
	row("add(1, 2) → number", g2h_add_ns, baseline_add_ns)
	row("echo(1,2,3,4) → 4x", g2h_echo4_ns, baseline_noop_ns)

	state:close()
end

-- ─── Nested: Host → Guest → Host ──────────────────────────────────────────

print("\nNested: Host → Guest → Host (round-trip):")

do
	local state = lua.new()
	local g     = state:globals()

	g:set("host_inc", function(x) return x + 1 end)
	local round_trip = state:eval("function(x) return host_inc(x) end")

	local rt_ns = measure(function() round_trip(41) end, WARMUP, ITERS)
	row("host_fn(guest_fn(host_inc(x)))", rt_ns, baseline_noop_ns)

	state:close()
end

print("\nNote: 'overhead' = measured time minus the same-state baseline.")
print(string.format("      Iterations: %d  Warmup: %d\n", ITERS, WARMUP))
