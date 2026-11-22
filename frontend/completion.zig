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
pub fn complete(context: *kosm.Frontend.Context, completion: Completion) kosm.Frontend.Error![]const Completion.File {
    const arena = context.arena;
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
    \\---Clears an optional field: `waybar = { spacing = kosm.null }`.
    \\---@class kosm.null
    \\
    \\---The type of a field of an app written in Lua. Call a boolean, integer, float or text one
    \\---with the field's default: `bars = kosm.integer(0)`.
    \\---@class kosm.type
    \\---@overload fun(default: boolean|number|string): kosm.type
    \\
    \\---An app written in Lua, as its script returns it. Write `---@type kosm.app` above its
    \\---`return`, and `---@param self <name>.App` above `apply` to complete its fields.
    \\---@class kosm.app
    \\---@field App? table<string, kosm.type|table> The app's fields by name, each with its type: `bars = kosm.integer(0)`, `foreground = kosm.optional(kosm.Color)`. A `---` comment above a field documents it.
    \\---@field from? fun(theme: kosm.Theme): table The app built from the theme: a table of the fields it sets. Without it the app starts from its defaults.
    \\---@field apply fun(self: any, output: kosm.Output) Writes the app's files through `output`.
    \\---@field reload? fun(self: any, reloader: kosm.Reloader) Tells the program to read its files again.
    \\
    \\---A modifier written in Lua, in `colors/`. Write `---@type kosm.modifier` above its `return`,
    \\---and `---@param self <name>.Modifier` above `apply` to complete its fields.
    \\---@class kosm.modifier
    \\---@field Modifier table<string, kosm.type|table> The modifier's fields by name, each with its type: `amount = kosm.float(0.5)`.
    \\---@field apply fun(self: any, color: kosm.Color): kosm.Color The color changed.
    \\
    \\---A palette style written in Lua, in `colors/`. Write `---@type kosm.style` above its
    \\---`return`, and `---@param self <name>.Style` above `apply` to complete its fields.
    \\---@class kosm.style
    \\---@field Style table<string, kosm.type|table> The style's fields by name, each with its type: `chroma = kosm.float(0.6)`.
    \\---@field apply fun(self: any, hue: kosm.Color, background: kosm.Color): kosm.Color The final color of a hue taken from an image; `kosm.Image.readable` keeps it readable on the background.
    \\
    \\---A value a package's root script exports, made by `kosm.value` or `kosm.takes`.
    \\---@class kosm.export
    \\
    \\---A variation family written in Lua, in `colors/`. Write `---@type kosm.family` above its
    \\---`return`.
    \\---@class kosm.family
    \\---@field Family table<string, kosm.type|table> The family's modifiers by name: `soft = kosm.Modifier`.
    \\---@field from fun(mode: "dark"|"light"): table The family's modifiers for a mode: a table of the fields it sets.
    \\
    \\
;

/// The prefix of the class of each namespace of the library: `kosm.library.kosm_kitty`.
const namespace_prefix = "kosm.library.";

fn writeGlobals(writer: *std.Io.Writer, completion: Completion) std.Io.Writer.Error!void {
    try writer.writeAll(header);
    try writer.writeAll(base_library);
    const has_kosm = for (completion.namespaces) |namespace| {
        if (std.mem.eql(u8, namespace.name, "kosm")) break true;
    } else false;
    try writer.print(
        \\---What kosm gives a kosmos.
        \\---@class kosm{s}{s}
        \\---@field null kosm.null Clears an optional field, so the program's own default applies.
        \\---@field at fun(place: string, value: any): any `value`, written at `place` (`"kosmoi/mine.json:3"`), which kosm's messages about it name. For frontends written in Lua.
        \\---@field boolean kosm.type An app's field holding true or false: `kosm.boolean(true)`.
        \\---@field integer kosm.type An app's field holding a whole number: `kosm.integer(0)`.
        \\---@field float kosm.type An app's field holding a number: `kosm.float(1.5)`.
        \\---@field text kosm.type An app's field holding a string: `kosm.text("bars")`.
        \\---@field optional fun(child: kosm.type|table): kosm.type An app's field that may be null, its default: `kosm.optional(kosm.Color)`.
        \\---@field list fun(item: kosm.type|table): kosm.type An app's field holding a list, empty by default: `kosm.list(kosm.Color)`.
        \\---@field value fun(type: any, build: fun(): any): kosm.export A value a package's root script exports, of a Zig type, built by `build` whenever it is used: `look = kosm.value(kosm_base.Look, function() ... end)`, or the package's kosmos: `kosmos = kosm.value(Base, function() ... end)`.
        \\---@field takes fun(...: any): kosm.export A base's `from`: the Zig type of each parameter, then the function giving the base: `from = kosm.takes(kosm_base.Look, function(look) ... end)`.
        \\kosm = {{}}
        \\
        \\
    , .{ if (has_kosm) ": " ++ namespace_prefix else "", if (has_kosm) "kosm" else "" });
    try writeNamespaces(writer, completion);
    try writeKosmoi(writer, completion);
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

/// A class per namespace, and a global for each without a dot but `kosm`.
fn writeNamespaces(writer: *std.Io.Writer, completion: Completion) std.Io.Writer.Error!void {
    for (completion.namespaces) |namespace| {
        try writeDoc(writer, namespace.doc);
        try writer.print("---@class {s}{s}\n", .{ namespace_prefix, namespace.name });
        if (namespace.call) |call| {
            try writer.writeAll("---@overload ");
            try writeFunction(writer, completion, call);
            try writer.writeByte('\n');
        }
        for (namespace.functions) |function| {
            try writer.writeAll("---@field ");
            try writeFieldName(writer, function.name);
            try writer.writeByte(' ');
            try writeFunction(writer, completion, function);
            try writeTrailingDoc(writer, function.doc);
        }
        for (namespace.values) |value| {
            try writer.writeAll("---@field ");
            try writeFieldName(writer, value.name);
            try writer.writeByte(' ');
            try writeType(writer, completion, value.type.?);
            try writeTrailingDoc(writer, value.doc);
        }
        try writer.writeByte('\n');
        if (std.mem.findScalar(u8, namespace.name, '.') == null and !std.mem.eql(u8, namespace.name, "kosm")) {
            try writer.print("---@type {s}{s}\n{s} = {{}}\n\n", .{ namespace_prefix, namespace.name, namespace.name });
        }
    }
}

/// `kosmoi`: each Zig kosmos a function of its parameters giving its tree, each group of
/// variants a class, callable when the group is a kosmos itself.
fn writeKosmoi(writer: *std.Io.Writer, completion: Completion) std.Io.Writer.Error!void {
    try writeKosmoiGroup(writer, completion, "");
    try writer.print("---Every Zig kosmos of the config, called with its parameters: `kosmoi.personal()`.\n---@type {s}kosmoi\nkosmoi = {{}}\n\n", .{namespace_prefix});
}

fn writeKosmoiGroup(writer: *std.Io.Writer, completion: Completion, group: []const u8) std.Io.Writer.Error!void {
    if (group.len == 0) {
        try writer.print("---@class {s}kosmoi\n", .{namespace_prefix});
    } else {
        if (findKosmos(completion, group)) |kosmos| try writeDoc(writer, kosmos.doc);
        try writer.print("---@class {s}kosmoi.{s}\n", .{ namespace_prefix, group });
        if (findKosmos(completion, group)) |kosmos| {
            try writer.writeAll("---@overload ");
            try writeKosmosFunction(writer, kosmos);
            try writer.writeByte('\n');
        }
    }
    // Each direct child once: the first kosmos naming it.
    for (completion.kosmoi, 0..) |kosmos, index| {
        const child = childOf(group, kosmos.name) orelse continue;
        const seen = for (completion.kosmoi[0..index]) |earlier| {
            const other = childOf(group, earlier.name) orelse continue;
            if (std.mem.eql(u8, other, child)) break true;
        } else false;
        if (seen) continue;
        const child_name = kosmos.name[0 .. (if (group.len == 0) 0 else group.len + 1) + child.len];
        try writer.writeAll("---@field ");
        try writeFieldName(writer, child);
        if (isGroup(completion, child_name)) {
            try writer.print(" {s}kosmoi.{s}\n", .{ namespace_prefix, child_name });
        } else {
            try writer.writeByte(' ');
            try writeKosmosFunction(writer, findKosmos(completion, child_name).?);
            try writeTrailingDoc(writer, findKosmos(completion, child_name).?.doc);
        }
    }
    try writer.writeByte('\n');
    for (completion.kosmoi, 0..) |kosmos, index| {
        const child = childOf(group, kosmos.name) orelse continue;
        const child_name = kosmos.name[0 .. (if (group.len == 0) 0 else group.len + 1) + child.len];
        const seen = for (completion.kosmoi[0..index]) |earlier| {
            const other = childOf(group, earlier.name) orelse continue;
            if (std.mem.eql(u8, other, child)) break true;
        } else false;
        if (!seen and isGroup(completion, child_name)) try writeKosmoiGroup(writer, completion, child_name);
    }
}

/// The name of the child of `group` that `name` is or lies in, or null when it is outside it.
fn childOf(group: []const u8, name: []const u8) ?[]const u8 {
    var rest = name;
    if (group.len != 0) {
        if (!std.mem.startsWith(u8, name, group) or name.len <= group.len or name[group.len] != '.') return null;
        rest = name[group.len + 1 ..];
    }
    return rest[0 .. std.mem.findScalar(u8, rest, '.') orelse rest.len];
}

fn isGroup(completion: Completion, name: []const u8) bool {
    for (completion.kosmoi) |kosmos| {
        if (kosmos.name.len > name.len and std.mem.startsWith(u8, kosmos.name, name) and kosmos.name[name.len] == '.') return true;
    }
    return false;
}

fn findKosmos(completion: Completion, name: []const u8) ?Completion.Kosmos {
    for (completion.kosmoi) |kosmos| {
        if (std.mem.eql(u8, kosmos.name, name)) return kosmos;
    }
    return null;
}

fn writeKosmosFunction(writer: *std.Io.Writer, kosmos: Completion.Kosmos) std.Io.Writer.Error!void {
    if (kosmos.params) |params| return writer.print("fun(params?: {s}): {s}", .{ params, kosmos.tree });
    try writer.print("fun(): {s}", .{kosmos.tree});
}

/// `fun(theme: kosm.Theme): kosm_kitty.App`.
fn writeFunction(writer: *std.Io.Writer, completion: Completion, function: Completion.Function) std.Io.Writer.Error!void {
    try writer.writeAll("fun(");
    for (function.parameters, 0..) |parameter, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeParameterName(writer, parameter.name);
        try writer.writeAll(": ");
        if (parameter.type) |parameter_type| try writeType(writer, completion, parameter_type) else try writer.writeAll("any");
    }
    try writer.writeByte(')');
    if (function.result) |result| {
        try writer.writeAll(": ");
        try writeType(writer, completion, result);
    }
}

/// `function record:name(...) end` with its doc, parameters and result; the first parameter
/// is the value itself. A color field is spelled `string|kosm.Color`, though reading one always
/// gives a `kosm.Color`, so a color's methods take that spelling as `self`.
fn writeMethod(writer: *std.Io.Writer, completion: Completion, record: []const u8, method: Completion.Function) std.Io.Writer.Error!void {
    try writeDoc(writer, method.doc);
    if (std.mem.eql(u8, record, "kosm.Color")) {
        try writer.writeAll("---@param self ");
        try writeType(writer, completion, .color);
        try writer.writeByte('\n');
    }
    const rest = if (method.parameters.len == 0) method.parameters else method.parameters[1..];
    for (rest) |parameter| {
        try writer.writeAll("---@param ");
        try writeParameterName(writer, parameter.name);
        try writer.writeByte(' ');
        if (parameter.type) |parameter_type| try writeType(writer, completion, parameter_type) else try writer.writeAll("any");
        try writer.writeByte('\n');
    }
    if (method.result) |result| {
        try writer.writeAll("---@return ");
        try writeType(writer, completion, result);
        try writer.writeByte('\n');
    }
    // `record:end()` does not parse, so a reserved name is a field holding the function.
    if (isReserved(method.name)) {
        try writer.print("record[\"{s}\"] = function(self", .{method.name});
        for (rest) |parameter| {
            try writer.writeAll(", ");
            try writeParameterName(writer, parameter.name);
        }
    } else {
        try writer.print("function record:{s}(", .{method.name});
        for (rest, 0..) |parameter, index| {
            if (index != 0) try writer.writeAll(", ");
            try writeParameterName(writer, parameter.name);
        }
    }
    try writer.writeAll(") end\n\n");
}

/// A doc after a `---@field` on its line, then the line's end.
fn writeTrailingDoc(writer: *std.Io.Writer, doc: ?[]const u8) std.Io.Writer.Error!void {
    if (doc) |text| {
        try writer.writeByte(' ');
        try writeOneLine(writer, text);
    }
    try writer.writeByte('\n');
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
            try writeType(writer, completion, field.type.?);
            try writeTrailingDoc(writer, field.doc);
        }
        if (record.methods.len != 0) {
            // Methods are functions of the class, not fields, so a table of the record's
            // fields misses none of them.
            try writer.writeAll("local record = {}\n\n");
            for (record.methods) |method| try writeMethod(writer, completion, record.name, method);
        }
        try writer.writeByte('\n');
    }
}

/// A type as LuaLS spells it: `integer`, `"block"|"beam"`, `kosm_kitty.App[]`, `number|kosm.null`.
/// A color reads back as a `kosm.Color` from Zig, when the completion describes that class.
fn writeType(writer: *std.Io.Writer, completion: Completion, field_type: Completion.Type) std.Io.Writer.Error!void {
    switch (field_type) {
        .boolean => try writer.writeAll("boolean"),
        .integer => try writer.writeAll("integer"),
        .number => try writer.writeAll("number"),
        .text, .path => try writer.writeAll("string"),
        .color, .color_or_hue => try writer.writeAll(if (completion.find("kosm.Color") != null) "string|kosm.Color" else "string"),
        .namespace => |name| try writer.print("{s}{s}", .{ namespace_prefix, name }),
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
                try writeType(writer, completion, payload);
                try writer.writeAll(" }");
            } else {
                try writer.print("\"{s}\"", .{tag.name});
            }
        },
        .record => |name| try writer.writeAll(name),
        .list => |item| {
            const grouped = isUnion(item.*);
            if (grouped) try writer.writeByte('(');
            try writeType(writer, completion, item.*);
            if (grouped) try writer.writeByte(')');
            try writer.writeAll("[]");
        },
        .optional => |child| {
            try writeType(writer, completion, child.*);
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

fn isReserved(name: []const u8) bool {
    for (reserved_words) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

fn writeFieldName(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    if (isReserved(name)) return writer.print("[\"{s}\"]", .{name});
    try writer.writeAll(name);
}

/// A parameter named by a reserved word gets a `_` after it: `end_`.
fn writeParameterName(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(name);
    if (isReserved(name)) try writer.writeByte('_');
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
    var context: kosm.Frontend.Context = .{ .arena = arena, .path = "lua" };
    const files = try complete(&context, completion);
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

test "namespaces, kosmoi and methods become classes, globals and function fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const app: Completion.Type = .{ .record = "kosm_kitty.App" };
    const theme: Completion.Type = .{ .record = "kosm.Theme" };
    const completion: Completion = .{
        .records = &.{
            .{ .name = "kosm.Color", .fields = &.{}, .methods = &.{.{ .name = "mix", .doc = "Mixes two colors.", .parameters = &.{ .{ .name = "color", .type = .color }, .{ .name = "other", .type = .color } }, .result = .color }} },
        },
        .kosmoi = &.{
            .{ .name = "personal", .doc = "My own.", .params = "personal.Params", .tree = "personal.Apps" },
            .{ .name = "personal.light", .tree = "personal.Apps" },
            .{ .name = "frost.iced", .tree = "frost.Tree" },
        },
        .standalone = "kosm.Standalone",
        .theme = "kosm.Theme.Input",
        .namespaces = &.{
            .{ .name = "kosm", .values = &.{.{ .name = "Theme", .type = .{ .namespace = "kosm.Theme" } }} },
            .{ .name = "kosm.Theme", .functions = &.{.{ .name = "from", .parameters = &.{.{ .name = "input", .type = .{ .record = "kosm.Theme.Input" } }}, .result = theme }} },
            .{ .name = "kosm_kitty", .doc = "kitty.", .functions = &.{.{ .name = "from", .doc = "kitty from a theme.", .parameters = &.{.{ .name = "theme", .type = theme }}, .result = app }}, .values = &.{.{ .name = "default", .type = app }} },
        },
    };
    var context: kosm.Frontend.Context = .{ .arena = arena, .path = "lua" };
    const files = try complete(&context, completion);
    const globals = files[0].contents;
    const expected = [_][]const u8{
        "---@class kosm: kosm.library.kosm\n",
        "---@class kosm.library.kosm.Theme\n---@field from fun(input: kosm.Theme.Input): kosm.Theme\n",
        "---kitty.\n---@class kosm.library.kosm_kitty\n---@field from fun(theme: kosm.Theme): kosm_kitty.App kitty from a theme.\n---@field default kosm_kitty.App\n\n---@type kosm.library.kosm_kitty\nkosm_kitty = {}\n",
        "---@class kosm.library.kosmoi\n---@field personal kosm.library.kosmoi.personal\n---@field frost kosm.library.kosmoi.frost\n",
        "---My own.\n---@class kosm.library.kosmoi.personal\n---@overload fun(params?: personal.Params): personal.Apps\n---@field light fun(): personal.Apps\n",
        "---@class kosm.library.kosmoi.frost\n---@field iced fun(): frost.Tree\n",
        "---@type kosm.library.kosmoi\nkosmoi = {}\n",
    };
    for (expected) |part| {
        if (std.mem.find(u8, globals, part) == null) {
            std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ part, globals });
            return error.TestMissingAnnotation;
        }
    }
    try testing.expect(std.mem.find(u8, globals, "\nkosm = {}") != null);
    try testing.expect(std.mem.find(u8, files[1].contents, "---@class kosm.Color\nlocal record = {}\n\n---Mixes two colors.\n---@param self string|kosm.Color\n---@param other string|kosm.Color\n---@return string|kosm.Color\nfunction record:mix(other) end\n") != null);
}

test "names Lua reserves are spelled so Lua reads them: end_ for a parameter, a field for a method" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const completion: Completion = .{
        .records = &.{
            .{ .name = "kosm.Span", .fields = &.{}, .methods = &.{
                .{ .name = "end", .parameters = &.{ .{ .name = "span", .type = .integer }, .{ .name = "until", .type = .integer } } },
                .{ .name = "grow", .parameters = &.{ .{ .name = "span", .type = .integer }, .{ .name = "and", .type = .integer } } },
            } },
        },
        .kosmoi = &.{},
        .standalone = "kosm.Standalone",
        .theme = "kosm.Theme.Input",
        .namespaces = &.{
            .{ .name = "kosm_span", .functions = &.{.{ .name = "cut", .parameters = &.{.{ .name = "end", .type = .integer }} }} },
        },
    };
    var context: kosm.Frontend.Context = .{ .arena = arena, .path = "lua" };
    const files = try complete(&context, completion);
    const expected = [_][]const u8{
        "---@field cut fun(end_: integer)\n",
        "---@param until_ integer\nrecord[\"end\"] = function(self, until_) end\n",
        "---@param and_ integer\nfunction record:grow(and_) end\n",
    };
    for (expected) |text| {
        if (std.mem.find(u8, files[0].contents, text) == null and std.mem.find(u8, files[1].contents, text) == null) {
            std.debug.print("missing:\n{s}\nin:\n{s}\n{s}\n", .{ text, files[0].contents, files[1].contents });
            return error.TestExpectedEqual;
        }
    }
}
