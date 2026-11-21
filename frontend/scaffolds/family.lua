-- The scaffold_name variation family, made by `kosm new family scaffold_name --language lua`. A
-- base holds it beside the theme, `scaffold_name.from(theme.mode)`, hands it to the apps reading
-- it, and a kosmos tweaks it there once for all of them: `family.soft.lightness = 0.1`.

---@type kosm.family
return {
    --- Glows for highlighted elements, applied to any color with `family.soft:apply(color)`.
    Family = {
        --- A soft glow. Default: a little lighter in dark mode, darker in light mode.
        soft = kosm.Modifier,
        --- A strong glow. Default: lighter and more saturated in dark mode, darker in light mode.
        strong = kosm.Modifier,
    },
    -- The family's modifiers for `mode`, "dark" or "light".
    from = function(mode)
        if mode == "dark" then
            return { soft = { lightness = 0.05 }, strong = { lightness = 0.12, chroma = 0.03 } }
        end
        return { soft = { lightness = -0.05 }, strong = { lightness = -0.12, chroma = 0.03 } }
    end,
}
