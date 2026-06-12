local Helpers = {}

Helpers.is_windows = (vim.uv or vim.loop).os_uname().sysname:find("Windows") ~= nil

-- unique temp dir, forward-slash normalized so comparisons work cross-OS
function Helpers.make_temp_dir()
    local path = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(path, "p")
    return path
end

-- populate dir from a spec table:
-- { ["a.txt"] = "contents", ["sub"] = { ["b.txt"] = "x" }, [".hidden"] = "" }
function Helpers.populate(dir, spec)
    for name, value in pairs(spec) do
        local path = dir .. "/" .. name
        if type(value) == "table" then
            vim.fn.mkdir(path, "p")
            Helpers.populate(path, value)
        else
            vim.fn.writefile(vim.split(value, "\n"), path)
        end
    end
end

function Helpers.remove_dir(dir)
    vim.fn.delete(dir, "rf")
end

return Helpers
