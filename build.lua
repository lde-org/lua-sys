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
    -- lde passes LDE_IMPLIB pointing to the import library it generated via
    -- --out-implib at compile time. Link bridge.dll against it so it can
    -- resolve lua* symbols from the host executable at runtime.
    local imp_path = assert(os.getenv("LDE_IMPLIB"),
        "LDE_IMPLIB not set — rebuild lde with a version that supports lua-sys")
    extra_link = " " .. imp_path
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
