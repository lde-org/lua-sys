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
    -- Windows DLLs cannot resolve symbols from the host executable at
    -- runtime. Generate an import library so gcc can link against lde's
    -- embedded LuaJIT symbols.
    --
    -- Use GetModuleFileNameA to find the running executable, then nm to
    -- extract every exported lua*/luaL*/luaJIT* symbol — avoids a manual
    -- list that goes stale when lde adds new API surface.
    local ffi = require("ffi")
    ffi.cdef("unsigned long GetModuleFileNameA(void*, char*, unsigned long);")
    local buf = ffi.new("char[512]")
    ffi.C.GetModuleFileNameA(nil, buf, 512)
    local exe_path = ffi.string(buf)
    local exe_name = exe_path:match("[^\\/]+$") or "lde.exe"

    local def_path = out .. "/lde.def"
    local lib_path = out .. "/liblde.a"
    local def = assert(io.open(def_path, "w"))
    def:write("EXPORTS\n")
    local nm   = io.popen('nm --defined-only "' .. exe_path .. '" 2>NUL')
    local seen = {}
    for line in nm:lines() do
        -- nm output: <addr> <class> <symbol>
        -- T/W = exported text symbol; match lua*, luaL*, luaJIT* names
        local sym = line:match("%s+[TW]%s+(lua[a-zA-Z0-9_]+)$")
        if sym and not seen[sym] then
            seen[sym] = true
            def:write("    " .. sym .. "\n")
        end
    end
    nm:close()
    def:close()
    build:sh("dlltool --dllname " .. exe_name
        .. " -d " .. def_path .. " -l " .. lib_path)
    extra_link = " -L" .. out .. " -llde"
elseif jit.os == "OSX" then
    ext        = "dylib"
    flags      = "-dynamiclib"
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
