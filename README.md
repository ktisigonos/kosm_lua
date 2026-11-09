# kosm_lua

Lua for kosm: the `lua` adapter, claiming `.lua` files and enabling `edit`.

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
as `["col.active"] = ...` is the quoted path segment `"col.active"`.

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
