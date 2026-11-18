//! Kosmoi written in Lua (the `lua` frontend).

const std = @import("std");
const kosm = @import("kosm");
const Interpreter = @import("Interpreter.zig");
const Lines = @import("Lines.zig");

/// Reads `kosmoi/<name>.lua`. The script runs in Lua 5.5 without the io, os, package and debug
/// libraries, and returns a table:
/// `return { base = "personal", params = { ... }, overrides = { kitty = { font_size = 11.5 } } }`.
/// Without `base` it gives `theme = { ... }` instead, and the apps `overrides` names are the
/// ones applied. A table with names is a set of fields, one running 1..n a list, and
/// `kosm.null` clears an optional field.
pub const frontend: kosm.Frontend = .{
    .name = "lua",
    .extensions = &.{".lua"},
    .load = load,
};

/// How deep tables may nest; deeper is taken for a table holding itself.
const max_depth = 64;

/// The fields a script's table may set.
const Field = enum { base, params, theme, overrides };

fn load(context: *kosm.Frontend.Context, source: []const u8) kosm.Frontend.Error!kosm.Frontend.Script {
    const interpreter = try Interpreter.init();
    defer interpreter.deinit();
    const chunk_name = try context.arena.dupeSentinel(u8, try context.arena.print("={s}", .{context.path}), 0);
    if (interpreter.run(source, chunk_name)) |message| return context.fail("{s}", .{message});

    var reader: Reader = .{
        .context = context,
        .interpreter = interpreter,
        .lines = try .init(context.arena, source),
    };
    return reader.script();
}

/// Turns the script's result, on top of the stack, into kosm's loose values.
const Reader = struct {
    context: *kosm.Frontend.Context,
    interpreter: Interpreter,
    lines: Lines,
    path: std.ArrayList(Lines.Segment) = .empty,

    fn script(reader: *Reader) kosm.Frontend.Error!kosm.Frontend.Script {
        const interpreter = reader.interpreter;
        if (interpreter.kind(-1) != .table) {
            return reader.context.fail("the script must return a table of base, params, theme and overrides, not {s}", .{describe(interpreter.kind(-1))});
        }
        const table = interpreter.absolute(-1);
        var result: kosm.Frontend.Script = .{};
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const name = interpreter.string(-2) orelse return reader.failHere("the returned table holds a {s} key; it may set only base, params, theme and overrides", .{describe(interpreter.kind(-2))});
            const field = std.meta.stringToEnum(Field, name) orelse return reader.failAt(&.{.{ .key = name }}, "the returned table sets '{s}'; it may set only base, params, theme and overrides", .{name});
            try reader.path.append(reader.context.arena, .{ .key = @tagName(field) });
            switch (field) {
                .base => result.base = switch (interpreter.kind(-1)) {
                    .string => try reader.context.arena.dupe(u8, interpreter.string(-1).?),
                    else => |kind| return reader.failAt(reader.path.items, "base names a kosmos, as a string, not {s}", .{describe(kind)}),
                },
                .params => result.params = try reader.requiredTable(),
                .theme => result.theme = try reader.requiredTable(),
                .overrides => result.overrides = try reader.requiredTable(),
            }
            _ = reader.path.pop();
            interpreter.pop(1);
        }
        return result;
    }

    /// The table on top of the stack, which `params`, `theme` and `overrides` must be.
    fn requiredTable(reader: *Reader) kosm.Frontend.Error!kosm.Loose {
        const kind = reader.interpreter.kind(-1);
        if (kind != .table) return reader.failAt(reader.path.items, "{s} must be a table, not {s}", .{ reader.pathText(), describe(kind) });
        return reader.value();
    }

    /// The value on top of the stack, at `reader.path`.
    fn value(reader: *Reader) kosm.Frontend.Error!kosm.Loose {
        const interpreter = reader.interpreter;
        const origin = if (reader.lines.find(reader.path.items)) |line| try reader.context.at(line) else null;
        const loose: kosm.Loose.Kind = switch (interpreter.kind(-1)) {
            .string => .{ .string = try reader.context.arena.dupe(u8, interpreter.string(-1).?) },
            .integer => .{ .integer = interpreter.integer(-1) },
            .float => .{ .float = interpreter.float(-1) },
            .boolean => .{ .boolean = interpreter.boolean(-1) },
            .null_marker => .null,
            .table => try reader.tableValue(),
            else => |kind| return reader.failAt(reader.path.items, "{s} is {s}; values are strings, numbers, booleans, tables or kosm.null", .{ reader.pathText(), describe(kind) }),
        };
        return .{ .value = loose, .origin = origin };
    }

    /// The table on top of the stack as named fields, sorted by where they are written, or
    /// as a list when its keys run 1..n.
    fn tableValue(reader: *Reader) kosm.Frontend.Error!kosm.Loose.Kind {
        if (reader.path.items.len > max_depth) return reader.failAt(reader.path.items, "{s} nests more than {d} tables deep; does a table hold itself?", .{ reader.pathText(), max_depth });
        const interpreter = reader.interpreter;
        // A key, a value and the next level's own key and value.
        try interpreter.reserve(4);
        const table_position = interpreter.absolute(-1);
        var named: usize = 0;
        var numbered: usize = 0;
        var largest: i64 = 0;
        interpreter.pushNil();
        while (interpreter.next(table_position)) {
            switch (interpreter.kind(-2)) {
                .string => named += 1,
                .integer => {
                    numbered += 1;
                    largest = @max(largest, interpreter.integer(-2));
                },
                else => |kind| {
                    interpreter.pop(2);
                    return reader.failAt(reader.path.items, "{s} has a {s} key; keys are names, or 1..n for a list", .{ reader.pathText(), describe(kind) });
                },
            }
            interpreter.pop(1);
        }
        if (named != 0 and numbered != 0) return reader.failAt(reader.path.items, "{s} mixes named fields with list items", .{reader.pathText()});
        if (numbered != 0) {
            if (largest != numbered) return reader.failAt(reader.path.items, "{s} has list items with gaps; a list's keys run 1..n", .{reader.pathText()});
            return .{ .list = try reader.items(table_position, numbered) };
        }
        return .{ .table = try reader.entries(table_position, named) };
    }

    fn items(reader: *Reader, table_position: c_int, count: usize) kosm.Frontend.Error![]const kosm.Loose {
        const list = try reader.context.arena.alloc(kosm.Loose, count);
        for (list, 1..) |*item, position| {
            reader.interpreter.pushItem(table_position, @intCast(position));
            try reader.path.append(reader.context.arena, .{ .item = position });
            item.* = try reader.value();
            _ = reader.path.pop();
            reader.interpreter.pop(1);
        }
        return list;
    }

    fn entries(reader: *Reader, table_position: c_int, count: usize) kosm.Frontend.Error![]const kosm.Loose.Entry {
        const interpreter = reader.interpreter;
        const found = try reader.context.arena.alloc(Placed, count);
        var index: usize = 0;
        interpreter.pushNil();
        while (interpreter.next(table_position)) : (index += 1) {
            const key = try reader.context.arena.dupe(u8, interpreter.string(-2).?);
            try reader.path.append(reader.context.arena, .{ .key = key });
            found[index] = .{ .line = reader.lines.find(reader.path.items), .entry = .{ .key = key, .value = try reader.value() } };
            _ = reader.path.pop();
            interpreter.pop(1);
        }
        try reader.checkWritten(found);
        std.mem.sort(Placed, found, {}, Placed.lessThan);
        const result = try reader.context.arena.alloc(kosm.Loose.Entry, count);
        for (found, result) |placed, *entry| entry.* = placed.entry;
        return result;
    }

    /// Fails when the table at `reader.path`, as the script spells it, writes a field that Lua
    /// left out because its value is nil.
    fn checkWritten(reader: *Reader, found: []const Placed) kosm.Frontend.Error!void {
        const written = reader.lines.node(reader.path.items) orelse return;
        if (written.kind != .table) return;
        next_field: for (written.children) |candidate| {
            const key = candidate.key orelse continue;
            for (found) |placed| {
                if (std.mem.eql(u8, placed.entry.key, key)) continue :next_field;
            }
            const line = try reader.context.at(reader.lines.line(candidate));
            const path = reader.pathText();
            return reader.context.fail("{s}: {s}{s}{s} is nil; leave the field out, or set it to kosm.null to clear it", .{ line, path, if (path.len == 0) "" else ".", key });
        }
    }

    /// Fails naming the line `path` is written on, or the script when it is not written out.
    fn failAt(reader: *Reader, path: []const Lines.Segment, comptime format: []const u8, arguments: anytype) kosm.Frontend.Error {
        var shown = path;
        while (shown.len != 0) : (shown = shown[0 .. shown.len - 1]) {
            if (reader.lines.find(shown)) |line| return reader.context.fail("{s}: " ++ format, .{try reader.context.at(line)} ++ arguments);
        }
        return reader.context.fail(format, arguments);
    }

    fn failHere(reader: *Reader, comptime format: []const u8, arguments: anytype) kosm.Frontend.Error {
        return reader.failAt(reader.path.items, format, arguments);
    }

    /// `reader.path` as messages spell it: `overrides.rofi.modes[2]`.
    fn pathText(reader: *Reader) []const u8 {
        var text: std.ArrayList(u8) = .empty;
        for (reader.path.items) |segment| switch (segment) {
            .key => |key| {
                if (text.items.len != 0) text.append(reader.context.arena, '.') catch return "the value";
                text.appendSlice(reader.context.arena, key) catch return "the value";
            },
            .item => |position| text.print(reader.context.arena, "[{d}]", .{position}) catch return "the value",
        };
        return text.items;
    }
};

/// An entry and the line it is written on, to sort a table's fields the way the script reads.
const Placed = struct {
    line: ?usize,
    entry: kosm.Loose.Entry,

    /// Fields without a line come after those with one; ties go by name, so the order never
    /// depends on how Lua happens to store the table.
    fn lessThan(_: void, left: Placed, right: Placed) bool {
        const left_line = left.line orelse std.math.maxInt(usize);
        const right_line = right.line orelse std.math.maxInt(usize);
        if (left_line != right_line) return left_line < right_line;
        return std.mem.order(u8, left.entry.key, right.entry.key) == .lt;
    }
};

/// A Lua value's kind, as messages name it.
fn describe(kind: Interpreter.Kind) []const u8 {
    return switch (kind) {
        .nil => "nil",
        .boolean => "a boolean",
        .null_marker => "kosm.null",
        .light_userdata, .userdata => "a userdata",
        .integer => "an integer",
        .float => "a number",
        .string => "a string",
        .table => "a table",
        .function => "a function",
        .thread => "a coroutine",
    };
}

const testing = std.testing;

/// Loads `source` as `kosmoi/mine.lua`.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    context: kosm.Frontend.Context = undefined,

    fn init(fixture: *Fixture) void {
        fixture.* = .{ .arena = .init(testing.allocator) };
        fixture.context = .{ .arena = fixture.arena.allocator(), .path = "kosmoi/mine.lua" };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena.deinit();
    }

    fn load(fixture: *Fixture, source: []const u8) !kosm.Frontend.Script {
        return frontend.load(&fixture.context, source);
    }

    fn expectFailure(fixture: *Fixture, source: []const u8, expected: []const u8) !void {
        try testing.expectError(error.InvalidScript, fixture.load(source));
        try testing.expectEqualStrings(expected, fixture.context.message.?);
    }
};

/// The entry `key` of the table `loose`.
fn entryOf(loose: kosm.Loose, key: []const u8) !kosm.Loose {
    for (loose.value.table) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return error.TestMissingField;
}

test "a script's base, params and overrides become loose values with their lines" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    const script = try fixture.load(
        \\local size = 11
        \\return {
        \\    base = "personal",
        \\    params = { wallpaper = "walls/dune.png" },
        \\    overrides = {
        \\        kitty = { font_size = size + 0.5, cursor_blink = false },
        \\        rofi = { modes = { "drun", "run" } },
        \\        waybar = { height = 30, spacing = kosm.null },
        \\    },
        \\}
    );
    try testing.expectEqualStrings("personal", script.base.?);
    try testing.expectEqualStrings("walls/dune.png", (try entryOf(script.params.?, "wallpaper")).value.string);
    const overrides = script.overrides.?;
    const kitty = try entryOf(overrides, "kitty");
    try testing.expectEqual(11.5, (try entryOf(kitty, "font_size")).value.float);
    try testing.expectEqual(false, (try entryOf(kitty, "cursor_blink")).value.boolean);
    try testing.expectEqualStrings("kosmoi/mine.lua:6", (try entryOf(kitty, "font_size")).origin.?);
    const modes = (try entryOf(try entryOf(overrides, "rofi"), "modes")).value.list;
    try testing.expectEqualStrings("run", modes[1].value.string);
    try testing.expectEqualStrings("kosmoi/mine.lua:7", modes[1].origin.?);
    const waybar = try entryOf(overrides, "waybar");
    try testing.expectEqual(30, (try entryOf(waybar, "height")).value.integer);
    try testing.expectEqual(.null, std.meta.activeTag((try entryOf(waybar, "spacing")).value));
    // Fields come in the order the script writes them.
    try testing.expectEqualStrings("kitty", overrides.value.table[0].key);
    try testing.expectEqualStrings("waybar", overrides.value.table[2].key);
}

test "a value held by a local takes the line of the field holding it" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    const script = try fixture.load(
        \\local kitty = { font_size = 12 }
        \\return {
        \\    overrides = { kitty = kitty },
        \\}
    );
    const kitty = try entryOf(script.overrides.?, "kitty");
    try testing.expectEqualStrings("kosmoi/mine.lua:3", kitty.origin.?);
    try testing.expectEqual(null, (try entryOf(kitty, "font_size")).origin);
}

test "a script without a base gives a theme and names its apps" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    const script = try fixture.load(
        \\return {
        \\    theme = { mode = "dark", palette = { black = "#101010", white = "#f0f0f0" } },
        \\    overrides = { kitty = {} },
        \\}
    );
    try testing.expectEqual(null, script.base);
    try testing.expectEqualStrings("dark", (try entryOf(script.theme.?, "mode")).value.string);
    try testing.expectEqual(0, (try entryOf(script.overrides.?, "kitty")).value.table.len);
}

test "Lua's own errors name the script and line" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    try fixture.expectFailure("return {\n  base = \n", "kosmoi/mine.lua:3: unexpected symbol near <eof>");
    try fixture.expectFailure("local x = nil\nreturn { base = x.y }\n", "kosmoi/mine.lua:2: attempt to index a nil value (local 'x')");
    try fixture.expectFailure("error('no wallpaper')\n", "kosmoi/mine.lua:1: no wallpaper");
}

test "bad values fail naming their line and path" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    try fixture.expectFailure("return 3", "the script must return a table of base, params, theme and overrides, not an integer");
    try fixture.expectFailure("return {\n  bass = 'x' }", "kosmoi/mine.lua:2: the returned table sets 'bass'; it may set only base, params, theme and overrides");
    try fixture.expectFailure("return {\n  base = 3 }", "kosmoi/mine.lua:2: base names a kosmos, as a string, not an integer");
    try fixture.expectFailure("local size\nreturn { overrides = {\n  kitty = { size = size } } }", "kosmoi/mine.lua:3: overrides.kitty.size is nil; leave the field out, or set it to kosm.null to clear it");
    try fixture.expectFailure("return { overrides = {\n  kitty = { size = sise } } }", "kosmoi/mine.lua:2: 'sise' is not defined");
    try fixture.expectFailure("return { overrides = {\n  kitty = { size = function() end } } }", "kosmoi/mine.lua:2: overrides.kitty.size is a function; values are strings, numbers, booleans, tables or kosm.null");
    try fixture.expectFailure("return { overrides = {\n  rofi = { modes = { 'a', x = 1 } } } }", "kosmoi/mine.lua:2: overrides.rofi.modes mixes named fields with list items");
    try fixture.expectFailure("return { overrides = {\n  rofi = { modes = { [1] = 'a', [3] = 'c' } } } }", "kosmoi/mine.lua:2: overrides.rofi.modes has list items with gaps; a list's keys run 1..n");
    try fixture.expectFailure("local t = {}\nt.t = t\nreturn { overrides = t }", "kosmoi/mine.lua:3: overrides.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t.t nests more than 64 tables deep; does a table hold itself?");
}

test "a script cannot reach files, the environment or native code" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    try fixture.expectFailure("return io.open('/etc/passwd')", "kosmoi/mine.lua:1: 'io' is not defined");
    try fixture.expectFailure("return os.getenv('HOME')", "kosmoi/mine.lua:1: 'os' is not defined");
    try fixture.expectFailure("return require('x')", "kosmoi/mine.lua:1: 'require' is not defined");
    try fixture.expectFailure("return dofile('/etc/passwd')", "kosmoi/mine.lua:1: 'dofile' is not defined");
    try fixture.expectFailure("return load('return 1')()", "kosmoi/mine.lua:1: 'load' is not defined");
}
