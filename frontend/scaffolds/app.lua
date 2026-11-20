-- The scaffold_name app, made by `kosm new app scaffold_name --language lua`. A Lua kosmos sets it
-- in its `overrides` as `scaffold_name = { ... }`; a Zig kosmos uses it like any app, with
-- `const scaffold_name = @import("scaffold_name");` and a field `scaffold_name: scaffold_name.App`
-- set to `scaffold_name.from(theme)`.

-- `kosm.<field>` is replaced by that field of the app.
local template = [[
foreground = kosm.foreground
background = kosm.background
accent = kosm.accent
]]

---@type kosm.app
return {
    -- Every setting of the program, as plain fields a kosmos can assign. `from` fills those that
    -- come from the theme; the rest have defaults.
    App = {
        --- The file kosm writes. Default: `~/.config/scaffold_name/colors.conf`.
        file = kosm.text("~/.config/scaffold_name/colors.conf"),
        --- Text. Default: white, black in light mode.
        foreground = kosm.Color,
        --- Background. Default: black, white in light mode.
        background = kosm.Color,
        --- The accent. Default: cyan.
        accent = kosm.Color,
    },
    -- The app's defaults, derived from the theme.
    from = function(theme)
        local dark = theme.mode == "dark"
        return {
            foreground = dark and theme.palette.white or theme.palette.black,
            background = dark and theme.palette.black or theme.palette.white,
            accent = theme.palette.cyan,
        }
    end,
    -- Writes the file. An app never reads or writes files itself, it only calls `output`; kosm
    -- writes everything at the end, all or nothing.
    ---@param self scaffold_name.App
    apply = function(self, output)
        output:templateValue({ file = self.file, text = template }, {
            foreground = self.foreground,
            background = self.background,
            accent = self.accent,
        })
    end,
    -- To reload the program after an apply, add:
    -- reload = function(self, reloader)
    --     reloader:run({ "pkill", "-USR1", "-x", "scaffold_name" })
    -- end,
}
