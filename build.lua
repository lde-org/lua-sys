-- build.lua — Compiles the C bridge module for lua-sys.
--
-- Linux/macOS: bridge.so/.dylib leaves lua* symbols unresolved at link time;
--   they are satisfied at load time from the host process image.
--
-- Windows: PE DLLs cannot defer symbol resolution to the process image, so
--   bridge.c resolves all lua* symbols itself at load time via
--   GetProcAddress(GetModuleHandle(NULL), ...) (lde exports them from the
--   exe with -Wl,--export-all-symbols). bridge.dll therefore links with no
--   LuaJIT at all — same single-runtime model as the POSIX builds.

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

local ext, args
if jit.os == "Windows" then
	ext = "dll"
	args = {
		"-shared", "-O2",
		"-I", out,
		"-o", out .. "/bridge." .. ext,
		out .. "/bridge.c",
	}
elseif jit.os == "OSX" then
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
		"-dynamiclib", "-undefined", "dynamic_lookup", "-O2",
		"-install_name", "@rpath/bridge-" .. bit.tohex(hash, 8) .. ".dylib",
		"-I", out,
		"-o", out .. "/bridge." .. ext,
		out .. "/bridge.c",
	}
else
	ext  = "so"
	args = {
		"-shared", "-fPIC", "-O2",
		"-I", out,
		"-o", out .. "/bridge." .. ext,
		out .. "/bridge.c",
	}
end

-- build:cc(args)
local compiler = os.getenv("SEA_CC") or "gcc"
build:sh(compiler .. " " .. table.concat(args, " "))
