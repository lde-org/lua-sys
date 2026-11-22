# Luau test fixture

Builds `libluau.so`, a Luau VM with its C API exported under the same
plain-C names as Lua (`lua_newstate`, `lua_pcall`, `luaL_openlibs`, ...). The
lua-sys `luau` binding and bridge tests load it through the FFI and through
`lua:open(path)`.

This fixture is **not shipped**: it is not listed in `lde.json` and is not part
of the lua-sys package. Only `src/` ships.

## What it builds

- Luau, pinned to release tag **0.748** (see `LUAU_TAG` in `build.sh`).
- CMake `Release` with `CMAKE_POSITION_INDEPENDENT_CODE=ON` and
  `LUAU_EXTERN_C=ON` (plain C linkage, and `LUA_USE_LONGJMP` so `luaL_error`
  longjmps instead of throwing a C++ exception through C frames).
- Static `Luau.VM`, `Luau.Compiler`, `Luau.Ast`, `Luau.Bytecode` and
  `Luau.Common`, whole-archived into a single `libluau.so` (a shared object).
  `-Wl,-Bsymbolic` binds the library's internal `lua_*` references locally:
  the host LuaJIT that loads it also exports `lua_*`, and without local
  binding Luau's own calls would resolve to the LuaJIT implementation and
  crash on a Luau state.
- Public headers, copied from the pinned source for reference:
  `include/lua.h`, `include/luaconf.h`, `include/lualib.h` (from `VM/include`)
  and `include/luacode.h` (from `Compiler/include`).

Both source compilation (`luau_compile`) and bytecode loading (`luau_load`)
are available, so `caps.source` is true for this runtime.

## Build

```sh
./tests/fixtures/luau/build.sh
```

Requirements: `bash`, `curl`, `tar`, `cmake`, a C++17 compiler and `nm`
(Linux/ELF; the script produces a `.so`). The first run downloads ~3.4 MB of
source and takes ~35 s; later runs are no-ops while the outputs exist.

The script is idempotent: if `libluau.so` exists, exports the required
symbols, its `target/luau-fixture/.luau-tag` stamp matches `LUAU_TAG`, and the headers are
present, it exits immediately. It works from any working directory (paths are
resolved from the script location) and fails loudly (non-zero exit,
`[luau-fixture] ERROR: ...`) when a tool, download, build, link or symbol
check fails.

Force a rebuild:

```sh
rm -rf target/luau-fixture tests/fixtures/luau/libluau.so
./tests/fixtures/luau/build.sh
```

To bump Luau, change `LUAU_TAG` in `build.sh` (the URL is derived from it) and
rebuild from scratch.

## How tests find it

1. `LUA_SYS_LUAU=/absolute/path/to/libluau.so` — used when set.
2. Otherwise `tests/fixtures/luau/libluau.so` (this directory).

Tests skip the Luau cases when neither exists. The env var points at the
shared library itself, not the directory; `LUA_SYS_LUAU` also overrides the
default path for `lua:open`.

## Contents

| Path | Tracked | Description |
|---|---|---|
| `build.sh` | yes | downloads, builds and links the library |
| `README.md` | yes | this file |
| `.gitignore` | yes | ignores generated outputs |
| `target/luau-fixture/` | no | source tarball, extracted tree, CMake build tree, logs (outside `tests/`) |
| `libluau.so` | no | the linked shared library |
| `include/` | no | generated header copies |

## Export check

The build verifies a fixed set of symbols (see `REQUIRED_SYMBOLS` in
`build.sh`) with `nm -D --defined-only`, including `lua_newstate`,
`luaL_newstate`, `luaL_openlibs`, `lua_pcall`, `lua_pushcclosurek`, `lua_ref`,
`lua_unref`, `lua_callbacks`, `lua_singlestep`, `luau_load` and
`luau_compile`. Names that are macros in Lua 5.1 (`lua_pushcclosure`,
`lua_tonumber`, `lua_getglobal`, `luaL_ref`, ...) are not exported by Luau;
use the underlying symbols listed in the multi-runtime notes.

## Quick sanity check

```lua
local ffi = require("ffi")
ffi.cdef[[
typedef struct lua_State lua_State;
typedef struct lua_CompileOptions lua_CompileOptions;
lua_State* luaL_newstate(void);
void luaL_openlibs(lua_State* L);
int lua_pcall(lua_State* L, int nargs, int nresults, int errfunc);
double lua_tonumberx(lua_State* L, int idx, int* isnum);
char* luau_compile(const char* source, size_t size, lua_CompileOptions* options, size_t* outsize);
int luau_load(lua_State* L, const char* chunkname, const char* data, size_t size, int env);
void free(void* p);
]]

local lib = ffi.load("tests/fixtures/luau/libluau.so")
local L = lib.luaL_newstate()
lib.luaL_openlibs(L)

local source, size = "return 6 * 7", ffi.new("size_t[1]")
local bytecode = lib.luau_compile(source, #source, nil, size)
assert(lib.luau_load(L, "=sanity", bytecode, size[0], 0) == 0)
ffi.C.free(bytecode)
assert(lib.lua_pcall(L, 0, 1, 0) == 0)
print(lib.lua_tonumberx(L, -1, nil)) --> 42
```
