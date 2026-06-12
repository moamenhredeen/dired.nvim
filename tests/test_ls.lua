local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[ls = require("dired.ls")]])
            child.lua([[H = dofile("tests/helpers.lua")]])
        end,
        post_once = child.stop,
    },
})

-- pure ----------------------------------------------------------------------

T["get_permission_str()"] = new_set()
T["get_permission_str()"]["regular file 644"] = function()
    eq(child.lua_get([[ls.get_permission_str(33188)]]), "-rw-r--r--") -- 0o100644
end
T["get_permission_str()"]["directory 755"] = function()
    eq(child.lua_get([[ls.get_permission_str(16877)]]), "drwxr-xr-x") -- 0o40755
end
T["get_permission_str()"]["setuid with exec shows s"] = function()
    eq(child.lua_get([[ls.get_permission_str(35309)]]), "-rwsr-xr-x") -- 0o104755
end
T["get_permission_str()"]["setgid without group exec shows l"] = function()
    eq(child.lua_get([[ls.get_permission_str(34212)]]), "-rw-r-lr--") -- 0o102644
end
T["get_permission_str()"]["sticky with other exec shows t"] = function()
    eq(child.lua_get([[ls.get_permission_str(17407)]]), "drwxrwxrwt") -- 0o41777
end

T["get_file_by_filename()"] = new_set()
T["get_file_by_filename()"]["finds by name"] = function()
    eq(
        child.lua_get([[(function()
            local files = { { filename = "a" }, { filename = "b" } }
            return ls.get_file_by_filename(files, "b").filename
        end)()]]),
        "b"
    )
end
T["get_file_by_filename()"]["miss returns nil"] = function()
    eq(child.lua_get([[ls.get_file_by_filename({ { filename = "a" } }, "z") == nil]]), true)
end
T["get_file_by_filename()"]["symlink listing splits on arrow"] = function()
    eq(
        child.lua_get([[(function()
            local files = { { filename = "link" } }
            return ls.get_file_by_filename(files, "link -> /target").filename
        end)()]]),
        "link"
    )
end

-- integration ---------------------------------------------------------------

T["integration"] = new_set({
    hooks = {
        pre_case = function()
            child.lua([[
                tmp = H.make_temp_dir()
                H.populate(tmp, { ["a.txt"] = "hello", [".hidden"] = "h", sub = {} })
            ]])
        end,
        post_case = function()
            child.lua([[H.remove_dir(tmp)]])
        end,
    },
})

T["integration"]["fs_entry.new() builds entry from stat"] = function()
    child.lua([[entry = ls.fs_entry.new("a.txt", tmp, "text")]])
    eq(child.lua_get([[entry.filename]]), "a.txt")
    eq(child.lua_get([[entry.filepath]]), child.lua_get([[tmp .. "/a.txt"]]))
    eq(child.lua_get([[entry.parent_dir]]), child.lua_get([[tmp]]))
    eq(child.lua_get([[entry.filetype]]), "text")
    eq(child.lua_get([[entry.size > 0]]), true)
    eq(child.lua_get([[type(entry.mode)]]), "number")
    eq(child.lua_get([[type(entry.stat)]]), "table")
end

T["integration"]["fs_entry.new() missing file returns nil, err"] = function()
    eq(
        child.lua_get([[(function()
            local entry, err = ls.fs_entry.new("missing", tmp, "text")
            return entry == nil and err ~= nil
        end)()]]),
        true
    )
end

T["integration"]["fs_entry.get_directory() lists dot dirs and files"] = function()
    child.lua([[
        files = ls.fs_entry.get_directory(tmp)
        names = {}
        for _, f in ipairs(files) do
            names[f.filename] = true
        end
    ]])
    eq(child.lua_get([[names["."] ]]), true)
    eq(child.lua_get([[names[".."] ]]), true)
    eq(child.lua_get([[names["a.txt"] ]]), true)
    eq(child.lua_get([[names[".hidden"] ]]), true)
    eq(child.lua_get([[names["sub"] ]]), true)
    eq(child.lua_get([[type(files.size)]]), "number")
end

T["integration"]["fs_entry.format() filters hidden files but keeps dot dirs"] = function()
    child.lua([[
        local files = ls.fs_entry.get_directory(tmp)
        comps = ls.fs_entry.format(files, true, false, false, false)
        shown = {}
        for _, c in ipairs(comps) do
            shown[c.filename] = true
        end
    ]])
    eq(child.lua_get([[shown["."] ]]), true)
    eq(child.lua_get([[shown[".."] ]]), true)
    eq(child.lua_get([[shown["a.txt"] ]]), true)
    eq(child.lua_get([[shown[".hidden"] ]]), vim.NIL)
end

T["integration"]["fs_entry.format() hide_details strips components"] = function()
    eq(
        child.lua_get([[(function()
            local files = ls.fs_entry.get_directory(tmp)
            local comps = ls.fs_entry.format(files, true, true, true, false)
            local c = comps[1]
            return c.permissions == nil and c.size == nil and c.filename ~= nil and c.fs_t ~= nil
        end)()]]),
        true
    )
end

T["integration"]["fs_entry.format() pads columns consistently"] = function()
    eq(
        child.lua_get([[(function()
            local files = ls.fs_entry.get_directory(tmp)
            local comps = ls.fs_entry.format(files, true, true, false, false)
            local w = nil
            for _, c in ipairs(comps) do
                w = w or #c.size
                if #c.size ~= w then
                    return false
                end
            end
            return true
        end)()]]),
        true
    )
end

return T
