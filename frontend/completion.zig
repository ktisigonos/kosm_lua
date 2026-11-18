//! Completion for Lua kosmoi: LuaLS annotation files (`---@class`, `---@field`) for every type a
//! script may set, with the doc comments of their Zig sources, and the `.luarc.json` pointing
//! LuaLS at them.

const std = @import("std");
const kosm = @import("kosm");

const Completion = kosm.Frontend.Completion;

/// The config's `.luarc.json`: Lua 5.5 with only the libraries a kosmos has, reading the
/// annotations kosm writes, and never the build's own folders, which hold copies of them. The base library is off because LuaLS cannot drop single functions
/// of it; `kosm.lua` declares the ones a kosmos keeps.
pub const editor_file: Completion.File = .{
    .path = ".luarc.json",
    .contents =
    \\{
    \\    "$schema": "https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json",
    \\    "runtime.version": "Lua 5.5",
    \\    "runtime.builtin": {
    \\        "basic": "disable",
    \\        "debug": "disable",
    \\        "io": "disable",
    \\        "os": "disable",
    \\        "package": "disable"
    \\    },
    \\    "workspace.library": ["zig-out/completions/lua"],
    \\    "workspace.ignoreDir": [".zig-cache", "zig-pkg", "zig-out"]
    \\}
    \\
    ,
};

/// Writes `kosm.lua`, declaring the globals a kosmos has and a class per script shape, and
/// `types.lua`, a class per record.
pub fn complete(arena: std.mem.Allocator, completion: Completion) std.mem.Allocator.Error![]const Completion.File {
    var globals: std.Io.Writer.Allocating = .init(arena);
    writeGlobals(&globals.writer, completion) catch return error.OutOfMemory;
    var types: std.Io.Writer.Allocating = .init(arena);
    writeTypes(&types.writer, completion) catch return error.OutOfMemory;
    return arena.dupe(Completion.File, &.{
        .{ .path = "kosm.lua", .contents = globals.written() },
        .{ .path = "types.lua", .contents = types.written() },
    });
}

const header =
    \\---@meta
    \\-- Written by kosm from the config's Zig sources whenever it builds the runner of scripts;
    \\-- edits here are lost.
    \\
    \\
;

/// The base library without `dofile`, `loadfile`, `load` and `print`, which a kosmos lacks.
const base_library =
    \\---Raises an error with `message` unless `v` is true; returns its arguments.
    \\---@generic T
    \\---@param v? T
    \\---@param message? any
    \\---@return T
    \\function assert(v, message, ...) end
    \\
    \\---Stops the script with `message`, which kosm prints naming the script's line.
    \\---@param message any
    \\---@param level? integer
    \\function error(message, level) end
    \\
    \\---@param object any
    \\---@return table?
    \\function getmetatable(object) end
    \\
    \\---Iterates a list's items in order.
    \\---@generic V
    \\---@param t V[]
    \\---@return fun(t: V[], i?: integer): integer, V
    \\function ipairs(t) end
    \\
    \\---@param t table
    \\---@param index? any
    \\---@return any key
    \\---@return any value
    \\function next(t, index) end
    \\
    \\---Iterates every key and value of a table, in no order.
    \\---@generic K, V
    \\---@param t table<K, V>
    \\---@return fun(t: table<K, V>, k?: K): K, V
    \\function pairs(t) end
    \\
    \\---@param f function
    \\---@return boolean success
    \\---@return any ...
    \\function pcall(f, ...) end
    \\
    \\---@return boolean
    \\function rawequal(v1, v2) end
    \\
    \\---@param t table
    \\---@return any
    \\function rawget(t, index) end
    \\
    \\---@param v table|string
    \\---@return integer
    \\function rawlen(v) end
    \\
    \\---@param t table
    \\---@return table
    \\function rawset(t, index, value) end
    \\
    \\---@param index integer|"#"
    \\---@return any ...
    \\function select(index, ...) end
    \\
    \\---@generic T: table
    \\---@param t T
    \\---@param metatable? table
    \\---@return T
    \\function setmetatable(t, metatable) end
    \\
    \\---@param e any
    \\---@param base? integer
    \\---@return number?
    \\function tonumber(e, base) end
    \\
    \\---@param v any
    \\---@return string
    \\function tostring(v) end
    \\
    \\---@param v any
    \\---@return "nil"|"number"|"string"|"boolean"|"table"|"function"|"thread"|"userdata"
    \\function type(v) end
    \\
    \\---@param f function
    \\---@param handler function
    \\---@return boolean success
    \\---@return any ...
    \\function xpcall(f, handler, ...) end
    \\
    \\---@param ... string
    \\function warn(...) end
    \\
    \\---@param option? string
    \\---@return any
    \\function collectgarbage(option, ...) end
    \\
    \\---@type table
    \\_G = {}
    \\
    \\---@type string
    \\_VERSION = "Lua 5.5"
    \\
    \\---What kosm gives a kosmos.
    \\---@class kosm
    \\---@field null kosm.null Clears an optional field, so the program's own default applies.
    \\kosm = {}
    \\
    \\---Clears an optional field: `waybar = { spacing = kosm.null }`.
    \\---@class kosm.null
    \\
    \\
;

fn writeGlobals(writer: *std.Io.Writer, completion: Completion) std.Io.Writer.Error!void {
    try writer.writeAll(header);
    try writer.writeAll(base_library);
    try writer.print(
        \\---A kosmos building on no other: it gives a theme, and the apps its overrides name are the
        \\---ones applied. Write `---@type kosm.script` above its `return`.
        \\---@class kosm.script
        \\---@field theme? {s} What every app is built from.
        \\---@field overrides? {s} Values set on the apps; naming an app chooses it.
        \\
        \\
    , .{ completion.theme, completion.standalone });
    for (completion.kosmoi) |kosmos| {
        try writeDoc(writer, kosmos.doc);
        try writer.print(
            \\---A kosmos building on {s}. Write `---@type kosm.on.{s}` above its `return`.
            \\---@class kosm.on.{s}
            \\---@field base string The kosmos it builds on: "{s}", or a script building on it.
            \\
        , .{ kosmos.name, kosmos.name, kosmos.name, kosmos.name });
        if (kosmos.params) |params| try writer.print("---@field params? {s} Its parameters, below the command line's.\n", .{params});
        try writer.print("---@field overrides? {s} Values set on its tree.\n\n", .{kosmos.tree});
    }
}

fn writeTypes(writer: *std.Io.Writer, completion: Completion) std.Io.Writer.Error!void {
    try writer.writeAll(header);
    for (completion.records) |record| {
        try writeDoc(writer, record.doc);
        try writer.print("---@class {s}\n", .{record.name});
        for (record.fields) |field| {
            try writer.writeAll("---@field ");
            try writeFieldName(writer, field.name);
            try writer.writeAll("? ");
            try writeType(writer, field.type.?);
            if (field.doc) |doc| {
                try writer.writeByte(' ');
                try writeOneLine(writer, doc);
            }
            try writer.writeByte('\n');
        }
        try writer.writeByte('\n');
    }
}

/// A type as LuaLS spells it: `integer`, `"block"|"beam"`, `kosm_kitty.App[]`, `number|kosm.null`.
fn writeType(writer: *std.Io.Writer, field_type: Completion.Type) std.Io.Writer.Error!void {
    switch (field_type) {
        .boolean => try writer.writeAll("boolean"),
        .integer => try writer.writeAll("integer"),
        .number => try writer.writeAll("number"),
        .text, .color, .color_or_hue, .path => try writer.writeAll("string"),
        .value => try writer.writeAll("any"),
        .choice => |names| for (names, 0..) |name, index| {
            if (index != 0) try writer.writeByte('|');
            try writer.print("\"{s}\"", .{name});
        },
        .variant => |tags| for (tags, 0..) |tag, index| {
            if (index != 0) try writer.writeByte('|');
            if (tag.type) |payload| {
                try writer.writeAll("{ ");
                try writeFieldName(writer, tag.name);
                try writer.writeAll(": ");
                try writeType(writer, payload);
                try writer.writeAll(" }");
            } else {
                try writer.print("\"{s}\"", .{tag.name});
            }
        },
        .record => |name| try writer.writeAll(name),
        .list => |item| {
            const grouped = isUnion(item.*);
            if (grouped) try writer.writeByte('(');
            try writeType(writer, item.*);
            if (grouped) try writer.writeByte(')');
            try writer.writeAll("[]");
        },
        .optional => |child| {
            try writeType(writer, child.*);
            try writer.writeAll("|kosm.null");
        },
    }
}

/// Whether `field_type` is spelled with `|`, so a list of it needs parentheses.
fn isUnion(field_type: Completion.Type) bool {
    return switch (field_type) {
        .choice => |names| names.len > 1,
        .variant => |tags| tags.len > 1,
        .optional => true,
        else => false,
    };
}

/// Lua's reserved words, which a field is named by only in brackets: `["end"]`.
const reserved_words = [_][]const u8{
    "and",   "break", "do",    "else", "elseif", "end", "false",  "for",    "function", "global", "goto",
    "if",    "in",    "local", "nil",  "not",    "or",  "repeat", "return", "then",     "true",   "until",
    "while",
};

fn writeFieldName(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (reserved_words) |word| {
        if (std.mem.eql(u8, word, name)) return writer.print("[\"{s}\"]", .{name});
    }
    try writer.writeAll(name);
}

/// A doc comment as `---` lines above a declaration.
fn writeDoc(writer: *std.Io.Writer, doc: ?[]const u8) std.Io.Writer.Error!void {
    const text = doc orelse return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try writer.print("---{s}\n", .{line});
}

/// A doc comment on one line, for after a `---@field`, which ends at the line's end.
fn writeOneLine(writer: *std.Io.Writer, doc: []const u8) std.Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, doc, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!first) try writer.writeByte(' ');
        try writer.writeAll(line);
        first = false;
    }
}

const testing = std.testing;

test "records become classes with typed, documented fields, and kosmoi script classes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const number: Completion.Type = .number;
    const color: Completion.Type = .color;
    const shape: Completion.Type = .{ .choice = &.{ "block", "beam" } };
    const fonts: Completion.Type = .{ .record = "kosm_kitty.App.fonts" };
    const completion: Completion = .{
        .records = &.{
            .{ .name = "kosm_kitty.App", .doc = "kitty's settings.\nEvery option.", .fields = &.{
                .{ .name = "fonts", .doc = "Font settings.", .type = fonts },
                .{ .name = "sizes", .doc = "Point sizes,\nin order.", .type = .{ .list = &number } },
                .{ .name = "shapes", .type = .{ .list = &shape } },
                .{ .name = "border", .type = .{ .optional = &color } },
                .{ .name = "end", .type = .{ .variant = &.{ .{ .name = "disabled", .type = null }, .{ .name = "size", .type = .integer } } } },
            } },
        },
        .kosmoi = &.{
            .{ .name = "frost.iced", .doc = "A colder frost.", .params = "frost.Params", .tree = "frost.Tree" },
            .{ .name = "plain", .tree = "plain.Tree" },
        },
        .standalone = "kosm.Standalone",
        .theme = "kosm.Theme.Input",
    };
    const files = try complete(arena, completion);
    try testing.expectEqualStrings("kosm.lua", files[0].path);
    try testing.expectEqualStrings(header ++
        \\---kitty's settings.
        \\---Every option.
        \\---@class kosm_kitty.App
        \\---@field fonts? kosm_kitty.App.fonts Font settings.
        \\---@field sizes? number[] Point sizes, in order.
        \\---@field shapes? ("block"|"beam")[]
        \\---@field border? string|kosm.null
        \\---@field ["end"]? "disabled"|{ size: integer }
        \\
        \\
    , files[1].contents);
    const globals = files[0].contents;
    try testing.expect(std.mem.find(u8, globals, "function print") == null);
    try testing.expect(std.mem.find(u8, globals, "---@field theme? kosm.Theme.Input What every app is built from.\n---@field overrides? kosm.Standalone ") != null);
    try testing.expect(std.mem.find(u8, globals,
        \\---A colder frost.
        \\---A kosmos building on frost.iced. Write `---@type kosm.on.frost.iced` above its `return`.
        \\---@class kosm.on.frost.iced
        \\---@field base string The kosmos it builds on: "frost.iced", or a script building on it.
        \\---@field params? frost.Params Its parameters, below the command line's.
        \\---@field overrides? frost.Tree Values set on its tree.
        \\
    ) != null);
    try testing.expect(std.mem.find(u8, globals, "---@class kosm.on.plain\n---@field base string The kosmos it builds on: \"plain\", or a script building on it.\n---@field overrides? plain.Tree") != null);
}
