local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[config = require("dired.config")]])
        end,
        post_once = child.stop,
    },
})

T["update()"] = new_set()
T["update()"]["empty opts produce no errors and keep defaults"] = function()
    eq(child.lua_get([[config.update({})]]), {})
    eq(child.lua_get([[config.get("show_hidden")]]), true)
    eq(child.lua_get([[config.get("show_icons")]]), false)
    eq(child.lua_get([[config.get("path_separator")]]), "/")
end

T["update()"]["stores valid values"] = function()
    eq(child.lua_get([[config.update({ show_hidden = false })]]), {})
    eq(child.lua_get([[config.get("show_hidden")]]), false)
end

T["update()"]["rejects wrong types"] = function()
    eq(
        child.lua_get([[config.update({ show_hidden = "yes" })[1] ]]),
        "`show_hidden` Must be boolean, instead received string"
    )
    -- invalid value is not stored
    eq(child.lua_get([[config.get("show_hidden")]]), true)
end

T["update()"]["validates path_separator length"] = function()
    eq(
        child.lua_get([[config.update({ path_separator = "ab" })[1] ]]),
        "`path_separator` Must be string of length 1, instead received string of length 2"
    )
    eq(
        child.lua_get([[config.update({ path_separator = 5 })[1] ]]),
        "`path_separator` Must be string of length 1, instead received number"
    )
end

T["update()"]["maps sort_order strings to functions"] = function()
    eq(child.lua_get([[config.update({ sort_order = "date" })]]), {})
    eq(child.lua_get([[config.get("sort_order") == require("dired.sort").sort_by_date]]), true)
end

T["update()"]["accepts sort_order function"] = function()
    eq(child.lua_get([[config.update({ sort_order = function() return true end })]]), {})
    eq(child.lua_get([[type(config.get("sort_order"))]]), "function")
end

T["update()"]["rejects unknown sort_order"] = function()
    eq(
        child.lua_get([[config.update({ sort_order = "bogus" })[1] ]]),
        '`sort_order` Must be one of {"name", "dirs", "date", or function}'
    )
end

T["update()"]["merges user keybinds over defaults"] = function()
    eq(child.lua_get([[config.update({ keybinds = { dired_enter = "o" } })]]), {})
    eq(child.lua_get([[config.get("keybinds").dired_enter]]), "o")
    eq(child.lua_get([[config.get("keybinds").dired_quit]]), "q")
end

T["update()"]["validates colors"] = function()
    eq(
        child.lua_get([[config.update({ colors = { DiredNormal = {} } })[1] ]]),
        "`colors` Must contain a link element for each highlight group"
    )
    eq(
        child.lua_get([[config.update({ colors = { DiredNormal = { link = "Normal" } } })[1] ]]),
        "`colors` link must be a table of highlight groups for DiredNormal"
    )
    eq(
        child.lua_get([[config.update({ colors = { DiredNormal = { link = { "Normal" }, bg = 5 } } })[1] ]]),
        "`colors` bg must be a string when provided for DiredNormal"
    )
end

T["update()"]["reports unrecognised options (characterization: missing space)"] = function()
    eq(child.lua_get([[config.update({ totally_bogus = 1 })[1] ]]), "`totally_bogus`not recognised")
end

T["get() raises on unknown option"] = function()
    eq(child.lua_get([[pcall(config.get, "nonexistent")]]), false)
end

T["get_sort_order()"] = function()
    eq(child.lua_get([[config.get_sort_order("name") == require("dired.sort").sort_by_name]]), true)
    eq(child.lua_get([[config.get_sort_order("dirs") == require("dired.sort").sort_by_dirs]]), true)
    eq(child.lua_get([[config.get_sort_order("date") == require("dired.sort").sort_by_date]]), true)
    eq(child.lua_get([[config.get_sort_order("bogus") == nil]]), true)
end

T["get_next_sort_order() cycles name -> date -> dirs -> name"] = function()
    child.g.dired_sort_order = "name"
    eq(child.lua_get([[config.get_next_sort_order()]]), "date")
    child.g.dired_sort_order = "date"
    eq(child.lua_get([[config.get_next_sort_order()]]), "dirs")
    child.g.dired_sort_order = "dirs"
    eq(child.lua_get([[config.get_next_sort_order()]]), "name")
end

return T
