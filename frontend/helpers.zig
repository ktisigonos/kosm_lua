//! What every script gets for writing it: `kosm.trace` prints values with the script's line,
//! `kosm.inspect` shows a value's fields as text, and `kosm.get` reads a path that may hold nil.

const std = @import("std");
const c = @import("lua_api");
const Interpreter = @import("Interpreter.zig");
const Bridge = @import("Bridge.zig");

/// Where `kosm.trace` writes. A state traces nothing until `traceInto` says where, so the runs
/// that only read what a script declares print nothing.
pub const TraceOutput = union(enum) {
    silent,
    stderr,
    /// For tests; it must outlive the state.
    writer: *std.Io.Writer,
};

/// Traces go to stderr, as a kosmos being applied or an app's function being run.
pub const to_stderr: TraceOutput = .stderr;

/// Registry key of the state's `TraceOutput`, compared by address.
var trace_key: u8 = 0;

/// Defines the helpers, given the `kosm` table and the functions they build on: `emit(text)`
/// writes a traced line, `shape(value)` gives a Zig value's field names and whether it is a
/// list (nothing otherwise), and `placed(function)` gives `function` called with the place of
/// the script calling it first ("kosmoi/mine.lua:3: "), which it raises its errors at.
const prelude =
    \\local kosm, emit, shape, placed = ...
    \\
    \\rawset(kosm, "trace", placed(function(place, ...)
    \\    local parts = {}
    \\    if place ~= "" then parts[1] = place:sub(1, -2) end
    \\    for index = 1, select("#", ...) do
    \\        local value = select(index, ...)
    \\        parts[#parts + 1] = value == kosm.null and "kosm.null" or tostring(value)
    \\    end
    \\    emit(table.concat(parts, " "))
    \\end))
    \\
    \\local function label(key)
    \\    if type(key) == "string" and key:match("^[%a_][%w_]*$") then return key end
    \\    return "[" .. (type(key) == "string" and string.format("%q", key) or tostring(key)) .. "]"
    \\end
    \\
    \\local function shown(value, depth)
    \\    if type(value) == "string" then return string.format("%q", value) end
    \\    if value == kosm.null then return "kosm.null" end
    \\    local fields, list = shape(value)
    \\    if fields == nil and type(value) ~= "table" then return tostring(value) end
    \\    local name = fields ~= nil and tostring(value) or nil
    \\    if depth == 0 then
    \\        if name == nil then return next(value) == nil and "{}" or "{ ... }" end
    \\        return list and name .. " (" .. #value .. " items)" or name
    \\    end
    \\    local parts = {}
    \\    if fields ~= nil then
    \\        if list then
    \\            for index = 1, #value do parts[#parts + 1] = shown(value[index], depth - 1) end
    \\        else
    \\            for _, field in ipairs(fields) do parts[#parts + 1] = label(field) .. " = " .. shown(value[field], depth - 1) end
    \\        end
    \\        if #parts == 0 then return list and name .. " {}" or name end
    \\        return name .. " { " .. table.concat(parts, ", ") .. " }"
    \\    end
    \\    local count = #value
    \\    for index = 1, count do parts[#parts + 1] = shown(value[index], depth - 1) end
    \\    local keys = {}
    \\    for key in pairs(value) do
    \\        if not (math.type(key) == "integer" and key >= 1 and key <= count) then keys[#keys + 1] = key end
    \\    end
    \\    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    \\    for _, key in ipairs(keys) do parts[#parts + 1] = label(key) .. " = " .. shown(value[key], depth - 1) end
    \\    if #parts == 0 then return "{}" end
    \\    return "{ " .. table.concat(parts, ", ") .. " }"
    \\end
    \\
    \\rawset(kosm, "inspect", placed(function(place, value, depth)
    \\    if depth ~= nil and (math.type(depth) ~= "integer" or depth < 1) then
    \\        error(place .. "kosm.inspect(value, depth): depth is how many levels to show, a whole number from 1", 0)
    \\    end
    \\    return shown(value, depth or 1)
    \\end))
    \\
    \\-- A failure reading a field names the script's line, not this chunk's.
    \\local function read(place, holder, key, path)
    \\    local kind = type(holder)
    \\    if kind ~= "table" and kind ~= "userdata" then
    \\        local what = holder == kosm.null and "kosm.null" or "a " .. kind
    \\        error(place .. "kosm.get: " .. path .. " is " .. what .. ", which has no fields or items", 0)
    \\    end
    \\    local ok, result = pcall(function() return holder[key] end)
    \\    if not ok then error(place .. (tostring(result):gsub("^kosm:%d+: ", "")), 0) end
    \\    return result
    \\end
    \\
    \\-- The keys `path` names, each with the path up to it for messages; nil when it is no path.
    \\local function keysOf(path)
    \\    local keys, rest = {}, path
    \\    while rest ~= "" do
    \\        local key, after = rest:match(#keys == 0 and "^([%a_][%w_]*)(.*)$" or "^%.([%a_][%w_]*)(.*)$")
    \\        if key == nil then
    \\            local position
    \\            position, after = rest:match("^%[(%d+)%](.*)$")
    \\            if position == nil then return nil end
    \\            key = math.tointeger(tonumber(position))
    \\        end
    \\        keys[#keys + 1] = { key = key, before = #keys == 0 and "the value" or path:sub(1, #path - #rest) }
    \\        rest = after
    \\    end
    \\    return keys
    \\end
    \\
    \\rawset(kosm, "get", placed(function(place, value, path)
    \\    if type(path) ~= "string" then
    \\        error(place .. "kosm.get takes a value, then the path to read in it: \"icons.beautyline\", \"layouts[1].layout\"", 0)
    \\    end
    \\    local keys = keysOf(path)
    \\    if keys == nil then
    \\        error(place .. "kosm.get: '" .. path .. "' is no path; it names fields as a.b and items as [1]", 0)
    \\    end
    \\    local current = value
    \\    for _, step in ipairs(keys) do
    \\        if current == nil then return nil end
    \\        current = read(place, current, step.key, step.before)
    \\    end
    \\    return current
    \\end))
;

/// Defines `kosm.trace`, `kosm.inspect` and `kosm.get` in the global `kosm` table.
pub fn install(interpreter: Interpreter) error{OutOfMemory}!void {
    const state = interpreter.state;
    // The chunk is ours and cannot fail but for lack of memory.
    if (c.luaL_loadbufferx(state, prelude, prelude.len, "=kosm", "t") != c.LUA_OK) return error.OutOfMemory;
    _ = c.lua_getglobal(state, "kosm");
    c.lua_pushcclosure(state, emit, 0);
    c.lua_pushcclosure(state, shape, 0);
    c.lua_pushcclosure(state, placed, 0);
    if (c.lua_pcallk(state, 4, 0, 0, 0, null) != c.LUA_OK) return error.OutOfMemory;
}

/// Makes `kosm.trace` write to `output`, which must outlive the state.
pub fn traceInto(interpreter: Interpreter, output: *const TraceOutput) void {
    c.lua_pushlightuserdata(interpreter.state, @constCast(output));
    c.lua_rawsetp(interpreter.state, c.LUA_REGISTRYINDEX, &trace_key);
}

fn outputOf(state: *c.lua_State) TraceOutput {
    _ = c.lua_rawgetp(state, c.LUA_REGISTRYINDEX, &trace_key);
    defer c.lua_settop(state, -2);
    const pointer = c.lua_touserdata(state, -1) orelse return .silent;
    const output: *const TraceOutput = @ptrCast(@alignCast(pointer));
    return output.*;
}

/// `emit(text)`: writes one traced line where the state traces to.
fn emit(state: ?*c.lua_State) callconv(.c) c_int {
    const known = state.?;
    const interpreter: Interpreter = .{ .state = known };
    const text = interpreter.string(1) orelse return 0;
    switch (outputOf(known)) {
        .silent => {},
        .stderr => {
            var buffer: [256]u8 = undefined;
            const locked = std.debug.lockStderr(&buffer);
            defer std.debug.unlockStderr();
            writeLine(&locked.file_writer.interface, text);
        },
        .writer => |writer| writeLine(writer, text),
    }
    return 0;
}

/// A trace never fails the script, so a line that cannot be written is dropped.
fn writeLine(writer: *std.Io.Writer, text: []const u8) void {
    writer.print("{s}\n", .{text}) catch {};
    writer.flush() catch {};
}

/// `shape(value)`: for a Zig value, the list of its field names and whether it is a list;
/// nothing for any other value.
fn shape(state: ?*c.lua_State) callconv(.c) c_int {
    const known = state.?;
    const handle = Bridge.handleAt(known, 1) orelse return 0;
    c.lua_createtable(known, @intCast(handle.type.fields.len), 0);
    for (handle.type.fields, 1..) |field, position| {
        _ = c.lua_pushlstring(known, field.ptr, field.len);
        c.lua_rawseti(known, -2, @intCast(position));
    }
    c.lua_pushboolean(known, @intFromBool(handle.type.list));
    return 2;
}

/// `placed(function)`: a Zig function calling `function` with the place of the script calling
/// it first. Being Zig, it keeps the script's place even when called as `return kosm.get(...)`,
/// a tail call, which would replace the script's frame with a Lua function's.
fn placed(state: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushcclosure(state.?, callPlaced, 1);
    return 1;
}

fn callPlaced(state: ?*c.lua_State) callconv(.c) c_int {
    const known = state.?;
    const count = c.lua_gettop(known);
    c.luaL_checkstack(known, 2, null);
    c.lua_pushvalue(known, c.lua_upvalueindex(1));
    c.lua_rotate(known, 1, 1);
    c.luaL_where(known, 1);
    c.lua_rotate(known, 2, 1);
    c.lua_callk(known, count + 1, c.LUA_MULTRET, 0, null);
    return c.lua_gettop(known);
}
