local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[history = require("dired.history")]])
        end,
        post_once = child.stop,
    },
})

T["push/pop is LIFO"] = function()
    child.lua([[history.push_path("/a")]])
    child.lua([[history.push_path("/b")]])
    eq(child.lua_get([[history.pop_path()]]), "/b")
    eq(child.lua_get([[history.pop_path()]]), "/a")
end

T["pop on empty stack returns nil"] = function()
    eq(child.lua_get([[history.pop_path() == nil]]), true)
end

T["push nil is a no-op"] = function()
    child.lua([[history.push_path(nil)]])
    eq(child.lua_get([[history.pop_path() == nil]]), true)
end

T["stack is buffer-local"] = function()
    child.lua([[history.push_path("/a")]])
    child.cmd("new")
    eq(child.lua_get([[history.pop_path() == nil]]), true)
    child.cmd("close")
    eq(child.lua_get([[history.pop_path()]]), "/a")
end

return T
