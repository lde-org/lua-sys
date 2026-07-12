-- build.lua — Compiles the C bridge module for lua-sys.
--
-- Linux/macOS: bridge.so/.dylib leaves lua* symbols unresolved at link time;
--   they are satisfied at load time from the host process image.
--
-- Windows: PE executables do not export symbols to DLLs, so we download a
--   pre-built libluajit and link it directly into bridge.dll. Guest states
--   use this embedded runtime — safe because lua-sys communicates with the
--   host exclusively through the Lua C API (push/pop, registry refs).

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

local ext, args
if jit.os == "Windows" then
	ext = "dll"

	local arch    = jit.arch == "arm64" and "aarch64" or "x86-64"
	local tarName = "libluajit-windows-" .. arch .. "-gnu.tar.gz"
	local tarUrl  = "https://github.com/lde-org/luajit/releases/download/latest/" .. tarName

	build:write(tarName, build:fetch(tarUrl))
	build:extract(tarName, "luajit")
	build:delete(tarName)

	local ljDir = out .. "/luajit/libluajit-windows-" .. arch .. "-gnu"

	args = {
		"-shared", "-O2",
		"-I", out,
		"-I", ljDir .. "/include",
		"-o", out .. "/bridge." .. ext,
		out .. "/bridge.c",
		"-Wl,--whole-archive", ljDir .. "/lib/libluajit.a", "-Wl,--no-whole-archive",
		"-lm",
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
