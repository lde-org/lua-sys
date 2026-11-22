local lua = require("lua-sys")
local rt = lua:lde()
local profiler = require("lua-sys.profiler")
local test = require("lde-test")

test.it("heapSnapshot attributes a global table and counts its elements", function()
	local state = rt:new()
	state:eval([[
		cache = { entries = {} }
		for i = 1, 1000 do cache.entries[i] = string.rep("x", 100) .. i end
	]])
	local snap = state:heapSnapshot()
	test.equal(snap.counts["_G.cache.entries[]"], 1000)
	test.equal(snap.parents["_G.cache.entries"], "_G.cache")
	test.equal(snap.parents["_G"], false)
	-- 1000 strings of 103-104 bytes plus their 25-byte headers, and the array.
	test.truthy(snap.retained["_G.cache.entries"] > 1000 * 128, "got " .. tostring(snap.retained["_G.cache.entries"]))
	test.truthy(snap.retained["_G.cache"] >= snap.retained["_G.cache.entries"])
	state:close()
end)

test.it("heapSnapshot names the upvalue that holds a table", function()
	local state = rt:new()
	state:eval([[
		local hidden = {}
		for i = 1, 100 do hidden[i] = { i } end
		function get() return hidden end
	]])
	local snap = state:heapSnapshot()
	test.equal(snap.counts["_G.get<upvalue hidden>[]"], 100)
	state:close()
end)

test.it("heapSnapshot does not follow weak references", function()
	local state = rt:new()
	state:eval([[
		weak = setmetatable({}, { __mode = "v" })
		for i = 1, 50 do weak[i] = {} end
	]])
	local snap = state:heapSnapshot()
	test.equal(snap.counts["_G.weak[]"], nil)
	state:close()
end)

test.it("heapSnapshot walks a chain deeper than its frame limit", function()
	local state = rt:new()
	state:eval([[
		local node = nil
		for i = 1, 20000 do node = { next = node } end
		list = node
	]])
	local snap = state:heapSnapshot()
	test.truthy(snap.objects >= 20000, "got " .. tostring(snap.objects))
	test.truthy(snap.retained["_G.list"] >= 20000 * 64, "got " .. tostring(snap.retained["_G.list"]))
	state:close()
end)

test.it("heapSnapshot adds no garbage to the guest", function()
	local state = rt:new()
	state:eval([[t = {} for i = 1, 5000 do t[i] = { i } end]])
	state:heapSnapshot() -- the first snapshot creates the walker thread
	state:eval("collectgarbage() collectgarbage()")
	local before = state:memory()
	state:heapSnapshot()
	test.equal(state:memory(), before)
	state:close()
end)

test.it("heapSnapshot from a profiler callback sees the main chunk's locals", function()
	local state = rt:new()
	---@type lua.HeapSnapshot?
	local snap
	profiler.start(state, "fi1", function()
		snap = snap or state:heapSnapshot()
	end)
	state:load([[
		local store = {}
		for i = 1, 2000 do store[i] = { i } end
		local function work()
			local s = 0
			for i = 1, 100000 do s = s + i end
			return s
		end
		for _ = 1, 500 do work() end
	]], "@main.lua"):call()
	profiler.stop(state)
	test.truthy(snap, "the profiler callback never ran") ---@cast snap -nil
	test.equal(snap.counts["main.lua:local store[]"], 2000)
	state:close()
end)
