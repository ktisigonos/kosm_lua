//! Frontends written in Lua: what a script declares, read while kosm builds the config. The
//! script returns a table of the frontend's data and its functions:
//! `{ name = "json", extensions = { ".json" }, editor_file = { path = ".jsonrc", contents = "..." },
//! load = function(source, path, variant) ... end, variants = function(source, path) ... end,
//! complete = function(completion) ... end }`. Its functions run like an app's, through
//! `apps.call`, in the one interpreter every script shares; `kosm.at(place, value)` gives a value
//! `load` returns the place it was written in the kosmos.

const std = @import("std");
const kosm = @import("kosm");
const Interpreter = @import("Interpreter.zig");
const Lines = @import("Lines.zig");

const FrontendDeclaration = kosm.Frontend.FrontendDeclaration;
const Context = kosm.Frontend.Context;
const Error = kosm.Frontend.Error;

/// The functions a script may give, in `kosm.Frontend`'s order.
const functions = [_][]const u8{ "load", "variants", "complete" };

/// What a frontend's returned table holds, for messages.
const holds = "name, extensions, editor_file, load, variants and complete";

/// Reads what the frontend script `source` declares, without calling any of its functions.
pub fn declare(context: *Context, source: []const u8) Error!FrontendDeclaration {
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

    fn declaration(reader: *Reader) Error!FrontendDeclaration {
        const interpreter = reader.interpreter;
        const path = reader.context.path;
        if (interpreter.kind(-1) != .table) return reader.context.fail("{s} returns {s}; a frontend's script returns a table of {s}", .{ path, Interpreter.describe(interpreter.kind(-1)), holds });
        const table = interpreter.absolute(-1);
        var found: FrontendDeclaration = .{ .name = "" };
        var given: [functions.len]bool = @splat(false);
        try interpreter.reserve(4);
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const key = try reader.context.arena.dupe(u8, interpreter.string(-2) orelse return reader.context.fail("{s}: the returned table holds a {s} key; it holds {s}", .{ path, Interpreter.describe(interpreter.kind(-2)), holds }));
            if (functionIndex(key)) |index| {
                if (interpreter.kind(-1) != .function) return reader.fail(&.{.{ .key = key }}, "{s} is {s}, not a function", .{ key, Interpreter.describe(interpreter.kind(-1)) });
                given[index] = true;
            } else if (std.mem.eql(u8, key, "name")) {
                found.name = try reader.text(-1, &.{.{ .key = key }});
            } else if (std.mem.eql(u8, key, "extensions")) {
                found.extensions = try reader.texts(-1, key);
            } else if (std.mem.eql(u8, key, "editor_file")) {
                found.editor_file = try reader.editorFile(-1);
            } else return reader.fail(&.{.{ .key = key }}, "the returned table sets '{s}'; it holds {s}", .{ key, holds });
            interpreter.pop(1);
        }
        var names: std.ArrayList([]const u8) = .empty;
        for (functions, given) |function, is_given| {
            if (is_given) try names.append(reader.context.arena, function);
        }
        found.functions = names.items;
        return found;
    }

    fn text(reader: *Reader, index: c_int, path: []const Lines.Segment) Error![]const u8 {
        // Checked first, since reading a number as text turns it into text in place.
        if (reader.interpreter.kind(index) != .string) return reader.fail(path, "{s} is {s}, not text", .{ nameOf(path), Interpreter.describe(reader.interpreter.kind(index)) });
        return reader.context.arena.dupe(u8, reader.interpreter.string(index).?);
    }

    /// A list of text, as `extensions = { ".json" }`.
    fn texts(reader: *Reader, index: c_int, key: []const u8) Error![]const []const u8 {
        const interpreter = reader.interpreter;
        if (interpreter.kind(index) != .table) return reader.fail(&.{.{ .key = key }}, "{s} is {s}, not a list of text such as {{ \".json\" }}", .{ key, Interpreter.describe(interpreter.kind(index)) });
        const position = interpreter.absolute(index);
        var found: std.ArrayList([]const u8) = .empty;
        var item: i64 = 1;
        while (true) : (item += 1) {
            interpreter.pushItem(position, item);
            defer interpreter.pop(1);
            if (interpreter.kind(-1) == .nil) break;
            try found.append(reader.context.arena, try reader.text(-1, &.{.{ .key = key }}));
        }
        return found.items;
    }

    /// `{ path = ".jsonrc", contents = "..." }`.
    fn editorFile(reader: *Reader, index: c_int) Error!kosm.Frontend.Completion.File {
        const interpreter = reader.interpreter;
        const key = "editor_file";
        if (interpreter.kind(index) != .table) return reader.fail(&.{.{ .key = key }}, "editor_file is {s}; it is {{ path = \".jsonrc\", contents = \"...\" }}", .{Interpreter.describe(interpreter.kind(index))});
        const position = interpreter.absolute(index);
        try interpreter.reserve(2);
        interpreter.pushField(position, "path");
        defer interpreter.pop(1);
        interpreter.pushField(position, "contents");
        defer interpreter.pop(1);
        return .{
            .path = try reader.text(-2, &.{ .{ .key = key }, .{ .key = "path" } }),
            .contents = try reader.text(-1, &.{ .{ .key = key }, .{ .key = "contents" } }),
        };
    }

    /// Fails at the line the value at `path` is written on, or at the script.
    fn fail(reader: *Reader, path: []const Lines.Segment, comptime message: []const u8, arguments: anytype) Error {
        const text_given = try reader.context.arena.print(message, arguments);
        const where = if (reader.lines.find(path)) |line| try reader.context.at(line) else reader.context.path;
        return reader.context.fail("{s}: {s}", .{ where, text_given });
    }
};

/// `editor_file.path` for `path`, for messages.
fn nameOf(path: []const Lines.Segment) []const u8 {
    const last = path[path.len - 1];
    if (path.len == 2 and std.mem.eql(u8, last.key, "path")) return "editor_file.path";
    if (path.len == 2) return "editor_file.contents";
    return last.key;
}

fn functionIndex(key: []const u8) ?usize {
    for (functions, 0..) |function, index| {
        if (std.mem.eql(u8, key, function)) return index;
    }
    return null;
}

const testing = std.testing;
const apps = @import("apps.zig");

/// A frontend for `key = value` lines, setting the base and overrides.
const lines_script =
    \\return {
    \\    name = "keys",
    \\    extensions = { ".keys" },
    \\    editor_file = { path = ".keys.json", contents = "{}\n" },
    \\    load = function(source, path, variant)
    \\        local result = { overrides = {} }
    \\        local number = 0
    \\        for line in source:gmatch("([^\n]*)\n?") do
    \\            number = number + 1
    \\            local key, value = line:match("^([%w_]+) = (.*)$")
    \\            if key == "base" then
    \\                result.base = value
    \\            elseif key then
    \\                result.overrides[key] = kosm.at(path .. ":" .. number, value)
    \\            elseif line ~= "" then
    \\                error(path .. ":" .. number .. ": cannot read '" .. line .. "'", 0)
    \\            end
    \\        end
    \\        if #variant ~= 0 then result.overrides.variant = variant[1] end
    \\        return result
    \\    end,
    \\    variants = function(source, path)
    \\        return { "light" }
    \\    end,
    \\}
    \\
;

test "a frontend's data and functions are read without calling any of them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "frontends/keys.lua" };
    const declared = try declare(&context, lines_script);
    try testing.expectEqualStrings("keys", declared.name);
    try testing.expectEqualStrings(".keys", declared.extensions[0]);
    try testing.expectEqualStrings(".keys.json", declared.editor_file.?.path);
    try testing.expectEqualStrings("{}\n", declared.editor_file.?.contents);
    try testing.expectEqual(2, declared.functions.len);
    try testing.expectEqualStrings("load", declared.functions[0]);
    try testing.expectEqualStrings("variants", declared.functions[1]);
}

test "a frontend's load runs in the shared interpreter, giving each value the place kosm.at names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "frontends/keys.lua" };
    const source: kosm.Loose = .{ .value = .{ .string = "base = frost\nsize = 12\n" } };
    const path: kosm.Loose = .{ .value = .{ .string = "kosmoi/mine.keys" } };
    const variant: kosm.Loose = .{ .value = .{ .list = &.{.{ .value = .{ .string = "light" } }} } };
    const loaded = try apps.call(&context, lines_script, "load", &.{ source, path, variant });
    const entries = loaded.value.table;
    try testing.expectEqualStrings("base", entries[0].key);
    try testing.expectEqualStrings("frost", entries[0].value.value.string);
    const overrides = entries[1].value.value.table;
    try testing.expectEqualStrings("size", overrides[0].key);
    try testing.expectEqualStrings("12", overrides[0].value.value.string);
    try testing.expectEqualStrings("kosmoi/mine.keys:2", overrides[0].value.origin.?);
    try testing.expectEqualStrings("light", overrides[1].value.value.string);
    try testing.expectEqual(null, overrides[1].value.origin);
    // An error the script raises about the kosmos names its place.
    const bad: kosm.Loose = .{ .value = .{ .string = "base = frost\noops\n" } };
    try testing.expectError(error.InvalidScript, apps.call(&context, lines_script, "load", &.{ bad, path, variant }));
    try testing.expectEqualStrings("kosmoi/mine.keys:2: cannot read 'oops'", context.message.?);
}

test "a frontend declaration kosm cannot read fails naming its line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { source: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .source = "return 3\n", .message = "frontends/keys.lua returns an integer; a frontend's script returns a table of name, extensions, editor_file, load, variants and complete" },
        .{ .source = "return {\n    name = \"keys\",\n    load = 3,\n}\n", .message = "frontends/keys.lua:3: load is an integer, not a function" },
        .{ .source = "return {\n    name = \"keys\",\n    parse = function() end,\n}\n", .message = "frontends/keys.lua:3: the returned table sets 'parse'; it holds name, extensions, editor_file, load, variants and complete" },
        .{ .source = "return {\n    editor_file = { path = 1, contents = \"\" },\n}\n", .message = "frontends/keys.lua:2: editor_file.path is an integer, not text" },
    };
    for (cases) |case| {
        var context: Context = .{ .arena = arena.allocator(), .path = "frontends/keys.lua" };
        try testing.expectError(error.InvalidScript, declare(&context, case.source));
        try testing.expectEqualStrings(case.message, context.message.?);
    }
}
