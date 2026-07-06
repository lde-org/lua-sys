-- src/profiler.lua
--
-- High-level profiler API wrapping LuaJIT's luaJIT_profile_* C API.
-- Profiles a specific guest lua.State rather than the host.
--
-- Basic usage:
--   local profiler = require("lua-sys.profiler")
--   profiler.start(state)
--   state:load("...")()
--   local report = profiler.stop(state)
--   profiler.print(report)
--
-- Custom callback (one call per sample tick):
--   profiler.start(state, "fi1", function(stack, samples, vmstate) ... end)
--   profiler.stop(state)

local raw = require("lua-sys.raw")

local profiler = {}

-- Active profiler state keyed by guest lua_State pointer (as number).
-- Allows profiling multiple guest states simultaneously.
local _active = {}

--- Start profiling a guest state.
--
-- state: the lua.State to profile.
-- mode:  LuaJIT profiler mode string (default "fi1").
--   f        — function-level stack dumps
--   l        — line-level stack dumps
--   i<ms>    — sampling interval in ms (default 10ms)
-- cb:   optional function(stack: string, samples: integer, vmstate: string).
--   Called once per sample tick. vmstate is one of: N I C G J
--   (native, interpreted, C, GC, JIT compiler).
--   When omitted, samples are aggregated and returned by stop().
--
---@param state lua.State
---@param mode  string?
---@param cb    fun(stack: string, samples: integer, vmstate: string)?
function profiler.start(state, mode, cb)
	assert(state and state.L, "profiler.start: expected a lua.State")
	local key = tostring(state.L)
	assert(not _active[key], "profiler already running for this state")
	mode = mode or "fi1"

	local entry
	if cb then
		entry = { custom = true }
		raw.jit_profile_start(state.L, mode, function(data, L, n, vmstate)
			cb(raw.jit_profile_dumpstack(L, "f;", 32), n, string.char(vmstate))
		end, nil)
	else
		local counts = {}
		local total  = 0
		entry = { counts = counts, total = 0 }
		raw.jit_profile_start(state.L, mode, function(data, L, n, vmstate)
			local stack = raw.jit_profile_dumpstack(L, "f;", 32)
			counts[stack] = (counts[stack] or 0) + n
			entry.total   = entry.total + n
		end, nil)
	end

	_active[key] = entry
end

--- Stop profiling a guest state and return an aggregated report.
--
-- Returns nil when started with a custom callback.
-- Otherwise returns a list sorted by sample count descending:
--   { { stack: string, count: integer, percent: number }, ..., total: integer }
--
---@param state lua.State
---@return { stack: string, count: integer, percent: number }[]|nil
function profiler.stop(state)
	assert(state and state.L, "profiler.stop: expected a lua.State")
	local key = tostring(state.L)
	assert(_active[key], "profiler not running for this state")

	raw.jit_profile_stop(state.L)
	local entry = _active[key]
	_active[key] = nil

	if entry.custom then return nil end

	local total   = entry.total
	local entries = {}
	for stack, count in pairs(entry.counts) do
		entries[#entries + 1] = {
			stack   = stack,
			count   = count,
			percent = total > 0 and count / total * 100 or 0,
		}
	end
	table.sort(entries, function(a, b) return a.count > b.count end)
	entries.total = total
	return entries
end

--- Print a report produced by stop() to stdout (or a file handle).
--
---@param report      table
---@param out         file*?
---@param min_percent number?  hide entries below this % (default 1)
function profiler.print(report, out, min_percent)
	out         = out or io.stdout
	min_percent = min_percent or 1
	out:write(string.format("%-8s  %-7s  %s\n", "samples", "%", "stack"))
	out:write(string.rep("-", 72) .. "\n")
	for _, e in ipairs(report) do
		if e.percent >= min_percent then
			out:write(string.format("%-8d  %6.1f%%  %s\n",
				e.count, e.percent, e.stack))
		end
	end
	out:write(string.format("\n%d total samples\n", report.total or 0))
end

return profiler
