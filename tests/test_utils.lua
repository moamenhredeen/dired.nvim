local Helpers = dofile("tests/helpers.lua")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua([[utils = require("dired.utils")]])
        end,
        post_once = child.stop,
    },
})

T["str_split()"] = new_set()
T["str_split()"]["splits on plain separator"] = function()
    eq(child.lua_get([[utils.str_split("a,b,c", ",", true)]]), { "a", "b", "c" })
end
T["str_split()"]["default separator is whitespace"] = function()
    eq(child.lua_get([[utils.str_split("a  b\tc")]]), { "a", "b", "c" })
end
T["str_split()"]["trailing separator yields trailing empty string"] = function()
    eq(child.lua_get([[utils.str_split("a,", ",", true)]]), { "a", "" })
end
T["str_split()"]["empty separator splits into characters"] = function()
    eq(child.lua_get([[utils.str_split("abc", "")]]), { "a", "b", "c" })
end
T["str_split()"]["empty-matching separator raises"] = function()
    eq(child.lua_get([[pcall(utils.str_split, "abc", "x*")]]), false)
end

T["replace_char()"] = function()
    eq(child.lua_get([[utils.replace_char(2, "abc", "X")]]), "aXc")
    eq(child.lua_get([[utils.replace_char(1, "abc", "X")]]), "Xbc")
end

T["concatenate_tables() appends and returns first table"] = function()
    eq(child.lua_get([[utils.concatenate_tables({ 1, 2 }, { 3, 4 })]]), { 1, 2, 3, 4 })
end

T["find()"] = function()
    eq(child.lua_get([[utils.find({ "a", "b", "c" }, "b")]]), 2)
    eq(child.lua_get([[utils.find({ "a" }, "z") == nil]]), true)
end

T["get_short_size()"] = new_set()
T["get_short_size()"]["bytes stay plain"] = function()
    eq(child.lua_get([[utils.get_short_size(0)]]), "0")
    eq(child.lua_get([[utils.get_short_size(1023)]]), "1023")
end
T["get_short_size()"]["1024 stays plain (strict >, characterization)"] = function()
    eq(child.lua_get([[utils.get_short_size(1024)]]), "1024")
end
T["get_short_size()"]["1025 becomes 1.0K"] = function()
    eq(child.lua_get([[utils.get_short_size(1025)]]), "1.0K")
end
T["get_short_size()"]["1MiB reported as 1024.0K (characterization)"] = function()
    eq(child.lua_get([[utils.get_short_size(1048576)]]), "1024.0K")
end
T["get_short_size()"]["larger sizes climb units"] = function()
    eq(child.lua_get([[utils.get_short_size(1048577)]]), "1.0M")
end

T["bit operations"] = function()
    -- 33188 == octal 100644 (regular file rw-r--r--)
    eq(child.lua_get([[utils.bitand(33188, 61440)]]), 32768)
    eq(child.lua_get([[utils.bitand(33188, 448)]]), 384)
    eq(child.lua_get([[utils.bitor(32768, 420)]]), 33188)
    eq(child.lua_get([[utils.bitxor(5, 3)]]), 6)
end

T["shallowcopy()"] = function()
    eq(child.lua_get([[(function()
        local orig = { a = 1, b = { 2 } }
        local copy = utils.shallowcopy(orig)
        return copy ~= orig and copy.a == 1 and copy.b == orig.b
    end)()]]), true)
    eq(child.lua_get([[utils.shallowcopy(42)]]), 42)
end

T["tableLength()"] = function()
    eq(child.lua_get([[utils.tableLength({ a = 1, b = 2, c = 3 })]]), 3)
    eq(child.lua_get([[utils.tableLength({})]]), 0)
end

T["getpwid()/getgroupname()"] = function()
    if Helpers.is_windows then
        -- Windows paths return env username / hostname
        eq(child.lua_get([[type(utils.getpwid(0)) == "string"]]), true)
        eq(child.lua_get([[type(utils.getgroupname(0)) == "string"]]), true)
        return
    end
    eq(child.lua_get([[utils.getpwid(0)]]), "root")
    eq(child.lua_get([[#utils.getgroupname(0) > 0]]), true)
end

return T
