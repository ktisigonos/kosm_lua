-- The scaffold_name modifier, made by `kosm new modifier scaffold_name --language lua`. A Lua
-- kosmos sets `scaffold_name.modifier({})` wherever a modifier goes (a variation, an `andThen`
-- step), or calls `scaffold_name.modifier({ amount = 0.2 }):apply(color)` on a color; a Zig
-- kosmos uses it with `const scaffold_name = @import("scaffold_name");` alike.

-- The hue warmed toward, in degrees (orange).
local warm_hue = 60
-- The share of the way to `warm_hue` an amount of 1 goes.
local hue_share = 0.25

---@type kosm.modifier
return {
    --- Warms a color: shifts its hue toward orange and adds a little chroma.
    Modifier = {
        --- How far toward orange, 0..1. Default: 0.5.
        amount = kosm.float(0.5),
    },
    -- The color changed. Runs wherever the modifier is applied; an error here fails the apply
    -- before anything is written.
    ---@param self scaffold_name.Modifier
    apply = function(self, color)
        -- The shorter way round the wheel, -180..180 degrees.
        local toward_warm = (warm_hue - color.hue + 180) % 360 - 180
        local result = color
        result.hue = (color.hue + toward_warm * self.amount * hue_share) % 360
        result.chroma = color.chroma + 0.02 * self.amount
        return result
    end,
}
