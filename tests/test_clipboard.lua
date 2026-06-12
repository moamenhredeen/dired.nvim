local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[clipboard = require("dired.clipboard")]])
            child.lua([[H = dofile("tests/helpers.lua")]])
        end,
        post_once = child.stop,
    },
})

-- state ---------------------------------------------------------------------

T["state"] = new_set({
    hooks = {
        pre_case = function()
            child.lua([[a = { filepath = "/tmp/a" }]])
        end,
    },
})

T["state"]["add_file() and get_action()"] = function()
    child.lua([[clipboard.add_file(a, "copy")]])
    eq(child.lua_get([[clipboard.get_action(a)]]), "copy")
    eq(child.lua_get([[#clipboard.clipboard]]), 1)
end

T["state"]["re-adding same filepath updates action"] = function()
    child.lua([[clipboard.add_file(a, "move")]])
    child.lua([[clipboard.add_file(a, "copy")]])
    eq(child.lua_get([[clipboard.get_action(a)]]), "copy")
    eq(child.lua_get([[#clipboard.clipboard]]), 1)
end

T["state"]["remove_file()"] = function()
    child.lua([[clipboard.add_file(a, "copy")]])
    child.lua([[clipboard.remove_file(a)]])
    eq(child.lua_get([[clipboard.get_action(a) == nil]]), true)
    eq(child.lua_get([[#clipboard.clipboard]]), 0)
end

T["state"]["get_action() miss returns nil"] = function()
    eq(child.lua_get([[clipboard.get_action({ filepath = "/nope" }) == nil]]), true)
end

-- integration ---------------------------------------------------------------

T["integration"] = new_set({
    hooks = {
        pre_case = function()
            child.lua([[
                src = H.make_temp_dir()
                dst = H.make_temp_dir()
                H.populate(src, { ["a.txt"] = "hello" })
                vim.g.current_dired_path = dst
                function file_entry(dir, name)
                    return { filename = name, filepath = dir .. "/" .. name, parent_dir = dir }
                end
                -- tripwire: an unexpected prompt must fail assertions instead
                -- of blocking the embedded child forever
                vim.fn.input = function() return "" end
            ]])
        end,
        post_case = function()
            child.lua([[H.remove_dir(src); H.remove_dir(dst)]])
        end,
    },
})

T["integration"]["copy_files() copies foreign file into current dir"] = function()
    child.lua([[
        _G.done = nil
        clipboard.copy_files({ file_entry(src, "a.txt") }, function(ok) _G.done = ok end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.done ~= nil end), "timeout")]])
    eq(child.lua_get("_G.done"), true)
    eq(child.lua_get([=[vim.fn.readfile(dst .. "/a.txt")[1] ]=]), "hello")
    -- source untouched
    eq(child.lua_get([[vim.fn.filereadable(src .. "/a.txt")]]), 1)
end

T["integration"]["copy_files() skips files already in current dir"] = function()
    child.lua([[
        H.populate(dst, { ["b.txt"] = "local" })
        _G.done = nil
        clipboard.copy_files({ file_entry(dst, "b.txt") }, function(ok) _G.done = ok end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.done ~= nil end), "timeout")]])
    eq(child.lua_get("_G.done"), true)
    eq(child.lua_get([=[vim.fn.readfile(dst .. "/b.txt")[1] ]=]), "local")
end

T["integration"]["copy_files() overwrite confirmed with yes"] = function()
    child.lua([[
        H.populate(dst, { ["a.txt"] = "old" })
        vim.fn.input = function() return "yes" end
        _G.done = nil
        clipboard.copy_files({ file_entry(src, "a.txt") }, function(ok) _G.done = ok end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.done ~= nil end), "timeout")]])
    eq(child.lua_get([=[vim.fn.readfile(dst .. "/a.txt")[1] ]=]), "hello")
end

T["integration"]["copy_files() overwrite declined with no"] = function()
    child.lua([[
        H.populate(dst, { ["a.txt"] = "old" })
        vim.fn.input = function() return "no" end
        _G.done = nil
        clipboard.copy_files({ file_entry(src, "a.txt") }, function(ok) _G.done = ok end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.done ~= nil end), "timeout")]])
    eq(child.lua_get([=[vim.fn.readfile(dst .. "/a.txt")[1] ]=]), "old")
end

T["integration"]["move_files() moves file into current dir"] = function()
    child.lua([[
        _G.done = nil
        clipboard.move_files({ file_entry(src, "a.txt") }, function(ok) _G.done = ok end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.done ~= nil end), "timeout")]])
    eq(child.lua_get("_G.done"), true)
    eq(child.lua_get([=[vim.fn.readfile(dst .. "/a.txt")[1] ]=]), "hello")
    eq(child.lua_get([[vim.fn.filereadable(src .. "/a.txt")]]), 0)
end

T["integration"]["do_action() dispatches copy and move, then clears clipboard"] = function()
    child.lua([[
        H.populate(src, { ["c.txt"] = "copy me", ["m.txt"] = "move me" })
        clipboard.add_file(file_entry(src, "c.txt"), "copy")
        clipboard.add_file(file_entry(src, "m.txt"), "move")
        _G.done = nil
        clipboard.do_action(function(ok) _G.done = ok end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.done ~= nil end), "timeout")]])
    eq(child.lua_get("_G.done"), true)
    eq(child.lua_get([[vim.fn.filereadable(dst .. "/c.txt")]]), 1)
    eq(child.lua_get([[vim.fn.filereadable(src .. "/c.txt")]]), 1)
    eq(child.lua_get([[vim.fn.filereadable(dst .. "/m.txt")]]), 1)
    eq(child.lua_get([[vim.fn.filereadable(src .. "/m.txt")]]), 0)
    eq(child.lua_get([[#clipboard.clipboard]]), 0)
end

return T
