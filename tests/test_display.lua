local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[display = require("dired.display")]])
        end,
        post_once = child.stop,
    },
})

T["get_filename_from_listing() without icons (8 columns)"] = new_set()
T["get_filename_from_listing() without icons (8 columns)"]["plain filename"] = function()
    child.g.dired_show_icons = false
    eq(
        child.lua_get([[display.get_filename_from_listing(
            "-rw-r--r-- 1 user group 1024 Jan 1 12:00 a.txt")]]),
        "a.txt"
    )
end
T["get_filename_from_listing() without icons (8 columns)"]["filename with spaces"] = function()
    child.g.dired_show_icons = false
    eq(
        child.lua_get([[display.get_filename_from_listing(
            "-rw-r--r-- 1 user group 1024 Jan 1 12:00 my file.txt")]]),
        "my file.txt"
    )
end
T["get_filename_from_listing() without icons (8 columns)"]["malformed line returns nil"] = function()
    child.g.dired_show_icons = false
    eq(child.lua_get([[display.get_filename_from_listing("just three tokens") == nil]]), true)
end

T["get_filename_from_listing() with icons (9 columns)"] = function()
    child.g.dired_show_icons = true
    eq(
        child.lua_get([[display.get_filename_from_listing(
            "-rw-r--r-- 1 user group 1024 Jan 1 12:00 X  b.txt")]]),
        "b.txt"
    )
end

return T
