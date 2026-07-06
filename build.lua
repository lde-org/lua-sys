-- build.lua — Compiles the C bridge module for lua-sys.
--
-- Uses gcc (available on all supported platforms).
-- No system luajit-dev package is needed: lde already embeds LuaJIT and
-- exports all required symbols, so the shared library resolves them at
-- runtime from the process image without an explicit -l flag.

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

local ext, flags
if jit.os == "Windows" then
    ext   = "dll"
    flags = "-shared"
elseif jit.os == "OSX" then
    ext   = "dylib"
    flags = "-dynamiclib"
else
    ext   = "so"
    flags = "-shared -fPIC"
end

build:sh("gcc " .. flags .. " -O2"
    .. " -I" .. out
    .. " -o " .. out .. "/bridge." .. ext
    .. " " .. out .. "/bridge.c")
