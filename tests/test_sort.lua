local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[
                sort = require("dired.sort")
                function entry(filename, filetype, mtime)
                    return {
                        component = {
                            fs_t = {
                                filename = filename,
                                filetype = filetype,
                                stat = { mtime = { sec = mtime } },
                            },
                        },
                    }
                end
                function names(entries)
                    return vim.tbl_map(function(e)
                        return e.component.fs_t.filename
                    end, entries)
                end
            ]])
        end,
        post_once = child.stop,
    },
})

T["sort_by_name() is case-insensitive"] = function()
    eq(
        child.lua_get([[(function()
            local t = { entry("b.txt", "file", 1), entry("A.txt", "file", 2), entry("c.txt", "file", 3) }
            table.sort(t, sort.sort_by_name)
            return names(t)
        end)()]]),
        { "A.txt", "b.txt", "c.txt" }
    )
end

T["sort_by_date() orders by mtime ascending"] = function()
    eq(
        child.lua_get([[(function()
            local t = { entry("new", "file", 300), entry("old", "file", 100), entry("mid", "file", 200) }
            table.sort(t, sort.sort_by_date)
            return names(t)
        end)()]]),
        { "old", "mid", "new" }
    )
end

T["sort_by_dirs() lists directories first"] = function()
    eq(
        child.lua_get([[(function()
            local t = {
                entry("zfile", "file", 1),
                entry("zdir", "directory", 1),
                entry("afile", "file", 1),
                entry("adir", "directory", 1),
            }
            table.sort(t, sort.sort_by_dirs)
            return names(t)
        end)()]]),
        { "adir", "zdir", "afile", "zfile" }
    )
end

return T
