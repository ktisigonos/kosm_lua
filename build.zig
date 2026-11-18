const std = @import("std");

pub fn build(b: *std.Build) void {
    @import("kosm").packageWithFrontend(b, .{
        .root = "frontend/root.zig",
        .lazy_dependencies = &.{"lua"},
        .wire = addLua,
    });
}

/// Lua's sources a kosmos may use. The io, os, package and debug libraries reach files, the
/// environment and native code, which a kosmos never does, so they are not even compiled.
const lua_sources = [_][]const u8{
    "lapi.c",     "lauxlib.c", "lbaselib.c", "lcode.c",    "lcorolib.c", "lctype.c",
    "ldebug.c",   "ldo.c",     "ldump.c",    "lfunc.c",    "lgc.c",      "llex.c",
    "lmathlib.c", "lmem.c",    "lobject.c",  "lopcodes.c", "lparser.c",  "lstate.c",
    "lstring.c",  "lstrlib.c", "ltable.c",   "ltablib.c",  "ltm.c",      "lundump.c",
    "lutf8lib.c", "lvm.c",     "lzio.c",
};

/// Compiles Lua into the frontend and imports its C API as `lua_api`.
fn addLua(b: *std.Build, module: *std.Build.Module, dependencies: []const *std.Build.Dependency) void {
    const lua = dependencies[0];
    module.link_libc = true;
    module.addCSourceFiles(.{ .root = lua.path("src"), .files = &lua_sources, .flags = &.{"-std=c99"} });
    const header = b.addWriteFiles().add("lua_api.h", "#include <lua.h>\n#include <lauxlib.h>\n#include <lualib.h>\n");
    const api = b.addTranslateC(.{ .root_source_file = header, .target = module.resolved_target.?, .optimize = module.optimize.? });
    api.addIncludePath(lua.path("src"));
    module.addImport("lua_api", api.createModule());
}
