# kosm_lua

Lua for kosm: the `lua` adapter, claiming `.lua` files and enabling `edit`, and the `lua`
frontend, for kosmoi written in Lua.

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

A file `kosmoi/<name>.lua` in the config is a kosmos, applied like any other
(`kosm apply mine`). It returns a table:

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
return a tree or a table of `base`, `params` and `overrides`.

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

The frontend is a module of its own, `kosm_lua_frontend`: packages using only the adapter
(`kosm_hyprland`, `kosm_nvim`) never fetch or build Lua.
