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
	ext  = "dylib"
	args = {
		"-dynamiclib", "-undefined", "dynamic_lookup", "-O2",
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
