-- abi/luau.lua — the Luau C API.
--
-- Luau exports the same plain names as Lua 5.1, which are already declared by
-- abi/lua51.lua, so this file uses prefixed typedefs and casts the addresses
-- from the image's own symbol table. Type ids and several signatures differ
-- from Lua 5.1 (ref/unref, pushcclosurek, a level-based debug API and source
-- compilation through luau_compile).

local ffi = require("ffi")

ffi.cdef[[
	typedef struct luau_State luau_State;
	typedef int (*luau_CFunction)(luau_State *L);
	typedef int (*luau_Continuation)(luau_State *L, int status);
	typedef void *(*luau_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);
	void free(void *p);

	typedef struct {
		const char *name;
		const char *what;
		const char *source;
		const char *short_src;
		int linedefined;
		int currentline;
		int protoid;
		int bytecodeid;
		unsigned char nupvals;
		unsigned char nparams;
		char isvararg;
		void *userdata;
		char ssbuf[256];
	} luau_Debug;

	typedef struct {
		char *p;
		char *end;
		luau_State *L;
		void *storage;
		char buffer[512];
	} luau_Buffer;

	typedef luau_State *(*luau_newstate_t)(luau_Alloc allocator, void *ud);
	typedef void (*luau_close_t)(luau_State *L);
	typedef luau_State *(*luau_newthread_t)(luau_State *L);
	typedef int (*luau_gettop_t)(luau_State *L);
	typedef void (*luau_settop_t)(luau_State *L, int idx);
	typedef void (*luau_pushvalue_t)(luau_State *L, int idx);
	typedef void (*luau_remove_t)(luau_State *L, int idx);
	typedef void (*luau_insert_t)(luau_State *L, int idx);
	typedef void (*luau_replace_t)(luau_State *L, int idx);
	typedef int (*luau_checkstack_t)(luau_State *L, int size);
	typedef void (*luau_xmove_t)(luau_State *from, luau_State *to, int n);

	typedef int (*luau_isnumber_t)(luau_State *L, int idx);
	typedef int (*luau_isstring_t)(luau_State *L, int idx);
	typedef int (*luau_iscfunction_t)(luau_State *L, int idx);
	typedef int (*luau_isuserdata_t)(luau_State *L, int idx);
	typedef int (*luau_type_t)(luau_State *L, int idx);
	typedef const char *(*luau_typename_t)(luau_State *L, int tp);
	typedef int (*luau_equal_t)(luau_State *L, int idx1, int idx2);
	typedef int (*luau_rawequal_t)(luau_State *L, int idx1, int idx2);
	typedef int (*luau_lessthan_t)(luau_State *L, int idx1, int idx2);
	typedef double (*luau_tonumberx_t)(luau_State *L, int idx, int *isnum);
	typedef int (*luau_tointegerx_t)(luau_State *L, int idx, int *isnum);
	typedef int (*luau_toboolean_t)(luau_State *L, int idx);
	typedef const char *(*luau_tolstring_t)(luau_State *L, int idx, size_t *len);
	typedef int (*luau_objlen_t)(luau_State *L, int idx);
	typedef luau_CFunction (*luau_tocfunction_t)(luau_State *L, int idx);
	typedef void *(*luau_touserdata_t)(luau_State *L, int idx);
	typedef luau_State *(*luau_tothread_t)(luau_State *L, int idx);
	typedef const void *(*luau_topointer_t)(luau_State *L, int idx);

	typedef void (*luau_pushnil_t)(luau_State *L);
	typedef void (*luau_pushnumber_t)(luau_State *L, double n);
	typedef void (*luau_pushinteger_t)(luau_State *L, int n);
	typedef void (*luau_pushlstring_t)(luau_State *L, const char *s, size_t len);
	typedef void (*luau_pushstring_t)(luau_State *L, const char *s);
	typedef const char *(*luau_pushvfstring_t)(luau_State *L, const char *fmt, void *argp);
	typedef const char *(*luau_pushfstring_t)(luau_State *L, const char *fmt, ...);
	typedef void (*luau_pushcclosurek_t)(luau_State *L, luau_CFunction fn, const char *debugname, int nup, luau_Continuation cont);
	typedef void (*luau_pushboolean_t)(luau_State *L, int b);
	typedef int (*luau_pushthread_t)(luau_State *L);
	typedef void (*luau_pushlightuserdatatagged_t)(luau_State *L, void *p, int tag);
	typedef void *(*luau_newuserdatatagged_t)(luau_State *L, size_t sz, int tag);

	typedef int (*luau_gettable_t)(luau_State *L, int idx);
	typedef int (*luau_getfield_t)(luau_State *L, int idx, const char *k);
	typedef int (*luau_rawget_t)(luau_State *L, int idx);
	typedef int (*luau_rawgeti_t)(luau_State *L, int idx, int n);
	typedef void (*luau_createtable_t)(luau_State *L, int narr, int nrec);
	typedef void (*luau_settable_t)(luau_State *L, int idx);
	typedef void (*luau_setfield_t)(luau_State *L, int idx, const char *k);
	typedef void (*luau_rawset_t)(luau_State *L, int idx);
	typedef void (*luau_rawseti_t)(luau_State *L, int idx, int n);
	typedef int (*luau_getmetatable_t)(luau_State *L, int objindex);
	typedef int (*luau_setmetatable_t)(luau_State *L, int objindex);
	typedef void (*luau_getfenv_t)(luau_State *L, int idx);
	typedef int (*luau_setfenv_t)(luau_State *L, int idx);

	typedef void (*luau_call_t)(luau_State *L, int nargs, int nresults);
	typedef int (*luau_pcall_t)(luau_State *L, int nargs, int nresults, int errfunc);
	typedef int (*luau_cpcall_t)(luau_State *L, luau_CFunction func, void *ud);
	typedef int (*luau_yield_t)(luau_State *L, int nresults);
	typedef int (*luau_resume_t)(luau_State *L, luau_State *from, int narg);
	typedef int (*luau_status_t)(luau_State *L);
	typedef int (*luau_isyieldable_t)(luau_State *L);
	typedef int (*luau_gc_t)(luau_State *L, int what, int data);
	typedef void (*luau_error_t)(luau_State *L);
	typedef int (*luau_next_t)(luau_State *L, int idx);
	typedef void (*luau_concat_t)(luau_State *L, int n);
	typedef luau_Alloc (*luau_getallocf_t)(luau_State *L, void **ud);

	typedef int (*luau_ref_t)(luau_State *L, int idx);
	typedef int (*luau_unref_t)(luau_State *L, int ref);
	typedef int (*luau_load_t)(luau_State *L, const char *chunkname, const char *data, size_t size, int env);
	/* Layout of Luau's lua_CompileOptions (Compiler/include/luacode.h). Only
	 * the first two fields are set; the rest stays NULL/0. */
	typedef struct luau_CompileOptions {
		int optimizationLevel;
		int debugLevel;
		int typeInfoLevel;
		int coverageLevel;
		const char *vectorLib;
		const char *vectorCtor;
		const char *vectorType;
		int vectorPrecision;
		const char *const *mutableGlobals;
		const char *const *userdataTypes;
		const char *const *librariesWithKnownMembers;
		void *libraryMemberTypeCb;
		void *libraryMemberConstantCb;
		const char *const *disabledBuiltins;
	} luau_CompileOptions;
	typedef char *(*luau_compile_t)(const char *source, size_t size, luau_CompileOptions *options, size_t *outsize);
	typedef void (*luau_free_t)(void *p);

	typedef int (*luau_getinfo_t)(luau_State *L, int level, const char *what, luau_Debug *ar);
	typedef const char *(*luau_getlocal_t)(luau_State *L, int level, int n);
	typedef const char *(*luau_setlocal_t)(luau_State *L, int level, int n);
	typedef const char *(*luau_getupvalue_t)(luau_State *L, int funcindex, int n);
	typedef const char *(*luau_setupvalue_t)(luau_State *L, int funcindex, int n);
	typedef int (*luau_stackdepth_t)(luau_State *L);
	typedef void (*luau_singlestep_t)(luau_State *L, int enabled);
	typedef void *(*luau_callbacks_t)(luau_State *L);

	typedef luau_State *(*luau_l_newstate_t)(void);
	typedef void (*luau_openlibs_t)(luau_State *L);
	typedef int (*luau_lerror_t)(luau_State *L, const char *fmt, ...);
	typedef int (*luau_argerror_t)(luau_State *L, int narg, const char *extramsg);
	typedef int (*luau_typeerror_t)(luau_State *L, int narg, const char *tname);
	typedef void (*luau_checkany_t)(luau_State *L, int narg);
	typedef const char *(*luau_checklstring_t)(luau_State *L, int numArg, size_t *len);
	typedef double (*luau_checknumber_t)(luau_State *L, int numArg);
	typedef int (*luau_checkinteger_t)(luau_State *L, int numArg);
	typedef void (*luau_l_checkstack_t)(luau_State *L, int sz, const char *msg);
	typedef void (*luau_checktype_t)(luau_State *L, int narg, int t);
	typedef void *(*luau_checkudata_t)(luau_State *L, int ud, const char *tname);
	typedef int (*luau_checkoption_t)(luau_State *L, int narg, const char *def, const char *const *lst);
	typedef int (*luau_optinteger_t)(luau_State *L, int nArg, int def);
	typedef const char *(*luau_optlstring_t)(luau_State *L, int nArg, const char *def, size_t *len);
	typedef double (*luau_optnumber_t)(luau_State *L, int nArg, double def);
	typedef int (*luau_callmeta_t)(luau_State *L, int obj, const char *e);
	typedef int (*luau_getmetafield_t)(luau_State *L, int obj, const char *e);
	typedef int (*luau_newmetatable_t)(luau_State *L, const char *tname);
	typedef void (*luau_register_t)(luau_State *L, const char *libname, const void *l);
	typedef void (*luau_l_setmetatable_t)(luau_State *L, const char *tname);
	typedef void (*luau_traceback_t)(luau_State *L1, luau_State *L2, const char *msg, int level);
	typedef void (*luau_where_t)(luau_State *L, int lvl);
	typedef const char *(*luau_findtable_t)(luau_State *L, int idx, const char *fname, int szhint);
	typedef const char *(*luau_typename_l_t)(luau_State *L, int idx);
	typedef const char *(*luau_tolstring_l_t)(luau_State *L, int idx, size_t *len);

	typedef void (*luau_buffinit_t)(luau_State *L, luau_Buffer *B);
	typedef char *(*luau_prepbuffsize_t)(luau_Buffer *B, size_t size);
	typedef void (*luau_addlstring_t)(luau_Buffer *B, const char *s, size_t l);
	typedef void (*luau_addvalue_t)(luau_Buffer *B);
	typedef void (*luau_pushresult_t)(luau_Buffer *B);

	typedef int (*luau_open_t)(luau_State *L);
]]

local LUA_REGISTRYINDEX = -10000
local LUA_GLOBALSINDEX = -10002
local LUA_ERRSYNTAX = 3
local LUA_ERRMEM = 4

---@class luau_State: ffi.cdata*
---@class luau_Debug: ffi.cdata*
---@class luau_Buffer: ffi.cdata*

local TYPE_NAMES = {
	[0] = "nil",
	[1] = "boolean",
	[2] = "lightuserdata",
	[3] = "number",
	[4] = "vector",
	[5] = "string",
	[6] = "table",
	[7] = "function",
	[8] = "userdata",
	[9] = "thread",
	[10] = "buffer",
	[11] = "class",
	[12] = "object"
}

local abi = { name = "luau" }

---@param img lua.Image
function abi.probe(img)
	return img:symbol("luau_load") ~= nil
end

---@param img lua.Image
---@return lua.Binding
function abi.bind(img)
	---@param symbol string
	---@return ffi.cdata*
	local function sym(symbol)
		return assert(img:symbol(symbol), "lua-sys: the Luau image at " .. (img.path or "<unnamed>") .. " lacks " .. symbol)
	end

	---@param symbol string
	---@param typedef string
	local function fn(symbol, typedef)
		return ffi.cast(typedef, sym(symbol))
	end

	local raw = {}

	raw.newstate = fn("lua_newstate", "luau_newstate_t")
	raw.close = fn("lua_close", "luau_close_t")
	raw.newthread = fn("lua_newthread", "luau_newthread_t")
	raw.gettop = fn("lua_gettop", "luau_gettop_t")
	raw.settop = fn("lua_settop", "luau_settop_t")
	raw.pushvalue = fn("lua_pushvalue", "luau_pushvalue_t")
	raw.remove = fn("lua_remove", "luau_remove_t")
	raw.insert = fn("lua_insert", "luau_insert_t")
	raw.replace = fn("lua_replace", "luau_replace_t")
	local checkstack = fn("lua_checkstack", "luau_checkstack_t")
	raw.checkstack = |L, extra| -> checkstack(L, extra) ~= 0
	raw.xmove = fn("lua_xmove", "luau_xmove_t")

	local isnumber = fn("lua_isnumber", "luau_isnumber_t")
	raw.isnumber = |L, idx| -> isnumber(L, idx) ~= 0
	local isstring = fn("lua_isstring", "luau_isstring_t")
	raw.isstring = |L, idx| -> isstring(L, idx) ~= 0
	local iscfunction = fn("lua_iscfunction", "luau_iscfunction_t")
	raw.iscfunction = |L, idx| -> iscfunction(L, idx) ~= 0
	local isuserdata = fn("lua_isuserdata", "luau_isuserdata_t")
	raw.isuserdata = |L, idx| -> isuserdata(L, idx) ~= 0
	raw.type = fn("lua_type", "luau_type_t")
	raw.typename = fn("lua_typename", "luau_typename_t")

	local equal = fn("lua_equal", "luau_equal_t")
	raw.equal = |L, idx1, idx2| -> equal(L, idx1, idx2) ~= 0
	local rawequal = fn("lua_rawequal", "luau_rawequal_t")
	raw.rawequal = |L, idx1, idx2| -> rawequal(L, idx1, idx2) ~= 0
	local lessthan = fn("lua_lessthan", "luau_lessthan_t")
	raw.lessthan = |L, idx1, idx2| -> lessthan(L, idx1, idx2) ~= 0

	local tonumberx = fn("lua_tonumberx", "luau_tonumberx_t")
	raw.tonumber = |L, idx| -> tonumberx(L, idx, nil)
	raw.tonumberx = tonumberx
	local tointegerx = fn("lua_tointegerx", "luau_tointegerx_t")
	raw.tointeger = |L, idx| -> tointegerx(L, idx, nil)
	raw.tointegerx = tointegerx
	local toboolean = fn("lua_toboolean", "luau_toboolean_t")
	raw.toboolean = |L, idx| -> toboolean(L, idx) ~= 0
	local tolstring_c = fn("lua_tolstring", "luau_tolstring_t")
	raw.objlen = fn("lua_objlen", "luau_objlen_t")
	raw.tocfunction = fn("lua_tocfunction", "luau_tocfunction_t")
	raw.touserdata = fn("lua_touserdata", "luau_touserdata_t")
	raw.tothread = fn("lua_tothread", "luau_tothread_t")
	raw.topointer = fn("lua_topointer", "luau_topointer_t")

	raw.pushnil = fn("lua_pushnil", "luau_pushnil_t")
	raw.pushnumber = fn("lua_pushnumber", "luau_pushnumber_t")
	raw.pushinteger = fn("lua_pushinteger", "luau_pushinteger_t")
	raw.pushlstring = fn("lua_pushlstring", "luau_pushlstring_t")
	raw.pushstring = fn("lua_pushstring", "luau_pushstring_t")
	raw.pushvfstring = fn("lua_pushvfstring", "luau_pushvfstring_t")
	raw.pushfstring = fn("lua_pushfstringL", "luau_pushfstring_t")
	local pushcclosurek = fn("lua_pushcclosurek", "luau_pushcclosurek_t")
	raw.pushcclosurek = pushcclosurek
	raw.pushcclosure = function(L, f, n) pushcclosurek(L, f, nil, n, nil) end
	local pushboolean = fn("lua_pushboolean", "luau_pushboolean_t")
	raw.pushboolean = function(L, b) pushboolean(L, b and 1 or 0) end
	local pushthread = fn("lua_pushthread", "luau_pushthread_t")
	raw.pushthread = L -> pushthread(L) ~= 0
	local pushlightuserdatatagged = fn("lua_pushlightuserdatatagged", "luau_pushlightuserdatatagged_t")
	raw.pushlightuserdata = function(L, p) pushlightuserdatatagged(L, p, 0) end
	local newuserdatatagged = fn("lua_newuserdatatagged", "luau_newuserdatatagged_t")
	raw.newuserdata = |L, sz| -> newuserdatatagged(L, sz, 0)
	raw.newuserdatatagged = newuserdatatagged

	raw.gettable = fn("lua_gettable", "luau_gettable_t")
	raw.getfield = fn("lua_getfield", "luau_getfield_t")
	raw.rawget = fn("lua_rawget", "luau_rawget_t")
	raw.rawgeti = fn("lua_rawgeti", "luau_rawgeti_t")
	raw.createtable = fn("lua_createtable", "luau_createtable_t")
	raw.settable = fn("lua_settable", "luau_settable_t")
	raw.setfield = fn("lua_setfield", "luau_setfield_t")
	raw.rawset = fn("lua_rawset", "luau_rawset_t")
	raw.rawseti = fn("lua_rawseti", "luau_rawseti_t")
	local getmetatable_c = fn("lua_getmetatable", "luau_getmetatable_t")
	raw.getmetatable = |L, idx| -> getmetatable_c(L, idx) ~= 0
	local setmetatable_c = fn("lua_setmetatable", "luau_setmetatable_t")
	raw.setmetatable = |L, idx| -> setmetatable_c(L, idx) ~= 0
	local getfenv_c = fn("lua_getfenv", "luau_getfenv_t")
	raw.getfenv = function(L, idx)
		getfenv_c(L, idx)
		return true
	end
	local setfenv_c = fn("lua_setfenv", "luau_setfenv_t")
	raw.setfenv = |L, idx| -> setfenv_c(L, idx) ~= 0

	raw.call = fn("lua_call", "luau_call_t")
	raw.pcall = fn("lua_pcall", "luau_pcall_t")
	raw.cpcall = fn("lua_cpcall", "luau_cpcall_t")
	raw.yield = fn("lua_yield", "luau_yield_t")
	local resume = fn("lua_resume", "luau_resume_t")
	raw.resume = |L, narg| -> resume(L, nil, narg)
	raw.status = fn("lua_status", "luau_status_t")
	local isyieldable = fn("lua_isyieldable", "luau_isyieldable_t")
	raw.isyieldable = L -> isyieldable(L) ~= 0
	raw.gc = fn("lua_gc", "luau_gc_t")
	raw.error = fn("lua_error", "luau_error_t")
	local next_c = fn("lua_next", "luau_next_t")
	raw.next = |L, idx| -> next_c(L, idx) ~= 0
	raw.concat = fn("lua_concat", "luau_concat_t")
	raw.getallocf = fn("lua_getallocf", "luau_getallocf_t")
	raw.dump = nil
	raw.load = nil
	raw.loadx = nil
	raw.getinfo = nil
	raw.getlocal = nil
	raw.setlocal = nil
	raw.getstack = nil
	raw.gethook = nil
	raw.gethookcount = nil
	raw.gethookmask = nil
	raw.sethook = nil
	raw.upvalueid = nil
	raw.upvaluejoin = nil
	raw.version = nil
	raw.setallocf = nil

	-- Reference system: Luau has lua_ref/lua_unref, no luaL_ref/luaL_unref.
	local ref_c = fn("lua_ref", "luau_ref_t")
	local unref_c = fn("lua_unref", "luau_unref_t")
	raw.ref = function(L, _)
		local ref = ref_c(L, -1)
		raw.settop(L, -2)
		return ref
	end
	raw.unref = |L, _, ref| -> unref_c(L, ref)

	raw.getupvalue = fn("lua_getupvalue", "luau_getupvalue_t")
	raw.setupvalue = fn("lua_setupvalue", "luau_setupvalue_t")
	local getlocal_c = fn("lua_getlocal", "luau_getlocal_t")
	local setlocal_c = fn("lua_setlocal", "luau_setlocal_t")
	local getinfo_c = fn("lua_getinfo", "luau_getinfo_t")
	raw.getinfoAt = getinfo_c
	raw.stackdepth = fn("lua_stackdepth", "luau_stackdepth_t")
	raw.singlestep = fn("lua_singlestep", "luau_singlestep_t")
	raw.callbacks = fn("lua_callbacks", "luau_callbacks_t")

	-- Source compilation (Luau.Compiler), optional in a VM-only build.
	local compileAddress = img:symbol("luau_compile")
	local compileFn, compileOptions
	if compileAddress ~= nil then
		compileFn = ffi.cast("luau_compile_t", compileAddress)
		-- debugLevel 2 keeps local and upvalue names, which the Frame
		-- methods (locals/getLocal/upvalues/getUpvalue) need. The default
		-- build keeps line info only.
		compileOptions = ffi.new("luau_CompileOptions")
		compileOptions.optimizationLevel = 1
		compileOptions.debugLevel = 2
	end
	raw.luau_load = fn("luau_load", "luau_load_t")
	raw.luau_compile = compileFn
	local freeAddress = img:symbol("free")
	raw.free = freeAddress ~= nil and ffi.cast("luau_free_t", freeAddress) or ffi.C.free

	-- Aux library (luaL_*)
	raw.buffinit = fn("luaL_buffinit", "luau_buffinit_t")
	local prepbuffsize = fn("luaL_prepbuffsize", "luau_prepbuffsize_t")
	raw.prepbuffer = B -> prepbuffsize(B, 512)
	local addlstring = fn("luaL_addlstring", "luau_addlstring_t")
	raw.addlstring = addlstring
	raw.addstring = function(B, s) addlstring(B, s, #s) end
	raw.addvalue = fn("luaL_addvalue", "luau_addvalue_t")
	raw.pushresult = fn("luaL_pushresult", "luau_pushresult_t")
	raw.argerror = fn("luaL_argerrorL", "luau_argerror_t")
	raw.typerror = fn("luaL_typeerrorL", "luau_typeerror_t")
	raw.lerror = fn("luaL_errorL", "luau_lerror_t")
	raw.checkany = fn("luaL_checkany", "luau_checkany_t")
	local checklstring_c = fn("luaL_checklstring", "luau_checklstring_t")
	raw.checknumber = fn("luaL_checknumber", "luau_checknumber_t")
	raw.checkinteger = fn("luaL_checkinteger", "luau_checkinteger_t")
	raw.lcheckstack = fn("luaL_checkstack", "luau_l_checkstack_t")
	raw.checktype = fn("luaL_checktype", "luau_checktype_t")
	raw.checkudata = fn("luaL_checkudata", "luau_checkudata_t")
	raw.checkoption = fn("luaL_checkoption", "luau_checkoption_t")
	local callmeta = fn("luaL_callmeta", "luau_callmeta_t")
	raw.callmeta = |L, obj, e| -> callmeta(L, obj, e) ~= 0
	raw.getmetafield = fn("luaL_getmetafield", "luau_getmetafield_t")
	raw.newmetatable = fn("luaL_newmetatable", "luau_newmetatable_t")
	raw.register = fn("luaL_register", "luau_register_t")
	raw.lsetmetatable = function(L, tname)
		raw.getfield(L, LUA_REGISTRYINDEX, tname)
		raw.setmetatable(L, -2)
	end
	raw.traceback = fn("luaL_traceback", "luau_traceback_t")
	raw.where = fn("luaL_where", "luau_where_t")
	raw.findtable = fn("luaL_findtable", "luau_findtable_t")
	raw.lnewstate = fn("luaL_newstate", "luau_l_newstate_t")
	raw.openlibs = fn("luaL_openlibs", "luau_openlibs_t")
	raw.optinteger = fn("luaL_optinteger", "luau_optinteger_t")
	raw.optlstring = fn("luaL_optlstring", "luau_optlstring_t")
	raw.optnumber = fn("luaL_optnumber", "luau_optnumber_t")

	raw.openBase = fn("luaopen_base", "luau_open_t")
	raw.openCoroutine = fn("luaopen_coroutine", "luau_open_t")
	raw.openTable = fn("luaopen_table", "luau_open_t")
	raw.openOS = fn("luaopen_os", "luau_open_t")
	raw.openString = fn("luaopen_string", "luau_open_t")
	raw.openBit32 = fn("luaopen_bit32", "luau_open_t")
	raw.openBuffer = fn("luaopen_buffer", "luau_open_t")
	raw.openUTF8 = fn("luaopen_utf8", "luau_open_t")
	raw.openClass = fn("luaopen_class", "luau_open_t")
	raw.openMath = fn("luaopen_math", "luau_open_t")
	raw.openDebug = fn("luaopen_debug", "luau_open_t")
	raw.openVector = fn("luaopen_vector", "luau_open_t")

	---@param L luau_State
	---@param n integer
	raw.pop = function(L, n) raw.settop(L, -n - 1) end

	local ar = ffi.new("luau_Debug")
	local length = ffi.new("size_t[1]")

	---@param L luau_State
	---@param idx integer
	---@return string
	raw.tolstring = |L, idx| -> ffi.string(ffi.cast("const char *", tolstring_c(L, idx, length)), length[0])

	---@param L luau_State
	---@param idx integer
	---@return string
	raw.checklstring = |L, idx| -> ffi.string(ffi.cast("const char *", checklstring_c(L, idx, length)), length[0])

	---@param L luau_State
	---@param name string
	raw.getglobal = function(L, name) raw.getfield(L, LUA_GLOBALSINDEX, name) end

	---@param code string
	---@return boolean
	local function isBytecode(code)
		if type(code) ~= "string" then return false end
		local byte = code:byte(1)
		-- Luau bytecode starts with its format version (a small control byte),
		-- not the \27 Lua signature, so whitespace and printable text are source.
		return byte ~= nil and byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 11 and byte ~= 12 and byte ~= 13
	end

	---@type lua.Caps
	local caps = {
		jit = false,
		hooks = (img:symbol("lua_callbacks") ~= nil and img:symbol("lua_singlestep") ~= nil) and "line" or nil,
		env = "fenv",
		integers = false,
		source = compileFn ~= nil
	}

	---@type lua.Binding
	local binding = { name = "luau", raw = raw, REGISTRYINDEX = LUA_REGISTRYINDEX, typeNames = TYPE_NAMES, caps = caps }

	local pushnumber = raw.pushnumber
	local pushstring = raw.pushstring

	---@param L luau_State
	---@param n number
	function binding.pushNumber(L, n) pushnumber(L, n) end

	---@param L luau_State
	---@param idx integer
	---@return number
	function binding.toNumber(L, idx) return tonumberx(L, idx, nil) end

	---@param L luau_State
	function binding.pushGlobals(L) raw.pushvalue(L, LUA_GLOBALSINDEX) end

	---@param L luau_State
	---@param code string
	---@param chunkName string?
	---@param _ "t"|"b"|"bt"|nil
	---@return integer
	function binding.load(L, code, chunkName, _)
		local name = chunkName or code
		if isBytecode(code) then
			return raw.luau_load(L, name, code, #code, 0)
		end
		if compileFn == nil then
			pushstring(L, "luau_compile is not available: this Luau VM cannot compile source text")
			return LUA_ERRSYNTAX
		end
		local outSize = ffi.new("size_t[1]")
		local bytecode = compileFn(code, #code, compileOptions, outSize)
		if bytecode == nil then
			pushstring(L, "luau_compile: out of memory")
			return LUA_ERRMEM
		end
		local status = raw.luau_load(L, name, bytecode, outSize[0], 0)
		if raw.free ~= nil then raw.free(bytecode) end
		return status
	end

	binding.isBytecode = isBytecode

	---@param L luau_State
	---@param level integer
	---@param n integer
	---@return string?
	function binding.getlocal(L, level, n)
		local name = getlocal_c(L, level, n)
		if name == nil then return nil end
		return ffi.string(ffi.cast("const char *", name))
	end

	---@param L luau_State
	---@param level integer
	---@param n integer
	---@return string?
	function binding.setlocal(L, level, n)
		local name = setlocal_c(L, level, n)
		if name == nil then return nil end
		return ffi.string(ffi.cast("const char *", name))
	end

	---@param L luau_State
	---@param level integer
	---@return boolean
	function binding.pushFrameFunction(L, level)
		return getinfo_c(L, level, "f", ar) ~= 0
	end

	---@param L luau_State
	---@param fnIndex integer
	function binding.getFunctionEnv(L, fnIndex)
		getfenv_c(L, fnIndex)
	end

	---@param L luau_State
	---@param chunkIndex integer
	function binding.setChunkEnv(L, chunkIndex)
		setfenv_c(L, chunkIndex)
	end

	return binding
end

return abi
