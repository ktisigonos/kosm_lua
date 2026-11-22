# kosm_lua

Lua for kosm: the `lua` adapter, claiming `.lua` files and enabling `edit`, and the `lua`
frontend, for kosmoi, apps, adapters and frontends written in Lua.

```zig
var file = try output.edit(.{ .files = "~/.config/hypr/defs.lua" });
try file.set("M.blur.enabled", self.blur);
try file.set("M.border.active_col", self.border_active.format("rgba({})", &.{.hex8}));
```

A path matches however the file nests its keys. Each of these holds `M.blur.enabled`:

```lua
M.blur = { enabled = true }
M.blur.enabled = true
local M = { blur = { enabled = true } }
hl.config({ M = { blur = { enabled = true } } })
```

Function calls are transparent, so `hl.config({ general = {...} })` holds `general`. Code inside
function bodies (keybind callbacks, `function ... end`) runs later, not when the file loads, so
paths never see it. A target whose key isn't spelled out (`M[key] = 1`) is skipped. A key written
as `["col.active"] = ...` is the quoted path segment `"col.active"`. Code inside `if` and `do` blocks
runs as the file loads, so paths see into it; a value set in several branches matches several
times.

A table spelled only through dotted keys (`M.blur` in `M.blur.enabled = true`) has no bytes of
its own, so it can't be replaced; set its keys instead.

Only the value's bytes change; comments, spacing and key order stay as they are.

| Value | Written as |
|---|---|
| string | a double-quoted Lua string, escaped |
| color | a string in the file's color format; default `#rrggbb` |
| integer, float | the number; floats at the file's precision, never infinity or NaN |
| bool | `true` or `false`; `format.boolean` must stay `.true_false` |
| struct | `{ key = value }` on one line, `["key"] = value` for keys that aren't names |
| list | `{ a, b }` on one line |
| `kosm.raw(text)` | `text`, verbatim |

Paths name keys only. Positional table entries (`{ "a", "b" }`) aren't reached by paths
or by `elements` yet.

## Kosmoi in Lua

`kosm new kosmos|app|adapter|frontend <name> --language lua` starts one, a commented file showing
each part.

A file `kosmoi/<name>.lua` in the config is a kosmos, applied like any other
(`kosm apply mine`); so is `kosmoi/<name>/root.lua`, whose folder may also hold Lua variants
(`kosmoi/<name>/nord.lua`) and Zig ones in a `root.zig` that declares no `kosmos`. It returns a
table:

```lua
local font_size = 13

return {
    base = "personal",                        -- the kosmos it builds on, Zig or Lua
    params = { wallpaper = "walls/dune.png" }, -- the base's Params
    overrides = {                             -- values set on the base's tree
        base = {
            kitty = { fonts = { font_size = font_size + 0.5 } },
            waybar = { spacing = kosm.null },
        },
    },
}
```

| Field | Meaning |
|---|---|
| `base` | the kosmos it builds on, as `kosm apply` spells it; without one it builds on none |
| `params` | the base's `Params`, below the command line's; relative paths start from `kosmoi/` |
| `theme` | without a base: the theme's input (`palette`, `mode`, `roles`, ...) |
| `overrides` | values set on the tree; without a base, the apps it names are the ones applied |

A table with names sets fields, one with items `1..n` is a list, and `kosm.null` clears an
optional field, since a field set to `nil` is no field at all. A string also names an enum value
or a color (`"dark"`, `"#88c0d0"`), and an integer fits a number field.

### Calling Zig

A script may also build its tree itself, by calling Zig code, and return it:

```lua
return {
    kosmos = function()
        local t = kosmoi.personal()                      -- every Zig kosmos, with its Params
        t.base.kitty.fonts.font_size = 15
        return t
    end,
    image = function()                                   -- kosm apply mine.image
        local t = kosmoi.personal.image({ wallpaper = "~/Pictures/walls" })
        local theme = kosm.Theme.from({ palette = { black = "#101010", white = "#f0f0f0" }, mode = "dark" })
        t.base.kitty = kosm_kitty.from(theme)            -- every package, by its name
        t.base.kitty.colors.color1 = theme.palette.red:mix(theme.palette.white, 0.25)
        return t
    end,
}
```

| Global | Holds |
|---|---|
| `kosmoi` | every Zig kosmos of the config, a function of its `Params` table giving its tree: `kosmoi.personal()`, `kosmoi.personal.light()` |
| `kosm` | kosm's own types and functions: `kosm.Theme.from`, `kosm.Color.parse`, `kosm.null` |
| `<package>` | every package and local module: its public functions and values, and those of its types (`kosm_kitty.from`, `kosm_base.Look.default`) |

Every public function whose parameters a script can give is there: plain values, tables and
values from Zig. Functions taking an allocator, a writer or a compile-time value are not. A Zig
kosmos is only under `kosmoi`, where it gets its images and files loaded like any apply.

A value a call returns stays a Zig value, held by reference: reading `t.base.kitty` gives the
app inside `t`, and setting its fields changes `t`, each assignment checked as in a table
(`size: expected an integer, got the string 'big'`). A struct's functions taking it first are
its methods (`color:mix(other, 0.25)`). Giving a Zig value to a call or a field copies it, and a
declared value (`kosm_base.Look.default`) is a fresh copy each time it is read. Lists count with
`#` and index from 1. Reading an unset optional gives `nil`; setting a field to `nil` fails, use
`kosm.null`.

A table of functions gives variants: `kosm apply mine.image` calls `image`, and `kosmos` is the
script's own; a table of functions inside it is a group, with a `kosmos` of its own. Each may
return a tree or a table of `base`, `params` and `overrides`. A variant may not share its name
with a Zig variant or a script in the kosmos' folder; kosm lists the variants without calling
them and fails naming both.

Editing a script compiles nothing: it is read when kosm runs. It runs in Lua 5.5 with the `table`,
`string`, `math`, `utf8` and `coroutine` libraries and the base library without `dofile`,
`loadfile`, `load` and `print`; `io`, `os`, `package` and `debug` are not there at all, as a
kosmos reaches no files or programs.

Errors name the script and line: Lua's own, a value of the wrong type (`kosmoi/mine.lua:5:
base.kitty.fonts.font_size: expected a number, got the string 'big'`), a name that is not defined
(a misspelled variable would otherwise be `nil`), and a field written in the script whose value is
`nil`. A value built in a `local` takes the line of the field holding it.

### Completion

Whenever kosm builds the runner of scripts (`kosm build`, `kosm add`, `kosm update`, or an apply
after Zig code changed), it writes LuaLS annotations for every app, base, look, Zig kosmos and its
`Params`, and every function, method and value a script calls, into the config's
`zig-out/completions/lua/`, with the doc comments of their Zig
sources, and creates `.luarc.json` in the config if it has none (it never rewrites one). The
`.luarc.json` sets Lua 5.5 and leaves out what a kosmos lacks, so `print` or `io` show as undefined.

Name a script's shape above its `return` to complete and check it:

```lua
---@type kosm.on.personal
return { base = "personal", overrides = { ... } }
```

`kosm.on.<kosmos>` builds on that Zig kosmos (`kosm.on.frost.iced` for a variant); a script
building on another script names the Zig kosmos at the bottom. `kosm.script` builds on none.
Types keep their Zig names: `kosm_kitty.App`, `kosm.Theme.Input`.

## Apps in Lua

An app is `apps/<name>.lua`, or `apps/<name>/root.lua` in a folder without a `root.zig`. It
returns its fields and functions, like a Zig app:

```lua
---@type kosm.app
return {
    --- Cava, the console audio visualizer.
    App = {
        --- How many bars; 0 fits as many as the terminal holds.
        bars = kosm.integer(0),
        --- The bars' color; null leaves cava's.
        foreground = kosm.optional(kosm.Color),
        --- The bars' colors from bottom to top; empty for none.
        gradient = kosm.list(kosm.Color),
    },
    from = function(theme)
        return { foreground = theme.roles.accent }
    end,
    ---@param self cava.App
    apply = function(self, output)
        output:generateValue({ file = "~/.config/cava/config", lang = "ini" }, {
            general = { bars = self.bars },
            color = { foreground = self.foreground },
        })
    end,
}
```

A field's type is `kosm.boolean`, `kosm.integer`, `kosm.float` or `kosm.text` called with its
default, `kosm.optional(type)` (null by default), `kosm.list(type)` (empty by default), or any
Zig type by name (`kosm.Color`, `kosm_cursor.App`). The `---` comment above a field documents it.
`from(theme)` returns a table of the fields it sets, `apply(self, output)` writes files through the
same `kosm.Output` methods a Zig app calls (`generateValue`, `blockValue`, `templateValue` and
`templateBlockValue` take a table), and `reload(self, reloader)` is optional. `output:edit({ files =
"~/.config/cava/config" })` picks files to change in place, and the selection's `setValue(path,
value)` (with `setFirstValue`, `setAllValue`, `setNthValue` and the rest), `nodesAt(path)`,
`replaceValue`, `insertValue` and `appendValue` take the path as text, as `"general.bars"`.

Kosm reads the declaration when it builds, without running any function, and generates the app's
Zig module, so Zig and Lua kosmoi use it alike (`@import("cava")`, `overrides = { cava = ... }`)
and both ZLS and LuaLS complete its fields. Editing a function body compiles nothing; changing the
fields rebuilds once. While kosm reads the declaration no Zig code runs, so a call outside the
functions fails naming its line. Every app's script runs in one Lua state, each with globals of its
own. A Lua table has no order, so the tables an app writes come sorted by key.

## Modifiers in Lua

A modifier of your own is `colors/<name>.lua`, or `colors/<name>/root.lua`. It declares its fields
as an app does, under `Modifier`, and gives `apply(self, color)`, which returns the new color:

```lua
return {
    --- Tints a color toward sepia.
    Modifier = {
        --- How far toward sepia, 0..1.
        amount = kosm.float(1),
    },
    apply = function(self, color)
        return color:mix(kosm.Color.parse("#704214"), self.amount)
    end,
}
```

`sepia.modifier({ amount = 0.5 })` gives it as a `kosm.Modifier`, to set wherever a modifier goes
(`theme.variations.state.inactive`, kitty's `bright`) or to compose with `then`; Zig calls the
same `sepia.modifier(.{ .amount = 0.5 })`. It runs after the modifier's deltas and mix, and before
its contrast pick and alpha. As for an app, kosm generates its Zig module from the declaration, so
editing `apply` compiles nothing. An error in `apply` fails the apply naming the script's line,
and nothing is written.

## Palette styles in Lua

A palette style of your own, for taking a theme from an image, is a script in `colors/` too. It
declares its fields under `Style` and gives `apply(self, hue, background)`, which returns each hue's
final color; nothing runs after it, so `kosm.Image.readable(color, background, contrast)` keeps it
readable as the built-in styles do:

```lua
return {
    --- Soft pastel hues.
    Style = {
        --- How far each hue is washed toward white, 0..1.
        wash = kosm.float(0.5),
    },
    apply = function(self, hue, background)
        local soft = hue:mix(kosm.Color.parse("#ffffff"), self.wash)
        return kosm.Image.readable(soft, background, 4.5)
    end,
}
```

`pastel.style({ wash = 0.6 })` gives a `kosm.Image.Style`, for `Image.Options`' `style` or a
kosmos' `Params` (`kosmoi.wallpaper({ style = pastel.style({ wash = 0.6 }) })`). Black and white
move apart as for every built-in style but `literal`.

## Variation families in Lua

A family of variations of your own, like the theme's `state` or `surface`, is a script in
`colors/` declaring its modifiers under `Family` and giving `from(mode)`, which returns the ones it
sets for `"dark"` or `"light"`:

```lua
return {
    --- Glows for highlighted elements, away from the background.
    Family = {
        --- A soft glow.
        soft = kosm.Modifier,
    },
    from = function(mode)
        local away = mode == "dark" and 1 or -1
        return { soft = { lightness = 0.15 * away } }
    end,
}
```

`glow.from("dark")` gives the family (Zig: `glow.from(.dark)`), whose modifiers are set and
read like the theme's (`family.soft:apply(color)`). The theme cannot hold a family of your own,
so your base holds it beside the theme, and your apps read it from there.

## Adapters in Lua

An adapter is `adapters/<name>.lua`, or `adapters/<name>/root.lua`. It returns its data and the
capabilities it gives, each a function and each optional:

```lua
return {
    name = "keys",                     -- the language apps pass as `lang`
    extensions = { ".keys" },
    comment = { line = "#" },          -- or { block = { open = "/*", close = "*/" } }
    default_format = { boolean = "yes_no" }, -- color, boolean, float_precision
    format = function(value) ... end,  -- returns the value's text
    parser = function(source) ... end, -- returns the root node
    serialize = function(root) ... end, -- returns the whole file
    insert = function(source, parent, key, value) ... end, -- returns the insertions
}
```

A value is `{ kind = "string", value = "text" }`, `kind` naming what it is: `string`, `integer`,
`float`, `boolean`, `color`, `raw`, `table`, `list` or `joined`. A boolean, float or color also
has `text`, already spelled in the file's format, and a color's `value` is a `kosm.Color`. A
table's `value` is a list of `{ key = "name", value = <value> }` in order; a list's and a joined
value's is a list of values.

A node is `{ key = "size", kind = "scalar", position = 1, value = { 8, 9 }, children = { ... } }`:
`kind` is `table`, `list` or `scalar`, `position` where the entry starts, and `value` the first and
last byte of its value, as `string.find` returns them and `string.sub` takes them. `key` is left
out for list elements and the root, `value` for a table that has no bytes of its own, `children`
for none. `insert` gets a node back as `parser` gave it, `key` nil for a list element, and returns
`{ { range = { first, last }, content = "text" } }`; a range adding bytes before position `p` is
`{ p, p - 1 }`.

A capability fails by raising an error (`error("cannot read 'x'")`), reported with the file and
the script's line. As for an app, kosm reads the declaration when it builds and generates the
adapter's Zig module, so Zig and Lua apps write through it alike, and editing a function compiles
nothing.

## Frontends in Lua

A frontend reads kosmoi written in another language. It is `frontends/<name>.lua`, or
`frontends/<name>/root.lua`, and returns its data and functions; only `load` is required:

```lua
return {
    name = "json",                     -- its completion goes to zig-out/completions/json/
    extensions = { ".json" },          -- kosmoi/<name>.json is read through it
    editor_file = { path = ".jsonrc", contents = "{}\n" }, -- created in the config if missing
    load = function(source, path, variant) ... end, -- returns the kosmos' table
    variants = function(source, path) ... end,      -- returns the variants' names
    complete = function(completion) ... end,        -- returns { { path = ..., contents = ... } }
}
```

`load` gets the kosmos' text, its place (`"kosmoi/mine.json"`) and the variant to build as a list
of names (`{ "dark", "soft" }` for `mine.dark.soft`, empty for the kosmos itself), and returns what
a Lua kosmos returns: `base`, `params`, `theme` and `overrides`, or `tree`. Wrap each value in
`kosm.at(path .. ":" .. line, value)`, so kosm's messages about it name that line. An error starting
with the kosmos' place (`error(path .. ":3: expected a value", 0)`) is reported there alone.
`variants` lists every variant without building any (`{ "dark", "dark.soft" }`). `complete` gets
every type a script may set, as tables: `records`, `kosmoi`, `standalone`, `theme` and
`namespaces`, each field's `type` a table of `kind` and, for those holding more, `value`
(`{ kind = "list", value = { kind = "color" } }`); a field left out is null.

As for an adapter, kosm generates the frontend's Zig module from what it declares, so editing a
function compiles nothing. A frontend written in Lua reads kosmoi only; apps and adapters in its
language need one written in Zig.

The frontend is a module of its own, `kosm_lua_frontend`: packages using only the adapter
(`kosm_hyprland`, `kosm_nvim`) never fetch or build Lua.

## Packages in Lua

A package of its own repository may be written in Lua: `root.lua` in place of `root.zig`,
beside the one-line `build.zig` and a `build.zig.zon` depending on `kosm` and `kosm_lua`.
`kosm new package my_bar --language lua` writes all three into `./my_bar/`, `root.lua` holding
an app. The script returns an app's table (it holds `App`), a modifier's (`Modifier`), a palette
style's (`Style`), a variation family's (`Family`), an adapter's (`name` and `extensions`), a
frontend's (`load`) or, holding none of them, a kosmos' table, and the package's build generates
its Zig module from it, so Zig kosmoi and packages import it like any package. Add Zig packages
whose types its fields name (`cursor = kosm_cursor.App`) to its `build.zig.zon`.

A package's kosmos is applied by the package's name (`kosm apply my_frost`,
`kosm apply my_frost.light` for a variant), and kosmoi build on it like on a Zig package's:
`base = "my_frost"` in Lua, `.{ .name = "my_frost" }` in a Zig kosmos' `kosm.Kosmos` field.
Relative paths it gives start from the package's folder.

### Looks and bases in packages

A package may instead export values for building on, typed as in Zig. Each value is
`kosm.value(T, function() ... end)`, its function returning a `T` (a value from Zig) or a table set
on `T.default` (or on `T`'s field defaults); a base is the struct of apps it declares as `Base`,
as an app declares `App`, with a `from` naming the Zig type of each parameter before its function:

```lua
local Base = {
    --- The official apps.
    official = kosm.optional(kosm_base.Base),
}
return {
    --- Frost's look.
    look = kosm.value(kosm_base.Look, function()
        return {
            theme = kosm.Theme.from({ palette = { black = "#101820", white = "#e0f0ff" }, mode = "dark" }),
            fonts = { families = { "Iosevka" }, size = 15 },
            tweak = function(base, look) base.kitty.fonts.font_size = look.fonts.size + 1 end,
        }
    end),
    Base = Base,
    from = kosm.takes(kosm_base.Look, function(look)
        return { official = kosm_base.from(look, "all") }
    end),
    kosmos = kosm.value(Base, function() return { official = kosm_base.from(kosm_base.Look.default, "all") } end),
}
```

Its Zig module gives `my_frost.look()`, `my_frost.Base`, `my_frost.from(look)` and
`my_frost.kosmos()`, used from Zig and Lua alike (`kosm_base.from(my_frost.look(), .all)`,
`my_frost.from(my_frost.look())`). A function in a table a value returns (a look's `tweak`) is
called whenever Zig calls that field; only tables carry one, so it cannot be set on a value
from Zig. A script exporting values gives its kosmos as a value too. A field of a Zig type
without defaults for every field (`kosm_base.Base`) is `kosm.optional`.

Kosm finds a package's script through the package's folder (`~~my_bar/root.lua`), which errors
name. A config needs to list only the packages it uses itself: a Lua package that comes only
through another package is found too.
