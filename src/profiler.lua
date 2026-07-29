-- src/profiler.lua
--
-- Sampling profiler for guest lua_State instances.

local raw    = require("lua-sys.raw")

local profiler = {}

local _active  = {}

-- ── POSIX path ────────────────────────────────────────────────────────────

local function start_posix(state, mode, cb)
	local key = tostring(state.L)

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
			local vm    = string.char(vmstate)
			local k     = stack .. "\0" .. vm
			local e     = counts[k]
			if e then
				e.count = e.count + n
			else
				counts[k] = { stack = stack, vmstate = vm, count = n }
			end
			entry.total = entry.total + n
		end, nil)
	end

	_active[key] = entry
end

local function stop_posix(state)
	local key = tostring(state.L)
	raw.jit_profile_stop(state.L)
	local entry = _active[key]
	_active[key] = nil

	if entry.custom then return nil end

	local total   = entry.total
	local entries = {}
	for _, e in pairs(entry.counts) do
		entries[#entries + 1] = {
			stack   = e.stack,
			vmstate = e.vmstate,
			count   = e.count,
			percent = total > 0 and e.count / total * 100 or 0,
		}
	end
	table.sort(entries, function(a, b) return a.count > b.count end)
	entries.total = total
	return entries
end

-- ── Public API ────────────────────────────────────────────────────────────

---@param state lua.State
---@param mode  string?
---@param cb    fun(stack: string, samples: integer, vmstate: string)?
function profiler.start(state, mode, cb)
	assert(state and state.L, "profiler.start: expected a lua.State")
	local key = tostring(state.L)
	assert(not _active[key], "profiler already running for this state")
	mode = mode or "fi1"

	start_posix(state, mode, cb)
end

---@param state lua.State
---@return { stack: string, vmstate: string, count: integer, percent: number }[]|nil
function profiler.stop(state)
	assert(state and state.L, "profiler.stop: expected a lua.State")
	local key = tostring(state.L)
	assert(_active[key], "profiler not running for this state")

	return stop_posix(state)
end

---@param report      table
---@param out         file*?
---@param min_percent number?
function profiler.print(report, out, min_percent)
	out         = out or io.stdout
	min_percent = min_percent or 1
	out:write(string.format("%-8s  %-7s  %-7s  %s\n", "samples", "%", "vmstate", "stack"))
	out:write(string.rep("-", 80) .. "\n")
	for _, e in ipairs(report) do
		if e.percent >= min_percent then
			out:write(string.format("%-8d  %6.1f%%  %-7s  %s\n",
				e.count, e.percent, e.vmstate or "?", e.stack))
		end
	end
	out:write(string.format("\n%d total samples\n", report.total or 0))
end

return profiler
