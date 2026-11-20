-- The scaffold_name frontend, made by `kosm new frontend scaffold_name --language lua`. It reads
-- kosmoi written as `kosmoi/<name>.scaffold_name`, one setting per line:
--
--     # A comment.
--     base kyanos
--     kitty.fonts.font_size = 12

-- `value` as a number or boolean where it spells one, else as text, which also names an enum
-- value or a color ("dark", "#88c0d0").
local function typed(value)
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end
    return tonumber(value) or value
end

-- `load` is required; `variants`, `complete` and `editor_file` are optional.
return {
    name = "scaffold_name",
    extensions = { ".scaffold_name" },
    -- Reads `base <kosmos>` and `<path> = <value>` lines, each value as `typed` reads it. `path`
    -- is the kosmos' place, as "kosmoi/mine.scaffold_name".
    load = function(source, path, variant)
        local kosmos = { overrides = {} }
        local number = 0
        for untrimmed in (source .. "\n"):gmatch("(.-)\n") do
            number = number + 1
            local place = path .. ":" .. number
            local line = untrimmed:match("^%s*(.-)%s*$")
            if line ~= "" and line:sub(1, 1) ~= "#" then
                local base = line:match("^base%s+(.+)$")
                local key, value = line:match("^(.-)%s*=%s*(.*)$")
                if base then
                    kosmos.base = base
                elseif key then
                    -- Each segment of the path is a table inside the one before.
                    local tables = kosmos.overrides
                    local last
                    for segment in key:gmatch("[^.]+") do
                        if last then
                            tables[last] = tables[last] or {}
                            tables = tables[last]
                        end
                        last = segment
                    end
                    tables[last] = kosm.at(place, typed(value))
                else
                    error(place .. ": expected 'base <kosmos>' or '<path> = <value>'", 0)
                end
            end
        end
        return kosmos
    end,
}
