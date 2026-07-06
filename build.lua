-- build.lua — Compiles the C bridge module for lua-sys.
--
-- Uses gcc (available on all supported platforms via MinGW on Windows).
-- No system luajit-dev package is needed: lde already embeds LuaJIT and
-- exports all required symbols. On Linux/macOS the shared library resolves
-- them at runtime from the process image. On Windows they must be resolved
-- at link time via an import library generated from lde's own export table.

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

local ext, flags, extra_link
if jit.os == "Windows" then
    ext   = "dll"
    flags = "-shared"
    -- sea.compile generates an import library (<exename>.a) alongside the exe
    -- via --out-implib, exporting all lua* symbols. Link against it directly.
    local ffi = require("ffi")
    ffi.cdef("unsigned long GetModuleFileNameA(void*, char*, unsigned long);")
    local buf = ffi.new("char[512]")
    ffi.C.GetModuleFileNameA(nil, buf, 512)
    local exe_path = ffi.string(buf)
    local imp_path = exe_path:gsub("%.exe$", "") .. ".a"
    extra_link = " -L" .. out .. " " .. imp_path
elseif jit.os == "OSX" then
    ext        = "dylib"
    flags      = "-dynamiclib -undefined dynamic_lookup"
    extra_link = ""
else
    ext        = "so"
    flags      = "-shared -fPIC"
    extra_link = ""
end

build:sh("gcc " .. flags .. " -O2"
    .. " -I" .. out
    .. " -o " .. out .. "/bridge." .. ext
    .. " " .. out .. "/bridge.c"
    .. extra_link)
