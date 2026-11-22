-- abi/lua51.lua — the plain Lua 5.1 C API (and the base of the LuaJIT ABI).
--
-- The 5.1 and LuaJIT images may declare the real C names: no other binding
-- declares `lua_*`, so this is the one cdef table for them, and binding
-- through `ffi.C`/`ffi.load(path)` keeps direct cdata calls (no Lua wrapper).
-- `abi/jit.lua` extends this binding with the LuaJIT symbols and the 5.2
-- backports; the declarations are here so ffi.cdef sees one self-consistent
-- block.

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
		/* Fedora's Lua 5.1 is built with LUA_IDSIZE 512; LuaJIT uses 60.
		 * A larger buffer is safe for both: the loader writes only its own
		 * LUA_IDSIZE bytes and no field after short_src is read. */
		char short_src[512];
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
	int lua_copy(lua_State *L, int fromidx, int toidx);
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
	int lua_lessthan(lua_State *L, int idx1, int idx2);
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

	int luaJIT_setmode(lua_State *L, int idx, int mode);
	void luaJIT_profile_start(lua_State *L, const char *mode, void (*cb)(void *data, lua_State *L, int samples, int vmstate), void *data);
	void luaJIT_profile_stop(lua_State *L);
	const char *luaJIT_profile_dumpstack(lua_State *L, const char *fmt, int depth, size_t *len);

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

local LUA_REGISTRYINDEX = -10000
local LUA_GLOBALSINDEX = -10002

local TYPE_NAMES = {
	[0] = "nil",
	[1] = "boolean",
	[2] = "lightuserdata",
	[3] = "number",
	[4] = "string",
	[5] = "table",
	[6] = "function",
	[7] = "userdata",
	[8] = "thread",
	[10] = "cdata"
}

---@param C ffi.namespace*
---@param name string
local function field(C, name)
	local ok, value = pcall(|| -> C[name])
	if ok then
		return value --[[@as ffi.cdata*?]]
	end
	return nil
end

---@param C ffi.namespace*
---@param name string
---@return ffi.cdata*
local function required(C, name)
	local fn = field(C, name)
	if fn == nil then error("lua-sys: the Lua 5.1 image lacks " .. name, 3) end
	return fn
end

local abi = { name = "5.1" }

---@param img lua.Image
function abi.probe(img)
	return img:symbol("lua_setfenv") ~= nil and img:symbol("lua_objlen") ~= nil and img:symbol("lua_newuserdatauv") == nil
end

---@param img lua.Image
---@return lua.Binding
function abi.bind(img)
	local C = img:clib("lua_gettop")
	local raw = {}
	local length = ffi.new("size_t[1]")

	-- Core API. Boolean-returning functions get the same Lua wrappers the old
	-- raw module had; the rest stay direct cdata calls.
	raw.atpanic = required(C, "lua_atpanic")
	raw.call = required(C, "lua_call")
	local checkstack = required(C, "lua_checkstack")
	raw.close = required(C, "lua_close")
	raw.concat = required(C, "lua_concat")
	raw.cpcall = required(C, "lua_cpcall")
	raw.createtable = required(C, "lua_createtable")
	raw.dump = required(C, "lua_dump")
	local equal = required(C, "lua_equal")
	raw.error = required(C, "lua_error")
	raw.gc = required(C, "lua_gc")
	raw.getallocf = required(C, "lua_getallocf")
	local getfenv_c = required(C, "lua_getfenv")
	raw.getfield = required(C, "lua_getfield")
	raw.gethook = required(C, "lua_gethook")
	raw.gethookcount = required(C, "lua_gethookcount")
	raw.gethookmask = required(C, "lua_gethookmask")
	raw.getinfo = required(C, "lua_getinfo")
	raw.getlocal = required(C, "lua_getlocal")
	local getmetatable_c = required(C, "lua_getmetatable")
	raw.getstack = required(C, "lua_getstack")
	raw.gettable = required(C, "lua_gettable")
	raw.gettop = required(C, "lua_gettop")
	raw.getupvalue = required(C, "lua_getupvalue")
	raw.insert = required(C, "lua_insert")
	local iscfunction = required(C, "lua_iscfunction")
	local isnumber = required(C, "lua_isnumber")
	local isstring = required(C, "lua_isstring")
	local isuserdata = required(C, "lua_isuserdata")
	local lessthan = required(C, "lua_lessthan")
	raw.load = required(C, "lua_load")
	raw.newstate = required(C, "lua_newstate")
	raw.newthread = required(C, "lua_newthread")
	raw.newuserdata = required(C, "lua_newuserdata")
	local next_c = required(C, "lua_next")
	raw.objlen = required(C, "lua_objlen")
	raw.pcall = required(C, "lua_pcall")
	local pushboolean = required(C, "lua_pushboolean")
	raw.pushcclosure = required(C, "lua_pushcclosure")
	raw.pushfstring = required(C, "lua_pushfstring")
	raw.pushinteger = required(C, "lua_pushinteger")
	raw.pushlightuserdata = required(C, "lua_pushlightuserdata")
	raw.pushlstring = required(C, "lua_pushlstring")
	raw.pushnil = required(C, "lua_pushnil")
	raw.pushnumber = required(C, "lua_pushnumber")
	raw.pushstring = required(C, "lua_pushstring")
	local pushthread = required(C, "lua_pushthread")
	raw.pushvalue = required(C, "lua_pushvalue")
	raw.pushvfstring = required(C, "lua_pushvfstring")
	local rawequal = required(C, "lua_rawequal")
	raw.rawget = required(C, "lua_rawget")
	raw.rawgeti = required(C, "lua_rawgeti")
	raw.rawset = required(C, "lua_rawset")
	raw.rawseti = required(C, "lua_rawseti")
	raw.remove = required(C, "lua_remove")
	raw.replace = required(C, "lua_replace")
	raw.resume = required(C, "lua_resume")
	raw.setallocf = required(C, "lua_setallocf")
	local setfenv_c = required(C, "lua_setfenv")
	raw.setfield = required(C, "lua_setfield")
	raw.sethook = required(C, "lua_sethook")
	raw.setlocal = required(C, "lua_setlocal")
	local setmetatable_c = required(C, "lua_setmetatable")
	raw.settable = required(C, "lua_settable")
	raw.settop = required(C, "lua_settop")
	raw.setupvalue = required(C, "lua_setupvalue")
	raw.status = required(C, "lua_status")
	local toboolean = required(C, "lua_toboolean")
	raw.tocfunction = required(C, "lua_tocfunction")
	raw.tointeger = required(C, "lua_tointeger")
	raw.tonumber = required(C, "lua_tonumber")
	raw.topointer = required(C, "lua_topointer")
	raw.tothread = required(C, "lua_tothread")
	raw.touserdata = required(C, "lua_touserdata")
	raw.type = required(C, "lua_type")
	raw.typename = required(C, "lua_typename")
	-- Lua 5.1 never exports lua_version (it is a macro); LuaJIT does.
	raw.version = field(C, "lua_version")
	raw.xmove = required(C, "lua_xmove")
	raw.yield = required(C, "lua_yield")

	local tolstring_c = required(C, "lua_tolstring")

	-- Aux library (luaL_*)
	raw.addlstring = required(C, "luaL_addlstring")
	raw.addstring = required(C, "luaL_addstring")
	raw.addvalue = required(C, "luaL_addvalue")
	raw.argerror = required(C, "luaL_argerror")
	raw.buffinit = required(C, "luaL_buffinit")
	local callmeta = required(C, "luaL_callmeta")
	raw.checkany = required(C, "luaL_checkany")
	raw.checkinteger = required(C, "luaL_checkinteger")
	local checklstring_c = required(C, "luaL_checklstring")
	raw.checknumber = required(C, "luaL_checknumber")
	raw.checkoption = required(C, "luaL_checkoption")
	raw.lcheckstack = required(C, "luaL_checkstack")
	raw.checktype = required(C, "luaL_checktype")
	raw.checkudata = required(C, "luaL_checkudata")
	raw.lerror = required(C, "luaL_error")
	-- Lua 5.1 lacks these (it has luaL_fileresult? no: both arrived in 5.2).
	raw.execresult = field(C, "luaL_execresult")
	raw.fileresult = field(C, "luaL_fileresult")
	raw.findtable = required(C, "luaL_findtable")
	raw.getmetafield = required(C, "luaL_getmetafield")
	raw.gsub = required(C, "luaL_gsub")
	raw.loadbuffer = required(C, "luaL_loadbuffer")
	raw.loadfile = required(C, "luaL_loadfile")
	raw.loadstring = required(C, "luaL_loadstring")
	raw.newmetatable = required(C, "luaL_newmetatable")
	raw.lnewstate = required(C, "luaL_newstate")
	raw.openlib = required(C, "luaL_openlib")
	raw.openlibs = required(C, "luaL_openlibs")
	raw.optinteger = required(C, "luaL_optinteger")
	raw.optlstring = required(C, "luaL_optlstring")
	raw.optnumber = required(C, "luaL_optnumber")
	raw.prepbuffer = required(C, "luaL_prepbuffer")
	raw.pushmodule = field(C, "luaL_pushmodule")
	raw.pushresult = required(C, "luaL_pushresult")
	raw.ref = required(C, "luaL_ref")
	raw.register = required(C, "luaL_register")
	raw.typerror = required(C, "luaL_typerror")
	raw.unref = required(C, "luaL_unref")
	raw.where = required(C, "luaL_where")

	-- Library openers (luaopen_*)
	raw.openBase = required(C, "luaopen_base")
	raw.openDebug = required(C, "luaopen_debug")
	raw.openIO = required(C, "luaopen_io")
	raw.openMath = required(C, "luaopen_math")
	raw.openOS = required(C, "luaopen_os")
	raw.openPackage = required(C, "luaopen_package")
	raw.openString = required(C, "luaopen_string")
	raw.openTable = required(C, "luaopen_table")

	-- Lua-visible wrappers with the same semantics as the old raw module.
	---@param L lua.raw.State
	---@param extra integer
	---@return boolean
	function raw.checkstack(L, extra) return checkstack(L, extra) ~= 0 end

	---@param L lua.raw.State
	---@param idx1 integer
	---@param idx2 integer
	---@return boolean
	function raw.equal(L, idx1, idx2) return equal(L, idx1, idx2) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.getfenv(L, idx) return getfenv_c(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.getmetatable(L, idx) return getmetatable_c(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.iscfunction(L, idx) return iscfunction(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.isnumber(L, idx) return isnumber(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.isstring(L, idx) return isstring(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.isuserdata(L, idx) return isuserdata(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx1 integer
	---@param idx2 integer
	---@return boolean
	function raw.lessthan(L, idx1, idx2) return lessthan(L, idx1, idx2) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.next(L, idx) return next_c(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param b boolean
	function raw.pushboolean(L, b) pushboolean(L, b and 1 or 0) end

	---@param L lua.raw.State
	---@return boolean
	function raw.pushthread(L) return pushthread(L) ~= 0 end

	---@param L lua.raw.State
	---@param idx1 integer
	---@param idx2 integer
	---@return boolean
	function raw.rawequal(L, idx1, idx2) return rawequal(L, idx1, idx2) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.setfenv(L, idx) return setfenv_c(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.setmetatable(L, idx) return setmetatable_c(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param idx integer
	---@return boolean
	function raw.toboolean(L, idx) return toboolean(L, idx) ~= 0 end

	---@param L lua.raw.State
	---@param obj integer
	---@param e string
	---@return boolean
	function raw.callmeta(L, obj, e) return callmeta(L, obj, e) ~= 0 end

	---@param L lua.raw.State
	---@param name string
	function raw.getglobal(L, name) raw.getfield(L, LUA_GLOBALSINDEX, name) end

	---@param L lua.raw.State
	---@param n integer
	function raw.pop(L, n) raw.settop(L, -n - 1) end

	---@param L lua.raw.State
	---@param idx integer
	---@return string
	function raw.tolstring(L, idx)
		return ffi.string(tolstring_c(L, idx, length), length[0])
	end

	---@param L lua.raw.State
	---@param idx integer
	---@return string
	function raw.checklstring(L, idx)
		return ffi.string(checklstring_c(L, idx, length), length[0])
	end

	---@param code string
	---@return boolean
	local function isBytecode(code)
		if type(code) ~= "string" then return false end
		return code:byte(1) == 27
	end

	local ar = ffi.new("lua_Debug")

	---@type lua.Caps
	local caps = { jit = false, hooks = "full", env = "fenv", integers = false, source = true }

	---@type lua.Binding
	local binding = {
		name = "5.1",
		raw = raw,
		REGISTRYINDEX = LUA_REGISTRYINDEX,
		typeNames = TYPE_NAMES,
		caps = caps,
		_clib = C
	}

	---@param L lua.raw.State
	---@param n number
	function binding.pushNumber(L, n) raw.pushnumber(L, n) end

	---@param L lua.raw.State
	---@param idx integer
	---@return number
	function binding.toNumber(L, idx) return raw.tonumber(L, idx) end

	---@param L lua.raw.State
	function binding.pushGlobals(L) raw.pushvalue(L, LUA_GLOBALSINDEX) end

	---@param L lua.raw.State
	---@param code string
	---@param chunkName string?
	---@param _ "t"|"b"|"bt"|nil
	---@return integer
	function binding.load(L, code, chunkName, _)
		return raw.loadbuffer(L, code, #code, chunkName or code)
	end

	binding.isBytecode = isBytecode

	---@param L lua.raw.State
	---@param level integer
	---@param n integer
	---@return string?
	function binding.getlocal(L, level, n)
		if raw.getstack(L, level, ar) == 0 then return nil end
		local name = raw.getlocal(L, ar, n)
		if name == nil then return nil end
		return ffi.string(ffi.cast("const char *", name))
	end

	---@param L lua.raw.State
	---@param level integer
	---@param n integer
	---@return string?
	function binding.setlocal(L, level, n)
		if raw.getstack(L, level, ar) == 0 then
			raw.pop(L, 1)
			return nil
		end
		local name = raw.setlocal(L, ar, n)
		if name == nil then return nil end
		return ffi.string(ffi.cast("const char *", name))
	end

	---@param L lua.raw.State
	---@param level integer
	---@return boolean
	function binding.pushFrameFunction(L, level)
		if raw.getstack(L, level, ar) == 0 then return false end
		return raw.getinfo(L, "f", ar) ~= 0
	end

	---@param L lua.raw.State
	---@param fnIndex integer
	function binding.getFunctionEnv(L, fnIndex)
		if not raw.getfenv(L, fnIndex) then binding.pushGlobals(L) end
	end

	---@param L lua.raw.State
	---@param chunkIndex integer
	function binding.setChunkEnv(L, chunkIndex)
		raw.setfenv(L, chunkIndex)
	end

	return binding
end

return abi
