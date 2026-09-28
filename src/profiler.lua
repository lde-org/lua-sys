-- src/profiler.lua
--
-- Sampling profiler for guest lua_State instances.

local raw    = require("lua-sys.raw")

local profiler = {}

-- lua.State → entry, with weak keys. The state object is the key and not its
-- address: a closed state releases its address, and lua.new() reuses it, so an
-- address key would refuse the next state. The entry also goes away with the
-- state object.
local _active = setmetatable({}, { __mode = "k" })

-- ── POSIX path ────────────────────────────────────────────────────────────

local function start_posix(state, mode, cb)
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

	_active[state] = entry
end

local function stop_posix(state)
	raw.jit_profile_stop(state.L)
	local entry = _active[state]
	_active[state] = nil

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

-- The profiler needs a live guest state. A closed state has L == nil, and the
-- raw profile calls on a freed lua_State would crash.
---@param state lua.State
---@param what  string
local function checkOpenState(state, what)
	if type(state) ~= "table" or state.L == nil then
		error(what .. ": expected an open lua.State", 3)
	end
end

---@param state lua.State
---@param mode  string?
---@param cb    fun(stack: string, samples: integer, vmstate: string)?
function profiler.start(state, mode, cb)
	checkOpenState(state, "profiler.start")
	assert(not _active[state], "profiler already running for this state")
	mode = mode or "fi1"

	start_posix(state, mode, cb)
end

---@param state lua.State
---@return { stack: string, vmstate: string, count: integer, percent: number }[]|nil
function profiler.stop(state)
	checkOpenState(state, "profiler.stop")
	assert(_active[state], "profiler not running for this state")

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
