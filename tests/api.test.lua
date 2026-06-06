local raw           = require("lua-sys.raw")
local test          = require("lde-test")
local lua           = raw -- alias so existing test bodies don't need changing

local LUA_TNIL      = 0
local LUA_TBOOLEAN  = 1
local LUA_TNUMBER   = 3
local LUA_TSTRING   = 4
local LUA_TTABLE    = 5
local LUA_TFUNCTION = 6
local LUA_TTHREAD   = 8
local LUA_MULTRET   = -1
local LUA_GCCOLLECT = 2
local LUA_ERRRUN    = 2



test.it("creates and closes a state", function()
	local st = lua.lnewstate()
	test.truthy(st)
	test.equal("cdata", type(st))
	lua.close(st)
end)

test.it("pcall returns error when calling nil", function()
	local st = lua.lnewstate()
	lua.pushnil(st)
	local ok = lua.pcall(st, 0, 0, 0)
	test.equal(LUA_ERRRUN, ok)
	lua.close(st)
end)

test.it("pushes and reads basic types", function()
	local st = lua.lnewstate()

	lua.pushnil(st)
	test.equal(LUA_TNIL, lua.type(st, 1))

	lua.pushboolean(st, true)
	test.equal(LUA_TBOOLEAN, lua.type(st, 2))
	test.truthy(lua.toboolean(st, 2))

	lua.pushnumber(st, 42.5)
	test.equal(LUA_TNUMBER, lua.type(st, 3))
	test.truthy(lua.isnumber(st, 3))
	test.equal(42.5, lua.tonumber(st, 3))

	lua.pushinteger(st, 99)
	test.equal(LUA_TNUMBER, lua.type(st, 4))
	test.equal(99, lua.tointeger(st, 4))

	lua.pushstring(st, "hello")
	test.equal(LUA_TSTRING, lua.type(st, 5))
	test.truthy(lua.isstring(st, 5))
	test.equal("hello", lua.tolstring(st, 5))

	test.equal(5, lua.gettop(st))
	lua.settop(st, 0)
	test.equal(0, lua.gettop(st))

	lua.close(st)
end)

test.it("type predicates return booleans", function()
	local st = lua.lnewstate()

	lua.pushnil(st)
	lua.pushnumber(st, 1)
	lua.pushstring(st, "s")

	test.equal(false, lua.isnumber(st, 1))
	test.equal(true, lua.isnumber(st, 2))
	test.equal(true, lua.isstring(st, 3))
	test.equal(false, lua.isstring(st, 1))
	test.equal(false, lua.iscfunction(st, 1))

	lua.close(st)
end)

test.it("stack manipulation (copy, remove, insert, replace)", function()
	local st = lua.lnewstate()

	lua.pushstring(st, "a")
	lua.pushstring(st, "b")
	lua.pushstring(st, "c")
	test.equal(3, lua.gettop(st))

	lua.copy(st, 1, 3)
	test.equal("a", lua.tolstring(st, 3))

	lua.remove(st, 1)
	test.equal(2, lua.gettop(st))
	test.equal("b", lua.tolstring(st, 1))
	test.equal("a", lua.tolstring(st, 2))

	lua.insert(st, 2)
	test.equal("b", lua.tolstring(st, 1))
	test.equal("a", lua.tolstring(st, 2))

	lua.pushstring(st, "x")
	lua.replace(st, 1)
	test.equal("x", lua.tolstring(st, 1))
	test.equal(2, lua.gettop(st))

	lua.close(st)
end)

test.it("createtable and raw table ops", function()
	local st = lua.lnewstate()

	lua.createtable(st, 0, 2)
	lua.pushstring(st, "value")
	lua.setfield(st, 1, "key")
	lua.getfield(st, 1, "key")
	test.equal("value", lua.tolstring(st, 2))
	test.equal(LUA_TSTRING, lua.type(st, 2))

	lua.pushnumber(st, 42)
	lua.rawseti(st, 1, 1)
	lua.rawgeti(st, 1, 1)
	test.equal(42, lua.tonumber(st, 3))

	lua.close(st)
end)

test.it("rawget / rawset", function()
	local st = lua.lnewstate()

	lua.createtable(st, 0, 0)
	lua.pushstring(st, "raw")
	lua.pushstring(st, "value")
	lua.rawset(st, 1)
	lua.pushstring(st, "raw")
	lua.rawget(st, 1)
	test.equal("value", lua.tolstring(st, 2))

	lua.close(st)
end)

test.it("gettable / settable", function()
	local st = lua.lnewstate()

	lua.createtable(st, 0, 0)
	lua.pushstring(st, "__index")
	lua.pushnil(st)
	lua.settable(st, 1)
	lua.pushstring(st, "__index")
	lua.gettable(st, 1)
	test.equal(LUA_TNIL, lua.type(st, 2))

	lua.close(st)
end)

test.it("loadstring and pcall", function()
	local st = lua.lnewstate()

	local ok = lua.loadstring(st, "return 2 + 2")
	test.equal(0, ok)

	ok = lua.pcall(st, 0, 1, 0)
	test.equal(0, ok)
	test.equal(4, lua.tonumber(st, 1))

	lua.close(st)
end)

test.it("loadfile returns error for missing file", function()
	local st = lua.lnewstate()
	local ok = lua.loadfile(st, "/nonexistent/file.lua")
	test.notEqual(0, ok)
	lua.close(st)
end)

test.it("equal / rawequal / lessthan", function()
	local st = lua.lnewstate()

	lua.pushnumber(st, 1)
	lua.pushnumber(st, 1)
	lua.pushnumber(st, 2)

	test.equal(true, lua.equal(st, 1, 2))
	test.equal(true, lua.rawequal(st, 1, 2))
	test.equal(false, lua.equal(st, 1, 3))
	test.equal(true, lua.lessthan(st, 1, 3))

	lua.close(st)
end)

test.it("concat", function()
	local st = lua.lnewstate()

	lua.pushstring(st, "ab")
	lua.pushstring(st, "cd")
	lua.pushstring(st, "ef")
	lua.concat(st, 3)
	test.equal("abcdef", lua.tolstring(st, 1))

	lua.close(st)
end)

test.it("objlen", function()
	local st = lua.lnewstate()

	lua.pushstring(st, "hello")
	test.equal(5, lua.objlen(st, 1))

	lua.createtable(st, 3, 0)
	test.equal(0, lua.objlen(st, 2))
	-- rawseti to populate array part
	lua.pushnumber(st, 10); lua.rawseti(st, 2, 1)
	lua.pushnumber(st, 20); lua.rawseti(st, 2, 2)
	test.equal(2, lua.objlen(st, 2))

	lua.close(st)
end)

test.it("next iterates a table", function()
	local st = lua.lnewstate()

	lua.createtable(st, 0, 0)
	lua.pushstring(st, "x")
	lua.pushnumber(st, 1)
	lua.rawset(st, 1)
	lua.pushstring(st, "y")
	lua.pushnumber(st, 2)
	lua.rawset(st, 1)

	lua.pushnil(st)
	local count = 0
	while lua.next(st, 1) do
		count = count + 1
		-- key at -2, value at -1 -- pop value, leave key for next iteration
		lua.pop(st, 1)
	end
	test.equal(2, count)

	lua.close(st)
end)

test.it("newthread creates a coroutine-capable thread", function()
	local st = lua.lnewstate()
	lua.openBase(st)

	local co = lua.newthread(st)
	test.equal(LUA_TTHREAD, lua.type(st, -1))

	lua.close(st)
end)

test.it("gc runs", function()
	local st = lua.lnewstate()
	local before = lua.gc(st, LUA_GCCOLLECT, 0)
	test.equal("number", type(before))
	lua.close(st)
end)

test.it("version returns a number", function()
	local st = lua.lnewstate()
	local v = lua.version(st)
	test.equal("number", type(v))
	lua.close(st)
end)

test.it("typename returns a string", function()
	local st = lua.lnewstate()
	local ffi = require("ffi")
	test.equal("nil", ffi.string(lua.typename(st, 0)))
	test.equal("boolean", ffi.string(lua.typename(st, 1)))
	test.equal("number", ffi.string(lua.typename(st, 3)))
	test.equal("string", ffi.string(lua.typename(st, 4)))
	test.equal("table", ffi.string(lua.typename(st, 5)))
	test.equal("function", ffi.string(lua.typename(st, 6)))
	lua.close(st)
end)

test.it("xmove between states", function()
	local st1 = lua.lnewstate()
	local st2 = lua.lnewstate()

	lua.pushstring(st1, "moved")
	lua.xmove(st1, st2, 1)
	test.equal("moved", lua.tolstring(st2, 1))
	test.equal(0, lua.gettop(st1))

	lua.close(st1)
	lua.close(st2)
end)

test.it("newuserdata / touserdata roundtrip", function()
	local st = lua.lnewstate()
	local ud = lua.newuserdata(st, 8)
	test.truthy(ud)
	test.equal(7, lua.type(st, 1))
	test.equal(ud, lua.touserdata(st, 1))
	lua.close(st)
end)

test.it("luaL_* aux library functions", function()
	local st = lua.lnewstate()

	lua.openBase(st)

	-- loadstring
	local ok = lua.loadstring(st, "return 10")
	test.equal(0, ok)

	-- luaL_checkfuncs (these error if wrong type, so just check they exist)
	test.truthy(lua.checkany)
	test.truthy(lua.checktype)
	test.truthy(lua.checknumber)
	test.truthy(lua.checkinteger)
	test.truthy(lua.checklstring)
	test.truthy(lua.checkudata)
	test.truthy(lua.lerror)
	test.truthy(lua.loadbuffer)
	test.truthy(lua.newmetatable)
	test.truthy(lua.lsetmetatable)
	test.truthy(lua.ref)
	test.truthy(lua.unref)
	test.truthy(lua.setfuncs)
	test.truthy(lua.where)

	lua.close(st)
end)

test.it("openlibs opens standard libraries", function()
	local st = lua.lnewstate()
	lua.openlibs(st)
	local ok = lua.loadstring(st, "return type(print)")
	test.equal(0, ok)
	ok = lua.pcall(st, 0, 1, 0)
	test.equal(0, ok)
	test.equal("function", lua.tolstring(st, 1))
	lua.close(st)
end)

test.it("checkstack returns boolean", function()
	local st = lua.lnewstate()
	test.equal(true, lua.checkstack(st, 100))
	lua.close(st)
end)
