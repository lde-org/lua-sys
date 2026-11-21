local ffi = require("ffi")

ffi.cdef[[
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
  int luaL_loadbufferx(lua_State *L, const char *buff, size_t sz, const char *name, const char *mode);
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

local C = ffi.C

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

---@param L lua.raw.State
---@param b boolean
function raw.pushboolean(L, b) C.lua_pushboolean(L, b and 1 or 0) end

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
raw.jit_setmode = C.luaJIT_setmode

-- The profiler callback runs from the interpreter on the main thread on all
-- platforms; the OS timer (SIGPROF on POSIX, a timer thread on Windows) only
-- arms the sampling hook. lua-sys.profiler uses these directly everywhere.
raw.jit_profile_start = C.luaJIT_profile_start
raw.jit_profile_stop = C.luaJIT_profile_stop

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
