local Helpers = dofile("tests/helpers.lua")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[funcs = require("dired.functions")]])
            child.lua([[H = dofile("tests/helpers.lua")]])
            child.lua([[
                tmp = H.make_temp_dir()
                H.populate(tmp, { ["a.txt"] = "hello", sub = { ["b.txt"] = "x" } })
                vim.g.current_dired_path = tmp
                function file_entry(name, filetype)
                    return {
                        filename = name,
                        filepath = tmp .. "/" .. name,
                        parent_dir = tmp,
                        filetype = filetype or "text",
                    }
                end
                function stub_input(answer)
                    vim.fn.input = function() return answer end
                end
                -- tripwire: an unexpected prompt must fail assertions instead
                -- of blocking the embedded child forever
                stub_input("")
            ]])
        end,
        post_case = function()
            child.lua([[H.remove_dir(tmp)]])
        end,
        post_once = child.stop,
    },
})

-- create_file (sync) ----------------------------------------------------------

T["create_file()"] = new_set()
T["create_file()"]["creates a file"] = function()
    child.lua([[stub_input("new.txt"); funcs.create_file()]])
    eq(child.lua_get([[vim.fn.filereadable(tmp .. "/new.txt")]]), 1)
end
T["create_file()"]["trailing separator creates a directory"] = function()
    child.lua([[stub_input("newdir/"); funcs.create_file()]])
    eq(child.lua_get([[vim.fn.isdirectory(tmp .. "/newdir")]]), 1)
end
T["create_file()"]["empty input is a no-op"] = function()
    child.lua([[stub_input(""); funcs.create_file()]])
    eq(child.lua_get([[#vim.fn.glob(tmp .. "/*", true, true)]]), 2)
end

-- rename_file (sync) ----------------------------------------------------------

T["rename_file()"] = function()
    child.lua([[stub_input("renamed.txt"); funcs.rename_file(file_entry("a.txt"))]])
    eq(child.lua_get([[vim.fn.filereadable(tmp .. "/a.txt")]]), 0)
    eq(child.lua_get([=[vim.fn.readfile(tmp .. "/renamed.txt")[1] ]=]), "hello")
    eq(child.lua_get([[require("dired.display").goto_filename]]), "renamed.txt")
end

-- delete_file (async) ---------------------------------------------------------

local function wait_result()
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
end

T["delete_file()"] = new_set()
T["delete_file()"]["deletes file without asking"] = function()
    child.lua([[
        _G.result = nil
        funcs.delete_file(file_entry("a.txt"), false, function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([[vim.fn.filereadable(tmp .. "/a.txt")]]), 0)
end
T["delete_file()"]["deletes directory recursively"] = function()
    child.lua([[
        _G.result = nil
        funcs.delete_file(file_entry("sub", "directory"), false, function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([[vim.fn.isdirectory(tmp .. "/sub")]]), 0)
end
T["delete_file()"]["ask=true with yes deletes"] = function()
    child.lua([[
        stub_input("yes")
        _G.result = nil
        funcs.delete_file(file_entry("a.txt"), true, function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([[vim.fn.filereadable(tmp .. "/a.txt")]]), 0)
end
T["delete_file()"]["ask=true with no keeps file and reports cancelled"] = function()
    child.lua([[
        stub_input("no")
        _G.result = nil
        funcs.delete_file(file_entry("a.txt"), true, function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), false)
    eq(child.lua_get("_G.result.err"), "cancelled")
    eq(child.lua_get([[vim.fn.filereadable(tmp .. "/a.txt")]]), 1)
end
T["delete_file()"]["refuses dot entries"] = function()
    child.lua([[
        _G.result = nil
        funcs.delete_file(file_entry(".", "directory"), false, function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), false)
    eq(child.lua_get("_G.result.err"), "refused")
end

-- duplicate_file (async) ------------------------------------------------------

T["duplicate_file()"] = new_set()
T["duplicate_file()"]["duplicates a file"] = function()
    child.lua([[
        stub_input("copy.txt")
        _G.result = nil
        funcs.duplicate_file(file_entry("a.txt"), function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([=[vim.fn.readfile(tmp .. "/copy.txt")[1] ]=]), "hello")
    eq(child.lua_get([[vim.fn.filereadable(tmp .. "/a.txt")]]), 1)
    eq(child.lua_get([[require("dired.display").goto_filename]]), "copy.txt")
end
T["duplicate_file()"]["duplicates a directory recursively"] = function()
    child.lua([[
        stub_input("sub2")
        _G.result = nil
        funcs.duplicate_file(file_entry("sub", "directory"), function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), true)
    eq(child.lua_get([[vim.fn.filereadable(tmp .. "/sub2/b.txt")]]), 1)
end
T["duplicate_file()"]["refuses existing destination"] = function()
    child.lua([[
        H.populate(tmp, { ["taken.txt"] = "x" })
        stub_input("taken.txt")
        _G.result = nil
        funcs.duplicate_file(file_entry("a.txt"), function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), false)
    eq(child.lua_get("_G.result.err"), "exists")
end
T["duplicate_file()"]["same name is cancelled"] = function()
    child.lua([[
        stub_input("a.txt")
        _G.result = nil
        funcs.duplicate_file(file_entry("a.txt"), function(ok, err) _G.result = { ok = ok, err = err } end)
    ]])
    wait_result()
    eq(child.lua_get("_G.result.ok"), false)
    eq(child.lua_get("_G.result.err"), "cancelled")
end

-- touch / chmod (sync) --------------------------------------------------------

T["touch_files() updates timestamps"] = function()
    eq(
        child.lua_get([[(function()
            local uv = vim.uv or vim.loop
            local path = tmp .. "/a.txt"
            uv.fs_utime(path, 1000, 1000)
            local before = uv.fs_stat(path).mtime.sec
            local ok = funcs.touch_files({ file_entry("a.txt") })
            local after = uv.fs_stat(path).mtime.sec
            return ok == true and before == 1000 and after > before
        end)()]]),
        true
    )
end

T["chmod_files() applies octal mode"] = function()
    if Helpers.is_windows then
        MiniTest.skip("chmod is not meaningful on Windows")
    end
    eq(
        child.lua_get([[(function()
            local uv = vim.uv or vim.loop
            stub_input("600")
            local ok = funcs.chmod_files({ file_entry("a.txt") })
            local mode = uv.fs_stat(tmp .. "/a.txt").mode % 512
            return ok == true and mode == 384 -- 0o600
        end)()]]),
        true
    )
end

return T
