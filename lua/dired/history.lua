
local M = {}

local function get_stack()
    if type(vim.b.dired_path_stack) ~= "table" then
        vim.b.dired_path_stack = {}
    end
    return vim.b.dired_path_stack
end

function M.push_path(path)
    if path then
        local stack = get_stack()
        table.insert(stack, path)
        vim.b.dired_path_stack = stack
    end
end

function M.pop_path()
    local stack = get_stack()
    local path = table.remove(stack)
    vim.b.dired_path_stack = stack
    return path
end

return M
