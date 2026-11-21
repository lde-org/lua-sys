-- build.lua — Compiles the C bridge module for lua-sys.
--
-- bridge.c has no undefined lua* symbols on any platform: it resolves them
-- at load time from the LuaJIT that loads it (see bridge_resolve_symbols), so
-- it links with no LuaJIT at all and binds to the right one even inside a
-- library built with `lde compile --shared` whose host has its own Lua.
--
-- The output follows build.target, not the host, so cross-compiling (e.g.
-- `lde compile --target windows-x86-64`) produces a bridge.dll.

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

local target = build.target or "unknown"
local isWindows, isMacos
if target == "unknown" then
	isWindows, isMacos = jit.os == "Windows", jit.os == "OSX"
else
	isWindows = target:find("windows", 1, true) or target:find("mingw", 1, true)
	isMacos = target:find("apple", 1, true) or target:find("darwin", 1, true)
end

local ext, args
if isWindows then
	ext = "dll"
	args = { "-shared", "-O2", "-I", out, "-o", out .. "/bridge." .. ext, out .. "/bridge.c" }
elseif isMacos then
	ext = "dylib"
	-- macOS dyld dedupes dylibs by install name (LC_ID_DYLIB): if a copy of
	-- this dylib is already loaded (e.g. the one embedded in the lde binary,
	-- whose install name defaults to its build path), dlopen'ing a fresh
	-- build at that same path returns the stale image — e.g. bridge.new_state
	-- coming back nil on macOS. A content-derived install name means identical
	-- copies share a name (harmless) but different versions never shadow each
	-- other. The require path is unchanged.
	local hash = 5381
	do
		local f = io.open(out .. "/bridge.c", "rb")
		if f then
			local data = f:read("*a")
			f:close()
			for i = 1, #data do
				hash = bit.band(hash * 33 + string.byte(data, i), 0xFFFFFFFF)
			end
		end
	end
	args = {
		"-dynamiclib",
		"-undefined",
		"dynamic_lookup",
		"-O2",
		"-install_name",
		"@rpath/bridge-" .. bit.tohex(hash, 8) .. ".dylib",
		"-I",
		out,
		"-o",
		out .. "/bridge." .. ext,
		out .. "/bridge.c"
	}
else
	ext = "so"
	args = { "-shared", "-fPIC", "-O2", "-I", out, "-o", out .. "/bridge." .. ext, out .. "/bridge.c" }
	-- dlopen/dladdr1 live in libdl before glibc 2.34; FreeBSD has them in libc.
	if target:find("linux", 1, true) or (target == "unknown" and jit.os == "Linux") then
		args[#args + 1] = "-ldl"
	end
end

build:cc(args)
