//! A Lua 5.5 state that runs one kosmos script with no way to reach files, the environment or
//! native code, and the few calls the frontend makes on it.

const Interpreter = @This();

const std = @import("std");
const c = @import("lua_api");

state: *c.lua_State,

/// What `kosm.null` is, compared by address: a field set to it is cleared.
var null_marker: u8 = 0;

/// Globals of the base library that read files or print, which a kosmos never does. `load` is
/// gone too, since it accepts precompiled chunks, which can crash the interpreter.
const removed_globals = [_][:0]const u8{ "dofile", "loadfile", "load", "print" };

/// Makes reading an undefined global an error: a misspelled name would otherwise be nil,
/// and a field set to nil is no field at all, so the value would vanish without a word.
const strict_globals =
    \\setmetatable(_G, { __index = function(_, name)
    \\    error("'" .. tostring(name) .. "' is not defined", 2)
    \\end })
;

/// The libraries a script gets, each under its usual global name.
const libraries = [_]struct { name: [:0]const u8, open: c.lua_CFunction }{
    .{ .name = "_G", .open = c.luaopen_base },
    .{ .name = "table", .open = c.luaopen_table },
    .{ .name = "string", .open = c.luaopen_string },
    .{ .name = "math", .open = c.luaopen_math },
    .{ .name = "utf8", .open = c.luaopen_utf8 },
    .{ .name = "coroutine", .open = c.luaopen_coroutine },
};

/// A fresh state with the libraries above and the global `kosm` table holding `kosm.null`.
/// Call `deinit` when done.
pub fn init() error{OutOfMemory}!Interpreter {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    const interpreter: Interpreter = .{ .state = state };
    for (libraries) |library| {
        c.luaL_requiref(state, library.name, library.open, 1);
        interpreter.pop(1);
    }
    for (removed_globals) |name| {
        c.lua_pushnil(state);
        c.lua_setglobal(state, name);
    }
    c.lua_createtable(state, 0, 1);
    c.lua_pushlightuserdata(state, &null_marker);
    c.lua_setfield(state, -2, "null");
    c.lua_setglobal(state, "kosm");
    // The chunk is ours and cannot fail but for lack of memory.
    if (interpreter.run(strict_globals, "=kosm")) |_| return error.OutOfMemory;
    interpreter.pop(1);
    return interpreter;
}

pub fn deinit(interpreter: Interpreter) void {
    c.lua_close(interpreter.state);
}

/// Runs `source` as a text chunk named `name` and leaves its first result on the stack. On
/// failure returns Lua's message ("kosmoi/a.lua:3: ..."), valid until the next call.
pub fn run(interpreter: Interpreter, source: []const u8, name: [:0]const u8) ?[]const u8 {
    if (c.luaL_loadbufferx(interpreter.state, source.ptr, source.len, name, "t") != c.LUA_OK) return interpreter.errorMessage();
    return interpreter.callTop();
}

/// Calls the function on top of the stack with no arguments, leaving its first result in its
/// place. On failure returns Lua's message, valid until the next call.
pub fn callTop(interpreter: Interpreter) ?[]const u8 {
    if (c.lua_pcallk(interpreter.state, 0, 1, 0, 0, null) != c.LUA_OK) return interpreter.errorMessage();
    return null;
}

/// The error object on top of the stack as text.
fn errorMessage(interpreter: Interpreter) []const u8 {
    return interpreter.string(-1) orelse "the script raised an error that is not a string";
}

/// What a stack slot holds.
pub const Kind = enum { nil, boolean, null_marker, light_userdata, integer, float, string, table, function, userdata, handle, thread };

/// The registry name of the metatable every handle to a Zig value has.
pub const handle_metatable = "kosm.handle";

/// A value's kind, as messages name it.
pub fn describe(value_kind: Kind) []const u8 {
    return switch (value_kind) {
        .nil => "nil",
        .boolean => "a boolean",
        .null_marker => "kosm.null",
        .light_userdata, .userdata => "a userdata",
        .handle => "a value from Zig",
        .integer => "an integer",
        .float => "a number",
        .string => "a string",
        .table => "a table",
        .function => "a function",
        .thread => "a coroutine",
    };
}

/// What the value at `index` is.
pub fn kind(interpreter: Interpreter, index: c_int) Kind {
    return switch (c.lua_type(interpreter.state, index)) {
        c.LUA_TNIL, c.LUA_TNONE => .nil,
        c.LUA_TBOOLEAN => .boolean,
        c.LUA_TLIGHTUSERDATA => if (c.lua_touserdata(interpreter.state, index) == @as(*anyopaque, &null_marker)) .null_marker else .light_userdata,
        c.LUA_TNUMBER => if (c.lua_isinteger(interpreter.state, index) != 0) .integer else .float,
        c.LUA_TSTRING => .string,
        c.LUA_TTABLE => .table,
        c.LUA_TFUNCTION => .function,
        c.LUA_TUSERDATA => if (c.luaL_testudata(interpreter.state, index, handle_metatable) != null) .handle else .userdata,
        else => .thread,
    };
}

/// The string at `index`, without converting numbers; it lives while the value is on the stack.
pub fn string(interpreter: Interpreter, index: c_int) ?[]const u8 {
    if (c.lua_type(interpreter.state, index) != c.LUA_TSTRING) return null;
    var length: usize = 0;
    const pointer = c.lua_tolstring(interpreter.state, index, &length) orelse return null;
    return pointer[0..length];
}

pub fn integer(interpreter: Interpreter, index: c_int) i64 {
    return c.lua_tointegerx(interpreter.state, index, null);
}

pub fn float(interpreter: Interpreter, index: c_int) f64 {
    return c.lua_tonumberx(interpreter.state, index, null);
}

pub fn boolean(interpreter: Interpreter, index: c_int) bool {
    return c.lua_toboolean(interpreter.state, index) != 0;
}

/// Pushes the value `table` (a stack index) holds at `key`, without metamethods.
pub fn pushField(interpreter: Interpreter, table: c_int, key: [:0]const u8) void {
    const table_position = interpreter.absolute(table);
    _ = c.lua_pushstring(interpreter.state, key);
    _ = c.lua_rawget(interpreter.state, table_position);
}

/// Pushes item `position` (from 1) of the table at `table`, without metamethods.
pub fn pushItem(interpreter: Interpreter, table: c_int, position: i64) void {
    _ = c.lua_rawgeti(interpreter.state, table, position);
}

/// Steps through the table at `table`: with the previous key on top, pops it and pushes the
/// next key and value, returning false (and pushing nothing) after the last. Start with `pushNil`.
pub fn next(interpreter: Interpreter, table: c_int) bool {
    return c.lua_next(interpreter.state, table) != 0;
}

/// Makes room for `count` more values on the stack, which Lua leaves to the caller beyond its
/// first 20; pushing past the room corrupts memory.
pub fn reserve(interpreter: Interpreter, count: c_int) error{OutOfMemory}!void {
    if (c.lua_checkstack(interpreter.state, count) == 0) return error.OutOfMemory;
}

pub fn pushNil(interpreter: Interpreter) void {
    c.lua_pushnil(interpreter.state);
}

pub fn pushCopy(interpreter: Interpreter, index: c_int) void {
    c.lua_pushvalue(interpreter.state, index);
}

pub fn pop(interpreter: Interpreter, count: c_int) void {
    c.lua_settop(interpreter.state, -count - 1);
}

/// `index` as a position from the bottom, so it stays valid while the stack grows.
pub fn absolute(interpreter: Interpreter, index: c_int) c_int {
    return c.lua_absindex(interpreter.state, index);
}
