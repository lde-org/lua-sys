#!/usr/bin/env bash
# Builds a single libluau.so exporting the Luau C API (VM + Compiler + Ast).
#
#   tests/fixtures/luau/build.sh
#
# Outputs (generated, gitignored; see .gitignore):
#   tests/fixtures/luau/libluau.so          one shared library, C API exported
#   tests/fixtures/luau/include/*.h         public VM and compiler headers
#   target/luau-fixture/                    download + cmake build tree
#
# The build tree lives outside tests/ on purpose: `lde test` discovers every
# *.test.lua below tests/, and the Luau source archive ships its own tests.
#
# Idempotent: the download, cmake configure/build and link are skipped when
# the outputs already exist, carry the current tag stamp, and `libluau.so`
# exports the required symbols.
set -euo pipefail

# Luau release tag this fixture is pinned to. Bump deliberately: the fixture
# is a test dependency, not a rolling one.
LUAU_TAG="0.748"
LUAU_URL="https://github.com/luau-lang/luau/archive/refs/tags/${LUAU_TAG}.tar.gz"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_DIR="${HERE}/../../../target/luau-fixture"
SRC_DIR="${BUILD_DIR}/luau-${LUAU_TAG}"
CMAKE_DIR="${BUILD_DIR}/cmake-${LUAU_TAG}"
TARBALL="${BUILD_DIR}/luau-${LUAU_TAG}.tar.gz"
OUT_LIB="${HERE}/libluau.so"
OUT_INC="${HERE}/include"
STAMP="${BUILD_DIR}/.luau-tag"

REQUIRED_SYMBOLS=(
	lua_newstate lua_close lua_newthread lua_tothread
	lua_gettop lua_settop lua_pushvalue lua_type lua_typename
	lua_pushnil lua_pushboolean lua_pushnumber lua_pushinteger
	lua_pushlstring lua_pushlightuserdatatagged lua_pushcclosurek
	lua_tonumberx lua_tointegerx lua_toboolean lua_tolstring lua_tocfunction
	lua_touserdata lua_topointer lua_createtable lua_rawgeti lua_rawseti
	lua_getfield lua_setfield lua_gettable lua_settable lua_call
	lua_pcall lua_resume lua_yield lua_gc lua_error
	lua_newuserdatatagged lua_setmetatable lua_getmetatable
	lua_ref lua_unref lua_callbacks lua_singlestep
	lua_getinfo lua_getlocal lua_setlocal lua_getupvalue lua_setupvalue
	luaL_newstate luaL_openlibs luaL_errorL
	luaL_checkstack luaL_typename luaL_where
	luau_load luau_compile
)

log() { printf '[luau-fixture] %s\n' "$*"; }
die() { printf '[luau-fixture] ERROR: %s\n' "$*" >&2; exit 1; }

trap 'die "failed at line ${LINENO} (command: ${BASH_COMMAND})"' ERR

missing_tools=()
for tool in curl tar cmake c++ nm; do
	command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
((${#missing_tools[@]} == 0)) || die "missing required tools: ${missing_tools[*]}"

# Verified against the dynamic symbol table. GNU nm prints symbols in field 3.
check_exports() {
	local lib="$1" sym
	[[ -f "$lib" ]] || die "missing ${lib}"
	local defined
	defined="$(nm -D --defined-only "$lib" | awk '{print $NF}')" ||
		die "nm failed on ${lib}"
	for sym in "${REQUIRED_SYMBOLS[@]}"; do
		grep -qx -- "$sym" <<<"$defined" ||
			die "${lib} does not export ${sym} (stale or broken build; remove ${BUILD_DIR})"
	done
}

headers_complete() {
	[[ -f "${OUT_INC}/lua.h" && -f "${OUT_INC}/luaconf.h" &&
		-f "${OUT_INC}/lualib.h" && -f "${OUT_INC}/luacode.h" ]]
}

if [[ -f "$OUT_LIB" ]] && headers_complete; then
	if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$LUAU_TAG" ]]; then
		check_exports "$OUT_LIB"
		log "up to date: ${OUT_LIB} (Luau ${LUAU_TAG}); nothing to do"
		exit 0
	fi
	log "outputs exist but were not built from Luau ${LUAU_TAG}; rebuilding"
fi

# --- source -----------------------------------------------------------------

mkdir -p "$BUILD_DIR"

if [[ ! -f "$TARBALL" ]]; then
	log "downloading Luau ${LUAU_TAG} from ${LUAU_URL}"
	curl -fsSL --retry 3 --retry-connrefused -o "${TARBALL}.part" "$LUAU_URL" ||
		die "download failed: ${LUAU_URL}"
	mv "${TARBALL}.part" "$TARBALL"
fi

if [[ ! -d "$SRC_DIR" ]]; then
	log "extracting ${TARBALL}"
	tar -xzf "$TARBALL" -C "$BUILD_DIR" || die "extract failed: ${TARBALL}"
fi
[[ -f "${SRC_DIR}/CMakeLists.txt" ]] || die "source tree incomplete: ${SRC_DIR}"

# --- build ------------------------------------------------------------------

# One configuration for all static libs: Release, PIC (they are linked into a
# shared object), extern "C" so the C API is directly callable from the FFI.
# LUAU_EXTERN_C also sets LUA_USE_LONGJMP, which luaL_error needs: without it
# errors throw C++ exceptions through C frames.
log "configuring (Release, PIC, extern C)"
start_ns="$(date +%s%N)"
cmake -S "$SRC_DIR" -B "$CMAKE_DIR" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DBUILD_SHARED_LIBS=OFF \
	-DLUAU_BUILD_CLI=OFF \
	-DLUAU_BUILD_TESTS=OFF \
	-DLUAU_BUILD_WEB=OFF \
	-DLUAU_WERROR=OFF \
	-DLUAU_EXTERN_C=ON \
	>"${BUILD_DIR}/cmake-configure.log" 2>&1 ||
	{ cat "${BUILD_DIR}/cmake-configure.log" >&2; die "cmake configure failed"; }

log "building Luau.VM Luau.Compiler Luau.Ast Luau.Bytecode Luau.Common"
cmake --build "$CMAKE_DIR" --parallel \
	--target Luau.VM Luau.Compiler Luau.Ast Luau.Bytecode Luau.Common \
	>"${BUILD_DIR}/cmake-build.log" 2>&1 ||
	{ tail -n 100 "${BUILD_DIR}/cmake-build.log" >&2; die "cmake build failed (full log: ${BUILD_DIR}/cmake-build.log)"; }

for archive in Luau.VM Luau.Compiler Luau.Ast Luau.Bytecode Luau.Common; do
	[[ -f "${CMAKE_DIR}/lib${archive}.a" ]] || die "missing ${CMAKE_DIR}/lib${archive}.a"
done

# Whole-archive everything: the VM references compiler/ast symbols only through
# callbacks, and the linker would otherwise drop most of the C API when no
# symbol from an archive is referenced by the shared object itself.
#
# -Bsymbolic is required: the library is dlopen'd into a LuaJIT host that
# exports its own lua_* symbols. Without local binding, Luau's internal calls
# (lua_pcall, luaL_openlibs, ...) would resolve to the host's LuaJIT functions
# through the global scope and crash on a Luau state.
log "linking ${OUT_LIB}"
c++ -shared -Wl,-Bsymbolic -o "${OUT_LIB}.tmp" \
	-Wl,--whole-archive \
	"${CMAKE_DIR}/libLuau.VM.a" \
	"${CMAKE_DIR}/libLuau.Compiler.a" \
	"${CMAKE_DIR}/libLuau.Ast.a" \
	"${CMAKE_DIR}/libLuau.Bytecode.a" \
	"${CMAKE_DIR}/libLuau.Common.a" \
	-Wl,--no-whole-archive \
	|| die "link failed"

mv "${OUT_LIB}.tmp" "$OUT_LIB"

# --- headers ----------------------------------------------------------------

log "copying headers to ${OUT_INC}"
mkdir -p "$OUT_INC"
cp "${SRC_DIR}"/VM/include/*.h "$OUT_INC"/
cp "${SRC_DIR}/Compiler/include/luacode.h" "$OUT_INC"/
headers_complete || die "headers incomplete in ${OUT_INC}"

# --- verify -----------------------------------------------------------------

check_exports "$OUT_LIB"
printf '%s\n' "$LUAU_TAG" > "$STAMP"

end_ns="$(date +%s%N)"
elapsed_ms=$(((end_ns - start_ns) / 1000000))
log "done in $((elapsed_ms / 1000)).$(printf '%03d' $((elapsed_ms % 1000)))s"
log "library: ${OUT_LIB} ($(du -h "$OUT_LIB" | cut -f1))"
log "headers: ${OUT_INC} (lua.h luaconf.h lualib.h luacode.h)"
log "symbols: $(nm -D --defined-only "$OUT_LIB" | wc -l) dynamic definitions"
