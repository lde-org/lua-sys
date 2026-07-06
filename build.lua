-- build.lua — Compiles the C bridge module for lua-sys.
--
-- bridge.c uses only the Lua C API via a bundled minimal header (lua_bridge.h).
-- No system luajit-dev package is needed: lde already embeds LuaJIT and
-- exports all required symbols, so bridge.so resolves them at load time
-- from the process image without an explicit -l flag.

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

local os_name = jit.os  -- "Linux", "OSX", "BSD", ...

local shared_flag = os_name == "OSX" and "-dynamiclib" or "-shared -fPIC"
local ext         = os_name == "OSX" and "dylib"       or "so"

build:sh("cc " .. shared_flag .. " -O2"
    .. " -I" .. out          -- pick up lua_bridge.h from the output dir
    .. " -o " .. out .. "/bridge." .. ext
    .. " " .. out .. "/bridge.c")
