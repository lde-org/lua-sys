local ffi = require("ffi")

ffi.cdef [[
  typedef struct lua_State lua_State;
  typedef int (*lua_CFunction)(lua_State *L);

  typedef struct {
    int event;
    const char *name;
    const char *namewhat;
    const char *what;
    const char *source;
    int currentline;
    int nups;
    int linedefined;
    int lastlinedefined;
    char short_src[60];
    int i_ci;
  } lua_Debug;

  typedef struct {
    char *p;
    int lvl;
    lua_State *L;
    char buffer[512];
  } luaL_Buffer;

  typedef struct {
    const char *name;
    lua_CFunction func;
  } luaL_Reg;

  typedef const char *(*lua_Reader)(lua_State *L, void *data, size_t *size);
  typedef int (*lua_Writer)(lua_State *L, const void *p, size_t sz, void *ud);
  typedef void *(*lua_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);
  typedef double lua_Number;
  typedef ptrdiff_t lua_Integer;

  typedef void (*lua_Hook)(lua_State *L, lua_Debug *ar);

  void *lua_atpanic(lua_State *L, lua_CFunction panicf);
  void lua_call(lua_State *L, int nargs, int nresults);
  int lua_checkstack(lua_State *L, int extra);
  void lua_close(lua_State *L);
  void lua_concat(lua_State *L, int n);
  void lua_copy(lua_State *L, int fromidx, int toidx);
  int lua_cpcall(lua_State *L, lua_CFunction func, void *ud);
  void lua_createtable(lua_State *L, int narr, int nrec);
  int lua_dump(lua_State *L, lua_Writer writer, void *data);
  int lua_equal(lua_State *L, int idx1, int idx2);
  int lua_error(lua_State *L);
  int lua_gc(lua_State *L, int what, int data);
  lua_Alloc lua_getallocf(lua_State *L, void **ud);
  int lua_getfenv(lua_State *L, int idx);
  void lua_getfield(lua_State *L, int idx, const char *k);
  lua_Hook lua_gethook(lua_State *L);
  int lua_gethookcount(lua_State *L);
  int lua_gethookmask(lua_State *L);
  int lua_getinfo(lua_State *L, const char *what, lua_Debug *ar);
  const char *lua_getlocal(lua_State *L, const lua_Debug *ar, int n);
  int lua_getmetatable(lua_State *L, int objindex);
  int lua_getstack(lua_State *L, int level, lua_Debug *ar);
  void lua_gettable(lua_State *L, int idx);
  int lua_gettop(lua_State *L);
  const char *lua_getupvalue(lua_State *L, int funcindex, int n);
  void lua_insert(lua_State *L, int idx);
  int lua_iscfunction(lua_State *L, int idx);
  int lua_isnumber(lua_State *L, int idx);
  int lua_isstring(lua_State *L, int idx);
  int lua_isuserdata(lua_State *L, int idx);
  int lua_isyieldable(lua_State *L);
  int luaJIT_setmode(lua_State *L, int idx, int mode);
  void luaJIT_profile_start(lua_State *L, const char *mode, void (*cb)(void *data, lua_State *L, int samples, int vmstate), void *data);
  void luaJIT_profile_stop(lua_State *L);
  const char *luaJIT_profile_dumpstack(lua_State *L, const char *fmt, int depth, int *len);
  void luaL_addlstring(luaL_Buffer *B, const char *s, size_t l);
  void luaL_addstring(luaL_Buffer *B, const char *s);
  void luaL_addvalue(luaL_Buffer *B);
  int luaL_argerror(lua_State *L, int narg, const char *extramsg);
  void luaL_buffinit(lua_State *L, luaL_Buffer *B);
  int luaL_callmeta(lua_State *L, int obj, const char *e);
  void luaL_checkany(lua_State *L, int narg);
  lua_Integer luaL_checkinteger(lua_State *L, int numArg);
  const char *luaL_checklstring(lua_State *L, int numArg, size_t *l);
  lua_Number luaL_checknumber(lua_State *L, int numArg);
  int luaL_checkoption(lua_State *L, int narg, const char *def, const char *const *lst);
  void luaL_checkstack(lua_State *L, int sz, const char *msg);
  void luaL_checktype(lua_State *L, int narg, int t);
  void *luaL_checkudata(lua_State *L, int ud, const char *tname);
  int luaL_error(lua_State *L, const char *fmt, ...);
  int luaL_execresult(lua_State *L, int stat);
  int luaL_fileresult(lua_State *L, int stat, const char *fname);
  int luaL_findtable(lua_State *L, int idx, const char *fname, int szhint);
  int luaL_getmetafield(lua_State *L, int obj, const char *e);
  const char *luaL_gsub(lua_State *L, const char *s, const char *p, const char *r);
  int luaL_loadbuffer(lua_State *L, const char *buff, size_t sz, const char *name);
  int luaL_loadbufferx(lua_State *L, const char *buff, size_t sz, const char *name);
  int luaL_loadfile(lua_State *L, const char *filename);
  int luaL_loadfilex(lua_State *L, const char *filename, const char *mode);
  int luaL_loadstring(lua_State *L, const char *s);
  int luaL_newmetatable(lua_State *L, const char *tname);
  lua_State *luaL_newstate(void);
  int luaL_openlib(lua_State *L, const char *libname, const luaL_Reg *l, int nup);
  void luaL_openlibs(lua_State *L);
  lua_Integer luaL_optinteger(lua_State *L, int numArg, lua_Integer def);
  const char *luaL_optlstring(lua_State *L, int numArg, const char *def, size_t *l);
  lua_Number luaL_optnumber(lua_State *L, int numArg, lua_Number def);
  char *luaL_prepbuffer(luaL_Buffer *B);
  void luaL_pushmodule(lua_State *L, const char *modname, int sizehint);
  void luaL_pushresult(luaL_Buffer *B);
  int luaL_ref(lua_State *L, int t);
  void luaL_register(lua_State *L, const char *libname, const luaL_Reg *l);
  void luaL_setfuncs(lua_State *L, const luaL_Reg *l, int nup);
  void luaL_setmetatable(lua_State *L, const char *tname);
  int luaL_testudata(lua_State *L, int ud, const char *tname);
  void luaL_traceback(lua_State *L1, lua_State *L2, const char *msg, int level);
  int luaL_typerror(lua_State *L, int narg, const char *tname);
  void luaL_unref(lua_State *L, int t, int ref);
  void luaL_where(lua_State *L, int lvl);
  int lua_load(lua_State *L, lua_Reader reader, void *data, const char *chunkname);
  int lua_loadx(lua_State *L, lua_Reader reader, void *data, const char *chunkname, const char *mode);
  lua_State *lua_newstate(lua_Alloc f, void *ud);
  lua_State *lua_newthread(lua_State *L);
  void *lua_newuserdata(lua_State *L, size_t sz);
  int lua_next(lua_State *L, int idx);
  size_t lua_objlen(lua_State *L, int idx);
  int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
  void lua_pushboolean(lua_State *L, int b);
  void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);
  const char *lua_pushfstring(lua_State *L, const char *fmt, ...);
  void lua_pushinteger(lua_State *L, lua_Integer n);
  void lua_pushlightuserdata(lua_State *L, void *p);
  void lua_pushlstring(lua_State *L, const char *s, size_t ls);
  void lua_pushnil(lua_State *L);
  void lua_pushnumber(lua_State *L, lua_Number n);
  const char *lua_pushstring(lua_State *L, const char *s);
  int lua_pushthread(lua_State *L);
  void lua_pushvalue(lua_State *L, int idx);
  const char *lua_pushvfstring(lua_State *L, const char *fmt, void *argp);
  int lua_rawequal(lua_State *L, int idx1, int idx2);
  void lua_rawget(lua_State *L, int idx);
  void lua_rawgeti(lua_State *L, int idx, int n);
  void lua_rawset(lua_State *L, int idx);
  void lua_rawseti(lua_State *L, int idx, int n);
  void lua_remove(lua_State *L, int idx);
  void lua_replace(lua_State *L, int idx);
  int lua_resume(lua_State *L, int narg);
  void lua_setallocf(lua_State *L, lua_Alloc f, void *ud);
  int lua_setfenv(lua_State *L, int idx);
  void lua_setfield(lua_State *L, int idx, const char *k);
  int lua_sethook(lua_State *L, lua_Hook func, int mask, int count);
  const char *lua_setlocal(lua_State *L, const lua_Debug *ar, int n);
  int lua_setmetatable(lua_State *L, int objindex);
  void lua_settable(lua_State *L, int idx);
  void lua_settop(lua_State *L, int idx);
  const char *lua_setupvalue(lua_State *L, int funcindex, int n);
  int lua_status(lua_State *L);
  int lua_toboolean(lua_State *L, int idx);
  lua_CFunction lua_tocfunction(lua_State *L, int idx);
  lua_Integer lua_tointeger(lua_State *L, int idx);
  lua_Integer lua_tointegerx(lua_State *L, int idx, int *isnum);
  const char *lua_tolstring(lua_State *L, int idx, size_t *len);
  lua_Number lua_tonumber(lua_State *L, int idx);
  lua_Number lua_tonumberx(lua_State *L, int idx, int *isnum);
  const void *lua_topointer(lua_State *L, int idx);
  lua_State *lua_tothread(lua_State *L, int idx);
  void *lua_touserdata(lua_State *L, int idx);
  int lua_type(lua_State *L, int idx);
  const char *lua_typename(lua_State *L, int tp);
  void *lua_upvalueid(lua_State *L, int funcindex, int n);
  void lua_upvaluejoin(lua_State *L, int funcindex1, int n1, int funcindex2, int n2);
  lua_Number lua_version(lua_State *L);
  void lua_xmove(lua_State *L1, lua_State *L2, int n);
  int lua_yield(lua_State *L, int nresults);

  int lua_lessthan(lua_State *L, int idx1, int idx2);

  int luaopen_base(lua_State *L);
  int luaopen_bit(lua_State *L);
  int luaopen_debug(lua_State *L);
  int luaopen_ffi(lua_State *L);
  int luaopen_io(lua_State *L);
  int luaopen_jit(lua_State *L);
  int luaopen_math(lua_State *L);
  int luaopen_os(lua_State *L);
  int luaopen_package(lua_State *L);
  int luaopen_string(lua_State *L);
  int luaopen_string_buffer(lua_State *L);
  int luaopen_table(lua_State *L);
]]

---@class lua.raw.State: ffi.cdata*

-- Get symbols from lde itself
---@class lua.raw.Fns
---@field lua_atpanic fun(L: lua.raw.State, panicf: fun(L: lua.raw.State): integer): ffi.cdata*
---@field lua_call fun(L: lua.raw.State, nargs: integer, nresults: integer)
---@field lua_checkstack fun(L: lua.raw.State, extra: integer): integer
---@field lua_close fun(L: lua.raw.State)
---@field lua_concat fun(L: lua.raw.State, n: integer)
---@field lua_copy fun(L: lua.raw.State, fromidx: integer, toidx: integer)
---@field lua_cpcall fun(L: lua.raw.State, func: fun(L: lua.raw.State): integer, ud: ffi.cdata*): integer
---@field lua_createtable fun(L: lua.raw.State, narr: integer, nrec: integer)
---@field lua_dump fun(L: lua.raw.State, writer: fun(L: lua.raw.State, p: ffi.cdata*, sz: integer, ud: ffi.cdata*): integer, data: ffi.cdata*): integer
---@field lua_equal fun(L: lua.raw.State, idx1: integer, idx2: integer): integer
---@field lua_error fun(L: lua.raw.State): integer
---@field lua_gc fun(L: lua.raw.State, what: integer, data: integer): integer
---@field lua_getallocf fun(L: lua.raw.State, ud: ffi.cdata*): ffi.cdata*
---@field lua_getfenv fun(L: lua.raw.State, idx: integer): integer
---@field lua_getfield fun(L: lua.raw.State, idx: integer, k: string)
---@field lua_gethook fun(L: lua.raw.State): ffi.cdata*
---@field lua_gethookcount fun(L: lua.raw.State): integer
---@field lua_gethookmask fun(L: lua.raw.State): integer
---@field lua_getinfo fun(L: lua.raw.State, what: string, ar: ffi.cdata*): integer
---@field lua_getlocal fun(L: lua.raw.State, ar: ffi.cdata*, n: integer): string
---@field lua_getmetatable fun(L: lua.raw.State, objindex: integer): integer
---@field lua_getstack fun(L: lua.raw.State, level: integer, ar: ffi.cdata*): integer
---@field lua_gettable fun(L: lua.raw.State, idx: integer)
---@field lua_gettop fun(L: lua.raw.State): integer
---@field lua_getupvalue fun(L: lua.raw.State, funcindex: integer, n: integer): string
---@field lua_insert fun(L: lua.raw.State, idx: integer)
---@field lua_iscfunction fun(L: lua.raw.State, idx: integer): integer
---@field lua_isnumber fun(L: lua.raw.State, idx: integer): integer
---@field lua_isstring fun(L: lua.raw.State, idx: integer): integer
---@field lua_isuserdata fun(L: lua.raw.State, idx: integer): integer
---@field lua_isyieldable fun(L: lua.raw.State): integer
---@field lua_lessthan fun(L: lua.raw.State, idx1: integer, idx2: integer): integer
---@field luaJIT_setmode fun(L: lua.raw.State, idx: integer, mode: integer): integer
---@field luaJIT_profile_start fun(L: lua.raw.State, mode: string, cb: fun(data: ffi.cdata*, L: lua.raw.State, samples: integer, vmstate: integer), data: ffi.cdata*)
---@field luaJIT_profile_stop fun(L: lua.raw.State)
---@field luaJIT_profile_dumpstack fun(L: lua.raw.State, fmt: string, depth: integer, len: ffi.cdata*): ffi.cdata*
---@field luaL_addlstring fun(B: ffi.cdata*, s: string, l: integer)
---@field luaL_addstring fun(B: ffi.cdata*, s: string)
---@field luaL_addvalue fun(B: ffi.cdata*)
---@field luaL_argerror fun(L: lua.raw.State, narg: integer, extramsg: string): integer
---@field luaL_buffinit fun(L: lua.raw.State, B: ffi.cdata*)
---@field luaL_callmeta fun(L: lua.raw.State, obj: integer, e: string): integer
---@field luaL_checkany fun(L: lua.raw.State, narg: integer)
---@field luaL_checkinteger fun(L: lua.raw.State, numArg: integer): integer
---@field luaL_checklstring fun(L: lua.raw.State, numArg: integer, l: ffi.cdata*): string
---@field luaL_checknumber fun(L: lua.raw.State, numArg: integer): number
---@field luaL_checkoption fun(L: lua.raw.State, narg: integer, def: string, lst: ffi.cdata*): integer
---@field luaL_checkstack fun(L: lua.raw.State, sz: integer, msg: string)
---@field luaL_checktype fun(L: lua.raw.State, narg: integer, t: integer)
---@field luaL_checkudata fun(L: lua.raw.State, ud: integer, tname: string): ffi.cdata*
---@field luaL_error fun(L: lua.raw.State, fmt: string, ...): integer
---@field luaL_execresult fun(L: lua.raw.State, stat: integer): integer
---@field luaL_fileresult fun(L: lua.raw.State, stat: integer, fname: string): integer
---@field luaL_findtable fun(L: lua.raw.State, idx: integer, fname: string, szhint: integer): integer
---@field luaL_getmetafield fun(L: lua.raw.State, obj: integer, e: string): integer
---@field luaL_gsub fun(L: lua.raw.State, s: string, p: string, r: string): string
---@field luaL_loadbuffer fun(L: lua.raw.State, buff: string, sz: integer, name: string): integer
---@field luaL_loadbufferx fun(L: lua.raw.State, buff: string, sz: integer, name: string): integer
---@field luaL_loadfile fun(L: lua.raw.State, filename: string): integer
---@field luaL_loadfilex fun(L: lua.raw.State, filename: string, mode: string): integer
---@field luaL_loadstring fun(L: lua.raw.State, s: string): integer
---@field luaL_newmetatable fun(L: lua.raw.State, tname: string): integer
---@field luaL_newstate fun(): lua.raw.State
---@field luaL_openlib fun(L: lua.raw.State, libname: string, l: ffi.cdata*, nup: integer)
---@field luaL_openlibs fun(L: lua.raw.State)
---@field luaL_optinteger fun(L: lua.raw.State, numArg: integer, def: integer): integer
---@field luaL_optlstring fun(L: lua.raw.State, numArg: integer, def: string, l: ffi.cdata*): string
---@field luaL_optnumber fun(L: lua.raw.State, numArg: integer, def: number): number
---@field luaL_prepbuffer fun(B: ffi.cdata*): string
---@field luaL_pushmodule fun(L: lua.raw.State, modname: string, sizehint: integer)
---@field luaL_pushresult fun(B: ffi.cdata*)
---@field luaL_ref fun(L: lua.raw.State, t: integer): integer
---@field luaL_register fun(L: lua.raw.State, libname: string, l: ffi.cdata*)
---@field luaL_setfuncs fun(L: lua.raw.State, l: ffi.cdata*, nup: integer)
---@field luaL_setmetatable fun(L: lua.raw.State, tname: string)
---@field luaL_testudata fun(L: lua.raw.State, ud: integer, tname: string): integer
---@field luaL_traceback fun(L1: lua.raw.State, L2: lua.raw.State, msg: string, level: integer)
---@field luaL_typerror fun(L: lua.raw.State, narg: integer, tname: string): integer
---@field luaL_unref fun(L: lua.raw.State, t: integer, ref: integer)
---@field luaL_where fun(L: lua.raw.State, lvl: integer)
---@field lua_load fun(L: lua.raw.State, reader: fun(L: lua.raw.State, data: ffi.cdata*, sz: ffi.cdata*): string, data: ffi.cdata*, chunkname: string): integer
---@field lua_loadx fun(L: lua.raw.State, reader: fun(L: lua.raw.State, data: ffi.cdata*, sz: ffi.cdata*): string, data: ffi.cdata*, chunkname: string, mode: string): integer
---@field lua_newstate fun(alloc: fun(ud: ffi.cdata*, ptr: ffi.cdata*, osize: integer, nsize: integer): ffi.cdata*, ud: ffi.cdata*): lua.raw.State
---@field lua_newthread fun(L: lua.raw.State): lua.raw.State
---@field lua_newuserdata fun(L: lua.raw.State, sz: integer): ffi.cdata*
---@field lua_next fun(L: lua.raw.State, idx: integer): integer
---@field lua_objlen fun(L: lua.raw.State, idx: integer): integer
---@field lua_pcall fun(L: lua.raw.State, nargs: integer, nresults: integer, errfunc: integer): integer
---@field lua_pushboolean fun(L: lua.raw.State, b: boolean)
---@field lua_pushcclosure fun(L: lua.raw.State, fn: fun(L: lua.raw.State): integer, n: integer)
---@field lua_pushfstring fun(L: lua.raw.State, fmt: string, ...): string
---@field lua_pushinteger fun(L: lua.raw.State, n: integer)
---@field lua_pushlightuserdata fun(L: lua.raw.State, p: ffi.cdata*)
---@field lua_pushlstring fun(L: lua.raw.State, s: string, ls: integer)
---@field lua_pushnil fun(L: lua.raw.State)
---@field lua_pushnumber fun(L: lua.raw.State, n: number)
---@field lua_pushstring fun(L: lua.raw.State, s: string)
---@field lua_pushthread fun(L: lua.raw.State): integer
---@field lua_pushvalue fun(L: lua.raw.State, idx: integer)
---@field lua_pushvfstring fun(L: lua.raw.State, fmt: string, argp: ffi.cdata*): string
---@field lua_rawequal fun(L: lua.raw.State, idx1: integer, idx2: integer): integer
---@field lua_rawget fun(L: lua.raw.State, idx: integer)
---@field lua_rawgeti fun(L: lua.raw.State, idx: integer, n: integer)
---@field lua_rawset fun(L: lua.raw.State, idx: integer)
---@field lua_rawseti fun(L: lua.raw.State, idx: integer, n: integer)
---@field lua_remove fun(L: lua.raw.State, idx: integer)
---@field lua_replace fun(L: lua.raw.State, idx: integer)
---@field lua_resume fun(L: lua.raw.State, narg: integer): integer
---@field lua_setallocf fun(L: lua.raw.State, alloc: fun(ud: ffi.cdata*, ptr: ffi.cdata*, osize: integer, nsize: integer): ffi.cdata*, ud: ffi.cdata*)
---@field lua_setfenv fun(L: lua.raw.State, idx: integer): integer
---@field lua_setfield fun(L: lua.raw.State, idx: integer, k: string)
---@field lua_sethook fun(L: lua.raw.State, func: fun(L: lua.raw.State, ar: ffi.cdata*), mask: integer, count: integer): integer
---@field lua_setlocal fun(L: lua.raw.State, ar: ffi.cdata*, n: integer): string
---@field lua_setmetatable fun(L: lua.raw.State, objindex: integer): integer
---@field lua_settable fun(L: lua.raw.State, idx: integer)
---@field lua_settop fun(L: lua.raw.State, idx: integer)
---@field lua_setupvalue fun(L: lua.raw.State, funcindex: integer, n: integer): string
---@field lua_status fun(L: lua.raw.State): integer
---@field lua_toboolean fun(L: lua.raw.State, idx: integer): boolean
---@field lua_tocfunction fun(L: lua.raw.State, idx: integer): ffi.cdata*
---@field lua_tointeger fun(L: lua.raw.State, idx: integer): integer
---@field lua_tointegerx fun(L: lua.raw.State, idx: integer, isnum: ffi.cdata*): integer
---@field lua_tolstring fun(L: lua.raw.State, idx: integer, len: ffi.cdata*): string
---@field lua_tonumber fun(L: lua.raw.State, idx: integer): number
---@field lua_tonumberx fun(L: lua.raw.State, idx: integer, isnum: ffi.cdata*): number
---@field lua_topointer fun(L: lua.raw.State, idx: integer): ffi.cdata*
---@field lua_tothread fun(L: lua.raw.State, idx: integer): lua.raw.State
---@field lua_touserdata fun(L: lua.raw.State, idx: integer): ffi.cdata*
---@field lua_type fun(L: lua.raw.State, idx: integer): integer
---@field lua_typename fun(L: lua.raw.State, tp: integer): string
---@field lua_upvalueid fun(L: lua.raw.State, funcindex: integer, n: integer): ffi.cdata*
---@field lua_upvaluejoin fun(L: lua.raw.State, funcindex1: integer, n1: integer, funcindex2: integer, n2: integer)
---@field lua_version fun(L: lua.raw.State): number
---@field lua_xmove fun(L1: lua.raw.State, L2: lua.raw.State, n: integer)
---@field lua_yield fun(L: lua.raw.State, nresults: integer): integer
---@field luaopen_base fun(L: lua.raw.State): integer
---@field luaopen_bit fun(L: lua.raw.State): integer
---@field luaopen_debug fun(L: lua.raw.State): integer
---@field luaopen_ffi fun(L: lua.raw.State): integer
---@field luaopen_io fun(L: lua.raw.State): integer
---@field luaopen_jit fun(L: lua.raw.State): integer
---@field luaopen_math fun(L: lua.raw.State): integer
---@field luaopen_os fun(L: lua.raw.State): integer
---@field luaopen_package fun(L: lua.raw.State): integer
---@field luaopen_string fun(L: lua.raw.State): integer
---@field luaopen_string_buffer fun(L: lua.raw.State): integer
---@field luaopen_table fun(L: lua.raw.State): integer
-- On Windows, lua symbols are embedded in bridge.dll (libluajit.a linked in).
-- Load them via ffi.load so ffi.C lookups resolve correctly.
-- On Linux/macOS they come from the host process image via ffi.C.
local C
if ffi.os == "Windows" then
	C = ffi.load("bridge")
else
	C = ffi.C
end

local raw = {}

-- Core API
raw.atpanic = C.lua_atpanic
raw.call = C.lua_call

---@param L lua.raw.State
---@param extra integer
---@return boolean
function raw.checkstack(L, extra) return C.lua_checkstack(L, extra) ~= 0 end

raw.close = C.lua_close
raw.concat = C.lua_concat
raw.copy = C.lua_copy
raw.cpcall = C.lua_cpcall
raw.createtable = C.lua_createtable
raw.dump = C.lua_dump

---@param L lua.raw.State
---@param idx1 integer
---@param idx2 integer
---@return boolean
function raw.equal(L, idx1, idx2) return C.lua_equal(L, idx1, idx2) ~= 0 end

raw.error = C.lua_error
raw.gc = C.lua_gc
raw.getallocf = C.lua_getallocf

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.getfenv(L, idx) return C.lua_getfenv(L, idx) ~= 0 end

raw.getfield = C.lua_getfield

---@param L lua.raw.State
---@param name string
function raw.getglobal(L, name) C.lua_getfield(L, -10002, name) end

raw.gethook = C.lua_gethook
raw.gethookcount = C.lua_gethookcount
raw.gethookmask = C.lua_gethookmask
raw.getinfo = C.lua_getinfo
raw.getlocal = C.lua_getlocal

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.getmetatable(L, idx) return C.lua_getmetatable(L, idx) ~= 0 end

raw.getstack = C.lua_getstack
raw.gettable = C.lua_gettable
raw.gettop = C.lua_gettop
raw.getupvalue = C.lua_getupvalue
raw.insert = C.lua_insert

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.iscfunction(L, idx) return C.lua_iscfunction(L, idx) ~= 0 end

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.isnumber(L, idx) return C.lua_isnumber(L, idx) ~= 0 end

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.isstring(L, idx) return C.lua_isstring(L, idx) ~= 0 end

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.isuserdata(L, idx) return C.lua_isuserdata(L, idx) ~= 0 end

---@param L lua.raw.State
---@return boolean
function raw.isyieldable(L) return C.lua_isyieldable(L) ~= 0 end

---@param L lua.raw.State
---@param idx1 integer
---@param idx2 integer
---@return boolean
function raw.lessthan(L, idx1, idx2) return C.lua_lessthan(L, idx1, idx2) ~= 0 end

raw.load = C.lua_load
raw.loadx = C.lua_loadx
raw.newstate = C.lua_newstate
raw.newthread = C.lua_newthread
raw.newuserdata = C.lua_newuserdata
---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.next(L, idx) return C.lua_next(L, idx) ~= 0 end

raw.objlen = C.lua_objlen
raw.pcall = C.lua_pcall
raw.pushboolean = C.lua_pushboolean
raw.pushcclosure = C.lua_pushcclosure
raw.pushfstring = C.lua_pushfstring
raw.pushinteger = C.lua_pushinteger
raw.pushlightuserdata = C.lua_pushlightuserdata
raw.pushlstring = C.lua_pushlstring
raw.pushnil = C.lua_pushnil
raw.pushnumber = C.lua_pushnumber
raw.pushstring = C.lua_pushstring

---@param L lua.raw.State
---@return boolean
function raw.pushthread(L) return C.lua_pushthread(L) ~= 0 end

raw.pushvalue = C.lua_pushvalue
raw.pushvfstring = C.lua_pushvfstring

---@param L lua.raw.State
---@param idx1 integer
---@param idx2 integer
---@return boolean
function raw.rawequal(L, idx1, idx2) return C.lua_rawequal(L, idx1, idx2) ~= 0 end

raw.rawget = C.lua_rawget
raw.rawgeti = C.lua_rawgeti
raw.rawset = C.lua_rawset
raw.rawseti = C.lua_rawseti
raw.remove = C.lua_remove
raw.replace = C.lua_replace
raw.resume = C.lua_resume
raw.setallocf = C.lua_setallocf

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.setfenv(L, idx) return C.lua_setfenv(L, idx) ~= 0 end

raw.setfield = C.lua_setfield
raw.sethook = C.lua_sethook
raw.setlocal = C.lua_setlocal

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.setmetatable(L, idx) return C.lua_setmetatable(L, idx) ~= 0 end

raw.settable = C.lua_settable
raw.settop = C.lua_settop

---@param L lua.raw.State
---@param n integer
function raw.pop(L, n) raw.settop(L, -(n) - 1) end

raw.setupvalue = C.lua_setupvalue
raw.status = C.lua_status

---@param L lua.raw.State
---@param idx integer
---@return boolean
function raw.toboolean(L, idx) return C.lua_toboolean(L, idx) ~= 0 end

raw.tocfunction = C.lua_tocfunction
raw.tointeger = C.lua_tointeger
raw.tointegerx = C.lua_tointegerx

---@param L lua.raw.State
---@param idx integer
---@return string
function raw.tolstring(L, idx)
	local len = ffi.new("size_t[1]")
	return ffi.string(C.lua_tolstring(L, idx, len), len[0])
end

raw.tonumber = C.lua_tonumber
raw.tonumberx = C.lua_tonumberx
raw.topointer = C.lua_topointer
raw.tothread = C.lua_tothread
raw.touserdata = C.lua_touserdata
raw.type = C.lua_type
raw.typename = C.lua_typename
raw.upvalueid = C.lua_upvalueid
raw.upvaluejoin = C.lua_upvaluejoin
raw.version = C.lua_version
raw.xmove = C.lua_xmove
raw.yield = C.lua_yield

-- Aux library (luaL_*)
raw.addlstring = C.luaL_addlstring
raw.addstring = C.luaL_addstring
raw.addvalue = C.luaL_addvalue
raw.argerror = C.luaL_argerror
raw.buffinit = C.luaL_buffinit

---@param L lua.raw.State
---@param obj integer
---@param e string
---@return boolean
function raw.callmeta(L, obj, e) return C.luaL_callmeta(L, obj, e) ~= 0 end

raw.checkany = C.luaL_checkany
raw.checkinteger = C.luaL_checkinteger

---@param L lua.raw.State
---@param idx integer
---@return string
function raw.checklstring(L, idx)
	local len = ffi.new("size_t[1]")
	return ffi.string(C.luaL_checklstring(L, idx, len), len[0])
end

raw.checknumber = C.luaL_checknumber
raw.checkoption = C.luaL_checkoption
raw.lcheckstack = C.luaL_checkstack
raw.checktype = C.luaL_checktype
raw.checkudata = C.luaL_checkudata
raw.lerror = C.luaL_error
raw.execresult = C.luaL_execresult
raw.fileresult = C.luaL_fileresult
raw.findtable = C.luaL_findtable
raw.getmetafield = C.luaL_getmetafield
raw.gsub = C.luaL_gsub
raw.loadbuffer = C.luaL_loadbuffer
raw.loadbufferx = C.luaL_loadbufferx
raw.loadfile = C.luaL_loadfile
raw.loadfilex = C.luaL_loadfilex
raw.loadstring = C.luaL_loadstring
raw.newmetatable = C.luaL_newmetatable
raw.lnewstate = C.luaL_newstate
raw.openlib = C.luaL_openlib
raw.openlibs = C.luaL_openlibs
raw.optinteger = C.luaL_optinteger
raw.optlstring = C.luaL_optlstring
raw.optnumber = C.luaL_optnumber
raw.prepbuffer = C.luaL_prepbuffer
raw.pushmodule = C.luaL_pushmodule
raw.pushresult = C.luaL_pushresult
raw.ref = C.luaL_ref
raw.register = C.luaL_register
raw.setfuncs = C.luaL_setfuncs
raw.lsetmetatable = C.luaL_setmetatable

---@param L lua.raw.State
---@param ud integer
---@param tname string
---@return boolean
function raw.testudata(L, ud, tname) return C.luaL_testudata(L, ud, tname) ~= 0 end

raw.traceback = C.luaL_traceback
raw.typerror = C.luaL_typerror
raw.unref = C.luaL_unref
raw.where = C.luaL_where

-- Library openers (luaopen_*)
raw.openBase = C.luaopen_base
raw.openBit = C.luaopen_bit
raw.openDebug = C.luaopen_debug
raw.openFFI = C.luaopen_ffi
raw.openIO = C.luaopen_io
raw.openJIT = C.luaopen_jit
raw.openMath = C.luaopen_math
raw.openOS = C.luaopen_os
raw.openPackage = C.luaopen_package
raw.openString = C.luaopen_string
raw.openStringBuffer = C.luaopen_string_buffer
raw.openTable = C.luaopen_table

-- JIT extensions (luaJIT_*)
raw.jit_setmode        = C.luaJIT_setmode
raw.jit_profile_start  = C.luaJIT_profile_start
raw.jit_profile_stop   = C.luaJIT_profile_stop

-- dumpstack returns a const char* into an internal profiler buffer (valid
-- only until the next dumpstack call or profile_stop). Copy to a Lua string
-- immediately. len is an int* out-param.
local _dumpstack_len = ffi.new("int[1]")
---@param L      lua.raw.State
---@param fmt    string
---@param depth  integer
function raw.jit_profile_dumpstack(L, fmt, depth)
	local p = C.luaJIT_profile_dumpstack(L, fmt, depth, _dumpstack_len)
	if p == nil then return "" end
	return ffi.string(p, _dumpstack_len[0])
end

return raw
