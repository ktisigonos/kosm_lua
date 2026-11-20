-- The scaffold_name kosmos, made by `kosm new kosmos scaffold_name --language lua`. Apply it with
-- `kosm apply scaffold_name`, or add `--diff` to see what it would change first.

-- Black and white are required; every hue left out is mixed from its wheel neighbours.
local palette = {
    black = "#12161c",
    white = "#d8dee9",
    red = "#c2626b",
    yellow = "#d9b56f",
    cyan = "#6fb3c2",
}

-- This kosmos builds on no other, so it gives the theme every app is built from, and the apps it
-- names in `overrides` are the ones applied. To build on another kosmos instead, give its name
-- as `base = "kyanos"` and set values on its tree in `overrides`.
local function build(mode)
    ---@type kosm.script
    return {
        theme = { palette = palette, mode = mode },
        overrides = {
            -- Apps come from installed packages (`kosm list --apps` shows them) or your own apps/.
            kitty = { fonts = { font_size = 12 } },
        },
    }
end

return {
    -- `kosm apply scaffold_name`.
    kosmos = function()
        return build("dark")
    end,
    -- A variant: `kosm apply scaffold_name.light`.
    light = function()
        return build("light")
    end,
}
