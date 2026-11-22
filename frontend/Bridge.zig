//! Gives a script kosm's library: each namespace is a global table filled in as the script reads
//! it, each Zig function a Lua function, and each Zig value a handle reaching into it.

const std = @import("std");
const kosm = @import("kosm");
const c = @import("lua_api");
const Interpreter = @import("Interpreter.zig");

const Frontend = kosm.Frontend;
const Loose = kosm.Loose;

/// The registry names of the handles' and namespaces' metatables.
const handle_metatable = Interpreter.handle_metatable;
const namespace_metatable = "kosm.namespace";

/// Registry key of the script's `Frontend.Context`, and the key a namespace table keeps its
/// namespace under, both compared by address.
var context_key: u8 = 0;
var namespace_key: u8 = 0;

/// How deep tables given to a call may nest; deeper is taken for a table holding itself.
const max_depth = 64;

/// Raised: the message to raise is in `Bridge.message`.
const Raised = error{Raised} || std.mem.Allocator.Error;

/// Installs the library of `context` as the script's globals; `context` must outlive the state.
/// Fails naming a namespace whose name a Lua library already has.
pub fn install(interpreter: Interpreter, context: *Frontend.Context) Frontend.Error!void {
    const state = interpreter.state;
    try interpreter.reserve(8);
    c.lua_pushlightuserdata(state, context);
    c.lua_rawsetp(state, c.LUA_REGISTRYINDEX, &context_key);

    _ = c.luaL_newmetatable(state, handle_metatable);
    setFunction(state, "__index", handleIndex);
    setFunction(state, "__newindex", handleNewIndex);
    setFunction(state, "__len", handleLength);
    setFunction(state, "__tostring", handleText);
    setFunction(state, "__eq", handleEqual);
    interpreter.pop(1);

    _ = c.luaL_newmetatable(state, namespace_metatable);
    setFunction(state, "__index", namespaceIndex);
    setFunction(state, "__call", namespaceCall);
    interpreter.pop(1);

    for (context.library.globals) |namespace| {
        const name = try context.arena.dupeSentinel(u8, namespace.name, 0);
        // Raw, as reading a global that is not there raises an error in a script.
        _ = c.lua_rawgeti(state, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);
        interpreter.pushField(-1, name);
        const existing = interpreter.kind(-1);
        if (std.mem.eql(u8, namespace.name, "kosm") and existing == .table) {
            markNamespace(state, namespace);
            interpreter.pop(2);
            continue;
        }
        interpreter.pop(2);
        if (existing != .nil) return context.fail("the package '{s}' has the name of a global Lua already has; a script cannot reach it", .{namespace.name});
        pushNamespace(state, namespace);
        c.lua_setglobal(state, name);
    }
}

/// Makes `context` the one the state's callbacks use until `leave`, and returns the one before
/// it, so a call into Zig that runs another script's function on the same state gets its own.
pub fn enter(interpreter: Interpreter, context: *Frontend.Context) ?*Frontend.Context {
    const state = interpreter.state;
    _ = c.lua_rawgetp(state, c.LUA_REGISTRYINDEX, &context_key);
    const previous: ?*Frontend.Context = @ptrCast(@alignCast(c.lua_touserdata(state, -1)));
    c.lua_settop(state, -2);
    c.lua_pushlightuserdata(state, context);
    c.lua_rawsetp(state, c.LUA_REGISTRYINDEX, &context_key);
    return previous;
}

/// Gives the state back the context `enter` returned.
pub fn leave(interpreter: Interpreter, previous: ?*Frontend.Context) void {
    if (previous) |context| {
        c.lua_pushlightuserdata(interpreter.state, context);
    } else c.lua_pushnil(interpreter.state);
    c.lua_rawsetp(interpreter.state, c.LUA_REGISTRYINDEX, &context_key);
}

/// The value at `index` as a loose value, as a call into Zig reads its arguments; a failure is
/// recorded through `context.fail`.
pub fn read(interpreter: Interpreter, context: *Frontend.Context, index: c_int) Frontend.Error!Loose {
    var session: Session = .{ .state = interpreter.state, .context = context };
    return session.loose(index, 0) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Raised => context.fail("{s}", .{session.message}),
    };
}

/// The value at `index` as a loose value, as an exported value's function returned it: each
/// function inside its tables is kept in the table at `kept` by its place (`place` and the keys
/// leading to it: "look.tweak"), and read as that place.
pub fn readExport(interpreter: Interpreter, context: *Frontend.Context, index: c_int, kept: c_int, place: []const u8) Frontend.Error!Loose {
    var session: Session = .{ .state = interpreter.state, .context = context, .capture = .{ .table = interpreter.absolute(kept) } };
    try session.capture.?.place.appendSlice(context.arena, place);
    return session.loose(interpreter.absolute(index), 0) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Raised => context.fail("{s}", .{session.message}),
    };
}

/// Pushes `value`, as a call into Zig gives back its result or kosm hands a script its
/// arguments: a table as a table, a list as a sequence counting from 1.
pub fn push(interpreter: Interpreter, context: *Frontend.Context, value: Loose) Frontend.Error!void {
    var session: Session = .{ .state = interpreter.state, .context = context };
    return session.push(value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Raised => context.fail("{s}", .{session.message}),
    };
}

/// Whether the table at `index` is what `kosm.at` returns.
fn isPlaced(state: *c.lua_State, index: c_int) bool {
    if (c.lua_getmetatable(state, index) == 0) return false;
    _ = c.lua_getfield(state, c.LUA_REGISTRYINDEX, Interpreter.placed_metatable);
    defer c.lua_settop(state, -3);
    return c.lua_rawequal(state, -1, -2) != 0;
}

/// Whether the value at `index` is a handle, and if so, which.
pub fn handleAt(state: *c.lua_State, index: c_int) ?Frontend.Handle {
    const pointer = c.luaL_testudata(state, index, handle_metatable) orelse return null;
    const handle: *Frontend.Handle = @ptrCast(@alignCast(pointer));
    return handle.*;
}

fn setFunction(state: *c.lua_State, name: [:0]const u8, function: c.lua_CFunction) void {
    c.lua_pushcclosure(state, function, 0);
    c.lua_setfield(state, -2, name);
}

/// Pushes a new table standing for `namespace`.
fn pushNamespace(state: *c.lua_State, namespace: *const Frontend.Namespace) void {
    c.lua_createtable(state, 0, 4);
    markNamespace(state, namespace);
}

/// Makes the table on top of the stack stand for `namespace`.
fn markNamespace(state: *c.lua_State, namespace: *const Frontend.Namespace) void {
    c.lua_pushlightuserdata(state, @constCast(namespace));
    c.lua_rawsetp(state, -2, &namespace_key);
    c.luaL_setmetatable(state, namespace_metatable);
}

fn namespaceAt(state: *c.lua_State, index: c_int) *const Frontend.Namespace {
    _ = c.lua_rawgetp(state, index, &namespace_key);
    const pointer = c.lua_touserdata(state, -1);
    c.lua_settop(state, -2);
    return @ptrCast(@alignCast(pointer.?));
}

fn contextOf(state: *c.lua_State) *Frontend.Context {
    _ = c.lua_rawgetp(state, c.LUA_REGISTRYINDEX, &context_key);
    const pointer = c.lua_touserdata(state, -1);
    c.lua_settop(state, -2);
    return @ptrCast(@alignCast(pointer.?));
}

/// What a callback works with: the script's context and the message of a failure.
const Session = struct {
    state: *c.lua_State,
    context: *Frontend.Context,
    message: []const u8 = "",
    /// Where functions are kept while reading an exported value; null where a function is no
    /// value.
    capture: ?Capture = null,

    const Capture = struct {
        /// The table keeping functions by place, at this absolute index.
        table: c_int,
        /// The place being read: "look.fonts".
        place: std.ArrayList(u8) = .empty,
    };

    fn of(state: ?*c.lua_State) Session {
        const known = state.?;
        return .{ .state = known, .context = contextOf(known) };
    }

    fn interpreter(session: *const Session) Interpreter {
        return .{ .state = session.state };
    }

    fn fail(session: *Session, comptime format: []const u8, arguments: anytype) Raised {
        session.message = try session.context.arena.print(format, arguments);
        return error.Raised;
    }

    /// Ends a callback: on success the number of values it pushed, otherwise raises a Lua error
    /// naming the script's line. Raising never returns, so it is the callback's last act.
    fn finish(session: *Session, result: Raised!c_int) c_int {
        const message = if (result) |count| return count else |err| switch (err) {
            error.Raised => session.message,
            error.OutOfMemory => "out of memory",
        };
        c.luaL_where(session.state, 1);
        _ = c.lua_pushlstring(session.state, message.ptr, message.len);
        c.lua_concat(session.state, 2);
        return c.lua_error(session.state);
    }

    /// Calls `function` with the values from `first` to the top as its arguments, and pushes
    /// what it returns.
    fn call(session: *Session, function: Frontend.Function, first: c_int) Raised!c_int {
        const top = c.lua_gettop(session.state);
        const count: usize = if (top >= first) @intCast(top - first + 1) else 0;
        const arguments = try session.context.arena.alloc(Loose, count);
        for (arguments, 0..) |*slot, offset| {
            const index = first + @as(c_int, @intCast(offset));
            slot.* = session.loose(index, 0) catch |err| return session.within(err, "argument {d}", .{offset + 1});
        }
        var frontend_call = session.context.library.call(session.context.arena);
        const result = function.call(&frontend_call, arguments) catch |err| return session.callFailed(err, &frontend_call);
        try session.push(result);
        return 1;
    }

    fn callFailed(session: *Session, err: Frontend.Call.Error, frontend_call: *const Frontend.Call) Raised {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CallFailed => session.fail("{s}", .{frontend_call.message orelse "the call failed and did not say why"}),
        };
    }

    /// `err`, its message saying it happened in `format`.
    fn within(session: *Session, err: Raised, comptime format: []const u8, arguments: anytype) Raised {
        if (err != error.Raised) return err;
        const place = try session.context.arena.print(format, arguments);
        return session.fail("{s}: {s}", .{ place, session.message });
    }

    /// The value at `index` as a loose value: tables with names are tables, ones running 1..n
    /// lists, handles handles; nil is null.
    fn loose(session: *Session, index: c_int, depth: usize) Raised!Loose {
        const interpreter_value = session.interpreter();
        const kind = interpreter_value.kind(index);
        return .{ .value = switch (kind) {
            .nil, .null_marker => .null,
            .boolean => .{ .boolean = interpreter_value.boolean(index) },
            .integer => .{ .integer = interpreter_value.integer(index) },
            .float => .{ .float = interpreter_value.float(index) },
            .string => .{ .string = try session.context.arena.dupe(u8, interpreter_value.string(index).?) },
            .handle => .{ .handle = handleAt(session.state, index).? },
            .table => if (isPlaced(session.state, index)) return session.placed(index, depth) else try session.table(index, depth),
            .function => if (session.capture) |*capture| kept: {
                try interpreter_value.reserve(2);
                c.lua_pushvalue(session.state, index);
                _ = c.lua_pushlstring(session.state, capture.place.items.ptr, capture.place.items.len);
                c.lua_rotate(session.state, -2, 1);
                c.lua_rawset(session.state, capture.table);
                break :kept .{ .function = try session.context.arena.dupe(u8, capture.place.items) };
            } else return session.fail("it is a function; values are strings, numbers, booleans, tables, kosm.null or values from Zig", .{}),
            else => return session.fail("it is {s}; values are strings, numbers, booleans, tables, kosm.null or values from Zig", .{Interpreter.describe(kind)}),
        } };
    }

    /// The value `kosm.at(place, value)` gave at `index`, its origin the place.
    fn placed(session: *Session, index: c_int, depth: usize) Raised!Loose {
        const interpreter_value = session.interpreter();
        try interpreter_value.reserve(2);
        const position = interpreter_value.absolute(index);
        interpreter_value.pushField(position, "place");
        const place = try session.context.arena.dupe(u8, interpreter_value.string(-1).?);
        interpreter_value.pop(1);
        interpreter_value.pushField(position, "value");
        defer interpreter_value.pop(1);
        var value = try session.loose(-1, depth + 1);
        value.origin = place;
        return value;
    }

    fn table(session: *Session, index: c_int, depth: usize) Raised!Loose.Kind {
        if (depth > max_depth) return session.fail("it nests more than {d} tables deep; does a table hold itself?", .{max_depth});
        const interpreter_value = session.interpreter();
        try interpreter_value.reserve(4);
        const position = interpreter_value.absolute(index);
        var entries: std.ArrayList(Loose.Entry) = .empty;
        var numbered: usize = 0;
        var largest: i64 = 0;
        interpreter_value.pushNil();
        while (interpreter_value.next(position)) {
            switch (interpreter_value.kind(-2)) {
                .string => {
                    const key = try session.context.arena.dupe(u8, interpreter_value.string(-2).?);
                    const outer_length = if (session.capture) |*capture| length: {
                        const length = capture.place.items.len;
                        try capture.place.print(session.context.arena, ".{s}", .{key});
                        break :length length;
                    } else 0;
                    const value = session.loose(-1, depth + 1) catch |err| {
                        interpreter_value.pop(2);
                        return session.within(err, "{s}", .{key});
                    };
                    if (session.capture) |*capture| capture.place.shrinkRetainingCapacity(outer_length);
                    try entries.append(session.context.arena, .{ .key = key, .value = value });
                },
                .integer => {
                    numbered += 1;
                    largest = @max(largest, interpreter_value.integer(-2));
                },
                else => |kind| {
                    interpreter_value.pop(2);
                    return session.fail("it has a {s} key; keys are names, or 1..n for a list", .{Interpreter.describe(kind)});
                },
            }
            interpreter_value.pop(1);
        }
        if (entries.items.len != 0 and numbered != 0) return session.fail("it mixes named fields with list items", .{});
        // Lua keeps no order of a table's fields, so they come sorted by name, the same every run.
        std.mem.sort(Loose.Entry, entries.items, {}, entryLessThan);
        if (numbered != 0) {
            if (largest != numbered) return session.fail("its list items have gaps; a list's keys run 1..n", .{});
            // A function in a list has no place of its own, so there it is no value.
            const outer_capture = session.capture;
            session.capture = null;
            defer session.capture = outer_capture;
            const items = try session.context.arena.alloc(Loose, numbered);
            for (items, 1..) |*item, item_position| {
                interpreter_value.pushItem(position, @intCast(item_position));
                item.* = session.loose(-1, depth + 1) catch |err| {
                    interpreter_value.pop(1);
                    return session.within(err, "[{d}]", .{item_position});
                };
                interpreter_value.pop(1);
            }
            return .{ .list = items };
        }
        return .{ .table = entries.items };
    }

    /// Pushes `value`, which a call or a handle gave: null as nil, a handle as a new userdata.
    fn push(session: *Session, value: Loose) Raised!void {
        const state = session.state;
        try session.interpreter().reserve(2);
        switch (value.value) {
            .null => c.lua_pushnil(state),
            .boolean => |boolean| c.lua_pushboolean(state, @intFromBool(boolean)),
            .integer => |integer| c.lua_pushinteger(state, integer),
            .float => |float| c.lua_pushnumber(state, float),
            .string, .text => |text| _ = c.lua_pushlstring(state, text.ptr, text.len),
            .handle => |handle| pushHandle(state, handle),
            .function => |place| return session.fail("the function the script gave at {s} cannot be handed back to it", .{place}),
            .table => |entries| {
                c.lua_createtable(state, 0, @intCast(entries.len));
                for (entries) |entry| {
                    _ = c.lua_pushlstring(state, entry.key.ptr, entry.key.len);
                    try session.push(entry.value);
                    c.lua_rawset(state, -3);
                }
            },
            .list => |items| {
                c.lua_createtable(state, @intCast(items.len), 0);
                for (items, 1..) |item, position| {
                    try session.push(item);
                    c.lua_rawseti(state, -2, @intCast(position));
                }
            },
        }
    }
};

fn entryLessThan(_: void, left: Loose.Entry, right: Loose.Entry) bool {
    return std.mem.order(u8, left.key, right.key) == .lt;
}

fn pushHandle(state: *c.lua_State, handle: Frontend.Handle) void {
    const memory = c.lua_newuserdatauv(state, @sizeOf(Frontend.Handle), 0);
    const slot: *Frontend.Handle = @ptrCast(@alignCast(memory.?));
    slot.* = handle;
    c.luaL_setmetatable(state, handle_metatable);
}

/// Pushes a Lua function calling `function`, which must outlive the state.
fn pushFunction(state: *c.lua_State, function: *const Frontend.Function) void {
    c.lua_pushlightuserdata(state, @constCast(function));
    c.lua_pushcclosure(state, functionCall, 1);
}

fn functionCall(state: ?*c.lua_State) callconv(.c) c_int {
    var session: Session = .of(state);
    const function: *const Frontend.Function = @ptrCast(@alignCast(c.lua_touserdata(state, c.lua_upvalueindex(1)).?));
    return session.finish(session.call(function.*, 1));
}

fn namespaceIndex(state: ?*c.lua_State) callconv(.c) c_int {
    var session: Session = .of(state);
    return session.finish(readNamespace(&session));
}

fn readNamespace(session: *Session) Raised!c_int {
    const state = session.state;
    const namespace = namespaceAt(state, 1);
    const name = session.interpreter().string(2) orelse return session.fail("{s} has names only, not {s}", .{ namespace.name, Interpreter.describe(session.interpreter().kind(2)) });
    for (namespace.entries) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        switch (entry.kind) {
            .function => |*function| pushFunction(state, function),
            .namespace => |child| pushNamespace(state, child),
            .constant => |constant| {
                // A fresh copy each time, so it is never kept in the table.
                var frontend_call = session.context.library.call(session.context.arena);
                const value = constant.call(&frontend_call, &.{}) catch |err| return session.callFailed(err, &frontend_call);
                try session.push(value);
                return 1;
            },
        }
        c.lua_pushvalue(state, 2);
        c.lua_pushvalue(state, -2);
        c.lua_rawset(state, 1);
        return 1;
    }
    return session.fail("{s} has no '{s}'", .{ namespace.name, name });
}

fn namespaceCall(state: ?*c.lua_State) callconv(.c) c_int {
    var session: Session = .of(state);
    const namespace = namespaceAt(state.?, 1);
    const function = namespace.call orelse return session.finish(session.fail("{s} is not a function; it holds {s}", .{ namespace.name, entryList(session.context.arena, namespace) }));
    return session.finish(session.call(function, 2));
}

fn entryList(arena: std.mem.Allocator, namespace: *const Frontend.Namespace) []const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (namespace.entries, 0..) |entry, index| {
        if (index != 0) list.appendSlice(arena, ", ") catch return "its entries";
        list.appendSlice(arena, entry.name) catch return "its entries";
    }
    return if (list.items.len == 0) "nothing" else list.items;
}

fn handleIndex(state: ?*c.lua_State) callconv(.c) c_int {
    var session: Session = .of(state);
    return session.finish(readHandle(&session));
}

fn readHandle(session: *Session) Raised!c_int {
    const handle = handleAt(session.state, 1).?;
    const key = try handleKey(session, handle, 2);
    if (key == .field) {
        for (handle.type.methods) |*method| {
            if (std.mem.eql(u8, method.name, key.field)) {
                pushFunction(session.state, method);
                return 1;
            }
        }
    }
    // One past a list's end is nil, as for a Lua sequence, so `ipairs` stops there.
    if (key == .item and handle.type.list and key.item == handle.type.length(handle.pointer)) {
        c.lua_pushnil(session.state);
        return 1;
    }
    var frontend_call = session.context.library.call(session.context.arena);
    const value = handle.type.get(&frontend_call, handle.pointer, key) catch |err| return session.callFailed(err, &frontend_call);
    try session.push(value);
    return 1;
}

fn handleNewIndex(state: ?*c.lua_State) callconv(.c) c_int {
    var session: Session = .of(state);
    return session.finish(writeHandle(&session));
}

fn writeHandle(session: *Session) Raised!c_int {
    const handle = handleAt(session.state, 1).?;
    const key = try handleKey(session, handle, 2);
    if (session.interpreter().kind(3) == .nil) return session.fail("a value set to nil is no value; set it to kosm.null to clear it", .{});
    const value = try session.loose(3, 0);
    var frontend_call = session.context.library.call(session.context.arena);
    handle.type.set(&frontend_call, handle.pointer, key, value) catch |err| return session.callFailed(err, &frontend_call);
    return 0;
}

/// The key at `index` as a handle takes it: a name, or a list's position from 1.
fn handleKey(session: *Session, handle: Frontend.Handle, index: c_int) Raised!Frontend.Handle.Key {
    const interpreter = session.interpreter();
    switch (interpreter.kind(index)) {
        .string => return .{ .field = try session.context.arena.dupe(u8, interpreter.string(index).?) },
        .integer => {
            const position = interpreter.integer(index);
            if (!handle.type.list) return session.fail("{s} has fields, not items", .{handle.type.name});
            if (position < 1) return session.fail("a list's items run from 1, not {d}", .{position});
            return .{ .item = @intCast(position - 1) };
        },
        else => |kind| return session.fail("{s} has no {s} key", .{ handle.type.name, Interpreter.describe(kind) }),
    }
}

fn handleLength(state: ?*c.lua_State) callconv(.c) c_int {
    const handle = handleAt(state.?, 1).?;
    c.lua_pushinteger(state, @intCast(handle.type.length(handle.pointer)));
    return 1;
}

fn handleText(state: ?*c.lua_State) callconv(.c) c_int {
    const handle = handleAt(state.?, 1).?;
    if (handle.as(kosm.Color)) |color| {
        const hex = color.hex8();
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s}({s})", .{ handle.type.name, hex.slice() }) catch handle.type.name;
        _ = c.lua_pushlstring(state, text.ptr, text.len);
        return 1;
    }
    _ = c.lua_pushlstring(state, handle.type.name.ptr, handle.type.name.len);
    return 1;
}

fn handleEqual(state: ?*c.lua_State) callconv(.c) c_int {
    const left = handleAt(state.?, 1);
    const right = handleAt(state.?, 2);
    const equal = left != null and right != null and left.?.pointer == right.?.pointer;
    c.lua_pushboolean(state, @intFromBool(equal));
    return 1;
}
