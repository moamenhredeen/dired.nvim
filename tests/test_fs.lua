local Helpers = dofile("tests/helpers.lua")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[fs = require("dired.fs")]])
            child.lua([[H = dofile("tests/helpers.lua")]])
        end,
        post_once = child.stop,
    },
})

-- pure path utils -----------------------------------------------------------

T["is_hidden()"] = function()
    eq(child.lua_get([[fs.is_hidden(".gitignore")]]), true)
    eq(child.lua_get([[fs.is_hidden("init.lua")]]), false)
end

T["get_filename()"] = new_set()
T["get_filename()"]["extracts from absolute path"] = function()
    eq(child.lua_get([[fs.get_filename("/a/b/c.txt")]]), "c.txt")
end
T["get_filename()"]["root-level file uses fallback"] = function()
    eq(child.lua_get([[fs.get_filename("/file")]]), "file")
end
T["get_filename()"]["no separator drops first char (characterization)"] = function()
    -- fallback is string.sub(filepath, 2): documented current behavior
    eq(child.lua_get([[fs.get_filename("plain")]]), "lain")
end

T["get_parent_path()"] = new_set()
T["get_parent_path()"]["keeps trailing separator"] = function()
    eq(child.lua_get([[fs.get_parent_path("/a/b/c.txt")]]), "/a/b/")
end
T["get_parent_path()"]["of root-level file is root"] = function()
    eq(child.lua_get([[fs.get_parent_path("/file")]]), "/")
end
T["get_parent_path()"]["no separator returns nil"] = function()
    eq(child.lua_get([[fs.get_parent_path("plain") == nil]]), true)
end

T["join_paths()"] = new_set()
T["join_paths()"]["joins with separator"] = function()
    eq(child.lua_get([[fs.join_paths("/tmp", "a", "b")]]), "/tmp/a/b")
end
T["join_paths()"]["strips trailing separators"] = function()
    eq(child.lua_get([[fs.join_paths("/tmp/", "a/", "b")]]), "/tmp/a/b")
end
T["join_paths()"]["root"] = function()
    eq(child.lua_get([[fs.join_paths("/", "etc")]]), "/etc")
end

-- filesystem integration ----------------------------------------------------

T["integration"] = new_set({
    hooks = {
        pre_case = function()
            child.lua([[
                tmp = H.make_temp_dir()
                H.populate(tmp, {
                    ["a.txt"] = "hello",
                    [".hidden"] = "h",
                    sub = { ["b.txt"] = "x", nested = { ["c.txt"] = "y" } },
                })
            ]])
        end,
        post_case = function()
            child.lua([[H.remove_dir(tmp)]])
        end,
    },
})

T["integration"]["file_exists()"] = function()
    eq(child.lua_get([[fs.file_exists(tmp .. "/a.txt")]]), true)
    eq(child.lua_get([[fs.file_exists(tmp .. "/missing")]]), false)
end

T["integration"]["is_directory()"] = function()
    eq(child.lua_get([[fs.is_directory(tmp .. "/sub")]]), true)
    eq(child.lua_get([[fs.is_directory(tmp .. "/a.txt")]]), false)
end

T["integration"]["get_symlink()"] = function()
    if Helpers.is_windows then
        MiniTest.skip("symlink creation needs elevated rights on Windows")
    end
    child.lua([[(vim.uv or vim.loop).fs_symlink(tmp .. "/a.txt", tmp .. "/link")]])
    eq(child.lua_get([[fs.get_symlink(tmp .. "/link")]]), child.lua_get([[tmp .. "/a.txt"]]))
    eq(child.lua_get([[fs.get_symlink(tmp .. "/a.txt") == nil]]), true)
end

T["integration"]["do_delete() removes tree recursively"] = function()
    child.lua([[
        _G.result = nil
        fs.do_delete(tmp .. "/sub", function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([[fs.file_exists(tmp .. "/sub")]]), false)
end

T["integration"]["do_delete() reports missing path"] = function()
    child.lua([[
        _G.result = nil
        fs.do_delete(tmp .. "/missing", function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.ok"), false)
end

T["integration"]["do_copy() copies single file"] = function()
    child.lua([[
        _G.result = nil
        fs.do_copy(tmp .. "/a.txt", tmp .. "/a2.txt", function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([=[vim.fn.readfile(tmp .. "/a2.txt")[1] ]=]), "hello")
end

T["integration"]["do_copy() copies directory recursively"] = function()
    child.lua([[
        _G.result = nil
        fs.do_copy(tmp .. "/sub", tmp .. "/sub2", function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([[fs.file_exists(tmp .. "/sub2/b.txt")]]), true)
    eq(child.lua_get([[fs.file_exists(tmp .. "/sub2/nested/c.txt")]]), true)
end

T["integration"]["do_copy() source == destination returns true early"] = function()
    child.lua([[
        _G.result = nil
        fs.do_copy(tmp .. "/a.txt", tmp .. "/a.txt", function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.ok"), true)
end

T["integration"]["do_copy() over existing directory wipes destination"] = function()
    child.lua([[
        H.populate(tmp, { sub2 = { ["stale.txt"] = "stale" } })
        _G.result = nil
        fs.do_copy(tmp .. "/sub", tmp .. "/sub2", function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([[fs.file_exists(tmp .. "/sub2/stale.txt")]]), false)
    eq(child.lua_get([[fs.file_exists(tmp .. "/sub2/b.txt")]]), true)
end

T["integration"]["do_copy() missing source fails"] = function()
    child.lua([[
        _G.result = nil
        fs.do_copy(tmp .. "/missing", tmp .. "/x", function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.ok"), false)
end

return T
