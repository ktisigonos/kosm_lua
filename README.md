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

Editing a script compiles nothing: it is read when kosm runs. It runs in Lua 5.5 with the `table`,
`string`, `math`, `utf8` and `coroutine` libraries and the base library without `dofile`,
`loadfile`, `load` and `print`; `io`, `os`, `package` and `debug` are not there at all, as a
kosmos reaches no files or programs.

Errors name the script and line: Lua's own, a value of the wrong type (`kosmoi/mine.lua:5:
base.kitty.fonts.font_size: expected a number, got the string 'big'`), a name that is not defined
(a misspelled variable would otherwise be `nil`), and a field written in the script whose value is
`nil`. A value built in a `local` takes the line of the field holding it.

The frontend is a module of its own, `kosm_lua_frontend`: packages using only the adapter
(`kosm_hyprland`, `kosm_nvim`) never fetch or build Lua.
