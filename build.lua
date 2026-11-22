-- build.lua — native artifacts for lua-sys.
--
-- high:    bridge.c -> bridge.<ext>. bridge.c has no undefined lua* symbols
--          on any platform: it resolves them at load time from the LuaJIT
--          that loads it (see bridge_resolve_symbols), so it links with no
--          LuaJIT at all and binds to the right one even inside a library
--          built with `lde compile --shared` whose host has its own Lua.
--
-- bundled: the chosen runtime (luajit/lua51/lua54/luau) is built into
--          bundled.<ext>, a shared library exporting its full C API (module
--          lua-sys.bundled). LuaJIT links the lde-org/luajit prebuilt dist
--          whole-archive; Lua 5.1/5.4 compile the official lua.org sources;
--          Luau compiles the pinned release as C++17. Downloads and builds
--          are cached in the output directory.
--
-- vendored: nothing to build (the host process provides the runtime).
--
-- The output follows build.target, not the host, so cross-compiling (e.g.
-- `lde compile --target windows-x86-64`) produces bridge.dll/bundled.dll.

local build = require("lde-build")

local out = assert(build.outDir, "build.outDir is not set")
local target = build.target or "unknown"

-- ── Target classification ──────────────────────────────────────────────────

local function classifyTarget()
	local platform, arch, libc

	if target:find("windows", 1, true) or target:find("mingw", 1, true) then
		platform = "windows"
	elseif target:find("apple", 1, true) or target:find("darwin", 1, true) then
		platform = "macos"
	elseif target:find("freebsd", 1, true) then
		platform = "freebsd"
	elseif target:find("android", 1, true) or target:find("linux", 1, true) then
		platform = "linux"
	end

	const machine = target:match("^([^-]+)")
	if machine == "x86_64" or machine == "x86-64" or machine == "amd64" then
		arch = "x86-64"
	elseif machine == "aarch64" or machine == "arm64" then
		arch = "aarch64"
	end

	if target:find("android", 1, true) then
		libc = "android"
	elseif target:find("musl", 1, true) then
		libc = "musl"
	elseif target:find("gnu", 1, true) then
		libc = "gnu"
	end

	-- build.target is the host triple unless cross-compiling, so this fallback
	-- only covers a driver that did not report one.
	if not platform then
		local os = jit and jit.os
		platform = os == "Windows" and "windows" or os == "OSX" and "macos" or os == "BSD" and "freebsd" or "linux"
	end
	if not arch then
		arch = jit and jit.arch == "arm64" and "aarch64" or "x86-64"
	end
	if platform == "macos" or platform == "freebsd" then
		libc = nil
	elseif platform == "windows" and not libc then
		libc = "gnu"
	elseif platform == "linux" and not libc then
		libc = "gnu"
	end

	return platform, arch, libc
end

local platform, arch, libc = classifyTarget()

local isWindows = platform == "windows"
local isMacos = platform == "macos"
local isElf = platform == "linux" or platform == "freebsd"
local sharedFlag = isMacos and "-dynamiclib" or "-shared"

---@param list string[]
---@param extra string[]
local function addAll(list, extra)
	for _, value in ipairs(extra) do
		list[#list + 1] = value
	end
end

-- ── Feature validation ─────────────────────────────────────────────────────
--
-- One Lua version and at most one source. `lde` is the LuaJIT lde itself
-- links, so it implies (and only accepts) the luajit version. Platform flags
-- are ignored here.

const VERSION_FLAGS = { "luajit", "lua51", "lua54", "luau" }
const SOURCE_FLAGS = { "lde", "vendored", "bundled" }

---@param flags string[]
local function enabledFlags(flags)
	local found = {}
	for _, flag in ipairs(flags) do
		if build:feature(flag) then found[#found + 1] = flag end
	end
	return found
end

---@param message string
local function fail(message)
	error("lua-sys: " .. message, 0)
end

local versions = enabledFlags(VERSION_FLAGS)
local sources = enabledFlags(SOURCE_FLAGS)

if #versions > 1 then
	fail(
		"more than one Lua version feature is enabled (" .. table.concat(versions, ", ") .. "); enable exactly one of luajit, lua51, lua54, luau"
	)
end
if #sources > 1 then
	fail(
		"more than one runtime source feature is enabled (" .. table.concat(sources, ", ") .. "); enable at most one of lde, vendored, bundled"
	)
end

local version = versions[1]
local source = sources[1]

if source == "lde" then
	if version ~= nil and version ~= "luajit" then
		fail("'lde' uses the LuaJIT that lde links; it cannot be combined " .. "with the '" .. version .. "' version feature")
	end
	version = version or "luajit" -- lde alone implies luajit
end

if source == "bundled" and version == nil then
	fail("'bundled' needs a version feature: one of luajit, lua51, lua54, luau")
end

-- ── Bridge ─────────────────────────────────────────────────────────────────

if build:feature("high") then
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
		if platform == "linux" then
			args[#args + 1] = "-ldl"
		end
	end
	build:cc(args)
end

-- ── Bundled runtime ────────────────────────────────────────────────────────

if source == "bundled" then
	const ext = isWindows and "dll" or (isMacos and "dylib" or "so")
	const output = "bundled." .. ext
	const stampFile = "bundled.stamp"
	const stampValue = version .. "\n" .. target .. "\n"
	const cache = "bundled-cache"

	local isFresh = build:exists(output) and build:exists(stampFile) and build:read(stampFile) == stampValue

	if not isFresh then
		const tmp = "bundled.tmp." .. ext
		const tmpPath = out .. "/" .. tmp

		---@param cacheRel string # archive path relative to the output dir
		---@param url string
		---@param root string # directory the archive extracts to, below cache
		---@param marker string # file that proves the extraction is complete
		local function ensureExtracted(cacheRel, url, root, marker)
			if build:exists(root .. "/" .. marker) then return end
			if not build:exists(cacheRel) then
				build:write(cacheRel, build:fetch(url))
			end
			build:extract(cacheRel, cache)
			if not build:exists(root .. "/" .. marker) then
				fail("could not extract " .. cacheRel)
			end
		end

		if version == "luajit" then
			-- Same dist naming as packages/sea/src/target.lua.
			const distName = "libluajit-" .. platform .. "-" .. arch .. (libc and ("-" .. libc) or "")
			const root = cache .. "/" .. distName
			ensureExtracted(
				cache .. "/" .. distName .. ".tar.gz",
				"https://github.com/lde-org/luajit/releases/download/latest/" .. distName .. ".tar.gz",
				root,
				"lib/libluajit.a"
			)

			local lib = out .. "/" .. root .. "/lib/libluajit.a"
			local args
			if isMacos then
				-- ld64 spells whole-archive "-all_load".
				args = { sharedFlag, "-O2", "-Wl,-all_load", lib }
			else
				args = { sharedFlag, "-O2", "-Wl,--whole-archive", lib, "-Wl,--no-whole-archive" }
			end
			if isElf then
				addAll(args, { "-Wl,-Bsymbolic", "-lm", "-ldl" })
			elseif isWindows then
				addAll(args, { "-Wl,--export-all-symbols" })
			end
			addAll(args, { "-o", tmpPath })
			build:cc(args)
		elseif version == "lua51" or version == "lua54" then
			-- Pinned official sources. lua54 tracks the latest 5.4 release.
			const releases = {
				lua51 = { root = "lua-5.1.5", url = "https://www.lua.org/ftp/lua-5.1.5.tar.gz" },
				lua54 = { root = "lua-5.4.8", url = "https://www.lua.org/ftp/lua-5.4.8.tar.gz" }
			}
			const release = releases[version]
			const root = cache .. "/" .. release.root
			ensureExtracted(cache .. "/" .. release.root .. ".tar.gz", release.url, root, "src/lua.h")

			-- Every library translation unit; lua.c/luac.c are the command-line
			-- programs and onelua.c is the generated single-file amalgamation.
			local sources = {}
			---@type string[]
			local cSources = build:scan(root .. "/src", "*.c")
			for _, rel in ipairs(cSources) do
				const name = rel:match("([^/\\]+)$")
				if name ~= "lua.c" and name ~= "luac.c" and name ~= "onelua.c" then
					sources[#sources + 1] = out .. "/" .. rel
				end
			end
			table.sort(sources)

			local args = { sharedFlag }
			if not isWindows then addAll(args, { "-fPIC" }) end
			addAll(args, { "-O2" })
			if isWindows then
				addAll(args, { "-DLUA_BUILD_AS_DLL", "-DLUA_CORE" })
			elseif isMacos then
				addAll(args, { "-DLUA_USE_MACOSX" })
			elseif version == "lua51" and platform == "linux" then
				addAll(args, { "-DLUA_USE_LINUX" })
			else
				addAll(args, { "-DLUA_USE_POSIX", "-DLUA_USE_DLOPEN" })
			end
			if isElf then addAll(args, { "-Wl,-Bsymbolic" }) end
			addAll(args, sources)
			addAll(args, { "-o", tmpPath })
			if isElf then addAll(args, { "-lm", "-ldl" }) end
			build:cc(args)
		elseif version == "luau" then
			-- Same tag as tests/fixtures/luau/build.sh. CMake's LUAU_EXTERN_C=ON
			-- is spelled out here as the two API macros plus LUA_USE_LONGJMP.
			const tag = "0.748"
			const root = cache .. "/luau-" .. tag
			ensureExtracted(
				cache .. "/luau-" .. tag .. ".tar.gz",
				"https://github.com/luau-lang/luau/archive/refs/tags/" .. tag .. ".tar.gz",
				root,
				"VM/include/lua.h"
			)

			local sources = {}
			for _, dir in ipairs({ "VM/src", "Compiler/src", "Ast/src", "Common/src", "Bytecode/src" }) do
				---@type string[]
				local found = build:scan(root .. "/" .. dir, "*.cpp")
				for _, rel in ipairs(found) do
					sources[#sources + 1] = out .. "/" .. rel
				end
			end
			table.sort(sources)

			local args = { sharedFlag }
			if not isWindows then addAll(args, { "-fPIC" }) end
			addAll(args, {
				"-x",
				"c++",
				"-std=c++17",
				"-O2",
				"-fno-math-errno",
				"-DLUA_USE_LONGJMP=1",
				"-DLUA_API=extern \"C\"",
				"-DLUACODE_API=extern \"C\"",
				"-I",
				out .. "/" .. root .. "/VM/include",
				"-I",
				out .. "/" .. root .. "/Compiler/include",
				"-I",
				out .. "/" .. root .. "/Ast/include",
				"-I",
				out .. "/" .. root .. "/Common/include",
				"-I",
				out .. "/" .. root .. "/Bytecode/include",
				"-I",
				out .. "/" .. root .. "/VM/src"
			})
			if isElf then addAll(args, { "-Wl,-Bsymbolic" }) end
			addAll(args, sources)
			addAll(args, { "-x", "none" })
			if isWindows then
				addAll(args, { "-lstdc++", "-static-libstdc++", "-static-libgcc", "-Wl,--export-all-symbols" })
			elseif platform == "linux" then
				addAll(args, { "-lstdc++" })
			else
				addAll(args, { "-lc++" })
			end
			addAll(args, { "-o", tmpPath })
			build:cc(args)
		else
			fail("unsupported bundled version '" .. tostring(version) .. "'")
		end

		if build:exists(output) then build:delete(output) end
		build:move(tmp, output)
		build:write(stampFile, stampValue)
	end
end
