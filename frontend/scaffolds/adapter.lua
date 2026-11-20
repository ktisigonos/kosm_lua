-- The scaffold_name adapter, made by `kosm new adapter scaffold_name --language lua`. Apps write
-- `.scaffold_name` files through it, or any file with `lang = "scaffold_name"`.

-- Every capability is optional: `serialize` lets apps generate whole files, `comment` lets them
-- write blocks, and `format` with `parser` lets them edit values by path.
return {
    name = "scaffold_name",
    extensions = { ".scaffold_name" },
    comment = { line = "#" },
    -- One `key = value` line per value. Nested tables and lists are refused.
    serialize = function(root)
        if root.kind ~= "table" then
            error("a scaffold_name file is a table of keys, not a " .. root.kind)
        end
        local lines = {}
        for _, entry in ipairs(root.value) do
            local value = entry.value
            local text
            if value.kind == "string" then
                text = '"' .. value.value .. '"'
            elseif value.kind == "raw" or value.kind == "integer" then
                text = tostring(value.value)
            elseif value.kind == "float" or value.kind == "boolean" or value.kind == "color" then
                -- Already spelled in the file's format.
                text = value.text
            else
                error("'" .. entry.key .. "' is a " .. value.kind .. "; scaffold_name files hold only plain values")
            end
            lines[#lines + 1] = entry.key .. " = " .. text .. "\n"
        end
        return table.concat(lines)
    end,
}
