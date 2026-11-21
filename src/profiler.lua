-- src/profiler.lua
--
-- Sampling profiler for guest lua_State instances.

local raw = require("lua-sys.raw")

---@class lua.profiler.Row
---@field stack   string
---@field vmstate string
---@field count   integer
---@field percent number

---@class lua.profiler.Report
---@field [integer] lua.profiler.Row
---@field total integer

---@class lua.profiler.Entry
---@field isCustom boolean
---@field counts   table<string, lua.profiler.Row>
---@field total    integer

---@class lua.profiler.Writer
---@field write fun(self: lua.profiler.Writer, text: string)

local profiler = {}

-- lua.State → entry, with weak keys. The state object is the key and not its
-- address: a closed state releases its address, and lua.new() reuses it, so an
-- address key would refuse the next state. The entry also goes away with the
-- state object.
local _active = setmetatable({}, { __mode = "k" }) --[[@as table<lua.State, lua.profiler.Entry>]]

-- ── POSIX path ────────────────────────────────────────────────────────────

---@param state lua.State
---@param mode  string
---@param cb    fun(stack: string, samples: integer, vmstate: string)?
local function start_posix(state, mode, cb)
	local L = assert(state.L, "state is closed")
	local entry = { isCustom = cb ~= nil, counts = {}, total = 0 }

	if cb then
		---@type fun(data: ffi.cdata*, L: lua.raw.State, samples: integer, vmstate: integer)
		local onSample = function(_, thread, samples, vmstate)
			cb(raw.jit_profile_dumpstack(thread, "f;", 32), samples, string.char(vmstate))
		end
		raw.jit_profile_start(L, mode, onSample, nil)
	else
		local counts = entry.counts
		---@type fun(data: ffi.cdata*, L: lua.raw.State, samples: integer, vmstate: integer)
		local onSample = function(_, thread, samples, vmstate)
			local stack = raw.jit_profile_dumpstack(thread, "f;", 32)
			local vm = string.char(vmstate)
			local k = stack .. "\0" .. vm
			local e = counts[k]
			if e then
				e.count = e.count + samples
			else
				counts[k] = { stack = stack, vmstate = vm, count = samples, percent = 0 }
			end
			entry.total = entry.total + samples
		end
		raw.jit_profile_start(L, mode, onSample, nil)
	end

	_active[state] = entry
end

---@param state lua.State
local function stop_posix(state)
	local L = assert(state.L, "state is closed")
	raw.jit_profile_stop(L)
	local entry = assert(_active[state], "profiler is not running for this state")
	_active[state] = nil

	if entry.isCustom then return nil end

	local total = entry.total
	---@type lua.profiler.Report
	local entries = {}
	for _, e in pairs(entry.counts) do
		entries[#entries + 1] = {
			stack = e.stack,
			vmstate = e.vmstate,
			count = e.count,
			percent = total > 0 and e.count / total * 100 or 0
		}
	end
	table.sort(entries, |a, b| -> a.count > b.count)
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
	start_posix(state, mode or "fi1", cb)
end

---@param state lua.State
---@return lua.profiler.Report?
function profiler.stop(state)
	checkOpenState(state, "profiler.stop")
	assert(_active[state], "profiler not running for this state")
	return stop_posix(state)
end

---@param report      lua.profiler.Report
---@param out         lua.profiler.Writer?
---@param min_percent number?
function profiler.print(report, out, min_percent)
	out = out or io.stdout
	min_percent = min_percent or 1
	out:write(string.format("%-8s  %-7s  %-7s  %s\n", "samples", "%", "vmstate", "stack"))
	out:write(string.rep("-", 80) .. "\n")
	for _, e in ipairs(report) do
		if e.percent >= min_percent then
			out:write(string.format("%-8d  %6.1f%%  %-7s  %s\n", e.count, e.percent, e.vmstate or "?", e.stack))
		end
	end
	out:write(string.format("\n%d total samples\n", report.total or 0))
end

return profiler
