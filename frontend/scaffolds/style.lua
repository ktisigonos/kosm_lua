-- The scaffold_name palette style, made by `kosm new style scaffold_name --language lua`. A kosmos
-- takes an image's colors with it by giving `scaffold_name.style({})` as the image's style; a
-- Zig kosmos uses it with `const scaffold_name = @import("scaffold_name");` alike.

---@type kosm.style
return {
    --- Takes each hue of an image softened: less chroma, then readable on the background.
    Style = {
        --- The share of each hue's chroma kept, 0..1. Default: 0.6.
        chroma = kosm.float(0.6),
        --- The WCAG 2 contrast ratio (1..21) every hue keeps against the background. Default: 4.5.
        contrast = kosm.float(4.5),
    },
    -- The final color of `hue`, taken from an image whose theme has `background`.
    ---@param self scaffold_name.Style
    apply = function(self, hue, background)
        local soft = hue
        soft.chroma = hue.chroma * self.chroma
        return kosm.Image.readable(soft, background, self.contrast)
    end,
}
