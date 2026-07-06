-- build.lua — Compiles the C bridge module for lua-sys.
--
-- Uses gcc (available on all supported platforms via MinGW on Windows).
-- No system luajit-dev package is needed: lde already embeds LuaJIT and
-- exports all required symbols. On Linux/macOS the shared library resolves
-- them at runtime from the process image. On Windows they must be resolved
-- at link time via an import library generated from lde.exe.

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

local ext, flags, extra_link
if jit.os == "Windows" then
    ext        = "dll"
    flags      = "-shared"
    -- Windows DLLs cannot resolve symbols from the host executable at
    -- runtime. Generate a minimal import library from a .def file so gcc
    -- can link against lde.exe's embedded LuaJIT symbols.
    local def_path = out .. "/lde.def"
    local lib_path = out .. "/liblde.a"
    local def = io.open(def_path, "w")
    def:write("EXPORTS\n")
    for _, sym in ipairs({
        "lua_call", "lua_error", "lua_gettop", "lua_pcall",
        "lua_pushboolean", "lua_pushcclosure", "lua_pushfstring",
        "lua_pushinteger", "lua_pushlightuserdata", "lua_pushlstring",
        "lua_pushnil", "lua_pushnumber", "lua_pushstring", "lua_pushvalue",
        "lua_rawgeti", "lua_rawseti", "lua_settop",
        "lua_toboolean", "lua_tonumber", "lua_tolstring", "lua_touserdata",
        "lua_type", "lua_typename",
        "luaL_checktype", "luaL_error", "luaL_newstate", "luaL_ref",
        "luaL_register", "luaL_unref",
    }) do
        def:write("    " .. sym .. "\n")
    end
    def:close()
    build:sh("dlltool -d " .. def_path .. " -l " .. lib_path)
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
    .. (extra_link or ""))
