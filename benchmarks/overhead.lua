-- benchmarks/overhead.lua
-- Cross-boundary call overhead benchmarks.
--
-- Run with:  lde ./benchmarks/overhead.lua --profile

local lua        = require("lua-sys")

local ITERATIONS = 5000000

print("=== lua-sys Cross-Boundary Call Overhead ===\n")

-- ═══════════════════════════════════════════════════════════════════
-- Benchmark 1: Guest → Host  bare overhead (no args, no returns)
-- ═══════════════════════════════════════════════════════════════════
do
	local state = lua.new()
	local g = state:globals()
	g:set("host_noop", function() end)
	local wrapper = state:load("function() host_noop() end")

	print("[1] Guest → Host: no args, no returns")
	for _ = 1, ITERATIONS do
		wrapper()
	end

	state:close()
end

-- ═══════════════════════════════════════════════════════════════════
-- Benchmark 2: Guest → Host  with N arguments and Y returns
-- ═══════════════════════════════════════════════════════════════════
local configs = {
	{ n = 0, y = 1 },
	{ n = 1, y = 0 },
	{ n = 1, y = 1 },
	{ n = 2, y = 0 },
	{ n = 2, y = 2 },
	{ n = 4, y = 0 },
	{ n = 4, y = 4 }
}

for _, cfg in ipairs(configs) do
	local n, y = cfg.n, cfg.y
	local state = lua.new()
	local g = state:globals()

	local host_fn
	if n == 0 then
		if y == 1 then host_fn = function() return 42 end end
	elseif n == 1 then
		if y == 0 then
			host_fn = function(a) end
		elseif y == 1 then
			host_fn = function(a) return a end
		end
	elseif n == 2 then
		if y == 0 then
			host_fn = function(a, b) end
		elseif y == 2 then
			host_fn = function(a, b) return b, a end
		end
	elseif n == 4 then
		if y == 0 then
			host_fn = function(a, b, c, d) end
		elseif y == 4 then
			host_fn = function(a, b, c, d) return d, c, b, a end
		end
	end

	g:set("host_fn", host_fn)

	local args = {}
	for i = 1, n do args[i] = "42" end
	local arg_str = table.concat(args, ", ")
	local wrapper = state:load(string.format("function() host_fn(%s) end", arg_str))

	print(string.format("[2] Guest → Host: %d arg(s), %d return(s)", n, y))
	for _ = 1, ITERATIONS do
		wrapper()
	end

	state:close()
end

-- ═══════════════════════════════════════════════════════════════════
-- Benchmark 3: Host → Guest  (guest-defined noop)
-- ═══════════════════════════════════════════════════════════════════
do
	local state = lua.new()
	local fn = state:load("function() end")

	print("[3] Host → Guest: no args, no returns")
	for _ = 1, ITERATIONS do
		fn()
	end

	state:close()
end

print("\nDone.")
