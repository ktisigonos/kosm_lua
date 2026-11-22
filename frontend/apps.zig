//! Apps, modifiers, palette styles and variation families written in Lua: what a script
//! declares, read while kosm builds the config, and its functions, run in the one interpreter
//! every script shares. An app's script returns `{ App = { field = kosm.integer(0), ... },
//! from = function(theme) ... end, apply = function(self, output) ... end,
//! reload = function(self, reloader) ... end }`; a modifier's `{ Modifier = { ... },
//! apply = function(self, color) ... end }`; a palette style's `{ Style = { ... },
//! apply = function(self, hue, background) ... end }`; a family's
//! `{ Family = { soft = kosm.Modifier, ... }, from = function(mode) ... end }`.

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
/// The registry name of the metatable of what `kosm.value` and `kosm.takes` return.
const export_metatable = "kosm.export";
/// The registry field holding, by each script's path, the functions the values it exports gave
/// by their place ("look.tweak").
pub const functions_field = "kosm.functions";
/// The registry field holding each app or adapter script's returned table by its path.
const apps_field = "kosm.apps";

/// How deep a field's types may nest (`kosm.list(kosm.optional(...))`).
const max_depth = 16;

/// What an app's or a modifier's script returns: the table of its fields and the functions it
/// may give.
const Shape = struct {
    /// The key of the table of fields: "App".
    fields: [:0]const u8,
    /// The functions the script may give.
    functions: []const []const u8,
    /// What the returned table holds, for messages: "App, from, apply and maybe reload".
    holds: []const u8,
    /// Whose script it is, for messages: "an app's".
    whose: []const u8,
};

const app_shape: Shape = .{ .fields = "App", .functions = &.{ "from", "apply", "reload" }, .holds = "App, from, apply and maybe reload", .whose = "an app's" };
const modifier_shape: Shape = .{ .fields = "Modifier", .functions = &.{"apply"}, .holds = "Modifier and apply", .whose = "a modifier's" };
const style_shape: Shape = .{ .fields = "Style", .functions = &.{"apply"}, .holds = "Style and apply", .whose = "a palette style's" };
const base_shape: Shape = .{ .fields = "Base", .functions = &.{}, .holds = "Base, from and its values as kosm.value(T, function() ... end)", .whose = "a package's" };
const family_shape: Shape = .{ .fields = "Family", .functions = &.{"from"}, .holds = "Family and from", .whose = "a variation family's" };
/// The most functions any shape gives.
const max_functions = 3;

/// Gives `kosm` the constructors of field types and of exported values, run with `kosm`, the
/// three metatables and whether kosm is reading a declaration. While it reads one no Zig code runs, so every other
/// name a script reaches (`kosm.Color`, `kosm_cursor.App`) stands for the Zig type of that name.
const prelude =
    \\local kosm, type_metatable, reference_metatable, export_metatable, declaring = ...
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
    \\rawset(kosm, "default", function(of, value)
    \\    if not isType(of) then
    \\        error("kosm.default takes a Zig type, then its default: kosm.default(kosm.Image, { path = \"~/Pictures\" })", 2)
    \\    end
    \\    if type(value) ~= "table" then
    \\        error("kosm.default takes the default as a table after the type: kosm.default(kosm.Image, { path = \"~/Pictures\" })", 2)
    \\    end
    \\    return setmetatable({ kind = "default", child = of, default = value }, type_metatable)
    \\end)
    \\rawset(kosm, "kosmos", function(tree, name)
    \\    if type(tree) ~= "table" or type(name) ~= "string" then
    \\        error("kosm.kosmos takes the type of the tree, a struct the script declares, then the kosmos it names by default: kosm.kosmos(Base, \"personal.nord\")", 2)
    \\    end
    \\    return setmetatable({ kind = "kosmos", tree = tree, default = { name = name } }, type_metatable)
    \\end)
    \\rawset(kosm, "value", function(of, build)
    \\    if of == nil then
    \\        error("kosm.value takes the value's Zig type, then the function building it: kosm.value(kosm_base.Look, function() ... end)", 2)
    \\    end
    \\    if type(build) ~= "function" then
    \\        error("kosm.value takes the function building the value after its type: kosm.value(kosm_base.Look, function() ... end)", 2)
    \\    end
    \\    return setmetatable({ kind = "value", type = of, build = build }, export_metatable)
    \\end)
    \\rawset(kosm, "takes", function(...)
    \\    local count = select("#", ...)
    \\    local build = select(count, ...)
    \\    if count < 2 or type(build) ~= "function" then
    \\        error("kosm.takes takes the Zig type of each parameter, then the function: kosm.takes(kosm_base.Look, function(look) ... end)", 2)
    \\    end
    \\    local types = { ... }
    \\    types[count] = nil
    \\    return setmetatable({ kind = "takes", types = types, build = build }, export_metatable)
    \\end)
    \\if declaring then
    \\    local function reference(name)
    \\        return setmetatable({ name = name }, reference_metatable)
    \\    end
    \\    reference_metatable.__index = function(self, key)
    \\        return reference(rawget(self, "name") .. "." .. key)
    \\    end
    \\    reference_metatable.__call = function(self)
    \\        error("'" .. rawget(self, "name") .. "' is called while kosm reads what the script declares, when no Zig code runs; call it inside a function the script gives", 2)
    \\    end
    \\    setmetatable(kosm, { __index = function(_, key) return reference("kosm." .. key) end })
    \\    setmetatable(_G, { __index = function(_, name) return reference(name) end })
    \\end
;

/// Reads what the app script `source` declares, without calling any of its functions.
pub fn declare(context: *Context, source: []const u8) Error!Declaration {
    return declareShaped(context, source, app_shape);
}

/// Reads what the modifier script `source` declares, without calling any of its functions.
pub fn declareModifier(context: *Context, source: []const u8) Error!Declaration {
    return declareShaped(context, source, modifier_shape);
}

/// Reads what the palette style script `source` declares, without calling any of its functions.
pub fn declareStyle(context: *Context, source: []const u8) Error!Declaration {
    return declareShaped(context, source, style_shape);
}

/// Reads what the variation family script `source` declares, without calling any of its
/// functions.
pub fn declareFamily(context: *Context, source: []const u8) Error!Declaration {
    return declareShaped(context, source, family_shape);
}

fn declareShaped(context: *Context, source: []const u8, shape: Shape) Error!Declaration {
    const interpreter = try Interpreter.init();
    defer interpreter.deinit();
    try installPrelude(interpreter, context, true);
    const chunk_name = try chunkName(context);
    if (interpreter.run(source, chunk_name)) |message| return context.fail("{s}", .{message});
    var reader: Reader = .{ .context = context, .interpreter = interpreter, .lines = try .init(context.arena, source), .source = source, .shape = shape };
    return reader.declaration();
}

/// Reads what a package's root script `source` exports: each value it gives as
/// `kosm.value(T, function() ... end)`, and a base declared as `Base = { ... }` with
/// `from = kosm.takes(T, function(look) ... end)`, without calling any of their functions.
pub fn declareExports(context: *Context, source: []const u8) Error!kosm.Frontend.ExportsDeclaration {
    const interpreter = try Interpreter.init();
    defer interpreter.deinit();
    try installPrelude(interpreter, context, true);
    if (interpreter.run(source, try chunkName(context))) |message| return context.fail("{s}", .{message});
    var reader: Reader = .{ .context = context, .interpreter = interpreter, .lines = try .init(context.arena, source), .source = source, .shape = base_shape };
    return reader.exports();
}

/// Says whether the script `source` gives an app (its table holds `App`), a modifier
/// (`Modifier`), a palette style (`Style`), a variation family (`Family`), a frontend (`load`),
/// values for building on (`Base`, or a value of `kosm.value` or `kosm.takes`), an adapter
/// (`name` or `extensions`, with none of them) or a kosmos (none of these), without calling any
/// of its functions.
pub fn declares(context: *Context, source: []const u8) Error!kosm.Frontend.Declared {
    const interpreter = try Interpreter.init();
    defer interpreter.deinit();
    try installPrelude(interpreter, context, true);
    if (interpreter.run(source, try chunkName(context))) |message| return context.fail("{s}", .{message});
    if (interpreter.kind(-1) != .table) return context.fail("{s} returns {s}; the script returns the table of an app, a modifier, a palette style, a variation family, an adapter, a frontend or a kosmos", .{ context.path, Interpreter.describe(interpreter.kind(-1)) });
    try interpreter.reserve(2);
    const keys = [_][:0]const u8{ "App", "Modifier", "Style", "Family", "load" };
    const kinds = [_]kosm.Frontend.Declared{ .app, .modifier, .style, .family, .frontend };
    var found: ?usize = null;
    for (keys, 0..) |key, position| {
        if (!holds(interpreter, key)) continue;
        if (found) |first| return context.fail("{s} returns a table holding both {s} and {s}; an app's holds App, a modifier's Modifier, a palette style's Style, a family's Family, a frontend's load, so it is one of them", .{ context.path, keys[first], key });
        found = position;
    }
    if (found) |position| return kinds[position];
    if (holds(interpreter, base_key) or holdsExport(interpreter)) return .exports;
    if (holds(interpreter, "name") or holds(interpreter, "extensions")) return .adapter;
    // An app's function without its fields is a broken app far more likely than a kosmos'
    // variant named so.
    if (holds(interpreter, "apply")) return context.fail("{s} returns a table holding apply but none of App, Modifier or Style: an app's holds App, a modifier's Modifier, a palette style's Style", .{context.path});
    // A kosmos' table holds what it builds on and sets (`base`, `overrides`), or its variants.
    return .kosmos;
}

/// Gives a kosmos script, run on `interpreter`, the constructors of exported values, so that one
/// exporting values runs to its end and `refuseExports` can say why it is read as a kosmos.
pub fn installExports(interpreter: Interpreter, context: *Context) Error!void {
    try installPrelude(interpreter, context, false);
}

/// Fails when the kosmos script `source`, whose table is on top of the stack, exports values:
/// its module gives its kosmoi, so the runner reads it as a script only when kosm could not
/// read what it exports when it built, which the message says.
pub fn refuseExports(interpreter: Interpreter, context: *Context, source: []const u8) Error!void {
    if (interpreter.kind(-1) != .table or !holdsExport(interpreter)) return;
    var reading: Context = .{ .arena = context.arena, .path = context.path };
    _ = declares(&reading, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidScript => return context.fail("{s}", .{reading.message orelse "it exports values, but kosm cannot read them"}),
    };
    return context.fail("{s} exports values, which its module gives, but that module is older than the script; kosm build brings it up to date", .{context.path});
}

/// Whether the table on top of the stack holds a value of `kosm.value` or `kosm.takes`.
fn holdsExport(interpreter: Interpreter) bool {
    const table = interpreter.absolute(-1);
    interpreter.pushNil();
    while (interpreter.next(table)) {
        const is_export = isExport(interpreter, -1);
        interpreter.pop(1);
        if (is_export) {
            interpreter.pop(1);
            return true;
        }
    }
    return false;
}

/// Whether the value at `index` is what `kosm.value` or `kosm.takes` returns.
fn isExport(interpreter: Interpreter, index: c_int) bool {
    const state = interpreter.state;
    if (c.lua_getmetatable(state, index) == 0) return false;
    _ = c.lua_getfield(state, c.LUA_REGISTRYINDEX, export_metatable);
    defer c.lua_settop(state, -3);
    return c.lua_rawequal(state, -1, -2) != 0;
}

/// A struct an exporting script declares, by its key, and where its table of fields is on the
/// stack while the script's declaration is read.
const StructTable = struct {
    name: [:0]const u8,
    position: c_int,
};

/// Whether `key` of an exporting script's table names a struct it declares: it starts with a
/// capital letter, as Zig names types.
fn isStructName(key: []const u8) bool {
    return key.len != 0 and std.ascii.isUpper(key[0]);
}

/// The kinds of `kosm.boolean`, `kosm.integer`, `kosm.float` and `kosm.text`, and the Zig types
/// a parameter of each has.
const scalar_kinds = [_][]const u8{ "boolean", "integer", "float", "text" };
const scalar_types = [_][]const u8{ "bool", "i64", "f64", "[]const u8" };

/// The key of the base a package's root script declares.
const base_key = kosm.Frontend.ExportsDeclaration.base_name;

/// Whether the table on top of the stack sets `key`.
fn holds(interpreter: Interpreter, key: [:0]const u8) bool {
    interpreter.pushField(-1, key);
    defer interpreter.pop(1);
    return interpreter.kind(-1) != .nil;
}

/// The one interpreter every app's script runs in, started on the first call. A global, because
/// an app's `from(theme)` takes nothing to hand it in; kosm runs one kosmos per process, and the
/// process ending closes it.
var shared: ?Interpreter = null;

/// What the script at `path` returns, for messages: an adapter's in `adapters/`, a frontend's in
/// `frontends/`, a modifier's, palette style's or family's in `colors/`, else an app's.
fn shapeOf(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "colors/")) return "a modifier's script returns a table with Modifier and apply, a palette style's with Style and apply, a variation family's with Family and from";
    if (std.mem.startsWith(u8, path, "adapters/")) return "an adapter's script returns a table with name, extensions and the capabilities it gives";
    if (std.mem.startsWith(u8, path, "frontends/")) return "a frontend's script returns a table with name, extensions and load, and maybe variants and complete";
    if (std.mem.startsWith(u8, path, "~~") or std.mem.startsWith(u8, path, "kosmoi/")) return "a kosmos script exporting values returns a table of what it gives, its values as kosm.value(T, function() ... end)";
    return "an app's script returns a table with App, from, apply and maybe reload";
}

/// Calls `function` of the app, adapter, frontend or package script at `context.path`, running
/// the script on its first call. A value the script exports is built by the function
/// `kosm.value` or `kosm.takes` holds, and the functions it returns are kept by their place
/// (`look.tweak`), which `function` names to call the one kept there.
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
    const exported = if (std.mem.findScalar(u8, function, '.') != null) kept: {
        pushKept(interpreter, context.path, name);
        if (interpreter.kind(-1) != .function) return context.fail("{s}: the script gave no function at {s}", .{ context.path, function });
        break :kept false;
    } else named: {
        interpreter.pushField(-1, name);
        const is_export = isExport(interpreter, -1);
        if (is_export) {
            interpreter.pushField(-1, "build");
            c.lua_rotate(state, -2, 1);
            interpreter.pop(1);
        }
        if (interpreter.kind(-1) != .function) return context.fail("{s} gives no function '{s}'; {s}", .{ context.path, function, shapeOf(context.path) });
        break :named is_export;
    };
    for (arguments) |argument| try Bridge.push(interpreter, context, argument);
    if (c.lua_pcallk(state, @intCast(arguments.len), 1, 0, 0, null) != c.LUA_OK)
        return context.fail("{s}", .{interpreter.string(-1) orelse "the script raised an error that is not a string"});
    if (interpreter.kind(-1) == .nil) return .{ .value = .null };
    if (exported) {
        pushKeptTable(interpreter, context.path);
        defer interpreter.pop(1);
        return Bridge.readExport(interpreter, context, -2, -1, function);
    }
    return Bridge.read(interpreter, context, -1);
}

/// Pushes the function kept at `place` for the script at `path`, or nil.
fn pushKept(interpreter: Interpreter, path: []const u8, place: [:0]const u8) void {
    pushKeptTable(interpreter, path);
    interpreter.pushField(-1, place);
    c.lua_rotate(interpreter.state, -2, 1);
    interpreter.pop(1);
}

/// Pushes the table of functions kept for the script at `path`, creating it when missing.
fn pushKeptTable(interpreter: Interpreter, path: []const u8) void {
    const state = interpreter.state;
    _ = c.lua_getfield(state, c.LUA_REGISTRYINDEX, functions_field);
    if (interpreter.kind(-1) != .table) {
        interpreter.pop(1);
        c.lua_createtable(state, 0, 4);
        c.lua_pushvalue(state, -1);
        c.lua_setfield(state, c.LUA_REGISTRYINDEX, functions_field);
    }
    _ = c.lua_pushlstring(state, path.ptr, path.len);
    if (c.lua_rawget(state, -2) != c.LUA_TTABLE) {
        interpreter.pop(1);
        c.lua_createtable(state, 0, 4);
        _ = c.lua_pushlstring(state, path.ptr, path.len);
        c.lua_pushvalue(state, -2);
        c.lua_rawset(state, -4);
    }
    c.lua_rotate(state, -2, 1);
    interpreter.pop(1);
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
    try interpreter.reserve(7);
    if (c.luaL_loadbufferx(state, prelude, prelude.len, "=kosm", "t") != c.LUA_OK) return error.OutOfMemory;
    _ = c.lua_getglobal(state, "kosm");
    _ = c.luaL_newmetatable(state, type_metatable);
    _ = c.luaL_newmetatable(state, reference_metatable);
    _ = c.luaL_newmetatable(state, export_metatable);
    c.lua_pushboolean(state, @intFromBool(declaring));
    if (c.lua_pcallk(state, 5, 0, 0, 0, null) != c.LUA_OK)
        return context.fail("kosm's own Lua failed: {s}", .{interpreter.string(-1) orelse "no message"});
}

/// Reads the table on top of the stack as a declaration.
const Reader = struct {
    context: *Context,
    interpreter: Interpreter,
    lines: Lines,
    source: []const u8,
    shape: Shape,
    /// The structs an exporting script declares, which types may name.
    structs: []const StructTable = &.{},

    fn declaration(reader: *Reader) Error!Declaration {
        const interpreter = reader.interpreter;
        const path = reader.context.path;
        const shape = reader.shape;
        if (interpreter.kind(-1) != .table) return reader.context.fail("{s} returns {s}; {s} script returns a table with {s}", .{ path, Interpreter.describe(interpreter.kind(-1)), shape.whose, shape.holds });
        const table = interpreter.absolute(-1);
        var given: [max_functions]bool = @splat(false);
        try interpreter.reserve(4);
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const key = interpreter.string(-2) orelse return reader.context.fail("{s}: the returned table holds a {s} key; it holds {s}", .{ path, Interpreter.describe(interpreter.kind(-2)), shape.holds });
            if (std.mem.eql(u8, key, shape.fields)) {
                interpreter.pop(1);
                continue;
            }
            const known = for (shape.functions, 0..) |function, position| {
                if (std.mem.eql(u8, function, key)) break position;
            } else return reader.failAt(&.{.{ .key = key }}, "the returned table sets '{s}'; it holds {s}", .{ key, shape.holds });
            if (interpreter.kind(-1) != .function) return reader.failAt(&.{.{ .key = key }}, "{s} is {s}, not a function", .{ key, Interpreter.describe(interpreter.kind(-1)) });
            given[known] = true;
            interpreter.pop(1);
        }
        interpreter.pushField(table, shape.fields);
        const declared_fields = switch (interpreter.kind(-1)) {
            .nil => &.{},
            .table => try reader.readFields(interpreter.absolute(-1)),
            else => |kind| return reader.failAt(&.{.{ .key = shape.fields }}, "{s} is {s}; it is a table of the fields, as {s} = {{ size = kosm.integer(0) }}", .{ shape.fields, Interpreter.describe(kind), shape.fields }),
        };
        interpreter.pop(1);
        var gives: std.ArrayList([]const u8) = .empty;
        for (shape.functions, given[0..shape.functions.len]) |function, is_given| {
            if (is_given) try gives.append(reader.context.arena, function);
        }
        const fields_line = reader.lines.find(&.{.{ .key = shape.fields }});
        return .{ .fields = declared_fields, .functions = gives.items, .doc = if (fields_line) |line| try reader.docAbove(line) else null };
    }

    /// What the package's root script exports, from the table on top of the stack.
    fn exports(reader: *Reader) Error!kosm.Frontend.ExportsDeclaration {
        const interpreter = reader.interpreter;
        const path = reader.context.path;
        const arena = reader.context.arena;
        if (interpreter.kind(-1) != .table) return reader.context.fail("{s} returns {s}; {s}", .{ path, Interpreter.describe(interpreter.kind(-1)), shapeOf(path) });
        const table = interpreter.absolute(-1);
        try interpreter.reserve(6);
        interpreter.pushField(table, base_key);
        const base_table: ?c_int = if (interpreter.kind(-1) == .table) interpreter.absolute(-1) else if (interpreter.kind(-1) == .nil) null else return reader.failAt(&.{.{ .key = base_key }}, "{s} is {s}; it is a table of the base's fields, as {s} = {{ official = kosm_base.Base }}", .{ base_key, Interpreter.describe(interpreter.kind(-1)), base_key });
        var values: std.ArrayList(kosm.Frontend.ExportsDeclaration.Value) = .empty;
        var structs: std.ArrayList(StructTable) = .empty;
        if (base_table) |position| try structs.append(arena, .{ .name = base_key, .position = position });
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const key = interpreter.string(-2) orelse return reader.context.fail("{s}: the returned table holds a {s} key; its keys name what it exports", .{ path, Interpreter.describe(interpreter.kind(-2)) });
            if (!std.mem.eql(u8, key, base_key) and isStructName(key) and interpreter.kind(-1) == .table and !isExport(interpreter, -1)) {
                // Kept on the stack below the walk, so its position stays valid while it is read.
                interpreter.pushCopy(-1);
                c.lua_rotate(interpreter.state, -3, 1);
                try structs.append(arena, .{ .name = try arena.dupeSentinel(u8, key, 0), .position = interpreter.absolute(-3) });
                try interpreter.reserve(6);
            }
            interpreter.pop(1);
        }
        reader.structs = structs.items;
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const key = interpreter.string(-2).?;
            if (std.mem.eql(u8, key, base_key) or reader.structNamed(key) != null) {
                interpreter.pop(1);
                continue;
            }
            const name = try arena.dupe(u8, key);
            if (!isExport(interpreter, -1)) return reader.failAt(&.{.{ .key = name }}, "'{s}' is {s}; a script exporting values gives each as kosm.value(T, function() ... end), its kosmos too, and a base's from as kosm.takes(T, function(look) ... end)", .{ name, Interpreter.describe(interpreter.kind(-1)) });
            try values.append(arena, try reader.exported(name, interpreter.absolute(-1), base_table));
            interpreter.pop(1);
        }
        std.mem.sort(kosm.Frontend.ExportsDeclaration.Value, values.items, {}, valueLessThan);
        var declared: kosm.Frontend.ExportsDeclaration = .{ .values = values.items };
        if (base_table) |position| {
            declared.base = try reader.readFields(position);
            declared.base_line = reader.lines.find(&.{.{ .key = base_key }}) orelse 0;
            if (declared.base_line != 0) declared.base_doc = try reader.docAbove(declared.base_line);
        }
        var others: std.ArrayList(kosm.Frontend.ExportsDeclaration.Struct) = .empty;
        for (reader.structs) |declared_struct| {
            if (std.mem.eql(u8, declared_struct.name, base_key)) continue;
            reader.shape.fields = declared_struct.name;
            const line = reader.lines.find(&.{.{ .key = declared_struct.name }}) orelse 0;
            try others.append(arena, .{
                .name = declared_struct.name,
                .fields = try reader.readFields(declared_struct.position),
                .line = line,
                .doc = if (line != 0) try reader.docAbove(line) else null,
            });
        }
        std.mem.sort(kosm.Frontend.ExportsDeclaration.Struct, others.items, {}, structLessThan);
        declared.structs = others.items;
        interpreter.pop(@intCast(others.items.len + 1));
        return declared;
    }

    fn structLessThan(_: void, left: kosm.Frontend.ExportsDeclaration.Struct, right: kosm.Frontend.ExportsDeclaration.Struct) bool {
        if (left.line != right.line) return left.line < right.line;
        return std.mem.order(u8, left.name, right.name) == .lt;
    }

    /// The struct the script declares named `name`, or null.
    fn structNamed(reader: *Reader, name: []const u8) ?StructTable {
        for (reader.structs) |declared| {
            if (std.mem.eql(u8, declared.name, name)) return declared;
        }
        return null;
    }

    /// The name of the struct the script declares that the table at `position` is, or null.
    fn structAt(reader: *Reader, position: c_int) ?[]const u8 {
        for (reader.structs) |declared| {
            if (c.lua_rawequal(reader.interpreter.state, position, declared.position) != 0) return declared.name;
        }
        return null;
    }

    /// The value `name` the export at `position` gives; `base_table` is the base the script
    /// declares, which a type may name.
    fn exported(reader: *Reader, name: []const u8, position: c_int, base_table: ?c_int) Error!kosm.Frontend.ExportsDeclaration.Value {
        const interpreter = reader.interpreter;
        const arena = reader.context.arena;
        const line = reader.lines.find(&.{.{ .key = name }}) orelse 0;
        var value: kosm.Frontend.ExportsDeclaration.Value = .{ .name = name, .type = "", .line = line, .doc = if (line != 0) try reader.docAbove(line) else null };
        interpreter.pushField(position, "kind");
        const takes = std.mem.eql(u8, interpreter.string(-1).?, "takes");
        interpreter.pop(1);
        if (!takes) {
            interpreter.pushField(position, "type");
            defer interpreter.pop(1);
            value.type = try reader.typeName(-1, name, line, base_table, false);
            return value;
        }
        // What a function takes, a base's `from` or a kosmos' `Params`, it builds the base from.
        value.type = base_key;
        interpreter.pushField(position, "types");
        const types = interpreter.absolute(-1);
        interpreter.pushField(position, "build");
        const build = interpreter.absolute(-1);
        defer interpreter.pop(2);
        const count: usize = @intCast(c.lua_rawlen(interpreter.state, types));
        const parameters = try arena.alloc(kosm.Frontend.ExportsDeclaration.Parameter, count);
        for (parameters, 1..) |*parameter, position_in_list| {
            interpreter.pushItem(types, @intCast(position_in_list));
            defer interpreter.pop(1);
            interpreter.pushCopy(build);
            const parameter_name = c.lua_getlocal(interpreter.state, null, @intCast(position_in_list));
            interpreter.pop(1);
            const given = parameter_name orelse return reader.failLine(line, "{s}: kosm.takes names {d} types, but its function takes {d} parameters", .{ name, count, position_in_list - 1 });
            parameter.* = .{ .name = try arena.dupe(u8, std.mem.span(given)), .type = try reader.typeName(-1, name, line, base_table, true) };
        }
        interpreter.pushCopy(build);
        const extra = c.lua_getlocal(interpreter.state, null, @intCast(count + 1));
        interpreter.pop(1);
        if (extra != null) return reader.failLine(line, "{s}: kosm.takes names {d} types, but its function takes more parameters; name the type of each", .{ name, count });
        value.parameters = parameters;
        return value;
    }

    /// The Zig type the value at `index` names for export `name`: a Zig type by its name, a
    /// struct the script declares, or with `scalars` (a parameter's) a plain type as Zig spells it.
    fn typeName(reader: *Reader, index: c_int, name: []const u8, line: usize, base_table: ?c_int, scalars: bool) Error![]const u8 {
        const interpreter = reader.interpreter;
        const position = interpreter.absolute(index);
        if (base_table) |base| {
            if (c.lua_rawequal(interpreter.state, position, base) != 0) return base_key;
        }
        if (reader.structAt(position)) |declared| return declared;
        if (scalars and reader.hasMetatable(position, type_metatable)) {
            interpreter.pushField(position, "kind");
            defer interpreter.pop(1);
            const kind = interpreter.string(-1).?;
            for (scalar_kinds, scalar_types) |scalar, zig_type| {
                if (std.mem.eql(u8, kind, scalar)) return zig_type;
            }
        }
        if (!reader.hasMetatable(position, reference_metatable))
            return reader.failLine(line, "{s}: its type is {s}; name a Zig type, as kosm_base.Look, kosm.text, or a struct the script declares, as {s}", .{ name, Interpreter.describe(interpreter.kind(position)), base_key });
        interpreter.pushField(position, "name");
        defer interpreter.pop(1);
        return reader.context.arena.dupe(u8, interpreter.string(-1).?);
    }

    fn valueLessThan(_: void, left: kosm.Frontend.ExportsDeclaration.Value, right: kosm.Frontend.ExportsDeclaration.Value) bool {
        if (left.line != right.line) return if (left.line == 0) false else if (right.line == 0) true else left.line < right.line;
        return std.mem.order(u8, left.name, right.name) == .lt;
    }

    /// The fields of the table of fields at `table`, in the order the script writes them.
    fn readFields(reader: *Reader, table: c_int) Error![]const Declaration.Field {
        const interpreter = reader.interpreter;
        const fields = reader.shape.fields;
        var found: std.ArrayList(Declaration.Field) = .empty;
        interpreter.pushNil();
        while (interpreter.next(table)) {
            const name = interpreter.string(-2) orelse return reader.failAt(&.{.{ .key = fields }}, "{s} holds a {s} key; its keys are the fields' names", .{ fields, Interpreter.describe(interpreter.kind(-2)) });
            const owned = try reader.context.arena.dupe(u8, name);
            const line = reader.lines.findAnywhere(&.{ .{ .key = fields }, .{ .key = owned } }) orelse 0;
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
        if (depth > max_depth) return reader.failLine(line, "{s}.{s}: its types nest more than {d} deep", .{ reader.shape.fields, name, max_depth });
        const position = interpreter.absolute(index);
        try interpreter.reserve(4);
        if (reader.hasMetatable(position, reference_metatable)) {
            interpreter.pushField(position, "name");
            defer interpreter.pop(1);
            return .{ .zig = try reader.context.arena.dupe(u8, interpreter.string(-1).?) };
        }
        if (interpreter.kind(position) == .table) {
            if (reader.structAt(position)) |declared| return .{ .declared = declared };
        }
        if (!reader.hasMetatable(position, type_metatable))
            return reader.failLine(line, "{s}.{s}: it is {s}, not a type; give kosm.boolean, kosm.integer, kosm.float or kosm.text (called with a default), kosm.optional(...), kosm.list(...) or a Zig type such as kosm.Color", .{ reader.shape.fields, name, Interpreter.describe(interpreter.kind(position)) });
        interpreter.pushField(position, "kind");
        const kind = try reader.context.arena.dupe(u8, interpreter.string(-1).?);
        interpreter.pop(1);
        if (std.mem.eql(u8, kind, "default")) {
            interpreter.pushField(position, "child");
            const child = interpreter.absolute(-1);
            defer interpreter.pop(1);
            if (!reader.hasMetatable(child, reference_metatable)) return reader.failLine(line, "{s}.{s}: kosm.default takes a Zig type, as kosm.Image", .{ reader.shape.fields, name });
            interpreter.pushField(child, "name");
            const type_name = try reader.context.arena.dupe(u8, interpreter.string(-1).?);
            interpreter.pop(1);
            interpreter.pushField(position, "default");
            defer interpreter.pop(1);
            default.* = try reader.plainValue(-1, name, line, 0);
            return .{ .zig = type_name };
        }
        if (std.mem.eql(u8, kind, "kosmos")) {
            interpreter.pushField(position, "tree");
            const tree = reader.structAt(interpreter.absolute(-1));
            interpreter.pop(1);
            const declared = tree orelse return reader.failLine(line, "{s}.{s}: kosm.kosmos takes the type of the tree as a struct the script declares, as {s}", .{ reader.shape.fields, name, base_key });
            interpreter.pushField(position, "default");
            defer interpreter.pop(1);
            default.* = try reader.plainValue(-1, name, line, 0);
            const arguments = try reader.context.arena.dupe(Declaration.Type, &.{.{ .declared = declared }});
            return .{ .applied = .{ .function = "kosm.Kosmos", .arguments = arguments } };
        }
        if (std.mem.eql(u8, kind, "optional") or std.mem.eql(u8, kind, "list")) {
            interpreter.pushField(position, "child");
            defer interpreter.pop(1);
            const child = try reader.context.arena.create(Declaration.Type);
            child.* = try reader.fieldType(-1, name, line, default, depth + 1);
            if (std.mem.eql(u8, kind, "list")) {
                if (default.* != null) return reader.failLine(line, "{s}.{s}: a list starts empty; its items take no default", .{ reader.shape.fields, name });
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
            else => |given| return reader.failLine(line, "{s}.{s}: a default is a boolean, number or string, not {s}", .{ reader.shape.fields, name, Interpreter.describe(given) }),
        };
        return scalar;
    }

    /// The plain value at `index`, a default field `name` gives: a table by its keys in order of
    /// their names, a sequence as a list, text, numbers and booleans.
    fn plainValue(reader: *Reader, index: c_int, name: []const u8, line: usize, depth: usize) Error!Loose {
        const interpreter = reader.interpreter;
        const arena = reader.context.arena;
        if (depth > max_depth) return reader.failLine(line, "{s}.{s}: its default nests more than {d} deep", .{ reader.shape.fields, name, max_depth });
        const position = interpreter.absolute(index);
        try interpreter.reserve(4);
        switch (interpreter.kind(position)) {
            .boolean => return .{ .value = .{ .boolean = interpreter.boolean(position) } },
            .integer => return .{ .value = .{ .integer = interpreter.integer(position) } },
            .float => return .{ .value = .{ .float = interpreter.float(position) } },
            .string => return .{ .value = .{ .string = try arena.dupe(u8, interpreter.string(position).?) } },
            .table => {},
            else => |given| return reader.failLine(line, "{s}.{s}: a default holds tables, text, numbers and booleans, not {s}", .{ reader.shape.fields, name, Interpreter.describe(given) }),
        }
        const length: usize = @intCast(c.lua_rawlen(interpreter.state, position));
        if (length != 0) {
            const items = try arena.alloc(Loose, length);
            for (items, 1..) |*item, item_position| {
                interpreter.pushItem(position, @intCast(item_position));
                defer interpreter.pop(1);
                item.* = try reader.plainValue(-1, name, line, depth + 1);
            }
            return .{ .value = .{ .list = items } };
        }
        var entries: std.ArrayList(Loose.Entry) = .empty;
        interpreter.pushNil();
        while (interpreter.next(position)) {
            const key = interpreter.string(-2) orelse return reader.failLine(line, "{s}.{s}: a default's tables have names as keys", .{ reader.shape.fields, name });
            try entries.append(arena, .{ .key = try arena.dupe(u8, key), .value = try reader.plainValue(-1, name, line, depth + 1) });
            interpreter.pop(1);
        }
        std.mem.sort(Loose.Entry, entries.items, {}, entryLessThan);
        return .{ .value = .{ .table = entries.items } };
    }

    fn entryLessThan(_: void, left: Loose.Entry, right: Loose.Entry) bool {
        return std.mem.order(u8, left.key, right.key) == .lt;
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

test "the fields and functions of a modifier, palette style and family are read like an app's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "colors/sepia.lua" };
    const declaration = try declareModifier(&context,
        \\return {
        \\    --- Tints toward sepia.
        \\    Modifier = {
        \\        --- How far toward sepia, 0..1.
        \\        amount = kosm.float(1),
        \\    },
        \\    apply = function(self, color) return color end,
        \\}
    );
    try testing.expectEqualStrings("Tints toward sepia.", declaration.doc.?);
    try testing.expectEqual(1, declaration.functions.len);
    try testing.expectEqualStrings("apply", declaration.functions[0]);
    try testing.expectEqualStrings("amount", declaration.fields[0].name);
    try testing.expectEqualStrings("How far toward sepia, 0..1.", declaration.fields[0].doc.?);
    try testing.expectEqual(.float, declaration.fields[0].type);
    try testing.expectError(error.InvalidScript, declareModifier(&context, "return { Modifier = {}, from = function(theme) end }"));
    try testing.expectEqualStrings("colors/sepia.lua:1: the returned table sets 'from'; it holds Modifier and apply", context.message.?);
    try testing.expectError(error.InvalidScript, declareModifier(&context, "return { Modifier = { amount = 1 }, apply = function() end }"));
    try testing.expectStringStartsWith(context.message.?, "colors/sepia.lua:1: Modifier.amount: it is an integer, not a type");
    context.path = "colors/pastel.lua";
    const style = try declareStyle(&context, "return { Style = { lift = kosm.float(0.1) }, apply = function(self, hue, background) return hue end }");
    try testing.expectEqualStrings("lift", style.fields[0].name);
    try testing.expectError(error.InvalidScript, declareStyle(&context, "return { Modifier = {}, apply = function() end }"));
    try testing.expectEqualStrings("colors/pastel.lua:1: the returned table sets 'Modifier'; it holds Style and apply", context.message.?);
    context.path = "colors/glow.lua";
    const family = try declareFamily(&context, "return { Family = { soft = kosm.Modifier }, from = function(mode) return {} end }");
    try testing.expectEqualStrings("kosm.Modifier", family.fields[0].type.zig);
    try testing.expectEqualStrings("from", family.functions[0]);
}

test "a script says whether it gives an app, modifier, palette style, family, adapter, frontend or kosmos" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var context: Context = .{ .arena = arena_state.allocator(), .path = "~~kosm_scratch/root.lua" };
    try std.testing.expectEqual(.app, try declares(&context, "return { App = { size = kosm.integer(1) }, apply = function() end }"));
    try std.testing.expectEqual(.adapter, try declares(&context, "return { name = 'keys', extensions = { '.keys' } }"));
    try std.testing.expectEqual(.frontend, try declares(&context, "return { name = 'ini', extensions = { '.ini' }, load = function() end }"));
    try std.testing.expectEqual(.modifier, try declares(&context, "return { Modifier = { amount = kosm.float(1) }, apply = function() end }"));
    try std.testing.expectEqual(.style, try declares(&context, "return { Style = {}, apply = function() end }"));
    try std.testing.expectEqual(.family, try declares(&context, "return { Family = { soft = kosm.Modifier }, from = function(mode) end }"));
    try std.testing.expectEqual(.kosmos, try declares(&context, "return { base = 'personal', overrides = {} }"));
    try std.testing.expectEqual(.kosmos, try declares(&context, "return { kosmos = function() end, light = function() end }"));
    try std.testing.expectError(error.InvalidScript, declares(&context, "return { App = {}, Modifier = {} }"));
    try std.testing.expectStringEndsWith(context.message.?, "holding both App and Modifier; an app's holds App, a modifier's Modifier, a palette style's Style, a family's Family, a frontend's load, so it is one of them");
    try std.testing.expectError(error.InvalidScript, declares(&context, "return { App = {}, load = function() end }"));
    try std.testing.expectStringEndsWith(context.message.?, "so it is one of them");
    try std.testing.expectError(error.InvalidScript, declares(&context, "return { apply = function() end }"));
    try std.testing.expectEqualStrings("~~kosm_scratch/root.lua returns a table holding apply but none of App, Modifier or Style: an app's holds App, a modifier's Modifier, a palette style's Style", context.message.?);
    try std.testing.expectError(error.InvalidScript, declares(&context, "return 3"));
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
    , "apps/cava/root.lua:1: 'kosm.Color.parseHex' is called while kosm reads what the script declares, when no Zig code runs; call it inside a function the script gives");
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

const exporting_script =
    \\local Base = {
    \\    --- How many bars.
    \\    bars = kosm.integer(3),
    \\}
    \\local seen = 0
    \\return {
    \\    --- The package's look.
    \\    look = kosm.value(kosm_base.Look, function()
    \\        return { fonts = { size = 14 }, tweak = function(base, look) seen = seen + base end, list = { 1 } }
    \\    end),
    \\    --- A base of its own.
    \\    Base = Base,
    \\    from = kosm.takes(kosm_base.Look, kosm_base.Apps, function(look, apps) return { bars = seen } end),
    \\    kosmos = kosm.value(Base, function() return { bars = 1 } end),
    \\}
;

test "a package's root script exporting values is read as its exports, typed, documented and in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "~~kosm_frost/root.lua" };
    try testing.expectEqual(.exports, try declares(&context, exporting_script));
    try testing.expectEqual(.exports, try declares(&context, "return { look = kosm.value(kosm_base.Look, function() end) }"));
    const declared = try declareExports(&context, exporting_script);
    try testing.expectEqual(3, declared.values.len);
    const look = declared.values[0];
    try testing.expectEqualStrings("look", look.name);
    try testing.expectEqualStrings("kosm_base.Look", look.type);
    try testing.expectEqualStrings("The package's look.", look.doc.?);
    try testing.expectEqual(8, look.line);
    try testing.expectEqual(0, look.parameters.len);
    const from = declared.values[1];
    try testing.expectEqualStrings("from", from.name);
    try testing.expectEqualStrings("Base", from.type);
    try testing.expectEqual(2, from.parameters.len);
    try testing.expectEqualStrings("look", from.parameters[0].name);
    try testing.expectEqualStrings("kosm_base.Look", from.parameters[0].type);
    try testing.expectEqualStrings("apps", from.parameters[1].name);
    try testing.expectEqualStrings("kosm_base.Apps", from.parameters[1].type);
    try testing.expectEqualStrings("kosmos", declared.values[2].name);
    try testing.expectEqualStrings("Base", declared.values[2].type);
    try testing.expectEqual(1, declared.base.?.len);
    try testing.expectEqualStrings("bars", declared.base.?[0].name);
    try testing.expectEqualStrings("How many bars.", declared.base.?[0].doc.?);
    try testing.expectEqualStrings("A base of its own.", declared.base_doc.?);
}

fn expectExportsFailure(source: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "~~kosm_frost/root.lua" };
    try testing.expectError(error.InvalidScript, declareExports(&context, source));
    try testing.expectEqualStrings(expected, context.message.?);
}

test "an exporting script's other structs are read like its base, and variants taking them are typed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: Context = .{ .arena = arena.allocator(), .path = "kosmoi/frost/root.lua" };
    const script =
        \\local Base = { base = kosm.optional(kosm_base.Base) }
        \\--- What the image takes.
        \\local Params = {
        \\    --- The picture.
        \\    wallpaper = kosm.default(kosm.Image, { path = "~/walls", sizes = { 1, 2.5 } }),
        \\    --- The kosmos below.
        \\    on = kosm.kosmos(Base, "frost.huge"),
        \\    size = kosm.integer(3),
        \\}
        \\return {
        \\    Base = Base,
        \\    Params = Params,
        \\    image = kosm.takes(Params, function(params) end),
        \\    named = kosm.takes(kosm.text, kosm.float, function(name, size) end),
        \\}
    ;
    const declared = try declareExports(&context, script);
    try testing.expectEqual(1, declared.structs.len);
    const params = declared.structs[0];
    try testing.expectEqualStrings("Params", params.name);
    try testing.expectEqual(3, params.fields.len);
    const wallpaper = params.fields[0];
    try testing.expectEqualStrings("wallpaper", wallpaper.name);
    try testing.expectEqualStrings("kosm.Image", wallpaper.type.zig);
    try testing.expectEqualStrings("The picture.", wallpaper.doc.?);
    const entries = wallpaper.default.?.value.table;
    try testing.expectEqualStrings("path", entries[0].key);
    try testing.expectEqualStrings("~/walls", entries[0].value.value.string);
    try testing.expectEqualStrings("sizes", entries[1].key);
    try testing.expectEqual(2.5, entries[1].value.value.list[1].value.float);
    const on = params.fields[1];
    try testing.expectEqualStrings("kosm.Kosmos", on.type.applied.function);
    try testing.expectEqualStrings("Base", on.type.applied.arguments[0].declared);
    try testing.expectEqualStrings("frost.huge", on.default.?.value.table[0].value.value.string);
    try testing.expectEqual(.integer, params.fields[2].type);
    const image = declared.values[0];
    try testing.expectEqualStrings("image", image.name);
    try testing.expectEqualStrings("Base", image.type);
    try testing.expectEqualStrings("Params", image.parameters[0].type);
    const named = declared.values[1];
    try testing.expectEqualStrings("[]const u8", named.parameters[0].type);
    try testing.expectEqualStrings("f64", named.parameters[1].type);
}

test "exports kosm cannot read fail naming the script's line" {
    try expectExportsFailure(
        \\return {
        \\    look = kosm.value(kosm_base.Look, function() end),
        \\    kosmos = function() end,
        \\}
    , "~~kosm_frost/root.lua:3: 'kosmos' is a function; a script exporting values gives each as kosm.value(T, function() ... end), its kosmos too, and a base's from as kosm.takes(T, function(look) ... end)");
    try expectExportsFailure(
        \\return {
        \\    look = kosm.takes("big", function(size) end),
        \\}
    , "~~kosm_frost/root.lua:2: look: its type is a string; name a Zig type, as kosm_base.Look, kosm.text, or a struct the script declares, as Base");
    try expectExportsFailure(
        \\return {
        \\    Base = {},
        \\    from = kosm.takes(kosm_base.Look, function(look, apps) end),
        \\}
    , "~~kosm_frost/root.lua:3: from: kosm.takes names 1 types, but its function takes more parameters; name the type of each");
    try expectExportsFailure(
        \\return {
        \\    look = kosm.value(kosm.integer(1), function() end),
        \\}
    , "~~kosm_frost/root.lua:2: look: its type is a table; name a Zig type, as kosm_base.Look, kosm.text, or a struct the script declares, as Base");
    try expectExportsFailure(
        \\return { look = kosm.value(kosm_base.Look) }
    , "~~kosm_frost/root.lua:1: kosm.value takes the function building the value after its type: kosm.value(kosm_base.Look, function() ... end)");
}

test "an exported value runs its function, keeping the functions it returns by their place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const script =
        \\local Base = { bars = kosm.integer(3) }
        \\local seen = 0
        \\return {
        \\    look = kosm.value(Base, function()
        \\        return { fonts = { size = 14, scale = function(by) seen = seen + by end }, tweak = function(by) seen = seen + by end }
        \\    end),
        \\    count = kosm.value(Base, function() return { bars = seen } end),
        \\    listed = kosm.value(Base, function() return { items = { function() end } } end),
        \\}
    ;
    const path = "~~kosm_frost/root.lua";
    var context: Context = .{ .arena = arena.allocator(), .path = path };
    const look = try call(&context, script, "look", &.{});
    const fonts = look.value.table[0];
    try testing.expectEqualStrings("fonts", fonts.key);
    try testing.expectEqualStrings("look.fonts.scale", fonts.value.value.table[0].value.value.function);
    try testing.expectEqualStrings("look.tweak", look.value.table[1].value.value.function);
    _ = try call(&context, script, "look.tweak", &.{.{ .value = .{ .integer = 2 } }});
    _ = try call(&context, script, "look.fonts.scale", &.{.{ .value = .{ .integer = 3 } }});
    try testing.expectEqual(5, (try call(&context, script, "count", &.{})).value.table[0].value.value.integer);
    try testing.expectError(error.InvalidScript, call(&context, script, "look.size", &.{}));
    try testing.expectEqualStrings("~~kosm_frost/root.lua: the script gave no function at look.size", context.message.?);
    try testing.expectError(error.InvalidScript, call(&context, script, "listed", &.{}));
    try testing.expectEqualStrings("items: [1]: it is a function; values are strings, numbers, booleans, tables, kosm.null or values from Zig", context.message.?);
}
