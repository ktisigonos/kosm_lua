//! Lua: set values by path in Lua files you write by hand (the `lua` adapter).

const std = @import("std");
const kosm = @import("kosm");

extern fn tree_sitter_lua() callconv(.c) *const kosm.treesitter.Language;

/// Edits `.lua` files through `output.edit` (D31, D39). A path matches however the file nests
/// it (D30): `M.blur = { enabled = true }`, `M.blur.enabled = true`, `local M = { ... }` and
/// `hl.config({ M = { blur = { enabled = true } } })` all hold `M.blur.enabled`. Code inside
/// function bodies runs later, not when the file loads, so paths never see it.
pub const adapter: kosm.Adapter = .{
    .name = "lua",
    .extensions = &.{".lua"},
    .default_format = .{ .boolean = .true_false },
    .comment = .{ .line = "--" },
    .format = format,
    .parser = kosm.treesitter.parser(tree_sitter_lua, .{
        .pair = "field",
        .key = "name",
        .value = "value",
        .nest = &.{"table_constructor"},
        .quoted_key = &.{"string"},
        .transparent = &.{ "function_call", "arguments", "variable_declaration" },
        .assign = .{
            .node = "assignment_statement",
            .targets = "variable_list",
            .target = "name",
            .values = "expression_list",
            .value = "value",
            .name = "identifier",
            .index = .{ .node = "dot_index_expression", .table = "table", .key = "field" },
        },
    }),
};

/// One value as Lua: strings and colors quoted and escaped, tables and lists on one line.
fn format(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string => |text| try writeString(writer, text),
        .raw => |text| try writer.writeAll(text),
        .joined => |parts| for (parts) |part| try format(writer, part, context),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| {
            if (!std.math.isFinite(float)) return context.unsupported("a Lua literal cannot be infinity or NaN; write kosm.raw(\"math.huge\") instead", .{});
            try context.writeFloat(writer, float);
        },
        .boolean => |boolean| {
            if (context.format.boolean != .true_false)
                return context.unsupported("Lua spells booleans only as true and false; leave format.boolean at .true_false", .{});
            try context.writeBoolean(writer, boolean);
        },
        .color => |color| {
            var buffer: [128]u8 = undefined;
            var color_writer: std.Io.Writer = .fixed(&buffer);
            context.writeColor(&color_writer, color) catch return context.unsupported("the color format prints more than {d} bytes", .{buffer.len});
            try writeString(writer, color_writer.buffered());
        },
        .list => |items| {
            if (items.len == 0) return writer.writeAll("{}");
            try writer.writeAll("{ ");
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(", ");
                try format(writer, item, context);
            }
            try writer.writeAll(" }");
        },
        .table => |entries| {
            if (entries.len == 0) return writer.writeAll("{}");
            try writer.writeAll("{ ");
            for (entries, 0..) |entry, index| {
                if (index != 0) try writer.writeAll(", ");
                if (isName(entry.key)) {
                    try writer.writeAll(entry.key);
                } else {
                    try writer.writeByte('[');
                    try writeString(writer, entry.key);
                    try writer.writeByte(']');
                }
                try writer.writeAll(" = ");
                try format(writer, entry.value, context);
            }
            try writer.writeAll(" }");
        },
    }
}

fn writeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |character| switch (character) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try writer.print("\\{d:0>3}", .{character}),
        else => try writer.writeByte(character),
    };
    try writer.writeByte('"');
}

const keywords = [_][]const u8{
    "and", "break", "do",  "else", "elseif", "end",    "false",  "for",  "function", "goto",  "if",
    "in",  "local", "nil", "not",  "or",     "repeat", "return", "then", "true",     "until", "while",
};

/// Whether `key` can be written bare (`size = 1`) rather than as `["key"] = 1`.
fn isName(key: []const u8) bool {
    if (key.len == 0 or std.ascii.isDigit(key[0])) return false;
    for (key) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
    }
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, key)) return false;
    }
    return true;
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    plan: kosm.Plan,
    diagnostics: kosm.Diagnostics = .{},
    warnings: kosm.Warnings = undefined,
    home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    output: kosm.Output = undefined,

    fn init(fixture: *Fixture, files: []const [2][]const u8) !void {
        fixture.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .plan = .init(testing.allocator, testing.io) };
        for (files) |file| {
            if (std.Io.Dir.path.dirname(file[0])) |parent| try fixture.tmp.dir.createDirPath(testing.io, parent);
            try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = file[0], .data = file[1] });
        }
        fixture.warnings = .init(fixture.arena.allocator());
        const length = try fixture.tmp.dir.realPath(testing.io, &fixture.home_buffer);
        fixture.output = .{
            .allocator = fixture.arena.allocator(),
            .home = fixture.home_buffer[0..length],
            .adapters = &.{adapter},
            .plan = &fixture.plan,
            .diagnostics = &fixture.diagnostics,
            .warnings = &fixture.warnings,
            .app = "hyprland",
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.plan.deinit();
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }

    fn planned(fixture: *Fixture, display_path: []const u8) []const u8 {
        for (fixture.plan.files.items) |file| {
            if (std.mem.eql(u8, file.display_path, display_path)) return file.new;
        }
        return "(not planned)";
    }
};

const defs =
    \\local utils = require("utils")
    \\
    \\local M = {}
    \\
    \\-- Main mod
    \\M.main_mod = "SUPER"
    \\
    \\-- Apps
    \\M.apps = {
    \\    terminal     = "ghostty",
    \\    browser      = "zen-browser",
    \\    file_manager = "yazi"
    \\}
    \\
    \\--[[ Opacity,
    \\     kept by kosm ]]
    \\M.opacity = {
    \\    active   = 1.0,
    \\    inactive = 1.0
    \\}
    \\
    \\M.border = {
    \\    rounding    = 10,
    \\    active_col  = "rgba(88c0d0ff)",
    \\}
    \\M.border.size = 1
    \\
    \\utils.deep_merge(M, require("def_overrides"))
    \\
    \\return M
    \\
;

test "set changes only the value's bytes in a defs file built from M.x = ... statements" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "hypr/defs.lua", defs }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/hypr/defs.lua" });
    try file.set("M.main_mod", "ALT");
    try file.set("M.apps.terminal", "kitty");
    try file.set(.{ "M", "opacity", "inactive" }, 0.9);
    try file.set("M.border.active_col", kosm.hex("#5e81ac").format("rgba({})", &.{.hex8}));
    try file.set("M.border.size", 2);
    try file.set("M.border.rounding", kosm.raw("utils.rounding"));

    try testing.expectEqualStrings(
        \\local utils = require("utils")
        \\
        \\local M = {}
        \\
        \\-- Main mod
        \\M.main_mod = "ALT"
        \\
        \\-- Apps
        \\M.apps = {
        \\    terminal     = "kitty",
        \\    browser      = "zen-browser",
        \\    file_manager = "yazi"
        \\}
        \\
        \\--[[ Opacity,
        \\     kept by kosm ]]
        \\M.opacity = {
        \\    active   = 1.0,
        \\    inactive = 0.9
        \\}
        \\
        \\M.border = {
        \\    rounding    = utils.rounding,
        \\    active_col  = "rgba(5e81acff)",
        \\}
        \\M.border.size = 2
        \\
        \\utils.deep_merge(M, require("def_overrides"))
        \\
        \\return M
        \\
    , fixture.planned("~/hypr/defs.lua"));
}

test "an unchanged value leaves the file unchanged" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "defs.lua", defs }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/defs.lua" });
    try file.set("M.main_mod", "SUPER");
    try file.set("M.border.size", 1);
    try testing.expect(!fixture.plan.hasChanges());
}

test "every way Lua nests a key matches the same path (D30)" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ "a/table.lua", "M.blur = { enabled = true, size = 8 }\n" },
        .{ "b/dotted.lua", "M.blur.enabled = true\n" },
        .{ "c/local.lua", "local M = { blur = { enabled = true } }\nreturn M\n" },
        .{ "d/call.lua", "hl.config({ M = { blur = { enabled = true } } })\n" },
        .{ "e/mixed.lua", "M = {}\nM.blur = {}\nM.blur.enabled = true\n" },
    });
    defer fixture.deinit();
    var files = try fixture.output.edit(.{ .files = "~/*/*.lua" });
    try testing.expectError(error.TooManyMatches, files.set("M.blur.enabled", false));
    try testing.expectEqualStrings("path 'M.blur.enabled' matches 5 values (~/a/table.lua:1, ~/b/dotted.lua:1, ~/c/local.lua:1, ~/d/call.lua:1, ~/e/mixed.lua:3); narrow .files, or pick with setFirst, setAll or setNth (D31)", fixture.diagnostics.message());
    try files.setAll("M.blur.enabled", false);

    try testing.expectEqualStrings("M.blur = { enabled = false, size = 8 }\n", fixture.planned("~/a/table.lua"));
    try testing.expectEqualStrings("M.blur.enabled = false\n", fixture.planned("~/b/dotted.lua"));
    try testing.expectEqualStrings("local M = { blur = { enabled = false } }\nreturn M\n", fixture.planned("~/c/local.lua"));
    try testing.expectEqualStrings("hl.config({ M = { blur = { enabled = false } } })\n", fixture.planned("~/d/call.lua"));
    try testing.expectEqualStrings("M = {}\nM.blur = {}\nM.blur.enabled = false\n", fixture.planned("~/e/mixed.lua"));
}

const general =
    \\local defs = require("defs")
    \\
    \\hl.config({
    \\    general = {
    \\        layout        = "scrolling",
    \\        border_size   = defs.border.size,
    \\
    \\        -- Border colors
    \\        col = {
    \\            inactive_border = defs.border.inactive_col,
    \\            active_border   = defs.border.active_col,
    \\        },
    \\        ["col.nogroup"] = "rgba(00000000)",
    \\        snap = { enabled = true, window_gap = 10 },
    \\    }
    \\})
    \\
;

const gamemode =
    \\hl.bind("SUPER + F1", function ()
    \\    local game_mode = (hl.get_config("animations.enabled") == false)
    \\    if game_mode then
    \\        hl.exec_cmd("hyprctl reload")
    \\        return
    \\    end
    \\    hl.config({
    \\        general = { gaps_in = 0, border_size = 0 },
    \\        decoration = { blur = { enabled = false } },
    \\    })
    \\end)
    \\
;

test "hl.config calls are transparent, and expressions are overwritten (D29)" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "hypr/general.lua", general }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/hypr/general.lua" });
    try file.set("general.border_size", 2);
    try file.set("general.col.active_border", "rgba(88c0d0ff)");
    try file.set("general.\"col.nogroup\"", "rgba(ffffffff)");
    try file.set("general.snap.window_gap", 5);
    try testing.expectError(error.NoMatch, file.set("hl.config", 1));

    try testing.expectEqualStrings(
        \\local defs = require("defs")
        \\
        \\hl.config({
        \\    general = {
        \\        layout        = "scrolling",
        \\        border_size   = 2,
        \\
        \\        -- Border colors
        \\        col = {
        \\            inactive_border = defs.border.inactive_col,
        \\            active_border   = "rgba(88c0d0ff)",
        \\        },
        \\        ["col.nogroup"] = "rgba(ffffffff)",
        \\        snap = { enabled = true, window_gap = 5 },
        \\    }
        \\})
        \\
    , fixture.planned("~/hypr/general.lua"));
}

test "code inside function bodies, such as keybind callbacks, is invisible to paths" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ "hypr/blur.lua", "hl.config({ decoration = { blur = { enabled = true } } })\n" },
        .{ "hypr/gamemode.lua", gamemode },
        .{ "hypr/utils.lua", "local M = {}\nfunction M.copy(original)\n    local duplicate = {}\n    return duplicate\nend\nM.f = function () M.x = 1 end\nreturn M\n" },
    });
    defer fixture.deinit();
    var files = try fixture.output.edit(.{ .files = "~/hypr/*.lua" });
    try files.set("decoration.blur.enabled", false);
    try testing.expectEqualStrings("hl.config({ decoration = { blur = { enabled = false } } })\n", fixture.planned("~/hypr/blur.lua"));
    try testing.expectError(error.NoMatch, files.set("general.gaps_in", 1));
    try testing.expectError(error.NoMatch, files.set("game_mode", 1));
    try testing.expectError(error.NoMatch, files.set("duplicate", 1));
    try testing.expectError(error.NoMatch, files.set("M.x", 1));
    try files.set("M.f", kosm.raw("nil"));
}

test "a table spelled only through dotted keys has no value to replace" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "defs.lua", "M.blur.enabled = true\nM.blur.size = 8\n" }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/defs.lua" });
    const blur = try file.nodes("M.blur");
    try testing.expectEqual(2, blur.len);
    try testing.expectEqual(null, blur[0].value);
    try testing.expectError(error.NoValue, file.setFirst("M.blur", .{ .enabled = false }));
    try testing.expectEqualStrings("line 1: this table is spelled only through dotted keys, so it has no value to replace; set its keys instead", fixture.diagnostics.message());
    try file.set("M.blur.size", 10);
    try testing.expectEqualStrings("M.blur.enabled = true\nM.blur.size = 10\n", fixture.planned("~/defs.lua"));
}

test "assignments pair targets with values, and skip targets whose key is unknown" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a.lua", "a, M.b, c = 1, 2\nM[key] = 3\nf().x = 4\nM.size = 5\nM.size = 6\n" }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/a.lua" });
    try file.set("a", 10);
    try file.set("M.b", 20);
    try testing.expectError(error.NoMatch, file.set("c", 1));
    try testing.expectError(error.NoMatch, file.set("M.key", 1));
    try testing.expectError(error.NoMatch, file.set("x", 1));
    try testing.expectError(error.TooManyMatches, file.set("M.size", 7));
    try file.setNth("M.size", 1, 7);
    try testing.expectEqualStrings("a, M.b, c = 10, 20\nM[key] = 3\nf().x = 4\nM.size = 5\nM.size = 7\n", fixture.planned("~/a.lua"));
}

test "edit refuses files that do not parse, naming the line" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "broken.lua", "M = {\n  a = 1,\n  b = = 2\n}\n" }});
    defer fixture.deinit();
    try testing.expectError(error.InvalidSyntax, fixture.output.edit(.{ .files = "~/broken.lua" }));
    try testing.expectEqualStrings("~/broken.lua", fixture.diagnostics.file);
    try testing.expectStringStartsWith(fixture.diagnostics.message(), "adapter 'lua': line 3, column ");
}

test "format quotes strings, spells tables and refuses what Lua cannot write" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a.lua", "M = { text = '', ratio = 1, nested = {}, empty = 0 }\n" }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/a.lua", .format = .{ .float_precision = 2 } });
    try file.set("M.text", "a\"b\\\n\u{1}");
    try file.set("M.ratio", 0.125);
    try file.set("M.nested", .{ .on = true, .names = .{ "x", "y" }, .end = 1, .@"col.x" = kosm.hex("#ff0000") });
    try file.set("M.empty", .{});
    try testing.expectEqualStrings("M = { text = \"a\\\"b\\\\\\n\\001\", ratio = 0.13, nested = { on = true, names = { \"x\", \"y\" }, [\"end\"] = 1, [\"col.x\"] = \"#ff0000\" }, empty = {} }\n", fixture.planned("~/a.lua"));

    try testing.expectError(error.UnsupportedValue, file.set("M.ratio", std.math.inf(f64)));
    var yes_no = try fixture.output.edit(.{ .files = "~/a.lua", .format = .{ .boolean = .yes_no } });
    try testing.expectError(error.UnsupportedValue, yes_no.set("M.ratio", true));
    try testing.expectEqualStrings("path 'M.ratio': adapter 'lua': Lua spells booleans only as true and false; leave format.boolean at .true_false", fixture.diagnostics.message());
}
