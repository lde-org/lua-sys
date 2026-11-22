-- high/hooks.lua — the high-level debug hook.
--
-- The bridge installs the C hook/trampoline; this module parses the mask,
-- keeps the host callback ref alive and wraps the user function so the frame
-- objects can find their state (the info table carries it).

local bridge = require("lua-sys.bridge")
local convert = require("lua-sys.high.convert")

local LUA_MASKCALL = 1
local LUA_MASKRET = 2
local LUA_MASKLINE = 4
local LUA_MASKCOUNT = 8

---@type table<string, integer>
local HOOK_MASK_NAMES = {
	call = LUA_MASKCALL,
	["return"] = LUA_MASKRET,
	ret = LUA_MASKRET,
	line = LUA_MASKLINE,
	count = LUA_MASKCOUNT
}

local hooks = {}

--- Turn a hook mask into a LUA_MASK* bitmask: event names with spaces, for
--- example "line" or "call return", or an integer bitmask.
---@param mask string|integer?
---@return integer
local function parseHookMask(mask)
	if type(mask) == "number" then return mask end
	if type(mask) ~= "string" then
		error("setHook: mask must be a string like \"line\" or an integer bitmask, got " .. type(mask), 3)
	end
	local bits = 0
	for word in mask:gmatch("%S+") do
		local bit = HOOK_MASK_NAMES[word]
		if bit == nil then
			error("setHook: unknown hook event '" .. word .. "' (expected call, return, line, count)", 3)
		end
		bits = bits + bit
	end
	if bits == 0 then error("setHook: hook mask cannot be empty", 3) end
	return bits
end

---@class lua.HookInfo
---@field event "call"|"return"|"line"|"count"|"tailcall"
---@field thread ffi.cdata*
---@field name string?
---@field namewhat string?
---@field what string?
---@field source string?
---@field short_src string
---@field currentline integer
---@field linedefined integer
---@field lastlinedefined integer
---@field nups integer
---@field stack fun(self: lua.HookInfo): lua.Frame[]

--- Install or remove a debug hook, the high-level form of lua_sethook. The
--- bridge calls `fn(event, info)` at each event with a lua.HookInfo. `mask`
--- takes event names or an integer bitmask, and `count` sets the "count"
--- interval (default 1). setHook(nil) removes the hook. A hook needs
--- interpreted code, so it disables the guest JIT engine until removal.
---@param State table
function hooks.install(State)
	---@param self lua.State
	---@param fn    fun(event: "call"|"return"|"line"|"count"|"tailcall", info: lua.HookInfo)|nil
	---@param mask  string|integer?
	---@param count integer?
	function State:setHook(fn, mask, count)
		if self.L == nil then error("state is closed", 3) end
		if self.rt.caps.hooks == nil then
			error("setHook: not supported by " .. self.rt.version.string, 3)
		end

		-- Validate the arguments before touching the current hook.
		if fn ~= nil and type(fn) ~= "function" then
			error("setHook: fn must be a function or nil, got " .. type(fn), 2)
		end
		local bits
		if fn ~= nil then bits = parseHookMask(mask) end

		-- Drop the previous hook callback before a new one goes in.
		if self._hook_ref then
			bridge.unregister(self._hook_ref)
			self._hook_ref = nil
		end

		if fn == nil then
			bridge.remove_hook(self._slot, self._guest_num)
			return
		end

		local state = self
		---@param event "call"|"return"|"line"|"count"|"tailcall"
		---@param info lua.HookInfo
		local ref = bridge.register(function(event, info)
			convert.rememberThread(state, info.thread)
			return fn(event, info)
		end)
		local ok, err = bridge.set_hook(self._slot, self._guest_num, ref, bits, count or 1)
		if not ok then
			bridge.unregister(ref)
			error(err or "setHook: the runtime refused the hook", 2)
		end
		self._hook_ref = ref
	end
end

return hooks
