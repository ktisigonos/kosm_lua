//! Where each value of a script is written, from the Lua adapter's parse of it: Lua keeps no
//! position for a table's fields, so the frontend looks a value up by its path instead.

const Lines = @This();

const std = @import("std");
const kosm = @import("kosm");

extern fn tree_sitter_lua() callconv(.c) *const kosm.treesitter.Language;

source: []const u8,
/// The parsed script; null when tree-sitter could not read it (newer syntax than the
/// grammar's), so no value has a line of its own.
root: ?kosm.Adapter.Node,

/// The Lua adapter's node names, seeing into the `return` statement as well.
const parse = kosm.treesitter.parser(tree_sitter_lua, .{
    .pair = "field",
    .key = "name",
    .value = "value",
    .nest = &.{"table_constructor"},
    .list = &.{"table_constructor"},
    .quoted_key = &.{"string"},
    .transparent = &.{ "return_statement", "expression_list", "function_call", "arguments", "variable_declaration", "if_statement", "elseif_statement", "else_statement", "do_statement", "block" },
    .assign = .{
        .node = "assignment_statement",
        .targets = "variable_list",
        .target = "name",
        .values = "expression_list",
        .value = "value",
        .name = "identifier",
        .index = .{ .node = "dot_index_expression", .table = "table", .key = "field" },
    },
});

/// One step of a path: a field by name, or a list item from 1.
pub const Segment = union(enum) {
    key: []const u8,
    item: usize,
};

/// Parses `source`; everything it returns lives in `arena`.
pub fn init(arena: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Lines {
    var context: kosm.Adapter.Context = .{ .format = (kosm.Format{}).resolve() };
    const root = parse(arena, source, &context) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    return .{ .source = source, .root = root };
}

/// The line (from 1) where the value at `path` is written, or null when the script does not
/// spell it out (a value from a `local`, or computed), so it takes its parent's line.
pub fn find(lines: Lines, path: []const Segment) ?usize {
    if (path.len == 0) return null;
    return lines.line(lines.node(path) orelse return null);
}

/// The parsed node of the value at `path`, as `find` locates it.
pub fn node(lines: Lines, path: []const Segment) ?kosm.Adapter.Node {
    var found = lines.root orelse return null;
    for (path) |segment| found = child(found, segment) orelse return null;
    return found;
}

/// The line (from 1) `found` starts on.
pub fn line(lines: Lines, found: kosm.Adapter.Node) usize {
    return 1 + std.mem.countScalar(u8, lines.source[0..found.position], '\n');
}

/// The child of `node` that `segment` names; the last one wins, as the last assignment does.
fn child(parent: kosm.Adapter.Node, segment: Segment) ?kosm.Adapter.Node {
    var found: ?kosm.Adapter.Node = null;
    var items: usize = 0;
    for (parent.children) |candidate| switch (segment) {
        .key => |key| if (candidate.key) |candidate_key| {
            if (std.mem.eql(u8, candidate_key, key)) found = candidate;
        },
        .item => |position| if (candidate.key == null) {
            items += 1;
            if (items == position) return candidate;
        },
    };
    return found;
}

const testing = std.testing;

test "a value is found on the line its field is written, inside the returned table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\local unused = { overrides = 1 }
        \\return {
        \\    base = "personal",
        \\    overrides = {
        \\        kitty = { font_size = 11.5 },
        \\        hyprland = {
        \\            general = { gaps_in = 4 },
        \\        },
        \\        rofi = { modes = { "drun", "run" } },
        \\    },
        \\}
    ;
    const lines: Lines = try .init(arena.allocator(), source);
    try testing.expectEqual(3, lines.find(&.{.{ .key = "base" }}));
    try testing.expectEqual(5, lines.find(&.{ .{ .key = "overrides" }, .{ .key = "kitty" }, .{ .key = "font_size" } }));
    try testing.expectEqual(7, lines.find(&.{ .{ .key = "overrides" }, .{ .key = "hyprland" }, .{ .key = "general" }, .{ .key = "gaps_in" } }));
    try testing.expectEqual(9, lines.find(&.{ .{ .key = "overrides" }, .{ .key = "rofi" }, .{ .key = "modes" }, .{ .item = 2 } }));
    try testing.expectEqual(null, lines.find(&.{ .{ .key = "overrides" }, .{ .key = "kitty" }, .{ .key = "missing" } }));
}

test "a value held by a local has no line of its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\local kitty = { font_size = 11.5 }
        \\return { overrides = {
        \\    kitty = kitty,
        \\} }
    ;
    const lines: Lines = try .init(arena.allocator(), source);
    try testing.expectEqual(3, lines.find(&.{ .{ .key = "overrides" }, .{ .key = "kitty" } }));
    try testing.expectEqual(null, lines.find(&.{ .{ .key = "overrides" }, .{ .key = "kitty" }, .{ .key = "font_size" } }));
}
