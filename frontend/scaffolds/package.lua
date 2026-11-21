-- The scaffold_name package, made by `kosm new package scaffold_name --language lua`: its root holds
-- one app. Once a config adds it (`kosm add`), a Lua kosmos sets it in its `overrides` as
-- `scaffold_name = { ... }`; a Zig kosmos uses it like any app, with
-- `const scaffold_name = @import("scaffold_name");` and a field `scaffold_name: scaffold_name.App`
-- set to `scaffold_name.from(theme)`.

-- The colors the file holds, in its order.
local colors = { "foreground", "background", "accent" }

---@type kosm.app
return {
    -- Every setting of the program, as plain fields a kosmos can assign. `from` fills those that
    -- come from the theme; the rest have defaults.
    App = {
        --- The file kosm writes. Default: `~/.config/scaffold_name/colors.conf`.
        file = kosm.text("~/.config/scaffold_name/colors.conf"),
        --- Text; null leaves the program's own. Default: white, black in light mode.
        foreground = kosm.optional(kosm.Color),
        --- Background; null leaves the program's own. Default: black, white in light mode.
        background = kosm.optional(kosm.Color),
        --- The accent; null leaves the program's own. Default: cyan.
        accent = kosm.optional(kosm.Color),
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
        -- A line `<name> = kosm.<name>` for each color set; `kosm.<name>` is replaced by `values.<name>`.
        local lines, values = {}, {}
        for _, name in ipairs(colors) do
            if self[name] then
                lines[#lines + 1] = name .. " = kosm." .. name .. "\n"
                values[name] = self[name]
            end
        end
        output:templateValue({ file = self.file, text = table.concat(lines) }, values)
    end,
    -- To reload the program after an apply, add:
    -- reload = function(self, reloader)
    --     reloader:run({ "pkill", "-USR1", "-x", "scaffold_name" })
    -- end,
}
