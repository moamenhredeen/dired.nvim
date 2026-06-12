local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[async = require("dired.async")]])
        end,
        post_once = child.stop,
    },
})

T["run() reports fn return values"] = function()
    child.lua([[
        _G.result = nil
        async.run(function()
            return true
        end, function(success, errmsg)
            _G.result = { success = success, errmsg = errmsg }
        end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.success"), true)
end

T["run() reports failure with errmsg"] = function()
    child.lua([[
        _G.result = nil
        async.run(function()
            return false, "boom"
        end, function(success, errmsg)
            _G.result = { success = success, errmsg = errmsg }
        end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.success"), false)
    eq(child.lua_get("_G.result.errmsg"), "boom")
end

T["run() turns raised errors into on_done(false) exactly once"] = function()
    child.lua([[
        _G.calls = 0
        _G.result = nil
        async.run(function()
            error("exploded")
        end, function(success, errmsg)
            _G.calls = _G.calls + 1
            _G.result = { success = success, errmsg = errmsg }
        end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result.success"), false)
    eq(child.lua_get([[_G.result.errmsg:find("exploded") ~= nil]]), true)
    eq(child.lua_get("_G.calls"), 1)
end

T["await() returns uv callback values"] = function()
    child.lua([[
        local uv = vim.uv or vim.loop
        _G.result = nil
        local tmp = vim.fn.tempname():gsub("\\", "/")
        vim.fn.writefile({ "x" }, tmp)
        async.run(function()
            local err, stat = async.await(uv.fs_stat, tmp)
            return err == nil and stat ~= nil and stat.type == "file"
        end, function(success)
            _G.result = success
            vim.fn.delete(tmp)
        end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result"), true)
end

T["await() preserves nil err hole on error results"] = function()
    child.lua([[
        local uv = vim.uv or vim.loop
        _G.result = nil
        async.run(function()
            local err, stat = async.await(uv.fs_stat, "/definitely/not/here")
            return err ~= nil and stat == nil
        end, function(success)
            _G.result = success
        end)
    ]])
    child.lua([[assert(vim.wait(5000, function() return _G.result ~= nil end), "timeout")]])
    eq(child.lua_get("_G.result"), true)
end

T["await() outside run() raises"] = function()
    eq(child.lua_get([[pcall(async.await, function() end)]]), false)
end

return T
