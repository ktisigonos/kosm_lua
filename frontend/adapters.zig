//! Adapters written in Lua: what a script declares, read while kosm builds the config. The
//! script returns a table of the adapter's data and the capabilities it gives as functions:
//! `{ name = "keys", extensions = { ".keys" }, comment = { line = "#" },
//! default_format = { boolean = "yes_no" }, format = function(value) ... end,
//! parser = function(source) ... end, serialize = function(root) ... end,
//! insert = function(source, parent, key, value) ... end }`. Its functions run like an app's,
//! through `apps.call`, in the one interpreter every script shares; byte positions count from 1
//! and a range ends on its last byte, as `string.sub` takes them.

const std = @import("std");
const kosm = @import("kosm");
const Interpreter = @import("Interpreter.zig");
const Bridge = @import("Bridge.zig");
const Lines = @import("Lines.zig");

const AdapterDeclaration = kosm.Frontend.AdapterDeclaration;
const Context = kosm.Frontend.Context;
const Error = kosm.Frontend.Error;

/// The capabilities a script may give, by `kosm.Adapter`'s names.
const capabilities = [_][]const u8{ "format", "parser", "serialize", "insert" };

/// What an adapter's returned table holds, for messages.
const holds = "name, extensions, comment, default_format, format, parser, serialize and insert";

/// Reads what the adapter script `source` declares, without calling any of its functions.
pub fn declare(context: *Context, source: []const u8) Error!AdapterDeclaration {
    const interpreter = try Interpreter.init();
    defer interpreter.deinit();
    const chunk_name = try context.arena.dupeSentinel(u8, try context.arena.print("={s}", .{context.path}), 0);
    if (interpreter.run(source, chunk_name)) |message| return context.fail("{s}", .{message});
    var reader: Reader = .{ .context = context, .interpreter = interpreter, .lines = try .init(context.arena, source) };
    return reader.declaration();
}

/// Reads the table on top of the stack as a declaration.
const Reader = struct {
    context: *Context,
    interpreter: Interpreter,
    lines: Lines,

    fn declaration(reader: *Reader) Error!AdapterDeclaration {
        const interpreter = reader.interpreter;
        const path = reader.context.path;
        if (interpreter.kind(-1) != .table) return reader.context.fail("{s} returns {s}; an adapter's script returns a table of {s}", .{ path, Interpreter.describe(interpreter.kind(-1)), holds });
        const table = interpreter.absolute(-1);
        var found: AdapterDeclaration = .{ .name = "" };
        var functions: std.ArrayList([]const u8) = .empty;
        try interpreter.reserve(4);
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const key = try reader.context.arena.dupe(u8, interpreter.string(-2) orelse return reader.context.fail("{s}: the returned table holds a {s} key; it holds {s}", .{ path, Interpreter.describe(interpreter.kind(-2)), holds }));
            if (isCapability(key)) {
                if (interpreter.kind(-1) != .function) return reader.fail(key, "{s} is {s}, not a function", .{ key, Interpreter.describe(interpreter.kind(-1)) });
                try functions.append(reader.context.arena, key);
            } else if (std.mem.eql(u8, key, "name")) {
                found.name = try reader.text(-1, key);
            } else if (std.mem.eql(u8, key, "extensions")) {
                found.extensions = try reader.texts(-1, key);
            } else if (std.mem.eql(u8, key, "comment")) {
                found.comment = try reader.comment(-1);
            } else if (std.mem.eql(u8, key, "default_format")) {
                found.default_format = try reader.format(-1);
            } else return reader.fail(key, "the returned table sets '{s}'; it holds {s}", .{ key, holds });
            interpreter.pop(1);
        }
        // `next` gives no order, so the capabilities come in `kosm.Adapter`'s.
        std.mem.sort([]const u8, functions.items, {}, capabilityLessThan);
        found.functions = functions.items;
        return found;
    }

    fn text(reader: *Reader, index: c_int, key: []const u8) Error![]const u8 {
        // Checked first, since reading a number as text turns it into text in place.
        if (reader.interpreter.kind(index) != .string) return reader.fail(key, "{s} is {s}, not text", .{ key, Interpreter.describe(reader.interpreter.kind(index)) });
        return reader.context.arena.dupe(u8, reader.interpreter.string(index).?);
    }

    /// A list of text, as `extensions = { ".keys", ".kv" }`.
    fn texts(reader: *Reader, index: c_int, key: []const u8) Error![]const []const u8 {
        const interpreter = reader.interpreter;
        if (interpreter.kind(index) != .table) return reader.fail(key, "{s} is {s}, not a list of text such as {{ \".keys\" }}", .{ key, Interpreter.describe(interpreter.kind(index)) });
        const position = interpreter.absolute(index);
        var found: std.ArrayList([]const u8) = .empty;
        var item: i64 = 1;
        while (true) : (item += 1) {
            interpreter.pushItem(position, item);
            defer interpreter.pop(1);
            if (interpreter.kind(-1) == .nil) break;
            try found.append(reader.context.arena, try reader.text(-1, key));
        }
        return found.items;
    }

    /// `{ line = "#" }` or `{ block = { open = "/*", close = "*/" } }`.
    fn comment(reader: *Reader, index: c_int) Error!kosm.Adapter.Comment {
        const interpreter = reader.interpreter;
        const shape = "comment is { line = \"#\" } or { block = { open = \"/*\", close = \"*/\" } }";
        if (interpreter.kind(index) != .table) return reader.fail("comment", "{s}", .{shape});
        const position = interpreter.absolute(index);
        try interpreter.reserve(4);
        interpreter.pushField(position, "line");
        if (interpreter.kind(-1) != .nil) {
            defer interpreter.pop(1);
            return .{ .line = try reader.text(-1, "comment") };
        }
        interpreter.pop(1);
        interpreter.pushField(position, "block");
        defer interpreter.pop(1);
        if (interpreter.kind(-1) != .table) return reader.fail("comment", "{s}", .{shape});
        interpreter.pushField(-1, "open");
        defer interpreter.pop(1);
        interpreter.pushField(-2, "close");
        defer interpreter.pop(1);
        return .{ .block = .{ .open = try reader.text(-2, "comment"), .close = try reader.text(-1, "comment") } };
    }

    /// The default format as loose values, each naming the line it is written on; kosm checks it.
    fn format(reader: *Reader, index: c_int) Error!kosm.Loose {
        var given = try Bridge.read(reader.interpreter, reader.context, index);
        const origin = try reader.place(&.{.{ .key = "default_format" }});
        given.origin = origin;
        if (given.value == .table) {
            const entries = try reader.context.arena.dupe(kosm.Loose.Entry, given.value.table);
            for (entries) |*entry| entry.value.origin = try reader.place(&.{ .{ .key = "default_format" }, .{ .key = entry.key } }) orelse origin;
            given.value = .{ .table = entries };
        }
        return given;
    }

    /// "adapters/keys.lua:3" for the value at `path`, or null when it has no line of its own.
    fn place(reader: *Reader, path: []const Lines.Segment) Error!?[]const u8 {
        const line = reader.lines.find(path) orelse return null;
        return try reader.context.at(line);
    }

    fn fail(reader: *Reader, key: []const u8, comptime message: []const u8, arguments: anytype) Error {
        const text_given = try reader.context.arena.print(message, arguments);
        const where = try reader.place(&.{.{ .key = key }}) orelse reader.context.path;
        return reader.context.fail("{s}: {s}", .{ where, text_given });
    }
};

fn isCapability(key: []const u8) bool {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, key, capability)) return true;
    }
    return false;
}

fn capabilityLessThan(_: void, left: []const u8, right: []const u8) bool {
    return capabilityIndex(left) < capabilityIndex(right);
}

fn capabilityIndex(name: []const u8) usize {
    for (capabilities, 0..) |capability, index| {
        if (std.mem.eql(u8, name, capability)) return index;
    }
    return capabilities.len;
}

const testing = std.testing;
const apps = @import("apps.zig");

/// An adapter for `key = value` lines, comments starting with `#`.
const keys_script =
    \\local function spelled(value)
    \\    if value.kind == "string" then return '"' .. value.value .. '"' end
    \\    if value.kind == "integer" then return tostring(value.value) end
    \\    if value.text then return value.text end
    \\    error("a " .. value.kind .. " cannot be written", 2)
    \\end
    \\
    \\return {
    \\    name = "keys",
    \\    extensions = { ".keys", ".kv" },
    \\    comment = { line = "#" },
    \\    default_format = {
    \\        boolean = "yes_no",
    \\    },
    \\    format = spelled,
    \\    serialize = function(root)
    \\        local lines = {}
    \\        for _, entry in ipairs(root.value) do
    \\            lines[#lines + 1] = entry.key .. " = " .. spelled(entry.value) .. "\n"
    \\        end
    \\        return table.concat(lines)
    \\    end,
    \\    parser = function(source)
    \\        local children = {}
    \\        for start, line in source:gmatch("()([^\n]*)\n?") do
    \\            local key, offset = line:match("^([%w_]+) = ()")
    \\            if key then
    \\                children[#children + 1] = { key = key, kind = "scalar", position = start, value = { start + offset - 1, start + #line - 1 } }
    \\            elseif line ~= "" and not line:find("^#") then
    \\                error("cannot read '" .. line .. "'")
    \\            end
    \\        end
    \\        return { kind = "table", position = 1, value = { 1, #source }, children = children }
    \\    end,
    \\    insert = function(source, parent, key, value)
    \\        return { { range = { #source + 1, #source }, content = key .. " = " .. value .. "\n" } }
    \\    end,
    \\}
    \\
;

test "an adapter's data and capabilities are read without calling any of them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "adapters/keys.lua" };
    const declared = try declare(&context, keys_script);
    try testing.expectEqualStrings("keys", declared.name);
    try testing.expectEqual(2, declared.extensions.len);
    try testing.expectEqualStrings(".kv", declared.extensions[1]);
    try testing.expectEqualStrings("#", declared.comment.?.line);
    try testing.expectEqualStrings("yes_no", declared.default_format.?.value.table[0].value.value.string);
    try testing.expectEqualStrings("adapters/keys.lua:13", declared.default_format.?.value.table[0].value.origin.?);
    try testing.expectEqual(4, declared.functions.len);
    try testing.expectEqualStrings("format", declared.functions[0]);
    try testing.expectEqualStrings("insert", declared.functions[3]);
}

test "a declaration kosm cannot read fails naming the script's line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { source: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .source = "return 1", .message = "adapters/keys.lua returns an integer; an adapter's script returns a table of " ++ holds },
        .{ .source = "return {\n    name = 3,\n}", .message = "adapters/keys.lua:2: name is an integer, not text" },
        .{ .source = "return {\n    name = \"keys\",\n    parse = function() end,\n}", .message = "adapters/keys.lua:3: the returned table sets 'parse'; it holds " ++ holds },
        .{ .source = "return {\n    format = \"text\",\n}", .message = "adapters/keys.lua:2: format is a string, not a function" },
        .{ .source = "return {\n    comment = \"#\",\n}", .message = "adapters/keys.lua:2: comment is { line = \"#\" } or { block = { open = \"/*\", close = \"*/\" } }" },
    };
    for (cases) |case| {
        var context: Context = .{ .arena = arena.allocator(), .path = "adapters/keys.lua" };
        try testing.expectError(error.InvalidScript, declare(&context, case.source));
        try testing.expectEqualStrings(case.message, context.message.?);
    }
}

/// Runs scripts as the runner of scripts does, through `apps.call`, each script's text by path.
const TestHost = struct {
    scripts: []const [2][]const u8,

    fn run(state: *anyopaque, call: *kosm.Frontend.Call, script: kosm.Frontend.ScriptFile, function: []const u8, arguments: []const kosm.Loose) kosm.Frontend.Call.Error!kosm.Loose {
        const host: *TestHost = @ptrCast(@alignCast(state));
        const source = for (host.scripts) |pair| {
            if (std.mem.eql(u8, pair[0], script.path)) break pair[1];
        } else unreachable;
        var context: Context = .{ .arena = call.arena, .path = script.path };
        return apps.call(&context, source, function, arguments) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidScript => call.fail("{s}", .{context.message.?}),
        };
    }

    fn handle(state: *anyopaque, id: *const anyopaque, pointer: *anyopaque) ?kosm.Frontend.Handle {
        _ = state;
        _ = id;
        _ = pointer;
        return null;
    }
};

const test_script: kosm.Frontend.ScriptAdapter = .{ .frontend = "lua", .path = "adapters/keys.lua", .counts_from = 1 };
const test_capabilities = kosm.Frontend.ScriptAdapter.Capabilities(test_script);
/// The adapter as the module kosm generates from `keys_script` gives it.
const test_adapter: kosm.Adapter = .{
    .name = "keys",
    .extensions = &.{".keys"},
    .default_format = .{ .boolean = .yes_no },
    .comment = .{ .line = "#" },
    .format = test_capabilities.format,
    .parser = test_capabilities.parser,
    .serialize = test_capabilities.serialize,
    .insert = test_capabilities.insert,
};

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    plan: kosm.Plan,
    diagnostics: kosm.Diagnostics = .{},
    warnings: kosm.Warnings = undefined,
    home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    output: kosm.Output = undefined,
    test_host: TestHost = .{ .scripts = &.{.{ "adapters/keys.lua", keys_script }} },
    host: kosm.Frontend.Host = undefined,

    fn init(fixture: *Fixture, file: []const u8) !void {
        fixture.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .plan = .init(testing.allocator, testing.io) };
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "main.keys", .data = file });
        fixture.warnings = .init(fixture.arena.allocator());
        const length = try fixture.tmp.dir.realPath(testing.io, &fixture.home_buffer);
        fixture.output = .{
            .allocator = fixture.arena.allocator(),
            .home = fixture.home_buffer[0..length],
            .adapters = &.{test_adapter},
            .plan = &fixture.plan,
            .diagnostics = &fixture.diagnostics,
            .warnings = &fixture.warnings,
            .app = "keyed",
        };
        fixture.host = .{ .state = &fixture.test_host, .arena = fixture.arena.allocator(), .run = TestHost.run, .handle = TestHost.handle };
        kosm.Frontend.Host.install(&fixture.host);
    }

    fn deinit(fixture: *Fixture) void {
        kosm.Frontend.Host.install(null);
        fixture.plan.deinit();
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }

    fn planned(fixture: *Fixture, display_path: []const u8) []const u8 {
        for (fixture.plan.files.items) |planned_file| {
            if (std.mem.eql(u8, planned_file.display_path, display_path)) return planned_file.new;
        }
        return "(not planned)";
    }
};

test "a Lua adapter parses, matches and formats, changing only the value's bytes, and inserts keeping the layout" {
    var fixture: Fixture = undefined;
    try fixture.init("# sizes\nsize = 4\nname = \"x\"\n");
    defer fixture.deinit();
    var selection = try fixture.output.edit(.{ .files = "~/main.keys" });
    try selection.set("size", 12);
    try selection.set("name", "kosm");
    for (try selection.nodes("")) |root| try selection.insert(root, "blur", true);
    try testing.expectEqualStrings("# sizes\nsize = 12\nname = \"kosm\"\nblur = yes\n", fixture.planned("~/main.keys"));
}

test "a Lua adapter writes a whole file, spelling values in its format" {
    var fixture: Fixture = undefined;
    try fixture.init("");
    defer fixture.deinit();
    try fixture.output.generate(.{ .file = "~/kosm.keys" }, .{ .blur = false, .gaps = 0.5, .name = "kosm", .size = 3 });
    try testing.expectEqualStrings("blur = no\ngaps = 0.5\nname = \"kosm\"\nsize = 3\n", fixture.planned("~/kosm.keys"));
}

test "a Lua error fails the edit naming the file and the script's line" {
    var fixture: Fixture = undefined;
    try fixture.init("size = 4\nbroken\n");
    defer fixture.deinit();
    try testing.expectError(error.InvalidSyntax, fixture.output.edit(.{ .files = "~/main.keys" }));
    try testing.expect(std.mem.find(u8, fixture.diagnostics.message(), "adapters/keys.lua:30: cannot read 'broken'") != null);
    try testing.expectEqualStrings("~/main.keys", fixture.diagnostics.file);
}
