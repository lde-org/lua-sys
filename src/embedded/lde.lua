-- embedded/lde.lua — the `lde` source feature: the LuaJIT lde already links,
-- the image running this code.

local image = require("lua-sys.image")

local backend = {}

---@return lua.Image?
function backend.image()
	return image.running()
end

--- The image only when it has already been resolved.
---@return lua.Image?
function backend.loaded()
	local running = image.running()
	if running ~= nil and running.isRunning then return running end
	return nil
end

return backend
