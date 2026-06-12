local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[
                marker = require("dired.marker")
                a = { filepath = "/tmp/a" }
                b = { filepath = "/tmp/b" }
            ]])
        end,
        post_once = child.stop,
    },
})

T["mark_file() marks a file"] = function()
    child.lua([[marker.mark_file(a)]])
    eq(child.lua_get([[marker.is_marked(a)]]), true)
    eq(child.lua_get([[#marker.marked_files]]), 1)
end

T["mark_file() twice unmarks (toggle, characterization)"] = function()
    child.lua([[marker.mark_file(a)]])
    child.lua([[marker.mark_file(a)]])
    eq(child.lua_get([[marker.is_marked(a)]]), false)
    eq(child.lua_get([[#marker.marked_files]]), 0)
end

T["is_marked() with remove flag removes"] = function()
    child.lua([[marker.mark_file(a)]])
    eq(child.lua_get([[marker.is_marked(a, true)]]), true)
    eq(child.lua_get([[marker.is_marked(a)]]), false)
end

T["files are tracked independently by filepath"] = function()
    child.lua([[marker.mark_file(a)]])
    child.lua([[marker.mark_file(b)]])
    eq(child.lua_get([[#marker.marked_files]]), 2)
    child.lua([[marker.is_marked(a, true)]])
    eq(child.lua_get([[marker.is_marked(a)]]), false)
    eq(child.lua_get([[marker.is_marked(b)]]), true)
end

return T
