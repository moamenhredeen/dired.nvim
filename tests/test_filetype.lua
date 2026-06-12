local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[filetype = require("dired.filetype")]])
        end,
        post_once = child.stop,
    },
})

T["get_filetype()"] = new_set()
T["get_filetype()"]["test/spec names take priority"] = function()
    eq(child.lua_get([[filetype.get_filetype("foo_test.lua", "file")]]), "test")
    eq(child.lua_get([[filetype.get_filetype("foo_spec.rb", "file")]]), "test")
end
T["get_filetype()"]["name-based overrides"] = function()
    eq(child.lua_get([[filetype.get_filetype("Dockerfile", "file")]]), "dockerfile")
    eq(child.lua_get([[filetype.get_filetype(".env", "file")]]), "env")
    eq(child.lua_get([[filetype.get_filetype(".gitignore", "file")]]), "git")
end
T["get_filetype()"]["falls back to vim.filetype.match"] = function()
    eq(child.lua_get([[filetype.get_filetype("init.lua", "file")]]), "lua")
end
T["get_filetype()"]["unknown extension falls back to text"] = function()
    eq(child.lua_get([[filetype.get_filetype("file.zzzunknown", "file")]]), "text")
end
T["get_filetype()"]["non-file scanner types pass through"] = function()
    eq(child.lua_get([[filetype.get_filetype("whatever", "directory")]]), "directory")
    eq(child.lua_get([[filetype.get_filetype("whatever", "link")]]), "link")
end

T["get_icon_by_filetype()"] = function()
    eq(child.lua_get([[type(filetype.get_icon_by_filetype("directory")) == "string"]]), true)
    eq(child.lua_get([[#filetype.get_icon_by_filetype("directory") > 0]]), true)
    -- unknown filetypes get the default icon, distinct from the directory one
    eq(child.lua_get([[
        filetype.get_icon_by_filetype("zzz-unknown") ~= filetype.get_icon_by_filetype("directory")
    ]]), true)
end

return T
