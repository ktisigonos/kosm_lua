//! Apps written in Lua: what a script declares, read while kosm builds the config, and its
//! functions, run in the one interpreter every app shares. The script returns a table:
//! `{ App = { field = kosm.integer(0), ... }, from = function(theme) ... end,
//! apply = function(self, output) ... end, reload = function(self, reloader) ... end }`.

const std = @import("std");
const kosm = @import("kosm");
const c = @import("lua_api");
const Interpreter = @import("Interpreter.zig");
const Bridge = @import("Bridge.zig");
const Lines = @import("Lines.zig");

const Declaration = kosm.Frontend.Declaration;
const Context = kosm.Frontend.Context;
const Error = kosm.Frontend.Error;
const Loose = kosm.Loose;

/// The registry names of the metatables of a field's type (`kosm.integer`) and of a Zig type
/// named while kosm reads what an app declares (`kosm_cursor.App`).
const type_metatable = "kosm.type";
const reference_metatable = "kosm.reference";
/// The registry field holding each app or adapter script's returned table by its path.
const apps_field = "kosm.apps";

/// How deep a field's types may nest (`kosm.list(kosm.optional(...))`).
const max_depth = 16;

/// The functions an app's script may give.
const functions = [_][]const u8{ "from", "apply", "reload" };

/// Gives `kosm` the constructors of field types, run with `kosm`, the two metatables and
/// whether kosm is reading a declaration. While it reads one no Zig code runs, so every other
/// name a script reaches (`kosm.Color`, `kosm_cursor.App`) stands for the Zig type of that name.
const prelude =
    \\local kosm, type_metatable, reference_metatable, declaring = ...
    \\local function isType(value)
    \\    local metatable = getmetatable(value)
    \\    return metatable == type_metatable or metatable == reference_metatable or not declaring
    \\end
    \\type_metatable.__call = function(self, default)
    \\    if self.kind == "optional" or self.kind == "list" then
    \\        error("kosm." .. self.kind .. "(...) already holds its type; it takes no default", 2)
    \\    end
    \\    if default == nil then
    \\        error("kosm." .. self.kind .. "(...) takes the field's default; leave the parentheses out for none", 2)
    \\    end
    \\    return setmetatable({ kind = self.kind, default = default }, type_metatable)
    \\end
    \\for _, kind in ipairs({ "boolean", "integer", "float", "text" }) do
    \\    rawset(kosm, kind, setmetatable({ kind = kind }, type_metatable))
    \\end
    \\for _, kind in ipairs({ "optional", "list" }) do
    \\    rawset(kosm, kind, function(child)
    \\        if not isType(child) then
    \\            error("kosm." .. kind .. " takes a type, as kosm.integer or kosm_cursor.App", 2)
    \\        end
    \\        return setmetatable({ kind = kind, child = child }, type_metatable)
    \\    end)
    \\end
    \\if declaring then
    \\    local function reference(name)
    \\        return setmetatable({ name = name }, reference_metatable)
    \\    end
    \\    reference_metatable.__index = function(self, key)
    \\        return reference(rawget(self, "name") .. "." .. key)
    \\    end
    \\    reference_metatable.__call = function(self)
    \\        error("'" .. rawget(self, "name") .. "' is called while kosm reads what the app declares, when no Zig code runs; call it inside from, apply or reload", 2)
    \\    end
    \\    setmetatable(kosm, { __index = function(_, key) return reference("kosm." .. key) end })
    \\    setmetatable(_G, { __index = function(_, name) return reference(name) end })
    \\end
;

/// Reads what the app script `source` declares, without calling any of its functions.
pub fn declare(context: *Context, source: []const u8) Error!Declaration {
    const interpreter = try Interpreter.init();
    defer interpreter.deinit();
    try installPrelude(interpreter, context, true);
    const chunk_name = try chunkName(context);
    if (interpreter.run(source, chunk_name)) |message| return context.fail("{s}", .{message});
    var reader: Reader = .{ .context = context, .interpreter = interpreter, .lines = try .init(context.arena, source), .source = source };
    return reader.declaration();
}

/// The one interpreter every app's script runs in, started on the first call. A global, because
/// an app's `from(theme)` takes nothing to hand it in; kosm runs one kosmos per process, and the
/// process ending closes it.
var shared: ?Interpreter = null;

/// What the script at `path` returns, for messages: an adapter's in `adapters/`, else an app's.
fn shapeOf(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "adapters/")) return "an adapter's script returns a table with name, extensions and the capabilities it gives";
    return "an app's script returns a table with App, from, apply and maybe reload";
}

/// Calls `function` of the app or adapter script at `context.path`, running the script on its
/// first call.
pub fn call(context: *Context, source: []const u8, function: []const u8, arguments: []const Loose) Error!Loose {
    const interpreter = shared orelse started: {
        const started = try Interpreter.init();
        errdefer started.deinit();
        try Bridge.install(started, context);
        try installPrelude(started, context, false);
        shared = started;
        break :started started;
    };
    const previous = Bridge.enter(interpreter, context);
    defer Bridge.leave(interpreter, previous);
    const state = interpreter.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    try interpreter.reserve(@intCast(arguments.len + 8));

    try pushApp(interpreter, context, source);
    const name = try context.arena.dupeSentinel(u8, function, 0);
    interpreter.pushField(-1, name);
    if (interpreter.kind(-1) != .function) return context.fail("{s} gives no function '{s}'; {s}", .{ context.path, function, shapeOf(context.path) });
    for (arguments) |argument| try Bridge.push(interpreter, context, argument);
    if (c.lua_pcallk(state, @intCast(arguments.len), 1, 0, 0, null) != c.LUA_OK)
        return context.fail("{s}", .{interpreter.string(-1) orelse "the script raised an error that is not a string"});
    if (interpreter.kind(-1) == .nil) return .{ .value = .null };
    return Bridge.read(interpreter, context, -1);
}

/// Pushes the table the app or adapter script `source` returns, running it the first time, in an
/// environment of its own so two scripts' globals never meet.
fn pushApp(interpreter: Interpreter, context: *Context, source: []const u8) Error!void {
    const state = interpreter.state;
    _ = c.lua_getfield(state, c.LUA_REGISTRYINDEX, apps_field);
    if (interpreter.kind(-1) != .table) {
        interpreter.pop(1);
        c.lua_createtable(state, 0, 4);
        c.lua_pushvalue(state, -1);
        c.lua_setfield(state, c.LUA_REGISTRYINDEX, apps_field);
    }
    const path = try context.arena.dupeSentinel(u8, context.path, 0);
    interpreter.pushField(-1, path);
    if (interpreter.kind(-1) == .table) {
        c.lua_rotate(state, -2, 1);
        interpreter.pop(1);
        return;
    }
    interpreter.pop(1);
    if (c.luaL_loadbufferx(state, source.ptr, source.len, try chunkName(context), "t") != c.LUA_OK)
        return context.fail("{s}", .{interpreter.string(-1) orelse "the script cannot be read"});
    // Its own globals, falling back to the shared ones (which fail on a name that is not there).
    c.lua_createtable(state, 0, 0);
    c.lua_createtable(state, 0, 1);
    _ = c.lua_rawgeti(state, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);
    c.lua_setfield(state, -2, "__index");
    _ = c.lua_setmetatable(state, -2);
    _ = c.lua_setupvalue(state, -2, 1);
    if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.LUA_OK)
        return context.fail("{s}", .{interpreter.string(-1) orelse "the script raised an error that is not a string"});
    if (interpreter.kind(-1) != .table) return context.fail("{s} returns {s}; {s}", .{ context.path, Interpreter.describe(interpreter.kind(-1)), shapeOf(context.path) });
    c.lua_pushvalue(state, -1);
    c.lua_setfield(state, -3, path);
    c.lua_rotate(state, -2, 1);
    interpreter.pop(1);
}

fn chunkName(context: *Context) Error![:0]const u8 {
    return context.arena.dupeSentinel(u8, try context.arena.print("={s}", .{context.path}), 0);
}

/// Runs the prelude on `interpreter`, whose global `kosm` it fills.
fn installPrelude(interpreter: Interpreter, context: *Context, declaring: bool) Error!void {
    const state = interpreter.state;
    try interpreter.reserve(6);
    if (c.luaL_loadbufferx(state, prelude, prelude.len, "=kosm", "t") != c.LUA_OK) return error.OutOfMemory;
    _ = c.lua_getglobal(state, "kosm");
    _ = c.luaL_newmetatable(state, type_metatable);
    _ = c.luaL_newmetatable(state, reference_metatable);
    c.lua_pushboolean(state, @intFromBool(declaring));
    if (c.lua_pcallk(state, 4, 0, 0, 0, null) != c.LUA_OK)
        return context.fail("kosm's own Lua failed: {s}", .{interpreter.string(-1) orelse "no message"});
}

/// Reads the table on top of the stack as a declaration.
const Reader = struct {
    context: *Context,
    interpreter: Interpreter,
    lines: Lines,
    source: []const u8,

    fn declaration(reader: *Reader) Error!Declaration {
        const interpreter = reader.interpreter;
        const path = reader.context.path;
        if (interpreter.kind(-1) != .table) return reader.context.fail("{s} returns {s}; an app's script returns a table with App, from, apply and maybe reload", .{ path, Interpreter.describe(interpreter.kind(-1)) });
        const table = interpreter.absolute(-1);
        var given: [functions.len]bool = @splat(false);
        try interpreter.reserve(4);
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const key = interpreter.string(-2) orelse return reader.context.fail("{s}: the returned table holds a {s} key; it holds App, from, apply and maybe reload", .{ path, Interpreter.describe(interpreter.kind(-2)) });
            if (std.mem.eql(u8, key, "App")) {
                interpreter.pop(1);
                continue;
            }
            const known = for (functions, 0..) |function, position| {
                if (std.mem.eql(u8, function, key)) break position;
            } else return reader.failAt(&.{.{ .key = key }}, "the returned table sets '{s}'; it holds App, from, apply and maybe reload", .{key});
            if (interpreter.kind(-1) != .function) return reader.failAt(&.{.{ .key = key }}, "{s} is {s}, not a function", .{ key, Interpreter.describe(interpreter.kind(-1)) });
            given[known] = true;
            interpreter.pop(1);
        }
        interpreter.pushField(table, "App");
        const app_fields = switch (interpreter.kind(-1)) {
            .nil => &.{},
            .table => try reader.readFields(interpreter.absolute(-1)),
            else => |kind| return reader.failAt(&.{.{ .key = "App" }}, "App is {s}; it is a table of the app's fields, as App = {{ bars = kosm.integer(0) }}", .{Interpreter.describe(kind)}),
        };
        interpreter.pop(1);
        var gives: std.ArrayList([]const u8) = .empty;
        for (functions, given) |function, is_given| {
            if (is_given) try gives.append(reader.context.arena, function);
        }
        const app_line = reader.lines.find(&.{.{ .key = "App" }});
        return .{ .fields = app_fields, .functions = gives.items, .doc = if (app_line) |line| try reader.docAbove(line) else null };
    }

    /// The fields of the App table at `table`, in the order the script writes them.
    fn readFields(reader: *Reader, table: c_int) Error![]const Declaration.Field {
        const interpreter = reader.interpreter;
        var found: std.ArrayList(Declaration.Field) = .empty;
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const name = interpreter.string(-2) orelse return reader.failAt(&.{.{ .key = "App" }}, "App holds a {s} key; its keys are the fields' names", .{Interpreter.describe(interpreter.kind(-2))});
            const owned = try reader.context.arena.dupe(u8, name);
            const line = reader.lines.find(&.{ .{ .key = "App" }, .{ .key = owned } }) orelse 0;
            var default: ?Loose = null;
            const field_type = try reader.fieldType(-1, owned, line, &default, 0);
            try found.append(reader.context.arena, .{
                .name = owned,
                .doc = if (line != 0) try reader.docAbove(line) else null,
                .type = field_type,
                .default = default,
                .line = line,
            });
            interpreter.pop(1);
        }
        std.mem.sort(Declaration.Field, found.items, {}, fieldLessThan);
        return found.items;
    }

    fn fieldLessThan(_: void, left: Declaration.Field, right: Declaration.Field) bool {
        // Fields without a line (built in code) come last, by name, so the order never changes.
        if (left.line != right.line) return if (left.line == 0) false else if (right.line == 0) true else left.line < right.line;
        return std.mem.order(u8, left.name, right.name) == .lt;
    }

    /// The type the value at `index` gives field `name`, with its default in `default`.
    fn fieldType(reader: *Reader, index: c_int, name: []const u8, line: usize, default: *?Loose, depth: usize) Error!Declaration.Type {
        const interpreter = reader.interpreter;
        if (depth > max_depth) return reader.failLine(line, "App.{s}: its types nest more than {d} deep", .{ name, max_depth });
        const position = interpreter.absolute(index);
        try interpreter.reserve(4);
        if (reader.hasMetatable(position, reference_metatable)) {
            interpreter.pushField(position, "name");
            defer interpreter.pop(1);
            return .{ .zig = try reader.context.arena.dupe(u8, interpreter.string(-1).?) };
        }
        if (!reader.hasMetatable(position, type_metatable))
            return reader.failLine(line, "App.{s}: it is {s}, not a type; give kosm.boolean, kosm.integer, kosm.float or kosm.text (called with a default), kosm.optional(...), kosm.list(...) or a Zig type such as kosm.Color", .{ name, Interpreter.describe(interpreter.kind(position)) });
        interpreter.pushField(position, "kind");
        const kind = try reader.context.arena.dupe(u8, interpreter.string(-1).?);
        interpreter.pop(1);
        if (std.mem.eql(u8, kind, "optional") or std.mem.eql(u8, kind, "list")) {
            interpreter.pushField(position, "child");
            defer interpreter.pop(1);
            const child = try reader.context.arena.create(Declaration.Type);
            child.* = try reader.fieldType(-1, name, line, default, depth + 1);
            if (std.mem.eql(u8, kind, "list")) {
                if (default.* != null) return reader.failLine(line, "App.{s}: a list starts empty; its items take no default", .{name});
                return .{ .list = child };
            }
            return .{ .optional = child };
        }
        interpreter.pushField(position, "default");
        defer interpreter.pop(1);
        const scalar: Declaration.Type = if (std.mem.eql(u8, kind, "boolean")) .boolean else if (std.mem.eql(u8, kind, "integer")) .integer else if (std.mem.eql(u8, kind, "float")) .float else .text;
        default.* = switch (interpreter.kind(-1)) {
            .nil => null,
            .boolean => .{ .value = .{ .boolean = interpreter.boolean(-1) } },
            .integer => .{ .value = .{ .integer = interpreter.integer(-1) } },
            .float => .{ .value = .{ .float = interpreter.float(-1) } },
            .string => .{ .value = .{ .string = try reader.context.arena.dupe(u8, interpreter.string(-1).?) } },
            else => |given| return reader.failLine(line, "App.{s}: a default is a boolean, number or string, not {s}", .{ name, Interpreter.describe(given) }),
        };
        return scalar;
    }

    /// Whether the value at `position` has the metatable registered as `name`.
    fn hasMetatable(reader: *Reader, position: c_int, name: [:0]const u8) bool {
        const state = reader.interpreter.state;
        if (c.lua_getmetatable(state, position) == 0) return false;
        _ = c.lua_getfield(state, c.LUA_REGISTRYINDEX, name);
        defer c.lua_settop(state, -3);
        return c.lua_rawequal(state, -1, -2) != 0;
    }

    /// The `---` comment lines right above line `line`, without the dashes; LuaLS annotations
    /// (`---@type`) are left out. Null for none.
    fn docAbove(reader: *Reader, line: usize) Error!?[]const u8 {
        var lines = std.mem.splitScalar(u8, reader.source, '\n');
        var number: usize = 0;
        var block: std.ArrayList([]const u8) = .empty;
        while (lines.next()) |text| {
            number += 1;
            if (number >= line) break;
            const trimmed = std.mem.trim(u8, text, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "---") and !std.mem.startsWith(u8, trimmed, "---@")) {
                try block.append(reader.context.arena, std.mem.trim(u8, trimmed[3..], " \t"));
            } else {
                block.clearRetainingCapacity();
            }
        }
        if (block.items.len == 0) return null;
        return try std.mem.join(reader.context.arena, "\n", block.items);
    }

    fn failAt(reader: *Reader, path: []const Lines.Segment, comptime format: []const u8, arguments: anytype) Error {
        return reader.failLine(reader.lines.find(path) orelse 0, format, arguments);
    }

    fn failLine(reader: *Reader, line: usize, comptime format: []const u8, arguments: anytype) Error {
        const message = try reader.context.arena.print(format, arguments);
        if (line == 0) return reader.context.fail("{s}: {s}", .{ reader.context.path, message });
        return reader.context.fail("{s}: {s}", .{ try reader.context.at(line), message });
    }
};

const testing = std.testing;

fn testDeclare(arena: std.mem.Allocator, source: []const u8) !Declaration {
    var context: Context = .{ .arena = arena, .path = "apps/cava/root.lua" };
    return declare(&context, source) catch |err| {
        if (err == error.InvalidScript) std.debug.print("{s}\n", .{context.message.?});
        return err;
    };
}

fn expectDeclareFailure(source: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "apps/cava/root.lua" };
    try testing.expectError(error.InvalidScript, declare(&context, source));
    try testing.expectEqualStrings(expected, context.message.?);
}

test "an app's fields come in the order written, with their types, defaults and doc comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const declaration = try testDeclare(arena.allocator(),
        \\--- Cava, the audio visualizer.
        \\local App = nil
        \\return {
        \\    --- Cava, the audio visualizer.
        \\    App = {
        \\        --- How many bars; 0 fills the terminal.
        \\        bars = kosm.integer(0),
        \\        ---@type number
        \\        --- Manual sensitivity in percent.
        \\        --- 200 doubles the height.
        \\        sensitivity = kosm.float(100),
        \\        method = kosm.optional(kosm.text),
        \\        gradient = kosm.list(kosm.Color),
        \\        cursor = kosm_cursor.App,
        \\        autosens = kosm.optional(kosm.boolean(true)),
        \\    },
        \\    from = function(theme) return {} end,
        \\    apply = function(self, output) end,
        \\}
    );
    try testing.expectEqualStrings("Cava, the audio visualizer.", declaration.doc.?);
    try testing.expectEqual(2, declaration.functions.len);
    try testing.expectEqualStrings("from", declaration.functions[0]);
    try testing.expectEqualStrings("apply", declaration.functions[1]);
    const fields = declaration.fields;
    try testing.expectEqual(6, fields.len);
    try testing.expectEqualStrings("bars", fields[0].name);
    try testing.expectEqualStrings("How many bars; 0 fills the terminal.", fields[0].doc.?);
    try testing.expectEqual(.integer, fields[0].type);
    try testing.expectEqual(0, fields[0].default.?.value.integer);
    try testing.expectEqual(7, fields[0].line);
    try testing.expectEqualStrings("Manual sensitivity in percent.\n200 doubles the height.", fields[1].doc.?);
    try testing.expectEqual(100, fields[1].default.?.value.integer);
    try testing.expectEqual(.text, fields[2].type.optional.*);
    try testing.expectEqual(null, fields[2].doc);
    try testing.expectEqualStrings("kosm.Color", fields[3].type.list.zig);
    try testing.expectEqualStrings("kosm_cursor.App", fields[4].type.zig);
    try testing.expectEqual(.boolean, fields[5].type.optional.*);
    try testing.expectEqual(true, fields[5].default.?.value.boolean);
}

test "a declaration kosm cannot read fails naming the script's line" {
    try expectDeclareFailure(
        \\return {
        \\    App = {
        \\        bars = 3,
        \\    },
        \\    apply = function(self, output) end,
        \\}
    , "apps/cava/root.lua:3: App.bars: it is an integer, not a type; give kosm.boolean, kosm.integer, kosm.float or kosm.text (called with a default), kosm.optional(...), kosm.list(...) or a Zig type such as kosm.Color");
    try expectDeclareFailure(
        \\return {
        \\    App = {},
        \\    aply = function(self, output) end,
        \\}
    , "apps/cava/root.lua:3: the returned table sets 'aply'; it holds App, from, apply and maybe reload");
    try expectDeclareFailure(
        \\local color = kosm.Color.parseHex("#ffffff")
        \\return { App = {}, apply = function(self, output) end }
    , "apps/cava/root.lua:1: 'kosm.Color.parseHex' is called while kosm reads what the app declares, when no Zig code runs; call it inside from, apply or reload");
    try expectDeclareFailure(
        \\return { App = { bars = kosm.optional(3) }, apply = function(self, output) end }
    , "apps/cava/root.lua:1: kosm.optional takes a type, as kosm.integer or kosm_cursor.App");
}

fn testCall(arena: std.mem.Allocator, path: []const u8, source: []const u8, function: []const u8) !Loose {
    var context: Context = .{ .arena = arena, .path = path };
    return call(&context, source, function, &.{.{ .value = .null }}) catch |err| {
        if (err == error.InvalidScript) std.debug.print("{s}\n", .{context.message.?});
        return err;
    };
}

test "an app's functions run in the shared interpreter, each script with globals of its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const first =
        \\count = 0
        \\return {
        \\    App = { bars = kosm.integer(3), colors = kosm.list(kosm.optional(kosm.integer)) },
        \\    from = function(theme)
        \\        count = count + 1
        \\        return { zeta = count, alpha = kosm.null == nil, middle = { 1, 2 } }
        \\    end,
        \\    apply = function(self, output) end,
        \\}
    ;
    const second =
        \\return {
        \\    from = function(theme) return { seen = rawget(_ENV, "count") == nil } end,
        \\    apply = function(self, output) error("cannot write", 0) end,
        \\}
    ;
    _ = try testCall(arena.allocator(), "apps/first.lua", first, "from");
    const given = try testCall(arena.allocator(), "apps/first.lua", first, "from");
    // The script ran once, so its globals live on; the table comes sorted by key.
    const entries = given.value.table;
    try testing.expectEqualStrings("alpha", entries[0].key);
    try testing.expectEqual(false, entries[0].value.value.boolean);
    try testing.expectEqualStrings("middle", entries[1].key);
    try testing.expectEqualStrings("zeta", entries[2].key);
    try testing.expectEqual(2, entries[2].value.value.integer);
    try testing.expectEqual(.null, (try testCall(arena.allocator(), "apps/first.lua", first, "apply")).value);
    const seen = try testCall(arena.allocator(), "apps/second.lua", second, "from");
    try testing.expectEqual(true, seen.value.table[0].value.value.boolean);

    var context: Context = .{ .arena = arena.allocator(), .path = "apps/second.lua" };
    try testing.expectError(error.InvalidScript, call(&context, second, "apply", &.{}));
    try testing.expectEqualStrings("cannot write", context.message.?);
    context.message = null;
    try testing.expectError(error.InvalidScript, call(&context, second, "reload", &.{}));
    try testing.expectEqualStrings("apps/second.lua gives no function 'reload'; an app's script returns a table with App, from, apply and maybe reload", context.message.?);
    const broken = "return { from = function(theme) return theme.palette end }";
    context = .{ .arena = arena.allocator(), .path = "apps/broken.lua" };
    try testing.expectError(error.InvalidScript, call(&context, broken, "from", &.{.{ .value = .null }}));
    try testing.expect(std.mem.startsWith(u8, context.message.?, "apps/broken.lua:1: "));
}
