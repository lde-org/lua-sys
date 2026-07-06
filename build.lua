-- build.lua — Compiles the C bridge module for lua-sys.
--
-- Requires: luajit-devel
-- lde copies src/ into the output dir before this script runs.

local build = require("lde-build")

local out = assert(os.getenv("LDE_OUTPUT_DIR"), "LDE_OUTPUT_DIR not set")

build:sh("cc -shared -fPIC -O2"
	.. " -I/usr/include/luajit-2.1"
	.. " -o " .. out .. "/bridge.so"
	.. " " .. out .. "/bridge.c"
	.. " -lluajit-5.1")
