-- abi/lua54.lua — the Lua 5.4 C API.
--
-- The real `lua_*` names are already declared by abi/lua51.lua, and a second
-- declaration would clash. Everything here is prefixed (`lua54_*`), declarations
-- are function-pointer typedefs, and the addresses come from the image's own
-- symbol table.

local ffi = require("ffi")

ffi.cdef[[
	typedef struct lua54_State lua54_State;
	typedef double lua54_Number;
	typedef long long lua54_Integer;
	typedef ptrdiff_t lua54_KContext;
	typedef int (*lua54_CFunction)(lua54_State *L);
	typedef const char *(*lua54_Reader)(lua54_State *L, void *data, size_t *size);
	typedef int (*lua54_Writer)(lua54_State *L, const void *p, size_t sz, void *ud);
	typedef void *(*lua54_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);

	typedef struct {
		int event;
		const char *name;
		const char *namewhat;
		const char *what;
		const char *source;
		size_t srclen;
		int currentline;
		int linedefined;
		int lastlinedefined;
		unsigned char nups;
		unsigned char nparams;
		char isvararg;
		char istailcall;
		unsigned short ftransfer;
		unsigned short ntransfer;
		char short_src[512];
		void *i_ci;
	} lua54_Debug;

	typedef void (*lua54_Hook)(lua54_State *L, lua54_Debug *ar);

	typedef struct {
		char *b;
		size_t size;
		size_t n;
		lua54_State *L;
		union { long double align; char b[512]; } init;
	} lua54_Buffer;

	typedef void *(*lua54_atpanic_t)(lua54_State *L, lua54_CFunction panicf);
	typedef void (*lua54_callk_t)(lua54_State *L, int nargs, int nresults, lua54_KContext ctx, void *k);
	typedef int (*lua54_checkstack_t)(lua54_State *L, int extra);
	typedef void (*lua54_close_t)(lua54_State *L);
	typedef void (*lua54_concat_t)(lua54_State *L, int n);
	typedef void (*lua54_copy_t)(lua54_State *L, int fromidx, int toidx);
	typedef void (*lua54_createtable_t)(lua54_State *L, int narr, int nrec);
	typedef int (*lua54_dump_t)(lua54_State *L, lua54_Writer writer, void *data, int strip);
	typedef int (*lua54_error_t)(lua54_State *L);
	typedef int (*lua54_gc_t)(lua54_State *L, int what, int data);
	typedef lua54_Alloc (*lua54_getallocf_t)(lua54_State *L, void **ud);
	typedef int (*lua54_getfield_t)(lua54_State *L, int idx, const char *k);
	typedef int (*lua54_getglobal_t)(lua54_State *L, const char *name);
	typedef lua54_Hook (*lua54_gethook_t)(lua54_State *L);
	typedef int (*lua54_gethookcount_t)(lua54_State *L);
	typedef int (*lua54_gethookmask_t)(lua54_State *L);
	typedef int (*lua54_getinfo_t)(lua54_State *L, const char *what, lua54_Debug *ar);
	typedef const char *(*lua54_getlocal_t)(lua54_State *L, const lua54_Debug *ar, int n);
	typedef int (*lua54_getmetatable_t)(lua54_State *L, int objindex);
	typedef int (*lua54_getstack_t)(lua54_State *L, int level, lua54_Debug *ar);
	typedef int (*lua54_gettable_t)(lua54_State *L, int idx);
	typedef int (*lua54_gettop_t)(lua54_State *L);
	typedef const char *(*lua54_getupvalue_t)(lua54_State *L, int funcindex, int n);
	typedef int (*lua54_geti_t)(lua54_State *L, int idx, lua54_Integer n);
	typedef int (*lua54_seti_t)(lua54_State *L, int idx, lua54_Integer n);
	typedef int (*lua54_getiuservalue_t)(lua54_State *L, int idx, int n);
	typedef int (*lua54_setiuservalue_t)(lua54_State *L, int idx, int n);
	typedef void (*lua54_insert_t)(lua54_State *L, int idx);
	typedef int (*lua54_iscfunction_t)(lua54_State *L, int idx);
	typedef int (*lua54_isinteger_t)(lua54_State *L, int idx);
	typedef int (*lua54_isnumber_t)(lua54_State *L, int idx);
	typedef int (*lua54_isstring_t)(lua54_State *L, int idx);
	typedef int (*lua54_isuserdata_t)(lua54_State *L, int idx);
	typedef int (*lua54_isyieldable_t)(lua54_State *L);
	typedef int (*lua54_load_t)(lua54_State *L, lua54_Reader reader, void *data, const char *chunkname, const char *mode);
	typedef lua54_State *(*lua54_newstate_t)(lua54_Alloc f, void *ud);
	typedef lua54_State *(*lua54_newthread_t)(lua54_State *L);
	typedef void *(*lua54_newuserdatauv_t)(lua54_State *L, size_t sz, int nuvalue);
	typedef int (*lua54_next_t)(lua54_State *L, int idx);
	typedef size_t (*lua54_rawlen_t)(lua54_State *L, int idx);
	typedef int (*lua54_pcallk_t)(lua54_State *L, int nargs, int nresults, int errfunc, lua54_KContext ctx, void *k);
	typedef void (*lua54_pushboolean_t)(lua54_State *L, int b);
	typedef void (*lua54_pushcclosure_t)(lua54_State *L, lua54_CFunction fn, int n);
	typedef const char *(*lua54_pushfstring_t)(lua54_State *L, const char *fmt, ...);
	typedef void (*lua54_pushinteger_t)(lua54_State *L, lua54_Integer n);
	typedef void (*lua54_pushlightuserdata_t)(lua54_State *L, void *p);
	typedef void (*lua54_pushlstring_t)(lua54_State *L, const char *s, size_t len);
	typedef void (*lua54_pushnil_t)(lua54_State *L);
	typedef void (*lua54_pushnumber_t)(lua54_State *L, lua54_Number n);
	typedef const char *(*lua54_pushstring_t)(lua54_State *L, const char *s);
	typedef int (*lua54_pushthread_t)(lua54_State *L);
	typedef void (*lua54_pushvalue_t)(lua54_State *L, int idx);
	typedef const char *(*lua54_pushvfstring_t)(lua54_State *L, const char *fmt, void *argp);
	typedef int (*lua54_rawequal_t)(lua54_State *L, int idx1, int idx2);
	typedef int (*lua54_rawget_t)(lua54_State *L, int idx);
	typedef int (*lua54_rawgeti_t)(lua54_State *L, int idx, lua54_Integer n);
	typedef int (*lua54_rawgetp_t)(lua54_State *L, int idx, const void *p);
	typedef void (*lua54_rawset_t)(lua54_State *L, int idx);
	typedef void (*lua54_rawseti_t)(lua54_State *L, int idx, lua54_Integer n);
	typedef void (*lua54_rawsetp_t)(lua54_State *L, int idx, const void *p);
	typedef void (*lua54_rotate_t)(lua54_State *L, int idx, int n);
	typedef void (*lua54_setallocf_t)(lua54_State *L, lua54_Alloc f, void *ud);
	typedef void (*lua54_setfield_t)(lua54_State *L, int idx, const char *k);
	typedef void (*lua54_setglobal_t)(lua54_State *L, const char *name);
	typedef void (*lua54_sethook_t)(lua54_State *L, lua54_Hook func, int mask, int count);
	typedef const char *(*lua54_setlocal_t)(lua54_State *L, const lua54_Debug *ar, int n);
	typedef int (*lua54_setmetatable_t)(lua54_State *L, int objindex);
	typedef void (*lua54_settable_t)(lua54_State *L, int idx);
	typedef void (*lua54_settop_t)(lua54_State *L, int idx);
	typedef const char *(*lua54_setupvalue_t)(lua54_State *L, int funcindex, int n);
	typedef int (*lua54_status_t)(lua54_State *L);
	typedef int (*lua54_toboolean_t)(lua54_State *L, int idx);
	typedef lua54_CFunction (*lua54_tocfunction_t)(lua54_State *L, int idx);
	typedef lua54_Integer (*lua54_tointegerx_t)(lua54_State *L, int idx, int *isnum);
	typedef const char *(*lua54_tolstring_t)(lua54_State *L, int idx, size_t *len);
	typedef lua54_Number (*lua54_tonumberx_t)(lua54_State *L, int idx, int *isnum);
	typedef const void *(*lua54_topointer_t)(lua54_State *L, int idx);
	typedef lua54_State *(*lua54_tothread_t)(lua54_State *L, int idx);
	typedef void *(*lua54_touserdata_t)(lua54_State *L, int idx);
	typedef int (*lua54_type_t)(lua54_State *L, int idx);
	typedef const char *(*lua54_typename_t)(lua54_State *L, int tp);
	typedef int (*lua54_compare_t)(lua54_State *L, int idx1, int idx2, int op);
	typedef int (*lua54_stringtonumber_t)(lua54_State *L, const char *s);
	typedef int (*lua54_absindex_t)(lua54_State *L, int idx);
	typedef void *(*lua54_upvalueid_t)(lua54_State *L, int funcindex, int n);
	typedef void (*lua54_upvaluejoin_t)(lua54_State *L, int f1, int n1, int f2, int n2);
	typedef lua54_Number (*lua54_version_t)(lua54_State *L);
	typedef void (*lua54_xmove_t)(lua54_State *from, lua54_State *to, int n);
	typedef int (*lua54_yieldk_t)(lua54_State *L, int nresults, lua54_KContext ctx, void *k);
	typedef int (*lua54_resume_t)(lua54_State *L, lua54_State *from, int narg, int *nres);

	typedef void (*lua54_addlstring_t)(lua54_Buffer *B, const char *s, size_t l);
	typedef void (*lua54_addstring_t)(lua54_Buffer *B, const char *s);
	typedef void (*lua54_addvalue_t)(lua54_Buffer *B);
	typedef int (*lua54_argerror_t)(lua54_State *L, int narg, const char *extramsg);
	typedef void (*lua54_buffinit_t)(lua54_State *L, lua54_Buffer *B);
	typedef int (*lua54_callmeta_t)(lua54_State *L, int obj, const char *e);
	typedef void (*lua54_checkany_t)(lua54_State *L, int narg);
	typedef lua54_Integer (*lua54_checkinteger_t)(lua54_State *L, int numArg);
	typedef const char *(*lua54_checklstring_t)(lua54_State *L, int numArg, size_t *l);
	typedef lua54_Number (*lua54_checknumber_t)(lua54_State *L, int numArg);
	typedef int (*lua54_checkoption_t)(lua54_State *L, int narg, const char *def, const char *const *lst);
	typedef void (*lua54_l_checkstack_t)(lua54_State *L, int sz, const char *msg);
	typedef void (*lua54_checktype_t)(lua54_State *L, int narg, int t);
	typedef void *(*lua54_checkudata_t)(lua54_State *L, int ud, const char *tname);
	typedef int (*lua54_lerror_t)(lua54_State *L, const char *fmt, ...);
	typedef int (*lua54_execresult_t)(lua54_State *L, int stat);
	typedef int (*lua54_fileresult_t)(lua54_State *L, int stat, const char *fname);
	typedef int (*lua54_getmetafield_t)(lua54_State *L, int obj, const char *e);
	typedef const char *(*lua54_gsub_t)(lua54_State *L, const char *s, const char *p, const char *r);
	typedef int (*lua54_loadbufferx_t)(lua54_State *L, const char *buff, size_t sz, const char *name, const char *mode);
	typedef int (*lua54_loadfilex_t)(lua54_State *L, const char *filename, const char *mode);
	typedef int (*lua54_loadstring_t)(lua54_State *L, const char *s);
	typedef int (*lua54_newmetatable_t)(lua54_State *L, const char *tname);
	typedef lua54_State *(*lua54_l_newstate_t)(void);
	typedef void (*lua54_openlibs_t)(lua54_State *L);
	typedef lua54_Integer (*lua54_optinteger_t)(lua54_State *L, int numArg, lua54_Integer def);
	typedef const char *(*lua54_optlstring_t)(lua54_State *L, int numArg, const char *def, size_t *l);
	typedef lua54_Number (*lua54_optnumber_t)(lua54_State *L, int numArg, lua54_Number def);
	typedef char *(*lua54_prepbuffsize_t)(lua54_Buffer *B, size_t size);
	typedef void (*lua54_pushresult_t)(lua54_Buffer *B);
	typedef int (*lua54_ref_t)(lua54_State *L, int t);
	typedef void (*lua54_setfuncs_t)(lua54_State *L, const void *l, int nup);
	typedef void (*lua54_setmetatable_l_t)(lua54_State *L, const char *tname);
	typedef int (*lua54_testudata_t)(lua54_State *L, int ud, const char *tname);
	typedef void (*lua54_traceback_t)(lua54_State *L1, lua54_State *L2, const char *msg, int level);
	typedef void (*lua54_unref_t)(lua54_State *L, int t, int ref);
	typedef void (*lua54_where_t)(lua54_State *L, int lvl);

	typedef int (*lua54_open_t)(lua54_State *L);
]]

local LUA_REGISTRYINDEX = -1001000
local LUA_RIDX_GLOBALS = 2
local LUA_OPEQ = 0
local LUA_OPLT = 1
local LUA_MININTEGER = -0x8000000000000000
local LUA_MAXINTEGER_EXCLUSIVE = 0x8000000000000000

---@class lua54_State: ffi.cdata*
---@class lua54_Debug: ffi.cdata*
---@class lua54_Buffer: ffi.cdata*

local TYPE_NAMES = {
	[0] = "nil",
	[1] = "boolean",
	[2] = "lightuserdata",
	[3] = "number",
	[4] = "string",
	[5] = "table",
	[6] = "function",
	[7] = "userdata",
	[8] = "thread"
}

local abi = { name = "5.4" }

---@param img lua.Image
function abi.probe(img)
	return img:symbol("lua_newuserdatauv") ~= nil
end

---@param img lua.Image
---@return lua.Binding
function abi.bind(img)
	---@param symbol string
	---@return ffi.cdata*
	local function sym(symbol)
		return assert(
			img:symbol(symbol),
			"lua-sys: the Lua 5.4 image at " .. (img.path or "<unnamed>") .. " lacks " .. symbol
		)
	end

	---@param symbol string
	---@param typedef string
	local function fn(symbol, typedef)
		return ffi.cast(typedef, sym(symbol))
	end

	local raw = {}

	local callk = fn("lua_callk", "lua54_callk_t")
	local pcallk = fn("lua_pcallk", "lua54_pcallk_t")
	local compare = fn("lua_compare", "lua54_compare_t")
	local rotate = fn("lua_rotate", "lua54_rotate_t")
	local copy = fn("lua_copy", "lua54_copy_t")
	local gettop = fn("lua_gettop", "lua54_gettop_t")
	local settop = fn("lua_settop", "lua54_settop_t")
	local tointegerx = fn("lua_tointegerx", "lua54_tointegerx_t")
	local tonumberx = fn("lua_tonumberx", "lua54_tonumberx_t")
	local tolstring_c = fn("lua_tolstring", "lua54_tolstring_t")
	local checklstring_c = fn("luaL_checklstring", "lua54_checklstring_t")
	local getstack = fn("lua_getstack", "lua54_getstack_t")
	local getinfo = fn("lua_getinfo", "lua54_getinfo_t")
	local getlocal_c = fn("lua_getlocal", "lua54_getlocal_t")
	local setlocal_c = fn("lua_setlocal", "lua54_setlocal_t")
	local getupvalue = fn("lua_getupvalue", "lua54_getupvalue_t")
	local setupvalue = fn("lua_setupvalue", "lua54_setupvalue_t")

	raw.atpanic = fn("lua_atpanic", "lua54_atpanic_t")
	raw.call = function(L, nargs, nresults) callk(L, nargs, nresults, 0, nil) end
	local checkstack = fn("lua_checkstack", "lua54_checkstack_t")
	raw.checkstack = |L, extra| -> checkstack(L, extra) ~= 0
	raw.close = fn("lua_close", "lua54_close_t")
	raw.concat = fn("lua_concat", "lua54_concat_t")
	raw.copy = copy
	raw.createtable = fn("lua_createtable", "lua54_createtable_t")

	local dump = fn("lua_dump", "lua54_dump_t")
	raw.dump = |L, writer, data| -> dump(L, writer, data, 0)

	raw.equal = |L, idx1, idx2| -> compare(L, idx1, idx2, LUA_OPEQ) ~= 0
	raw.error = fn("lua_error", "lua54_error_t")
	raw.gc = fn("lua_gc", "lua54_gc_t")
	raw.getallocf = fn("lua_getallocf", "lua54_getallocf_t")
	raw.getfield = fn("lua_getfield", "lua54_getfield_t")
	raw.getglobal = fn("lua_getglobal", "lua54_getglobal_t")
	raw.gethook = fn("lua_gethook", "lua54_gethook_t")
	raw.gethookcount = fn("lua_gethookcount", "lua54_gethookcount_t")
	raw.gethookmask = fn("lua_gethookmask", "lua54_gethookmask_t")
	raw.getinfo = getinfo
	raw.getlocal = getlocal_c
	local getmetatable_c = fn("lua_getmetatable", "lua54_getmetatable_t")
	raw.getmetatable = |L, idx| -> getmetatable_c(L, idx) ~= 0
	raw.getstack = getstack
	raw.gettable = fn("lua_gettable", "lua54_gettable_t")
	raw.gettop = gettop
	raw.getupvalue = getupvalue
	raw.insert = function(L, idx) rotate(L, idx, 1) end
	local iscfunction = fn("lua_iscfunction", "lua54_iscfunction_t")
	raw.iscfunction = |L, idx| -> iscfunction(L, idx) ~= 0
	local isinteger = fn("lua_isinteger", "lua54_isinteger_t")
	raw.isinteger = |L, idx| -> isinteger(L, idx) ~= 0
	local isnumber = fn("lua_isnumber", "lua54_isnumber_t")
	raw.isnumber = |L, idx| -> isnumber(L, idx) ~= 0
	local isstring = fn("lua_isstring", "lua54_isstring_t")
	raw.isstring = |L, idx| -> isstring(L, idx) ~= 0
	local isuserdata = fn("lua_isuserdata", "lua54_isuserdata_t")
	raw.isuserdata = |L, idx| -> isuserdata(L, idx) ~= 0
	local isyieldable = fn("lua_isyieldable", "lua54_isyieldable_t")
	raw.isyieldable = L -> isyieldable(L) ~= 0

	local load_c = fn("lua_load", "lua54_load_t")
	raw.load = |L, reader, data, chunkname| -> load_c(L, reader, data, chunkname, nil)
	raw.loadx = load_c

	raw.lessthan = |L, idx1, idx2| -> compare(L, idx1, idx2, LUA_OPLT) ~= 0
	raw.newstate = fn("lua_newstate", "lua54_newstate_t")
	raw.newthread = fn("lua_newthread", "lua54_newthread_t")
	local newuserdatauv = fn("lua_newuserdatauv", "lua54_newuserdatauv_t")
	raw.newuserdata = |L, sz| -> newuserdatauv(L, sz, 1)
	raw.newuserdatauv = newuserdatauv
	local next_c = fn("lua_next", "lua54_next_t")
	raw.next = |L, idx| -> next_c(L, idx) ~= 0
	raw.objlen = fn("lua_rawlen", "lua54_rawlen_t")
	raw.rawlen = raw.objlen
	raw.pcall = |L, nargs, nresults, errfunc| -> pcallk(L, nargs, nresults, errfunc, 0, nil)
	local pushboolean = fn("lua_pushboolean", "lua54_pushboolean_t")
	raw.pushboolean = function(L, b) pushboolean(L, b and 1 or 0) end
	raw.pushcclosure = fn("lua_pushcclosure", "lua54_pushcclosure_t")
	raw.pushfstring = fn("lua_pushfstring", "lua54_pushfstring_t")
	raw.pushinteger = fn("lua_pushinteger", "lua54_pushinteger_t")
	raw.pushlightuserdata = fn("lua_pushlightuserdata", "lua54_pushlightuserdata_t")
	raw.pushlstring = fn("lua_pushlstring", "lua54_pushlstring_t")
	raw.pushnil = fn("lua_pushnil", "lua54_pushnil_t")
	raw.pushnumber = fn("lua_pushnumber", "lua54_pushnumber_t")
	raw.pushstring = fn("lua_pushstring", "lua54_pushstring_t")
	local pushthread = fn("lua_pushthread", "lua54_pushthread_t")
	raw.pushthread = L -> pushthread(L) ~= 0
	raw.pushvalue = fn("lua_pushvalue", "lua54_pushvalue_t")
	raw.pushvfstring = fn("lua_pushvfstring", "lua54_pushvfstring_t")
	local rawequal = fn("lua_rawequal", "lua54_rawequal_t")
	raw.rawequal = |L, idx1, idx2| -> rawequal(L, idx1, idx2) ~= 0
	raw.rawget = fn("lua_rawget", "lua54_rawget_t")
	raw.rawgeti = fn("lua_rawgeti", "lua54_rawgeti_t")
	raw.rawgetp = fn("lua_rawgetp", "lua54_rawgetp_t")
	raw.rawset = fn("lua_rawset", "lua54_rawset_t")
	raw.rawseti = fn("lua_rawseti", "lua54_rawseti_t")
	raw.rawsetp = fn("lua_rawsetp", "lua54_rawsetp_t")
	raw.rotate = rotate
	raw.remove = function(L, idx)
		rotate(L, idx, -1)
		settop(L, -2)
	end
	raw.replace = function(L, idx)
		copy(L, -1, idx)
		settop(L, -2)
	end
	local resume = fn("lua_resume", "lua54_resume_t")
	raw.resume = |L, narg| -> resume(L, nil, narg, nil)
	raw.setallocf = fn("lua_setallocf", "lua54_setallocf_t")
	raw.setfield = fn("lua_setfield", "lua54_setfield_t")
	raw.setglobal = fn("lua_setglobal", "lua54_setglobal_t")
	raw.sethook = fn("lua_sethook", "lua54_sethook_t")
	raw.setlocal = setlocal_c
	local setmetatable_c = fn("lua_setmetatable", "lua54_setmetatable_t")
	raw.setmetatable = |L, idx| -> setmetatable_c(L, idx) ~= 0
	raw.settable = fn("lua_settable", "lua54_settable_t")
	raw.settop = settop
	raw.setupvalue = setupvalue
	raw.status = fn("lua_status", "lua54_status_t")
	local toboolean = fn("lua_toboolean", "lua54_toboolean_t")
	raw.toboolean = |L, idx| -> toboolean(L, idx) ~= 0
	raw.tocfunction = fn("lua_tocfunction", "lua54_tocfunction_t")
	raw.tointeger = |L, idx| -> tointegerx(L, idx, nil)
	raw.tointegerx = tointegerx
	raw.tolstring = function(L, idx)
		local length = ffi.new("size_t[1]")
		return ffi.string(ffi.cast("const char *", tolstring_c(L, idx, length)), length[0])
	end
	raw.tonumber = |L, idx| -> tonumberx(L, idx, nil)
	raw.tonumberx = tonumberx
	raw.topointer = fn("lua_topointer", "lua54_topointer_t")
	raw.tothread = fn("lua_tothread", "lua54_tothread_t")
	raw.touserdata = fn("lua_touserdata", "lua54_touserdata_t")
	raw.type = fn("lua_type", "lua54_type_t")
	raw.typename = fn("lua_typename", "lua54_typename_t")
	raw.upvalueid = fn("lua_upvalueid", "lua54_upvalueid_t")
	raw.upvaluejoin = fn("lua_upvaluejoin", "lua54_upvaluejoin_t")
	raw.version = fn("lua_version", "lua54_version_t")
	raw.xmove = fn("lua_xmove", "lua54_xmove_t")
	local yieldk = fn("lua_yieldk", "lua54_yieldk_t")
	raw.yield = |L, nresults| -> yieldk(L, nresults, 0, nil)

	raw.geti = fn("lua_geti", "lua54_geti_t")
	raw.seti = fn("lua_seti", "lua54_seti_t")
	raw.getiuservalue = fn("lua_getiuservalue", "lua54_getiuservalue_t")
	raw.setiuservalue = fn("lua_setiuservalue", "lua54_setiuservalue_t")
	raw.compare = compare
	raw.absindex = fn("lua_absindex", "lua54_absindex_t")
	raw.stringtonumber = fn("lua_stringtonumber", "lua54_stringtonumber_t")

	-- Aux library (luaL_*)
	raw.addlstring = fn("luaL_addlstring", "lua54_addlstring_t")
	raw.addstring = fn("luaL_addstring", "lua54_addstring_t")
	raw.addvalue = fn("luaL_addvalue", "lua54_addvalue_t")
	raw.argerror = fn("luaL_argerror", "lua54_argerror_t")
	raw.buffinit = fn("luaL_buffinit", "lua54_buffinit_t")
	local callmeta = fn("luaL_callmeta", "lua54_callmeta_t")
	raw.callmeta = |L, obj, e| -> callmeta(L, obj, e) ~= 0
	raw.checkany = fn("luaL_checkany", "lua54_checkany_t")
	raw.checkinteger = fn("luaL_checkinteger", "lua54_checkinteger_t")
	raw.checklstring = function(L, idx)
		local length = ffi.new("size_t[1]")
		return ffi.string(ffi.cast("const char *", checklstring_c(L, idx, length)), length[0])
	end
	raw.checknumber = fn("luaL_checknumber", "lua54_checknumber_t")
	raw.checkoption = fn("luaL_checkoption", "lua54_checkoption_t")
	raw.lcheckstack = fn("luaL_checkstack", "lua54_l_checkstack_t")
	raw.checktype = fn("luaL_checktype", "lua54_checktype_t")
	raw.checkudata = fn("luaL_checkudata", "lua54_checkudata_t")
	raw.lerror = fn("luaL_error", "lua54_lerror_t")
	raw.execresult = fn("luaL_execresult", "lua54_execresult_t")
	raw.fileresult = fn("luaL_fileresult", "lua54_fileresult_t")
	raw.getmetafield = fn("luaL_getmetafield", "lua54_getmetafield_t")
	raw.gsub = fn("luaL_gsub", "lua54_gsub_t")
	local loadbufferx = fn("luaL_loadbufferx", "lua54_loadbufferx_t")
	raw.loadbufferx = loadbufferx
	raw.loadbuffer = |L, buff, sz, name| -> loadbufferx(L, buff, sz, name, nil)
	local loadfilex = fn("luaL_loadfilex", "lua54_loadfilex_t")
	raw.loadfilex = loadfilex
	raw.loadfile = |L, name| -> loadfilex(L, name, nil)
	raw.loadstring = fn("luaL_loadstring", "lua54_loadstring_t")
	raw.newmetatable = fn("luaL_newmetatable", "lua54_newmetatable_t")
	raw.lnewstate = fn("luaL_newstate", "lua54_l_newstate_t")
	raw.openlibs = fn("luaL_openlibs", "lua54_openlibs_t")
	raw.optinteger = fn("luaL_optinteger", "lua54_optinteger_t")
	raw.optlstring = fn("luaL_optlstring", "lua54_optlstring_t")
	raw.optnumber = fn("luaL_optnumber", "lua54_optnumber_t")
	local prepbuffsize = fn("luaL_prepbuffsize", "lua54_prepbuffsize_t")
	raw.prepbuffer = B -> prepbuffsize(B, 512)
	raw.pushresult = fn("luaL_pushresult", "lua54_pushresult_t")
	raw.ref = fn("luaL_ref", "lua54_ref_t")
	raw.setfuncs = fn("luaL_setfuncs", "lua54_setfuncs_t")
	raw.lsetmetatable = fn("luaL_setmetatable", "lua54_setmetatable_l_t")
	local testudata = fn("luaL_testudata", "lua54_testudata_t")
	raw.testudata = |L, ud, tname| -> testudata(L, ud, tname) ~= 0
	raw.traceback = fn("luaL_traceback", "lua54_traceback_t")
	raw.unref = fn("luaL_unref", "lua54_unref_t")
	raw.where = fn("luaL_where", "lua54_where_t")

	-- Library openers (luaopen_*)
	raw.openBase = fn("luaopen_base", "lua54_open_t")
	raw.openDebug = fn("luaopen_debug", "lua54_open_t")
	raw.openIO = fn("luaopen_io", "lua54_open_t")
	raw.openMath = fn("luaopen_math", "lua54_open_t")
	raw.openOS = fn("luaopen_os", "lua54_open_t")
	raw.openPackage = fn("luaopen_package", "lua54_open_t")
	raw.openString = fn("luaopen_string", "lua54_open_t")
	raw.openTable = fn("luaopen_table", "lua54_open_t")

	---@param L lua54_State
	---@param n integer
	raw.pop = function(L, n) settop(L, -n - 1) end

	local ar = ffi.new("lua54_Debug")

	---@param code string
	---@return boolean
	local function isBytecode(code)
		if type(code) ~= "string" then return false end
		return code:byte(1) == 27
	end

	---@type lua.Caps
	local caps = { jit = false, hooks = "full", env = "_ENV", integers = true, source = true }

	---@type lua.Binding
	local binding = { name = "5.4", raw = raw, REGISTRYINDEX = LUA_REGISTRYINDEX, typeNames = TYPE_NAMES, caps = caps }

	local pushinteger = raw.pushinteger
	local pushnumber = raw.pushnumber

	---@param L lua54_State
	---@param n number
	function binding.pushNumber(L, n)
		if n % 1 == 0 and n >= LUA_MININTEGER and n < LUA_MAXINTEGER_EXCLUSIVE then
			pushinteger(L, n)
		else
			pushnumber(L, n)
		end
	end

	---@param L lua54_State
	---@param idx integer
	---@return number
	function binding.toNumber(L, idx) return tonumberx(L, idx, nil) end

	---@param L lua54_State
	function binding.pushGlobals(L) raw.rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS) end

	---@param L lua54_State
	---@param code string
	---@param chunkName string?
	---@param mode "t"|"b"|"bt"|nil
	---@return integer
	function binding.load(L, code, chunkName, mode)
		return loadbufferx(L, code, #code, chunkName or code, mode or "bt")
	end

	binding.isBytecode = isBytecode

	---@param L lua54_State
	---@param level integer
	---@param n integer
	---@return string?
	function binding.getlocal(L, level, n)
		if getstack(L, level, ar) == 0 then return nil end
		local name = getlocal_c(L, ar, n)
		if name == nil then return nil end
		return ffi.string(ffi.cast("const char *", name))
	end

	---@param L lua54_State
	---@param level integer
	---@param n integer
	---@return string?
	function binding.setlocal(L, level, n)
		if getstack(L, level, ar) == 0 then
			raw.pop(L, 1)
			return nil
		end
		local name = setlocal_c(L, ar, n)
		if name == nil then return nil end
		return ffi.string(ffi.cast("const char *", name))
	end

	---@param L lua54_State
	---@param level integer
	---@return boolean
	function binding.pushFrameFunction(L, level)
		if getstack(L, level, ar) == 0 then return false end
		return getinfo(L, "f", ar) ~= 0
	end

	---@param L lua54_State
	---@param fnIndex integer
	function binding.getFunctionEnv(L, fnIndex)
		for i = 1, 200 do
			local name = getupvalue(L, fnIndex, i)
			if name == nil then break end
			local isEnv = ffi.string(ffi.cast("const char *", name)) == "_ENV"
			raw.pop(L, 1)
			if isEnv then
				getupvalue(L, fnIndex, i)
				return
			end
		end
		binding.pushGlobals(L)
	end

	---@param L lua54_State
	---@param chunkIndex integer
	function binding.setChunkEnv(L, chunkIndex)
		local top = gettop(L)
		local chunk = chunkIndex
		if chunk < 0 and chunk > LUA_REGISTRYINDEX then chunk = top + chunk + 1 end
		for i = 1, 200 do
			local name = getupvalue(L, chunk, i)
			if name == nil then break end
			local isEnv = ffi.string(ffi.cast("const char *", name)) == "_ENV"
			raw.pop(L, 1)
			if isEnv then
				raw.pushvalue(L, top)
				setupvalue(L, chunk, i)
				raw.pop(L, 1)
				return
			end
		end
		raw.pop(L, 1)
	end

	return binding
end

return abi
